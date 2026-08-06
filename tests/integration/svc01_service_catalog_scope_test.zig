// Integration tests for SVC-01: service_catalog scope and owner_tenant_id columns.
// Requires: BPM_TEST_DB_URL and migration GBL-078 applied.
//
// Tests:
//   - Global service is visible to any tenant.
//   - Tenant-scoped service is visible only to its owner tenant.
//   - CHECK constraint: scope=tenant with NULL owner_tenant_id is rejected.
//   - ON DELETE CASCADE: deleting the owner tenant removes its service entry.
//   - Legacy rows (pre-migration) default to scope='global'.

const std = @import("std");
const portable_env = @import("env");
const pg = @import("pg");
const helpers = @import("helpers.zig");

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = @import("bpm").api_tenant_context;

// ---------------------------------------------------------------------------
// UUID helper
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Setup / cleanup helpers
// ---------------------------------------------------------------------------

fn insertTenant(conn: *pg.Conn, id_hex: []const u8, slug: []const u8) !void {
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ id_hex, slug, slug, slug, "00000000-0000-0000-0000-000000000000" },
    );
}

/// ISS-0144 / GitHub #454: several tests below register a scope=.tenant
/// service via `ServiceCatalog.registerService()` (src/repository/service_catalog.zig),
/// which requires `owner_tenant_id` to already exist as a row in
/// public.tenant (it runs `SELECT id FROM public.tenant WHERE id =
/// $1::uuid` and returns CatalogError.TenantNotFound otherwise). Those
/// tests generated a random tenant UUID under a comment claiming it was a
/// "pre-committed fixture tenant" but never actually inserted it, so every
/// one of those calls deterministically hit TenantNotFound.
///
/// Unlike insertTenant() above (which writes via `h.conn` and is safe only
/// when every later query in the SAME test also uses `h.conn`),
/// insertTenantViaPool() writes via the SAME `*Pool` that
/// ServiceCatalog.registerService() acquires connections from.
/// TestHarness.init() holds h.conn inside an explicit transaction that is
/// only ever rolled back in deinit() (by design, for per-test isolation) —
/// an INSERT issued there is invisible to any other session under
/// Postgres's default READ COMMITTED isolation, including a separate
/// pool.acquire() connection. Use this helper (not insertTenant) whenever
/// the test also calls registerService() against `pool`.
fn insertTenantViaPool(alloc: std.mem.Allocator, pool: anytype, id_hex: []const u8, label: []const u8) !void {
    // ISS-0144 rework: `slug` and `idp_realm_id` both carry UNIQUE indexes
    // (idx_tenant_slug_unique, idx_tenant_idp_realm_id) in public.tenant.
    // Because this INSERT commits immediately (via `pool`, not the
    // TestHarness's rolled-back h.conn — see the doc comment above), a
    // static per-test-name slug like "svc01-lst-a" collides with the SAME
    // row left behind by every PRIOR run of this suite: `ON CONFLICT (id)
    // DO NOTHING` only covers the `id` column, so the slug/idp_realm_id
    // unique-index violation on the second and later runs was an uncaught
    // Postgres error. Derive both from `id_hex` (already a fresh random
    // UUID per test) so they are unique per call, forever, with no
    // accumulation risk — matching the convention
    // bpm_provision_tenant_schema() itself already uses
    // ('tenant-' || replace(id::text, '-', '')).
    const unique_slug = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ label, id_hex });
    defer alloc.free(unique_slug);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $2, now(), 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ id_hex, unique_slug, label, "00000000-0000-0000-0000-000000000000" },
    );
}

fn insertGlobalService(conn: *pg.Conn, svc_id: []const u8) !void {
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'global', NULL)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{svc_id},
    );
}

fn insertScopedService(conn: *pg.Conn, svc_id: []const u8, owner_hex: []const u8) !void {
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'tenant', $2::uuid)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{ svc_id, owner_hex },
    );
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

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    fillRandom(buf);
    for (buf) |*b| b.* = chars[@as(usize, b.*) % chars.len];
    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "svc01: global service visible to any tenant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-glb-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    try insertGlobalService(&h.conn, svc_id);

    // List for a random tenant — global service must appear.
    const tenant_hex = try randomUuidStr(std.testing.allocator);
    defer std.testing.allocator.free(tenant_hex);
    const rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id, scope, owner_tenant_id
        \\FROM public.service_catalog
        \\WHERE service_id = $1
        \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
    ,
        &.{ svc_id, tenant_hex },
    );
    defer {
        var r = rows;
        r.deinit();
    }
    try std.testing.expect(rows.rows.len == 1);
    const scope_val: []const u8 = rows.rows[0][1] orelse "";
    try std.testing.expectEqualStrings("global", scope_val);

    // Also visible to a different tenant.
    const tenant2_hex = try randomUuidStr(std.testing.allocator);
    defer std.testing.allocator.free(tenant2_hex);
    const rows2 = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM public.service_catalog
        \\WHERE service_id = $1
        \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
    ,
        &.{ svc_id, tenant2_hex },
    );
    defer {
        var r2 = rows2;
        r2.deinit();
    }
    try std.testing.expect(rows2.rows.len == 1);
}

test "svc01: tenant-scoped service visible only to owner tenant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    // Insert tenant A (owner).
    const tenant_a_hex = try randomUuidStr(std.testing.allocator);
    defer std.testing.allocator.free(tenant_a_hex);
    try insertTenant(&h.conn, tenant_a_hex, "svc01-ta");

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-scpd-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    try insertScopedService(&h.conn, svc_id, tenant_a_hex);

    // Visible to tenant A (the owner).
    const rows_a = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM public.service_catalog
        \\WHERE service_id = $1
        \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
    ,
        &.{ svc_id, tenant_a_hex },
    );
    defer {
        var r = rows_a;
        r.deinit();
    }
    try std.testing.expect(rows_a.rows.len == 1);

    // NOT visible to tenant B (different tenant).
    const tenant_b_hex = try randomUuidStr(std.testing.allocator);
    defer std.testing.allocator.free(tenant_b_hex);
    const rows_b = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM public.service_catalog
        \\WHERE service_id = $1
        \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
    ,
        &.{ svc_id, tenant_b_hex },
    );
    defer {
        var r = rows_b;
        r.deinit();
    }
    try std.testing.expect(rows_b.rows.len == 0);
}

test "svc01: check constraint rejects scope=tenant with NULL owner" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-bad-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    // Attempt INSERT with scope='tenant', owner_tenant_id=NULL — should fail CHECK constraint.
    const result = h.conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://bad.com', '{}', '{}', 'NONE', 5000, '{}', 'tenant', NULL)
    ,
        &.{svc_id},
    );
    try std.testing.expectError(error.ServerError, result);
}

test "svc01: on_delete_cascade removes scoped service when owner tenant deleted" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_hex = try randomUuidStr(std.testing.allocator);
    defer std.testing.allocator.free(tenant_hex);
    // Insert tenant directly (NOT through the harness transaction so we can delete it).
    try h.conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_hex, "svc01-cascade-test", "SVC01 Cascade Test", "realm-cascade", "00000000-0000-0000-0000-000000000000" },
    );

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-cas-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    try insertScopedService(&h.conn, svc_id, tenant_hex);

    // Verify it was inserted.
    const before = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM public.service_catalog WHERE service_id = $1
    ,
        &.{svc_id},
    );
    defer {
        var r = before;
        r.deinit();
    }
    try std.testing.expect(before.rows.len == 1);

    // Delete the owning tenant — CASCADE should remove the service.
    try h.conn.exec(
        \\DELETE FROM tenant WHERE id = $1::uuid
    ,
        &.{tenant_hex},
    );

    const after = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM public.service_catalog WHERE service_id = $1
    ,
        &.{svc_id},
    );
    defer {
        var r = after;
        r.deinit();
    }
    try std.testing.expect(after.rows.len == 0);
}

test "svc01: existing rows default to scope=global" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    // Any row in service_catalog should have a non-null scope column defaulting to 'global'.
    // ISS-0144 / GitHub #454 (recurrence of ISS-0089 / GitHub #338): this
    // query must be schema-qualified as public.service_catalog. GBL-117
    // (formerly GBL-078) adds `scope`/`owner_tenant_id` only to
    // public.service_catalog; TestHarness's search_path is
    // "tenant_default,public", and tenant_default has its own
    // service_catalog copy (created by an earlier, non-GBL migration, still
    // lacking these columns) that an unqualified reference silently
    // resolves to instead — producing a deterministic C42703 "column scope
    // does not exist" that looks like a migration/concurrency bug but is
    // actually this test querying the wrong schema's copy of the table.
    const rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT COUNT(*) FROM public.service_catalog WHERE scope IS NULL
    ,
        &.{},
    );
    defer {
        var r = rows;
        r.deinit();
    }
    // No rows should have NULL scope (the DEFAULT 'global' ensures this).
    const count_str: []const u8 = if (rows.rows.len > 0 and rows.rows[0][0] != null)
        rows.rows[0][0].?
    else
        "0";
    const count = std.fmt.parseInt(i64, count_str, 10) catch 0;
    try std.testing.expect(count == 0);
}

// ---------------------------------------------------------------------------
// TC-SVC-01-06: listServicesForTenant filters correctly via store API
// ---------------------------------------------------------------------------

test "svc01: listServicesForTenant filters correctly via store API" {
    const alloc = std.testing.allocator;

    // TestHarness ensures migrations are applied.
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const bpm = @import("bpm");
    const Pool = bpm.pool.Pool;
    const PoolConfig = bpm.pool.PoolConfig;
    const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
    const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping svc01 store API test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    // Per-test UUIDs to avoid shared state.
    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);

    var svc_glb_id_buf: [28]u8 = undefined;
    const svc_glb_id = try std.fmt.bufPrint(&svc_glb_id_buf, "svc-lst-g-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    fillRandom(&rand_bytes);
    var svc_scpd_id_buf: [28]u8 = undefined;
    const svc_scpd_id = try std.fmt.bufPrint(&svc_scpd_id_buf, "svc-lst-s-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    fillRandom(&rand_bytes);
    var svc_other_id_buf: [28]u8 = undefined;
    const svc_other_id = try std.fmt.bufPrint(&svc_other_id_buf, "svc-lst-o-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // Insert fixture tenants for real — see insertTenantViaPool()'s doc
    // comment (ISS-0144 / GitHub #454).
    const tenant_a_hex = try randomUuidStr(alloc);
    defer alloc.free(tenant_a_hex);
    const tenant_b_hex = try randomUuidStr(alloc);
    defer alloc.free(tenant_b_hex);
    try insertTenantViaPool(alloc, &pool, tenant_a_hex, "svc01-lst-a");
    try insertTenantViaPool(alloc, &pool, tenant_b_hex, "svc01-lst-b");

    // Parse tenant UUIDs into [16]u8.
    const tid_a = try parseUuid36(tenant_a_hex);
    const tid_b = try parseUuid36(tenant_b_hex);

    // Register: global, tenant-A scoped, tenant-B scoped.
    const rec_glb = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_glb_id,
        .endpoint_url = "https://example.com/glb",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .global,
        .owner_tenant_id = null,
    });
    defer freeServiceRecord(alloc, rec_glb);

    const rec_scpd = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_scpd_id,
        .endpoint_url = "https://example.com/scpd",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_a,
    });
    defer freeServiceRecord(alloc, rec_scpd);

    const rec_other = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_other_id,
        .endpoint_url = "https://example.com/other",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_b,
    });
    defer freeServiceRecord(alloc, rec_other);

    // List for tenant A: must include global + A-scoped, must NOT include B-scoped.
    const list_a = try catalog.listServicesForTenant(alloc, tid_a, null, 200);
    defer {
        for (list_a) |r| freeServiceRecord(alloc, r);
        alloc.free(list_a);
    }

    var found_glb = false;
    var found_scpd = false;
    var found_other = false;
    for (list_a) |r| {
        if (std.mem.eql(u8, r.service_id, svc_glb_id)) found_glb = true;
        if (std.mem.eql(u8, r.service_id, svc_scpd_id)) found_scpd = true;
        if (std.mem.eql(u8, r.service_id, svc_other_id)) found_other = true;
    }
    try std.testing.expect(found_glb);
    try std.testing.expect(found_scpd);
    try std.testing.expect(!found_other); // B's scoped service must NOT appear for A.
}

// ---------------------------------------------------------------------------
// TC-SVC-01-07: getServiceForTenant returns ServiceNotFound for cross-tenant scoped service
// ---------------------------------------------------------------------------

test "svc01: getServiceForTenant returns ServiceNotFound for cross-tenant service" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const bpm = @import("bpm");
    const Pool = bpm.pool.Pool;
    const PoolConfig = bpm.pool.PoolConfig;
    const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
    const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;
    const CatalogError = bpm.service_catalog.CatalogError;

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [28]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-xscp-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // Insert the owner fixture tenant for real — see insertTenantViaPool()'s
    // doc comment (ISS-0144 / GitHub #454). tid_caller does not need a row:
    // it is only passed to getServiceForTenant() as the requesting tenant.
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    const caller_hex = try randomUuidStr(alloc);
    defer alloc.free(caller_hex);
    try insertTenantViaPool(alloc, &pool, owner_hex, "svc01-xscp-owner");

    const tid_owner = try parseUuid36(owner_hex);
    const tid_caller = try parseUuid36(caller_hex);

    const rec = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_id,
        .endpoint_url = "https://example.com/xscp",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_owner,
    });
    defer freeServiceRecord(alloc, rec);

    // Owner can fetch it.
    const rec_owner = try catalog.getServiceForTenant(alloc, svc_id, tid_owner);
    defer freeServiceRecord(alloc, rec_owner);
    try std.testing.expectEqualStrings(svc_id, rec_owner.service_id);

    // Caller (different tenant) must get ServiceNotFound.
    try std.testing.expectError(CatalogError.ServiceNotFound, catalog.getServiceForTenant(alloc, svc_id, tid_caller));
}

// ---------------------------------------------------------------------------
// TC-SVC-01-08: registerService stores scope and owner_tenant_id correctly
// ---------------------------------------------------------------------------

test "svc01: registerService stores scope and owner_tenant_id correctly" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const bpm = @import("bpm");
    const Pool = bpm.pool.Pool;
    const PoolConfig = bpm.pool.PoolConfig;
    const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
    const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [28]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-reg-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // ISS-0144 / GitHub #454: insert the fixture tenant via `pool` (the same
    // pool ServiceCatalog.registerService() below acquires connections
    // from), not `h.conn`. TestHarness.init() holds h.conn inside an
    // explicit transaction that is only ever rolled back in deinit(), so an
    // INSERT issued there is invisible to any other session under Postgres's
    // default READ COMMITTED isolation — including registerService()'s own
    // pool.acquire() call, whose `SELECT id FROM public.tenant WHERE id =
    // $1::uuid` existence check would otherwise always see zero rows and
    // return CatalogError.TenantNotFound, exactly as observed here before
    // this fix.
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);

    const tid_owner = try parseUuid36(owner_hex);
    try insertTenantViaPool(alloc, &pool, owner_hex, "svc01-reg");

    const rec = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_id,
        .endpoint_url = "https://example.com/reg",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 7000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_owner,
    });
    defer freeServiceRecord(alloc, rec);

    try std.testing.expectEqual(bpm.service_catalog.ServiceScope.tenant, rec.scope);
    try std.testing.expect(rec.owner_tenant_id != null);
    try std.testing.expect(std.mem.eql(u8, &rec.owner_tenant_id.?, &tid_owner));

    // Confirm persistence via getService (no scope filter — admin path).
    const fetched = try catalog.getService(alloc, svc_id);
    defer freeServiceRecord(alloc, fetched);
    try std.testing.expectEqual(bpm.service_catalog.ServiceScope.tenant, fetched.scope);
    try std.testing.expect(fetched.owner_tenant_id != null);
}

// ---------------------------------------------------------------------------
// TC-SVC-01-09: registerService rejects scope=global with owner_tenant_id
// ---------------------------------------------------------------------------

test "svc01: registerService rejects scope=global with owner_tenant_id" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const bpm = @import("bpm");
    const Pool = bpm.pool.Pool;
    const PoolConfig = bpm.pool.PoolConfig;
    const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
    const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;
    const CatalogError = bpm.service_catalog.CatalogError;

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [28]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-bad2-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // Per-test-generated UUID for the spurious owner (see
    // docs/guides/test_infrastructure_guide.md §9 / ISS-0121 — hardcoded
    // literals are forbidden even for "doesn't matter" fixture values).
    var some_tid: [16]u8 = undefined;
    fillRandom(&some_tid);

    try std.testing.expectError(
        CatalogError.InvalidScopeConstraint,
        catalog.registerService(alloc, RegisterServiceParams{
            .service_id = svc_id,
            .endpoint_url = "https://bad.example.com",
            .request_schema = "{}",
            .response_schema = "{}",
            .required_auth = .NONE,
            .timeout_ms = 5000,
            .retry_policy = null,
            .scope = .global,
            .owner_tenant_id = some_tid, // invalid: global + non-null owner
        }),
    );
}

// ---------------------------------------------------------------------------
// TC-SVC-01-10: listServicesForTenant with nil tenant returns all entries
// ---------------------------------------------------------------------------

test "svc01: listServicesForTenant with nil tenant returns all entries" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const bpm = @import("bpm");
    const Pool = bpm.pool.Pool;
    const PoolConfig = bpm.pool.PoolConfig;
    const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
    const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_a_id_buf: [28]u8 = undefined;
    const svc_a_id = try std.fmt.bufPrint(&svc_a_id_buf, "svc-all-g-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});
    fillRandom(&rand_bytes);
    var svc_b_id_buf: [28]u8 = undefined;
    const svc_b_id = try std.fmt.bufPrint(&svc_b_id_buf, "svc-all-s-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // Insert the fixture tenant for real — see insertTenantViaPool()'s doc
    // comment (ISS-0144 / GitHub #454).
    const tenant_all_hex = try randomUuidStr(alloc);
    defer alloc.free(tenant_all_hex);
    const tid_all = try parseUuid36(tenant_all_hex);
    try insertTenantViaPool(alloc, &pool, tenant_all_hex, "svc01-all");

    const rec_a = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_a_id,
        .endpoint_url = "https://example.com/a",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .global,
        .owner_tenant_id = null,
    });
    defer freeServiceRecord(alloc, rec_a);

    const rec_b = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_b_id,
        .endpoint_url = "https://example.com/b",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_all,
    });
    defer freeServiceRecord(alloc, rec_b);

    // nil caller_tenant_id → admin path → all entries returned.
    const all_list = try catalog.listServicesForTenant(alloc, null, null, 200);
    defer {
        for (all_list) |r| freeServiceRecord(alloc, r);
        alloc.free(all_list);
    }

    var found_a = false;
    var found_b = false;
    for (all_list) |r| {
        if (std.mem.eql(u8, r.service_id, svc_a_id)) found_a = true;
        if (std.mem.eql(u8, r.service_id, svc_b_id)) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b); // Tenant-scoped service must appear in admin listing.
}

// ---------------------------------------------------------------------------
// Helpers used by the extended tests
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

fn freeServiceRecord(alloc: std.mem.Allocator, rec: @import("bpm").service_catalog.ServiceCatalogRecord) void {
    alloc.free(rec.service_id);
    alloc.free(rec.endpoint_url);
    alloc.free(rec.request_schema);
    alloc.free(rec.response_schema);
    alloc.free(rec.retry_policy);
}
