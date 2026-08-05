//! Integration tests for ENV-01 — Tenant type field (production vs test).
//!
//! Covers: migration column/constraint presence, DB-level constraint enforcement,
//! onboarding validation, GET /admin/tenants field inclusion, PATCH immutability,
//! and ON DELETE RESTRICT FK behaviour.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via defer.
//!
//! Requirement traceability:
//!   ENV-01 → TC-ENV-01-01 .. TC-ENV-01-12

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const pool_mod = bpm.db_pool;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;
const auth_mod = bpm.api_auth;
const onboarding_mod = bpm.onboarding_mod;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — ENV-01 integration tests FAILED (env var required)\n",
                .{},
            );
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

/// Insert a bare production tenant row directly into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertProductionTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', NULL)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug },
    );
    _ = allocator;
}

/// Insert a bare test tenant row directly into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertTestTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
    production_tenant_id: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug, production_tenant_id },
    );
    _ = allocator;
}

/// Delete a tenant row by id (best-effort, used in defer cleanup).
fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

fn adminActor() auth_mod.AuthContext {
    var tenant_id_arr: [36]u8 = undefined;
    @memset(&tenant_id_arr, 0);
    const default = auth_mod.DEFAULT_TENANT_ID;
    @memcpy(tenant_id_arr[0..default.len], default);
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-env01",
        .principal = "integration-env01",
        .tenant_id = tenant_id_arr,
        .tenant_source = .default_fallback,
    };
}

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

// ---------------------------------------------------------------------------
// TC-ENV-01-01
// ---------------------------------------------------------------------------

test "TC-ENV-01-01: tenant_type column exists in public.tenant with NOT NULL constraint" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Query information_schema to verify the column exists.
    const row = try conn.queryRow(
        alloc,
        \\SELECT column_name, is_nullable, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name   = 'tenant'
        \\  AND column_name  = 'tenant_type'
    ,
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const r = row.?;

    // column_name
    const col_name = r[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tenant_type", col_name);

    // is_nullable must be 'NO'
    const is_nullable = r[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("NO", is_nullable);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-02
// ---------------------------------------------------------------------------

test "TC-ENV-01-02: production_tenant_id column exists as nullable FK in public.tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        alloc,
        \\SELECT column_name, is_nullable, udt_name
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name   = 'tenant'
        \\  AND column_name  = 'production_tenant_id'
    ,
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const r = row.?;

    const col_name = r[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("production_tenant_id", col_name);

    // is_nullable must be 'YES'
    const is_nullable = r[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("YES", is_nullable);

    // udt_name must be 'uuid'
    const udt = r[2] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("uuid", udt);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-03
// ---------------------------------------------------------------------------

test "TC-ENV-01-03: existing tenant rows have tenant_type='production' and production_tenant_id IS NULL" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Count rows that violate the expectation.
    const row = try conn.queryRow(
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM public.tenant
        \\WHERE tenant_type != 'production'
        \\   OR production_tenant_id IS NOT NULL
        \\-- Only check rows that existed before ENV-01 (no test rows from this suite yet)
        \\  AND slug NOT LIKE 'tc-env01-%'
    ,
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const r = row.?;
    const count_str = r[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_str, 10);
    try testing.expectEqual(@as(i64, 0), count);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-04
// ---------------------------------------------------------------------------

test "TC-ENV-01-04: DB INSERT of test tenant with valid production_tenant_id succeeds" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    // Cleanup: prod_id registered first (runs last); test_id registered second (runs first).
    // LIFO order ensures the FK child (test tenant) is deleted before the FK parent.
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, "tc-env01-04-prod");
    try insertTestTenant(alloc, &pool, test_id, "tc-env01-04-test", prod_id);

    // Verify the row exists with correct values.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        alloc,
        \\SELECT tenant_type, production_tenant_id::text
        \\FROM public.tenant
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{test_id},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(row != null);
    const r = row.?;
    const tenant_type = r[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("test", tenant_type);

    const linked_prod = r[1] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(prod_id, linked_prod);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-05
// ---------------------------------------------------------------------------

test "TC-ENV-01-05: DB INSERT of test tenant with NULL production_tenant_id fails with constraint violation" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // This INSERT must fail because it violates ck_tenant_type_fk_coherence.
    const result = conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, 'tc-env01-05-test', 'TC ENV-01-05', 'ACTIVE', NULL, 'test', NULL)
    ,
        &[_][]const u8{test_id},
    );

    // Expect an error — the constraint must fire (any DB error is acceptable).
    // If the INSERT succeeds (no error), the constraint is missing — fail the test.
    if (result) |_| {
        return error.TestExpectedConstraintViolation;
    } else |_| {}
}

// ---------------------------------------------------------------------------
// TC-ENV-01-06
// ---------------------------------------------------------------------------

test "TC-ENV-01-06: DB INSERT of production tenant with non-null production_tenant_id fails" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const other_prod_id = try randomUuidStr(alloc);
    defer alloc.free(other_prod_id);

    // First insert a real production tenant so we have a valid FK target.
    defer cleanupTenantById(&pool, prod_id);
    try insertProductionTenant(alloc, &pool, prod_id, "tc-env01-06-prod");

    defer cleanupTenantById(&pool, other_prod_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // This INSERT must fail because production tenants must not have a production_tenant_id.
    const result = conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, 'tc-env01-06-badprod', 'TC ENV-01-06', 'ACTIVE', NULL, 'production', $2::uuid)
    ,
        &[_][]const u8{ other_prod_id, prod_id },
    );

    // If the INSERT succeeds (no error), the constraint is missing — fail the test.
    if (result) |_| {
        return error.TestExpectedConstraintViolation;
    } else |_| {}
}

// ---------------------------------------------------------------------------
// TC-ENV-01-07: Onboarding validation — test tenant missing production_tenant_id
// ---------------------------------------------------------------------------

test "TC-ENV-01-07: executeSaga with test tenant and null production_tenant_id returns TestTenantMissingProductionRef" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Null IDP manager — validation fires before any IDP call.
    const null_mgr: bpm.identity_provider.manager.Manager = .{};

    const input = onboarding_mod.OnboardingInput{
        .slug = "tc-env01-07-test",
        .display_name = "TC ENV-01-07",
        .admin_email = "admin@tc-env01-07.local",
        .admin_username = "admin-tc-env01-07",
        .admin_display_name = "Admin TC ENV-01-07",
        .hostname = "tc-env01-07.local",
        .realm_config = null,
        .client_config = null,
        .tenant_type = .testing,
        .production_tenant_id = null, // Missing — should trigger validation error
    };

    const result = onboarding_mod.executeSaga(
        alloc,
        null_mgr,
        &pool,
        input,
        null,
        build_options.migrations_dir,
    );

    try testing.expectError(error.TestTenantMissingProductionRef, result);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-08: Onboarding validation — production tenant with production_tenant_id
// ---------------------------------------------------------------------------

test "TC-ENV-01-08: executeSaga with production tenant and non-null production_tenant_id returns ProductionTenantMustNotHaveRef" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const null_mgr: bpm.identity_provider.manager.Manager = .{};

    const input = onboarding_mod.OnboardingInput{
        .slug = "tc-env01-08-prod",
        .display_name = "TC ENV-01-08",
        .admin_email = "admin@tc-env01-08.local",
        .admin_username = "admin-tc-env01-08",
        .admin_display_name = "Admin TC ENV-01-08",
        .hostname = "tc-env01-08.local",
        .realm_config = null,
        .client_config = null,
        .tenant_type = .production,
        .production_tenant_id = "00000000-0000-0000-0000-000000000099", // Non-null — must trigger error
    };

    const result = onboarding_mod.executeSaga(
        alloc,
        null_mgr,
        &pool,
        input,
        null,
        build_options.migrations_dir,
    );

    try testing.expectError(error.ProductionTenantMustNotHaveRef, result);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-09: GET /admin/tenants includes tenant_type and production_tenant_id
// ---------------------------------------------------------------------------

test "TC-ENV-01-09: handleListTenants response includes tenant_type and production_tenant_id fields" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    // Cleanup: prod_id registered first (runs last); test_id registered second (runs first).
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, "tc-env01-09-prod");
    try insertTestTenant(alloc, &pool, test_id, "tc-env01-09-test", prod_id);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = identity_routes.handleListTenants(
        &service,
        alloc,
        adminActor(),
        .{ .search = null, .limit = 200, .offset = 0 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const items = parsed.value.object.get("items") orelse return error.TestUnexpectedResult;
    try testing.expect(items == .array);

    // Find our test tenant in the response.
    var found_test = false;
    var found_prod = false;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const tid = (obj.get("tenant_id") orelse continue).string;

        if (std.mem.eql(u8, tid, test_id)) {
            found_test = true;
            // Must have tenant_type and production_tenant_id keys.
            const tt = obj.get("tenant_type") orelse return error.TestUnexpectedResult;
            try testing.expect(tt == .string);
            try testing.expectEqualStrings("test", tt.string);
            const ptid = obj.get("production_tenant_id") orelse return error.TestUnexpectedResult;
            try testing.expect(ptid == .string);
            try testing.expectEqualStrings(prod_id, ptid.string);
        }
        if (std.mem.eql(u8, tid, prod_id)) {
            found_prod = true;
            const tt = obj.get("tenant_type") orelse return error.TestUnexpectedResult;
            try testing.expect(tt == .string);
            try testing.expectEqualStrings("production", tt.string);
            const ptid = obj.get("production_tenant_id") orelse return error.TestUnexpectedResult;
            // production tenant's production_tenant_id should be null.
            try testing.expect(ptid == .null);
        }
    }
    try testing.expect(found_test);
    try testing.expect(found_prod);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-10: PATCH with tenant_type key returns HTTP 422
// ---------------------------------------------------------------------------

test "TC-ENV-01-10: handlePatchTenant with tenant_type key returns HTTP 422 immutable_field" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    // This test exercises the pure JSON key-presence guard — no tenant in DB needed.
    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        "some-slug",
        "{\"tenant_type\":\"production\",\"display_name\":\"Allowed\"}",
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "immutable_field") != null);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-11: PATCH with production_tenant_id key returns HTTP 422
// ---------------------------------------------------------------------------

test "TC-ENV-01-11: handlePatchTenant with production_tenant_id key returns HTTP 422 immutable_field" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        "some-slug",
        "{\"production_tenant_id\":\"00000000-0000-0000-0000-000000000001\"}",
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "immutable_field") != null);
}

// ---------------------------------------------------------------------------
// TC-ENV-01-12: ON DELETE RESTRICT blocks deleting production tenant with linked test tenant
// ---------------------------------------------------------------------------

test "TC-ENV-01-12: DELETE production tenant while test tenant references it fails with FK violation" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    // Cleanup order: LIFO — test_id registered last (runs first, FK child), prod_id registered first (runs last, FK parent).
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, "tc-env01-12-prod");
    try insertTestTenant(alloc, &pool, test_id, "tc-env01-12-test", prod_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Attempt to delete the production tenant while the test tenant references it.
    // This must fail with a FK violation (ON DELETE RESTRICT).
    const del_result = conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{prod_id},
    );

    // The delete must fail — if it succeeds, ON DELETE RESTRICT is not enforced.
    if (del_result) |_| {
        return error.TestExpectedForeignKeyViolation;
    } else |_| {}

    // Verify the production tenant row still exists.
    const check_row = try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{prod_id},
    );
    defer if (check_row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };
    try testing.expect(check_row != null);
    const count_str = check_row.?[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_str, 10);
    try testing.expectEqual(@as(i64, 1), count);
}
