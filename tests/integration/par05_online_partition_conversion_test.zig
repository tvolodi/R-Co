//! Integration tests for PAR-05 (online partition conversion —
//! src/db/partition_conversion.zig).
//!
//! Fixture note (see tests/specs/PAR-05.md's "Scoping / fixture note" and
//! src/design/par-05-online-partition-conversion.md's Open questions §2):
//! PAR-05 converts an EXISTING, populated, UNPARTITIONED `events` table — the
//! pre-PAR-01 shape. A freshly migrated bpm_test always takes PAR-01's
//! from-scratch path (1147_par01_events_partitioning.sql unconditionally
//! DROP TABLE IF EXISTS events and rebuilds it PARTITION BY RANGE), so the
//! real tenant_default.events table can never be exercised by this module.
//!
//! Every test below therefore builds its OWN isolated PostgreSQL schema
//! (CREATE SCHEMA par05_test_<uuid>) containing a pre-PAR-01-shaped
//! unpartitioned `events` table plus the sibling tables PartitionConverter
//! touches (plat_event_idempotency, plat_partition_catalog), points ONE held
//! connection's search_path at that schema for the test's entire duration
//! (Pool.acquire() resets search_path on every call, so the SAME *db.Conn is
//! reused across every PartitionConverter method call rather than
//! re-acquiring), and drops the schema (CASCADE) on exit. This never touches
//! the shared tenant_default.events table any other concurrently-running
//! test-integration binary depends on — every statement
//! partition_conversion.zig/partition_attach.zig issues is unqualified and
//! resolves through search_path / ::regclass (confirmed by reading both
//! files in full), so schema isolation is sound.
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const bpm = @import("bpm");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PartitionConverter = bpm.partition_conversion.PartitionConverter;
const ConversionConfig = bpm.partition_conversion.ConversionConfig;
const ConversionError = bpm.partition_conversion.ConversionError;
const MonthRange = bpm.partition_conversion.MonthRange;

// Root-level export required so pool connections apply tenant-schema
// search_path instead of falling back to search_path=public.
pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping PAR-05 integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    // pool_size must be >= 2 (Pool.init()'s InvalidPoolSize floor) even though
    // this file only ever acquires ONE connection and holds it for the whole
    // test — search_path isolation requires never re-acquiring mid-test.
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 2 });
}

/// A short, collision-safe schema name: "par05_" + 8 random hex chars. Real
/// PostgreSQL identifiers allow this length comfortably; kept short because
/// this name is interpolated into DDL identifier position (never user input,
/// always this test's own freshly-generated randomness).
fn randomSchemaName(buf: *[14]u8) []const u8 {
    var raw: [4]u8 = undefined;
    helpers.fillRandom(&raw);
    return std.fmt.bufPrint(buf, "par05_{x:0>8}", .{std.mem.readInt(u32, &raw, .big)}) catch unreachable;
}

/// Build the pre-PAR-01 unpartitioned `events` shape (001_event_store.sql's
/// original DDL, before 1147_par01_events_partitioning.sql's PARTITION BY
/// RANGE rebuild) inside the CURRENT search_path's first schema. Also creates
/// plat_partition_catalog (PAR-02 shape) since reconcileOrRollback() queries
/// it, and the tenant_id column PAR-04's CHECK-before-attach discipline
/// requires on every partition (attachPartitionTimed() -> verifyAttachConstraints()
/// looks for a "tenant_id ... IS NOT NULL" CHECK).
fn createUnpartitionedEventsFixture(conn: *bpm.pool.Conn) !void {
    // PRIMARY KEY (event_id, created_at) — the WIDENED composite key
    // 1147_par01_events_partitioning.sql's Migration 1 gives the partitioned
    // `events` table (a partitioned table's unique/PK index must include the
    // partition key, per PostgreSQL's own requirement quoted in that
    // migration's comments). partition_conversion.zig's Step 4/Step 5
    // `INSERT INTO events_part ... ON CONFLICT (event_id, created_at) DO
    // NOTHING` requires a matching unique constraint to exist on
    // events_part, which `CREATE TABLE events_part (LIKE events INCLUDING
    // DEFAULTS INCLUDING IDENTITY)` only copies from `events` itself
    // (INCLUDING IDENTITY does not imply INCLUDING CONSTRAINTS) — so this
    // fixture's `events` must already declare the composite PK, matching the
    // real pre-partition-conversion source table's actual shape, not
    // 001_event_store.sql's single-column PK (which predates the PAR-01
    // composite-key widening this conversion assumes as its starting point;
    // see the design's own Scoping note: "an already-populated,
    // unpartitioned `events` table" — that table, by the time PAR-05 is
    // relevant, already carries the composite PK from whatever prior
    // migration widened it in a real pre-PAR-01-conversion database).
    try conn.exec(
        \\CREATE TABLE events (
        \\    event_id          UUID            DEFAULT gen_random_uuid(),
        \\    instance_id       UUID            NOT NULL,
        \\    event_type        TEXT            NOT NULL,
        \\    payload           JSONB           NOT NULL DEFAULT '{}',
        \\    actor_id          UUID            NOT NULL,
        \\    tenant_id         UUID            NOT NULL,
        \\    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
        \\    sequence_number   BIGINT          NOT NULL,
        \\    idempotency_key   TEXT            NOT NULL,
        \\    metadata          JSONB           NOT NULL DEFAULT '{}',
        \\    global_seq        BIGINT          NOT NULL,
        \\    PRIMARY KEY (event_id, created_at)
        \\)
    ,
        &.{},
    );
    // ISS-0681 / GH-724 (REWORK 3): must match 1148_par02_partition_catalog.sql's
    // real column set exactly — backfillOneMonth()/swap() now go through
    // partition_maintenance.zig's upsertPartitionCatalogRow()/UPDATE
    // statements, which reference created_at/updated_at (the same columns
    // ensurePartitionAttached() already relies on for its own catalog
    // upsert). The prior narrower fixture shape (missing both timestamp
    // columns) predates that call path and no longer matches production.
    try conn.exec(
        "CREATE TABLE plat_partition_catalog (" ++
            "id uuid PRIMARY KEY DEFAULT gen_random_uuid(), " ++
            "table_name text NOT NULL UNIQUE, parent_table text NOT NULL, " ++
            "range_start timestamptz NOT NULL, range_end timestamptz NOT NULL, " ++
            "state text NOT NULL DEFAULT 'ATTACHED', " ++
            "created_at timestamptz NOT NULL DEFAULT now(), " ++
            "updated_at timestamptz NOT NULL DEFAULT now())",
        &.{},
    );
}

/// Insert `count` rows into `events` spread evenly across the given month
/// window [start_us, end_us), each with a fresh random UUID/idempotency_key
/// (per-test-UUID fixture isolation — no static IDs).
fn insertEventsInMonth(alloc: std.mem.Allocator, conn: *bpm.pool.Conn, month: MonthRange, count: u32, seq_start: *i64) !void {
    var i: u32 = 0;
    const span = month.end_us - month.start_us;
    while (i < count) : (i += 1) {
        const offset_us = if (count > 1) @divFloor(span * @as(i64, i), @as(i64, count)) else 0;
        const ts_text = try bpm.partition_maintenance.formatTimestamptzLiteral(alloc, month.start_us + offset_us);
        defer alloc.free(ts_text);
        const inst_bytes = helpers.randomUuidBytes();
        const inst_hex = try helpers.uuidBytesToString(alloc, inst_bytes);
        defer alloc.free(inst_hex);
        const idem = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
        defer alloc.free(idem);
        seq_start.* += 1;
        var seq_buf: [24]u8 = undefined;
        const seq_text = std.fmt.bufPrint(&seq_buf, "{d}", .{seq_start.*}) catch unreachable;
        var gseq_buf: [24]u8 = undefined;
        const gseq_text = std.fmt.bufPrint(&gseq_buf, "{d}", .{seq_start.*}) catch unreachable;

        try conn.exec(
            \\INSERT INTO events (instance_id, event_type, payload, actor_id, tenant_id,
            \\    created_at, sequence_number, idempotency_key, global_seq)
            \\VALUES ($1::uuid, 'PAR05_TEST_EVENT', '{}', $1::uuid, $1::uuid,
            \\    $2::timestamptz, $3, $4, $5)
        ,
            &.{ inst_hex, ts_text, seq_text, idem, gseq_text },
        );
    }
}

fn countRows(alloc: std.mem.Allocator, conn: *bpm.pool.Conn, table_name: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) FROM {s}", .{table_name});
    defer alloc.free(sql);
    var rows = try conn.query(alloc, sql, &.{});
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0].len == 0 or rows.rows[0][0] == null) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0].?, 10) catch 0;
}

fn relationExists(alloc: std.mem.Allocator, conn: *bpm.pool.Conn, name: []const u8) !bool {
    const row = try conn.queryRow(
        alloc,
        "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = $1 AND n.nspname = current_schema()",
        &.{name},
    );
    if (row) |r| {
        for (r) |c| if (c) |v| alloc.free(v);
        alloc.free(r);
        return true;
    }
    return false;
}

fn isPartitioned(alloc: std.mem.Allocator, conn: *bpm.pool.Conn, name: []const u8) !bool {
    const row = try conn.queryRow(
        alloc,
        "SELECT 1 FROM pg_partitioned_table pt JOIN pg_class c ON c.oid = pt.partrelid WHERE c.relname = $1 AND c.relnamespace = current_schema()::regnamespace",
        &.{name},
    );
    if (row) |r| {
        for (r) |c| if (c) |v| alloc.free(v);
        alloc.free(r);
        return true;
    }
    return false;
}

/// Full setup shared by every test: acquire ONE connection, create+select an
/// isolated schema, build the pre-PAR-01 events fixture inside it. Returns
/// the connection (search_path already pointed at the new schema) and the
/// schema name (caller must defer dropSchema()).
const Fixture = struct {
    pool: Pool,
    conn: *bpm.pool.Conn,
    schema_buf: [14]u8,
    schema_name: []const u8,

    fn init(alloc: std.mem.Allocator, url: []const u8) !Fixture {
        var pool = try makePool(alloc, url);
        errdefer pool.deinit();
        const conn = try pool.acquire();

        var f = Fixture{ .pool = pool, .conn = conn, .schema_buf = undefined, .schema_name = undefined };
        f.schema_name = randomSchemaName(&f.schema_buf);

        const create_schema_sql = try std.fmt.allocPrint(alloc, "CREATE SCHEMA {s}", .{f.schema_name});
        defer alloc.free(create_schema_sql);
        try conn.exec(create_schema_sql, &.{});

        const set_path_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}", .{f.schema_name});
        defer alloc.free(set_path_sql);
        try conn.exec(set_path_sql, &.{});

        try createUnpartitionedEventsFixture(conn);
        return f;
    }

    /// Never re-acquire from `pool` before calling this — that would reset
    /// search_path back to tenant_default,public (Pool.acquire()'s
    /// applyRequestStorageRouting()) and break schema isolation mid-test.
    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        const drop_sql = std.fmt.allocPrint(alloc, "DROP SCHEMA IF EXISTS {s} CASCADE", .{self.schema_name}) catch {
            self.pool.release(self.conn);
            self.pool.deinit();
            return;
        };
        defer alloc.free(drop_sql);
        self.conn.exec(drop_sql, &.{}) catch {};
        // Reset search_path before releasing back to the pool so a later
        // acquire (by a DIFFERENT test in the same binary, after this pool
        // is deinit'd — not applicable here since we own this Pool
        // exclusively, but kept for defensive hygiene) never inherits a
        // dropped schema.
        self.conn.exec("SET search_path TO public", &.{}) catch {};
        self.pool.release(self.conn);
        self.pool.deinit();
    }
};

// ---------------------------------------------------------------------------
// TC-PAR-05-01: parent creation alongside the live table
// ---------------------------------------------------------------------------

test "TC-PAR-05-01: createParent builds events_part partitioned parent; events untouched" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    // Populate events with rows in one month so row-count checks are meaningful.
    const month = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 0);
    var seq: i64 = 0;
    try insertEventsInMonth(alloc, fx.conn, month, 5, &seq);

    const before_count = try countRows(alloc, fx.conn, "events");
    try std.testing.expectEqual(@as(i64, 5), before_count);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    try converter.createParent(alloc, fx.conn);

    try std.testing.expect(try relationExists(alloc, fx.conn, "events_part"));
    try std.testing.expect(try isPartitioned(alloc, fx.conn, "events_part"));

    // events itself is untouched: same row count, still NOT partitioned.
    const after_count = try countRows(alloc, fx.conn, "events");
    try std.testing.expectEqual(@as(i64, 5), after_count);
    try std.testing.expect(!try isPartitioned(alloc, fx.conn, "events"));

    // The live table continues to accept appends unchanged after createParent().
    const extra_inst = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(extra_inst);
    const extra_idem = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(extra_idem);
    try fx.conn.exec(
        \\INSERT INTO events (instance_id, event_type, payload, actor_id, tenant_id,
        \\    created_at, sequence_number, idempotency_key, global_seq)
        \\VALUES ($1::uuid, 'PAR05_TEST_EVENT', '{}', $1::uuid, $1::uuid, NOW(), 999, $2, 999)
    ,
        &.{ extra_inst, extra_idem },
    );
    const after_append_count = try countRows(alloc, fx.conn, "events");
    try std.testing.expectEqual(@as(i64, 6), after_append_count);

    // Idempotent: a second createParent() call is a no-op, not an error.
    try converter.createParent(alloc, fx.conn);
}

// ---------------------------------------------------------------------------
// TC-PAR-05-02: PartitionRangeGap on empty events table
// ---------------------------------------------------------------------------

test "TC-PAR-05-02: validateCoverage on empty events table returns PartitionRangeGap" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    const result = converter.validateCoverage(alloc, fx.conn);
    try std.testing.expectError(ConversionError.PartitionRangeGap, result);

    // No DDL ran as a result: events_part must not exist.
    try std.testing.expect(!try relationExists(alloc, fx.conn, "events_part"));
}

// ---------------------------------------------------------------------------
// TC-PAR-05-03: backfill loop idempotent under interruption/re-run
// ---------------------------------------------------------------------------

// KNOWN FAILING against current code — ISS-0676 / GH-718 (filed during this
// same handoff): PartitionConverter.createParent() builds events_part via
// CREATE TABLE (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY), which
// copies NO constraints — events_part has no (event_id, created_at) unique
// constraint, so the ON CONFLICT (event_id, created_at) DO NOTHING clause
// this test's first backfillAllMonths() call relies on fails with real
// PostgreSQL error 42P10 ("no unique or exclusion constraint matching the ON
// CONFLICT specification"). This is real, correct fail-first signal for
// PAR-05 AC1/AC3 — the requirement's idempotent-backfill guarantee does not
// hold against a real database today. Do NOT silence/skip; fix ISS-0676
// instead (this test, and TC-PAR-05-04/-05/-06 below which build on the same
// backfilled state, will pass once events_part carries the constraint).
test "TC-PAR-05-03: backfillAllMonths re-run absorbs duplicates via ON CONFLICT DO NOTHING" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    const month0 = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 0);
    const month1 = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 1);
    var seq: i64 = 0;
    try insertEventsInMonth(alloc, fx.conn, month0, 4, &seq);
    try insertEventsInMonth(alloc, fx.conn, month1, 3, &seq);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    try converter.createParent(alloc, fx.conn);
    try converter.createAndBackfillIdempotency(alloc, fx.conn);

    const months = [_]MonthRange{ month0, month1 };
    try converter.backfillAllMonths(alloc, fx.conn, &months);

    const first_run_count = try countRows(alloc, fx.conn, "events_part");
    try std.testing.expectEqual(@as(i64, 7), first_run_count);

    // Re-run (simulated interruption/retry) against the SAME months list.
    try converter.backfillAllMonths(alloc, fx.conn, &months);

    const second_run_count = try countRows(alloc, fx.conn, "events_part");
    try std.testing.expectEqual(first_run_count, second_run_count);
}

// ---------------------------------------------------------------------------
// TC-PAR-05-04: swap renames tables
// ---------------------------------------------------------------------------

test "TC-PAR-05-04: swap renames events->events_legacy and events_part->events" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    const month0 = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 0);
    var seq: i64 = 0;
    try insertEventsInMonth(alloc, fx.conn, month0, 3, &seq);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    try converter.createParent(alloc, fx.conn);
    try converter.createAndBackfillIdempotency(alloc, fx.conn);
    const months = [_]MonthRange{month0};
    try converter.backfillAllMonths(alloc, fx.conn, &months);

    try converter.swap(alloc, fx.conn);

    // events_legacy is the ORIGINAL unpartitioned table (3 rows, not partitioned).
    try std.testing.expect(try relationExists(alloc, fx.conn, "events_legacy"));
    try std.testing.expect(!try isPartitioned(alloc, fx.conn, "events_legacy"));
    const legacy_count = try countRows(alloc, fx.conn, "events_legacy");
    try std.testing.expectEqual(@as(i64, 3), legacy_count);

    // events is now the (renamed) partitioned parent.
    try std.testing.expect(try relationExists(alloc, fx.conn, "events"));
    try std.testing.expect(try isPartitioned(alloc, fx.conn, "events"));
    try std.testing.expect(!try relationExists(alloc, fx.conn, "events_part"));
}

// ---------------------------------------------------------------------------
// TC-PAR-05-05: reconciliation passes when counts match
// ---------------------------------------------------------------------------

test "TC-PAR-05-05: reconcileOrRollback succeeds when per-month counts match" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    const month0 = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 0);
    var seq: i64 = 0;
    try insertEventsInMonth(alloc, fx.conn, month0, 4, &seq);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    try converter.createParent(alloc, fx.conn);
    try converter.createAndBackfillIdempotency(alloc, fx.conn);
    const months = [_]MonthRange{month0};
    try converter.backfillAllMonths(alloc, fx.conn, &months);
    try converter.swap(alloc, fx.conn);

    try converter.reconcileOrRollback(alloc, fx.conn);

    // No inverse rename occurred: `events` (not events_part_failed) still
    // holds the live, partitioned table.
    try std.testing.expect(!try relationExists(alloc, fx.conn, "events_part_failed"));
    try std.testing.expect(try isPartitioned(alloc, fx.conn, "events"));
}

// ---------------------------------------------------------------------------
// TC-PAR-05-06: mismatch triggers ConversionRowCountMismatch + inverse rename
// ---------------------------------------------------------------------------

test "TC-PAR-05-06: reconcileOrRollback on row-count mismatch inverse-renames and returns error" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var fx = try Fixture.init(alloc, url);
    defer fx.deinit(alloc);

    const month0 = bpm.partition_maintenance.monthRange(bpm.partition_maintenance.yearMonthToUs(2020, 1), 0);
    var seq: i64 = 0;
    try insertEventsInMonth(alloc, fx.conn, month0, 4, &seq);

    var converter = PartitionConverter.init(&fx.pool, ConversionConfig{});
    try converter.createParent(alloc, fx.conn);
    try converter.createAndBackfillIdempotency(alloc, fx.conn);
    const months = [_]MonthRange{month0};
    try converter.backfillAllMonths(alloc, fx.conn, &months);
    try converter.swap(alloc, fx.conn);

    const pre_swap_count = try countRows(alloc, fx.conn, "events_legacy");
    try std.testing.expectEqual(@as(i64, 4), pre_swap_count);

    // Deliberately delete one row from the new (post-swap) events partition
    // for month0, so this month's count(*) diverges from events_legacy's.
    const suffix = month0.suffix;
    const del_sql = try std.fmt.allocPrint(alloc, "DELETE FROM events_{s} WHERE ctid = (SELECT ctid FROM events_{s} LIMIT 1)", .{ suffix, suffix });
    defer alloc.free(del_sql);
    try fx.conn.exec(del_sql, &.{});

    const result = converter.reconcileOrRollback(alloc, fx.conn);
    try std.testing.expectError(ConversionError.ConversionRowCountMismatch, result);

    // Inverse rename already executed: the mutated table is now
    // events_part_failed, and events_legacy has been renamed back to events.
    try std.testing.expect(try relationExists(alloc, fx.conn, "events_part_failed"));
    try std.testing.expect(try relationExists(alloc, fx.conn, "events"));
    try std.testing.expect(!try relationExists(alloc, fx.conn, "events_legacy"));

    // The restored `events` is the ORIGINAL unpartitioned table with the
    // original, unmutated row count.
    try std.testing.expect(!try isPartitioned(alloc, fx.conn, "events"));
    const restored_count = try countRows(alloc, fx.conn, "events");
    try std.testing.expectEqual(pre_swap_count, restored_count);
}
