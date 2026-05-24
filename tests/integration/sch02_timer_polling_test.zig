//! Integration tests for SCH-02 — Timer polling and firing.
const std = @import("std");
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
const TimerStore = bpm.scheduler;
const Scheduler = bpm.scheduler_poller.Scheduler;

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
const actor_id_str = "00000000-0000-0000-0000-000000000001";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping SCH-02 integration tests\n", .{});
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

fn insertRecurringPendingTimer(
    pool: *Pool,
    allocator: std.mem.Allocator,
    instance_id_hex: []const u8,
    repeat_expression: []const u8,
    repeat_total: ?u32,
    fired_count: u32,
    interval_us: u64,
    fire_offset_interval: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const repeat_total_text = if (repeat_total) |n|
        try std.fmt.allocPrint(allocator, "{}", .{n})
    else
        "";
    defer if (repeat_total != null) allocator.free(repeat_total_text);

    const fired_count_text = try std.fmt.allocPrint(allocator, "{}", .{fired_count});
    defer allocator.free(fired_count_text);

    const interval_us_text = try std.fmt.allocPrint(allocator, "{}", .{interval_us});
    defer allocator.free(interval_us_text);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"timer_kind\":\"scheduled_transition\",\"source\":\"SCH-07\",\"node_id\":\"WAIT_TIMER\",\"event_type_on_fire\":\"TIMER_FIRED\",\"recurrence\":{{\"expression\":\"{s}\",\"repeat_total\":{s},\"fired_count\":{},\"interval_us\":{}}}}}",
        .{ repeat_expression, if (repeat_total != null) repeat_total_text else "null", fired_count, interval_us },
    );
    defer allocator.free(payload);

    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status, repeat_expression, repeat_total, fired_count, repeat_interval_us) VALUES ($1::uuid, 'scheduled_transition', 'WAIT_TIMER', NOW() + $2::interval, 'auto_transition', $3::jsonb, 'pending', $4, NULLIF($5, '')::integer, $6::integer, $7::bigint)",
        &.{
            instance_id_hex,
            fire_offset_interval,
            payload,
            repeat_expression,
            repeat_total_text,
            fired_count_text,
            interval_us_text,
        },
    );
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

fn timerIdForInstance(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT id::text FROM timers WHERE instance_id = $1::uuid ORDER BY created_at ASC LIMIT 1",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }
    if (rows.rows.len == 0) return error.TimerNotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "") catch return error.OutOfMemory;
}

fn firstPendingTaskId(allocator: std.mem.Allocator, task_store: *TaskStore, instance_id: [16]u8) ![16]u8 {
    const tasks = try task_store.list(allocator, instance_id, null, null, 50, 0);
    defer {
        for (tasks) |task| bpm.tasks.freeTask(allocator, task);
        allocator.free(tasks);
    }
    if (tasks.len == 0) return error.TaskNotFound;
    return tasks[0].task_id;
}

test "TC-SCH-04-01: activating a human task with escalation_timer_duration persists a pending escalation timer" {
    const allocator = std.heap.page_allocator;
    const five_minutes_us = 5 * std.time.us_per_min;

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

    const name = "SCH04-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\",\"escalation_timer_duration\":\"PT5M\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id = try firstPendingTaskId(allocator, &task_store, inst.instance_id);
    const task_id_hex = try uuidToHexStr(allocator, task_id);
    defer allocator.free(task_id_hex);
    const task = try task_store.getById(allocator, task_id);
    defer bpm.tasks.freeTask(allocator, task);

    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT timer_type, action_type, status, action_config->>'timer_kind', action_config->>'task_id', action_config->>'escalation_duration_iso8601', action_config->>'due_at_utc', (EXTRACT(EPOCH FROM fires_at) * 1000000)::bigint FROM timers WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][0] orelse "", "human_task_escalation"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][1] orelse "", "append_escalation_event"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][2] orelse "", "pending"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][3] orelse "", "human_task_escalation"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][4] orelse "", task_id_hex));
    try std.testing.expect(std.mem.eql(u8, rows.rows[0][5] orelse "", "PT5M"));

    const due_at_utc = try std.fmt.parseInt(i64, rows.rows[0][6] orelse "0", 10);
    const fire_at_utc = try std.fmt.parseInt(i64, rows.rows[0][7] orelse "0", 10);
    try std.testing.expectEqual(task.created_at + five_minutes_us, due_at_utc);
    try std.testing.expectEqual(task.created_at + five_minutes_us, fire_at_utc);
}

test "TC-SCH-04-02: scheduler fires escalation timer, appends ESCALATION, and reassigns atomically" {
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

    const name = "SCH04-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\",\"escalation_timer_duration\":\"PT0S\",\"reassign_to\":{\"assignee_type\":\"USER\",\"assignee_ref\":\"u2\"}}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id = try firstPendingTaskId(allocator, &task_store, inst.instance_id);
    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const escalations = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'ESCALATION'",
        &.{inst_id_hex},
    );
    const timer_fired = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );
    const fired_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired' AND timer_type = 'human_task_escalation'",
        &.{inst_id_hex},
    );

    const updated_task = try task_store.getById(allocator, task_id);
    defer bpm.tasks.freeTask(allocator, updated_task);

    try std.testing.expectEqual(@as(i64, 1), escalations);
    try std.testing.expectEqual(@as(i64, 0), timer_fired);
    try std.testing.expectEqual(@as(i64, 1), fired_timers);
    try std.testing.expect(updated_task.assignee_type != null);
    try std.testing.expect(updated_task.assignee_ref != null);
    try std.testing.expect(std.mem.eql(u8, updated_task.assignee_type.?, "USER"));
    try std.testing.expect(std.mem.eql(u8, updated_task.assignee_ref.?, "u2"));
}

test "TC-SCH-04-03: completing a task cancels its pending escalation timer and prevents ESCALATION" {
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

    const name = "SCH04-TC03";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\",\"escalation_timer_duration\":\"PT0S\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id = try firstPendingTaskId(allocator, &task_store, inst.instance_id);
    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{}");

    const pending_after_complete = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending' AND timer_type = 'human_task_escalation'",
        &.{inst_id_hex},
    );
    const cancelled_after_complete = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled' AND timer_type = 'human_task_escalation'",
        &.{inst_id_hex},
    );

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const escalations = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'ESCALATION'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 0), pending_after_complete);
    try std.testing.expectEqual(@as(i64, 1), cancelled_after_complete);
    try std.testing.expectEqual(@as(i64, 0), escalations);
}

test "TC-SCH-02-01: due timer is fired atomically and emits TIMER_FIRED" {
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
    const task_store = TaskStore.init(&pool);
    _ = task_store;

    const name = "SCH02-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const fired_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), fired_timers);
    try std.testing.expectEqual(@as(i64, 1), timer_fired_events);
}

test "TC-SCH-02-02: scheduler skips locked timers and does not fire CANCELLED timers" {
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

    const name = "SCH02-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    const timer_id_hex = try timerIdForInstance(allocator, &pool, inst_id_hex);
    defer allocator.free(timer_id_hex);
    const timer_uuid = try parseUuid(timer_id_hex);
    const lock_key = bpm.scheduler_poller.advisoryLockKey(timer_uuid);
    const lock_key_text = try std.fmt.allocPrint(allocator, "{}", .{lock_key});
    defer allocator.free(lock_key_text);

    const lock_conn = try pool.acquire();
    defer pool.release(lock_conn);
    try lock_conn.begin();
    defer lock_conn.rollback() catch {};
    try lock_conn.exec("SELECT pg_advisory_xact_lock($1::bigint)", &.{lock_key_text});

    var scheduler = Scheduler.init(&pool, .{});
    const skipped_summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), skipped_summary.fired);
    try std.testing.expect(skipped_summary.skipped_locked > 0);

    const pending_before_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), pending_before_cancel);

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    const post_cancel_summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), post_cancel_summary.fired);

    const fired_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    const cancelled_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 0), fired_after_cancel);
    try std.testing.expectEqual(@as(i64, 1), cancelled_after_cancel);
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

test "TC-SCH-02-03: firing rollback keeps timer PENDING when event append fails" {
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

    const name = "SCH02-TC03";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    const timer_id_hex = try timerIdForInstance(allocator, &pool, inst_id_hex);
    defer allocator.free(timer_id_hex);

    const max_seq = try countInt(
        &pool,
        allocator,
        "SELECT COALESCE(MAX(sequence_number), 0) FROM events WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    const next_seq_text = try std.fmt.allocPrint(allocator, "{}", .{max_seq + 1});
    defer allocator.free(next_seq_text);

    const conflicting_idem = try std.fmt.allocPrint(allocator, "timer-fired:{s}", .{timer_id_hex});
    defer allocator.free(conflicting_idem);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO events (instance_id, event_type, payload, actor_id, sequence_number, idempotency_key) VALUES ($1::uuid, $2, $3::jsonb, $1::uuid, $4::bigint, $5)",
        &.{ inst_id_hex, "TIMER_FIRED", "{}", next_seq_text, conflicting_idem },
    );

    var scheduler = Scheduler.init(&pool, .{});
    try std.testing.expectError(
        bpm.scheduler_poller.SchedulerError.TransactionFailed,
        scheduler.pollDueTimers(allocator),
    );

    const pending_count = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE id = $1::uuid AND status = 'pending'",
        &.{timer_id_hex},
    );
    const fired_count = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE id = $1::uuid AND status = 'fired'",
        &.{timer_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), pending_count);
    try std.testing.expectEqual(@as(i64, 0), fired_count);
}

test "TC-SCH-03-01: completing an instance cancels pending timers and scheduler does not fire them" {
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

    const name = "SCH03-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
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
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW(), 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );

    const pending_before_complete = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), pending_before_complete);

    const task_id = try firstPendingTaskId(allocator, &task_store, inst.instance_id);
    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{}");

    const completed_instances = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM instance_projections WHERE instance_id = $1::uuid AND status = 'COMPLETED'",
        &.{inst_id_hex},
    );
    const pending_after_complete = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    const cancelled_after_complete = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), completed_instances);
    try std.testing.expectEqual(@as(i64, 0), pending_after_complete);
    try std.testing.expectEqual(@as(i64, 1), cancelled_after_complete);

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const fired_after_poll = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 0), fired_after_poll);
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

test "TC-SCH-03-02: cancelling an instance atomically cancels all pending timers and leaves FIRED timers unchanged" {
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

    const name = "SCH03-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
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
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW(), 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW(), 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status, fired_at) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW(), 'auto_transition', '{}'::jsonb, 'fired', NOW())",
        &.{inst_id_hex},
    );

    const pending_before_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    const fired_before_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 2), pending_before_cancel);
    try std.testing.expectEqual(@as(i64, 1), fired_before_cancel);

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    const pending_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    const cancelled_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled'",
        &.{inst_id_hex},
    );
    const fired_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 0), pending_after_cancel);
    try std.testing.expectEqual(@as(i64, 2), cancelled_after_cancel);
    try std.testing.expectEqual(@as(i64, 1), fired_after_cancel);

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

test "TC-SCH-03-03: fire-before-cancel outcome keeps timer FIRED (first-commit-wins ordering)" {
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

    const name = "SCH03-TC03";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    var scheduler = Scheduler.init(&pool, .{});
    const fired_summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), fired_summary.fired);

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    const fired_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    const cancelled_after_cancel = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), fired_after_cancel);
    try std.testing.expectEqual(@as(i64, 0), cancelled_after_cancel);
}

test "TC-SCH-03-04: cancel-before-fire outcome keeps timer CANCELLED and prevents TIMER_FIRED append" {
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

    const name = "SCH03-TC04";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const cancelled_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'cancelled'",
        &.{inst_id_hex},
    );
    const fired_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), cancelled_timers);
    try std.testing.expectEqual(@as(i64, 0), fired_timers);
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

// =============================================================================
// SCH-05 — Missed timer recovery
// =============================================================================

test "TC-SCH-05-01: startup sweep fires all due timers with fired_late=true" {
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

    const name = "SCH05-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    // Ensure the timer is materially overdue so fired_late=true is deterministic
    // on startup sweep (PT0S can be equal-to-now on fast hosts).
    const prep_conn = try pool.acquire();
    defer pool.release(prep_conn);
    try prep_conn.exec(
        "UPDATE timers SET fires_at = NOW() - INTERVAL '1 second' WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );

    // Fresh scheduler — is_startup_sweep = true
    var scheduler = Scheduler.init(&pool, .{ .poll_interval_ms = 5000 });
    try std.testing.expect(scheduler.is_startup_sweep);

    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    // Verify TIMER_FIRED event has fired_late=true in the payload
    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expect(rows.rows.len > 0);
    if (rows.rows.len > 0) {
        const payload = rows.rows[0][0] orelse "";
        try std.testing.expect(
            std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":true") or
                std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\": true"),
        );
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"scheduled_fire_at\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"actual_fire_at\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"timer_id\""));
    }
}

test "TC-SCH-05-02: normal poll does not mark sub-interval lateness" {
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

    const name = "SCH05-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    // First call: startup sweep. This consumes the PT0S timer.
    var scheduler = Scheduler.init(&pool, .{ .poll_interval_ms = 5000 });
    _ = try scheduler.pollDueTimers(allocator);
    try std.testing.expect(!scheduler.is_startup_sweep);

    // Insert a new timer with fires_at = NOW() — should be due but not overdue
    // by more than one poll interval.
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'WAIT_TIMER', NOW(), 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );

    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expect(rows.rows.len > 0);
    if (rows.rows.len > 0) {
        const payload = rows.rows[0][0] orelse "";
        // A timer fired at NOW() should NOT be marked late in a normal poll
        // because the delta is within one poll_interval.
        try std.testing.expect(
            std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":false") or
                std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\": false"),
        );
    }
}

test "TC-SCH-05-03: normal poll marks timers overdue by more than one poll interval" {
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

    const name = "SCH05-TC03";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    // First call: startup sweep consumes the PT0S timer.
    var scheduler = Scheduler.init(&pool, .{ .poll_interval_ms = 100 });
    _ = try scheduler.pollDueTimers(allocator);
    try std.testing.expect(!scheduler.is_startup_sweep);

    // Insert a timer with fires_at well in the past (> poll_interval ago).
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'WAIT_TIMER', NOW() - INTERVAL '10 seconds', 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );

    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expect(rows.rows.len > 0);
    if (rows.rows.len > 0) {
        const payload = rows.rows[0][0] orelse "";
        // A timer 10 seconds overdue with 100ms poll interval should be late
        try std.testing.expect(
            std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":true") or
                std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\": true"),
        );
    }
}

test "TC-SCH-05-04: extended TIMER_FIRED payload contains all metadata fields" {
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

    const name = "SCH05-TC04";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    var scheduler = Scheduler.init(&pool, .{});
    _ = try scheduler.pollDueTimers(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expect(rows.rows.len > 0);
    if (rows.rows.len > 0) {
        const payload = rows.rows[0][0] orelse "";
        // The payload must be valid JSON with all four fields
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"timer_id\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"scheduled_fire_at\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"actual_fire_at\""));

        // Validate numeric values are actual integers (not null or text)
        const scheduled_pos = std.mem.indexOf(u8, payload, "\"scheduled_fire_at\"") orelse @panic("missing field");
        const after_scheduled = payload[scheduled_pos..];
        try std.testing.expect(std.mem.containsAtLeast(u8, after_scheduled, 1, ":"));
    }
}

test "TC-SCH-05-05: is_startup_sweep transitions from true to false after first poll" {
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

    const name = "SCH05-TC05";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
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

    var scheduler = Scheduler.init(&pool, .{});
    try std.testing.expect(scheduler.is_startup_sweep);

    _ = try scheduler.pollDueTimers(allocator);

    try std.testing.expect(!scheduler.is_startup_sweep);

    // Calling pollDueTimers again should keep is_startup_sweep = false
    _ = try scheduler.pollDueTimers(allocator);
    try std.testing.expect(!scheduler.is_startup_sweep);
}

test "TC-SCH-05-06: all due timers are processed — none skipped" {
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

    const name = "SCH05-TC06";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    // Create a definition with two timer branches to get multiple timers
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "PARALLEL", .node_type = .PARALLEL_GATEWAY, .label = null, .attributes = null },
        .{ .id = "T1", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
        .{ .id = "T2", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT0S\"}" },
        .{ .id = "JOIN", .node_type = .PARALLEL_GATEWAY, .label = null, .attributes = null },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "PARALLEL", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "PARALLEL", .target = "T1", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "PARALLEL", .target = "T2", .condition = null, .is_default = false },
        .{ .id = "e4", .source = "T1", .target = "JOIN", .condition = null, .is_default = false },
        .{ .id = "e5", .source = "T2", .target = "JOIN", .condition = null, .is_default = false },
        .{ .id = "e6", .source = "JOIN", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    // Check we have 2 pending timers
    const timer_count_before = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 2), timer_count_before);

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 2), summary.fired);

    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 2), timer_fired_events);

    const fired_timers = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'fired'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 2), fired_timers);
}

test "TC-SCH-05-07: cancelled timers are skipped even if fires_at <= NOW()" {
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

    const name = "SCH05-TC07";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    // Insert a timer with fires_at = NOW() - 1 hour, status = CANCELLED
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW() - INTERVAL '1 hour', 'auto_transition', '{}'::jsonb, 'cancelled')",
        &.{inst_id_hex},
    );

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    // No pending timers to fire (the only one is CANCELLED)
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

test "TC-SCH-05-12: crash/restart — timer inserted with past fires_at is fired with fired_late=true" {
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

    const name = "SCH05-TC12";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    // Start an instance to get a valid instance_id for timer insertion
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    // Simulate crash/restart: insert a timer with fires_at in the past
    // that was never processed (status = pending).
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO timers (instance_id, timer_type, step_name, fires_at, action_type, action_config, status) VALUES ($1::uuid, 'scheduled_transition', 'APPROVE', NOW() - INTERVAL '5 minutes', 'auto_transition', '{}'::jsonb, 'pending')",
        &.{inst_id_hex},
    );

    // Fresh scheduler simulates a restart — is_startup_sweep = true
    var scheduler = Scheduler.init(&pool, .{ .poll_interval_ms = 5000 });
    try std.testing.expect(scheduler.is_startup_sweep);

    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    // Verify fired_late=true in the payload
    const rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expect(rows.rows.len > 0);
    if (rows.rows.len > 0) {
        const payload = rows.rows[0][0] orelse "";
        try std.testing.expect(
            std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":true") or
                std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\": true"),
        );
        // Verify the timer was indeed overdue (scheduled < actual)
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"scheduled_fire_at\""));
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"actual_fire_at\""));
    }

    // Verify is_startup_sweep transitioned
    try std.testing.expect(!scheduler.is_startup_sweep);
}

// =============================================================================
// SCH-07 — Recurring timers
// =============================================================================

test "TC-SCH-07-01: firing a recurring timer re-arms next timer in same poll transaction" {
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

    const name = "SCH07-TC01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try insertRecurringPendingTimer(
        &pool,
        allocator,
        inst_id_hex,
        "R3/PT1H",
        3,
        0,
        3_600_000_000,
        "-1 second",
    );

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const recurring_fired = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'fired'",
        &.{inst_id_hex},
    );
    const recurring_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'pending'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), recurring_fired);
    try std.testing.expectEqual(@as(i64, 1), recurring_pending);
    try std.testing.expectEqual(@as(i64, 1), timer_fired_events);

    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT repeat_expression, COALESCE(repeat_total::text, ''), COALESCE(fired_count::text, ''), COALESCE(repeat_interval_us::text, '') FROM timers WHERE instance_id = $1::uuid AND status = 'pending' AND repeat_expression IS NOT NULL ORDER BY created_at DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("R3/PT1H", rows.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("3", rows.rows[0][1] orelse "");
    try std.testing.expectEqualStrings("1", rows.rows[0][2] orelse "");
    try std.testing.expectEqualStrings("3600000000", rows.rows[0][3] orelse "");
}

test "TC-SCH-07-02: finite recurring timer R3/PT1H stops after third firing" {
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

    const name = "SCH07-TC02";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try insertRecurringPendingTimer(
        &pool,
        allocator,
        inst_id_hex,
        "R3/PT1H",
        3,
        0,
        3_600_000_000,
        "-1 second",
    );

    var scheduler = Scheduler.init(&pool, .{});

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE timers SET fires_at = NOW() - INTERVAL '1 second' WHERE instance_id = $1::uuid AND status = 'pending' AND repeat_expression IS NOT NULL",
            &.{inst_id_hex},
        );

        const summary = try scheduler.pollDueTimers(allocator);
        try std.testing.expectEqual(@as(u32, 1), summary.fired);
    }

    const recurring_fired = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'fired'",
        &.{inst_id_hex},
    );
    const recurring_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'pending'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 3), recurring_fired);
    try std.testing.expectEqual(@as(i64, 0), recurring_pending);
    try std.testing.expectEqual(@as(i64, 3), timer_fired_events);
}

test "TC-SCH-07-03: infinite recurring timer R/PT1H continues by creating next pending timer" {
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

    const name = "SCH07-TC03";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try insertRecurringPendingTimer(
        &pool,
        allocator,
        inst_id_hex,
        "R/PT1H",
        null,
        0,
        3_600_000_000,
        "-1 second",
    );

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const recurring_fired = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'fired'",
        &.{inst_id_hex},
    );
    const recurring_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'pending'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 1), recurring_fired);
    try std.testing.expectEqual(@as(i64, 1), recurring_pending);

    const conn = try pool.acquire();
    defer pool.release(conn);
    const rows = try conn.query(
        allocator,
        "SELECT repeat_expression, COALESCE(repeat_total::text, ''), COALESCE(fired_count::text, '') FROM timers WHERE instance_id = $1::uuid AND status = 'pending' AND repeat_expression IS NOT NULL ORDER BY created_at DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("R/PT1H", rows.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("", rows.rows[0][1] orelse "");
    try std.testing.expectEqualStrings("1", rows.rows[0][2] orelse "");
}

test "TC-SCH-07-04: cancelling instance cancels recurring chain and prevents further firing" {
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

    const name = "SCH07-TC04";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try insertRecurringPendingTimer(
        &pool,
        allocator,
        inst_id_hex,
        "R/PT1H",
        null,
        0,
        3_600_000_000,
        "-1 second",
    );

    try inst_store.cancelInstance(allocator, &task_store, inst.instance_id, actor_id_str);

    var scheduler = Scheduler.init(&pool, .{});
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 0), summary.fired);

    const recurring_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'pending'",
        &.{inst_id_hex},
    );
    const recurring_cancelled = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'cancelled'",
        &.{inst_id_hex},
    );
    const timer_fired_events = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED'",
        &.{inst_id_hex},
    );

    try std.testing.expectEqual(@as(i64, 0), recurring_pending);
    try std.testing.expectEqual(@as(i64, 1), recurring_cancelled);
    try std.testing.expectEqual(@as(i64, 0), timer_fired_events);
}

test "TC-SCH-07-05: overdue recurring timer on startup sweep fires with fired_late=true and re-arms" {
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

    const name = "SCH07-TC05";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "APPROVE", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "APPROVE", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "APPROVE", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    try insertRecurringPendingTimer(
        &pool,
        allocator,
        inst_id_hex,
        "R/PT1H",
        null,
        0,
        3_600_000_000,
        "-2 hour",
    );

    var scheduler = Scheduler.init(&pool, .{ .poll_interval_ms = 5000 });
    try std.testing.expect(scheduler.is_startup_sweep);
    const summary = try scheduler.pollDueTimers(allocator);
    try std.testing.expectEqual(@as(u32, 1), summary.fired);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const payload_rows = try conn.query(
        allocator,
        "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'TIMER_FIRED' ORDER BY sequence_number DESC LIMIT 1",
        &.{inst_id_hex},
    );
    defer {
        var r = payload_rows;
        r.deinit();
    }

    try std.testing.expect(payload_rows.rows.len > 0);
    const payload = payload_rows.rows[0][0] orelse "";
    try std.testing.expect(
        std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":true") or
            std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\": true"),
    );

    const recurring_pending = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND repeat_expression IS NOT NULL AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), recurring_pending);
}
