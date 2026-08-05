//! ISS-0602 / GitHub #414 — cross-process child B.
//!
//! This file is invoked as a child binary by
//! `tests/integration/iss0602_cross_process_isolation_test.zig`.
//! Child B is the *parked target*: it initialises its harness, captures its
//! own `pg_backend_pid()`, then sits in `'idle in transaction'` long enough
//! for child A to run `killIdleConnections` against its own tag. Child B's
//! connection must survive because the exact-equality predicate on
//! `application_name` excludes child A's tag.
//!
//! Exits 0 with `CROSS_PROCESS_B_OK` on stdout when all assertions pass.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing at a real
//! PostgreSQL database — read internally by helpers.TestHarness.init().

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const GetTestOwnerTag = helpers.GetTestOwnerTag;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Child B's tag is generated fresh in this process.
    const my_tag = try GetTestOwnerTag(alloc);
    defer alloc.free(my_tag);
    if (!std.mem.startsWith(u8, my_tag, "uid_")) {
        std.debug.print("CROSS_PROCESS_B_FAIL: tag does not start with uid_ prefix: {s}\n", .{my_tag});
        std.process.exit(1);
    }

    // Verify the connection's application_name matches the cached tag.
    var q = try h.conn.query(alloc, "SELECT current_setting('application_name')", &.{});
    defer q.deinit();
    const app_name = q.rows[0][0] orelse "";
    if (!std.mem.eql(u8, app_name, my_tag)) {
        std.debug.print("CROSS_PROCESS_B_FAIL: application_name {s} != tag {s}\n", .{ app_name, my_tag });
        std.process.exit(1);
    }

    // Capture pid before park.
    var pre = try h.conn.query(alloc, "SELECT pg_backend_pid()", &.{});
    defer pre.deinit();
    const pid_before_str = pre.rows[0][0] orelse "0";
    const pid_before = std.fmt.parseInt(i64, pid_before_str, 10) catch 0;

    // Park in 'idle in transaction': the harness already has BEGIN open,
    // and a SELECT 1 inside the open transaction keeps the connection
    // visibly idle-in-tx for child A's kill attempt.
    var keep = try h.conn.query(alloc, "SELECT 1 AS keep_alive", &.{});
    defer keep.deinit();

    // Wait long enough that child A's killIdleConnections has definitely run.
    std.time.sleep(2 * std.time.ns_per_s);

    // Connection must still be alive.
    var post = try h.conn.query(alloc, "SELECT 1 AS alive, pg_backend_pid()", &.{});
    defer post.deinit();
    const alive = post.rows[0][0] orelse "0";
    const pid_after_str = post.rows[0][1] orelse "0";
    const pid_after = std.fmt.parseInt(i64, pid_after_str, 10) catch 0;

    if (!std.mem.eql(u8, alive, "1")) {
        std.debug.print("CROSS_PROCESS_B_FAIL: connection was terminated (alive={s})\n", .{alive});
        std.process.exit(1);
    }
    if (pid_before != pid_after) {
        std.debug.print("CROSS_PROCESS_B_FAIL: pid changed {d} -> {d}\n", .{ pid_before, pid_after });
        std.process.exit(1);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout.interface;
    try w.print("CROSS_PROCESS_B_OK\n", .{});
    try w.flush();
}
