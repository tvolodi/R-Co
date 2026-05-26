//! Integration tests for ADP-04 user tenant binding and tenant-safe
//! identity/group operations.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;

const tenant_a = "11111111-1111-1111-1111-111111111111";
const tenant_b = "22222222-2222-2222-2222-222222222222";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn actorForTenant(tenant_id: []const u8, token_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = token_id,
        .tenant_id = uuid36ToArray(tenant_id),
        .tenant_source = .token_claim,
    };
}

fn uuid36ToArray(value: []const u8) [36]u8 {
    var out: [36]u8 = undefined;
    @memcpy(out[0..], value);
    return out;
}

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return allocator.dupe(u8, value.string);
}

fn cleanupUserByUsername(pool: *pool_mod.Pool, username: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM group_members
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

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

test "TC-ADP-04-01: user creation without explicit tenant_id binds to actor tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-adp-04-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"username\":\"tc-adp-04-01-user\"," ++
        "\"display_name\":\"ADP04 Default Tenant\"," ++
        "\"email\":\"tc-adp-04-01@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";

    const result = identity_routes.handleCreateUser(&service, alloc, actorForTenant(auth_mod.DEFAULT_TENANT_ID, "adp04-actor-default"), body);
    defer freeRouteBody(alloc, result.body);
    try testing.expectEqual(@as(u16, 201), result.status_code);

    const user_id = try extractStringField(alloc, result.body, "user_id");
    defer alloc.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT tenant_id::text FROM users WHERE id = $1::uuid",
        &[_][]const u8{user_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const persisted_tenant = row[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(auth_mod.DEFAULT_TENANT_ID, persisted_tenant);
}

test "TC-ADP-04-02: cross-tenant group membership add is blocked" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-adp-04-02-group-a";
    const user_a = "tc-adp-04-02-user-a";
    const user_b = "tc-adp-04-02-user-b";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, user_a);
    cleanupUserByUsername(&pool, user_b);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, user_a);
    defer cleanupUserByUsername(&pool, user_b);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const actor_a = actorForTenant(tenant_a, "adp04-actor-a");
    const actor_b = actorForTenant(tenant_b, "adp04-actor-b");

    const group_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(group_body);
    const group_res = identity_routes.handleCreateGroup(&service, alloc, actor_a, group_body);
    defer freeRouteBody(alloc, group_res.body);
    try testing.expectEqual(@as(u16, 201), group_res.status_code);
    const group_id = try extractStringField(alloc, group_res.body, "group_id");
    defer alloc.free(group_id);

    const user_a_body =
        "{" ++
        "\"username\":\"tc-adp-04-02-user-a\"," ++
        "\"display_name\":\"Tenant A User\"," ++
        "\"email\":\"tc-adp-04-02-a@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const user_a_res = identity_routes.handleCreateUser(&service, alloc, actor_a, user_a_body);
    defer freeRouteBody(alloc, user_a_res.body);
    try testing.expectEqual(@as(u16, 201), user_a_res.status_code);
    const user_a_id = try extractStringField(alloc, user_a_res.body, "user_id");
    defer alloc.free(user_a_id);

    const user_b_body =
        "{" ++
        "\"username\":\"tc-adp-04-02-user-b\"," ++
        "\"display_name\":\"Tenant B User\"," ++
        "\"email\":\"tc-adp-04-02-b@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const user_b_res = identity_routes.handleCreateUser(&service, alloc, actor_b, user_b_body);
    defer freeRouteBody(alloc, user_b_res.body);
    try testing.expectEqual(@as(u16, 201), user_b_res.status_code);
    const user_b_id = try extractStringField(alloc, user_b_res.body, "user_id");
    defer alloc.free(user_b_id);

    const add_a_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_a_id});
    defer alloc.free(add_a_body);
    const add_a = identity_routes.handleAddGroupMember(&service, alloc, actor_a, group_id, add_a_body);
    defer freeRouteBody(alloc, add_a.body);
    try testing.expectEqual(@as(u16, 201), add_a.status_code);

    const add_b_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_b_id});
    defer alloc.free(add_b_body);
    const cross = identity_routes.handleAddGroupMember(&service, alloc, actor_a, group_id, add_b_body);
    defer freeRouteBody(alloc, cross.body);
    try testing.expectEqual(@as(u16, 404), cross.status_code);
    try testing.expect(std.mem.indexOf(u8, cross.body, "user_not_found") != null);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const count_row = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM group_members WHERE group_id = $1::uuid AND user_id = $2::uuid",
        &[_][]const u8{ group_id, user_b_id },
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, count_row);

    const count_str = count_row[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(u32, count_str, 10);
    try testing.expectEqual(@as(u32, 0), count);
}

test "TC-ADP-04-03: legacy user row defaults to default tenant and remains tenant-scoped" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const legacy_username = "tc-adp-04-03-legacy-user";
    cleanupUserByUsername(&pool, legacy_username);
    defer cleanupUserByUsername(&pool, legacy_username);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1, $2, '', TRUE, $3, 'ACTIVE')
    , &[_][]const u8{
        "tc-adp-04-03@example.com",
        "Legacy Default Tenant User",
        legacy_username,
    });

    const row = (try conn.queryRow(
        alloc,
        "SELECT id::text, tenant_id::text FROM users WHERE username = $1",
        &[_][]const u8{legacy_username},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const user_id = row[0] orelse return error.TestUnexpectedResult;
    const persisted_tenant = row[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(auth_mod.DEFAULT_TENANT_ID, persisted_tenant);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const default_status = try service.getUserStatusById(alloc, auth_mod.DEFAULT_TENANT_ID, user_id);
    try testing.expect(default_status != null);
    try testing.expectEqual(identity_registry.UserStatus.ACTIVE, default_status.?);

    const foreign_status = try service.getUserStatusById(alloc, tenant_a, user_id);
    try testing.expect(foreign_status == null);
}

test "TC-ADP-04-04: group claim checks allow same-tenant user and deny cross-tenant user" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-adp-04-04-group-a";
    const user_a = "tc-adp-04-04-user-a";
    const user_b = "tc-adp-04-04-user-b";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, user_a);
    cleanupUserByUsername(&pool, user_b);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, user_a);
    defer cleanupUserByUsername(&pool, user_b);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const actor_a = actorForTenant(tenant_a, "adp04-actor-claim-a");
    const actor_b = actorForTenant(tenant_b, "adp04-actor-claim-b");

    const group_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(group_body);
    const group_res = identity_routes.handleCreateGroup(&service, alloc, actor_a, group_body);
    defer freeRouteBody(alloc, group_res.body);
    try testing.expectEqual(@as(u16, 201), group_res.status_code);
    const group_id = try extractStringField(alloc, group_res.body, "group_id");
    defer alloc.free(group_id);

    const user_a_body =
        "{" ++
        "\"username\":\"tc-adp-04-04-user-a\"," ++
        "\"display_name\":\"Tenant A Claim User\"," ++
        "\"email\":\"tc-adp-04-04-a@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const user_a_res = identity_routes.handleCreateUser(&service, alloc, actor_a, user_a_body);
    defer freeRouteBody(alloc, user_a_res.body);
    try testing.expectEqual(@as(u16, 201), user_a_res.status_code);
    const user_a_id = try extractStringField(alloc, user_a_res.body, "user_id");
    defer alloc.free(user_a_id);

    const user_b_body =
        "{" ++
        "\"username\":\"tc-adp-04-04-user-b\"," ++
        "\"display_name\":\"Tenant B Claim User\"," ++
        "\"email\":\"tc-adp-04-04-b@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const user_b_res = identity_routes.handleCreateUser(&service, alloc, actor_b, user_b_body);
    defer freeRouteBody(alloc, user_b_res.body);
    try testing.expectEqual(@as(u16, 201), user_b_res.status_code);
    const user_b_id = try extractStringField(alloc, user_b_res.body, "user_id");
    defer alloc.free(user_b_id);

    const add_a_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_a_id});
    defer alloc.free(add_a_body);
    const add_a = identity_routes.handleAddGroupMember(&service, alloc, actor_a, group_id, add_a_body);
    defer freeRouteBody(alloc, add_a.body);
    try testing.expectEqual(@as(u16, 201), add_a.status_code);

    try testing.expect(try service.canClaimGroupTask(alloc, tenant_a, group_id, user_a_id));
    try testing.expect(!(try service.canClaimGroupTask(alloc, tenant_a, group_id, user_b_id)));
    try testing.expect(!(try service.canClaimGroupTask(alloc, tenant_b, group_id, user_b_id)));
}
