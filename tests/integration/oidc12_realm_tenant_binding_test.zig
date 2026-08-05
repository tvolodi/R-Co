//! Integration tests for OIDC-12 — Realm-tenant binding.
//!
//! Tests resolveTenantByRealm, resolveRealmByTenant, and the binding
//! invariants end-to-end against a real PostgreSQL database.
//!
//! Requirement: OIDC-12 — Realm-tenant binding [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs — all tests use real PostgreSQL.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const realm_tenant_binding = @import("realm_tenant_binding");
const pg = @import("pg");

const pool_mod = bpm.db_pool;

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const default_tenant = "00000000-0000-0000-0000-000000000000";
const tenant_a = "11111111-1111-1111-1111-111111111111";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
    , &[_][]const u8{slug}) catch {};

    conn.exec("DELETE FROM tenant WHERE slug = $1", &[_][]const u8{slug}) catch {};
}

// ---------------------------------------------------------------------------
// TC-OIDC-12-01: Tenant with realm binding can be looked up by realm ID
// ---------------------------------------------------------------------------

test "TC-OIDC-12-01: resolveTenantByRealm returns correct tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-oidc12-01-tenant";
    const realm_id = "kc-oidc12-01-realm";

    cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, tenant_slug);

    // Create a tenant with an explicit realm binding.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, 'test', $4::uuid)
            \\ON CONFLICT (slug) DO UPDATE
            \\SET idp_realm_id = EXCLUDED.idp_realm_id,
            \\    display_name = EXCLUDED.display_name,
            \\    updated_at = NOW()
        , &[_][]const u8{ tenant_slug, "OIDC12 Tenant 01", realm_id, "00000000-0000-0000-0000-000000000000" });
    }

    // Look up by realm ID.
    const binding = try realm_tenant_binding.resolveTenantByRealm(alloc, &pool, .{
        .idp_realm_id = realm_id,
    });
    defer binding.deinit(alloc);

    try testing.expectEqualStrings(tenant_slug, binding.tenant_slug);
    try testing.expectEqualStrings(realm_id, binding.idp_realm_id);
}

// ---------------------------------------------------------------------------
// TC-OIDC-12-02: Default tenant has idp_realm_id = 'bpm-default'
// ---------------------------------------------------------------------------

test "TC-OIDC-12-02: default tenant has bpm-default realm binding" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const binding = try realm_tenant_binding.resolveTenantByRealm(alloc, &pool, .{
        .idp_realm_id = "bpm-default",
    });
    defer binding.deinit(alloc);

    try testing.expectEqualStrings(binding.tenant_id, default_tenant);
    try testing.expectEqualStrings(binding.idp_realm_id, "bpm-default");
}

// ---------------------------------------------------------------------------
// TC-OIDC-12-03: Lookup by unknown realm returns NotFound
// ---------------------------------------------------------------------------

test "TC-OIDC-12-03: resolveTenantByRealm returns NotFound for unknown realm" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const result = realm_tenant_binding.resolveTenantByRealm(alloc, &pool, .{
        .idp_realm_id = "unknown-realm-oidc12-03",
    });

    try testing.expectError(error.NotFound, result);
}

// ---------------------------------------------------------------------------
// TC-OIDC-12-04: Tenant-to-realm reverse lookup returns realm ID
// ---------------------------------------------------------------------------

test "TC-OIDC-12-04: resolveRealmByTenant returns correct realm ID" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-oidc12-04-tenant";
    const realm_id = "kc-oidc12-04-realm";

    cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, tenant_slug);

    // Create a tenant with realm binding.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, 'test', $4::uuid)
            \\ON CONFLICT (slug) DO UPDATE
            \\SET idp_realm_id = EXCLUDED.idp_realm_id,
            \\    updated_at = NOW()
        , &[_][]const u8{ tenant_slug, "OIDC12 Tenant 04", realm_id, "00000000-0000-0000-0000-000000000000" });
    }

    // Get the tenant_id first.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        const row = (try conn.queryRow(
            alloc,
            "SELECT id::text FROM tenant WHERE slug = $1",
            &[_][]const u8{tenant_slug},
        )) orelse return error.TestUnexpectedResult;
        defer freeRow(alloc, row);

        const tenant_id = row[0] orelse return error.TestUnexpectedResult;

        // Reverse lookup.
        const resolved_realm = try realm_tenant_binding.resolveRealmByTenant(alloc, &pool, tenant_id);
        defer alloc.free(resolved_realm);

        try testing.expectEqualStrings(realm_id, resolved_realm);
    }
}

// ---------------------------------------------------------------------------
// TC-OIDC-12-05: Reverse lookup by unknown tenant returns NotFound
// ---------------------------------------------------------------------------

test "TC-OIDC-12-05: resolveRealmByTenant returns NotFound for unknown tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const fake_tenant_id = "00000000-0000-0000-0000-ffffffffffff";
    const result = realm_tenant_binding.resolveRealmByTenant(alloc, &pool, fake_tenant_id);

    try testing.expectError(error.NotFound, result);
}
