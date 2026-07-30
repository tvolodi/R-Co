// tests/integration/iss0076_secrets_table_test.zig
// Requirements: EXP-501 (regression coverage for ISS-0076 / GitHub #335)
//
// migrations/GBL-100_exp501_secrets.sql originally guarded its entire body
// (including CREATE TABLE secrets) on `to_regclass('instance_projections')
// IS NOT NULL`. Because GBL-prefixed migrations run only against the public
// schema, and instance_projections was permanently dropped from public by
// GBL-073_tnt01_drop_legacy_public_business_tables.sql, that guard always
// evaluated false: the secrets table was never created in any environment,
// and Store.putSecret()/resolveSecret() would fail with a
// relation-does-not-exist error at the DB layer.
//
// This suite verifies, against a real PostgreSQL database, that:
//   1) the `secrets` table exists in the public schema after migrating, and
//   2) Store.putSecret() + Store.resolveSecret() round-trip successfully
//      through it end-to-end (the actual failure mode described in #335).
//
// BPM_TEST_DB_URL must be set; TestHarness.init() applies all pending
// migrations (including the GBL-101 corrective migration) before each test.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const secrets = bpm.secrets;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0076 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn randomSuffix(allocator: std.mem.Allocator) ![]u8 {
    var raw: [8]u8 = undefined;
    std.testing.io.random(&raw);
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
    });
}

test "TC-ISS-0076-01: secrets table exists in public schema after migration" {
    const allocator = testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    // TestHarness.init() sets search_path to tenant_default,public — query
    // pg_tables directly by schema to avoid relying on unqualified name
    // resolution, matching the issue's own diagnostic method.
    var rows = try h.conn.query(
        allocator,
        "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'secrets'",
        &.{},
    );
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "TC-ISS-0076-02: Store.putSecret + resolveSecret round-trip against the real secrets table" {
    const allocator = testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 2 });
    defer pool.deinit();

    var store = try secrets.Store.init(allocator, &pool, .{
        .wrapping_key_ref = "local:test-master",
        .wrapping_key_version = "v1",
        .master_key_hex = "abababababababababababababababababababababababababababababababab",
    });

    const suffix = try randomSuffix(allocator);
    defer allocator.free(suffix);
    const name = try std.fmt.allocPrint(allocator, "iss0076-{s}", .{suffix});
    defer allocator.free(name);

    const plaintext = "super-secret-value-iss-0076";

    const put_result = try store.putSecret(allocator, .{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .namespace = "webhook",
        .name = name,
        .purpose = .webhook_hmac,
        .plaintext_value = plaintext,
        .key_id = null,
        .actor_id = "iss0076-test",
    });
    defer put_result.deinit(allocator);

    const resolved = try store.resolveSecret(allocator, .{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .secret_ref = put_result.secret_ref,
        .consumer = .webhook_dispatcher,
    });
    defer resolved.deinit(allocator);

    try testing.expectEqualStrings(plaintext, resolved.value);
}
