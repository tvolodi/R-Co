//! Integration tests for ADP-07 agent role and reserved usernames.

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

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

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
        .token_id = "integration-adp07-admin",
        .principal = "integration-adp07-admin",
    };
}

fn workerActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000002",
        .role = .TASK_WORKER,
        .is_bootstrap = false,
        .token_id = "integration-adp07-worker",
        .principal = "integration-adp07-worker",
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

fn ensureTenantBinding(pool: *pool_mod.Pool, tenant_id: []const u8, slug: []const u8, display_name: []const u8, realm: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
        \\ON CONFLICT (id) DO UPDATE
        \\SET slug = EXCLUDED.slug,
        \\    display_name = EXCLUDED.display_name,
        \\    status = 'ACTIVE',
        \\    idp_realm_id = EXCLUDED.idp_realm_id,
        \\    updated_at = NOW()
    ,
        &[_][]const u8{ tenant_id, slug, display_name, realm, "00000000-0000-0000-0000-000000000000" },
    );
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

test "TC-ADP-07-01: AGENT_RUNNER role is seeded and token issuance accepts it" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-adp-07-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const user = try service.createUser(alloc, adminActor(), .{
        .tenant_id = null,
        .username = username,
        .display_name = "ADP07 Role Seed User",
        .email = "tc-adp-07-01@example.com",
        .status = .ACTIVE,
        .caller_supplied_user_id = false,
        .caller_supplied_created_at = false,
    });
    defer user.deinit(alloc);

    const issued = try service.issueToken(alloc, adminActor(), .{
        .user_id = user.user_id,
        .roles = &[_]auth_mod.Role{.AGENT_RUNNER},
        .expires_at = null,
    });
    defer issued.deinit(alloc);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const role_row = (try conn.queryRow(
        alloc,
        "SELECT name FROM roles WHERE name = 'AGENT_RUNNER'",
        &[_][]const u8{},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, role_row);
    try testing.expectEqualStrings("AGENT_RUNNER", role_row[0] orelse return error.TestUnexpectedResult);

    const token_row = (try conn.queryRow(
        alloc,
        "SELECT roles_json::text FROM api_tokens WHERE id = $1::uuid",
        &[_][]const u8{issued.token_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, token_row);
    const roles_json = token_row[0] orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, roles_json, "AGENT_RUNNER") != null);
}

test "TC-ADP-07-02: non-admin actor cannot create agent-prefixed usernames" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = service.createUser(alloc, workerActor(), .{
        .tenant_id = null,
        .username = "AgEnT:tc-adp-07-02",
        .display_name = "ADP07 Worker Agent",
        .email = "tc-adp-07-02@example.com",
        .status = .ACTIVE,
        .caller_supplied_user_id = false,
        .caller_supplied_created_at = false,
    });

    try testing.expectError(identity_service.IdentityError.ReservedUsernameRequiresPlatformAdmin, result);
}

test "TC-ADP-07-03: PLATFORM_ADMIN actor can create agent-prefixed usernames" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "agent:tc-adp-07-03";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try service.createUser(alloc, adminActor(), .{
        .tenant_id = null,
        .username = username,
        .display_name = "ADP07 Admin Agent",
        .email = "tc-adp-07-03@example.com",
        .status = .ACTIVE,
        .caller_supplied_user_id = false,
        .caller_supplied_created_at = false,
    });
    defer created.deinit(alloc);

    try testing.expectEqualStrings(username, created.username);
}

test "TC-ADP-07-04: JIT OIDC path rejects reserved agent username prefix" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

// GH-512 retention: doc-identity fixture (matched against substring assertions in payload/correlation_id checks)
    try ensureTenantBinding(&pool, "33333333-3333-3333-3333-333333333333", "adp07-tenant", "ADP07 Tenant", "kc-realm-adp07");

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = "33333333-3333-3333-3333-333333333333",
        .external_realm = "kc-realm-adp07",
        .external_id = "sub-adp07-04",
        .preferred_username = "agent:jit-adp07",
        .display_name = "ADP07 JIT Agent",
        .email = "tc-adp-07-04@example.com",
        .status = .ACTIVE,
    });

    try testing.expectError(identity_service.IdentityError.ReservedUsernameRequiresPlatformAdmin, result);
}

test "TC-ADP-07-05: non-agent usernames remain compatible on create path" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-adp-07-05-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    // Regression guard: non-agent usernames must keep existing behavior.
    const created = try service.createUser(alloc, adminActor(), .{
        .tenant_id = null,
        .username = username,
        .display_name = "ADP07 Non Agent Compatibility",
        .email = "tc-adp-07-05@example.com",
        .status = .ACTIVE,
        .caller_supplied_user_id = false,
        .caller_supplied_created_at = false,
    });
    defer created.deinit(alloc);

    try testing.expectEqualStrings(username, created.username);
}
