//! Integration tests for EE-08 — Instance Cancellation.
//!
//! Tests exercise InstanceStore.cancelInstance() against a real PostgreSQL
//! database. All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Isolation: each test cleans up its own rows explicitly in FK order
//!   tasks → instance_definition_snapshots → instance_projections → process_definitions
//! because InstanceStore.cancelInstance() commits its own transactions
//! independently from any TestHarness rollback transaction.
//!
//! Requirement traceability:
//!   EE-08 → TC-EE-08-01 through TC-EE-08-05
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const InstanceStatus = bpm.engine.InstanceStatus;
const CancelInstanceError = bpm.engine.CancelInstanceError;
const Instance = bpm.engine.Instance;

const TaskStore = bpm.tasks.TaskStore;

// ---------------------------------------------------------------------------
// Fixed test UUIDs and constants
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
/// actor_id placeholder used for cancel operations (real IDN-03 not yet in scope).
const actor_id_str = "00000000-0000-0000-0000-000000000001";
/// UUID guaranteed absent from any real test run.
const nonexistent_uuid_str = "00000000-0000-4000-8000-000000000000";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Test Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{
    .nodes = &minimal_nodes,
    .edges = &minimal_edges,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL; skip if missing.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
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

/// Parse a UUID hex string (36 chars with hyphens) into [16]u8.
fn parseUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
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

/// Free heap-allocated fields of a Definition.
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

/// Free heap-allocated fields of an Instance.
fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

/// Delete tasks, snapshots, and projection rows for one instance (FK order).
/// Best-effort — does not return an error on failure.
fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM tasks WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
    conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
    conn.exec(
        "DELETE FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
}

/// Delete all process_definitions rows with the given name. Best-effort.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

/// Query the status of an instance from instance_projections.
/// Returns the status string, owned by allocator.
fn queryInstanceStatus(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    const row = rows.rows[0];
    const status_col = if (row.len > 0) row[0] orelse "" else "";
    return allocator.dupe(u8, status_col);
}

/// Count PENDING tasks for an instance.
fn countPendingTasks(pool: *Pool, instance_id_hex: []const u8) !i64 {
    const alloc = std.testing.allocator;
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING'",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    const row = rows.rows[0];
    const val = if (row.len > 0) row[0] orelse "0" else "0";
    return std.fmt.parseInt(i64, val, 10) catch 0;
}

/// Count CANCELLED tasks for an instance.
fn countCancelledTasks(pool: *Pool, instance_id_hex: []const u8) !i64 {
    const alloc = std.testing.allocator;
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE instance_id = $1::uuid AND status = 'CANCELLED'",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    const row = rows.rows[0];
    const val = if (row.len > 0) row[0] orelse "0" else "0";
    return std.fmt.parseInt(i64, val, 10) catch 0;
}

/// Count INSTANCE_CANCELLED events for an instance.
fn countCancelEvents(pool: *Pool, instance_id_hex: []const u8) !i64 {
    const alloc = std.testing.allocator;
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'INSTANCE_CANCELLED'",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    const row = rows.rows[0];
    const val = if (row.len > 0) row[0] orelse "0" else "0";
    return std.fmt.parseInt(i64, val, 10) catch 0;
}

/// Query cancelled_at from instance_projections. Returns true if non-NULL.
fn instanceHasCancelledAt(pool: *Pool, instance_id_hex: []const u8) !bool {
    const alloc = std.testing.allocator;
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        alloc,
        "SELECT cancelled_at FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return false;
    const row = rows.rows[0];
    if (row.len == 0) return false;
    return row[0] != null; // NULL column → false; non-NULL → true
}

// ---------------------------------------------------------------------------
// TC-EE-08-01: Happy path — ACTIVE instance with a PENDING task cancels correctly
// ---------------------------------------------------------------------------

test "TC-EE-08-01: cancel ACTIVE instance sets status CANCELLED and cancels open tasks" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-08-01 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create and activate a definition.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);
    defer cleanupByName(&pool, name);

    // Start an instance.
    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Verify the instance is ACTIVE before cancel.
    const status_before = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status_before);
    try std.testing.expectEqualStrings("ACTIVE", status_before);

    // Cancel the instance.
    try inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);

    // Verify: status is now CANCELLED.
    const status_after = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status_after);
    try std.testing.expectEqualStrings("CANCELLED", status_after);

    // Verify: cancelled_at is set.
    const has_cancelled_at = try instanceHasCancelledAt(&pool, inst_hex);
    try std.testing.expect(has_cancelled_at);

    // Verify: INSTANCE_CANCELLED event appended.
    const cancel_event_count = try countCancelEvents(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 1), cancel_event_count);

    // Verify: no remaining PENDING tasks.
    const pending_count = try countPendingTasks(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), pending_count);
}

// ---------------------------------------------------------------------------
// TC-EE-08-02: HTTP 409 — already-CANCELLED instance returns InstanceAlreadyTerminated
// ---------------------------------------------------------------------------

test "TC-EE-08-02: cancel already-CANCELLED instance returns InstanceAlreadyTerminated" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-08-02 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // First cancel — must succeed.
    try inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);

    // Second cancel — must return InstanceAlreadyTerminated.
    const result = inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);
    try std.testing.expectError(CancelInstanceError.InstanceAlreadyTerminated, result);
}

// ---------------------------------------------------------------------------
// TC-EE-08-03: HTTP 404 — non-existent instance returns InstanceNotFound
// ---------------------------------------------------------------------------

test "TC-EE-08-03: cancel non-existent instance returns InstanceNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // A UUID that does not exist in instance_projections.
    const absent_id = try parseUuid(alloc, nonexistent_uuid_str);

    const result = inst_store.cancelInstance(alloc, &task_store, absent_id, actor_id_str);
    try std.testing.expectError(CancelInstanceError.InstanceNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-EE-08-04: Edge case — cancel with no open tasks still appends INSTANCE_CANCELLED event
// ---------------------------------------------------------------------------

test "TC-EE-08-04: cancel instance with no open tasks still appends INSTANCE_CANCELLED event" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Use a graph with no HUMAN_TASK — START → SERVICE_TASK → END.
    // SERVICE_TASK keeps the token parked (not yet implemented in transition),
    // so the instance stays ACTIVE with no tasks created.
    const taskless_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "X", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"http://localhost\",\"timeout_ms\":5000}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const taskless_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "X", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "X", .target = "E", .condition = null, .is_default = false },
    };
    const taskless_graph = DefinitionGraph{
        .nodes = &taskless_nodes,
        .edges = &taskless_edges,
    };

    const name = "TC-EE-08-04 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = taskless_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // Start an instance. This instance has no HUMAN_TASK nodes so no tasks will
    // be created. The instance starts ACTIVE.
    const inst = try inst_store.create(alloc, draft.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Confirm no pending tasks exist for this instance.
    const pending_before = try countPendingTasks(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), pending_before);

    // Cancel the instance.
    try inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);

    // Verify: status is CANCELLED.
    const status_after = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status_after);
    try std.testing.expectEqualStrings("CANCELLED", status_after);

    // Verify: INSTANCE_CANCELLED event was appended despite no tasks.
    const cancel_event_count = try countCancelEvents(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 1), cancel_event_count);

    // Verify: still no PENDING tasks (nothing was wrongly created).
    const pending_after = try countPendingTasks(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), pending_after);
}

// ---------------------------------------------------------------------------
// TC-EE-08-05: Concurrency — first-writer-wins via row-level lock
//
// This test executes two sequential cancels to verify the first-writer-wins
// semantic guaranteed by the FOR UPDATE lock in cancelInstance(). Because the
// first call commits before the second begins, the second sees CANCELLED status
// and returns InstanceAlreadyTerminated. This verifies the lock mechanism
// without requiring true parallel goroutines.
// ---------------------------------------------------------------------------

test "TC-EE-08-05: concurrent cancel — first writer wins, second gets InstanceAlreadyTerminated" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-08-05 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // First cancel — must succeed (first writer wins).
    try inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);

    // Verify the instance is now CANCELLED.
    const status_mid = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status_mid);
    try std.testing.expectEqualStrings("CANCELLED", status_mid);

    // Second cancel — must fail because the instance is already CANCELLED.
    const result = inst_store.cancelInstance(alloc, &task_store, inst.instance_id, actor_id_str);
    try std.testing.expectError(CancelInstanceError.InstanceAlreadyTerminated, result);

    // Verify: exactly one INSTANCE_CANCELLED event (no double-cancel).
    const cancel_event_count = try countCancelEvents(&pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 1), cancel_event_count);

    // Verify: final status is still CANCELLED.
    const status_final = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status_final);
    try std.testing.expectEqualStrings("CANCELLED", status_final);
}
