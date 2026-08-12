// Integration tests for PAR-06's instance_projections schema slice
// (migration 1150_par06_instance_projections_event_window.sql), hand-written
// from templates/specs/par06-instance-projections-event-window.migration.yaml's
// test scaffold (the codegen'd draft assertions are demoted to comments by
// tools/codegen_migration.py per lint Y134 — filled in here for real).
//
// Covers ONLY the migration's schema slice (columns + index) per the YAML's
// own header note; the bounded-query/repair-path behaviour specified by the
// companion Type E design (src/design/par-06-time-bounded-reconstruction.md)
// is exercised by src/engine/reconstruction.zig's reconstructInstance()/
// eventWindowForInstanceInTx() and Store.append() call paths (see
// par06_reconstruction_bounded_test.zig; store.zig's now-deleted
// Store.reconstructBounded() was dead code, removed via GH-716), not
// re-tested here.
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.
const std = @import("std");
const helpers = @import("helpers.zig");

test "par06_instance_projections_event_window: new_columns_exist_and_are_nullable" {
    // instance_projections carries first_event_at/last_event_at, both nullable.
    // covers: PAR-06
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var rows = try h.conn.query(
        alloc,
        \\SELECT column_name, is_nullable FROM information_schema.columns
        \\WHERE table_name = 'instance_projections'
        \\  AND table_schema = 'tenant_default'
        \\  AND column_name IN ('first_event_at', 'last_event_at')
        \\ORDER BY column_name
    ,
        &.{},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
    // ORDER BY column_name ASC: 'first_event_at' < 'last_event_at'.
    try std.testing.expectEqualStrings("first_event_at", rows.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("YES", rows.rows[0][1] orelse "");
    try std.testing.expectEqualStrings("last_event_at", rows.rows[1][0] orelse "");
    try std.testing.expectEqualStrings("YES", rows.rows[1][1] orelse "");
}

test "par06_instance_projections_event_window: pre_migration_instance_has_null_window" {
    // An instance row inserted with no first_event_at/last_event_at supplied
    // still has NULL columns — the migration itself performs no backfill.
    // covers: PAR-06
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const instance_id = try h.newUuidString(alloc);
    defer alloc.free(instance_id);
    const definition_id = try h.newUuidString(alloc);
    defer alloc.free(definition_id);

    defer h.conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (tenant_id, instance_id, definition_id, status, current_nodes, variables, last_event_seq, started_at, updated_at)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0, NOW(), NOW())
    ,
        &.{ instance_id, definition_id },
    );

    var rows = try h.conn.query(
        alloc,
        "SELECT first_event_at, last_event_at FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expect(rows.rows[0][0] == null);
    try std.testing.expect(rows.rows[0][1] == null);
}

test "par06_instance_projections_event_window: index_supports_bounded_lookup" {
    // idx_instance_projections_event_window exists and covers
    // (instance_id, first_event_at, last_event_at) for the bounded-query
    // lookup the companion Type E design's Public interface performs before
    // every reconstruction.
    // covers: PAR-06
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var rows = try h.conn.query(
        alloc,
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_instance_projections_event_window' AND schemaname = 'tenant_default'",
        &.{},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const indexdef = rows.rows[0][0] orelse "";
    try std.testing.expect(std.mem.indexOf(u8, indexdef, "instance_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, indexdef, "first_event_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, indexdef, "last_event_at") != null);
    // Column order: instance_id before first_event_at before last_event_at.
    const instance_pos = std.mem.indexOf(u8, indexdef, "instance_id").?;
    const first_pos = std.mem.indexOf(u8, indexdef, "first_event_at").?;
    const last_pos = std.mem.indexOf(u8, indexdef, "last_event_at").?;
    try std.testing.expect(instance_pos < first_pos);
    try std.testing.expect(first_pos < last_pos);
}
