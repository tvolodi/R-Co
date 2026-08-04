//! ISS-0602 / GitHub #414 — cross-process child A.
//!
//! This file is invoked as a child binary by
//! `tests/integration/iss0602_cross_process_isolation_test.zig`.
//! Each child runs in its own process so its per-process owner-tag cache
//! is fresh. The child A process is the *caller* of
//! `killIdleConnections`; the child B process is the *parked target*.
//! The exact-equality predicate on `application_name` must exclude the
//! other child's backend, so child B's connection must survive.
//!
//! Exits 0 with `CROSS_PROCESS_A_OK` on stdout when all assertions pass.

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

    // Child A's tag must be a fresh per-process value.
    const my_tag = try GetTestOwnerTag(alloc);
    defer alloc.free(my_tag);
    if (!std.mem.startsWith(u8, my_tag, "uid_")) {
        std.debug.print("CROSS_PROCESS_A_FAIL: tag does not start with uid_ prefix: {s}\n", .{my_tag});
        std.process.exit(1);
    }

    // Verify the connection's application_name matches the cached tag.
    var q = try h.conn.query(alloc, "SELECT current_setting('application_name')", &.{});
    defer q.deinit();
    const app_name = q.rows[0][0] orelse "";
    if (!std.mem.eql(u8, app_name, my_tag)) {
        std.debug.print("CROSS_PROCESS_A_FAIL: application_name {s} != tag {s}\n", .{ app_name, my_tag });
        std.process.exit(1);
    }

    // Give child B time to park its connection.
    std.time.sleep(400 * std.time.ns_per_ms);

    // Call killIdleConnections. Under correct behavior the predicate
    // excludes child B's backend (different application_name), so the
    // kill is a zero-row no-op on A's own backends and must not raise
    // error.OwnerTagMismatch.
    helpers.killIdleConnections(&h.conn, h.tag) catch |err| switch (err) {
        error.OwnerTagMismatch => {
            std.debug.print("CROSS_PROCESS_A_FAIL: OwnerTagMismatch on same-process kill\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("CROSS_PROCESS_A_FAIL: killIdleConnections error: {}\n", .{err});
            std.process.exit(1);
        },
    };

    // Verify A's own connection still works (self-exclusion guard).
    var alive = try h.conn.query(alloc, "SELECT 1 AS alive, pg_backend_pid()", &.{});
    defer alive.deinit();
    const a_alive = alive.rows[0][0] orelse "0";
    if (!std.mem.eql(u8, a_alive, "1")) {
        std.debug.print("CROSS_PROCESS_A_FAIL: own connection did not survive self-exclusion\n", .{});
        std.process.exit(1);
    }

    // Print success marker on stdout.
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout.interface;
    try w.print("CROSS_PROCESS_A_OK\n", .{});
    try w.flush();
}
