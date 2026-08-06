//! Integration tests for TM-01 (list tenants API) and TM-03 (patch tenant API).
//!
//! All tests connect to a real PostgreSQL database via BPM_TEST_DB_URL.
//! Tests fail clearly when BPM_TEST_DB_URL is absent.
//! Each test creates and cleans up its own fixtures using unique slugs.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;

// ── Test helpers ──────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for TM integration tests and is not set\n", .{});
            return err;
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

fn uuid36ToArray(uuid: []const u8) [36]u8 {
    var out: [36]u8 = undefined;
    @memset(&out, 0);
    const n = @min(uuid.len, out.len);
    @memcpy(out[0..n], uuid[0..n]);
    return out;
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-tm01",
        .principal = "integration-tm01",
        .tenant_id = uuid36ToArray(auth_mod.DEFAULT_TENANT_ID),
        .tenant_source = .default_fallback,
    };
}

fn viewerActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000002",
        .role = .VIEWER,
        .is_bootstrap = false,
        .token_id = "integration-tm01-viewer",
        .principal = "integration-tm01-viewer",
        .tenant_id = uuid36ToArray(auth_mod.DEFAULT_TENANT_ID),
        .tenant_source = .default_fallback,
    };
}

fn cleanupTenantBySlug(pool: *pool_mod.Pool, slug: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tenant WHERE slug = $1", &[_][]const u8{slug}) catch {};
}

/// Free a body returned by a route handler.
/// Static error strings like the internal_error fallback are not heap-allocated.
fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

/// Create a test tenant fixture. Caller must call cleanupTenantBySlug on completion.
fn createTestTenant(
    alloc: std.mem.Allocator,
    service: *identity_service.Service,
    slug: []const u8,
    display_name: []const u8,
) !identity_registry.Tenant {
    return service.createTenant(alloc, adminActor(), .{
        .tenant_id = null,
        .slug = slug,
        .display_name = display_name,
        .idp_realm_id = null,
        .oidc_mode = .disabled,
    });
}

fn runtimeFixtureSlug(alloc: std.mem.Allocator, prefix: []const u8, test_case_id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_case_id, &digest, .{});
    return std.fmt.allocPrint(
        alloc,
        "{s}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            prefix,
            digest[0],
            digest[1],
            digest[2],
            digest[3],
            digest[4],
            digest[5],
            digest[6],
            digest[7],
            digest[8],
            digest[9],
            digest[10],
            digest[11],
            digest[12],
            digest[13],
            digest[14],
            digest[15],
        },
    );
}

// ── TC-TM-01-01 ───────────────────────────────────────────────────────────────

test "TC-TM-01-01: PLATFORM_ADMIN can list tenants — returns 200 with items and total" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = "tc-tm-01-01";
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TC TM-01-01 Tenant");
    defer created.deinit(alloc);

    const result = identity_routes.handleListTenants(
        &service,
        alloc,
        adminActor(),
        .{ .search = null, .limit = 50, .offset = 0 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    const items_val = obj.get("items") orelse return error.TestUnexpectedResult;
    const total_val = obj.get("total") orelse return error.TestUnexpectedResult;

    try testing.expect(items_val == .array);
    try testing.expect(total_val == .integer);
    try testing.expect(total_val.integer >= 1);
    try testing.expect(items_val.array.items.len >= 1);
}

// ── TC-TM-01-02 ───────────────────────────────────────────────────────────────

test "TC-TM-01-02: non-PLATFORM_ADMIN (VIEWER) gets HTTP 403 from handleListTenants" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = identity_routes.handleListTenants(
        &service,
        alloc,
        viewerActor(),
        .{ .search = null, .limit = 50, .offset = 0 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "forbidden") != null);
}

// ── TC-TM-01-03 ───────────────────────────────────────────────────────────────

test "TC-TM-01-03: pagination — limit and offset return correct slice and total" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Create 3 fixture tenants so we have a known set for pagination.
    const slugs = [_][]const u8{ "tc-tm-01-03-a", "tc-tm-01-03-b", "tc-tm-01-03-c" };
    for (slugs) |s| cleanupTenantBySlug(&pool, s);
    defer for (slugs) |s| cleanupTenantBySlug(&pool, s);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    for (slugs) |s| {
        const t = try createTestTenant(alloc, &service, s, "Pagination Fixture");
        t.deinit(alloc);
    }

    // First page: limit=2, offset=0 — should return 2 items.
    const first = identity_routes.handleListTenants(
        &service,
        alloc,
        adminActor(),
        .{ .search = null, .limit = 2, .offset = 0 },
    );
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 200), first.status_code);

    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, first.body, .{ .allocate = .alloc_always });
    defer p1.deinit();
    try testing.expect(p1.value == .object);
    const p1_items = p1.value.object.get("items") orelse return error.TestUnexpectedResult;
    const p1_total = p1.value.object.get("total") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), p1_items.array.items.len);
    try testing.expect(p1_total.integer >= 3);

    // Second page: limit=2, offset=2 — should return at least 1 item (we have ≥3 total).
    const second = identity_routes.handleListTenants(
        &service,
        alloc,
        adminActor(),
        .{ .search = null, .limit = 2, .offset = 2 },
    );
    defer freeRouteBody(alloc, second.body);
    try testing.expectEqual(@as(u16, 200), second.status_code);

    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, second.body, .{ .allocate = .alloc_always });
    defer p2.deinit();
    try testing.expect(p2.value == .object);
    const p2_items = p2.value.object.get("items") orelse return error.TestUnexpectedResult;
    const p2_total = p2.value.object.get("total") orelse return error.TestUnexpectedResult;
    // Offset=2 with total≥3 means at least 1 item on the second page.
    try testing.expect(p2_items.array.items.len >= 1);
    // Total must be consistent across pages.
    try testing.expectEqual(p1_total.integer, p2_total.integer);
}

// ── TC-TM-03-01 ───────────────────────────────────────────────────────────────

test "TC-TM-03-01: PLATFORM_ADMIN PATCH display_name returns 200 with updated tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = "tc-tm-03-01";
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "Original Name");
    defer created.deinit(alloc);

    const body = "{\"display_name\":\"Updated Display Name\"}";

    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        slug,
        body,
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const display_name_val = parsed.value.object.get("display_name") orelse return error.TestUnexpectedResult;
    try testing.expect(display_name_val == .string);
    try testing.expectEqualStrings("Updated Display Name", display_name_val.string);

    const slug_val = parsed.value.object.get("slug") orelse return error.TestUnexpectedResult;
    try testing.expect(slug_val == .string);
    try testing.expectEqualStrings(slug, slug_val.string);
}

// ── TC-TM-03-02 ───────────────────────────────────────────────────────────────

test "TC-TM-03-02: PATCH body containing 'slug' key returns HTTP 422 immutable_field_update" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = "tc-tm-03-02";
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "Immutable Test");
    defer created.deinit(alloc);

    const body = "{\"slug\":\"new-slug\",\"display_name\":\"Allowed Field\"}";

    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        slug,
        body,
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "immutable_field_update") != null);
}

// ── TC-TM-03-03 ───────────────────────────────────────────────────────────────

test "TC-TM-03-03: PATCH body containing 'idp_realm_id' key returns HTTP 422 immutable_field_update" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = "tc-tm-03-03";
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "Realm Immutable Test");
    defer created.deinit(alloc);

    const body = "{\"idp_realm_id\":\"some-realm\",\"display_name\":\"Allowed Field\"}";

    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        slug,
        body,
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "immutable_field_update") != null);
}

// ── TC-TM-03-04 ───────────────────────────────────────────────────────────────

test "TC-TM-03-04: PATCH on non-existent slug returns HTTP 404 tenant_not_found" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Ensure this slug definitely does not exist.
    const nonexistent_slug = "tc-tm-03-04-nonexistent";
    cleanupTenantBySlug(&pool, nonexistent_slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body = "{\"display_name\":\"Should Not Exist\"}";

    const result = identity_routes.handlePatchTenant(
        &service,
        alloc,
        adminActor(),
        nonexistent_slug,
        body,
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "tenant_not_found") != null);
}

// ── TM-04 / TM-05 lifecycle controls ─────────────────────────────────────────

fn assertTenantStatusBySlug(
    alloc: std.mem.Allocator,
    registry: *identity_registry.Registry,
    slug: []const u8,
    expected_status: identity_registry.TenantStatus,
) !void {
    const maybe_tenant = try registry.selectTenantBySlug(alloc, slug);
    const tenant = maybe_tenant orelse return error.TestUnexpectedResult;
    defer tenant.deinit(alloc);
    try testing.expectEqual(expected_status, tenant.status);
}

test "TC-TM-04-01: deactivate endpoint sets tenant status INACTIVE and returns 200" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-04-01", "TC-TM-04-01");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-04 Deactivate");
    defer created.deinit(alloc);

    const result = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"INACTIVE\"") != null);
    try assertTenantStatusBySlug(alloc, &registry, slug, .INACTIVE);
}

test "TC-TM-04-02: deactivate endpoint is idempotent when already INACTIVE" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-04-02", "TC-TM-04-02");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-04 Idempotent");
    defer created.deinit(alloc);

    const first = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 200), first.status_code);

    const second = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, second.body);
    try testing.expectEqual(@as(u16, 200), second.status_code);
    try testing.expect(std.mem.indexOf(u8, second.body, "\"status\":\"INACTIVE\"") != null);

    try assertTenantStatusBySlug(alloc, &registry, slug, .INACTIVE);
}

test "TC-TM-04-03: deactivate endpoint rejects invalid slug and invalid payload" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const invalid_slug = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), "Bad_Slug", "{}");
    defer freeRouteBody(alloc, invalid_slug.body);
    try testing.expectEqual(@as(u16, 400), invalid_slug.status_code);
    try testing.expect(std.mem.indexOf(u8, invalid_slug.body, "invalid_tenant_slug") != null);

    const invalid_payload = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), "valid-slug", "{\"x\":1}");
    defer freeRouteBody(alloc, invalid_payload.body);
    try testing.expectEqual(@as(u16, 422), invalid_payload.status_code);
    try testing.expect(std.mem.indexOf(u8, invalid_payload.body, "invalid_lifecycle_payload") != null);
}

test "TC-TM-04-04: non-PLATFORM_ADMIN cannot deactivate tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-04-04", "TC-TM-04-04");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-04 Forbidden");
    defer created.deinit(alloc);

    const result = identity_routes.handleDeactivateTenant(&service, alloc, viewerActor(), slug, "{}");
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "forbidden") != null);
}

test "TC-TM-05-01: reactivate endpoint sets tenant status ACTIVE and returns 200" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-05-01", "TC-TM-05-01");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-05 Reactivate");
    defer created.deinit(alloc);

    const deactivated = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, deactivated.body);
    try testing.expectEqual(@as(u16, 200), deactivated.status_code);

    const reactivated = identity_routes.handleReactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, reactivated.body);
    try testing.expectEqual(@as(u16, 200), reactivated.status_code);
    try testing.expect(std.mem.indexOf(u8, reactivated.body, "\"status\":\"ACTIVE\"") != null);

    try assertTenantStatusBySlug(alloc, &registry, slug, .ACTIVE);
}

test "TC-TM-05-02: reactivate endpoint is idempotent when already ACTIVE" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-05-02", "TC-TM-05-02");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-05 Idempotent");
    defer created.deinit(alloc);

    const first = identity_routes.handleReactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, first.body);
    try testing.expectEqual(@as(u16, 200), first.status_code);

    const second = identity_routes.handleReactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, second.body);
    try testing.expectEqual(@as(u16, 200), second.status_code);
    try testing.expect(std.mem.indexOf(u8, second.body, "\"status\":\"ACTIVE\"") != null);

    try assertTenantStatusBySlug(alloc, &registry, slug, .ACTIVE);
}

test "TC-TM-05-03: non-PLATFORM_ADMIN cannot reactivate tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const slug = try runtimeFixtureSlug(alloc, "tc-tm-05-03", "TC-TM-05-03");
    defer alloc.free(slug);
    cleanupTenantBySlug(&pool, slug);
    defer cleanupTenantBySlug(&pool, slug);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const created = try createTestTenant(alloc, &service, slug, "TM-05 Forbidden");
    defer created.deinit(alloc);

    const deactivate = identity_routes.handleDeactivateTenant(&service, alloc, adminActor(), slug, "{}");
    defer freeRouteBody(alloc, deactivate.body);
    try testing.expectEqual(@as(u16, 200), deactivate.status_code);

    const reactivate = identity_routes.handleReactivateTenant(&service, alloc, viewerActor(), slug, "{}");
    defer freeRouteBody(alloc, reactivate.body);
    try testing.expectEqual(@as(u16, 403), reactivate.status_code);
    try testing.expect(std.mem.indexOf(u8, reactivate.body, "forbidden") != null);

    try assertTenantStatusBySlug(alloc, &registry, slug, .INACTIVE);
}
