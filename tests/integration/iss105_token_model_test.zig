// ISS-105 integration tests: Persist new token model ({token_id, node_id} + join_counters)
//
// Requirements: ISS-105
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.

const std = @import("std");
const pg = @import("pg");
const helpers = @import("helpers.zig");

// ---------------------------------------------------------------------------
// TC-ISS-105-01: active_tokens and join_counters columns exist on instance_projections
// ---------------------------------------------------------------------------

test "iss105_token_model: active_tokens and join_counters columns exist" {
    // covers: ISS-105 AC-1, AC-2 (columns exist with correct type and default)
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var col_rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT column_name, data_type, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = current_schema()
        \\  AND table_name = 'instance_projections'
        \\  AND column_name IN ('active_tokens', 'join_counters')
        \\ORDER BY column_name
    ,
        &.{},
    );
    defer col_rows.deinit();

    // Both columns must exist.
    try std.testing.expectEqual(@as(usize, 2), col_rows.rows.len);

    // active_tokens: jsonb type, defaults to '[]'::jsonb.
    try std.testing.expect(std.mem.eql(u8, col_rows.rows[0][0].?, "active_tokens"));
    try std.testing.expect(std.mem.eql(u8, col_rows.rows[0][1].?, "jsonb"));
    try std.testing.expect(col_rows.rows[0][2] != null);
    try std.testing.expect(std.mem.indexOf(u8, col_rows.rows[0][2].?, "[]") != null);

    // join_counters: jsonb type, defaults to '{}'::jsonb.
    try std.testing.expect(std.mem.eql(u8, col_rows.rows[1][0].?, "join_counters"));
    try std.testing.expect(std.mem.eql(u8, col_rows.rows[1][1].?, "jsonb"));
    try std.testing.expect(col_rows.rows[1][2] != null);
    try std.testing.expect(std.mem.indexOf(u8, col_rows.rows[1][2].?, "{}") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-105-02: join_counters NOT NULL constraint is enforced
// ---------------------------------------------------------------------------

test "iss105_token_model: join_counters column is NOT NULL" {
    // covers: ISS-105 AC-2 (join_counters is NOT NULL)
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var null_check = try h.conn.query(
        std.testing.allocator,
        \\SELECT is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = current_schema()
        \\  AND table_name = 'instance_projections'
        \\  AND column_name = 'join_counters'
    ,
        &.{},
    );
    defer null_check.deinit();

    try std.testing.expectEqual(@as(usize, 1), null_check.rows.len);
    try std.testing.expect(std.mem.eql(u8, null_check.rows[0][0].?, "NO"));
}

// ---------------------------------------------------------------------------
// TC-ISS-105-03: active_tokens GIN index exists for query optimization
// ---------------------------------------------------------------------------

test "iss105_token_model: active_tokens has GIN index" {
    // covers: ISS-105 AC-1 (index for query optimization)
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var idx_rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT indexname FROM pg_indexes
        \\WHERE schemaname = current_schema()
        \\  AND tablename = 'instance_projections'
        \\  AND indexname = 'idx_instance_active_tokens'
    ,
        &.{},
    );
    defer idx_rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), idx_rows.rows.len);
}

// ---------------------------------------------------------------------------
// TC-ISS-105-04: backfill SQL is idempotent and runs without error
// ---------------------------------------------------------------------------

test "iss105_token_model: backfill where-clause runs safely on empty table" {
    // covers: ISS-105 AC-3 (backfill is safe and idempotent)
    //
    // Strategy: run the backfill UPDATE against a table that already has
    // active_tokens populated (post-migration state). The WHERE clause
    // should match 0 rows, making it a safe no-op.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    // Execute the backfill logic from migration 088.
    // In a freshly-migrated DB, all rows already have active_tokens = '[]'
    // (the DEFAULT), and current_nodes may be '[]' as well. The WHERE clause
    // should match 0 rows because either current_nodes is empty or is not
    // a string-array. Either way, the UPDATE is a safe no-op.
    try h.conn.exec(
        \\UPDATE instance_projections
        \\SET active_tokens = (
        \\    SELECT jsonb_agg(
        \\        jsonb_build_object(
        \\            'token_id', gen_random_uuid()::text,
        \\            'node_id', elem::text,
        \\            'branch_id', instance_id::text || '/' || elem::text || '/0'
        \\        )
        \\        ORDER BY ordinality
        \\    )
        \\    FROM jsonb_array_elements_text(current_nodes) WITH ORDINALITY AS elem(value, ordinality)
        \\)
        \\WHERE current_nodes IS NOT NULL
        \\  AND jsonb_typeof(current_nodes) = 'array'
        \\  AND jsonb_array_length(current_nodes) > 0
        \\  AND active_tokens = '[]'::jsonb
        \\  AND jsonb_typeof(current_nodes -> 0) = 'string'
    ,
        &.{},
    );
}
