const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const auth = bpm.api_auth;

const default_tenant = "00000000-0000-0000-0000-000000000000";
const tenant_b = "22222222-2222-2222-2222-222222222222";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set -- skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn parseCount(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

fn makeJwtLikeToken(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(payload_json.len);
    const encoded_payload = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded_payload);
    _ = encoder.encode(encoded_payload, payload_json);
    return std.fmt.allocPrint(allocator, "h.{s}.s", .{encoded_payload});
}

test "TC-ADP-03-01: legacy token without tenant claim resolves deterministically to default tenant" {
    const resolved_first = try auth.resolveTenantContext(std.testing.allocator, "legacy-opaque-token");
    const resolved_second = try auth.resolveTenantContext(std.testing.allocator, "legacy-opaque-token");

    try std.testing.expectEqualStrings(default_tenant, resolved_first.tenant_id[0..]);
    try std.testing.expectEqual(auth.TenantContextSource.default_fallback, resolved_first.source);
    try std.testing.expectEqualStrings(resolved_first.tenant_id[0..], resolved_second.tenant_id[0..]);
    try std.testing.expectEqual(resolved_first.source, resolved_second.source);
}

test "TC-ADP-03-02: tenant_id claim resolves deterministically to claim tenant" {
    const alloc = std.testing.allocator;
    const token = try makeJwtLikeToken(alloc, "{\"tenant_id\":\"22222222-2222-2222-2222-222222222222\"}");
    defer alloc.free(token);

    const resolved_first = try auth.resolveTenantContext(alloc, token);
    const resolved_second = try auth.resolveTenantContext(alloc, token);

    try std.testing.expectEqualStrings(tenant_b, resolved_first.tenant_id[0..]);
    try std.testing.expectEqual(auth.TenantContextSource.token_claim, resolved_first.source);
    try std.testing.expectEqualStrings(resolved_first.tenant_id[0..], resolved_second.tenant_id[0..]);
    try std.testing.expectEqual(resolved_first.source, resolved_second.source);
}

test "TC-ADP-03-03: bpm_effective_tenant_id() returns the default UUID stub after SPT-02" {
    // After migration 062 and 066, bpm_effective_scope_context() is a stub that always
    // returns '00000000-0000-0000-0000-000000000000' regardless of session config.
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const token = try makeJwtLikeToken(alloc, "{\"tenant_id\":\"22222222-2222-2222-2222-222222222222\"}");
    defer alloc.free(token);

    const resolved = try auth.resolveTenantContext(alloc, token);
    try std.testing.expectEqual(auth.TenantContextSource.token_claim, resolved.source);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // The function is now a stub and always returns the default UUID.
    const row = (try conn.queryRow(alloc, "SELECT bpm_effective_tenant_id()::text", &.{})) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| alloc.free(v);
        alloc.free(row);
    }

    const tenant_value = row[0] orelse "";
    try std.testing.expectEqualStrings(default_tenant, tenant_value);
}

test "TC-ADP-03-04: malformed tenant claim is rejected before scoped operations" {
    const alloc = std.testing.allocator;
    const bad_token = try makeJwtLikeToken(alloc, "{\"tenant_id\":\"not-a-uuid\"}");
    defer alloc.free(bad_token);

    try std.testing.expectError(error.InvalidTenantClaimFormat, auth.resolveTenantContext(alloc, bad_token));
}

test "TC-ADP-03-05: process definitions persist correctly without tenant_id after SPT-02" {
    // After migration 062, process_definitions no longer has a row-level scope column.
    // Definitions are globally unique by (name, version) via uq_definition_name_version.
    // This test verifies that two definitions with different names can coexist.
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_a = "adp03-def-a";
    const name_b = "adp03-def-b";
    const actor = "00000000-0000-0000-0000-000000000123";

    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = conn.exec("DELETE FROM process_definitions WHERE name IN ($1, $2)", &.{ name_a, name_b }) catch {};
    defer {
        conn.exec("DELETE FROM process_definitions WHERE name IN ($1, $2)", &.{ name_a, name_b }) catch {};
    }

    // Insert two definitions (scope column no longer exists).
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (name, version, description, status, graph, created_by)
        \\VALUES
        \\  ($1, '1.0.0', 'def-a', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
    ,
        &.{ name_a, actor },
    );
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (name, version, description, status, graph, created_by)
        \\VALUES
        \\  ($1, '1.0.0', 'def-b', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
    ,
        &.{ name_b, actor },
    );

    // Both definitions are accessible from any connection (no RLS after SPT-02).
    var a_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM process_definitions WHERE name = $1 AND version = '1.0.0'",
        &.{name_a},
    );
    defer a_rows.deinit();
    var b_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM process_definitions WHERE name = $1 AND version = '1.0.0'",
        &.{name_b},
    );
    defer b_rows.deinit();

    const a_count = std.fmt.parseInt(i64, a_rows.rows[0][0] orelse "0", 10) catch 0;
    const b_count = std.fmt.parseInt(i64, b_rows.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 1), a_count);
    try std.testing.expectEqual(@as(i64, 1), b_count);
}

test "TC-ADP-03-06: process definition updates work globally without tenant-scoped predicates" {
    // After migration 062, the scope column is gone from process_definitions.
    // Updates are no longer tenant-scoped; any connection can update any row.
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "adp03-tenant-mutation-def";
    const actor = "00000000-0000-0000-0000-000000000124";

    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    defer conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};

    // Insert a definition (scope column was removed by SPT-02).
    const created = (try conn.queryRow(
        alloc,
        \\INSERT INTO process_definitions
        \\  (name, version, description, status, graph, created_by)
        \\VALUES
        \\  ($1, '1.0.0', 'original', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
        \\RETURNING id::text
    ,
        &.{ name, actor },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (created[0]) |v| alloc.free(v);
        alloc.free(created);
    }
    const def_id = created[0] orelse return error.TestUnexpectedResult;

    // UPDATE succeeds without tenant-scoped predicate (no RLS after SPT-02).
    const updated = try conn.queryRow(
        alloc,
        "UPDATE process_definitions SET description = 'updated' WHERE id = $1::uuid RETURNING id::text",
        &.{def_id},
    );
    defer if (updated) |row| {
        if (row[0]) |v| alloc.free(v);
        alloc.free(row);
    };
    try std.testing.expect(updated != null);

    // Verify the update persisted.
    const verify_row = (try conn.queryRow(
        alloc,
        "SELECT description FROM process_definitions WHERE id = $1::uuid",
        &.{def_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (verify_row[0]) |v| alloc.free(v);
        alloc.free(verify_row);
    }
    try std.testing.expectEqualStrings("updated", verify_row[0] orelse "");
}

test "TC-ADP-03-07: instance projections work without tenant_id after SPT-02" {
    // After migration 062, instance_projections no longer has a row-level scope column.
    // Instances are accessible from any connection.
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const definition_id = "55555555-5555-5555-5555-555555555550";
    const instance_id = "55555555-5555-5555-5555-555555555551";

    const resolved = try auth.resolveTenantContext(alloc, "legacy-opaque-token");
    try std.testing.expectEqualStrings(default_tenant, resolved.tenant_id[0..]);

    _ = conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    defer conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    // Insert instance projection (scope column removed in SPT-02).
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'adp03-default-compat', 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_id, definition_id },
    );

    // Verify the row is accessible without tenant filter.
    const count_row = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM instance_projections WHERE instance_id = $1::uuid AND status = 'ACTIVE'",
        &.{instance_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (count_row[0]) |v| alloc.free(v);
        alloc.free(count_row);
    }
    try std.testing.expectEqual(@as(i64, 1), parseCount(count_row[0] orelse "0"));
}
