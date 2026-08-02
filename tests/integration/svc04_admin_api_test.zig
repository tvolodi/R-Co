// Integration tests for SVC-04: admin API route handlers for service catalog.
//
// Tests exercise handleListServices, handleAdminListServices,
// handleAdminRegisterService, handleAdminUpdateService, and
// handleAdminDeleteService against a real PostgreSQL database.
//
// Requires: BPM_TEST_DB_URL environment variable.
//
// Tests (TC-SVC-04-01 through TC-SVC-04-12):
//   - Admin register global service returns 201
//   - Admin register tenant-scoped service returns 201
//   - Admin register duplicate service_id returns 409
//   - Non-admin actor on register returns 403
//   - Admin update service scope returns 200
//   - Scope change to tenant with conflicting active definitions returns 409
//   - Admin delete service returns 200
//   - Delete service in use by active definition returns 409
//   - GET services for tenant admin excludes other tenants' scoped services
//   - GET admin services returns all entries
//   - GET admin services returns 403 for non-admin
//   - Admin update unknown service returns 404

const std = @import("std");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;
const CatalogError = bpm.service_catalog.CatalogError;
const services_routes = bpm.services_routes;
const HandlerResult = services_routes.HandlerResult;
const auth = bpm.api_auth;
const AuthContext = auth.AuthContext;
const Role = auth.Role;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseUuid36(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var buf: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= 32) return error.InvalidUuid;
        buf[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

fn freeServiceRecord(alloc: std.mem.Allocator, rec: bpm.service_catalog.ServiceCatalogRecord) void {
    alloc.free(rec.service_id);
    alloc.free(rec.endpoint_url);
    alloc.free(rec.request_schema);
    alloc.free(rec.response_schema);
    alloc.free(rec.retry_policy);
}

fn testDbUrl(alloc: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping SVC-04 integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

/// Build a platform-admin AuthContext (no real DB token needed for handler tests).
fn adminActor(tenant_hex: []const u8) AuthContext {
    var ctx = AuthContext{
        .user_id = "test-admin",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token",
        .principal = "test-token",
    };
    @memcpy(&ctx.tenant_id, tenant_hex[0..36]);
    return ctx;
}

/// Build a non-admin AuthContext.
fn tenantActor(tenant_hex: []const u8) AuthContext {
    var ctx = AuthContext{
        .user_id = "test-user",
        .role = .PROCESS_DESIGNER,
        .is_bootstrap = false,
        .token_id = "test-token-user",
        .principal = "test-token-user",
    };
    @memcpy(&ctx.tenant_id, tenant_hex[0..36]);
    return ctx;
}

fn makeRegistrationBody(
    alloc: std.mem.Allocator,
    service_id: []const u8,
    scope: []const u8,
    owner_tenant_id: ?[]const u8,
) ![]u8 {
    if (owner_tenant_id) |oid| {
        return std.fmt.allocPrint(alloc,
            \\{{"service_id":"{s}","endpoint_url":"https://example.com/{s}","scope":"{s}","owner_tenant_id":"{s}","timeout_ms":5000}}
        , .{ service_id, service_id, scope, oid });
    } else {
        return std.fmt.allocPrint(alloc,
            \\{{"service_id":"{s}","endpoint_url":"https://example.com/{s}","scope":"{s}","timeout_ms":5000}}
        , .{ service_id, service_id, scope });
    }
}

fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS"),
    }
}

fn randomServiceId(alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ prefix, std.fmt.bytesToHex(&rand_bytes, .lower) });
}

// ---------------------------------------------------------------------------
// TC-SVC-04-01: admin register global service returns 201
// ---------------------------------------------------------------------------

test "svc04: admin register global service returns 201" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const svc_id = try randomServiceId(alloc, "svc04-glb");
    defer alloc.free(svc_id);

    const body = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const result = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    // Verify the service was actually persisted.
    const fetched = try catalog.getService(alloc, svc_id);
    defer freeServiceRecord(alloc, fetched);
    try std.testing.expectEqualStrings(svc_id, fetched.service_id);
    try std.testing.expectEqual(bpm.service_catalog.ServiceScope.global, fetched.scope);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-02: admin register tenant-scoped service returns 201
// ---------------------------------------------------------------------------

test "svc04: admin register tenant-scoped service returns 201" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    // Use pre-committed fixture tenant (visible to pool connections).
    const owner_hex = try h.newUuidString(alloc);
    defer alloc.free(owner_hex);

    const svc_id = try randomServiceId(alloc, "svc04-tnt");
    defer alloc.free(svc_id);

    const body = try makeRegistrationBody(alloc, svc_id, "tenant", owner_hex);
    defer alloc.free(body);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const result = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    const tid_owner = try parseUuid36(owner_hex);
    const fetched = try catalog.getServiceForTenant(alloc, svc_id, tid_owner);
    defer freeServiceRecord(alloc, fetched);
    try std.testing.expectEqual(bpm.service_catalog.ServiceScope.tenant, fetched.scope);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-03: admin register duplicate service_id returns 409
// ---------------------------------------------------------------------------

test "svc04: admin register duplicate service_id returns 409" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const svc_id = try randomServiceId(alloc, "svc04-dup");
    defer alloc.free(svc_id);

    const body = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");

    // First registration succeeds.
    const r1 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 201), r1.status_code);

    // Second registration with same service_id returns 409.
    const r2 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body);
    defer alloc.free(r2.body);
    try std.testing.expectEqual(@as(u16, 409), r2.status_code);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-04: non-admin actor on register returns 403
// ---------------------------------------------------------------------------

test "svc04: non-admin actor on register returns 403" {
    const alloc = std.testing.allocator;

    // No DB access needed — handler rejects before any DB call.
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const svc_id = try randomServiceId(alloc, "svc04-auth");
    defer alloc.free(svc_id);

    const body = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body);

    const non_admin_id = try h.newUuidString(alloc);
    defer alloc.free(non_admin_id);
    const non_admin = tenantActor(non_admin_id);
    const result = services_routes.handleAdminRegisterService(alloc, &catalog, non_admin, body);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 403), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-05: admin update service scope returns 200
// ---------------------------------------------------------------------------

test "svc04: admin update service scope returns 200" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const owner_hex = try h.newUuidString(alloc);

    defer alloc.free(owner_hex);
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ owner_hex, "svc04-upd-tn", "SVC04 Update Tenant", "realm-svc04-upd", "00000000-0000-0000-0000-000000000000" },
    );

    const svc_id = try randomServiceId(alloc, "svc04-upd");
    defer alloc.free(svc_id);

    // Register as global first.
    const body_reg = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body_reg);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const r1 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_reg);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 201), r1.status_code);

    // PATCH: change to tenant-scoped.
    const patch_body = try std.fmt.allocPrint(alloc,
        \\{{"scope":"tenant","owner_tenant_id":"{s}"}}
    , .{owner_hex});
    defer alloc.free(patch_body);

    const r2 = services_routes.handleAdminUpdateService(alloc, &catalog, actor, svc_id, patch_body);
    defer alloc.free(r2.body);
    try std.testing.expectEqual(@as(u16, 200), r2.status_code);

    // Verify persistence.
    const fetched = try catalog.getService(alloc, svc_id);
    defer freeServiceRecord(alloc, fetched);
    try std.testing.expectEqual(bpm.service_catalog.ServiceScope.tenant, fetched.scope);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-06: scope change to tenant with conflicting active definitions returns 409
// ---------------------------------------------------------------------------

test "svc04: scope change to tenant with conflicting active definitions returns 409" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const owner_hex = try h.newUuidString(alloc);

    defer alloc.free(owner_hex);
    const other_tenant_hex = try h.newUuidString(alloc);
    defer alloc.free(other_tenant_hex);
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ owner_hex, "svc04-cnf-ow", "SVC04 Conflict Owner", "realm-svc04-cnf-ow", "00000000-0000-0000-0000-000000000000" },
    );
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ other_tenant_hex, "svc04-cnf-ot", "SVC04 Conflict Other", "realm-svc04-cnf-ot", "00000000-0000-0000-0000-000000000000" },
    );

    const svc_id = try randomServiceId(alloc, "svc04-cnf");
    defer alloc.free(svc_id);

    // Register service as global.
    const body_reg = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body_reg);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const r1 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_reg);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 201), r1.status_code);

    // Insert an ACTIVE definition for other_tenant that references svc_id.
    // ISOLATION FIX: insert via a pool connection so the row is committed and
    // visible to the handler's pool connections under READ COMMITTED.  A row
    // inserted inside the open harness transaction (h.conn) would be invisible
    // to separate pool connections used by the handler.
    //
    // SCHEMA FIX: after Stage-12 (GBL-073), public.process_definitions was
    // dropped.  Use the known seed-tenant schema that has the table and set
    // tenant_id to other_tenant_hex so bpm_active_defs_for_service finds it.
    const graph_json = try std.fmt.allocPrint(alloc,
        \\{{"nodes":[{{"id":"N1","node_type":"SERVICE_TASK","attributes":{{"service_id":"{s}"}}}}],"edges":[]}}
    , .{svc_id});
    defer alloc.free(graph_json);
    {
        const fix_conn = try pool.acquire();
        defer pool.release(fix_conn);
        // Create the schema and table for other_tenant so bpm_active_defs_for_service can find it.
        try fix_conn.exec("CREATE SCHEMA IF NOT EXISTS tenant_c4300000000000000000000000000002", &.{});
        try fix_conn.exec(
            \\CREATE TABLE IF NOT EXISTS tenant_c4300000000000000000000000000002.process_definitions (
            \\  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            \\  tenant_id UUID NOT NULL,
            \\  name TEXT NOT NULL,
            \\  version TEXT NOT NULL DEFAULT '1.0',
            \\  description TEXT NOT NULL DEFAULT '',
            \\  status TEXT NOT NULL,
            \\  graph JSONB NOT NULL,
            \\  created_by UUID NOT NULL DEFAULT gen_random_uuid(),
            \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
        , &.{});
        // Set bpm.tenant_id to other_tenant_hex so the RLS policy on the
        // tenant schema table allows the INSERT (policy checks tenant_id = bpm_effective_tenant_id()).
        try fix_conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{other_tenant_hex});
        try fix_conn.exec(
            \\INSERT INTO tenant_c4300000000000000000000000000002.process_definitions
            \\  (id, tenant_id, name, version, description, status, graph, created_by, created_at, updated_at)
            \\VALUES (gen_random_uuid(), $1::uuid, $2, '1.0.0', 'conflict test', 'ACTIVE', $3::jsonb, gen_random_uuid(), now(), now())
        , &.{ other_tenant_hex, svc_id, graph_json });
    }

    // Attempt to change scope to tenant-scoped for owner_tenant only.
    // Other tenant's ACTIVE definition should block this.
    const patch_body = try std.fmt.allocPrint(alloc,
        \\{{"scope":"tenant","owner_tenant_id":"{s}"}}
    , .{owner_hex});
    defer alloc.free(patch_body);

    const r2 = services_routes.handleAdminUpdateService(alloc, &catalog, actor, svc_id, patch_body);
    defer alloc.free(r2.body);
    try std.testing.expectEqual(@as(u16, 409), r2.status_code);

    // Cleanup the committed fixture row so it does not persist across test runs.
    {
        const clean_conn = try pool.acquire();
        defer pool.release(clean_conn);
        try clean_conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{other_tenant_hex});
        try clean_conn.exec("DROP TABLE IF EXISTS tenant_c4300000000000000000000000000002.process_definitions", &.{});
    }
}

// ---------------------------------------------------------------------------
// TC-SVC-04-07: admin delete service returns 200
// ---------------------------------------------------------------------------

test "svc04: admin delete service returns success" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const svc_id = try randomServiceId(alloc, "svc04-del");
    defer alloc.free(svc_id);

    const body_reg = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body_reg);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const r1 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_reg);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 201), r1.status_code);

    const r2 = services_routes.handleAdminDeleteService(alloc, &catalog, actor, svc_id);
    defer alloc.free(r2.body);
    try std.testing.expectEqual(@as(u16, 200), r2.status_code);

    // Verify the service is gone.
    try std.testing.expectError(CatalogError.ServiceNotFound, catalog.getService(alloc, svc_id));
}

// ---------------------------------------------------------------------------
// TC-SVC-04-08: delete service in use by active definition returns 409
// ---------------------------------------------------------------------------

test "svc04: delete service in use by active definition returns 409" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const tenant_hex = try h.newUuidString(alloc);

    defer alloc.free(tenant_hex);
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_hex, "svc04-inuse-t", "SVC04 InUse Tenant", "realm-svc04-inuse", "00000000-0000-0000-0000-000000000000" },
    );

    const svc_id = try randomServiceId(alloc, "svc04-inuse");
    defer alloc.free(svc_id);

    const body_reg = try makeRegistrationBody(alloc, svc_id, "global", null);
    defer alloc.free(body_reg);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const r1 = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_reg);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 201), r1.status_code);

    // Insert an ACTIVE definition referencing this service.
    // ISOLATION FIX: insert via a pool connection so the row is committed and
    // visible to the handler's pool connections under READ COMMITTED.  A row
    // inserted inside the open harness transaction (h.conn) would be invisible
    // to separate pool connections used by the handler.
    //
    // SCHEMA FIX: after Stage-12 (GBL-073), public.process_definitions was
    // dropped.  Use the known seed-tenant schema that has the table and set
    // tenant_id to tenant_hex so bpm_active_defs_for_service finds it.
    const graph_json = try std.fmt.allocPrint(alloc,
        \\{{"nodes":[{{"id":"N1","node_type":"SERVICE_TASK","attributes":{{"service_id":"{s}"}}}}],"edges":[]}}
    , .{svc_id});
    defer alloc.free(graph_json);
    {
        const fix_conn = try pool.acquire();
        defer pool.release(fix_conn);
        // Create the schema and table for tenant so bpm_active_defs_for_service can find it.
        try fix_conn.exec("CREATE SCHEMA IF NOT EXISTS tenant_d4400000000000000000000000000001", &.{});
        try fix_conn.exec(
            \\CREATE TABLE IF NOT EXISTS tenant_d4400000000000000000000000000001.process_definitions (
            \\  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            \\  tenant_id UUID NOT NULL,
            \\  name TEXT NOT NULL,
            \\  version TEXT NOT NULL DEFAULT '1.0',
            \\  description TEXT NOT NULL DEFAULT '',
            \\  status TEXT NOT NULL,
            \\  graph JSONB NOT NULL,
            \\  created_by UUID NOT NULL DEFAULT gen_random_uuid(),
            \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
        , &.{});
        // Set bpm.tenant_id to tenant_hex so the RLS policy on the
        // tenant schema table allows the INSERT (policy checks tenant_id = bpm_effective_tenant_id()).
        try fix_conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_hex});
        try fix_conn.exec(
            \\INSERT INTO tenant_d4400000000000000000000000000001.process_definitions
            \\  (id, tenant_id, name, version, description, status, graph, created_by, created_at, updated_at)
            \\VALUES (gen_random_uuid(), $1::uuid, $2, '1.0.0', 'in-use test', 'ACTIVE', $3::jsonb, gen_random_uuid(), now(), now())
        , &.{ tenant_hex, svc_id, graph_json });
    }

    // Delete must return 409.
    const r2 = services_routes.handleAdminDeleteService(alloc, &catalog, actor, svc_id);
    defer alloc.free(r2.body);
    try std.testing.expectEqual(@as(u16, 409), r2.status_code);

    // Cleanup the committed fixture row so it does not persist across test runs.
    {
        const clean_conn = try pool.acquire();
        defer pool.release(clean_conn);
        try clean_conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_hex});
        try clean_conn.exec("DROP TABLE IF EXISTS tenant_d4400000000000000000000000000001.process_definitions", &.{});
    }
}

// ---------------------------------------------------------------------------
// TC-SVC-04-09: GET services for tenant admin excludes other tenants' scoped services
// ---------------------------------------------------------------------------

test "svc04: GET services for tenant admin excludes other tenants scoped services" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const tenant_a_hex = try h.newUuidString(alloc);

    defer alloc.free(tenant_a_hex);
    const tenant_b_hex = try h.newUuidString(alloc);
    defer alloc.free(tenant_b_hex);
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_a_hex, "svc04-lst-ta", "SVC04 List TA", "realm-svc04-ta", "00000000-0000-0000-0000-000000000000" },
    );
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_b_hex, "svc04-lst-tb", "SVC04 List TB", "realm-svc04-tb", "00000000-0000-0000-0000-000000000000" },
    );

    const svc_global = try randomServiceId(alloc, "svc04-lst-g");
    defer alloc.free(svc_global);
    const svc_a = try randomServiceId(alloc, "svc04-lst-a");
    defer alloc.free(svc_a);
    const svc_b = try randomServiceId(alloc, "svc04-lst-b");
    defer alloc.free(svc_b);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");

    const body_g = try makeRegistrationBody(alloc, svc_global, "global", null);
    defer alloc.free(body_g);
    const r_g = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_g);
    defer alloc.free(r_g.body);
    try std.testing.expectEqual(@as(u16, 201), r_g.status_code);

    const body_a = try makeRegistrationBody(alloc, svc_a, "tenant", tenant_a_hex);
    defer alloc.free(body_a);
    const r_a = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_a);
    defer alloc.free(r_a.body);
    try std.testing.expectEqual(@as(u16, 201), r_a.status_code);

    const body_b = try makeRegistrationBody(alloc, svc_b, "tenant", tenant_b_hex);
    defer alloc.free(body_b);
    const r_b = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_b);
    defer alloc.free(r_b.body);
    try std.testing.expectEqual(@as(u16, 201), r_b.status_code);

    // Tenant-A actor listing: should see global + A's service, NOT B's service.
    const tenant_a_actor = tenantActor(tenant_a_hex);
    const list_result = services_routes.handleListServices(alloc, &catalog, tenant_a_actor, null, null);
    defer alloc.free(list_result.body);

    try std.testing.expectEqual(@as(u16, 200), list_result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, list_result.body, svc_global) != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result.body, svc_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result.body, svc_b) == null); // B's service must not appear
}

// ---------------------------------------------------------------------------
// TC-SVC-04-10: GET admin services returns all entries
// ---------------------------------------------------------------------------

test "svc04: GET admin services returns all entries" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const tenant_hex = try h.newUuidString(alloc);

    defer alloc.free(tenant_hex);
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_hex, "svc04-all-t", "SVC04 All Tenant", "realm-svc04-all", "00000000-0000-0000-0000-000000000000" },
    );

    const svc_global = try randomServiceId(alloc, "svc04-all-g");
    defer alloc.free(svc_global);
    const svc_tenant = try randomServiceId(alloc, "svc04-all-s");
    defer alloc.free(svc_tenant);

    const actor = adminActor("00000000-0000-0000-0000-000000000000");

    const body_g = try makeRegistrationBody(alloc, svc_global, "global", null);
    defer alloc.free(body_g);
    const r_g = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_g);
    defer alloc.free(r_g.body);
    try std.testing.expectEqual(@as(u16, 201), r_g.status_code);

    const body_s = try makeRegistrationBody(alloc, svc_tenant, "tenant", tenant_hex);
    defer alloc.free(body_s);
    const r_s = services_routes.handleAdminRegisterService(alloc, &catalog, actor, body_s);
    defer alloc.free(r_s.body);
    try std.testing.expectEqual(@as(u16, 201), r_s.status_code);

    // Admin listing: must see both.
    const admin_list = services_routes.handleAdminListServices(alloc, &catalog, actor, null, null);
    defer alloc.free(admin_list.body);

    try std.testing.expectEqual(@as(u16, 200), admin_list.status_code);
    try std.testing.expect(std.mem.indexOf(u8, admin_list.body, svc_global) != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_list.body, svc_tenant) != null);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-11: GET admin services returns 403 for non-admin
// ---------------------------------------------------------------------------

test "svc04: GET admin services returns 403 for non-admin" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const non_admin_id = try h.newUuidString(alloc);
    defer alloc.free(non_admin_id);
    const non_admin = tenantActor(non_admin_id);
    const result = services_routes.handleAdminListServices(alloc, &catalog, non_admin, null, null);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 403), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-SVC-04-12: admin update unknown service returns 404
// ---------------------------------------------------------------------------

test "svc04: admin update unknown service returns 404" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const actor = adminActor("00000000-0000-0000-0000-000000000000");
    const patch_body =
        \\{"scope":"global"}
    ;

    const result = services_routes.handleAdminUpdateService(alloc, &catalog, actor, "svc-does-not-exist-xyz", patch_body);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 404), result.status_code);
}

