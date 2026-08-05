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
const Definition = bpm.definition.Definition;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const TaskStore = bpm.tasks.TaskStore;

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
const actor_id_str = "00000000-0000-0000-0000-000000000001";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - skipping integration test\n", .{});
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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn freeCreatedInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM subprocess_links WHERE child_instance_id = $1::uuid OR parent_instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tokens WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn queryPendingTaskId(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![16]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' ORDER BY created_at ASC LIMIT 1",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return parseUuid(allocator, rows.rows[0][0] orelse "");
}

fn queryChildInstanceIdHex(allocator: std.mem.Allocator, pool: *Pool, parent_instance_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT child_instance_id FROM subprocess_links WHERE parent_instance_id = $1::uuid ORDER BY created_at DESC LIMIT 1",
        &.{parent_instance_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "");
}

fn queryStatus(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
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
    return allocator.dupe(u8, rows.rows[0][0] orelse "");
}

fn queryVariablesText(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT variables::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "{}");
}

fn queryLatestEventPayloadByType(
    allocator: std.mem.Allocator,
    pool: *Pool,
    instance_id_hex: []const u8,
    event_type: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT payload::text FROM events WHERE instance_id = $1::uuid AND event_type = $2 ORDER BY sequence_number DESC LIMIT 1",
        &.{ instance_id_hex, event_type },
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "{}");
}

fn setupParentChildDefinitions(
    alloc: std.mem.Allocator,
    def_store: *DefinitionStore,
    parent_name: []const u8,
    child_name: []const u8,
) !struct { parent: Definition, child: Definition } {
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const child_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "CT", .node_type = .HUMAN_TASK, .label = "Child Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const child_edges = [_]GraphEdge{
        .{ .id = "ce1", .source = "S", .target = "CT", .condition = null, .is_default = false },
        .{ .id = "ce2", .source = "CT", .target = "E", .condition = null, .is_default = false },
    };

    const child_draft = try def_store.create(alloc, CreateParams{
        .name = child_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &child_nodes, .edges = &child_edges },
        .created_by = created_by,
    });
    const child_active = try def_store.activate(alloc, child_draft.id);
    freeDefinition(alloc, child_draft);

    const child_id_hex = try uuidToHexStr(alloc, child_active.id);
    defer alloc.free(child_id_hex);

    const parent_attrs = try std.fmt.allocPrint(alloc, "{{\"child_definition_id\":\"{s}\"}}", .{child_id_hex});
    defer alloc.free(parent_attrs);

    const parent_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "PT", .node_type = .HUMAN_TASK, .label = "Parent Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "SP", .node_type = .SUB_PROCESS, .label = "Sub", .attributes = parent_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const parent_edges = [_]GraphEdge{
        .{ .id = "pe1", .source = "S", .target = "PT", .condition = null, .is_default = false },
        .{ .id = "pe2", .source = "PT", .target = "SP", .condition = null, .is_default = false },
        .{ .id = "pe3", .source = "SP", .target = "E", .condition = null, .is_default = false },
    };

    const parent_draft = try def_store.create(alloc, CreateParams{
        .name = parent_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &parent_nodes, .edges = &parent_edges },
        .created_by = created_by,
    });
    const parent_active = try def_store.activate(alloc, parent_draft.id);
    freeDefinition(alloc, parent_draft);

    return .{ .parent = parent_active, .child = child_active };
}

test "EXT-05: completing parent task on SUB_PROCESS starts child and marks parent waiting" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-01 Parent";
    const child_name = "TC-EXT-05-01 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const wait_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_projections WHERE instance_id = $1::uuid AND current_nodes::text LIKE '%waiting_child_instance_id%'",
        &.{parent_hex},
    );
    defer {
        var r = wait_rows;
        r.deinit();
    }
    const waiting_count = std.fmt.parseInt(i64, wait_rows.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expect(waiting_count == 1);
}

test "EXT-05: child completion merges variables and completes parent" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-02 Parent";
    const child_name = "TC-EXT-05-02 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"x\":2,\"child_only\":true}");

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("COMPLETED", parent_status);

    const vars_text = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(vars_text);
    try std.testing.expect(std.mem.indexOf(u8, vars_text, "\"x\": 2") != null or std.mem.indexOf(u8, vars_text, "\"x\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, vars_text, "child_only") != null);
}

test "EXT-05: child variables are isolated from parent until child completion" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-04 Parent";
    const child_name = "TC-EXT-05-04 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1,\"parent_only\":true}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const parent_vars_before = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(parent_vars_before);

    try std.testing.expect(std.mem.indexOf(u8, parent_vars_before, "\"x\": 1") != null or std.mem.indexOf(u8, parent_vars_before, "\"x\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent_vars_before, "child_only") == null);

    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"x\":2,\"child_only\":true}");

    const parent_vars_after = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(parent_vars_after);

    try std.testing.expect(std.mem.indexOf(u8, parent_vars_after, "\"x\": 2") != null or std.mem.indexOf(u8, parent_vars_after, "\"x\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent_vars_after, "child_only") != null);
}

test "EXT-05: child error propagates parent error with required IDs" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-05 Parent";
    const child_name = "TC-EXT-05-05 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_id = try parseUuid(alloc, child_hex);
    try inst_store.setInstanceError(alloc, .{
        .instance_id = child_id,
        .error_type = .SERVICE_TASK_FAILURE,
        .affected_node = null,
        .affected_field = null,
        .reason = "child failure",
        .variable_state = "{\"x\":1}",
        .evaluated_conditions = null,
        .actor_id = actor_id_str,
    });

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "CHILD_PROCESS_ERROR");
    defer alloc.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "CHILD_PROCESS_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, parent_hex) != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, child_hex) != null);
}

test "EXT-05: child external cancellation propagates parent error with required IDs" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-06 Parent";
    const child_name = "TC-EXT-05-06 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_id = try parseUuid(alloc, child_hex);
    try inst_store.cancelInstance(alloc, &task_store, child_id, actor_id_str);

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "CHILD_PROCESS_CANCELLED");
    defer alloc.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "CHILD_PROCESS_CANCELLED") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, parent_hex) != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, child_hex) != null);
}

test "EXT-05: parent cancel does not cascade to child" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-EXT-05-03 Parent";
    const child_name = "TC-EXT-05-03 Child";
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    try inst_store.cancelInstance(alloc, &task_store, parent_instance.instance_id, actor_id_str);

    const child_status = try queryStatus(alloc, &pool, child_hex);
    defer alloc.free(child_status);
    try std.testing.expectEqualStrings("ACTIVE", child_status);
}
