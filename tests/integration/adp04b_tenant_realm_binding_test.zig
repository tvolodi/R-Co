//! Integration tests for ADP-04b tenant realm binding behavior.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;

const default_tenant = auth_mod.DEFAULT_TENANT_ID;

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
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn uuid36ToArray(uuid: []const u8) [36]u8 {
    var out: [36]u8 = undefined;
    @memset(&out, 0);
    const n = @min(uuid.len, out.len);
    @memcpy(out[0..n], uuid[0..n]);
    return out;
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000111",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "adp04b-test-token",
        .principal = "adp04b-test-token",
        .tenant_id = uuid36ToArray(default_tenant),
        .tenant_source = .default_fallback,
    };
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

fn cleanupTenantBySlug(pool: *pool_mod.Pool, slug: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM users
        \\WHERE tenant_id IN (SELECT id FROM tenant WHERE slug = $1)
    ,
        &[_][]const u8{slug},
    ) catch {};

    conn.exec("DELETE FROM tenant WHERE slug = $1", &[_][]const u8{slug}) catch {};
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

test "TC-ADP-04b-01: migration backfills default tenant realm binding to bpm-default" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        \\SELECT idp_realm_id
        \\FROM tenant
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{default_tenant},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const realm = row[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("bpm-default", realm);
}

test "TC-ADP-04b-02: OIDC-enabled non-default tenant creation requires idp_realm_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-adp-04b-02-no-realm";
    cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, tenant_slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const create = service.createTenant(alloc, adminActor(), .{
        .tenant_id = null,
        .slug = tenant_slug,
        .display_name = "ADP04b Missing Realm",
        .idp_realm_id = null,
        .oidc_mode = .enabled,
    });

    try testing.expectError(identity_service.IdentityError.MissingRealmBinding, create);
}

test "TC-ADP-04b-03: OIDC-disabled tenant creation remains backward compatible without realm binding" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-adp-04b-03-compat";
    cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, tenant_slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try service.createTenant(alloc, adminActor(), .{
        .tenant_id = null,
        .slug = tenant_slug,
        .display_name = "ADP04b Compat",
        .idp_realm_id = null,
        .oidc_mode = .disabled,
    });
    defer created.deinit(alloc);

    try testing.expect(created.idp_realm_id == null);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT idp_realm_id FROM tenant WHERE id = $1::uuid",
        &[_][]const u8{created.tenant_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expect(row[0] == null);
}

test "TC-ADP-04b-04: ADP-04a OIDC user provisioning enforces tenant realm ownership and realm uniqueness" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-adp-04b-04-tenant";
    const duplicate_slug = "tc-adp-04b-04-duplicate";
    const username = "tc-adp-04b-04-user";
    cleanupTenantBySlug(&pool, tenant_slug);
    cleanupTenantBySlug(&pool, duplicate_slug);
    cleanupUserByUsername(&pool, username);
    defer cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, duplicate_slug);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created_tenant = try service.createTenant(alloc, adminActor(), .{
        .tenant_id = null,
        .slug = tenant_slug,
        .display_name = "ADP04b Guard",
        .idp_realm_id = "kc-adp04b-04",
        .oidc_mode = .enabled,
    });
    defer created_tenant.deinit(alloc);

    const duplicate_create = service.createTenant(alloc, adminActor(), .{
        .tenant_id = null,
        .slug = duplicate_slug,
        .display_name = "ADP04b Duplicate Realm",
        .idp_realm_id = "kc-adp04b-04",
        .oidc_mode = .enabled,
    });
    try testing.expectError(identity_service.IdentityError.DuplicateRealmBinding, duplicate_create);

    const created_user = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = created_tenant.tenant_id,
        .external_realm = "kc-adp04b-04",
        .external_id = "sub-adp04b-04",
        .preferred_username = username,
        .display_name = "ADP04b OIDC",
        .email = "tc-adp-04b-04@example.com",
        .status = .ACTIVE,
    });
    defer created_user.user.deinit(alloc);
    try testing.expect(created_user.created);

    const mismatch = service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = created_tenant.tenant_id,
        .external_realm = "kc-adp04b-04-other",
        .external_id = "sub-adp04b-04-other",
        .preferred_username = "tc-adp-04b-04-user-other",
        .display_name = "ADP04b OIDC Mismatch",
        .email = "tc-adp-04b-04-other@example.com",
        .status = .ACTIVE,
    });
    try testing.expectError(identity_service.IdentityError.RealmOwnershipMismatch, mismatch);
}

test "TC-ADP-04b-05: OIDC-enabled default-tenant rejects non-bpm-default realm binding" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const create = service.createTenant(alloc, adminActor(), .{
        .tenant_id = default_tenant,
        .slug = "tc-adp-04b-05-default-mismatch",
        .display_name = "ADP04b Default Mismatch",
        .idp_realm_id = "kc-not-bpm-default",
        .oidc_mode = .enabled,
    });

    try testing.expectError(identity_service.IdentityError.DefaultTenantRealmMismatch, create);
}

test "TC-ADP-04b-06: OIDC-enabled default-tenant omitted realm normalizes to bpm-default" {
    const realm = try identity_service.Service.resolveTenantRealmBinding(.{
        .tenant_id = default_tenant,
        .slug = "tc-adp-04b-06-default-normalized",
        .display_name = "ADP04b Default Normalized",
        .idp_realm_id = null,
        .oidc_mode = .enabled,
    });

    try testing.expect(realm != null);
    try testing.expectEqualStrings("bpm-default", realm.?);
}
