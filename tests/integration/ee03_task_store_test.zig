//! Integration tests for EE-03 — Task store (createInTx, getById, completeInTx, cancelInTx).
//!
//! Tests exercise TaskStore directly against a real PostgreSQL database.
//! All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   EE-03 → TC-EE-03-01 through TC-EE-03-06
const std = @import("std");
const portable_env = @import("env");
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

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const Instance = bpm.engine.Instance;

const TaskStore = bpm.tasks.TaskStore;
const TaskStatus = bpm.tasks.TaskStatus;
const TaskError = bpm.tasks.TaskError;

// ---------------------------------------------------------------------------
// Fixed test UUIDs and constants
// ---------------------------------------------------------------------------

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = "My Task", .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

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

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

fn createActiveDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    version: []const u8,
) ![16]u8 {
    const creator_id = try parseUuid(allocator, creator_uuid_str);
    const created = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = creator_id,
    });
    const def_id = created.id;
    allocator.free(created.name);
    allocator.free(created.version);
    if (created.description) |d| allocator.free(d);
    if (created.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, created.graph);
    const activated = try def_store.activate(allocator, def_id);
    allocator.free(activated.name);
    allocator.free(activated.version);
    if (activated.description) |d| allocator.free(d);
    if (activated.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, activated.graph);
    return def_id;
}

/// Query the active token_id for the given instance. Returned [16]u8 is a value type (no alloc).
fn getTokenId(pool: *Pool, allocator: std.mem.Allocator, instance_id_hex: []const u8) ![16]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT id FROM tokens WHERE instance_id = $1::uuid AND status = 'active' LIMIT 1",
        &.{instance_id_hex},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0][0] == null) return error.NoToken;
    return parseUuid(allocator, result.rows[0][0].?);
}

/// Query the first PENDING task_id for the given instance as a UUID [16]u8.
fn getFirstTaskId(pool: *Pool, allocator: std.mem.Allocator, instance_id_hex: []const u8) ![16]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' LIMIT 1",
        &.{instance_id_hex},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0][0] == null) return error.NoTask;
    return parseUuid(allocator, result.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EE-03-01: createInTx returns PENDING task
// ---------------------------------------------------------------------------

test "TC-EE-03-01: createInTx returns task with PENDING status" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-03-01 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Get the active token created by the engine.
    const token_id = try getTokenId(&pool, alloc, inst_id_hex);

    var task_store = TaskStore.init(&pool);

    // Create a task directly via createInTx inside a real transaction.
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.begin();
    errdefer conn.exec("ROLLBACK", &.{}) catch {};

    const task = try task_store.createInTx(alloc, conn, inst_id, token_id, "T", "My Task", null, null, null);
    defer bpm.tasks.freeTask(alloc, task);

    try conn.commit();

    try std.testing.expectEqual(TaskStatus.PENDING, task.status);
}

// ---------------------------------------------------------------------------
// TC-EE-03-02: getById returns the correct task
// ---------------------------------------------------------------------------

test "TC-EE-03-02: getById returns task with matching instance_id and PENDING status" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-03-02 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Get the engine-created task id.
    const task_id = try getFirstTaskId(&pool, alloc, inst_id_hex);

    var task_store = TaskStore.init(&pool);
    const task = try task_store.getById(alloc, task_id);
    defer bpm.tasks.freeTask(alloc, task);

    try std.testing.expectEqual(TaskStatus.PENDING, task.status);
    try std.testing.expectEqual(inst_id, task.instance_id);
}

// ---------------------------------------------------------------------------
// TC-EE-03-03: getById with unknown task_id returns NotFound
// ---------------------------------------------------------------------------

test "TC-EE-03-03: getById with unknown task_id returns NotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var task_store = TaskStore.init(&pool);
    var nonexistent_id: [16]u8 = undefined;
    @memset(&nonexistent_id, 0xff);

    try std.testing.expectError(TaskError.NotFound, task_store.getById(alloc, nonexistent_id));
}

// ---------------------------------------------------------------------------
// TC-EE-03-04: completeInTx returns COMPLETED task
// ---------------------------------------------------------------------------

test "TC-EE-03-04: completeInTx returns task with COMPLETED status" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-03-04 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const task_id = try getFirstTaskId(&pool, alloc, inst_id_hex);

    var task_store = TaskStore.init(&pool);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.begin();
    errdefer conn.exec("ROLLBACK", &.{}) catch {};

    const completed_task = try task_store.completeInTx(alloc, conn, task_id, "{}");
    defer bpm.tasks.freeTask(alloc, completed_task);

    try conn.commit();

    try std.testing.expectEqual(TaskStatus.COMPLETED, completed_task.status);
}

// ---------------------------------------------------------------------------
// TC-EE-03-05: completeInTx on already-completed task returns AlreadyTerminated
// ---------------------------------------------------------------------------

test "TC-EE-03-05: completeInTx on already-completed task returns AlreadyTerminated" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-03-05 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const task_id = try getFirstTaskId(&pool, alloc, inst_id_hex);

    var task_store = TaskStore.init(&pool);

    // First complete — must succeed.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.begin();
        errdefer conn.exec("ROLLBACK", &.{}) catch {};
        const t1 = try task_store.completeInTx(alloc, conn, task_id, "{}");
        bpm.tasks.freeTask(alloc, t1);
        try conn.commit();
    }

    // Second complete — must return AlreadyTerminated.
    {
        const conn2 = try pool.acquire();
        defer pool.release(conn2);
        try conn2.begin();
        const result = task_store.completeInTx(alloc, conn2, task_id, "{}");
        conn2.exec("ROLLBACK", &.{}) catch {};
        try std.testing.expectError(TaskError.AlreadyTerminated, result);
    }
}

// ---------------------------------------------------------------------------
// TC-EE-03-06: cancelInTx cancels all pending tasks and returns count >= 1
// ---------------------------------------------------------------------------

test "TC-EE-03-06: cancelInTx returns count >= 1 and tasks are CANCELLED" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-03-06 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Verify there is at least one PENDING task before cancellation.
    const task_id = try getFirstTaskId(&pool, alloc, inst_id_hex);
    _ = task_id;

    var task_store = TaskStore.init(&pool);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.begin();
    errdefer conn.exec("ROLLBACK", &.{}) catch {};

    const cancelled_count = try task_store.cancelInTx(alloc, conn, inst_id);
    try conn.commit();

    try std.testing.expect(cancelled_count >= 1);

    // Verify via DB that no PENDING tasks remain for this instance.
    const check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var pending_result = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING'",
        &.{inst_id_hex},
    );
    defer pending_result.deinit();
    const pending_count = std.fmt.parseInt(i64, pending_result.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 0), pending_count);
}
