// Minimal reproducer for GH-758: acquireIntegrationLock + minimal pool + exit.
// Goal: determine whether the hang is in the lock acquire, the pool init, or
// the pool use.
//
// NOT wired into any build step. Run by hand with:
//   zig test tests/integration/repro_g758.zig \
//     --mod bpm::src/bpm.zig --deps bpm \
//     -test-filter 'repro_g758' \
//     -lc -lpthread -lpq
// (Most operators use the existing tests/integration/*.zig files via
//  `zig build test-integration-<solo>` instead.)
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const bpm = @import("bpm");
const pool_mod = bpm.db_pool;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
}

test "repro_g758: acquire lock, init pool, single ping, release" {
    std.debug.print("repro_g758: STEP 1: acquireIntegrationLock\n", .{});
    var lock_conn = try helpers.acquireIntegrationLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);
    std.debug.print("repro_g758: STEP 2: lock acquired\n", .{});

    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    std.debug.print("repro_g758: STEP 3: pool.init (5 conns)\n", .{});
    var pool = try pool_mod.Pool.init(std.testing.io, alloc, .{ .url = url, .pool_size = 5 });
    defer pool.deinit();
    std.debug.print("repro_g758: STEP 4: pool ready\n", .{});

    std.debug.print("repro_g758: STEP 5: pool.acquire\n", .{});
    const conn = try pool.acquire();
    defer pool.release(conn);
    std.debug.print("repro_g758: STEP 6: conn acquired\n", .{});

    std.debug.print("repro_g758: STEP 7: SELECT 1\n", .{});
    const row = (try conn.queryRow(alloc, "SELECT 1::int", &.{})) orelse return error.TestUnexpectedResult;
    defer alloc.free(row);
    std.debug.print("repro_g758: STEP 8: SELECT 1 returned {any}\n", .{if (row.len > 0) row[0] else null});

    std.debug.print("repro_g758: DONE\n", .{});
}
