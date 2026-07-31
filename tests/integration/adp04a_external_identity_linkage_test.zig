//! Integration tests for ADP-04a external identity linkage on users.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;

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

fn cleanupUserByExternalIdentity(pool: *pool_mod.Pool, realm: []const u8, external_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM group_members
        \\WHERE user_id IN (SELECT id FROM users WHERE external_realm = $1 AND external_id = $2)
    ,
        &[_][]const u8{ realm, external_id },
    ) catch {};

    conn.exec(
        \\DELETE FROM api_tokens
        \\WHERE user_id IN (SELECT id FROM users WHERE external_realm = $1 AND external_id = $2)
    ,
        &[_][]const u8{ realm, external_id },
    ) catch {};

    conn.exec(
        \\DELETE FROM user_roles
        \\WHERE user_id IN (SELECT id FROM users WHERE external_realm = $1 AND external_id = $2)
    ,
        &[_][]const u8{ realm, external_id },
    ) catch {};

    conn.exec(
        "DELETE FROM users WHERE external_realm = $1 AND external_id = $2",
        &[_][]const u8{ realm, external_id },
    ) catch {};
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

test "TC-ADP-04a-01: legacy/internal users keep auth_source=internal and NULL external linkage" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-adp-04a-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, $3, '', TRUE, $4, 'ACTIVE')
    , &[_][]const u8{
        tenant_a,
        "tc-adp-04a-01@example.com",
        "ADP04a Legacy Internal",
        username,
    });

    const row = (try conn.queryRow(
        alloc,
        \\SELECT auth_source, external_realm, external_id
        \\FROM users
        \\WHERE username = $1
    ,
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const auth_source = row[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("internal", auth_source);
    try testing.expect(row[1] == null);
    try testing.expect(row[2] == null);
}

test "TC-ADP-04a-02: createOrGetJitOidcUser stores oidc linkage and resolves by tenant+realm+sub" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-adp04a-02";
    const external_id = "sub-adp04a-02";
    const username = "tc-adp-04a-02-user";

    cleanupUserByUsername(&pool, username);
    cleanupUserByExternalIdentity(&pool, realm, external_id);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupUserByExternalIdentity(&pool, realm, external_id);

    try ensureTenantBinding(&pool, tenant_a, "adp04a-tenant-a", "ADP04a Tenant A", realm);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = username,
        .display_name = "ADP04a OIDC User",
        .email = "tc-adp-04a-02@example.com",
        .status = .ACTIVE,
    });
    defer first.user.deinit(alloc);

    try testing.expect(first.created);

    const resolved = try service.resolveUserByExternalIdentity(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
    });
    defer if (resolved) |u| u.deinit(alloc);

    try testing.expect(resolved != null);
    try testing.expectEqualStrings(first.user.user_id, resolved.?.user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        \\SELECT auth_source, external_realm, external_id
        \\FROM users
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{first.user.user_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const auth_source = row[0] orelse return error.TestUnexpectedResult;
    const persisted_realm = row[1] orelse return error.TestUnexpectedResult;
    const persisted_external_id = row[2] orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("oidc", auth_source);
    try testing.expectEqualStrings(realm, persisted_realm);
    try testing.expectEqualStrings(external_id, persisted_external_id);
}

test "TC-ADP-04a-03: createOrGetJitOidcUser is idempotent for same tenant+realm+sub" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-adp04a-03";
    const external_id = "sub-adp04a-03";
    const first_username = "tc-adp-04a-03-first";

    cleanupUserByUsername(&pool, first_username);
    cleanupUserByExternalIdentity(&pool, realm, external_id);
    defer cleanupUserByUsername(&pool, first_username);
    defer cleanupUserByExternalIdentity(&pool, realm, external_id);

    try ensureTenantBinding(&pool, tenant_a, "adp04a-tenant-a", "ADP04a Tenant A", realm);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = first_username,
        .display_name = "ADP04a First",
        .email = "tc-adp-04a-03-first@example.com",
        .status = .ACTIVE,
    });
    defer first.user.deinit(alloc);
    try testing.expect(first.created);

    const second = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = "tc-adp-04a-03-second",
        .display_name = "ADP04a Second",
        .email = "tc-adp-04a-03-second@example.com",
        .status = .ACTIVE,
    });
    defer second.user.deinit(alloc);

    try testing.expect(!second.created);
    try testing.expectEqualStrings(first.user.user_id, second.user.user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const count_row = (try conn.queryRow(
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM users
        \\WHERE tenant_id = $1::uuid
        \\  AND external_realm = $2
        \\  AND external_id = $3
    ,
        &[_][]const u8{ tenant_a, realm, external_id },
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, count_row);

    const count_raw = count_row[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(u32, count_raw, 10);
    try testing.expectEqual(@as(u32, 1), count);
}

test "TC-ADP-04a-04: tenant-scoped resolution prevents cross-tenant identity binding" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm = "kc-realm-adp04a-04";
    const tenant_b_realm = "kc-realm-adp04a-04-b";
    const external_id = "sub-adp04a-04";
    const username = "tc-adp-04a-04-user";

    cleanupUserByUsername(&pool, username);
    cleanupUserByExternalIdentity(&pool, realm, external_id);
    defer cleanupUserByUsername(&pool, username);
    defer cleanupUserByExternalIdentity(&pool, realm, external_id);

    try ensureTenantBinding(&pool, tenant_a, "adp04a-tenant-a", "ADP04a Tenant A", realm);
    try ensureTenantBinding(&pool, tenant_b, "adp04a-tenant-b", "ADP04a Tenant B", tenant_b_realm);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = username,
        .display_name = "ADP04a Collision",
        .email = "tc-adp-04a-04@example.com",
        .status = .ACTIVE,
    });
    defer first.user.deinit(alloc);
    try testing.expect(first.created);

    const foreign = service.resolveUserByExternalIdentity(alloc, .{
        .tenant_id = tenant_b,
        .external_realm = realm,
        .external_id = external_id,
    });
    try testing.expectError(identity_service.IdentityError.RealmOwnershipMismatch, foreign);

    const collision = service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_b,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = "tc-adp-04a-04-other-tenant",
        .display_name = "ADP04a Collision Other",
        .email = "tc-adp-04a-04-other@example.com",
        .status = .ACTIVE,
    });
    try testing.expectError(identity_service.IdentityError.RealmOwnershipMismatch, collision);
}

test "TC-ADP-04a-06: multiple internal NULL-linkage rows coexist while duplicate external pairs are rejected" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const internal_user_1 = "tc-adp-04a-06-internal-1";
    const internal_user_2 = "tc-adp-04a-06-internal-2";
    const oidc_user = "tc-adp-04a-06-oidc";
    const duplicate_user = "tc-adp-04a-06-duplicate";
    const realm = "kc-realm-adp04a-06";
    const external_id = "sub-adp04a-06";

    cleanupUserByUsername(&pool, internal_user_1);
    cleanupUserByUsername(&pool, internal_user_2);
    cleanupUserByUsername(&pool, oidc_user);
    cleanupUserByUsername(&pool, duplicate_user);
    cleanupUserByExternalIdentity(&pool, realm, external_id);
    defer cleanupUserByUsername(&pool, internal_user_1);
    defer cleanupUserByUsername(&pool, internal_user_2);
    defer cleanupUserByUsername(&pool, oidc_user);
    defer cleanupUserByUsername(&pool, duplicate_user);
    defer cleanupUserByExternalIdentity(&pool, realm, external_id);

    try ensureTenantBinding(&pool, tenant_a, "adp04a-tenant-a", "ADP04a Tenant A", realm);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, $3, '', TRUE, $4, 'ACTIVE')
    , &[_][]const u8{
        tenant_a,
        "tc-adp-04a-06-internal-1@example.com",
        "ADP04a Internal One",
        internal_user_1,
    });

    try conn.exec(
        \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, $3, '', TRUE, $4, 'ACTIVE')
    , &[_][]const u8{
        tenant_a,
        "tc-adp-04a-06-internal-2@example.com",
        "ADP04a Internal Two",
        internal_user_2,
    });

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try service.createOrGetJitOidcUser(alloc, .{
        .tenant_id = tenant_a,
        .external_realm = realm,
        .external_id = external_id,
        .preferred_username = oidc_user,
        .display_name = "ADP04a OIDC Anchor",
        .email = "tc-adp-04a-06-oidc@example.com",
        .status = .ACTIVE,
    });
    defer created.user.deinit(alloc);
    try testing.expect(created.created);

    const internal_count_row = (try conn.queryRow(
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM users
        \\WHERE username IN ($1, $2)
        \\  AND auth_source = 'internal'
        \\  AND external_realm IS NULL
        \\  AND external_id IS NULL
    ,
        &[_][]const u8{ internal_user_1, internal_user_2 },
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, internal_count_row);

    const internal_count_raw = internal_count_row[0] orelse return error.TestUnexpectedResult;
    const internal_count = try std.fmt.parseInt(u32, internal_count_raw, 10);
    try testing.expectEqual(@as(u32, 2), internal_count);

    const index_row = (try conn.queryRow(
        alloc,
        \\SELECT indexdef
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname = 'idx_users_external_identity_unique'
    ,
        &.{},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, index_row);

    const index_def = index_row[0] orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, index_def, "CREATE UNIQUE INDEX") != null);
    try testing.expect(std.mem.indexOf(u8, index_def, "users_external_identity_unique") != null);
    try testing.expect(std.mem.indexOf(u8, index_def, "external_realm, external_id") != null);
    try testing.expect(std.mem.indexOf(u8, index_def, "WHERE (external_id IS NOT NULL)") != null);

    try testing.expectError(pool_mod.PoolError.QueryFailed, conn.exec(
        \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status, auth_source, external_realm, external_id)
        \\VALUES ($1::uuid, $2, $3, '', TRUE, $4, 'ACTIVE', 'oidc', $5, $6)
    , &[_][]const u8{
        tenant_a,
        "tc-adp-04a-06-duplicate@example.com",
        "ADP04a Duplicate OIDC",
        duplicate_user,
        realm,
        external_id,
    }));

    const oidc_count_row = (try conn.queryRow(
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM users
        \\WHERE external_realm = $1
        \\  AND external_id = $2
    ,
        &[_][]const u8{ realm, external_id },
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, oidc_count_row);

    const oidc_count_raw = oidc_count_row[0] orelse return error.TestUnexpectedResult;
    const oidc_count = try std.fmt.parseInt(u32, oidc_count_raw, 10);
    try testing.expectEqual(@as(u32, 1), oidc_count);
}
