//! Integration tests for IDN-01 user registry create-user behavior.
//!
//! These tests exercise identity route + service + registry against a real
//! PostgreSQL database via the project pool implementation.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;

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
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-idn01",
        .principal = "integration-idn01",
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

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

fn expectUuidLike(value: []const u8) !void {
    try testing.expectEqual(@as(usize, 36), value.len);
    try testing.expectEqual(@as(u8, '-'), value[8]);
    try testing.expectEqual(@as(u8, '-'), value[13]);
    try testing.expectEqual(@as(u8, '-'), value[18]);
    try testing.expectEqual(@as(u8, '-'), value[23]);
}

test "TC-IDN-01-01: create-user success returns 201 with platform-assigned user_id and created_at" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"username\":\"tc-idn-01-01-user\"," ++
        "\"display_name\":\"IDN 01 User\"," ++
        "\"email\":\"tc-idn-01-01@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";

    const result = identity_routes.handleCreateUser(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const user_id = obj.get("user_id") orelse return error.TestUnexpectedResult;
    const created_at = obj.get("created_at") orelse return error.TestUnexpectedResult;
    const status = obj.get("status") orelse return error.TestUnexpectedResult;

    try testing.expect(user_id == .string);
    try testing.expect(created_at == .string);
    try testing.expect(status == .string);
    try expectUuidLike(user_id.string);
    try testing.expect(created_at.string.len > 0);
    try testing.expectEqualStrings("ACTIVE", status.string);
}

test "TC-IDN-01-02: duplicate username returns HTTP 409" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-02-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first_body =
        "{" ++
        "\"username\":\"tc-idn-01-02-user\"," ++
        "\"display_name\":\"Duplicate One\"," ++
        "\"email\":\"tc-idn-01-02-a@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const first = identity_routes.handleCreateUser(&service, alloc, adminActor(), first_body);
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 201), first.status_code);

    const second_body =
        "{" ++
        "\"username\":\"tc-idn-01-02-user\"," ++
        "\"display_name\":\"Duplicate Two\"," ++
        "\"email\":\"tc-idn-01-02-b@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";
    const second = identity_routes.handleCreateUser(&service, alloc, adminActor(), second_body);
    defer freeRouteBody(alloc, second.body);

    try testing.expectEqual(@as(u16, 409), second.status_code);
    try testing.expect(std.mem.indexOf(u8, second.body, "duplicate_username") != null);
}

test "TC-IDN-01-03: invalid email returns HTTP 422" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-03-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"username\":\"tc-idn-01-03-user\"," ++
        "\"display_name\":\"Invalid Email\"," ++
        "\"email\":\"not-an-email\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";

    const result = identity_routes.handleCreateUser(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "validation_failed") != null);
}

test "TC-IDN-01-04: caller-provided user_id or created_at returns HTTP 422" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-04-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"user_id\":\"11111111-1111-1111-1111-111111111111\"," ++
        "\"created_at\":\"2026-01-01T00:00:00Z\"," ++
        "\"username\":\"tc-idn-01-04-user\"," ++
        "\"display_name\":\"Caller Fields\"," ++
        "\"email\":\"tc-idn-01-04@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";

    const result = identity_routes.handleCreateUser(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "validation_failed") != null);
}

test "TC-IDN-01-05: create-user with INACTIVE status is allowed" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-05-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"username\":\"tc-idn-01-05-user\"," ++
        "\"display_name\":\"Inactive Allowed\"," ++
        "\"email\":\"tc-idn-01-05@example.com\"," ++
        "\"status\":\"INACTIVE\"" ++
        "}";

    const result = identity_routes.handleCreateUser(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const status = obj.get("status") orelse return error.TestUnexpectedResult;
    try testing.expect(status == .string);
    try testing.expectEqualStrings("INACTIVE", status.string);
}
