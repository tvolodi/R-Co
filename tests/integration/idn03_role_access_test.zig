//! Integration tests for IDN-03 role-based access behavior.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;
const definition_mod = bpm.definition;
const snapshot_mod = bpm.snapshot;
const instance_mod = bpm.engine;
const task_mod = bpm.tasks;

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

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-idn03-admin",
    };
}

fn taskWorkerActor(user_id: []const u8) bpm.task_routes.Actor {
    return .{
        .user_id = user_id,
        .roles = &[_]bpm.api_authorization.Role{.TASK_WORKER},
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };
}

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

fn cleanupUserByUsername(pool: *pool_mod.Pool, username: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM api_tokens
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec(
        \\DELETE FROM user_roles
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec("DELETE FROM users WHERE username = $1", &[_][]const u8{username}) catch {};
}

fn cleanupGroupByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM group_members
        \\WHERE group_id IN (SELECT id FROM groups WHERE name = $1)
    ,
        &[_][]const u8{name},
    ) catch {};

    conn.exec("DELETE FROM groups WHERE name = $1", &[_][]const u8{name}) catch {};
}

fn cleanupDefinitionByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &[_][]const u8{name}) catch {};
}

fn cleanupInstance(pool: *pool_mod.Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
}

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return allocator.dupe(u8, value.string);
}

fn createGroupId(service: *identity_service.Service, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{name});
    defer allocator.free(body);

    const result = identity_routes.handleCreateGroup(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try testing.expectEqual(@as(u16, 201), result.status_code);

    return extractStringField(allocator, result.body, "group_id");
}

fn createUserId(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"username\":\"{s}\",\"display_name\":\"{s}\",\"email\":\"{s}\",\"status\":\"ACTIVE\"}}",
        .{ username, display_name, email },
    );
    defer allocator.free(body);

    const result = identity_routes.handleCreateUser(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try testing.expectEqual(@as(u16, 201), result.status_code);

    return extractStringField(allocator, result.body, "user_id");
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

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

fn makeTaskFixture(
    allocator: std.mem.Allocator,
    def_store: *definition_mod.Store,
    inst_store: *instance_mod.InstanceStore,
    task_store: *task_mod.TaskStore,
    def_name: []const u8,
) !struct { inst_id_hex: []u8, task_id_hex: []u8 } {
    const nodes = [_]definition_mod.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"placeholder\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]definition_mod.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = definition_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(creator_uuid_str);
    const def = try def_store.create(allocator, .{
        .name = def_name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
    }

    const activated = try def_store.activate(allocator, def.id);
    defer {
        allocator.free(activated.name);
        allocator.free(activated.version);
        if (activated.description) |desc| allocator.free(desc);
        if (activated.stage) |stage| allocator.free(stage);
    }

    const inst = try inst_store.create(allocator, def.id, null, "{}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    errdefer allocator.free(inst_id_hex);

    const tasks = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks) |t| task_mod.freeTask(allocator, t);
        allocator.free(tasks);
    }
    try testing.expect(tasks.len > 0);

    const task_id_hex = try uuidToHexStr(allocator, tasks[0].task_id);
    errdefer allocator.free(task_id_hex);

    return .{ .inst_id_hex = inst_id_hex, .task_id_hex = task_id_hex };
}

fn taskListContainsTaskId(allocator: std.mem.Allocator, body: []const u8, task_id: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const root = parsed.value.object;
    const items_val = root.get("items") orelse return error.TestUnexpectedResult;
    if (items_val != .array) return error.TestUnexpectedResult;

    for (items_val.array.items) |item| {
        if (item != .object) continue;
        const task_id_val = item.object.get("task_id") orelse continue;
        if (task_id_val != .string) continue;
        if (std.mem.eql(u8, task_id_val.string, task_id)) return true;
    }
    return false;
}

fn taskListCount(allocator: std.mem.Allocator, body: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const root = parsed.value.object;
    const count_val = root.get("count") orelse return error.TestUnexpectedResult;
    if (count_val != .integer) return error.TestUnexpectedResult;
    return @intCast(count_val.integer);
}

test "TC-IDN-03-03b: TASK_WORKER GET /tasks returns own and group-member tasks only" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = definition_mod.Store.init(alloc, &pool);
    defer def_store.deinit();
    var snap_store = snapshot_mod.SnapshotStore{ .pool = &pool };
    var inst_store = instance_mod.InstanceStore.init(&pool, &snap_store);
    var task_store = task_mod.TaskStore.init(&pool);

    const group_name = "tc-idn-03-03-group";
    const worker_username = "tc-idn-03-03-worker";
    const other_username = "tc-idn-03-03-other";

    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, worker_username);
    cleanupUserByUsername(&pool, other_username);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, worker_username);
    defer cleanupUserByUsername(&pool, other_username);

    const def_name_base = "tc-idn-03-03-def";
    cleanupDefinitionByName(&pool, def_name_base);
    cleanupDefinitionByName(&pool, "tc-idn-03-03-def-2");
    cleanupDefinitionByName(&pool, "tc-idn-03-03-def-3");
    defer cleanupDefinitionByName(&pool, def_name_base);
    defer cleanupDefinitionByName(&pool, "tc-idn-03-03-def-2");
    defer cleanupDefinitionByName(&pool, "tc-idn-03-03-def-3");

    const own_task = try makeTaskFixture(alloc, &def_store, &inst_store, &task_store, def_name_base);
    defer {
        cleanupInstance(&pool, own_task.inst_id_hex);
        alloc.free(own_task.inst_id_hex);
        alloc.free(own_task.task_id_hex);
    }
    const group_task = try makeTaskFixture(alloc, &def_store, &inst_store, &task_store, "tc-idn-03-03-def-2");
    defer {
        cleanupInstance(&pool, group_task.inst_id_hex);
        alloc.free(group_task.inst_id_hex);
        alloc.free(group_task.task_id_hex);
    }
    const other_task = try makeTaskFixture(alloc, &def_store, &inst_store, &task_store, "tc-idn-03-03-def-3");
    defer {
        cleanupInstance(&pool, other_task.inst_id_hex);
        alloc.free(other_task.inst_id_hex);
        alloc.free(other_task.task_id_hex);
    }

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);

    const worker_user_id = try createUserId(&service, alloc, worker_username, "Worker", "tc-idn-03-03-worker@example.com");
    defer alloc.free(worker_user_id);
    const other_user_id = try createUserId(&service, alloc, other_username, "Other", "tc-idn-03-03-other@example.com");
    defer alloc.free(other_user_id);

    const add_worker_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{worker_user_id});
    defer alloc.free(add_worker_body);
    const add_result = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_worker_body);
    defer freeRouteBody(alloc, add_result.body);
    try testing.expectEqual(@as(u16, 201), add_result.status_code);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        "UPDATE tasks SET assignee_type = 'USER', assignee_ref = $2 WHERE id = $1::uuid",
        &.{ own_task.task_id_hex, worker_user_id },
    );
    try conn.exec(
        "UPDATE tasks SET assignee_type = 'GROUP', assignee_ref = $2 WHERE id = $1::uuid",
        &.{ group_task.task_id_hex, group_id },
    );
    try conn.exec(
        "UPDATE tasks SET assignee_type = 'USER', assignee_ref = $2 WHERE id = $1::uuid",
        &.{ other_task.task_id_hex, other_user_id },
    );

    const result = bpm.task_routes.handleList(
        &task_store,
        alloc,
        taskWorkerActor(worker_user_id),
        .{
            .assignee_id = null,
            .status = null,
            .instance_id = null,
            .cursor = null,
            .page_size = 50,
        },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const count = try taskListCount(alloc, result.body);
    try testing.expect(count >= 2);
    try testing.expect(try taskListContainsTaskId(alloc, result.body, own_task.task_id_hex));
    try testing.expect(try taskListContainsTaskId(alloc, result.body, group_task.task_id_hex));
    try testing.expect(!(try taskListContainsTaskId(alloc, result.body, other_task.task_id_hex)));
}
