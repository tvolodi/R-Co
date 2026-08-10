const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

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
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 3 });
}

/// ISS-0659 / GH-681: self-managed-pool binary must serialize against
/// TestHarness peers via the bpm_test_migrations_public advisory lock for the
/// binary's full lifetime. PR #494 / ISS-0162 extended this lock inside
/// TestHarness.init(); this entry point lets a makePool-based binary acquire
/// the same lock around its own test block. Pair with
/// `helpers.releaseIntegrationLock(&lock_conn)` via defer at the top of every
/// `test` block.
fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

test "TC-ADM-UI-09-INT-01: GET /health/ready returns readiness payload used by the admin dashboard" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var readiness = bpm.api_health_readiness.ReadinessService.init(alloc, &pool, &.{});

    const result = bpm.health_routes.handleReady(alloc, &pool, &readiness);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"db_latency_ms\":") != null);
}
