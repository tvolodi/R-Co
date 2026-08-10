// ISS-105 integration tests: Persist new token model ({token_id, node_id} + join_counters)
//
// Requirements: ISS-105
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.

const std = @import("std");
const pg = @import("pg");
const helpers = @import("helpers.zig");

// ---------------------------------------------------------------------------
// TC-ISS-105-01: active_tokens column exists with JSONB type
// ---------------------------------------------------------------------------

test "iss105_token_model: active_tokens column exists with jsonb type" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    try h.conn.exec(
        \\ALTER TABLE instance_projections ADD COLUMN IF NOT EXISTS active_tokens JSONB NOT NULL DEFAULT '[]'
    ,
        &.{},
    );

    var col_rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT 1 FROM pg_attribute
        \\WHERE attrelid = 'instance_projections'::regclass
        \\  AND attname = 'active_tokens'
        \\  AND NOT attisdropped
    ,
        &.{},
    );
    defer col_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), col_rows.rows.len);
}

// ---------------------------------------------------------------------------
// TC-ISS-105-02: join_counters column exists with JSONB type and NOT NULL
// ---------------------------------------------------------------------------

test "iss105_token_model: join_counters column exists with jsonb not null" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    try h.conn.exec(
        \\ALTER TABLE instance_projections ADD COLUMN IF NOT EXISTS join_counters JSONB NOT NULL DEFAULT '{}'
    ,
        &.{},
    );

    var col_rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT 1 FROM pg_attribute
        \\WHERE attrelid = 'instance_projections'::regclass
        \\  AND attname = 'join_counters'
        \\  AND NOT attisdropped
    ,
        &.{},
    );
    defer col_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), col_rows.rows.len);
}

// ---------------------------------------------------------------------------
// TC-ISS-105-03: active_tokens GIN index exists
// ---------------------------------------------------------------------------

test "iss105_token_model: active_tokens has GIN index" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    try h.conn.exec(
        \\ALTER TABLE instance_projections ADD COLUMN IF NOT EXISTS active_tokens JSONB NOT NULL DEFAULT '[]'
    ,
        &.{},
    );

    try h.conn.exec(
        \\CREATE INDEX IF NOT EXISTS idx_instance_active_tokens
        \\ON instance_projections USING GIN (active_tokens)
    ,
        &.{},
    );

    // ISS-0658 (GH #679): pg_indexes is not search_path-scoped — it returns one
    // row per schema in which a same-named index exists. instance_projections
    // is provisioned into multiple schemas (public, tenant_default, and any
    // tenant schema a concurrently-running integration binary provisions
    // during a parallel `zig build test-integration` run), so an unqualified
    // WHERE tablename=... AND indexname=... match can legitimately return 2
    // or more rows even though this test's own CREATE INDEX only ran once.
    // Scope the query to the first schema on this connection's search_path
    // (the schema this test actually created the index in) using
    // pg_table_is_visible, mirroring how `attrelid = 'instance_projections'::
    // regclass` above already resolves through search_path rather than
    // scanning every schema.
    var idx_rows = try h.conn.query(
        std.testing.allocator,
        \\SELECT 1 FROM pg_indexes
        \\WHERE tablename = 'instance_projections'
        \\  AND indexname = 'idx_instance_active_tokens'
        \\  AND pg_table_is_visible((schemaname || '.' || indexname)::regclass)
    ,
        &.{},
    );
    defer idx_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), idx_rows.rows.len);
}

// ---------------------------------------------------------------------------
// TC-ISS-105-04: backfill UPDATE runs safely (no-op on empty table)
// ---------------------------------------------------------------------------

test "iss105_token_model: backfill update is safe and idempotent" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    try h.conn.exec(
        \\ALTER TABLE instance_projections ADD COLUMN IF NOT EXISTS active_tokens JSONB NOT NULL DEFAULT '[]'
    ,
        &.{},
    );
    try h.conn.exec(
        \\ALTER TABLE instance_projections ADD COLUMN IF NOT EXISTS join_counters JSONB NOT NULL DEFAULT '{}'
    ,
        &.{},
    );

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

    // Idempotent re-run.
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
