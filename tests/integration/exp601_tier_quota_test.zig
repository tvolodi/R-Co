//! Integration tests for EXP-601 tier-to-quota enforcement.
//!
//! Uses a real PostgreSQL database and isolated tenant fixtures. Each test
//! provisions its own tenant schema, seeds only the rows it needs, and relies on
//! the shared quota-policy and quota-enforcement modules rather than stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing at a real
//! PostgreSQL database — read internally by helpers.TestHarness.init().
const std = @import("std");
const testing = std.testing;
const pg = @import("pg");
const portable_env = @import("env");

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
// ISS-0137 / GH #439: reached through `bpm` rather than by relative path.
// `../../src/...` escapes the tests/integration module root, which Zig 0.16
// rejects — and every other integration test reaches src/ through this shim.
const quota_policy = bpm.quota_policy;
const quota_middleware = bpm.quota_enforcement;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// ISS-0137 / GH #439: this file called `&harness.pool`, but TestHarness has no
// `pool` field and never had one — it exposes a single `pg.Conn`. The quota
// modules under test take a real `*Pool`, so the tests build one the same way
// every other pool-using integration test here does (see
// adm_ui_09_health_test.zig / adp02_tenant_scope_test.zig). The file could not
// compile before this; nothing noticed because it was wired into no build target.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - integration test cannot run\n", .{});
            return error.TestEnvironmentMissing;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Tenant context must be set BEFORE Pool.init so every acquire() applies
    // SET search_path (schema isolation).
    bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 3 });
}

fn insertQuotaPolicyArtifact(conn: *pg.Conn, artifact_id: []const u8, version_id: []const u8, content_json: []const u8) !void {
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

fn ensureQuotaPolicyActivation(conn: *pg.Conn, tenant_id: []const u8, version_id: []const u8) !void {
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

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const tenant_with_policy = try harness.newUuidString(alloc);
    defer alloc.free(tenant_with_policy);
    const tenant_without_policy = try harness.newUuidString(alloc);
    defer alloc.free(tenant_without_policy);

    try harness.provisionTenant(tenant_with_policy);
    try harness.provisionTenant(tenant_without_policy);
    harness.setTenant(tenant_with_policy);

    const artifact_id = try harness.newUuidString(alloc);
    defer alloc.free(artifact_id);
    const version_id = try harness.newUuidString(alloc);
    defer alloc.free(version_id);

    try insertQuotaPolicyArtifact(&harness.conn, artifact_id, version_id, generousQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_with_policy, version_id);

    harness.setTenant(tenant_with_policy);
    const with_profile = try quota_policy.loadEffectiveQuotaProfile(alloc, &pool, tenant_with_policy);
    try testing.expectEqualStrings(tenant_with_policy, with_profile.tenant_id);
    try testing.expectEqual(quota_policy.TierName.standard, with_profile.tier);
    try testing.expectEqual(@as(u64, 10), with_profile.max_entity_records_total);
    try testing.expectEqual(@as(u32, 1), with_profile.max_concurrent_sandboxes);

    harness.setTenant(tenant_without_policy);
    const default_profile = try quota_policy.loadEffectiveQuotaProfile(alloc, &pool, tenant_without_policy);
    try testing.expectEqualStrings(tenant_without_policy, default_profile.tenant_id);
    try testing.expect(default_profile.max_entity_records_total > 10);
    try testing.expect(default_profile.max_file_count_total > 10);
}

test "TC-EXP-601-02: quota middleware rejects entity writes when entity limits are exceeded" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    const artifact_id = try harness.newUuidString(alloc);
    defer alloc.free(artifact_id);
    const version_id = try harness.newUuidString(alloc);
    defer alloc.free(version_id);
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const definition_id = try harness.newUuidString(alloc);
    defer alloc.free(definition_id);

    try insertQuotaPolicyArtifact(&harness.conn, artifact_id, version_id, zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, version_id);
    try harness.conn.exec("INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)", &.{ instance_id, definition_id });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const result = try quota_middleware.check(alloc, &pool, .{
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

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    const artifact_id = try harness.newUuidString(alloc);
    defer alloc.free(artifact_id);
    const version_id = try harness.newUuidString(alloc);
    defer alloc.free(version_id);
    const file_artifact_id = try harness.newUuidString(alloc);
    defer alloc.free(file_artifact_id);
    const file_version_id = try harness.newUuidString(alloc);
    defer alloc.free(file_version_id);

    try insertQuotaPolicyArtifact(&harness.conn, artifact_id, version_id, zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, version_id);
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
    , &.{ file_artifact_id, file_version_id, "{\"kind\":\"file\"}" });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const result = try quota_middleware.check(alloc, &pool, .{
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

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const tenant_id = try harness.newUuidString(alloc);
    defer alloc.free(tenant_id);
    try harness.provisionTenant(tenant_id);
    harness.setTenant(tenant_id);

    const artifact_id = try harness.newUuidString(alloc);
    defer alloc.free(artifact_id);
    const version_id = try harness.newUuidString(alloc);
    defer alloc.free(version_id);
    const wait_instance_id = try harness.newUuidString(alloc);
    defer alloc.free(wait_instance_id);
    const wait_ref_id = try harness.newUuidString(alloc);
    defer alloc.free(wait_ref_id);
    const dlq_id = try harness.newUuidString(alloc);
    defer alloc.free(dlq_id);

    try insertQuotaPolicyArtifact(&harness.conn, artifact_id, version_id, zeroQuotaPolicyJson());
    try ensureQuotaPolicyActivation(&harness.conn, tenant_id, version_id);
    try harness.conn.exec("INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at) VALUES ($1::uuid, 'sandbox', $2::uuid, 'EXP601_NODE', NOW()) ON CONFLICT (instance_id, ref_id) DO NOTHING", &.{ wait_instance_id, wait_ref_id });
    try harness.conn.exec("INSERT INTO dead_letter_items (id, tenant_id, retry_count, created_at, updated_at) VALUES ($1::uuid, $2::uuid, 1, NOW(), NOW())", &.{ dlq_id, tenant_id });

    try quota_middleware.init(alloc);
    defer quota_middleware.deinit();

    const sandbox_result = try quota_middleware.check(alloc, &pool, .{
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

    const retry_result = try quota_middleware.check(alloc, &pool, .{
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
