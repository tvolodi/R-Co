//! Integration tests for EXP-601 tier-to-quota enforcement.
//!
//! Uses a real PostgreSQL database and isolated tenant fixtures. Each test
//! provisions its own tenant schema, seeds only the rows it needs, and relies on
//! the shared quota-policy and quota-enforcement modules rather than stubs.
const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const quota_policy = @import("../../src/config/quota_policy.zig");
const quota_middleware = @import("../../src/api/middleware/quota_enforcement.zig");

fn insertQuotaPolicyArtifact(conn: *bpm.pool.Conn, artifact_id: []const u8, version_id: []const u8, content_json: []const u8) !void {
    try conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  content_hash, content_type, byte_size,
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_json, parent_version_id, created_at
        \\) VALUES (
        \\  convert_to(($1::text || ':' || $2::text || ':' || $3::text || ':' || $4::text), 'UTF8'),
        \\  'application/json',
        \\  octet_length($4::text),
        \\  $1::uuid, $2::uuid, 'config', 'tier_quota_policy',
        \\  $4::jsonb, NULL, NOW()
        \\)
    , &.{ artifact_id, version_id, "tier_quota_policy", content_json });
}

fn ensureQuotaPolicyActivation(conn: *bpm.pool.Conn, tenant_id: []const u8, version_id: []const u8) !void {
    try conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1::uuid, 'config', 'tier_quota_policy', $2::uuid, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = EXCLUDED.active_version_id,
        \\    activated_at = NOW()
    , &.{ tenant_id, version_id });
}

fn zeroQuotaPolicyJson() []const u8 {
    return "{\"version\":\"1\",\"default_tier\":\"standard\",\"tiers\":{\"standard\":{\"script_cpu_millis_per_request\":0,\"script_memory_bytes_per_request\":0,\"max_entity_records_total\":0,\"max_entity_storage_bytes\":0,\"max_file_bytes_total\":0,\"max_file_count_total\":0,\"max_concurrent_sandboxes\":0,\"max_agent_retries_per_job\":0,\"max_agent_retries_per_day\":0}}}";
}

fn generousQuotaPolicyJson() []const u8 {
    return "{\"version\":\"1\",\"default_tier\":\"standard\",\"tiers\":{\"standard\":{\"script_cpu_millis_per_request\":5000,\"script_memory_bytes_per_request\":67108864,\"max_entity_records_total\":10,\"max_entity_storage_bytes\":1024,\"max_file_bytes_total\":1024,\"max_file_count_total\":10,\"max_concurrent_sandboxes\":1,\"max_agent_retries_per_job\":1,\"max_agent_retries_per_day\":5}}}";
}

test "TC-EXP-601-01: quota policy resolves the effective profile from the active config surface" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_with_policy = try harness.newUuidString(alloc);
    defer alloc.free(tenant_with_policy);
    const tenant_without_policy = try harness.newUuidString(alloc);
    defer alloc.free(tenant_without_policy);

    try harness.provisionTenant(tenant_with_policy);
    try harness.provisionTenant(tenant_without_policy);
    harness.setTenant(tenant_with_policy);

    try insertQuotaPolicyArtifact(&harness.conn, "e6010000-0000-0000-0000-000000000010", "e6010000-0000-0000-0000-000000000011", generousQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_with_policy, "e6010000-0000-0000-0000-000000000011");

    harness.setTenant(tenant_with_policy);
    const with_profile = try quota_policy.loadEffectiveQuotaProfile(alloc, &harness.pool, tenant_with_policy);
    try testing.expectEqualStrings(tenant_with_policy, with_profile.tenant_id);
    try testing.expectEqual(quota_policy.TierName.standard, with_profile.tier);
    try testing.expectEqual(@as(u64, 10), with_profile.max_entity_records_total);
    try testing.expectEqual(@as(u32, 1), with_profile.max_concurrent_sandboxes);

    harness.setTenant(tenant_without_policy);
    const default_profile = try quota_policy.loadEffectiveQuotaProfile(alloc, &harness.pool, tenant_without_policy);
    try testing.expectEqualStrings(tenant_without_policy, default_profile.tenant_id);
    try testing.expect(default_profile.max_entity_records_total > 10);
    try testing.expect(default_profile.max_file_count_total > 10);
}

test "TC-EXP-601-02: quota middleware rejects entity writes when entity limits are exceeded" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    try insertQuotaPolicyArtifact(&harness.conn, "e6010000-0000-0000-0000-000000000020", "e6010000-0000-0000-0000-000000000021", zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, "e6010000-0000-0000-0000-000000000021");
    try harness.conn.exec("INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)", &.{ "e6010000-0000-0000-0000-000000002011", "e6010000-0000-0000-0000-000000002012" });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const result = try quota_middleware.check(alloc, &harness.pool, .{
        .tenant_id = tenant_id,
        .target = .entity_write,
        .requested_delta = 1,
        .request_path = "/api/v1/entities/customer",
        .request_method = .POST,
    });

    switch (result) {
        .allowed => return error.TestUnexpectedResult,
        .rejected => |handler_result| {
            try testing.expectEqual(@as(u16, 429), handler_result.status_code);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "quota-exceeded") != null);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "entity_records") != null);
        },
    }
}

test "TC-EXP-601-03: quota middleware rejects file writes when file limits are exceeded" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    try insertQuotaPolicyArtifact(&harness.conn, "e6010000-0000-0000-0000-000000000030", "e6010000-0000-0000-0000-000000000031", zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, "e6010000-0000-0000-0000-000000000031");
    try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  content_hash, content_type, byte_size,
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_json, parent_version_id, created_at
        \\) VALUES (
        \\  convert_to(('file-fixture:' || $1::text || ':' || $2::text || ':' || $3::text), 'UTF8'),
        \\  'application/json',
        \\  octet_length($3::text),
        \\  $1::uuid, $2::uuid, 'file', 'exp601-file',
        \\  $3::jsonb, NULL, NOW()
        \\)
    , &.{ "e6010000-0000-0000-0000-000000002021", "e6010000-0000-0000-0000-000000002022", "{\"kind\":\"file\"}" });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const result = try quota_middleware.check(alloc, &harness.pool, .{
        .tenant_id = tenant_id,
        .target = .file_write,
        .requested_delta = 1,
        .request_path = "/api/v1/files/upload",
        .request_method = .POST,
    });

    switch (result) {
        .allowed => return error.TestUnexpectedResult,
        .rejected => |handler_result| {
            try testing.expectEqual(@as(u16, 429), handler_result.status_code);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "quota-exceeded") != null);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "file_count") != null or std.mem.indexOf(u8, handler_result.body, "file_bytes") != null);
        },
    }
}

test "TC-EXP-601-04: quota middleware rejects sandbox allocation and agent retries through the same guard path" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    try insertQuotaPolicyArtifact(&harness.conn, "e6010000-0000-0000-0000-000000000040", "e6010000-0000-0000-0000-000000000041", zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, "e6010000-0000-0000-0000-000000000041");
    try harness.conn.exec("INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at) VALUES ($1::uuid, 'sandbox', $2::uuid, 'EXP601_NODE', NOW()) ON CONFLICT (instance_id, ref_id) DO NOTHING", &.{ "e6010000-0000-0000-0000-000000002031", "e6010000-0000-0000-0000-000000002032" });
    try harness.conn.exec("INSERT INTO dead_letter_items (id, tenant_id, retry_count, created_at, updated_at) VALUES ($1::uuid, $2::uuid, 1, NOW(), NOW())", &.{ "e6010000-0000-0000-0000-000000002041", tenant_id });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const sandbox_result = try quota_middleware.check(alloc, &harness.pool, .{
        .tenant_id = tenant_id,
        .target = .sandbox_allocate,
        .requested_delta = 1,
        .request_path = "/api/v1/sandbox/claim",
        .request_method = .POST,
    });
    switch (sandbox_result) {
        .allowed => return error.TestUnexpectedResult,
        .rejected => |handler_result| {
            try testing.expectEqual(@as(u16, 429), handler_result.status_code);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "concurrent_sandboxes") != null);
        },
    }

    const retry_result = try quota_middleware.check(alloc, &harness.pool, .{
        .tenant_id = tenant_id,
        .target = .agent_retry,
        .requested_delta = 1,
        .request_path = "/api/v1/agent/jobs/abc/retry",
        .request_method = .POST,
    });
    switch (retry_result) {
        .allowed => return error.TestUnexpectedResult,
        .rejected => |handler_result| {
            try testing.expectEqual(@as(u16, 429), handler_result.status_code);
            try testing.expect(std.mem.indexOf(u8, handler_result.body, "agent_retry") != null);
        },
    }
}

test "TC-EXP-601-05: quota target classification maps supported write routes and rejects unsupported or read-only requests" {
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, .entity_write), quota_middleware.classifyTarget("/api/v1/entities/customer/1", .POST));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, .file_write), quota_middleware.classifyTarget("/api/v1/files/upload", .POST));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, .sandbox_allocate), quota_middleware.classifyTarget("/api/v1/sandbox/claim", .POST));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, .agent_retry), quota_middleware.classifyTarget("/api/v1/agent/jobs/123/retry", .POST));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, .script_execute), quota_middleware.classifyTarget("/api/v1/scripts/run", .POST));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, null), quota_middleware.classifyTarget("/api/v1/instances", .GET));
    try testing.expectEqual(@as(?quota_middleware.QuotaGuardTarget, null), quota_middleware.classifyTarget("/api/v1/unknown", .POST));
}
