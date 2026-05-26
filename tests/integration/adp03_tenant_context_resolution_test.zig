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

test "TC-ADP-03-03: tenant_id claim scopes DB session tenant context" {
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

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{resolved.tenant_id[0..]});

    const row = (try conn.queryRow(alloc, "SELECT bpm_effective_tenant_id()::text", &.{})) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| alloc.free(v);
        alloc.free(row);
    }

    const tenant_value = row[0] orelse "";
    try std.testing.expectEqualStrings(tenant_b, tenant_value);
}

test "TC-ADP-03-04: malformed tenant claim is rejected before scoped operations" {
    const alloc = std.testing.allocator;
    const bad_token = try makeJwtLikeToken(alloc, "{\"tenant_id\":\"not-a-uuid\"}");
    defer alloc.free(bad_token);

    try std.testing.expectError(error.InvalidTenantClaimFormat, auth.resolveTenantContext(alloc, bad_token));
}

test "TC-ADP-03-05: cross-tenant reads are blocked within a request tenant scope" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "adp03-tenant-isolation-def";
    const actor = "00000000-0000-0000-0000-000000000123";

    var id_a: [64]u8 = undefined;
    var id_b: [64]u8 = undefined;

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    const row_a = (try conn.queryRow(
        alloc,
        \\INSERT INTO process_definitions
        \\  (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1, '1.0.0', 'tenant-a', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
        \\RETURNING id::text
    ,
        &.{ name, actor },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row_a[0]) |v| alloc.free(v);
        alloc.free(row_a);
    }
    const id_text_a = row_a[0] orelse return error.TestUnexpectedResult;
    @memset(id_a[0..], 0);
    @memcpy(id_a[0..id_text_a.len], id_text_a);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    const row_b = (try conn.queryRow(
        alloc,
        \\INSERT INTO process_definitions
        \\  (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1, '1.0.0', 'tenant-b', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
        \\RETURNING id::text
    ,
        &.{ name, actor },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row_b[0]) |v| alloc.free(v);
        alloc.free(row_b);
    }
    const id_text_b = row_b[0] orelse return error.TestUnexpectedResult;
    @memset(id_b[0..], 0);
    @memcpy(id_b[0..id_text_b.len], id_text_b);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    const row_a_view = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM process_definitions WHERE id = $1::uuid AND tenant_id = bpm_effective_tenant_id()",
        &.{std.mem.sliceTo(&id_b, 0)},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row_a_view[0]) |v| alloc.free(v);
        alloc.free(row_a_view);
    }
    try std.testing.expectEqual(@as(i64, 0), parseCount(row_a_view[0] orelse "0"));

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    const row_b_view = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM process_definitions WHERE id = $1::uuid AND tenant_id = bpm_effective_tenant_id()",
        &.{std.mem.sliceTo(&id_a, 0)},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row_b_view[0]) |v| alloc.free(v);
        alloc.free(row_b_view);
    }
    try std.testing.expectEqual(@as(i64, 0), parseCount(row_b_view[0] orelse "0"));

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{});
}

test "TC-ADP-03-06: cross-tenant mutation attempts are rejected by tenant-scoped predicates" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "adp03-tenant-mutation-def";
    const actor = "00000000-0000-0000-0000-000000000124";

    var id_b: [64]u8 = undefined;

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    const created_b = (try conn.queryRow(
        alloc,
        \\INSERT INTO process_definitions
        \\  (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1, '1.0.0', 'tenant-b-original', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
        \\RETURNING id::text
    ,
        &.{ name, actor },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (created_b[0]) |v| alloc.free(v);
        alloc.free(created_b);
    }
    const id_text_b = created_b[0] orelse return error.TestUnexpectedResult;
    @memset(id_b[0..], 0);
    @memcpy(id_b[0..id_text_b.len], id_text_b);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    const blocked = try conn.queryRow(
        alloc,
        "UPDATE process_definitions SET description = 'mutated-by-tenant-a' WHERE id = $1::uuid AND tenant_id = bpm_effective_tenant_id() RETURNING id::text",
        &.{std.mem.sliceTo(&id_b, 0)},
    );
    try std.testing.expect(blocked == null);

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    const verify_row = (try conn.queryRow(
        alloc,
        "SELECT description FROM process_definitions WHERE id = $1::uuid AND tenant_id = bpm_effective_tenant_id()",
        &.{std.mem.sliceTo(&id_b, 0)},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (verify_row[0]) |v| alloc.free(v);
        alloc.free(verify_row);
    }
    try std.testing.expectEqualStrings("tenant-b-original", verify_row[0] orelse "");

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    _ = conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{});
}

test "TC-ADP-03-07: legacy default-tenant compatibility is preserved for request persistence flow" {
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

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    // Simulate legacy/default request flow where tenant is resolved then DB defaults apply.
    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{resolved.tenant_id[0..]});
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'adp03-default-compat', 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_id, definition_id },
    );

    const tenant_row = (try conn.queryRow(
        alloc,
        "SELECT tenant_id::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (tenant_row[0]) |v| alloc.free(v);
        alloc.free(tenant_row);
    }
    try std.testing.expectEqualStrings(default_tenant, tenant_row[0] orelse "");

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    const hidden_from_other_tenant = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM instance_projections WHERE instance_id = $1::uuid AND tenant_id = bpm_effective_tenant_id()",
        &.{instance_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (hidden_from_other_tenant[0]) |v| alloc.free(v);
        alloc.free(hidden_from_other_tenant);
    }
    try std.testing.expectEqual(@as(i64, 0), parseCount(hidden_from_other_tenant[0] orelse "0"));

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{default_tenant});
    _ = conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    try conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{});
}
