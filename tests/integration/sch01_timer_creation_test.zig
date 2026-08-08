//! Integration tests for SCH-01 — Durable timer creation.
//!
//! Tests exercise timer persistence behavior through InstanceStore and the
//! scheduler timer store against a real PostgreSQL database.
//!
//! DIRECTIVE T-1: real DB only, no mocks/stubs.
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const Definition = bpm.definition.Definition;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const TaskStore = bpm.tasks.TaskStore;
const scheduler_store = bpm.scheduler;

// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
// GH-512 retention: platform-admin user_id (system actor); preserve identity for RBAC/role-guard assertions
const actor_id_str = "00000000-0000-0000-0000-000000000001";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping SCH-01 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn freeInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM timers WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn countInt(pool: *Pool, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(allocator, sql, params);
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    const value = if (rows.rows[0].len > 0) rows.rows[0][0] orelse "0" else "0";
    return std.fmt.parseInt(i64, value, 10) catch 0;
}

fn createAndActivateDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    graph: DefinitionGraph,
) ![16]u8 {
    const created_by = try parseUuid(creator_uuid_str);
    const draft = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer freeDefinition(allocator, draft);

    const active = try def_store.activate(allocator, draft.id);
    defer freeDefinition(allocator, active);

    return draft.id;
}

fn firstTaskId(allocator: std.mem.Allocator, task_store: *TaskStore, instance_id: [16]u8) ![16]u8 {
    const tasks = try task_store.list(allocator, instance_id, null, null, 50, 0);
    defer {
        for (tasks) |task| bpm.tasks.freeTask(allocator, task);
        allocator.free(tasks);
    }
    if (tasks.len == 0) return error.TaskNotFound;
    return tasks[0].task_id;
}

test "TC-SCH-01-01: timer record is persisted when execution reaches a timer node" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const name = "SCH01-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT5M\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "WAIT_TIMER", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "WAIT_TIMER", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);

    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT id::text, instance_id::text, status, action_config::text, (fires_at IS NOT NULL)::int FROM timers WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const row = rows.rows[0];
    const timer_id_col: []const u8 = if (row[0]) |v| v else "";
    const instance_id_col: []const u8 = if (row[1]) |v| v else "";
    const status_col: []const u8 = if (row[2]) |v| v else "";
    const payload_col: []const u8 = if (row[3]) |v| v else "";
    const fires_at_non_null_col: []const u8 = if (row[4]) |v| v else "0";
    try std.testing.expect(timer_id_col.len > 0);
    try std.testing.expectEqualStrings(inst_id_hex, instance_id_col);
    try std.testing.expectEqualStrings("pending", status_col);
    try std.testing.expect(std.mem.indexOf(u8, payload_col, "node_id") != null);
    try std.testing.expectEqualStrings("1", fires_at_non_null_col);
}

test "TC-SCH-01-02: transition/state/event and timer persistence are committed together" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const name = "SCH01-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT5M\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "WAIT_TIMER", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "WAIT_TIMER", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);

    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id = try firstTaskId(allocator, &task_store, inst.instance_id);
    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{}");

    const completed_tasks = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM tasks WHERE instance_id = $1::uuid AND status = 'COMPLETED'",
        &.{inst_id_hex},
    );
    const task_completed_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'task_completed'",
        &.{inst_id_hex},
    );
    const pending_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), completed_tasks);
    try std.testing.expectEqual(@as(i64, 1), task_completed_events);
    try std.testing.expectEqual(@as(i64, 1), pending_timers);

    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT current_nodes::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expect(std.mem.indexOf(u8, rows.rows[0][0] orelse "", "WAIT_TIMER") != null);
}

test "TC-SCH-01-03: pending timers survive restart simulation" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);

    var def_store = DefinitionStore.init(allocator, &pool);
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);

    const name = "SCH01-TC03";
    cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT10M\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "WAIT_TIMER", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "WAIT_TIMER", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    const pending_before = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), pending_before);

    freeInstance(allocator, inst);
    inst_store.deinit();
    def_store.deinit();
    pool.deinit();

    var pool_after = try makePool(allocator, url);
    defer pool_after.deinit();
    defer cleanupInstance(&pool_after, inst_id_hex);
    defer cleanupByName(&pool_after, name);

    const pending_after = try countInt(
        &pool_after,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), pending_after);
}

test "TC-SCH-01-04: fire_at <= NOW timers are due immediately and remain pending" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const name = "SCH01-TC04";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "DUE_NOW", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "DUE_NOW", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "DUE_NOW", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const due_now_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending' AND fires_at <= NOW()",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), due_now_pending);
}

test "TC-SCH-01-05: cancelled instance rejects timer creation" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const name = "SCH01-TC05";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.begin();
    defer conn.rollback() catch {};

// GH-512: replaced hardcoded definition-sentinel with TestHarness.newUuid() per GH-512.
// The test asserts only that the insert errors with InstanceCancelled, so the specific
// timer_id value does not matter — per-test uniqueness is preserved.
    const attempted_timer_id = h.newUuid();

    const insert_result = scheduler_store.insertPendingTimerInTx(
        allocator,
        conn,
        .{
            .timer_id = attempted_timer_id,
            .instance_id = inst.instance_id,
            .step_name = "DUMMY_TIMER",
            .duration_iso8601 = "PT1M",
            .payload_json = "{\"node_id\":\"DUMMY_TIMER\"}",
        },
    );
    try std.testing.expectError(scheduler_store.TimerStoreError.InstanceCancelled, insert_result);

    const timer_count = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 0), timer_count);
}
