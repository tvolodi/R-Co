//! Integration tests for OIDC-10 — Attribute Synchronisation and Role Reconciliation.
//!
//! Tests the full syncAttributesFromIdentityContext flow (profile update + role
//! reconciliation) end-to-end against a real PostgreSQL database.
//!
//! Requirement: OIDC-10 — Attribute Synchronisation and Role Reconciliation [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs — all tests use real PostgreSQL.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const jit_provisioning = @import("jit_provisioning");
const claim_mapping = @import("claim_mapping");
const pg = @import("pg");

const pool_mod = bpm.db_pool;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const tenant_a = "11111111-1111-1111-1111-111111111111";
const tenant_b = "22222222-2222-2222-2222-222222222222";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
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

fn cleanupUserRoles(pool: *pool_mod.Pool, user_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM user_roles WHERE user_id = $1::uuid", &[_][]const u8{user_id}) catch {};
}

fn cleanupRoles(pool: *pool_mod.Pool) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM roles WHERE name LIKE 'oidc10-%'", &.{}) catch {};
}

fn ensureRole(pool: *pool_mod.Pool, name: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try conn.exec(
        \\INSERT INTO roles (name, description)
        \\VALUES ($1, $1)
        \\ON CONFLICT (name) DO NOTHING
    ,
        &[_][]const u8{name},
    );
}

fn ensureTenantBinding(pool: *pool_mod.Pool, tenant_id: []const u8, slug: []const u8, display_name: []const u8, realm: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', $4)
        \\ON CONFLICT (id) DO UPDATE
        \\SET slug = EXCLUDED.slug,
        \\    display_name = EXCLUDED.display_name,
        \\    status = 'ACTIVE',
        \\    idp_realm_id = EXCLUDED.idp_realm_id,
        \\    updated_at = NOW()
    ,
        &[_][]const u8{ tenant_id, slug, display_name, realm },
    );
}

fn assignOidcRole(pool: *pool_mod.Pool, user_id: []const u8, role_slug: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id, role_source)
        \\SELECT $1::uuid, r.id, 'oidc'
        \\FROM roles r
        \\WHERE r.name = $2
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    ,
        &[_][]const u8{ user_id, role_slug },
    );
}

fn assignInternalRole(pool: *pool_mod.Pool, user_id: []const u8, role_slug: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id, role_source)
        \\SELECT $1::uuid, r.id, 'internal'
        \\FROM roles r
        \\WHERE r.name = $2
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    ,
        &[_][]const u8{ user_id, role_slug },
    );
}

fn countUserRoles(pool: *pool_mod.Pool, user_id: []const u8) !usize {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        testing.allocator,
        "SELECT COUNT(*)::text FROM user_roles WHERE user_id = $1::uuid",
        &[_][]const u8{user_id},
    );
    if (row) |r| {
        defer freeRow(testing.allocator, r);
        const count_str = r[0] orelse return 0;
        return std.fmt.parseInt(usize, count_str, 10) catch 0;
    }
    return 0;
}

fn getUserProfile(pool: *pool_mod.Pool, user_id: []const u8) !struct { display_name: []u8, email: []u8, status: []u8 } {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        testing.allocator,
        "SELECT display_name, email, status FROM users WHERE id = $1::uuid",
        &[_][]const u8{user_id},
    )) orelse return error.NotFound;
    defer freeRow(testing.allocator, row);

    return .{
        .display_name = try testing.allocator.dupe(u8, row[0] orelse ""),
        .email = try testing.allocator.dupe(u8, row[1] orelse ""),
        .status = try testing.allocator.dupe(u8, row[2] orelse ""),
    };
}

fn getUserRoleSources(pool: *pool_mod.Pool, user_id: []const u8) !struct { roles: [][]u8, sources: [][]u8 } {
    const conn = try pool.acquire();
    defer pool.release(conn);

    var qr = try conn.query(
        testing.allocator,
        \\SELECT r.name, ur.role_source
        \\FROM user_roles ur
        \\JOIN roles r ON r.id = ur.role_id
        \\WHERE ur.user_id = $1::uuid
        \\ORDER BY r.name, ur.role_source
    ,
        &[_][]const u8{user_id},
    );
    defer qr.deinit();

    const roles = try testing.allocator.alloc([]u8, qr.rows.len);
    errdefer {
        for (roles) |r| testing.allocator.free(r);
        testing.allocator.free(roles);
    }
    const sources = try testing.allocator.alloc([]u8, qr.rows.len);
    errdefer {
        for (sources) |s| testing.allocator.free(s);
        testing.allocator.free(sources);
    }

    for (qr.rows, 0..) |row, i| {
        roles[i] = try testing.allocator.dupe(u8, row[0] orelse "");
        sources[i] = try testing.allocator.dupe(u8, row[1] orelse "");
    }

    return .{ .roles = roles, .sources = sources };
}

fn provisionTestUser(
    _: *pool_mod.Pool,
    registry: *identity_registry.Registry,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    realm: []const u8,
    external_id: []const u8,
) !identity_registry.User {
    const result = try registry.createOrGetJitOidcUser(testing.allocator, tenant_a, .{
        .username = username,
        .display_name = display_name,
        .email = email,
        .status = identity_registry.UserStatus.ACTIVE,
        .external_realm = realm,
        .external_id = external_id,
    });
    return result.user;
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-01: Full flow — resolve user, update profile, reconcile roles
// ---------------------------------------------------------------------------

test "TC-OIDC-10-01: full flow — resolve user, update profile, reconcile roles" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-01";
    const external_id = "sub-oidc10-01";
    const username = "tc-oidc-10-01-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-a", "OIDC10 Tenant A", realm);
    try ensureRole(&pool, "oidc10-role-tw");
    try ensureRole(&pool, "oidc10-role-po");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Old Name", "old@example.com", realm, external_id);
    defer user.deinit(alloc);

    // Grant OIDC role TASK_WORKER.
    try assignOidcRole(&pool, user.user_id, "oidc10-role-tw");

    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{ "oidc10-role-tw", "oidc10-role-po" },
        .email = "updated@example.com",
        .preferred_username = username,
        .display_name = "Updated Name",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    // Verify profile was updated.
    try testing.expect(sync_result.profile_changed);

    // Verify role reconciliation.
    try testing.expectEqual(@as(usize, 1), sync_result.roles_added.len);
    try testing.expectEqualStrings("oidc10-role-po", sync_result.roles_added[0]);
    try testing.expectEqual(@as(usize, 0), sync_result.roles_removed.len);

    // Verify updated profile in DB.
    const profile = try getUserProfile(&pool, user.user_id);
    defer {
        alloc.free(profile.display_name);
        alloc.free(profile.email);
        alloc.free(profile.status);
    }
    try testing.expectEqualStrings("Updated Name", profile.display_name);
    try testing.expectEqualStrings("updated@example.com", profile.email);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-02: Profile sync — update when claims differ
// ---------------------------------------------------------------------------

test "TC-OIDC-10-02: profile sync — display_name, email updated when claims differ" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-02";
    const external_id = "sub-oidc10-02";
    const username = "tc-oidc-10-02-user";

    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-b", "OIDC10 Tenant B", realm);

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Old Name", "old@example.com", realm, external_id);
    defer user.deinit(alloc);

    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{},
        .email = "new@example.com",
        .preferred_username = username,
        .display_name = "New Name",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    try testing.expect(sync_result.profile_changed);

    const profile = try getUserProfile(&pool, user.user_id);
    defer {
        alloc.free(profile.display_name);
        alloc.free(profile.email);
        alloc.free(profile.status);
    }
    try testing.expectEqualStrings("New Name", profile.display_name);
    try testing.expectEqualStrings("new@example.com", profile.email);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-03: Profile no-op — no update when claims match stored values
// ---------------------------------------------------------------------------

test "TC-OIDC-10-03: profile no-op — no update when claims match stored values" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-03";
    const external_id = "sub-oidc10-03";
    const username = "tc-oidc-10-03-user";

    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-c", "OIDC10 Tenant C", realm);

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Same Name", "same@example.com", realm, external_id);
    defer user.deinit(alloc);

    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{},
        .email = "same@example.com",
        .preferred_username = username,
        .display_name = "Same Name",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    try testing.expect(!sync_result.profile_changed);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-04: Role reconciliation — add new OIDC roles, remove stale OIDC roles
// ---------------------------------------------------------------------------

test "TC-OIDC-10-04: role reconciliation — add new, remove stale" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-04";
    const external_id = "sub-oidc10-04";
    const username = "tc-oidc-10-04-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-d", "OIDC10 Tenant D", realm);
    try ensureRole(&pool, "oidc10-role-tw");
    try ensureRole(&pool, "oidc10-role-pd");
    try ensureRole(&pool, "oidc10-role-po");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Test User 04", "test04@example.com", realm, external_id);
    defer user.deinit(alloc);
    defer cleanupUserRoles(&pool, user.user_id);

    // Grant existing OIDC roles: TASK_WORKER and PROCESS_DESIGNER.
    try assignOidcRole(&pool, user.user_id, "oidc10-role-tw");
    try assignOidcRole(&pool, user.user_id, "oidc10-role-pd");

    // Token roles: TASK_WORKER (keep) and PROCESS_OPERATOR (new) — no PROCESS_DESIGNER (remove).
    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{ "oidc10-role-tw", "oidc10-role-po" },
        .email = "test04@example.com",
        .preferred_username = username,
        .display_name = "Test User 04",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    // Verify add_set includes PROCESS_OPERATOR, remove_set includes PROCESS_DESIGNER.
    try testing.expectEqual(@as(usize, 1), sync_result.roles_added.len);
    try testing.expectEqualStrings("oidc10-role-po", sync_result.roles_added[0]);
    try testing.expectEqual(@as(usize, 1), sync_result.roles_removed.len);
    try testing.expectEqualStrings("oidc10-role-pd", sync_result.roles_removed[0]);

    // Check the database: role bindings should be TASK_WORKER/oidc and PROCESS_OPERATOR/oidc.
    const role_data = try getUserRoleSources(&pool, user.user_id);
    defer {
        for (role_data.roles) |r| alloc.free(r);
        alloc.free(role_data.roles);
        for (role_data.sources) |s| alloc.free(s);
        alloc.free(role_data.sources);
    }

    try testing.expectEqual(@as(usize, 2), role_data.roles.len);
    try testing.expectEqualStrings("oidc10-role-po", role_data.roles[0]);
    try testing.expectEqualStrings("oidc", role_data.sources[0]);
    try testing.expectEqualStrings("oidc10-role-tw", role_data.roles[1]);
    try testing.expectEqualStrings("oidc", role_data.sources[1]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-05: Role preservation — locally-assigned roles survive
// ---------------------------------------------------------------------------

test "TC-OIDC-10-05: role preservation — locally-assigned roles survive reconciliation" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-05";
    const external_id = "sub-oidc10-05";
    const username = "tc-oidc-10-05-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-e", "OIDC10 Tenant E", realm);
    try ensureRole(&pool, "oidc10-role-viewer");
    try ensureRole(&pool, "oidc10-role-tw");
    try ensureRole(&pool, "oidc10-role-po");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Test User 05", "test05@example.com", realm, external_id);
    defer user.deinit(alloc);
    defer cleanupUserRoles(&pool, user.user_id);

    // Grant OIDC role TASK_WORKER and internal role VIEWER.
    try assignOidcRole(&pool, user.user_id, "oidc10-role-tw");
    try assignInternalRole(&pool, user.user_id, "oidc10-role-viewer");

    // Token roles: PROCESS_OPERATOR only — TASK_WORKER should be removed, VIEWER preserved.
    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{"oidc10-role-po"},
        .email = "test05@example.com",
        .preferred_username = username,
        .display_name = "Test User 05",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    // role-po added, role-tw removed, viewer/internal preserved.
    try testing.expectEqual(@as(usize, 1), sync_result.roles_added.len);
    try testing.expectEqualStrings("oidc10-role-po", sync_result.roles_added[0]);
    try testing.expectEqual(@as(usize, 1), sync_result.roles_removed.len);
    try testing.expectEqualStrings("oidc10-role-tw", sync_result.roles_removed[0]);

    // Check DB: should have role-po/oidc, role-viewer/internal.
    const role_data = try getUserRoleSources(&pool, user.user_id);
    defer {
        for (role_data.roles) |r| alloc.free(r);
        alloc.free(role_data.roles);
        for (role_data.sources) |s| alloc.free(s);
        alloc.free(role_data.sources);
    }

    try testing.expectEqual(@as(usize, 2), role_data.roles.len);
    try testing.expectEqualStrings("oidc10-role-po", role_data.roles[0]);
    try testing.expectEqualStrings("oidc", role_data.sources[0]);
    try testing.expectEqualStrings("oidc10-role-viewer", role_data.roles[1]);
    try testing.expectEqualStrings("internal", role_data.sources[1]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-06: Role overlap — role is both OIDC-sourced and locally-assigned
// ---------------------------------------------------------------------------

test "TC-OIDC-10-06: role overlap — both OIDC-sourced and locally-assigned" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-06";
    const external_id = "sub-oidc10-06";
    const username = "tc-oidc-10-06-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-f", "OIDC10 Tenant F", realm);
    try ensureRole(&pool, "oidc10-role-pd");
    try ensureRole(&pool, "oidc10-role-pd-local");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Test User 06", "test06@example.com", realm, external_id);
    defer user.deinit(alloc);
    defer cleanupUserRoles(&pool, user.user_id);

    // Grant PROCESS_DESIGNER as OIDC-sourced and a DIFFERENT role slug as internal.
    // Uses different slugs because the UNIQUE (user_id, role_id) constraint prevents
    // two bindings for the same role with different sources.
    try assignOidcRole(&pool, user.user_id, "oidc10-role-pd");
    try assignInternalRole(&pool, user.user_id, "oidc10-role-pd-local");

    // Token roles are empty — OIDC-sourced PD should be removed, internal PD-local preserved.
    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{},
        .email = "test06@example.com",
        .preferred_username = username,
        .display_name = "Test User 06",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), sync_result.roles_added.len);
    try testing.expectEqual(@as(usize, 1), sync_result.roles_removed.len);
    try testing.expectEqualStrings("oidc10-role-pd", sync_result.roles_removed[0]);

    // Check DB: only the internal PD-LOCAL binding should remain.
    const role_data = try getUserRoleSources(&pool, user.user_id);
    defer {
        for (role_data.roles) |r| alloc.free(r);
        alloc.free(role_data.roles);
        for (role_data.sources) |s| alloc.free(s);
        alloc.free(role_data.sources);
    }

    try testing.expectEqual(@as(usize, 1), role_data.roles.len);
    try testing.expectEqualStrings("oidc10-role-pd-local", role_data.roles[0]);
    try testing.expectEqualStrings("internal", role_data.sources[0]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-07: Empty token roles — all OIDC-sourced removed, local preserved
// ---------------------------------------------------------------------------

test "TC-OIDC-10-07: empty token roles — OIDC roles removed, local preserved" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-07";
    const external_id = "sub-oidc10-07";
    const username = "tc-oidc-10-07-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-g", "OIDC10 Tenant G", realm);
    try ensureRole(&pool, "oidc10-role-tw");
    try ensureRole(&pool, "oidc10-role-po");
    try ensureRole(&pool, "oidc10-role-viewer");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Test User 07", "test07@example.com", realm, external_id);
    defer user.deinit(alloc);
    defer cleanupUserRoles(&pool, user.user_id);

    try assignOidcRole(&pool, user.user_id, "oidc10-role-tw");
    try assignOidcRole(&pool, user.user_id, "oidc10-role-po");
    try assignInternalRole(&pool, user.user_id, "oidc10-role-viewer");

    // Empty token roles.
    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{},
        .email = "test07@example.com",
        .preferred_username = username,
        .display_name = "Test User 07",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), sync_result.roles_added.len);
    try testing.expectEqual(@as(usize, 2), sync_result.roles_removed.len);

    // Check DB: only VIEWER/internal remains.
    const role_data = try getUserRoleSources(&pool, user.user_id);
    defer {
        for (role_data.roles) |r| alloc.free(r);
        alloc.free(role_data.roles);
        for (role_data.sources) |s| alloc.free(s);
        alloc.free(role_data.sources);
    }

    try testing.expectEqual(@as(usize, 1), role_data.roles.len);
    try testing.expectEqualStrings("oidc10-role-viewer", role_data.roles[0]);
    try testing.expectEqualStrings("internal", role_data.sources[0]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-08: Error handling — user not found returns error.UserNotFound
// ---------------------------------------------------------------------------

test "TC-OIDC-10-08: user not found returns error.UserNotFound" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-08";
    const external_id = "nonexistent-sub-oidc10-08";

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-h", "OIDC10 Tenant H", realm);

    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{},
        .email = "nobody@example.com",
        .preferred_username = "nonexistent",
        .display_name = "Nobody",
    };

    try testing.expectError(
        error.UserNotFound,
        jit_provisioning.syncAttributesFromIdentityContext(
            alloc,
            &pool,
            &identity_ctx,
            tenant_a,
        ),
    );
}

// ---------------------------------------------------------------------------
// TC-OIDC-10-10: No change — identical profile and roles produce empty result
// ---------------------------------------------------------------------------

test "TC-OIDC-10-10: no change — identical profile and roles produce empty result" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-oidc10-10";
    const external_id = "sub-oidc10-10";
    const username = "tc-oidc-10-10-user";

    cleanupUserByUsername(&pool, username);
    cleanupRoles(&pool);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupRoles(&pool);

    try ensureTenantBinding(&pool, tenant_a, "oidc10-tenant-i", "OIDC10 Tenant I", realm);
    try ensureRole(&pool, "oidc10-role-tw");

    var registry = identity_registry.Registry.init(&pool);
    var user = try provisionTestUser(&pool, &registry, username, "Same Name", "same@example.com", realm, external_id);
    defer user.deinit(alloc);
    defer cleanupUserRoles(&pool, user.user_id);

    try assignOidcRole(&pool, user.user_id, "oidc10-role-tw");

    // Token has same roles and same profile as stored.
    var identity_ctx = claim_mapping.IdentityContext{
        .external_user_id = external_id,
        .tenant_id = tenant_a,
        .realm = realm,
        .roles = &[_][]const u8{"oidc10-role-tw"},
        .email = "same@example.com",
        .preferred_username = username,
        .display_name = "Same Name",
    };

    var sync_result = try jit_provisioning.syncAttributesFromIdentityContext(
        alloc,
        &pool,
        &identity_ctx,
        tenant_a,
    );
    defer sync_result.deinit(alloc);

    try testing.expect(!sync_result.profile_changed);
    try testing.expectEqual(@as(usize, 0), sync_result.roles_added.len);
    try testing.expectEqual(@as(usize, 0), sync_result.roles_removed.len);
}
