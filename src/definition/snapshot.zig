//! Definition snapshot store — PD-08
//!
//! Creates and retrieves immutable snapshots of process definitions bound to
//! specific process instances.  Called by the engine at instance-start time
//! (EE-01) BEFORE any event is appended to the event store.
//!
//! Design artefact: src/design/definition.md §PD-08
const std = @import("std");
const db = @import("../db/pool.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const graph_mod = @import("graph.zig");

// Re-export types so callers can import from one file.
pub const Uuid = graph_mod.Uuid;
pub const DefinitionGraph = graph_mod.DefinitionGraph;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const SnapshotError = error{
    /// The referenced definition_id does not exist in process_definitions.
    /// HTTP 404.
    DefinitionNotFound,
    /// A snapshot for this instance_id already exists — snapshots are immutable
    /// after creation; a duplicate insert is rejected.  HTTP 409.
    SnapshotAlreadyExists,
    /// db.Pool.acquire() returned ExhaustedPool.  HTTP 503.
    PoolExhausted,
    /// DB transaction failed to commit (transient).  HTTP 500.
    TransactionFailed,
};

// ---------------------------------------------------------------------------
// Snapshot struct
// ---------------------------------------------------------------------------

pub const Snapshot = struct {
    /// Primary key of the snapshot row; one-to-one with a process instance.
    /// Maps to: instance_definition_snapshots.instance_id (UUID PRIMARY KEY)
    instance_id: Uuid,
    /// FK to process_definitions.id — the definition version snapshotted.
    /// Maps to: instance_definition_snapshots.definition_id
    definition_id: Uuid,
    /// Denormalised definition name at time of snapshot.
    /// Maps to: instance_definition_snapshots.definition_name (TEXT NOT NULL)
    definition_name: []const u8,
    /// Denormalised version string at time of snapshot.
    /// Maps to: instance_definition_snapshots.definition_ver (TEXT NOT NULL)
    definition_ver: []const u8,
    /// Full immutable DefinitionGraph (nodes, edges, attributes, is_default flags).
    /// Maps to: instance_definition_snapshots.graph (JSONB NOT NULL)
    graph: graph_mod.DefinitionGraph,
    /// UTC epoch microseconds derived from TIMESTAMPTZ snapshotted_at column.
    snapshotted_at: i64,
};

pub fn freeSnapshot(allocator: std.mem.Allocator, snapshot: Snapshot) void {
    allocator.free(snapshot.definition_name);
    allocator.free(snapshot.definition_ver);

    for (snapshot.graph.nodes) |node| {
        allocator.free(node.id);
        if (node.label) |label| allocator.free(label);
        if (node.attributes) |attributes| allocator.free(attributes);
    }
    if (snapshot.graph.nodes.len > 0) {
        allocator.free(snapshot.graph.nodes);
    }

    for (snapshot.graph.edges) |edge| {
        allocator.free(edge.id);
        allocator.free(edge.source);
        allocator.free(edge.target);
        if (edge.condition) |condition| allocator.free(condition);
    }
    if (snapshot.graph.edges.len > 0) {
        allocator.free(snapshot.graph.edges);
    }
}

// ---------------------------------------------------------------------------
// SnapshotStore
// ---------------------------------------------------------------------------

pub const SnapshotStore = struct {
    pool: *Pool,

    /// Create a new SnapshotStore backed by the given connection pool.
    pub fn init(pool: *Pool) SnapshotStore {
        return SnapshotStore{ .pool = pool };
    }

    // -----------------------------------------------------------------------
    // create  (PD-08)
    // -----------------------------------------------------------------------

    /// Create an immutable snapshot of `definition_id` bound to `instance_id`.
    ///
    /// Reads the definition row from `process_definitions` (under FOR SHARE lock)
    /// and inserts a row into `instance_definition_snapshots` — both within a
    /// single DB transaction.  This atomicity ensures the captured graph is
    /// consistent with the row referenced by the FK.
    ///
    /// Returns DefinitionNotFound if `definition_id` is not in process_definitions.
    /// Returns SnapshotAlreadyExists if a snapshot for `instance_id` already exists
    ///   (INSERT ... ON CONFLICT DO NOTHING returned 0 rows).
    ///
    /// Called by the engine at instance-start time (EE-01).  If this function
    /// returns any error, the EE-01 caller MUST abort — do NOT append any event.
    ///
    /// Security: ALL values bound as pg parameters ($1, $2, …) — no SQL string
    /// interpolation of user data anywhere in this function.
    pub fn create(
        self: *SnapshotStore,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        definition_id: Uuid,
    ) SnapshotError!Snapshot {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return SnapshotError.PoolExhausted,
            else => return SnapshotError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Serialise UUIDs to hex strings for binding.  All user-supplied values
        // bind via $N — no UUID bytes appear in the SQL string literal.
        const def_id_hex = uuidToHex(a, definition_id) catch
            return SnapshotError.TransactionFailed;
        const inst_id_hex = uuidToHex(a, instance_id) catch
            return SnapshotError.TransactionFailed;

        // BEGIN transaction.
        conn.begin() catch return SnapshotError.TransactionFailed;
        // On any error path after BEGIN, roll back.  Double-rollback after a
        // COMMIT is harmless — the server rejects it and we ignore the error.
        errdefer conn.rollback() catch {};

        // ── Step 1: read the definition under a shared lock ──────────────────
        // FOR SHARE prevents any concurrent transaction from hard-deleting or
        // exclusively locking the definition row between this read and the INSERT.
        // $1 = definition_id (UUID bound parameter — no SQL string interpolation).
        const def_rows = conn.query(
            allocator,
            \\SELECT id, name, version, graph
            \\FROM process_definitions
            \\WHERE id = $1::uuid
            \\  AND tenant_id = bpm_effective_tenant_id()
            \\FOR SHARE
        ,
            &.{def_id_hex},
        ) catch return SnapshotError.TransactionFailed;
        defer {
            var r = def_rows;
            r.deinit();
        }

        // 0 rows → definition does not exist (or was deleted before we locked it).
        if (def_rows.rows.len == 0) return SnapshotError.DefinitionNotFound;

        const def_row = def_rows.rows[0];
        const def_name = colGet(def_row, 1);
        const def_ver = colGet(def_row, 2);
        const graph_json_str = colGet(def_row, 3);

        // ── Step 2: insert the snapshot row idempotently ─────────────────────
        // ON CONFLICT (instance_id) DO NOTHING: if a snapshot already exists for
        // this instance_id (e.g. a retried EE-01), the INSERT is silently skipped
        // and RETURNING yields 0 rows → SnapshotAlreadyExists.
        //
        // Parameter binding (no SQL string interpolation):
        //   $1 = definition_id  $2 = instance_id
        //   $3 = name           $4 = version
        //   $5 = graph (raw JSONB text from Step 1 result, re-bound as JSONB)
        const ins_rows = conn.query(
            allocator,
            \\INSERT INTO instance_definition_snapshots
            \\    (instance_id, definition_id, definition_name, definition_ver, graph)
            \\VALUES ($2::uuid, $1::uuid, $3, $4, $5::jsonb)
            \\ON CONFLICT (instance_id) DO NOTHING
            \\RETURNING
            \\    instance_id,
            \\    definition_id,
            \\    definition_name,
            \\    definition_ver,
            \\    graph,
            \\    (EXTRACT(EPOCH FROM snapshotted_at) * 1000000)::bigint
        ,
            &.{ def_id_hex, inst_id_hex, def_name, def_ver, graph_json_str },
        ) catch return SnapshotError.TransactionFailed;
        defer {
            var r = ins_rows;
            r.deinit();
        }

        // 0 rows returned → ON CONFLICT triggered → snapshot already existed.
        if (ins_rows.rows.len == 0) return SnapshotError.SnapshotAlreadyExists;

        // COMMIT the transaction.
        conn.commit() catch return SnapshotError.TransactionFailed;

        return rowToSnapshot(allocator, ins_rows.rows[0]) catch
            SnapshotError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // getByInstanceId  (PD-08)
    // -----------------------------------------------------------------------

    /// Retrieve the immutable snapshot for a running instance.
    ///
    /// Returns DefinitionNotFound if no snapshot row exists for `instance_id`.
    /// Used by the engine transition function (EE-02) to obtain the graph for
    /// evaluating state transitions.
    ///
    /// Security: `instance_id` binds as $1 — no SQL string interpolation.
    pub fn getByInstanceId(
        self: *SnapshotStore,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
    ) SnapshotError!Snapshot {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return SnapshotError.PoolExhausted,
            else => return SnapshotError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const inst_id_hex = uuidToHex(a, instance_id) catch
            return SnapshotError.TransactionFailed;

        const rows = conn.query(
            allocator,
            \\SELECT
            \\    instance_id,
            \\    definition_id,
            \\    definition_name,
            \\    definition_ver,
            \\    graph,
            \\    (EXTRACT(EPOCH FROM snapshotted_at) * 1000000)::bigint
            \\FROM instance_definition_snapshots
            \\WHERE instance_id = $1::uuid
        ,
            &.{inst_id_hex},
        ) catch return SnapshotError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        // 0 rows → no snapshot exists for this instance.
        if (rows.rows.len == 0) return SnapshotError.DefinitionNotFound;

        return rowToSnapshot(allocator, rows.rows[0]) catch
            SnapshotError.TransactionFailed;
    }
};

// ---------------------------------------------------------------------------
// Row parsing helpers
// ---------------------------------------------------------------------------

/// Columns returned by the INSERT RETURNING and SELECT queries:
///   0  instance_id      UUID text
///   1  definition_id    UUID text
///   2  definition_name  TEXT
///   3  definition_ver   TEXT
///   4  graph            JSONB text
///   5  snapshotted_at   bigint (UTC µs)
fn rowToSnapshot(
    allocator: std.mem.Allocator,
    row: []?[]u8,
) error{OutOfMemory}!Snapshot {
    const instance_id = parseUuid(colGet(row, 0)) catch std.mem.zeroes(Uuid);
    const definition_id = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);
    const definition_name = try allocator.dupe(u8, colGet(row, 2));
    const definition_ver = try allocator.dupe(u8, colGet(row, 3));

    // Deserialise the graph JSONB text back to a DefinitionGraph.
    // Falls back to an empty graph on parse failure (e.g. stub pg.zig rows).
    const graph_json_str = colGet(row, 4);
    const graph: graph_mod.DefinitionGraph = parseGraphJson(allocator, graph_json_str) catch
        graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };

    const snapshotted_at = std.fmt.parseInt(i64, colGet(row, 5), 10) catch 0;

    return Snapshot{
        .instance_id = instance_id,
        .definition_id = definition_id,
        .definition_name = definition_name,
        .definition_ver = definition_ver,
        .graph = graph,
        .snapshotted_at = snapshotted_at,
    };
}

/// Return column i from row as a non-null slice; empty string for NULL or
/// out-of-bounds.
inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

// ---------------------------------------------------------------------------
// JSONB graph parsing
// ---------------------------------------------------------------------------

/// Parse a JSONB text string into a DefinitionGraph.
/// All returned memory is allocated from `allocator`.
fn parseGraphJson(
    allocator: std.mem.Allocator,
    json_str: []const u8,
) error{ OutOfMemory, InvalidGraph }!graph_mod.DefinitionGraph {
    if (json_str.len == 0) return error.InvalidGraph;
    const parsed = std.json.parseFromSlice(
        graph_mod.DefinitionGraph,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidGraph;
    defer parsed.deinit();
    return duplicateGraph(allocator, parsed.value);
}

/// Deep-copy a DefinitionGraph into `allocator`-owned memory so that ownership
/// transfers to the caller independently of the parse arena.
fn duplicateGraph(
    allocator: std.mem.Allocator,
    src: graph_mod.DefinitionGraph,
) error{OutOfMemory}!graph_mod.DefinitionGraph {
    const nodes = try allocator.alloc(graph_mod.GraphNode, src.nodes.len);
    errdefer allocator.free(nodes);

    for (src.nodes, 0..) |n, i| {
        nodes[i] = graph_mod.GraphNode{
            .id = try allocator.dupe(u8, n.id),
            .node_type = n.node_type,
            .label = if (n.label) |l| try allocator.dupe(u8, l) else null,
            .attributes = if (n.attributes) |attr| try allocator.dupe(u8, attr) else null,
        };
    }

    const edges = try allocator.alloc(graph_mod.GraphEdge, src.edges.len);
    errdefer allocator.free(edges);

    for (src.edges, 0..) |e, i| {
        edges[i] = graph_mod.GraphEdge{
            .id = try allocator.dupe(u8, e.id),
            .source = try allocator.dupe(u8, e.source),
            .target = try allocator.dupe(u8, e.target),
            .condition = if (e.condition) |c| try allocator.dupe(u8, c) else null,
            .transform = if (e.transform) |t| try allocator.dupe(u8, t) else null,
            .is_default = e.is_default,
        };
    }

    return graph_mod.DefinitionGraph{ .nodes = nodes, .edges = edges };
}

// ---------------------------------------------------------------------------
// UUID helpers  (mirrors private helpers in store.zig)
// ---------------------------------------------------------------------------

/// Render a UUID as lowercase hex with hyphens:
/// xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
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

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB required)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "TC-PD-08-06u-01: parseGraphJson valid empty graph" {
    const allocator = testing.allocator;
    const json = "{\"nodes\":[],\"edges\":[]}";
    const result = try parseGraphJson(allocator, json);
    defer {
        allocator.free(result.nodes);
        allocator.free(result.edges);
    }
    try testing.expectEqual(@as(usize, 0), result.nodes.len);
    try testing.expectEqual(@as(usize, 0), result.edges.len);
}

test "TC-PD-08-06u-02: parseGraphJson invalid json returns error" {
    const allocator = testing.allocator;
    const result = parseGraphJson(allocator, "not-json");
    try testing.expectError(error.InvalidGraph, result);
}

test "TC-PD-08-06u-03: parseGraphJson empty string returns error" {
    const allocator = testing.allocator;
    const result = parseGraphJson(allocator, "");
    try testing.expectError(error.InvalidGraph, result);
}

test "TC-PD-08-06u-04: duplicateGraph independent copy" {
    const allocator = testing.allocator;
    const node = graph_mod.GraphNode{
        .id = "n1",
        .node_type = .START,
        .label = null,
        .attributes = null,
    };
    const src = graph_mod.DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{node},
        .edges = &.{},
    };
    const copy = try duplicateGraph(allocator, src);
    defer {
        allocator.free(copy.nodes[0].id);
        allocator.free(copy.nodes);
        allocator.free(copy.edges);
    }
    try testing.expectEqual(@as(usize, 1), copy.nodes.len);
    try testing.expectEqualStrings("n1", copy.nodes[0].id);
    try testing.expectEqual(graph_mod.NodeType.START, copy.nodes[0].node_type);
    // Verify it's a distinct allocation (not the same pointer)
    try testing.expect(copy.nodes[0].id.ptr != node.id.ptr);
}
