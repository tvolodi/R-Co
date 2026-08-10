//! Integration tests for IDN-04 API token management.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;

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

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

/// ISS-0659 / GH-681: self-managed-pool binary must serialize against
/// TestHarness peers via the bpm_test_migrations_public advisory lock for the
/// binary's full lifetime. PR #494 / ISS-0162 extended this lock inside
/// TestHarness.init(); this entry point lets a makePool-based binary acquire
/// the same lock around its own test block. Pair with
/// `helpers.releaseIntegrationLock(&lock_conn)` via defer at the top of every
/// `test` block.
fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-idn04-admin",
        .principal = "integration-idn04-admin",
    };
}

fn workerActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000002",
        .role = .TASK_WORKER,
        .is_bootstrap = false,
        .token_id = "integration-idn04-worker",
        .principal = "integration-idn04-worker",
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

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return allocator.dupe(u8, value.string);
}

fn createActiveUserId(
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

fn sha256Hex(allocator: std.mem.Allocator, token_value: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token_value, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
}

test "TC-IDN-04-01: issue token returns one-time token value and persists only hash" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-04-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user_id = try createActiveUserId(&service, alloc, username, "IDN04 User 01", "tc-idn-04-01@example.com");
    defer alloc.free(user_id);

    const create_body = try std.fmt.allocPrint(
        alloc,
        "{{\"user_id\":\"{s}\",\"roles\":[\"PROCESS_OPERATOR\",\"TASK_WORKER\"],\"expires_at\":null}}",
        .{user_id},
    );
    defer alloc.free(create_body);

    const create_result = identity_routes.handleCreateToken(&service, alloc, adminActor(), create_body);
    defer freeRouteBody(alloc, create_result.body);
    try testing.expectEqual(@as(u16, 201), create_result.status_code);

    const token_id = try extractStringField(alloc, create_result.body, "token_id");
    defer alloc.free(token_id);
    const token_value = try extractStringField(alloc, create_result.body, "token_value");
    defer alloc.free(token_value);
    try expectUuidLike(token_id);
    try testing.expect(token_value.len > 16);

    const expected_hash = try sha256Hex(alloc, token_value);
    defer alloc.free(expected_hash);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const hash_row = (try conn.queryRow(
        alloc,
        "SELECT token_hash FROM api_tokens WHERE id = $1::uuid",
        &[_][]const u8{token_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (hash_row[0]) |v| alloc.free(v);
        alloc.free(hash_row);
    }

    const persisted_hash = hash_row[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 64), persisted_hash.len);
    try testing.expectEqualStrings(expected_hash, persisted_hash);
    try testing.expect(!std.mem.eql(u8, token_value, persisted_hash));

    const list_result = identity_routes.handleListTokens(&service, alloc, adminActor());
    defer freeRouteBody(alloc, list_result.body);
    try testing.expectEqual(@as(u16, 200), list_result.status_code);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"token_value\"") == null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, token_value) == null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, token_id) != null);
}

test "TC-IDN-04-02: create token with past expires_at returns 422" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-04-02-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user_id = try createActiveUserId(&service, alloc, username, "IDN04 User 02", "tc-idn-04-02@example.com");
    defer alloc.free(user_id);

    const create_body = try std.fmt.allocPrint(
        alloc,
        "{{\"user_id\":\"{s}\",\"roles\":[\"TASK_WORKER\"],\"expires_at\":\"2000-01-01T00:00:00Z\"}}",
        .{user_id},
    );
    defer alloc.free(create_body);

    const create_result = identity_routes.handleCreateToken(&service, alloc, adminActor(), create_body);
    defer freeRouteBody(alloc, create_result.body);
    try testing.expectEqual(@as(u16, 422), create_result.status_code);
    try testing.expect(std.mem.indexOf(u8, create_result.body, "validation_failed") != null);
}

test "TC-IDN-04-03: revoke token is idempotent and list status shows revoked" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-04-03-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user_id = try createActiveUserId(&service, alloc, username, "IDN04 User 03", "tc-idn-04-03@example.com");
    defer alloc.free(user_id);

    const create_body = try std.fmt.allocPrint(
        alloc,
        "{{\"user_id\":\"{s}\",\"roles\":[\"TASK_WORKER\"],\"expires_at\":null}}",
        .{user_id},
    );
    defer alloc.free(create_body);

    const create_result = identity_routes.handleCreateToken(&service, alloc, adminActor(), create_body);
    defer freeRouteBody(alloc, create_result.body);
    try testing.expectEqual(@as(u16, 201), create_result.status_code);

    const token_id = try extractStringField(alloc, create_result.body, "token_id");
    defer alloc.free(token_id);

    const revoke_first = identity_routes.handleRevokeToken(&service, alloc, adminActor(), token_id);
    defer freeRouteBody(alloc, revoke_first.body);
    try testing.expectEqual(@as(u16, 204), revoke_first.status_code);

    const revoke_second = identity_routes.handleRevokeToken(&service, alloc, adminActor(), token_id);
    defer freeRouteBody(alloc, revoke_second.body);
    try testing.expectEqual(@as(u16, 204), revoke_second.status_code);

    const list_result = identity_routes.handleListTokens(&service, alloc, adminActor());
    defer freeRouteBody(alloc, list_result.body);
    try testing.expectEqual(@as(u16, 200), list_result.status_code);
    try testing.expect(std.mem.indexOf(u8, list_result.body, token_id) != null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"status\":\"REVOKED\"") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"revoked_at\":null") == null);
}

test "TC-IDN-04-05: optional expiry and role claims are persisted in metadata" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-04-05-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user_id = try createActiveUserId(&service, alloc, username, "IDN04 User 05", "tc-idn-04-05@example.com");
    defer alloc.free(user_id);

    const create_body = try std.fmt.allocPrint(
        alloc,
        "{{\"user_id\":\"{s}\",\"roles\":[\"TASK_WORKER\",\"PROCESS_OPERATOR\"],\"expires_at\":null}}",
        .{user_id},
    );
    defer alloc.free(create_body);

    const create_result = identity_routes.handleCreateToken(&service, alloc, adminActor(), create_body);
    defer freeRouteBody(alloc, create_result.body);
    try testing.expectEqual(@as(u16, 201), create_result.status_code);

    const list_result = identity_routes.handleListTokens(&service, alloc, adminActor());
    defer freeRouteBody(alloc, list_result.body);
    try testing.expectEqual(@as(u16, 200), list_result.status_code);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"PROCESS_OPERATOR\"") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"TASK_WORKER\"") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.body, "\"expires_at\":null") != null);

    const invalid_roles_result = identity_routes.handleCreateToken(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"user_id\":\"00000000-0000-0000-0000-000000000000\"," ++
            "\"roles\":[\"VIEWER\"]," ++
            "\"expires_at\":null" ++
            "}",
    );
    defer freeRouteBody(alloc, invalid_roles_result.body);
    try testing.expectEqual(@as(u16, 422), invalid_roles_result.status_code);
}

test "TC-IDN-04-06: token endpoints require PLATFORM_ADMIN" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-04-06-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user_id = try createActiveUserId(&service, alloc, username, "IDN04 User 06", "tc-idn-04-06@example.com");
    defer alloc.free(user_id);

    const create_body = try std.fmt.allocPrint(
        alloc,
        "{{\"user_id\":\"{s}\",\"roles\":[\"TASK_WORKER\"],\"expires_at\":null}}",
        .{user_id},
    );
    defer alloc.free(create_body);

    const create_forbidden = identity_routes.handleCreateToken(&service, alloc, workerActor(), create_body);
    defer freeRouteBody(alloc, create_forbidden.body);
    try testing.expectEqual(@as(u16, 403), create_forbidden.status_code);

    const admin_create = identity_routes.handleCreateToken(&service, alloc, adminActor(), create_body);
    defer freeRouteBody(alloc, admin_create.body);
    try testing.expectEqual(@as(u16, 201), admin_create.status_code);

    const token_id = try extractStringField(alloc, admin_create.body, "token_id");
    defer alloc.free(token_id);

    const list_forbidden = identity_routes.handleListTokens(&service, alloc, workerActor());
    defer freeRouteBody(alloc, list_forbidden.body);
    try testing.expectEqual(@as(u16, 403), list_forbidden.status_code);

    const revoke_forbidden = identity_routes.handleRevokeToken(&service, alloc, workerActor(), token_id);
    defer freeRouteBody(alloc, revoke_forbidden.body);
    try testing.expectEqual(@as(u16, 403), revoke_forbidden.status_code);
}
