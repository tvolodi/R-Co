// Tests for OBP-01 migration 1167: depth_refreshed_at column on plat_outbox_gate,
// and OBP-02 migration seed: EXECUTION_INGRESS_REFUSED in event_type_registry.
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.

const std = @import("std");
const helpers = @import("helpers.zig");
const bpm = @import("bpm");
const env = @import("env");

fn requireTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const environ = env.globalEnviron();
    return environ.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — cannot run OBP-01 migration contract tests\n",
                .{},
            );
            return error.MissingTestDbUrl;
        },
        else => return err,
    };
}

test "obp01_plat_outbox_gate_depth_ts: TC-OBP-01-depth-refreshed-at-exists" {
    // covers: OBP-01 — depth_refreshed_at column exists on plat_outbox_gate and is NOT NULL.
    _ = try requireTestDbUrl(std.testing.allocator);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var result = try h.conn.query(
        std.testing.allocator,
        \\SELECT column_name, is_nullable
        \\FROM information_schema.columns
        \\WHERE table_name = 'plat_outbox_gate'
        \\  AND column_name = 'depth_refreshed_at'
        \\  AND table_schema = current_schema()
    ,
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("depth_refreshed_at", result.rows[0][0] orelse "");
    // The column is nullable — freshly provisioned rows have NULL until the drainer writes.
    const is_nullable = result.rows[0][1] orelse "NO";
    try std.testing.expectEqualStrings("YES", is_nullable);
}

test "obp01_plat_outbox_gate_depth_ts: TC-OBP-01-depth-refreshed-at-independent-of-state-transition" {
    // covers: OBP-01 AC3 — a state-column UPDATE does not advance depth_refreshed_at.
    _ = try requireTestDbUrl(std.testing.allocator);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const uuid = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(uuid);
    const tenant = try std.fmt.allocPrint(std.testing.allocator, "obp01-ts-{s}", .{uuid});
    defer std.testing.allocator.free(tenant);

    // Seed a gate row with a known depth_refreshed_at value.
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate
        \\  (tenant_schema, state, depth, cap, low_water, depth_refreshed_at)
        \\VALUES
        \\  ($1, 'open', 0, 50000, 40000, now() - interval '10 seconds')
    ,
        &.{tenant},
    );

    // Record the original depth_refreshed_at.
    var before = try h.conn.query(
        std.testing.allocator,
        "SELECT depth_refreshed_at::text FROM plat_outbox_gate WHERE tenant_schema = $1",
        &.{tenant},
    );
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.rows.len);
    const ts_before = before.rows[0][0] orelse return error.MissingTimestamp;

    // Update only the state column.
    try h.conn.exec(
        "UPDATE plat_outbox_gate SET state = 'closed' WHERE tenant_schema = $1",
        &.{tenant},
    );

    // depth_refreshed_at must be unchanged.
    var after_result = try h.conn.query(
        std.testing.allocator,
        "SELECT depth_refreshed_at::text FROM plat_outbox_gate WHERE tenant_schema = $1",
        &.{tenant},
    );
    defer after_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), after_result.rows.len);
    const ts_after = after_result.rows[0][0] orelse return error.MissingTimestamp;
    try std.testing.expectEqualStrings(ts_before, ts_after);
}

test "obp01_plat_outbox_gate_depth_ts: TC-OBP-01-stale-after-5s" {
    // covers: OBP-01 AC3 — a depth_refreshed_at > 5 s old is treated as stale.
    _ = try requireTestDbUrl(std.testing.allocator);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const uuid = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(uuid);
    const tenant = try std.fmt.allocPrint(std.testing.allocator, "obp01-stale-{s}", .{uuid});
    defer std.testing.allocator.free(tenant);

    // Seed a row with depth_refreshed_at 6 s in the past.
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate
        \\  (tenant_schema, state, depth, cap, low_water, depth_refreshed_at)
        \\VALUES
        \\  ($1, 'open', 0, 50000, 40000, now() - interval '6 seconds')
    ,
        &.{tenant},
    );

    // The age of depth_refreshed_at must exceed 5 s (= stale threshold).
    var staleness = try h.conn.query(
        std.testing.allocator,
        \\SELECT (EXTRACT(EPOCH FROM (now() - depth_refreshed_at)) > 5)::text AS is_stale
        \\FROM plat_outbox_gate
        \\WHERE tenant_schema = $1
    ,
        &.{tenant},
    );
    defer staleness.deinit();
    try std.testing.expectEqual(@as(usize, 1), staleness.rows.len);
    try std.testing.expectEqualStrings("true", staleness.rows[0][0] orelse "false");
}

test "obp01_plat_outbox_gate_depth_ts: TC-OBP-02-ingress-refused-event-seeded" {
    // covers: OBP-02 — EXECUTION_INGRESS_REFUSED is seeded in event_type_registry.
    _ = try requireTestDbUrl(std.testing.allocator);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var result = try h.conn.query(
        std.testing.allocator,
        "SELECT COUNT(*)::int AS n FROM event_type_registry WHERE name = 'EXECUTION_INGRESS_REFUSED'",
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("1", result.rows[0][0] orelse "0");
}
