//! Process definition store — PD-01, PD-02
//!
//! Owns all DB-backed CRUD operations against `process_definitions`.
//! Calls graph.validateGraph() synchronously inside create() before any
//! INSERT is committed.
//!
//! Design artefact: src/design/definition.md
const std = @import("std");
const db = @import("../db/pool.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const graph_mod = @import("graph.zig");

// ---------------------------------------------------------------------------
// Re-export shared types from graph.zig so callers can import one file
// ---------------------------------------------------------------------------

pub const Uuid = graph_mod.Uuid;
pub const NodeType = graph_mod.NodeType;
pub const DefinitionStatus = graph_mod.DefinitionStatus;
pub const GraphNode = graph_mod.GraphNode;
pub const GraphEdge = graph_mod.GraphEdge;
pub const DefinitionGraph = graph_mod.DefinitionGraph;
pub const Definition = graph_mod.Definition;
pub const Violation = graph_mod.Violation;
pub const ValidationResult = graph_mod.ValidationResult;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const DefinitionError = error{
    /// db.Pool.acquire() returned ExhaustedPool → HTTP 503.
    PoolExhausted,
    /// UNIQUE (name, version) constraint violated → HTTP 409 (PD-01).
    DuplicateNameVersion,
    /// id not found in process_definitions → HTTP 404.
    DefinitionNotFound,
    /// Attempted status transition not permitted by lifecycle rules (PD-04) → HTTP 422.
    InvalidStatusTransition,
    /// Caller supplied a non-DRAFT initial status → HTTP 422 (PD-01).
    InitialStatusNotDraft,
    /// name is empty or longer than 255 characters → HTTP 422 (PD-01).
    NameInvalid,
    /// version is empty → HTTP 422 (PD-01).
    VersionEmpty,
    /// graph is not a JSON object with a `nodes` array and an `edges` array → HTTP 422.
    GraphStructureInvalid,
    /// graph failed one or more PD-02 structural checks; call lastViolations() → HTTP 422.
    GraphValidationFailed,
    /// DB transaction failed to commit (transient) → HTTP 500.
    TransactionFailed,
    /// Definition is already ACTIVE; activate() is a no-op (HTTP 200).  Defined
    /// for use by HTTP handlers that need to distinguish the idempotent case.
    AlreadyActive,
    /// Attempted to activate a DEPRECATED or ARCHIVED definition → HTTP 409.
    /// Only DRAFT definitions may be activated (PD-03).
    NotDraft,
};

// ---------------------------------------------------------------------------
// Input / option types
// ---------------------------------------------------------------------------

/// Parameters for Store.create() (PD-01).
pub const CreateParams = struct {
    name: []const u8,
    version: []const u8,
    /// Optional; stored as NULL when omitted.
    description: ?[]const u8,
    graph: DefinitionGraph,
    /// Taken from auth middleware ctx.actor.user_id.
    created_by: Uuid,
    /// Optional process stage label (PD-07). Stored as NULL when omitted.
    stage: ?[]const u8 = null,
};

/// Options for Store.list().
pub const ListOpts = struct {
    /// Filter by exact name; null = all names.
    name: ?[]const u8,
    /// Filter by status; null = all statuses.
    status: ?DefinitionStatus,
    /// Filter by process stage label; null = all stages (PD-07).
    stage: ?[]const u8 = null,
    /// Cursor: return rows with created_at (UTC µs) strictly after this value.
    after_created: ?i64,
    /// Maximum rows to return; 0 → default 50; max 200.
    limit: u8,
};

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub const Store = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    /// Violations from the most recent create() that returned GraphValidationFailed.
    /// Owned by the Store; freed on the next Store method call or deinit().
    last_violations: []Violation,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// pool must outlive Store.
    pub fn init(allocator: std.mem.Allocator, pool: *Pool) Store {
        return Store{
            .allocator = allocator,
            .pool = pool,
            .last_violations = &.{},
        };
    }

    pub fn deinit(self: *Store) void {
        self.clearLastViolations();
    }

    // -----------------------------------------------------------------------
    // create  (PD-01, PD-02)
    // -----------------------------------------------------------------------

    /// Validate input fields, run graph.validateGraph(), then INSERT into
    /// process_definitions with status = DRAFT and a platform-assigned UUID.
    ///
    /// Returns the fully-populated Definition on success (HTTP 201).
    /// On PD-02 failure: returns GraphValidationFailed; call lastViolations().
    /// On name+version collision: returns DuplicateNameVersion (HTTP 409).
    ///
    /// Security: all user-supplied values bind via $N placeholders — no SQL
    /// string interpolation anywhere in this function.
    pub fn create(
        self: *Store,
        allocator: std.mem.Allocator,
        params: CreateParams,
    ) DefinitionError!Definition {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        // [A] Input validation (no DB writes on failure)

        // PD-01: name non-empty, ≤ 255 chars.
        if (params.name.len == 0 or params.name.len > 255) return DefinitionError.NameInvalid;

        // PD-01: version non-empty.
        if (params.version.len == 0) return DefinitionError.VersionEmpty;

        // PD-01: graph must have a nodes array and an edges array (structural check only).
        // Deep structural validation happens in validateGraph below.
        // (Null-check is implicit — DefinitionGraph always has the fields.)

        // [B] PD-02: graph structural validation.
        self.clearLastViolations();
        const vresult = graph_mod.validateGraph(allocator, params.graph) catch
            return DefinitionError.TransactionFailed;
        if (!vresult.valid) {
            // Store violations so the caller can retrieve them via lastViolations().
            self.last_violations = vresult.violations;
            return DefinitionError.GraphValidationFailed;
        }
        // vresult.violations is empty; free the (empty) slice.
        allocator.free(vresult.violations);

        // [B2] PD-05: per-node-type attribute validation.
        const attr_result = graph_mod.validateNodeAttributes(allocator, params.graph) catch
            return DefinitionError.TransactionFailed;
        if (!attr_result.valid) {
            self.last_violations = attr_result.violations;
            return DefinitionError.GraphValidationFailed;
        }
        allocator.free(attr_result.violations);

        // [B3] PD-06: edge condition validation.
        const edge_result = graph_mod.validateEdgeConditions(allocator, params.graph) catch
            return DefinitionError.TransactionFailed;
        if (!edge_result.valid) {
            self.last_violations = edge_result.violations;
            return DefinitionError.GraphValidationFailed;
        }
        allocator.free(edge_result.violations);

        // [C] Acquire pool connection.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Serialise graph to JSON for JSONB column.  No user input in the SQL
        // string itself — the serialised value binds as $4.
        const graph_json = std.json.Stringify.valueAlloc(a, params.graph, .{}) catch
            return DefinitionError.TransactionFailed;
        // graph_json is freed when param_arena is deinitialized at function exit.

        // [D] INSERT … ON CONFLICT (name, version) DO NOTHING RETURNING *
        //     Parameterised — $1=name, $2=version, $3=description, $4=graph, $5=created_by.
        //     Security: no user data appears in the SQL string literal.
        const insert_rows = conn.query(
            allocator,
            \\INSERT INTO process_definitions
            \\  (name, version, description, status, graph, created_by, stage)
            \\VALUES ($1, $2, $3, 'DRAFT', $4::jsonb, $5::uuid, $6)
            \\ON CONFLICT (name, version) DO NOTHING
            \\RETURNING id, name, version, description, status, graph, created_by,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\          stage
        ,
            &.{
                params.name,
                params.version,
                params.description orelse "",
                graph_json,
                uuidToHex(a, params.created_by) catch return DefinitionError.TransactionFailed,
                params.stage orelse "",
            },
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = insert_rows;
            r.deinit();
        }

        // 0 rows = UNIQUE conflict lost the race (PD-01 concurrent requests).
        if (insert_rows.rows.len == 0) return DefinitionError.DuplicateNameVersion;

        return rowToDefinition(allocator, insert_rows.rows[0], params) catch
            DefinitionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // getById
    // -----------------------------------------------------------------------

    /// Retrieve a single definition by primary key.
    /// Returns DefinitionNotFound if id is not in process_definitions.
    ///
    /// Security: id binds as $1 — no SQL string interpolation.
    pub fn getById(
        self: *Store,
        allocator: std.mem.Allocator,
        id: Uuid,
    ) DefinitionError!Definition {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const rows = conn.query(
            allocator,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\       stage
            \\FROM process_definitions
            \\WHERE id = $1::uuid
        ,
            &.{uuidToHex(a, id) catch return DefinitionError.TransactionFailed},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const stub_params = CreateParams{
            .name = "",
            .version = "",
            .description = null,
            .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
            .created_by = std.mem.zeroes(Uuid),
        };
        return rowToDefinition(allocator, rows.rows[0], stub_params) catch
            DefinitionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // list
    // -----------------------------------------------------------------------

    /// List definitions with optional filters; cursor-based, ordered by
    /// created_at ASC.  Returns an empty slice when no rows match.
    ///
    /// Security: all filter values bind via $N placeholders.  The SQL string
    /// is assembled from constant literals only — no user input is interpolated
    /// into the SQL string.
    pub fn list(
        self: *Store,
        allocator: std.mem.Allocator,
        opts: ListOpts,
    ) DefinitionError![]Definition {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const effective_limit: u8 = if (opts.limit == 0) 50 else if (opts.limit > 200) 200 else opts.limit;

        // Build parameterised query from constant SQL parts.
        // User filter values appear exclusively as $N parameters — never in the
        // SQL string literals — so there is no SQL injection risk.
        var sql: std.ArrayList(u8) = .empty;
        var bound: std.ArrayList([]const u8) = .empty;
        var pidx: usize = 1;
        var first_clause = true;

        sql.appendSlice(a,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\       stage
            \\FROM process_definitions
        ) catch return DefinitionError.TransactionFailed;

        if (opts.name) |name| {
            sql.appendSlice(a, if (first_clause) "\nWHERE " else "\n  AND ") catch
                return DefinitionError.TransactionFailed;
            first_clause = false;
            sql.appendSlice(a, std.fmt.allocPrint(a, "name = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, name) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (opts.status) |status| {
            sql.appendSlice(a, if (first_clause) "\nWHERE " else "\n  AND ") catch
                return DefinitionError.TransactionFailed;
            first_clause = false;
            sql.appendSlice(a, std.fmt.allocPrint(a, "status = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, definitionStatusToStr(status)) catch
                return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (opts.stage) |stage| {
            sql.appendSlice(a, if (first_clause) "\nWHERE " else "\n  AND ") catch
                return DefinitionError.TransactionFailed;
            first_clause = false;
            sql.appendSlice(a, std.fmt.allocPrint(a, "stage = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, stage) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (opts.after_created) |after| {
            sql.appendSlice(a, if (first_clause) "\nWHERE " else "\n  AND ") catch
                return DefinitionError.TransactionFailed;
            first_clause = false;
            sql.appendSlice(a, std.fmt.allocPrint(
                a,
                "(EXTRACT(EPOCH FROM created_at) * 1000000)::bigint > ${d}",
                .{pidx},
            ) catch return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(
                a,
                intToStr(a, after) catch return DefinitionError.TransactionFailed,
            ) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }

        sql.appendSlice(a, std.fmt.allocPrint(
            a,
            "\nORDER BY created_at ASC\nLIMIT ${d}",
            .{pidx},
        ) catch return DefinitionError.TransactionFailed) catch
            return DefinitionError.TransactionFailed;
        bound.append(
            a,
            intToStr(a, @as(i64, @intCast(effective_limit))) catch
                return DefinitionError.TransactionFailed,
        ) catch return DefinitionError.TransactionFailed;

        const rows = conn.query(allocator, sql.items, bound.items) catch
            return DefinitionError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        return rowsToDefinitions(allocator, rows.rows);
    }

    // -----------------------------------------------------------------------
    // activate  (PD-03)
    // -----------------------------------------------------------------------

    /// Atomically activate a DRAFT process definition.
    ///
    /// Behaviour (PD-03):
    ///   - DRAFT      → sets any existing ACTIVE version of the same name to
    ///                  DEPRECATED, then sets this definition to ACTIVE.
    ///                  Returns the updated Definition.
    ///   - ACTIVE     → no-op; returns the definition unchanged (idempotent,
    ///                  HTTP 200).
    ///   - DEPRECATED / ARCHIVED → returns NotDraft (HTTP 409).
    ///   - Not found  → returns DefinitionNotFound (HTTP 404).
    ///
    /// All state changes run inside a single SQL transaction (BEGIN … COMMIT)
    /// so that the unique-per-name ACTIVE invariant is never violated.
    ///
    /// Security: id binds via $1::uuid — no user input is interpolated into
    /// SQL string literals.
    pub fn activate(
        self: *Store,
        allocator: std.mem.Allocator,
        id: Uuid,
    ) DefinitionError!Definition {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Serialise id once; reused for SELECT and UPDATE.
        const id_hex = uuidToHex(a, id) catch return DefinitionError.TransactionFailed;

        // BEGIN transaction.
        conn.begin() catch return DefinitionError.TransactionFailed;
        // On any error path after this point, roll back.  Double-rollback after
        // an explicit COMMIT is harmless — the server rejects it and we ignore
        // the error.
        errdefer conn.rollback() catch {};

        // [A] SELECT FOR UPDATE — read current status and lock the row.
        //     $1 = id.  No user input in the SQL string literal.
        const lock_rows = conn.query(
            allocator,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint
            \\FROM process_definitions
            \\WHERE id = $1::uuid
            \\FOR UPDATE
        ,
            &.{id_hex},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const row = lock_rows.rows[0];

        const col = struct {
            fn get(r: []?[]u8, i: usize) []const u8 {
                if (i >= r.len) return "";
                return r[i] orelse "";
            }
        };

        const current_status = parseDefinitionStatus(col.get(row, 4)) catch .DRAFT;

        // [B] Already ACTIVE → idempotent no-op; rollback (nothing changed) and
        //     return the current definition.
        if (current_status == .ACTIVE) {
            conn.rollback() catch {};
            const stub = CreateParams{
                .name = "",
                .version = "",
                .description = null,
                .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
                .created_by = std.mem.zeroes(Uuid),
            };
            return rowToDefinition(allocator, row, stub) catch
                DefinitionError.TransactionFailed;
        }

        // [C] DEPRECATED or ARCHIVED → reject with NotDraft (HTTP 409).
        if (current_status != .DRAFT) return DefinitionError.NotDraft;

        // [D] status is DRAFT — proceed with the atomic activation.

        // The name value is a slice into lock_rows memory; it lives until the
        // defer above frees lock_rows at function exit.
        const def_name = col.get(row, 1);

        // [E] Deprecate any existing ACTIVE version for the same name.
        //     $1 = name (bound parameter — no SQL string interpolation).
        conn.exec(
            \\UPDATE process_definitions
            \\SET status = 'DEPRECATED', updated_at = NOW()
            \\WHERE name = $1 AND status = 'ACTIVE'
        ,
            &.{def_name},
        ) catch return DefinitionError.TransactionFailed;

        // [F] Activate the target row.  RETURNING gives us the post-UPDATE row
        //     so we avoid a separate SELECT after COMMIT.
        //     $1 = id (bound parameter — no SQL string interpolation).
        const update_rows = conn.query(
            allocator,
            \\UPDATE process_definitions
            \\SET status = 'ACTIVE', updated_at = NOW()
            \\WHERE id = $1::uuid AND status = 'DRAFT'
            \\RETURNING id, name, version, description, status, graph, created_by,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint
        ,
            &.{id_hex},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = update_rows;
            r.deinit();
        }

        // [G] COMMIT the transaction.
        conn.commit() catch return DefinitionError.TransactionFailed;

        if (update_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const stub = CreateParams{
            .name = "",
            .version = "",
            .description = null,
            .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
            .created_by = std.mem.zeroes(Uuid),
        };
        return rowToDefinition(allocator, update_rows.rows[0], stub) catch
            DefinitionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // lastViolations
    // -----------------------------------------------------------------------

    /// Return the PD-02 violations from the most recent create() call that
    /// returned GraphValidationFailed.  The slice is owned by the Store and
    /// valid until the next Store method call.
    pub fn lastViolations(self: *Store) []const Violation {
        return self.last_violations;
    }

    // -----------------------------------------------------------------------
    // getActiveByName  (PD-07)
    // -----------------------------------------------------------------------

    /// Retrieve the currently ACTIVE version of a definition by name.
    /// Returns DefinitionNotFound if no ACTIVE version exists for the given name.
    ///
    /// SQL: SELECT … FROM process_definitions WHERE name = $1 AND status = 'ACTIVE'
    /// The unique partial index uq_active_definition guarantees at most one row.
    ///
    /// Security: name binds as $1 — no SQL string interpolation.
    pub fn getActiveByName(
        self: *Store,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) DefinitionError!Definition {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const rows = conn.query(
            allocator,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\       stage
            \\FROM process_definitions
            \\WHERE name = $1 AND status = 'ACTIVE'
        ,
            &.{name},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const stub_params = CreateParams{
            .name = "",
            .version = "",
            .description = null,
            .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
            .created_by = std.mem.zeroes(Uuid),
        };
        return rowToDefinition(allocator, rows.rows[0], stub_params) catch
            DefinitionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn clearLastViolations(self: *Store) void {
        if (self.last_violations.len > 0) {
            for (self.last_violations) |v| self.allocator.free(v.message);
            self.allocator.free(self.last_violations);
            self.last_violations = &.{};
        }
    }
};

// ---------------------------------------------------------------------------
// Row parsing helpers
// ---------------------------------------------------------------------------

/// Columns returned by every SELECT / INSERT RETURNING in this module:
///   0  id           UUID text
///   1  name         TEXT
///   2  version      TEXT
///   3  description  TEXT or NULL
///   4  status       TEXT
///   5  graph        JSONB text
///   6  created_by   UUID text
///   7  created_at   bigint (µs)
///   8  updated_at   bigint (µs)
///   9  archived_at  bigint or NULL
///
/// NOTE: When pg.zig is fully implemented, real row data will be present.
/// Currently all DB calls return QueryFailed so this path is never reached.
fn rowToDefinition(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    fallback: CreateParams,
) error{OutOfMemory}!Definition {
    const col = struct {
        fn get(r: []?[]u8, i: usize) []const u8 {
            if (i >= r.len) return "";
            return r[i] orelse "";
        }
        fn getOpt(r: []?[]u8, i: usize) ?[]const u8 {
            if (i >= r.len) return null;
            return r[i];
        }
    };

    const id_str = col.get(row, 0);
    const id = parseUuid(id_str) catch std.mem.zeroes(Uuid);

    const name = try allocator.dupe(u8, if (col.get(row, 1).len > 0) col.get(row, 1) else fallback.name);
    const version = try allocator.dupe(u8, if (col.get(row, 2).len > 0) col.get(row, 2) else fallback.version);

    const desc_raw = col.getOpt(row, 3);
    const description: ?[]const u8 = if (desc_raw) |d|
        try allocator.dupe(u8, d)
    else
        null;

    const status = parseDefinitionStatus(col.get(row, 4)) catch .DRAFT;

    // Stub: graph column not parsed until pg.zig delivers real rows.
    // TODO: parse JSONB text into DefinitionGraph when pg.zig is complete.
    const graph = fallback.graph;

    const created_by_str = col.get(row, 6);
    const created_by = parseUuid(created_by_str) catch fallback.created_by;

    const created_at = std.fmt.parseInt(i64, col.get(row, 7), 10) catch 0;
    const updated_at = std.fmt.parseInt(i64, col.get(row, 8), 10) catch 0;
    const archived_at: ?i64 = if (col.getOpt(row, 9)) |s|
        std.fmt.parseInt(i64, s, 10) catch null
    else
        null;

    const stage_raw = col.getOpt(row, 10);
    const stage: ?[]const u8 = if (stage_raw) |s|
        try allocator.dupe(u8, s)
    else
        null;

    return Definition{
        .id = id,
        .name = name,
        .version = version,
        .description = description,
        .status = status,
        .graph = graph,
        .created_by = created_by,
        .created_at = created_at,
        .updated_at = updated_at,
        .archived_at = archived_at,
        .stage = stage,
    };
}

fn rowsToDefinitions(allocator: std.mem.Allocator, rows: [][]?[]u8) DefinitionError![]Definition {
    const defs = allocator.alloc(Definition, rows.len) catch
        return DefinitionError.TransactionFailed;
    const stub = CreateParams{
        .name = "",
        .version = "",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
        .created_by = std.mem.zeroes(Uuid),
    };
    for (rows, 0..) |row, i| {
        defs[i] = rowToDefinition(allocator, row, stub) catch {
            allocator.free(defs);
            return DefinitionError.TransactionFailed;
        };
    }
    return defs;
}

// ---------------------------------------------------------------------------
// Module-level helper functions
// ---------------------------------------------------------------------------

/// Render a UUID as lowercase hex with hyphens: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
fn uuidToHex(allocator: std.mem.Allocator, uuid: Uuid) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Parse a UUID hex string (36 chars with hyphens) into a raw [16]u8.
fn parseUuid(hex: []const u8) error{InvalidUuid}!Uuid {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: Uuid = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

/// Serialise a signed integer to a decimal string owned by allocator.
fn intToStr(allocator: std.mem.Allocator, value: i64) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn definitionStatusToStr(status: DefinitionStatus) []const u8 {
    return switch (status) {
        .DRAFT => "DRAFT",
        .ACTIVE => "ACTIVE",
        .DEPRECATED => "DEPRECATED",
        .ARCHIVED => "ARCHIVED",
    };
}

fn parseDefinitionStatus(s: []const u8) error{InvalidStatus}!DefinitionStatus {
    if (std.mem.eql(u8, s, "DRAFT")) return .DRAFT;
    if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
    if (std.mem.eql(u8, s, "DEPRECATED")) return .DEPRECATED;
    if (std.mem.eql(u8, s, "ARCHIVED")) return .ARCHIVED;
    return error.InvalidStatus;
}
