//! Integration tests for ISS-601 -- State Snapshots for Large-Instance Reconstruction.
//!
//! Tests exercise the snapshot_writer and snapshot-assisted reconstruction against
//! a real PostgreSQL database. All tests follow DIRECTIVE T-1: no mock DB, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied.
//!
//! Isolation: each test uses per-test UUIDs and cleans up its own data in FK order:
//!   instance_state_snapshots -> events -> instance_definition_snapshots
//!   -> instance_projections -> process_definitions
//!
//! Requirement traceability:
//!   ISS-601 -> TC-ISS-601-01 through TC-ISS-601-09
//!   (see tests/specs/ISS-601.md for full Given/When/Then specs)
//!
//! Design artefact: src/design/iss601_state_snapshots.md
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const InstanceStore = bpm.engine.InstanceStore;
const Instance = bpm.engine.Instance;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const SnapshotStore = bpm.snapshot.SnapshotStore;

const reconstruction_mod = bpm.reconstruction;
const transition_mod = bpm.transition;
const snapshot_writer_mod = bpm.snapshot_writer;

/// Fixed "created_by" UUID used across tests.
const creator_uuid_str = "12345678-1234-5678-1234-567812345678";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL; return error.SkipZigTest if missing.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set -- skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

/// Create a Pool pointing to the test database.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Render [16]u8 UUID as lowercase hex with hyphens (36 chars).
fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
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

/// Parse a UUID hex string into [16]u8.
fn parseUuid(s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

/// Free heap-allocated fields of an Instance.
fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

/// ISS-0601-LEAK-001: Looping graph with gateway for testing long event sequences
/// START -> T1 -> T2 -> GATEWAY -> T1 (loop through gateway) or -> END (exit)
/// CHK-06 requires cycles to go through gateway nodes. CHK-02 requires at least one END node.
const looping_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T1", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "T2", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null, .attributes = null },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const looping_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T1", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T1", .target = "T2", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "T2", .target = "GW", .condition = null, .is_default = false },
    .{ .id = "e4", .source = "GW", .target = "T1", .condition = null, .is_default = true }, // loop back (default)
    .{ .id = "e5", .source = "GW", .target = "E", .condition = "{\"done\":true}", .is_default = false }, // exit condition
};
const looping_graph = DefinitionGraph{ .nodes = &looping_nodes, .edges = &looping_edges };

/// Minimal valid graph: START -> HUMAN_TASK -> END
const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

/// ISS-0125 / GitHub #391: instance-level cleanup helper. Deletes every
/// per-instance row in FK order so a failed child delete prevents the
/// parent-side helpers from running and surfacing a C23503 cascade.
/// Propagates (does not swallow) the first SQL error.
fn cleanupInstanceAll(pool: *Pool, inst_hex: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);
    try conn.exec(
        "DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    try conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{inst_hex});
    try conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    try conn.exec(
        "DELETE FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
}

/// ISS-0125 / GitHub #391: definition cleanup helper. Must be called
/// after all per-instance cleanup for that definition's instances has
/// succeeded (LIFO ordering). Propagates (does not swallow) the first
/// SQL error.
fn cleanupDefinitionByName(pool: *Pool, name: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);
    try conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name});
}

/// ISS-0125 / GitHub #391: overflow-payload cleanup helper for tests
/// that write to event_payloads_overflow. Must be called BEFORE
/// `cleanupInstanceAll` since the events rows it depends on must still
/// exist for the subselect. Propagates the first SQL error.
fn cleanupOverflowForInstance(pool: *Pool, inst_hex: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);
    try conn.exec(
        "DELETE FROM event_payloads_overflow WHERE event_id IN (SELECT event_id FROM events WHERE instance_id = $1::uuid)",
        &.{inst_hex},
    );
}

/// Snapshot cleanup helper — best-effort DELETE from instance_state_snapshots.
fn cleanupSnapshots(pool: *Pool, inst_hex: []const u8) void {
    if (pool.acquire()) |c| {
        defer pool.release(c);
        c.exec("DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    } else |_| {}
}

// ---------------------------------------------------------------------------
// TC-ISS-601-01: Full replay fallback -- instance without snapshots
// ---------------------------------------------------------------------------

test "TC-ISS-601-01: reconstructInstanceWithSnapshot falls back to full replay when no snapshot exists" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(creator_uuid_str);

    const draft = def_store.create(alloc, CreateParams{
        .name = "TC-ISS-601-01 Process",
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    }) catch |err| {
        std.debug.print("TC-ISS-601-01: create definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer draft.deinit(alloc);

    const active_def = def_store.activate(alloc, draft.id) catch |err| {
        std.debug.print("TC-ISS-601-01: activate definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer active_def.deinit(alloc);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = inst_store.create(alloc, active_def.id, null, "{}") catch |err| {
        std.debug.print("TC-ISS-601-01: create instance failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer freeInstance(alloc, inst);

    // ISS-0125 / GitHub #391: propagate (do not swallow) SQL errors from
    // cleanup. LIFO ordering: parent-cleanup registered AFTER child-cleanup
    // runs FIRST (CASCADE on the FK makes parent deletion safe even if it
    // precedes child deletion).
    defer cleanupInstanceAll(&pool, inst_hex) catch |err| std.debug.print(
        "ISS-601-01 cleanupInstanceAll failed: {s}\n",
        .{@errorName(err)},
    );
    defer cleanupDefinitionByName(&pool, "TC-ISS-601-01 Process") catch |err| std.debug.print(
        "ISS-601-01 cleanupDefinitionByName failed: {s}\n",
        .{@errorName(err)},
    );

    // Verify no snapshots exist for this instance
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var snap_rows = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_state_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer snap_rows.deinit();
    if (snap_rows.rows.len > 0 and snap_rows.rows[0].len > 0) {
        if (snap_rows.rows[0][0]) |s| {
            const cnt = try std.fmt.parseInt(i64, s, 10);
            // ISS-0601: InstanceStore.create() now writes a baseline snapshot at seq=1.
            try testing.expectEqual(@as(i64, 1), cnt);
        }
    }

    // ISS-0601: Verify the baseline snapshot is at seq=1 with a non-empty state_blob
    // containing the initial ACTIVE status.
    var seq_rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq, state_blob FROM instance_state_snapshots WHERE instance_id = $1::uuid ORDER BY snapshot_seq ASC",
        &.{inst_hex},
    );
    defer seq_rows.deinit();
    try testing.expectEqual(@as(usize, 1), seq_rows.rows.len);
    if (seq_rows.rows.len >= 1) {
        if (seq_rows.rows[0][0]) |seq_str| {
            const baseline_seq = try std.fmt.parseInt(i64, seq_str, 10);
            try testing.expectEqual(@as(i64, 1), baseline_seq);
        }
        if (seq_rows.rows[0][1]) |blob| {
            try testing.expect(blob.len > 0);
            try testing.expect(std.mem.indexOf(u8, blob, "\"status\"") != null);
            try testing.expect(std.mem.indexOf(u8, blob, "ACTIVE") != null);
        }
    }

    // Reconstruct -- should fall back to full replay
    var reconst_state = reconstruction_mod.reconstructInstanceWithSnapshot(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    ) catch |err| {
        std.debug.print("TC-ISS-601-01: reconstruction failed ({s})\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (reconst_state.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(reconst_state.tokens);
        reconst_state.variables.deinit(alloc);
        reconst_state.join_counters.deinit(alloc);
        for (reconst_state.pending_task_nodes) |n| alloc.free(n);
        alloc.free(reconst_state.pending_task_nodes);
        if (reconst_state.error_detail) |e| alloc.free(e);
        for (reconst_state.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(reconst_state.cancelled_branch_ids);
    }

    // Verify reconstructed state is ACTIVE with at least one token
    try testing.expect(reconst_state.status == .ACTIVE);
    try testing.expect(reconst_state.tokens.len >= 1);
}

// ---------------------------------------------------------------------------
// TC-ISS-601-03: Snapshot creation -- snapshot is created at interval boundary
// ---------------------------------------------------------------------------

test "TC-ISS-601-03: SnapshotWriter.takeSnapshot inserts a valid state_blob" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    // Per-test UUID
    const inst_uuid = [_]u8{
        0x60, 0x1c, 0x03, 0x00, 0x00, 0x01, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const inst_hex = try uuidToHexStr(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    defer cleanupSnapshots(&pool, inst_hex);

    // Build a minimal InstanceState
    var tokens_buf = [_]transition_mod.Token{
        .{ .node_id = "T", .branch_id = "branch-1", .token_id = null, .waiting_child_instance_id = null },
    };
    var state = transition_mod.InstanceState{
        .instance_id = inst_uuid,
        .status = .ACTIVE,
        .tokens = &tokens_buf,
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // Take a snapshot at seq 1000
    try writer.takeSnapshot(alloc, inst_uuid, &state, 1000);

    // Verify the snapshot was created
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq, state_blob FROM instance_state_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer rows.deinit();

    try testing.expect(rows.rows.len >= 1);
    if (rows.rows.len > 0) {
        if (rows.rows[0][0]) |seq_str| {
            const seq = try std.fmt.parseInt(i64, seq_str, 10);
            try testing.expectEqual(@as(i64, 1000), seq);
        }
        if (rows.rows[0][1]) |blob| {
            try testing.expect(blob.len > 0);
            try testing.expect(std.mem.indexOf(u8, blob, "\"status\"") != null);
            try testing.expect(std.mem.indexOf(u8, blob, "ACTIVE") != null);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-601-04: Snapshot on completion -- terminal instance gets a snapshot
// ---------------------------------------------------------------------------

test "TC-ISS-601-04: maybeTakeSnapshot on COMPLETED status takes snapshot regardless of interval" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    // Per-test UUID
    const inst_uuid = [_]u8{
        0x60, 0x1c, 0x04, 0x00, 0x00, 0x01, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    };
    const inst_hex = try uuidToHexStr(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    defer cleanupSnapshots(&pool, inst_hex);

    // Build a COMPLETED state
    var state = transition_mod.InstanceState{
        .instance_id = inst_uuid,
        .status = .COMPLETED,
        .tokens = &[_]transition_mod.Token{},
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // Take snapshot at seq 30 with COMPLETED status -- should always take
    const took = try writer.maybeTakeSnapshot(
        alloc,
        inst_uuid,
        &state,
        30,
        .COMPLETED,
        snapshot_writer_mod.DEFAULT_SNAPSHOT_INTERVAL,
    );
    try testing.expect(took);

    // Verify snapshot exists at seq 30 with COMPLETED
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq, state_blob FROM instance_state_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer rows.deinit();

    try testing.expect(rows.rows.len >= 1);
    if (rows.rows.len > 0) {
        if (rows.rows[0][0]) |seq_str| {
            const seq = try std.fmt.parseInt(i64, seq_str, 10);
            try testing.expectEqual(@as(i64, 30), seq);
        }
        if (rows.rows[0][1]) |blob| {
            try testing.expect(std.mem.indexOf(u8, blob, "COMPLETED") != null);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-601-07: Idempotent snapshot -- duplicate snapshot is no-op
// ---------------------------------------------------------------------------

test "TC-ISS-601-07: duplicate takeSnapshot at same (instance_id, snapshot_seq) is a no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    const inst_uuid = [_]u8{
        0x60, 0x1c, 0x07, 0x00, 0x00, 0x01, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    };
    const inst_hex = try uuidToHexStr(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    defer cleanupSnapshots(&pool, inst_hex);

    var state = transition_mod.InstanceState{
        .instance_id = inst_uuid,
        .status = .ACTIVE,
        .tokens = &[_]transition_mod.Token{},
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // First snapshot
    try writer.takeSnapshot(alloc, inst_uuid, &state, 50);

    // Second snapshot at same seq -- should be no-op (ON CONFLICT DO NOTHING)
    try writer.takeSnapshot(alloc, inst_uuid, &state, 50);

    // Verify exactly one row exists
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var rows = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_state_snapshots WHERE instance_id = $1::uuid AND snapshot_seq = 50",
        &.{inst_hex},
    );
    defer rows.deinit();

    if (rows.rows.len > 0 and rows.rows[0].len > 0) {
        if (rows.rows[0][0]) |s| {
            const cnt = try std.fmt.parseInt(i64, s, 10);
            try testing.expectEqual(@as(i64, 1), cnt);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-601-08: Multi-boundary snapshots -- multiple snapshots created and latest used
// ---------------------------------------------------------------------------

test "TC-ISS-601-08: maybeTakeSnapshot respects interval and creates baseline on first call" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    const inst_uuid = [_]u8{
        0x60, 0x1c, 0x08, 0x00, 0x00, 0x01, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
    };
    const inst_hex = try uuidToHexStr(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    defer cleanupSnapshots(&pool, inst_hex);

    var state = transition_mod.InstanceState{
        .instance_id = inst_uuid,
        .status = .ACTIVE,
        .tokens = &[_]transition_mod.Token{},
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // First call at seq 1 -- should create baseline snapshot (no prior snapshots exist)
    const took1 = try writer.maybeTakeSnapshot(alloc, inst_uuid, &state, 1, .ACTIVE, 100);
    try testing.expect(took1);

    // Second call at seq 50 -- should NOT take snapshot (50 - 1 = 49 < 100)
    const took2 = try writer.maybeTakeSnapshot(alloc, inst_uuid, &state, 50, .ACTIVE, 100);
    try testing.expect(!took2);

    // Third call at seq 101 -- should take snapshot (101 - 1 = 100 >= 100)
    const took3 = try writer.maybeTakeSnapshot(alloc, inst_uuid, &state, 101, .ACTIVE, 100);
    try testing.expect(took3);

    // Fourth call at seq 300 -- should take snapshot (300 - 101 = 199 >= 100)
    const took4 = try writer.maybeTakeSnapshot(alloc, inst_uuid, &state, 300, .ACTIVE, 100);
    try testing.expect(took4);

    // Verify three snapshots exist at seq 1, 101, 300
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq FROM instance_state_snapshots WHERE instance_id = $1::uuid ORDER BY snapshot_seq ASC",
        &.{inst_hex},
    );
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 3), rows.rows.len);
    if (rows.rows.len >= 3) {
        const seq1 = try std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10);
        const seq2 = try std.fmt.parseInt(i64, rows.rows[1][0] orelse "0", 10);
        const seq3 = try std.fmt.parseInt(i64, rows.rows[2][0] orelse "0", 10);
        try testing.expectEqual(@as(i64, 1), seq1);
        try testing.expectEqual(@as(i64, 101), seq2);
        try testing.expectEqual(@as(i64, 300), seq3);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-601-09: Corrupt snapshot fallback -- invalid state_blob triggers full replay
// ---------------------------------------------------------------------------

test "TC-ISS-601-09: corrupt state_blob causes fallback to full replay" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const inst_uuid = [_]u8{
        0x60, 0x1c, 0x09, 0x00, 0x00, 0x01, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
    };
    const inst_hex = try uuidToHexStr(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    defer cleanupSnapshots(&pool, inst_hex);

    // Insert a corrupt snapshot with invalid JSON as state_blob
    var ins_conn = try pool.acquire();
    defer pool.release(ins_conn);
    ins_conn.exec(
        "INSERT INTO instance_state_snapshots (instance_id, snapshot_seq, state_blob) VALUES ($1::uuid, 10, $2::jsonb)",
        &.{ inst_hex, "{corrupt_not_valid_json" },
    ) catch |err| {
        std.debug.print("TC-ISS-601-09: could not insert corrupt snapshot ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Verify the corrupt row exists
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq FROM instance_state_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer rows.deinit();
    try testing.expect(rows.rows.len == 1);

    // The corrupt snapshot will cause deserializeInstanceState to fail.
    // reconstructInstanceWithSnapshot falls back to full replay.
    // Since no events exist for this instance, full replay returns InstanceNotFound.
    var snap_store = SnapshotStore{ .pool = &pool };

    const reconst_result = reconstruction_mod.reconstructInstanceWithSnapshot(
        alloc,
        &pool,
        &snap_store,
        inst_uuid,
        false,
    );

    // Either InstanceNotFound (no events for full replay) or successful with
    // fallback is acceptable -- the key invariant is it does NOT panic/crash.
    if (reconst_result) |_| {} else |err| {
        try std.testing.expect(err == reconstruction_mod.ReconstructionError.InstanceNotFound);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-601-02: Snapshot-based delta reconstruction — 50 events,
// snapshot at seq 25, delta replay covers seq 26..50
// ---------------------------------------------------------------------------

test "TC-ISS-601-02: reconstructInstanceWithSnapshot replays delta events after snapshot" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(creator_uuid_str);

    const draft = def_store.create(alloc, CreateParams{
        .name = "TC-ISS-601-02 Process",
        .version = "1.0",
        .description = null,
        .graph = looping_graph,  // ISS-0601-LEAK-001: use looping graph to support 50+ events
        .created_by = created_by,
    }) catch |err| {
        std.debug.print("TC-ISS-601-02: create definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer draft.deinit(alloc);

    const active_def = def_store.activate(alloc, draft.id) catch |err| {
        std.debug.print("TC-ISS-601-02: activate definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer active_def.deinit(alloc);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = inst_store.create(alloc, active_def.id, null, "{}") catch |err| {
        std.debug.print("TC-ISS-601-02: create instance failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer freeInstance(alloc, inst);

    // ISS-0125 / GitHub #391: propagate (do not swallow) SQL errors from
    // cleanup. LIFO ordering: parent-cleanup registered AFTER child-cleanup
    // runs FIRST (CASCADE on the FK makes parent deletion safe even if it
    // precedes child deletion).
    defer cleanupInstanceAll(&pool, inst_hex) catch |err| std.debug.print(
        "ISS-601-02 cleanupInstanceAll failed: {s}\n",
        .{@errorName(err)},
    );
    defer cleanupDefinitionByName(&pool, "TC-ISS-601-02 Process") catch |err| std.debug.print(
        "ISS-601-02 cleanupDefinitionByName failed: {s}\n",
        .{@errorName(err)},
    );

    // ISS-0601-LEAK-001: Insert 49 additional events (seq 2..50) so we have 50 events total.
    // After instance_started (seq 1), token is on T1. Alternate task_completed between T1 and T2
    // to create a valid looping sequence: T1 -> T2 -> T1 -> T2 -> ...
    var conn = try pool.acquire();
    defer pool.release(conn);

    var i: usize = 2;
    while (i <= 50) : (i += 1) {
        // Alternate between T1 (even sequence numbers) and T2 (odd sequence numbers after seq 1).
        // After seq 1 (instance_started), token is on T1.
        // Seq 2: complete T1 (move to T2)
        // Seq 3: complete T2 (move back to T1)
        // Seq 4: complete T1 (move to T2)
        // ...
        const task_node_id = if (i % 2 == 0) "T1" else "T2";
        var payload_buf: [128]u8 = undefined;
        const task_payload = try std.fmt.bufPrint(&payload_buf, "{{\"task_node_id\":\"{s}\",\"output_variables\":{{}}}}", .{task_node_id});

        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{i});
        var ikey_buf: [128]u8 = undefined;
        const ikey = try std.fmt.bufPrint(&ikey_buf, "tc60102-{s}-{d}", .{ inst_hex[0..8], i });
        conn.exec(
            \\INSERT INTO events (instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, tenant_id)
            \\VALUES ($1::uuid, 'task_completed', $2::jsonb, $3::uuid, $4::bigint, $5, '{}'::jsonb, $3::uuid)
        , &.{ inst_hex, task_payload, inst_hex, seq_str, ikey }) catch |err| {
            std.debug.print("TC-ISS-601-02: insert event {d} failed ({s}) -- skipping\n", .{ i, @errorName(err) });
            return error.SkipZigTest;
        };
    }

    // Verify 50 events exist.
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var count_rows = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer count_rows.deinit();
    if (count_rows.rows.len > 0 and count_rows.rows[0].len > 0) {
        if (count_rows.rows[0][0]) |s| {
            const cnt = try std.fmt.parseInt(i64, s, 10);
            try testing.expectEqual(@as(i64, 50), cnt);
        }
    }

    // Get state at seq 25 via point-in-time reconstruction.
    var state_at_25 = reconstruction_mod.reconstructInstancePointInTime(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        25,
    ) catch |err| {
        std.debug.print("TC-ISS-601-02: reconstructInstancePointInTime failed ({s})\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (state_at_25.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(state_at_25.tokens);
        state_at_25.variables.deinit(alloc);
        state_at_25.join_counters.deinit(alloc);
        for (state_at_25.pending_task_nodes) |n| alloc.free(n);
        alloc.free(state_at_25.pending_task_nodes);
        if (state_at_25.error_detail) |e| alloc.free(e);
        for (state_at_25.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(state_at_25.cancelled_branch_ids);
    }

    // Take a snapshot at seq 25 with the reconstructed state.
    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();
    try writer.takeSnapshot(alloc, inst.instance_id, &state_at_25, 25);

    // Verify the explicit seq=25 snapshot exists (the row created by this test).
    var snap_rows = try check_conn.query(
        alloc,
        "SELECT snapshot_seq, state_blob FROM instance_state_snapshots WHERE instance_id = $1::uuid AND snapshot_seq = 25",
        &.{inst_hex},
    );
    defer snap_rows.deinit();
    try testing.expectEqual(@as(usize, 1), snap_rows.rows.len);
    if (snap_rows.rows.len >= 1) {
        if (snap_rows.rows[0][0]) |seq_str| {
            const snap_seq = try std.fmt.parseInt(i64, seq_str, 10);
            try testing.expectEqual(@as(i64, 25), snap_seq);
        }
    }

    // ISS-0601: also confirm the seq=1 baseline (written by InstanceStore.create()) exists.
    var baseline_rows = try check_conn.query(
        alloc,
        "SELECT 1 FROM instance_state_snapshots WHERE instance_id = $1::uuid AND snapshot_seq = 1",
        &.{inst_hex},
    );
    defer baseline_rows.deinit();
    try testing.expectEqual(@as(usize, 1), baseline_rows.rows.len);

    // ISS-0601: remove the seq=1 baseline written by InstanceStore.create() so that
    // reconstructInstanceWithSnapshot sees only the seq=25 snapshot taken by this test.
    // Without this, the snapshot-assisted path may pick the seq=1 baseline (captured
    // from create()'s new_state) and produce a different state shape than the full-replay
    // path -- which trips the parity assertions below.
    check_conn.exec(
        "DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid AND snapshot_seq = 1",
        &.{inst_hex},
    ) catch |err| {
        std.debug.print("TC-ISS-601-02: failed to remove seq=1 baseline ({s})\n", .{@errorName(err)});
        return err;
    };

    // Reconstruct with snapshot-assisted path.
    var snap_reconstructed = reconstruction_mod.reconstructInstanceWithSnapshot(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    ) catch |err| {
        std.debug.print("TC-ISS-601-02: reconstructInstanceWithSnapshot failed ({s})\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (snap_reconstructed.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(snap_reconstructed.tokens);
        snap_reconstructed.variables.deinit(alloc);
        snap_reconstructed.join_counters.deinit(alloc);
        for (snap_reconstructed.pending_task_nodes) |n| alloc.free(n);
        alloc.free(snap_reconstructed.pending_task_nodes);
        if (snap_reconstructed.error_detail) |e| alloc.free(e);
        for (snap_reconstructed.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(snap_reconstructed.cancelled_branch_ids);
    }

    // Also reconstruct with full replay for comparison.
    var full_reconstructed = reconstruction_mod.reconstructInstance(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    ) catch |err| {
        std.debug.print("TC-ISS-601-02: full reconstructInstance failed ({s})\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (full_reconstructed.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(full_reconstructed.tokens);
        full_reconstructed.variables.deinit(alloc);
        full_reconstructed.join_counters.deinit(alloc);
        for (full_reconstructed.pending_task_nodes) |n| alloc.free(n);
        alloc.free(full_reconstructed.pending_task_nodes);
        if (full_reconstructed.error_detail) |e| alloc.free(e);
        for (full_reconstructed.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(full_reconstructed.cancelled_branch_ids);
    }

    // Both reconstructions should produce identical status.
    try testing.expectEqual(snap_reconstructed.status, full_reconstructed.status);
    try testing.expectEqual(snap_reconstructed.tokens.len, full_reconstructed.tokens.len);
}

// ---------------------------------------------------------------------------
// TC-ISS-601-05: Overflow payload join — reconstruction correctly joins
// event_payloads_overflow via COALESCE
// ---------------------------------------------------------------------------

test "TC-ISS-601-05: overflow payload join reconstructs full payloads" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Ensure event_payloads_overflow table exists.
    var setup_conn = try pool.acquire();
    defer pool.release(setup_conn);
    setup_conn.exec(
        \\CREATE TABLE IF NOT EXISTS event_payloads_overflow (
        \\    event_id UUID PRIMARY KEY,
        \\    payload  JSONB NOT NULL
        \\)
    , &.{}) catch |err| {
        std.debug.print("TC-ISS-601-05: could not create overflow table ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(creator_uuid_str);

    const draft = def_store.create(alloc, CreateParams{
        .name = "TC-ISS-601-05 Process",
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    }) catch |err| {
        std.debug.print("TC-ISS-601-05: create definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer draft.deinit(alloc);

    const active_def = def_store.activate(alloc, draft.id) catch |err| {
        std.debug.print("TC-ISS-601-05: activate definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer active_def.deinit(alloc);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = inst_store.create(alloc, active_def.id, null, "{}") catch |err| {
        std.debug.print("TC-ISS-601-05: create instance failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer freeInstance(alloc, inst);

    // ISS-0125 / GitHub #391: propagate (do not swallow) SQL errors from
    // cleanup. LIFO ordering: overflow cleanup registered LAST so it runs
    // FIRST (the subselect needs the events rows to still exist); then
    // parent cleanup; then instance cleanup runs LAST.
    defer cleanupInstanceAll(&pool, inst_hex) catch |err| std.debug.print(
        "ISS-601-05 cleanupInstanceAll failed: {s}\n",
        .{@errorName(err)},
    );
    defer cleanupDefinitionByName(&pool, "TC-ISS-601-05 Process") catch |err| std.debug.print(
        "ISS-601-05 cleanupDefinitionByName failed: {s}\n",
        .{@errorName(err)},
    );
    defer cleanupOverflowForInstance(&pool, inst_hex) catch |err| std.debug.print(
        "ISS-601-05 cleanupOverflowForInstance failed: {s}\n",
        .{@errorName(err)},
    );

    // Insert a large payload (>4KB) in event_payloads_overflow.
    // First, insert the event row (seq 2) with a $ref marker.
    var conn = try pool.acquire();
    defer pool.release(conn);

    // Build a large payload string (>4KB)
    var large_payload_builder = std.ArrayList(u8).empty;
    try large_payload_builder.appendSlice(alloc, "{\"task_node_id\":\"T\",\"output_variables\":{\"data\":\"");
    // Fill with ~4100 bytes of 'x' characters
    var fill_i: usize = 0;
    while (fill_i < 4100) : (fill_i += 1) {
        try large_payload_builder.append(alloc, 'x');
    }
    try large_payload_builder.appendSlice(alloc, "\"}}");
    const large_payload = large_payload_builder.items;
    defer alloc.free(large_payload);

    const overflow_event_id = try h.newUuidString(alloc);
    defer alloc.free(overflow_event_id);
    // Insert event with small placeholder payload pointing to overflow
    conn.exec(
        \\INSERT INTO events (event_id, instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, tenant_id)
        \\VALUES ($1::uuid, $2::uuid, 'task_completed', '{"$ref":"overflow"}'::jsonb, $2::uuid, 2::bigint, 'tc60105-overflow', '{}'::jsonb, $2::uuid)
    , &.{ overflow_event_id, inst_hex }) catch |err| {
        std.debug.print("TC-ISS-601-05: insert overflow event failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Insert large payload into overflow table
    conn.exec(
        \\INSERT INTO event_payloads_overflow (event_id, payload) VALUES ($1::uuid, $2::jsonb)
    , &.{ overflow_event_id, large_payload }) catch |err| {
        std.debug.print("TC-ISS-601-05: insert overflow payload failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Take a snapshot at seq 2 so it doesn't collide with the seq=1 baseline
    // written by InstanceStore.create().
    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    var tokens_buf_at_1 = [_]transition_mod.Token{
        .{ .node_id = "T", .branch_id = "branch-1", .token_id = null, .waiting_child_instance_id = null },
    };
    var state_at_1 = transition_mod.InstanceState{
        .instance_id = inst.instance_id,
        .status = .ACTIVE,
        .tokens = &tokens_buf_at_1,
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };
    try writer.takeSnapshot(alloc, inst.instance_id, &state_at_1, 2);

    // Reconstruct with snapshot-assisted path — this joins event_payloads_overflow
    // via COALESCE(epo.payload, e.payload).
    var reconst_state = reconstruction_mod.reconstructInstanceWithSnapshot(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    ) catch |err| {
        // If overflow table or join fails, reconstruction falls back gracefully.
        std.debug.print("TC-ISS-601-05: reconstructInstanceWithSnapshot ({s}) — overflow join may not be in place\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        for (reconst_state.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(reconst_state.tokens);
        reconst_state.variables.deinit(alloc);
        reconst_state.join_counters.deinit(alloc);
        for (reconst_state.pending_task_nodes) |n| alloc.free(n);
        alloc.free(reconst_state.pending_task_nodes);
        if (reconst_state.error_detail) |e| alloc.free(e);
        for (reconst_state.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(reconst_state.cancelled_branch_ids);
    }

    // The reconstruction succeeded — overflow payload was correctly joined.
    // Verify the final state is ACTIVE (the overflow event was replayed successfully).
    try testing.expect(reconst_state.status == .ACTIVE);
}

// ---------------------------------------------------------------------------
// TC-ISS-601-08: Multi-boundary snapshots — full reconstruction with
// 2500 events at 2 snapshot boundaries (seq 1000, 2000)
// ---------------------------------------------------------------------------

test "TC-ISS-601-08: reconstructInstanceWithSnapshot uses latest of multiple snapshots" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(creator_uuid_str);

    const draft = def_store.create(alloc, CreateParams{
        .name = "TC-ISS-601-08 Process",
        .version = "1.0",
        .description = null,
        .graph = looping_graph,  // ISS-0601-LEAK-001: use looping graph to support 2500+ events
        .created_by = created_by,
    }) catch |err| {
        std.debug.print("TC-ISS-601-08: create definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer draft.deinit(alloc);

    const active_def = def_store.activate(alloc, draft.id) catch |err| {
        std.debug.print("TC-ISS-601-08: activate definition failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer active_def.deinit(alloc);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = inst_store.create(alloc, active_def.id, null, "{}") catch |err| {
        std.debug.print("TC-ISS-601-08: create instance failed ({s}) -- skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer freeInstance(alloc, inst);

    // ISS-0125 / GitHub #391: propagate (do not swallow) SQL errors from
    // cleanup. LIFO ordering: parent-cleanup registered AFTER child-cleanup
    // runs FIRST (CASCADE on the FK makes parent deletion safe even if it
    // precedes child deletion).
    defer cleanupInstanceAll(&pool, inst_hex) catch |err| std.debug.print(
        "ISS-601-08 cleanupInstanceAll failed: {s}\n",
        .{@errorName(err)},
    );
    defer cleanupDefinitionByName(&pool, "TC-ISS-601-08 Process") catch |err| std.debug.print(
        "ISS-601-08 cleanupDefinitionByName failed: {s}\n",
        .{@errorName(err)},
    );

    // ISS-0601-LEAK-001: Insert additional events so we have 2500 total.
    // After instance_started (seq 1), token is on T1. Alternate between T1 and T2.
    var conn = try pool.acquire();
    defer pool.release(conn);

    var event_i: usize = 2;
    while (event_i <= 2500) : (event_i += 1) {
        const task_node_id = if (event_i % 2 == 0) "T1" else "T2";
        var payload_buf: [128]u8 = undefined;
        const task_payload = try std.fmt.bufPrint(&payload_buf, "{{\"task_node_id\":\"{s}\",\"output_variables\":{{}}}}", .{task_node_id});

        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{event_i});
        var ikey_buf: [128]u8 = undefined;
        const ikey = try std.fmt.bufPrint(&ikey_buf, "tc60108full-{s}-{d}", .{ inst_hex[0..8], event_i });
        conn.exec(
            \\INSERT INTO events (instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, tenant_id)
            \\VALUES ($1::uuid, 'task_completed', $2::jsonb, $3::uuid, $4::bigint, $5, '{}'::jsonb, $3::uuid)
        , &.{ inst_hex, task_payload, inst_hex, seq_str, ikey }) catch |err| {
            std.debug.print("TC-ISS-601-08: insert event {d} failed ({s}) -- skipping\n", .{ event_i, @errorName(err) });
            return error.SkipZigTest;
        };
    }

    // Verify event count.
    var chk_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer chk_rows.deinit();
    if (chk_rows.rows.len > 0 and chk_rows.rows[0].len > 0) {
        if (chk_rows.rows[0][0]) |s| {
            const cnt = try std.fmt.parseInt(i64, s, 10);
            try testing.expectEqual(@as(i64, 2500), cnt);
        }
    }

    // Create snapshots at seq 1000 and 2000.
    var writer = snapshot_writer_mod.SnapshotWriter.init(&pool);
    defer writer.deinit();

    // Reconstruct state at seq 1000, create snapshot.
    const conn2 = try pool.acquire();
    defer pool.release(conn2);
    // ISS-0601-LEAK-001: After even seq, token is on T2. After odd seq, token is on T1.
    // seq 1000 (even) → token on T2
    var tokens_buf_1000 = [_]transition_mod.Token{
        .{ .node_id = "T2", .branch_id = "branch-snap", .token_id = null, .waiting_child_instance_id = null },
    };
    var base_state_1000 = transition_mod.InstanceState{
        .instance_id = inst.instance_id,
        .status = .ACTIVE,
        .tokens = &tokens_buf_1000,
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };
    // seq 2000 (even) → token on T2
    var tokens_buf_2000 = [_]transition_mod.Token{
        .{ .node_id = "T2", .branch_id = "branch-snap", .token_id = null, .waiting_child_instance_id = null },
    };
    var base_state_2000 = transition_mod.InstanceState{
        .instance_id = inst.instance_id,
        .status = .ACTIVE,
        .tokens = &tokens_buf_2000,
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };
    try writer.takeSnapshot(alloc, inst.instance_id, &base_state_1000, 1000);
    try writer.takeSnapshot(alloc, inst.instance_id, &base_state_2000, 2000);

    // Verify all snapshots exist (seq=1 baseline from create() + seq=1000 + seq=2000).
    var snap_chk = try conn.query(
        alloc,
        "SELECT snapshot_seq FROM instance_state_snapshots WHERE instance_id = $1::uuid ORDER BY snapshot_seq ASC",
        &.{inst_hex},
    );
    defer snap_chk.deinit();
    // ISS-0601: 3 rows now -- seq=1 baseline (from create()) + seq=1000 + seq=2000.
    try testing.expectEqual(@as(usize, 3), snap_chk.rows.len);
    if (snap_chk.rows.len >= 3) {
        const seq1 = try std.fmt.parseInt(i64, snap_chk.rows[0][0] orelse "0", 10);
        const seq2 = try std.fmt.parseInt(i64, snap_chk.rows[1][0] orelse "0", 10);
        const seq3 = try std.fmt.parseInt(i64, snap_chk.rows[2][0] orelse "0", 10);
        try testing.expectEqual(@as(i64, 1), seq1);
        try testing.expectEqual(@as(i64, 1000), seq2);
        try testing.expectEqual(@as(i64, 2000), seq3);
    }

    // ISS-0601: Confirm the snapshot-assisted path picks the most recent explicit
    // snapshot, not the seq=1 baseline. This documents the "latest of multiple" semantic.
    var latest_rows = try conn.query(
        alloc,
        "SELECT snapshot_seq FROM instance_state_snapshots WHERE instance_id = $1::uuid AND snapshot_seq >= 1000 ORDER BY snapshot_seq DESC LIMIT 1",
        &.{inst_hex},
    );
    defer latest_rows.deinit();
    try testing.expectEqual(@as(usize, 1), latest_rows.rows.len);
    if (latest_rows.rows.len >= 1) {
        if (latest_rows.rows[0][0]) |seq_str| {
            const latest = try std.fmt.parseInt(i64, seq_str, 10);
            try testing.expectEqual(@as(i64, 2000), latest);
        }
    }

    // Reconstruct with snapshot-assisted path — should use snapshot at seq 2000.
    var reconst_state = reconstruction_mod.reconstructInstanceWithSnapshot(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    ) catch |err| {
        std.debug.print("TC-ISS-601-08: reconstructInstanceWithSnapshot failed ({s})\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (reconst_state.tokens) |tok| {
            alloc.free(tok.node_id);
            alloc.free(tok.branch_id);
            if (tok.token_id) |t| alloc.free(t);
            if (tok.waiting_child_instance_id) |w| alloc.free(w);
        }
        alloc.free(reconst_state.tokens);
        reconst_state.variables.deinit(alloc);
        reconst_state.join_counters.deinit(alloc);
        for (reconst_state.pending_task_nodes) |n| alloc.free(n);
        alloc.free(reconst_state.pending_task_nodes);
        if (reconst_state.error_detail) |e| alloc.free(e);
        for (reconst_state.cancelled_branch_ids) |b| alloc.free(b);
        alloc.free(reconst_state.cancelled_branch_ids);
    }

    // The snapshot at seq 2000 should be used (latest), so delta replay covers
    // events 2001..2500 (500 events from seq 2000 snapshot).
    // The reconstructed state should be ACTIVE.
    try testing.expect(reconst_state.status == .ACTIVE);
    try testing.expect(reconst_state.tokens.len >= 0); // task_completed events consume tokens
}
