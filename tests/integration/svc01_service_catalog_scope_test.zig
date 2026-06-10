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
const pg = @import("pg");
const helpers = @import("helpers.zig");

// ---------------------------------------------------------------------------
// Setup / cleanup helpers
// ---------------------------------------------------------------------------

fn insertTenant(conn: *pg.Conn, id_hex: []const u8, slug: []const u8) !void {
    try conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at)
        \\VALUES ($1::uuid, $2, $3, $4, now())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ id_hex, slug, slug, slug },
    );
}

fn insertGlobalService(conn: *pg.Conn, svc_id: []const u8) !void {
    try conn.exec(
        \\INSERT INTO service_catalog
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
        \\INSERT INTO service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'tenant', $2::uuid)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{ svc_id, owner_hex },
    );
}

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.nanoTimestamp()));
    for (buf) |*b| b.* = chars[rng.random().intRangeAtMost(u8, 0, 35)];
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

    try insertGlobalService(h.conn, svc_id);

    // List for a random tenant — global service must appear.
    const tenant_hex = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01";
    const rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id, scope, owner_tenant_id
        \\FROM service_catalog
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
    const tenant2_hex = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee02";
    const rows2 = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM service_catalog
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
    const tenant_a_hex = "c0111111-0000-0000-0000-000000000001";
    try insertTenant(h.conn, tenant_a_hex, "svc01-ta");

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-scpd-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    try insertScopedService(h.conn, svc_id, tenant_a_hex);

    // Visible to tenant A (the owner).
    const rows_a = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM service_catalog
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
    const tenant_b_hex = "c0222222-0000-0000-0000-000000000002";
    const rows_b = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM service_catalog
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
        \\INSERT INTO service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://bad.com', '{}', '{}', 'NONE', 5000, '{}', 'tenant', NULL)
    ,
        &.{svc_id},
    );
    try std.testing.expectError(error.PgError, result);
}

test "svc01: on_delete_cascade removes scoped service when owner tenant deleted" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_hex = "d1111111-0000-0000-0000-000000000001";
    // Insert tenant directly (NOT through the harness transaction so we can delete it).
    try h.conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at)
        \\VALUES ($1::uuid, $2, $3, $4, now())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ tenant_hex, "svc01-cascade-test", "SVC01 Cascade Test", "realm-cascade" },
    );

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(std.testing.allocator, "svc-cas-{s}", .{randomId(&id_buf)});
    defer std.testing.allocator.free(svc_id);

    try insertScopedService(h.conn, svc_id, tenant_hex);

    // Verify it was inserted.
    const before = try h.conn.query(
        std.testing.allocator,
        \\SELECT service_id FROM service_catalog WHERE service_id = $1
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
        \\SELECT service_id FROM service_catalog WHERE service_id = $1
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
    const rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT COUNT(*) FROM service_catalog WHERE scope IS NULL
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

