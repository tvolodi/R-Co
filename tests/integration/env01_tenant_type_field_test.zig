//! Integration tests for ENV-01 — tenant type field (production vs test).
//!
//! Requirements: ENV-01
//!
//! `public.tenant` carries two coupled columns:
//!   - `tenant_type TEXT NOT NULL DEFAULT 'production' CHECK IN ('production','test')`
//!   - `production_tenant_id UUID NULL REFERENCES public.tenant(id) ON DELETE RESTRICT`
//!
//! A table-level CHECK (`ck_tenant_type_fk_coherence`) enforces the type/FK
//! coherence invariant: production tenants have `production_tenant_id IS NULL`;
//! test tenants have `production_tenant_id IS NOT NULL`. Pre-existing rows are
//! backfilled to `tenant_type='production'` by the column DEFAULT. The admin
//! list route exposes both columns, and `PATCH /api/v1/tenants/:id` rejects any
//! attempt to change either with HTTP 422.
//!
//! ISS-0150 / GH #466: this file began life as an unfinished codegen scaffold —
//! nine `test` blocks whose bodies were `// CUSTOM:` placeholder comments with
//! zero `std.testing.expect*` calls of any kind, each one building a harness,
//! discarding its fixtures with `_ = fx`, and returning. It was invisible for
//! months because it was wired into no build target, so it neither ran nor
//! compiled. GH #439 repaired it only to the point of COMPILING, deliberately
//! leaving it uncovered so the gap stayed visible rather than being deleted to
//! make a gate pass. Every block below now carries real assertions executed
//! against real PostgreSQL; the intended SQL that previously existed only as a
//! comment is now the actual query.
//!
//! BPM_TEST_DB_URL must be set; the tests connect to a real PostgreSQL and each
//! block creates its own fixtures with per-test UUIDs, cleaned up via `defer`.

const std = @import("std");
const pg = @import("pg");
const portable_env = @import("env");
const testing = std.testing;
const helpers = @import("helpers.zig");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;
const auth_mod = bpm.api_auth;

// Root-level export so pool connections apply the tenant-schema search_path
// rather than falling back to search_path=public.
pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — ENV-01 tenant type field integration tests FAILED (env var required)\n",
                .{},
            );
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so every acquire() applies
    // SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

/// Per-test UUID string. Every block mints its own so concurrent or repeated
/// runs never collide on a shared tenant row (T010 hardcoded-UUID class).
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    const raw = helpers.randomUuidBytes();
    return @constCast(try helpers.uuidBytesToString(allocator, raw));
}

/// Per-test slug derived from the block's own UUID — `idx_tenant_slug_unique`
/// makes a shared literal slug a cross-run collision.
fn slugFor(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, id[0..8] });
}

/// Insert a production tenant row. Security: every value is bound as a
/// parameter — no SQL string interpolation of test data.
fn insertProductionTenant(pool: *Pool, tenant_id: []const u8, slug: []const u8) !void {
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
}

/// Insert a test tenant row linked to `production_tenant_id`.
fn insertTestTenant(
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
}

/// Best-effort delete used in `defer` cleanup. Registered unconditionally so a
/// mid-test failure still removes the row.
fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &[_][]const u8{tenant_id}) catch {};
}

/// Read back (tenant_type, production_tenant_id) for one tenant. Caller frees.
fn readTenantTypeRow(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
) !?[]const ?[]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    return conn.queryRow(
        allocator,
        \\SELECT tenant_type, production_tenant_id::text
        \\FROM public.tenant
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{tenant_id},
    );
}

/// Platform-admin caller for the two route-level cases. `user_id` is generated
/// per call rather than fixed: none of the assertions depend on its value, and
/// a literal UUID here is a T010 fixture-isolation violation waiting to collide
/// with another test's row. Caller owns `user_id` and must free it.
fn adminActor(user_id: []const u8) auth_mod.AuthContext {
    var tenant_id_arr: [36]u8 = undefined;
    @memset(&tenant_id_arr, 0);
    const default = auth_mod.DEFAULT_TENANT_ID;
    @memcpy(tenant_id_arr[0..default.len], default);
    return .{
        .user_id = user_id,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-env01-tenant-type",
        .principal = "integration-env01-tenant-type",
        .tenant_id = tenant_id_arr,
        .tenant_source = .default_fallback,
    };
}

fn freeRouteBody(allocator: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        allocator.free(body);
    }
}

// ---------------------------------------------------------------------------
// 1. Backfill: rows created without the new columns land on the DEFAULT.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: backfill_existing_rows_are_production" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const slug = try slugFor(allocator, "env01-backfill", prod_tenant_id);
    defer allocator.free(slug);
    defer cleanupTenantById(&pool, prod_tenant_id);

    // Insert WITHOUT naming tenant_type/production_tenant_id — exactly the shape
    // a row written before the migration had. The column DEFAULT is what
    // backfilled every pre-existing row, so this reproduces that path.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)
            \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL)
        ,
            &[_][]const u8{ prod_tenant_id, slug, slug },
        );
    }

    const row = (try readTenantTypeRow(allocator, &pool, prod_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }

    try testing.expectEqualStrings("production", row[0] orelse return error.TestUnexpectedResult);
    try testing.expect(row[1] == null);
}

// ---------------------------------------------------------------------------
// 2. A production tenant may be inserted with no parent reference.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: production_tenant_insert_no_parent" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const new_id = try randomUuidStr(allocator);
    defer allocator.free(new_id);
    const slug = try slugFor(allocator, "env01-prod-new", new_id);
    defer allocator.free(slug);
    defer cleanupTenantById(&pool, new_id);

    try insertProductionTenant(&pool, new_id, slug);

    const row = (try readTenantTypeRow(allocator, &pool, new_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }

    try testing.expectEqualStrings("production", row[0] orelse return error.TestUnexpectedResult);
    try testing.expect(row[1] == null);
}

// ---------------------------------------------------------------------------
// 3. A test tenant may be inserted with a valid parent reference.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: test_tenant_insert_with_valid_parent" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const test_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(test_tenant_id);
    const prod_slug = try slugFor(allocator, "env01-linked-prod", prod_tenant_id);
    defer allocator.free(prod_slug);
    const test_slug = try slugFor(allocator, "env01-linked-test", test_tenant_id);
    defer allocator.free(test_slug);

    // LIFO cleanup: the FK child must be deleted before the parent, so the
    // child's cleanup is registered LAST and therefore runs FIRST.
    defer cleanupTenantById(&pool, prod_tenant_id);
    defer cleanupTenantById(&pool, test_tenant_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);
    try insertTestTenant(&pool, test_tenant_id, test_slug, prod_tenant_id);

    const row = (try readTenantTypeRow(allocator, &pool, test_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }

    try testing.expectEqualStrings("test", row[0] orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        prod_tenant_id,
        row[1] orelse return error.TestUnexpectedResult,
    );
}

// ---------------------------------------------------------------------------
// 4. CHECK rejects a test tenant with no parent.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: check_constraint_rejects_test_tenant_without_parent" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const orphan_id = try randomUuidStr(allocator);
    defer allocator.free(orphan_id);
    const slug = try slugFor(allocator, "env01-no-parent", orphan_id);
    defer allocator.free(slug);
    // Registered even though the INSERT is expected to fail: if the constraint
    // ever regresses, the row must not survive into the next run.
    defer cleanupTenantById(&pool, orphan_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const result = conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', NULL)
    ,
        &[_][]const u8{ orphan_id, slug, slug },
    );
    try testing.expectError(error.QueryFailed, result);

    // And nothing was written.
    const row = try readTenantTypeRow(allocator, &pool, orphan_id);
    defer if (row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    try testing.expect(row == null);
}

// ---------------------------------------------------------------------------
// 5. CHECK rejects a production tenant that carries a parent.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: check_constraint_rejects_production_tenant_with_parent" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const bad_id = try randomUuidStr(allocator);
    defer allocator.free(bad_id);
    const prod_slug = try slugFor(allocator, "env01-badprod-parent", prod_tenant_id);
    defer allocator.free(prod_slug);
    const bad_slug = try slugFor(allocator, "env01-bad-prod", bad_id);
    defer allocator.free(bad_slug);

    defer cleanupTenantById(&pool, prod_tenant_id);
    defer cleanupTenantById(&pool, bad_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const result = conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', $4::uuid)
    ,
        &[_][]const u8{ bad_id, bad_slug, bad_slug, prod_tenant_id },
    );
    try testing.expectError(error.QueryFailed, result);

    const row = try readTenantTypeRow(allocator, &pool, bad_id);
    defer if (row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    try testing.expect(row == null);
}

// ---------------------------------------------------------------------------
// 6. ON DELETE RESTRICT protects a parent that still has children.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: on_delete_restrict_blocks_deleting_parent_with_children" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const test_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(test_tenant_id);
    const prod_slug = try slugFor(allocator, "env01-restrict-prod", prod_tenant_id);
    defer allocator.free(prod_slug);
    const test_slug = try slugFor(allocator, "env01-restrict-test", test_tenant_id);
    defer allocator.free(test_slug);

    defer cleanupTenantById(&pool, prod_tenant_id);
    defer cleanupTenantById(&pool, test_tenant_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);
    try insertTestTenant(&pool, test_tenant_id, test_slug, prod_tenant_id);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const result = conn.exec(
            "DELETE FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{prod_tenant_id},
        );
        try testing.expectError(error.QueryFailed, result);
    }

    // The parent must still be there — RESTRICT blocks, it does not cascade.
    const row = (try readTenantTypeRow(allocator, &pool, prod_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }
    try testing.expectEqualStrings("production", row[0] orelse return error.TestUnexpectedResult);

    // And so must the child, since the delete was rejected outright.
    const child = (try readTenantTypeRow(allocator, &pool, test_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (child) |col| if (col) |v| allocator.free(v);
        allocator.free(child);
    }
    try testing.expectEqualStrings("test", child[0] orelse return error.TestUnexpectedResult);
}

// ---------------------------------------------------------------------------
// 7. GET /api/v1/admin/tenants exposes both columns.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: admin_list_includes_new_fields" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const test_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(test_tenant_id);
    const prod_slug = try slugFor(allocator, "env01-list-prod", prod_tenant_id);
    defer allocator.free(prod_slug);
    const test_slug = try slugFor(allocator, "env01-list-test", test_tenant_id);
    defer allocator.free(test_slug);

    defer cleanupTenantById(&pool, prod_tenant_id);
    defer cleanupTenantById(&pool, test_tenant_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);
    try insertTestTenant(&pool, test_tenant_id, test_slug, prod_tenant_id);

    const admin_user_id = try randomUuidStr(allocator);
    defer allocator.free(admin_user_id);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = identity_routes.handleListTenants(
        &service,
        allocator,
        adminActor(admin_user_id),
        .{ .search = null, .limit = 500, .offset = 0 },
    );
    defer freeRouteBody(allocator, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const items = parsed.value.object.get("items") orelse return error.TestUnexpectedResult;
    try testing.expect(items == .array);

    var found_prod = false;
    var found_test = false;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const tid_val = obj.get("tenant_id") orelse continue;
        if (tid_val != .string) continue;
        const tid = tid_val.string;

        if (std.mem.eql(u8, tid, prod_tenant_id)) {
            found_prod = true;
            const tt = obj.get("tenant_type") orelse return error.TestUnexpectedResult;
            try testing.expect(tt == .string);
            try testing.expectEqualStrings("production", tt.string);
            const ptid = obj.get("production_tenant_id") orelse return error.TestUnexpectedResult;
            try testing.expect(ptid == .null);
        }
        if (std.mem.eql(u8, tid, test_tenant_id)) {
            found_test = true;
            const tt = obj.get("tenant_type") orelse return error.TestUnexpectedResult;
            try testing.expect(tt == .string);
            try testing.expectEqualStrings("test", tt.string);
            const ptid = obj.get("production_tenant_id") orelse return error.TestUnexpectedResult;
            try testing.expect(ptid == .string);
            try testing.expectEqualStrings(prod_tenant_id, ptid.string);
        }
    }
    try testing.expect(found_prod);
    try testing.expect(found_test);
}

// ---------------------------------------------------------------------------
// 8. PATCH may not change tenant_type.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: patch_immutability_tenant_type" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const prod_slug = try slugFor(allocator, "env01-patch-tt", prod_tenant_id);
    defer allocator.free(prod_slug);
    defer cleanupTenantById(&pool, prod_tenant_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);

    const admin_user_id = try randomUuidStr(allocator);
    defer allocator.free(admin_user_id);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = identity_routes.handlePatchTenant(
        &service,
        allocator,
        adminActor(admin_user_id),
        prod_slug,
        "{\"tenant_type\":\"test\",\"display_name\":\"Allowed Change\"}",
    );
    defer freeRouteBody(allocator, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "tenant_type") != null);

    // The rejection must be total: the stored row is untouched.
    const row = (try readTenantTypeRow(allocator, &pool, prod_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }
    try testing.expectEqualStrings("production", row[0] orelse return error.TestUnexpectedResult);
    try testing.expect(row[1] == null);
}

// ---------------------------------------------------------------------------
// 9. PATCH may not change production_tenant_id.
// ---------------------------------------------------------------------------

test "env01_tenant_type_field: patch_immutability_production_tenant_id" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const prod_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(prod_tenant_id);
    const test_tenant_id = try randomUuidStr(allocator);
    defer allocator.free(test_tenant_id);
    const prod_slug = try slugFor(allocator, "env01-patch-ptid-prod", prod_tenant_id);
    defer allocator.free(prod_slug);
    const test_slug = try slugFor(allocator, "env01-patch-ptid-test", test_tenant_id);
    defer allocator.free(test_slug);

    defer cleanupTenantById(&pool, prod_tenant_id);
    defer cleanupTenantById(&pool, test_tenant_id);

    try insertProductionTenant(&pool, prod_tenant_id, prod_slug);
    try insertTestTenant(&pool, test_tenant_id, test_slug, prod_tenant_id);

    const admin_user_id = try randomUuidStr(allocator);
    defer allocator.free(admin_user_id);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"production_tenant_id\":\"{s}\"}}",
        .{test_tenant_id},
    );
    defer allocator.free(body);

    const result = identity_routes.handlePatchTenant(
        &service,
        allocator,
        adminActor(admin_user_id),
        test_slug,
        body,
    );
    defer freeRouteBody(allocator, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "production_tenant_id") != null);

    // The stored link still points at the original parent.
    const row = (try readTenantTypeRow(allocator, &pool, test_tenant_id)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }
    try testing.expectEqualStrings("test", row[0] orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        prod_tenant_id,
        row[1] orelse return error.TestUnexpectedResult,
    );
}
