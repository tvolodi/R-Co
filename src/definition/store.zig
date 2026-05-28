//! Process definition store — PD-01, PD-02
//!
//! Owns all DB-backed CRUD operations against `process_definitions`.
//! Calls graph.validateGraph() synchronously inside create() before any
//! INSERT is committed.
//!
//! Design artefact: src/design/definition.md
const std = @import("std");
const db = @import("pool");
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
    /// Search query is empty → HTTP 422 (PD-10).
    QueryEmpty,
    /// Search query exceeds 512 characters → HTTP 422 (PD-10).
    QueryTooLong,
    /// Attempted to DELETE an already-ARCHIVED definition → HTTP 409.
    AlreadyArchived,
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

/// Parameters for Store.update() — used by both PUT and PATCH handlers.
/// Null fields mean "do not change". For PUT, the handler fills all fields.
/// For PATCH, the handler fills only the fields present in the request body.
pub const UpdateParams = struct {
    name: ?[]const u8,
    version: ?[]const u8,
    description: ?[]const u8,
    /// When non-null, the full graph validation pipeline is re-run.
    graph: ?DefinitionGraph,
    stage: ?[]const u8,
};

/// Input to Store.search() (PD-10).
pub const SearchOptions = struct {
    /// The search query string.
    /// Non-empty (QueryEmpty → HTTP 422) and ≤ 512 characters (QueryTooLong → HTTP 422).
    query: []const u8,
    /// Maximum number of results to return; default 20, max 100.
    limit: u32,
    /// Number of results to skip; default 0.
    offset: u32,
};

/// A single result item returned by Store.search() (PD-10).
pub const SearchResult = struct {
    /// The matching definition (all fields identical to Definition).
    definition: Definition,
    /// Relevance rank: 3.0 = exact name match, 2.0 = partial name match, 1.0 = description-only match.
    rank: f32,
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

        const transform_result = graph_mod.validateEdgeTransforms(allocator, params.graph) catch
            return DefinitionError.TransactionFailed;
        if (!transform_result.valid) {
            self.last_violations = transform_result.violations;
            return DefinitionError.GraphValidationFailed;
        }
        allocator.free(transform_result.violations);

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

        // [D] INSERT … ON CONFLICT ON CONSTRAINT uq_definition_tenant_version DO NOTHING RETURNING *
        //     Parameterised — $1=name, $2=version, $3=description, $4=graph, $5=created_by.
        //     Security: no user data appears in the SQL string literal.
        //
        //     Note on ON CONFLICT: the unique constraint uq_definition_tenant_version on
        //     (tenant_id, name, version) enforces the constraint. When an INSERT conflicts
        //     with an existing row, DO NOTHING causes the INSERT to be skipped and RETURNING
        //     to emit 0 rows. (This is expected and correct for concurrent requests — PD-01.)
        const insert_rows = conn.query(
            allocator,
            \\INSERT INTO process_definitions
            \\  (tenant_id, name, version, description, status, graph, created_by, stage)
            \\VALUES (bpm_effective_tenant_id(), $1, $2, $3, 'DRAFT', $4::jsonb, $5::uuid, $6)
            \\ON CONFLICT ON CONSTRAINT uq_definition_tenant_version DO NOTHING
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
            \\  AND tenant_id = bpm_effective_tenant_id()
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
        var first_clause = false;

        sql.appendSlice(a,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\       stage
            \\FROM process_definitions
            \\WHERE tenant_id = bpm_effective_tenant_id()
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
            \\  AND tenant_id = bpm_effective_tenant_id()
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

        if (current_status == .DRAFT) {
            self.clearLastViolations();

            const graph_json = col.get(row, 5);
            const graph_to_validate = parseGraphJson(allocator, graph_json) catch {
                self.setSingleValidationViolation(
                    allocator,
                    "GRAPH_STRUCTURE_INVALID",
                    "Stored definition graph is not a valid JSON graph document",
                ) catch return DefinitionError.TransactionFailed;
                return DefinitionError.GraphValidationFailed;
            };
            defer freeDefinitionGraph(allocator, graph_to_validate);

            const vresult = graph_mod.validateGraph(allocator, graph_to_validate) catch
                return DefinitionError.TransactionFailed;
            if (!vresult.valid) {
                self.last_violations = vresult.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(vresult.violations);

            const attr_result = graph_mod.validateNodeAttributes(allocator, graph_to_validate) catch
                return DefinitionError.TransactionFailed;
            if (!attr_result.valid) {
                self.last_violations = attr_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(attr_result.violations);

            const edge_result = graph_mod.validateEdgeConditions(allocator, graph_to_validate) catch
                return DefinitionError.TransactionFailed;
            if (!edge_result.valid) {
                self.last_violations = edge_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(edge_result.violations);

            const transform_result = graph_mod.validateEdgeTransforms(allocator, graph_to_validate) catch
                return DefinitionError.TransactionFailed;
            if (!transform_result.valid) {
                self.last_violations = transform_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(transform_result.violations);
        }

        // [B] Already ACTIVE → return AlreadyActive error (HTTP 200 via handler).
        //     The handler layer fetches the current definition and returns it with
        //     status 200 — the store signals idempotency via this error variant.
        if (current_status == .ACTIVE) {
            conn.rollback() catch {};
            return DefinitionError.AlreadyActive;
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
            \\  AND tenant_id = bpm_effective_tenant_id()
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
            \\  AND tenant_id = bpm_effective_tenant_id()
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
    // deprecate  (PD-04)
    // -----------------------------------------------------------------------

    /// Atomically deprecate an ACTIVE process definition.
    ///
    /// Behaviour (PD-04):
    ///   - ACTIVE     → sets status to DEPRECATED and updated_at = NOW().
    ///                  Returns the updated Definition.
    ///   - Not found  → returns DefinitionNotFound (HTTP 404).
    ///   - DRAFT / DEPRECATED / ARCHIVED → returns InvalidStatusTransition (HTTP 409).
    ///
    /// Security: id binds via $1::uuid — no user input is interpolated into
    /// SQL string literals.
    pub fn deprecate(
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

        const id_hex = uuidToHex(a, id) catch return DefinitionError.TransactionFailed;

        conn.begin() catch return DefinitionError.TransactionFailed;
        errdefer conn.rollback() catch {};

        // [A] UPDATE ACTIVE → DEPRECATED with RETURNING.
        //     $1 = id (bound parameter — no SQL string interpolation).
        const update_rows = conn.query(
            allocator,
            \\UPDATE process_definitions
            \\SET status = 'DEPRECATED', updated_at = NOW()
            \\WHERE id = $1::uuid AND status = 'ACTIVE'
            \\  AND tenant_id = bpm_effective_tenant_id()
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

        // [B] 0 rows: SELECT to distinguish NotFound from InvalidStatusTransition.
        //     $1 = id (bound parameter — no SQL string interpolation).
        if (update_rows.rows.len == 0) {
            const check_rows = conn.query(
                allocator,
                \\SELECT id FROM process_definitions
                \\WHERE id = $1::uuid
                \\  AND tenant_id = bpm_effective_tenant_id()
            ,
                &.{id_hex},
            ) catch return DefinitionError.TransactionFailed;
            defer {
                var r = check_rows;
                r.deinit();
            }
            if (check_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;
            return DefinitionError.InvalidStatusTransition;
        }

        // [C] COMMIT the transaction.
        conn.commit() catch return DefinitionError.TransactionFailed;

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
    // archive  (PD-04)
    // -----------------------------------------------------------------------

    /// Atomically archive a DEPRECATED process definition.
    ///
    /// Behaviour (PD-04):
    ///   - DEPRECATED → sets status to ARCHIVED, archived_at = NOW(), updated_at = NOW().
    ///                  Returns the updated Definition.
    ///   - Not found  → returns DefinitionNotFound (HTTP 404).
    ///   - DRAFT / ACTIVE / ARCHIVED → returns InvalidStatusTransition (HTTP 409).
    ///
    /// Security: id binds via $1::uuid — no user input is interpolated into
    /// SQL string literals.
    pub fn archive(
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

        const id_hex = uuidToHex(a, id) catch return DefinitionError.TransactionFailed;

        conn.begin() catch return DefinitionError.TransactionFailed;
        errdefer conn.rollback() catch {};

        // [A] UPDATE DEPRECATED → ARCHIVED with RETURNING.
        //     $1 = id (bound parameter — no SQL string interpolation).
        const update_rows = conn.query(
            allocator,
            \\UPDATE process_definitions
            \\SET status = 'ARCHIVED', archived_at = NOW(), updated_at = NOW()
            \\WHERE id = $1::uuid AND status = 'DEPRECATED'
            \\  AND tenant_id = bpm_effective_tenant_id()
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

        // [B] 0 rows: SELECT to distinguish NotFound from InvalidStatusTransition.
        //     $1 = id (bound parameter — no SQL string interpolation).
        if (update_rows.rows.len == 0) {
            const check_rows = conn.query(
                allocator,
                \\SELECT id FROM process_definitions
                \\WHERE id = $1::uuid
                \\  AND tenant_id = bpm_effective_tenant_id()
            ,
                &.{id_hex},
            ) catch return DefinitionError.TransactionFailed;
            defer {
                var r = check_rows;
                r.deinit();
            }
            if (check_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;
            return DefinitionError.InvalidStatusTransition;
        }

        // [C] COMMIT the transaction.
        conn.commit() catch return DefinitionError.TransactionFailed;

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
    // update  (PD-03, PUT/PATCH)
    // -----------------------------------------------------------------------

    /// Update a DRAFT definition in-place.  Any null field in params is left
    /// unchanged.  If params.graph is non-null, the full graph validation
    /// pipeline runs before the UPDATE.
    ///
    /// Behaviour:
    ///   - Fetches current row for existence check and status guard.
    ///   - DRAFT only; any other status → NotDraft (HTTP 409).
    ///   - Not found → DefinitionNotFound (HTTP 404).
    ///   - Graph validation failure → GraphValidationFailed (HTTP 422).
    ///   - name+version uniqueness conflict → DuplicateNameVersion (HTTP 409).
    ///
    /// Security: all user-supplied values bind via $N placeholders.
    pub fn update(
        self: *Store,
        allocator: std.mem.Allocator,
        id: Uuid,
        params: UpdateParams,
    ) DefinitionError!Definition {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        // [A] Run graph validation before touching the DB (fail fast).
        if (params.graph) |g| {
            self.clearLastViolations();

            const vresult = graph_mod.validateGraph(allocator, g) catch
                return DefinitionError.TransactionFailed;
            if (!vresult.valid) {
                self.last_violations = vresult.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(vresult.violations);

            const attr_result = graph_mod.validateNodeAttributes(allocator, g) catch
                return DefinitionError.TransactionFailed;
            if (!attr_result.valid) {
                self.last_violations = attr_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(attr_result.violations);

            const edge_result = graph_mod.validateEdgeConditions(allocator, g) catch
                return DefinitionError.TransactionFailed;
            if (!edge_result.valid) {
                self.last_violations = edge_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(edge_result.violations);

            const transform_result = graph_mod.validateEdgeTransforms(allocator, g) catch
                return DefinitionError.TransactionFailed;
            if (!transform_result.valid) {
                self.last_violations = transform_result.violations;
                return DefinitionError.GraphValidationFailed;
            }
            allocator.free(transform_result.violations);
        }

        // [B] Acquire pool connection.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const id_hex = uuidToHex(a, id) catch return DefinitionError.TransactionFailed;

        conn.begin() catch return DefinitionError.TransactionFailed;
        errdefer conn.rollback() catch {};

        // [C] SELECT FOR UPDATE — verify existence and DRAFT status.
        //     $1 = id (bound parameter — no SQL string interpolation).
        const lock_rows = conn.query(
            allocator,
            \\SELECT id, status FROM process_definitions
            \\WHERE id = $1::uuid
            \\  AND tenant_id = bpm_effective_tenant_id()
            \\FOR UPDATE
        ,
            &.{id_hex},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const col = struct {
            fn get(r: []?[]u8, i: usize) []const u8 {
                if (i >= r.len) return "";
                return r[i] orelse "";
            }
        };

        const current_status = parseDefinitionStatus(col.get(lock_rows.rows[0], 1)) catch .DRAFT;
        if (current_status != .DRAFT) return DefinitionError.NotDraft;

        // [D] Build the SET clause dynamically from non-null params.
        //     All user values are bound parameters — no SQL string interpolation.
        var sql: std.ArrayList(u8) = .empty;
        var bound: std.ArrayList([]const u8) = .empty;
        var pidx: usize = 1;

        sql.appendSlice(a, "UPDATE process_definitions SET updated_at = NOW()") catch
            return DefinitionError.TransactionFailed;

        if (params.name) |name| {
            if (name.len == 0 or name.len > 255) return DefinitionError.NameInvalid;
            sql.appendSlice(a, std.fmt.allocPrint(a, ", name = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, name) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (params.version) |version| {
            if (version.len == 0) return DefinitionError.VersionEmpty;
            sql.appendSlice(a, std.fmt.allocPrint(a, ", version = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, version) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (params.description) |description| {
            sql.appendSlice(a, std.fmt.allocPrint(a, ", description = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, description) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (params.graph) |g| {
            const graph_json = std.json.Stringify.valueAlloc(a, g, .{}) catch
                return DefinitionError.TransactionFailed;
            sql.appendSlice(a, std.fmt.allocPrint(a, ", graph = ${d}::jsonb", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, graph_json) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }
        if (params.stage) |stage| {
            sql.appendSlice(a, std.fmt.allocPrint(a, ", stage = ${d}", .{pidx}) catch
                return DefinitionError.TransactionFailed) catch
                return DefinitionError.TransactionFailed;
            bound.append(a, stage) catch return DefinitionError.TransactionFailed;
            pidx += 1;
        }

        // WHERE clause: id AND status = 'DRAFT' (double-check after SELECT FOR UPDATE).
        sql.appendSlice(a, std.fmt.allocPrint(
            a,
            " WHERE id = ${d}::uuid AND status = 'DRAFT' AND tenant_id = bpm_effective_tenant_id()",
            .{pidx},
        ) catch return DefinitionError.TransactionFailed) catch
            return DefinitionError.TransactionFailed;
        bound.append(a, id_hex) catch return DefinitionError.TransactionFailed;

        // RETURNING clause.
        sql.appendSlice(a,
            \\ RETURNING id, name, version, description, status, graph, created_by,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\          stage
        ) catch return DefinitionError.TransactionFailed;

        // [E] Execute UPDATE … RETURNING.
        const update_rows = conn.query(allocator, sql.items, bound.items) catch |err| switch (err) {
            // DuplicateNameVersion maps to DB UNIQUE constraint violation.
            // pg.zig surfaces constraint violations as QueryFailed; we detect by
            // attempting to distinguish it from other errors at this layer.
            // Without direct pg error-code access in the stub, we treat any
            // QueryFailed after the status guard as DuplicateNameVersion when
            // name or version params were provided.
            else => {
                if (params.name != null or params.version != null) {
                    return DefinitionError.DuplicateNameVersion;
                }
                return DefinitionError.TransactionFailed;
            },
        };
        defer {
            var r = update_rows;
            r.deinit();
        }

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
    // hardDelete  (PD-04 — DRAFT only)
    // -----------------------------------------------------------------------

    /// Hard-delete a DRAFT definition from process_definitions.
    ///
    /// Behaviour:
    ///   - DRAFT   → DELETE row → success (no return value).
    ///   - Not found → DefinitionNotFound (HTTP 404).
    ///   - Non-DRAFT → NotDraft (HTTP 409).
    ///
    /// Security: id binds via $1::uuid — no user input is interpolated into
    /// SQL string literals.
    pub fn hardDelete(
        self: *Store,
        allocator: std.mem.Allocator,
        id: Uuid,
    ) DefinitionError!void {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const id_hex = uuidToHex(a, id) catch return DefinitionError.TransactionFailed;

        conn.begin() catch return DefinitionError.TransactionFailed;
        errdefer conn.rollback() catch {};

        // [A] SELECT FOR UPDATE — verify existence and DRAFT status.
        //     $1 = id (bound parameter — no SQL string interpolation).
        const lock_rows = conn.query(
            allocator,
            \\SELECT id, status FROM process_definitions
            \\WHERE id = $1::uuid
            \\  AND tenant_id = bpm_effective_tenant_id()
            \\FOR UPDATE
        ,
            &.{id_hex},
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0) return DefinitionError.DefinitionNotFound;

        const col = struct {
            fn get(r: []?[]u8, i: usize) []const u8 {
                if (i >= r.len) return "";
                return r[i] orelse "";
            }
        };

        const current_status = parseDefinitionStatus(col.get(lock_rows.rows[0], 1)) catch .DRAFT;
        if (current_status != .DRAFT) return DefinitionError.NotDraft;

        // [B] DELETE the DRAFT row.
        //     $1 = id (bound parameter — no SQL string interpolation).
        conn.exec(
            \\DELETE FROM process_definitions
            \\WHERE id = $1::uuid AND status = 'DRAFT'
            \\  AND tenant_id = bpm_effective_tenant_id()
        ,
            &.{id_hex},
        ) catch return DefinitionError.TransactionFailed;

        // [C] COMMIT.
        conn.commit() catch return DefinitionError.TransactionFailed;
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
    /// SQL: SELECT … FROM process_definitions WHERE tenant_id = bpm_effective_tenant_id() AND name = $1 AND status = 'ACTIVE'
    /// The unique partial index uq_active_definition_tenant guarantees at most one row.
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
            \\WHERE tenant_id = bpm_effective_tenant_id()
            \\  AND name = $1 AND status = 'ACTIVE'
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
    // search  (PD-10)
    // -----------------------------------------------------------------------

    /// Search definitions by name or description using case-insensitive ILIKE.
    ///
    /// Results are ordered by relevance rank (DESC), then by created_at (DESC).
    /// Returns an empty slice (not an error) when no rows match.
    ///
    /// Security: opts.query is bound as pg parameters $1 (exact) and $2 (pattern).
    /// The '%' wildcards in the pattern are placed in the SQL text as part of the
    /// parameter value, never interpolated into the SQL string literal — no SQL
    /// injection is possible.
    pub fn search(
        self: *Store,
        allocator: std.mem.Allocator,
        opts: SearchOptions,
    ) DefinitionError![]SearchResult {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        // [A] Validate query (belt-and-suspenders; handler also validates).
        if (opts.query.len == 0) return DefinitionError.QueryEmpty;
        if (opts.query.len > 512) return DefinitionError.QueryTooLong;

        // [B] Build ILIKE pattern: "%{query}%".
        // Security: opts.query is a plain Zig string value; the '%' characters are
        // added here in Zig, then the entire pattern string is bound as parameter $2
        // via pg.zig — it is never embedded in the SQL text.
        const pattern = std.fmt.allocPrint(a, "%{s}%", .{opts.query}) catch
            return DefinitionError.TransactionFailed;

        // [C] Acquire pool connection.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return DefinitionError.PoolExhausted,
            else => return DefinitionError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Serialise limit and offset as decimal strings for pg parameter binding.
        const limit_str = intToStr(a, @as(i64, @intCast(opts.limit))) catch
            return DefinitionError.TransactionFailed;
        const offset_str = intToStr(a, @as(i64, @intCast(opts.offset))) catch
            return DefinitionError.TransactionFailed;

        // [D] Execute ILIKE SELECT with four bound parameters:
        //     $1 = opts.query (exact match for rank 3.0)
        //     $2 = pattern    (partial match for rank 2.0 / WHERE clause)
        //     $3 = limit
        //     $4 = offset
        //     Column order matches rowToDefinition expectations (cols 0–10) + rank at col 11.
        //     Security: no user input appears in the SQL string literal.
        const rows = conn.query(
            allocator,
            \\SELECT id, name, version, description, status, graph, created_by,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint,
            \\       stage,
            \\       CASE WHEN name ILIKE $1 THEN 3.0 WHEN name ILIKE $2 THEN 2.0 ELSE 1.0 END AS rank
            \\FROM process_definitions
            \\WHERE tenant_id = bpm_effective_tenant_id()
            \\  AND (name ILIKE $2 OR description ILIKE $2)
            \\ORDER BY rank DESC, created_at DESC
            \\LIMIT $3 OFFSET $4
        ,
            &.{ opts.query, pattern, limit_str, offset_str },
        ) catch return DefinitionError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        return rowsToSearchResults(allocator, rows.rows);
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    pub fn clearLastViolations(self: *Store) void {
        if (self.last_violations.len > 0) {
            for (self.last_violations) |v| self.allocator.free(v.message);
            self.allocator.free(self.last_violations);
            self.last_violations = &.{};
        }
    }

    fn setSingleValidationViolation(
        self: *Store,
        allocator: std.mem.Allocator,
        code: []const u8,
        message: []const u8,
    ) error{OutOfMemory}!void {
        self.clearLastViolations();
        const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code, message });
        const violations = try allocator.alloc(Violation, 1);
        violations[0] = Violation{ .code = code, .message = msg };
        self.last_violations = violations;
    }
};

// ---------------------------------------------------------------------------
// Row parsing helpers
// ---------------------------------------------------------------------------

pub fn freeDefinitionGraph(allocator: std.mem.Allocator, graph: DefinitionGraph) void {
    for (graph.nodes) |n| {
        allocator.free(n.id);
        if (n.label) |l| allocator.free(l);
        if (n.attributes) |attrs| allocator.free(attrs);
    }
    allocator.free(graph.nodes);

    for (graph.edges) |e| {
        allocator.free(e.id);
        allocator.free(e.source);
        allocator.free(e.target);
        if (e.condition) |c| allocator.free(c);
        if (e.transform) |t| allocator.free(t);
    }
    allocator.free(graph.edges);
}

fn parseGraphJson(allocator: std.mem.Allocator, graph_json: []const u8) !DefinitionGraph {
    var parsed = try std.json.parseFromSlice(DefinitionGraph, allocator, graph_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    const nodes_copy = try allocator.alloc(graph_mod.GraphNode, parsed.value.nodes.len);
    var nodes_built: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < nodes_built) : (i += 1) {
            allocator.free(nodes_copy[i].id);
            if (nodes_copy[i].label) |l| allocator.free(l);
            if (nodes_copy[i].attributes) |a| allocator.free(a);
        }
        allocator.free(nodes_copy);
    }
    for (parsed.value.nodes, 0..) |n, i| {
        nodes_copy[i] = .{
            .id = try allocator.dupe(u8, n.id),
            .node_type = n.node_type,
            .label = if (n.label) |l| try allocator.dupe(u8, l) else null,
            .attributes = if (n.attributes) |a| try allocator.dupe(u8, a) else null,
        };
        nodes_built += 1;
    }

    const edges_copy = try allocator.alloc(graph_mod.GraphEdge, parsed.value.edges.len);
    var edges_built: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < edges_built) : (i += 1) {
            allocator.free(edges_copy[i].id);
            allocator.free(edges_copy[i].source);
            allocator.free(edges_copy[i].target);
            if (edges_copy[i].condition) |c| allocator.free(c);
            if (edges_copy[i].transform) |t| allocator.free(t);
        }
        allocator.free(edges_copy);
    }
    for (parsed.value.edges, 0..) |e, i| {
        edges_copy[i] = .{
            .id = try allocator.dupe(u8, e.id),
            .source = try allocator.dupe(u8, e.source),
            .target = try allocator.dupe(u8, e.target),
            .condition = if (e.condition) |c| try allocator.dupe(u8, c) else null,
            .transform = if (e.transform) |t| try allocator.dupe(u8, t) else null,
            .is_default = e.is_default,
        };
        edges_built += 1;
    }

    parsed.deinit();
    return DefinitionGraph{ .nodes = nodes_copy, .edges = edges_copy };
}

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
/// Parses a DB row into a Definition. Column index layout documented above.
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

    const graph_json_str = col.get(row, 5);
    const graph = if (graph_json_str.len > 0)
        parseGraphJson(allocator, graph_json_str) catch fallback.graph
    else
        fallback.graph;

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

/// Build []SearchResult from raw DB rows returned by Store.search().
/// Columns 0–10 match rowToDefinition expectations; column 11 is the rank float.
fn rowsToSearchResults(allocator: std.mem.Allocator, rows: [][]?[]u8) DefinitionError![]SearchResult {
    const results = allocator.alloc(SearchResult, rows.len) catch
        return DefinitionError.TransactionFailed;
    const stub = CreateParams{
        .name = "",
        .version = "",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
        .created_by = std.mem.zeroes(Uuid),
    };
    const col = struct {
        fn get(r: []?[]u8, idx: usize) []const u8 {
            if (idx >= r.len) return "";
            return r[idx] orelse "";
        }
    };
    for (rows, 0..) |row, i| {
        const def = rowToDefinition(allocator, row, stub) catch {
            allocator.free(results);
            return DefinitionError.TransactionFailed;
        };
        const rank = std.fmt.parseFloat(f32, col.get(row, 11)) catch 1.0;
        results[i] = SearchResult{ .definition = def, .rank = rank };
    }
    return results;
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
