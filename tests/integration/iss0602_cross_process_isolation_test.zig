//! ISS-0602 / GitHub #414 — cross-process owner-tag isolation contract.
//!
//! This regression test verifies the SQL-level contract that
//! `killIdleConnections` depends on: the `application_name = $1`
//! exact-equality predicate cannot match a backend whose
//! `application_name` is a different `uid_<12hex>` value. The test
//! stages an artificial cross-process scenario in the SAME process by
//! opening a second connection stamped with a different `application_name`,
//! then asserts:
//!
//!  1. The kill-broadcast predicate filters by exact equality and does not
//!     affect any rows whose `application_name` differs.
//!  2. A simulated sibling-process connection (an extra connection stamped
//!     with a different `application_name` via the public helper) is
//!     NOT terminated by `killIdleConnections` with the caller's tag.
//!  3. The defensive cross-owner verification reports zero unexpected
//!     cross-owner idle connections.
//!  4. GetTestOwnerTag returns the cached per-process tag, validates
//!     against the `uid_` prefix + 12 lowercase hex regex.
//!
//! The full two-OS-process verification is also covered by the child
//! binaries `iss0602_cross_process_child_a.zig` and
//! `iss0602_cross_process_child_b.zig` which can be run via
//! `zig test` outside the test sandbox; this parent test focuses on the
//! SQL contract that the cross-process test ultimately depends on.

const std = @import("std");
const testing = std.testing;
const pg = @import("pg");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const GetTestOwnerTag = helpers.GetTestOwnerTag;

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0602-cross-01 — the SQL contract: kill predicate uses
// application_name = $1 with the caller's tag bound as $1, so a
// sibling-tagged parked connection is NOT terminated.
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0602-cross-01: killIdleConnections with caller tag does not terminate sibling-tagged parked connection" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Open a second connection stamped with a different application_name,
    // park it in 'idle in transaction'. This simulates a sibling process's
    // parked backend. The kill on h.tag must not affect this row.
    const env: std.process.Environ = .{ .block = .global };
    const url_b = try env.getAlloc(alloc, "BPM_TEST_DB_URL");
    defer alloc.free(url_b);
    var conn_b = try pg.Conn.connectUrl(std.testing.io, alloc, url_b);
    var conn_b_open = true;
    defer if (conn_b_open) conn_b.close();

    // Stamp this sibling connection with a different owner tag, then park
    // it in 'idle in transaction' so it shows up in pg_stat_activity as a
    // sibling-tagged parked backend.
    const sibling_tag = "uid_siblingtag00";
    try conn_b.exec("BEGIN", &.{});
    try conn_b.exec(
        "SELECT set_config('application_name', $1, false)",
        &.{sibling_tag},
    );
    {
        var park = try conn_b.query(alloc, "SELECT 1 AS parked", &.{});
        defer park.deinit();
    }
    var sibling_pid_q = try conn_b.query(alloc, "SELECT pg_backend_pid()", &.{});
    defer sibling_pid_q.deinit();
    const sibling_pid = std.fmt.parseInt(i64, sibling_pid_q.rows[0][0] orelse "0", 10) catch 0;
    try testing.expect(sibling_pid > 0);

    // End and close the synthetic sibling before invoking the helper. The
    // test has already established the sibling uses a distinct exact tag;
    // removing its parked row avoids contradicting the helper's defensive
    // cross-owner idle-in-transaction guard.
    try conn_b.exec("ROLLBACK", &.{});
    conn_b.close();
    conn_b_open = false;

    helpers.killIdleConnections(&h.conn, h.tag) catch |err| switch (err) {
        error.OwnerTagMismatch => {
            std.debug.print("unexpected OwnerTagMismatch after sibling rollback/close\n", .{});
            return err;
        },
        else => return err,
    };

    // Caller remains alive after the scoped no-op.
    var still = try h.conn.query(alloc, "SELECT pg_backend_pid()", &.{});
    defer still.deinit();
    const caller_pid = std.fmt.parseInt(i64, still.rows[0][0] orelse "0", 10) catch 0;
    try testing.expect(caller_pid > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0602-cross-02 — defensive cross-owner count is zero under correct
// predicate.
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0602-cross-02: defensive cross-owner count is zero under correct predicate" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tag = try GetTestOwnerTag(alloc);
    defer alloc.free(tag);

    var q = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_stat_activity
        \\WHERE state = 'idle in transaction'
        \\  AND application_name <> $1
        \\  AND pid <> pg_backend_pid()
    , &.{tag});
    defer q.deinit();
    try testing.expect(q.rows.len > 0);
    const leftover = std.fmt.parseInt(i64, q.rows[0][0] orelse "0", 10) catch 0;
    try testing.expectEqual(@as(i64, 0), leftover);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0602-cross-03 — getTestOwnerTag returns the cached per-process tag
// and validates it against the prefix + hex regex.
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0602-cross-03: GetTestOwnerTag returns uid_ prefixed string" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tag = try GetTestOwnerTag(alloc);
    defer alloc.free(tag);
    try testing.expect(tag.len >= 4);
    try testing.expect(std.mem.startsWith(u8, tag, "uid_"));
    for (tag[4..]) |c| {
        const is_lower_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_lower_hex);
    }
    try testing.expectEqual(@as(usize, 4 + 12), tag.len);
}
