//! Integration tests for IDN-02 group management.
//!
//! These tests exercise the identity routes, identity service, registry, and
//! task completion authorization against a real PostgreSQL database.

const std = @import("std");
const portable_env = @import("env");
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

/// Per-test-run "created_by" UUID — generated fresh instead of a fixed
/// literal so this fixture follows the per-test-UUID isolation convention
/// (see docs/guides/test_infrastructure_guide.md §9 / ISS-0121).
fn makeCreatorUuid() [16]u8 {
    var bytes: bpm.uuid.Uuid = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return bytes;
}

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

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-idn02-admin",
        .principal = "integration-idn02-admin",
    };
}

fn taskWorkerActor(user_id: []const u8) bpm.task_routes.Actor {
    return .{
        .user_id = user_id,
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };
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

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
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

fn expectUuidLike(value: []const u8) !void {
    try testing.expectEqual(@as(usize, 36), value.len);
    try testing.expectEqual(@as(u8, '-'), value[8]);
    try testing.expectEqual(@as(u8, '-'), value[13]);
    try testing.expectEqual(@as(u8, '-'), value[18]);
    try testing.expectEqual(@as(u8, '-'), value[23]);
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
    status: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"username\":\"{s}\",\"display_name\":\"{s}\",\"email\":\"{s}\",\"status\":\"{s}\"}}",
        .{ username, display_name, email, status },
    );
    defer allocator.free(body);

    const result = identity_routes.handleCreateUser(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try testing.expectEqual(@as(u16, 201), result.status_code);

    return extractStringField(allocator, result.body, "user_id");
}

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return allocator.dupe(u8, value.string);
}

fn makeGroupTaskFixture(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    def_store: *definition_mod.Store,
    inst_store: *instance_mod.InstanceStore,
    task_store: *task_mod.TaskStore,
    def_name: []const u8,
) !struct { inst_id_hex: []u8, task_id_hex: []u8 } {
    _ = pool;
    const nodes = [_]definition_mod.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Group task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"placeholder\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]definition_mod.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = definition_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = makeCreatorUuid();
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
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }

    const activated = try def_store.activate(allocator, def.id);
    defer {
        allocator.free(activated.name);
        allocator.free(activated.version);
        if (activated.description) |desc| allocator.free(desc);
        if (activated.stage) |stage| allocator.free(stage);
        bpm.definition.freeDefinitionGraph(allocator, activated.graph);
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

test "TC-IDN-02-01: create-group success returns 201 with platform-assigned group_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-01-group";
    cleanupGroupByName(&pool, group_name);
    defer cleanupGroupByName(&pool, group_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(body);

    const result = identity_routes.handleCreateGroup(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const group_id = obj.get("group_id") orelse return error.TestUnexpectedResult;
    const name = obj.get("name") orelse return error.TestUnexpectedResult;
    const created_at = obj.get("created_at") orelse return error.TestUnexpectedResult;
    try testing.expect(group_id == .string);
    try testing.expect(name == .string);
    try testing.expect(created_at == .string);
    try expectUuidLike(group_id.string);
    try testing.expectEqualStrings(group_name, name.string);
    try testing.expect(created_at.string.len > 0);
}

test "TC-IDN-02-02: duplicate group name returns HTTP 409" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-02-group";
    cleanupGroupByName(&pool, group_name);
    defer cleanupGroupByName(&pool, group_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(first_body);
    const first = identity_routes.handleCreateGroup(&service, alloc, adminActor(), first_body);
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 201), first.status_code);

    const second_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(second_body);
    const second = identity_routes.handleCreateGroup(&service, alloc, adminActor(), second_body);
    defer freeRouteBody(alloc, second.body);

    try testing.expectEqual(@as(u16, 409), second.status_code);
    try testing.expect(std.mem.indexOf(u8, second.body, "duplicate_group_name") != null);
}

test "TC-IDN-02-03: add-member is idempotent for duplicate membership insertion" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-03-group";
    const username = "tc-idn-02-03-user";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, username);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id = try createUserId(&service, alloc, username, "Group User", "tc-idn-02-03@example.com", "ACTIVE");
    defer alloc.free(user_id);

    const add_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id});
    defer alloc.free(add_body);

    const first = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 201), first.status_code);
    try testing.expect(std.mem.indexOf(u8, first.body, "\"created\":true") != null);

    const second = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);
    defer freeRouteBody(alloc, second.body);
    try testing.expectEqual(@as(u16, 200), second.status_code);
    try testing.expect(std.mem.indexOf(u8, second.body, "\"created\":false") != null);
}

test "TC-IDN-02-04: missing user or missing group returns HTTP 404" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-04-group";
    const username = "tc-idn-02-04-user";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, username);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id = try createUserId(&service, alloc, username, "Group User", "tc-idn-02-04@example.com", "ACTIVE");
    defer alloc.free(user_id);

    const add_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id});
    defer alloc.free(add_body);

    const missing_user = identity_routes.handleAddGroupMember(
        &service,
        alloc,
        adminActor(),
        group_id,
        "{\"user_id\":\"11111111-1111-1111-1111-111111111111\"}",
    );
    defer freeRouteBody(alloc, missing_user.body);
    try testing.expectEqual(@as(u16, 404), missing_user.status_code);

    const missing_group = identity_routes.handleAddGroupMember(
        &service,
        alloc,
        adminActor(),
        "11111111-1111-1111-1111-111111111111",
        add_body,
    );
    defer freeRouteBody(alloc, missing_group.body);
    try testing.expectEqual(@as(u16, 404), missing_group.status_code);
}

test "TC-IDN-02-05: group members are returned in paginated order" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-04-group";
    const user_one = "tc-idn-02-04-user-1";
    const user_two = "tc-idn-02-04-user-2";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, user_one);
    cleanupUserByUsername(&pool, user_two);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, user_one);
    defer cleanupUserByUsername(&pool, user_two);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id_one = try createUserId(&service, alloc, user_one, "Group One", "tc-idn-02-04-1@example.com", "ACTIVE");
    defer alloc.free(user_id_one);
    const user_id_two = try createUserId(&service, alloc, user_two, "Group Two", "tc-idn-02-04-2@example.com", "ACTIVE");
    defer alloc.free(user_id_two);

    const add_one = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id_one});
    defer alloc.free(add_one);
    const add_two = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id_two});
    defer alloc.free(add_two);

    const add_result_one = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_one);
    defer freeRouteBody(alloc, add_result_one.body);
    try testing.expectEqual(@as(u16, 201), add_result_one.status_code);

    const add_result_two = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_two);
    defer freeRouteBody(alloc, add_result_two.body);
    try testing.expectEqual(@as(u16, 201), add_result_two.status_code);

    const first_page = try registry.listGroupMemberRecords(alloc, auth_mod.DEFAULT_TENANT_ID, group_id, null, null, 1);
    defer {
        for (first_page) |record| record.deinit(alloc);
        alloc.free(first_page);
    }
    try testing.expectEqual(@as(usize, 2), first_page.len);
    try testing.expectEqualStrings(user_two, first_page[0].member.username);

    const second_page = try registry.listGroupMemberRecords(
        alloc,
        auth_mod.DEFAULT_TENANT_ID,
        group_id,
        first_page[0].added_at_us,
        first_page[0].member.user_id,
        1,
    );
    defer {
        for (second_page) |record| record.deinit(alloc);
        alloc.free(second_page);
    }
    try testing.expectEqual(@as(usize, 1), second_page.len);
    try testing.expectEqualStrings(user_one, second_page[0].member.username);
}

test "TC-IDN-02-06: ACTIVE group member can claim and complete a GROUP-assigned task" {
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

    const group_name = "tc-idn-02-05-group";
    const active_user = "tc-idn-02-05-active";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, active_user);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, active_user);

    const def_name = "tc-idn-02-05-def";
    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);

    const fixture = try makeGroupTaskFixture(alloc, &pool, &def_store, &inst_store, &task_store, def_name);
    defer {
        cleanupInstance(&pool, fixture.inst_id_hex);
        alloc.free(fixture.inst_id_hex);
        alloc.free(fixture.task_id_hex);
    }

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const active_user_id = try createUserId(&service, alloc, active_user, "Active User", "tc-idn-02-05@example.com", "ACTIVE");
    defer alloc.free(active_user_id);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE tasks SET assignee_type = 'GROUP', assignee_ref = $2 WHERE id = $1::uuid",
            &.{ fixture.task_id_hex, group_id },
        );
    }

    const before = try service.canClaimGroupTask(alloc, auth_mod.DEFAULT_TENANT_ID, group_id, active_user_id);
    try testing.expect(!before);

    const add_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{active_user_id});
    defer alloc.free(add_body);
    const add_result = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);
    defer freeRouteBody(alloc, add_result.body);
    try testing.expectEqual(@as(u16, 201), add_result.status_code);

    try testing.expect(try service.canClaimGroupTask(alloc, auth_mod.DEFAULT_TENANT_ID, group_id, active_user_id));

    const complete = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &service,
        alloc,
        taskWorkerActor(active_user_id),
        fixture.task_id_hex,
        "{\"output_variables\":{}}",
    );
    defer freeRouteBody(alloc, complete.body);
    try testing.expectEqual(@as(u16, 200), complete.status_code);

    const task_row = try task_store.getById(alloc, try parseUuid(alloc, fixture.task_id_hex));
    defer task_mod.freeTask(alloc, task_row);
    try testing.expectEqual(task_mod.TaskStatus.COMPLETED, task_row.status);
}

test "TC-IDN-02-07: removing a member does not mutate an already-assigned GROUP task" {
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

    const group_name = "tc-idn-02-06-group";
    const user_a = "tc-idn-02-06-user-a";
    const user_b = "tc-idn-02-06-user-b";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, user_a);
    cleanupUserByUsername(&pool, user_b);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, user_a);
    defer cleanupUserByUsername(&pool, user_b);

    const def_name = "tc-idn-02-06-def";
    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);

    const fixture = try makeGroupTaskFixture(alloc, &pool, &def_store, &inst_store, &task_store, def_name);
    defer {
        cleanupInstance(&pool, fixture.inst_id_hex);
        alloc.free(fixture.inst_id_hex);
        alloc.free(fixture.task_id_hex);
    }

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_a_id = try createUserId(&service, alloc, user_a, "Group User A", "tc-idn-02-06-a@example.com", "ACTIVE");
    defer alloc.free(user_a_id);
    const user_b_id = try createUserId(&service, alloc, user_b, "Group User B", "tc-idn-02-06-b@example.com", "ACTIVE");
    defer alloc.free(user_b_id);

    const add_a = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_a_id});
    defer alloc.free(add_a);
    const add_b = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_b_id});
    defer alloc.free(add_b);

    const add_result_a = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_a);
    defer freeRouteBody(alloc, add_result_a.body);
    try testing.expectEqual(@as(u16, 201), add_result_a.status_code);

    const add_result_b = identity_routes.handleAddGroupMember(&service, alloc, adminActor(), group_id, add_b);
    defer freeRouteBody(alloc, add_result_b.body);
    try testing.expectEqual(@as(u16, 201), add_result_b.status_code);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE tasks SET assignee_type = 'GROUP', assignee_ref = $2 WHERE id = $1::uuid",
            &.{ fixture.task_id_hex, group_id },
        );
    }

    const remove = identity_routes.handleRemoveGroupMember(&service, alloc, adminActor(), group_id, user_a_id);
    defer freeRouteBody(alloc, remove.body);
    try testing.expectEqual(@as(u16, 204), remove.status_code);

    const conn2 = try pool.acquire();
    defer pool.release(conn2);
    const task_row = try conn2.query(
        alloc,
        "SELECT assignee_type, assignee_ref, status FROM tasks WHERE id = $1::uuid",
        &.{fixture.task_id_hex},
    );
    defer {
        var r = task_row;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), task_row.rows.len);
    try testing.expectEqualStrings("GROUP", task_row.rows[0][0] orelse "");
    try testing.expectEqualStrings(group_id, task_row.rows[0][1] orelse "");
    try testing.expectEqualStrings("PENDING", task_row.rows[0][2] orelse "");

    try testing.expect(!(try service.canClaimGroupTask(alloc, auth_mod.DEFAULT_TENANT_ID, group_id, user_a_id)));
    try testing.expect(try service.canClaimGroupTask(alloc, auth_mod.DEFAULT_TENANT_ID, group_id, user_b_id));

    const complete = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &service,
        alloc,
        taskWorkerActor(user_b_id),
        fixture.task_id_hex,
        "{\"output_variables\":{}}",
    );
    defer freeRouteBody(alloc, complete.body);
    try testing.expectEqual(@as(u16, 200), complete.status_code);
}
