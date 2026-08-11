//! PAR-04: AttachScanRequired CHECK-before-ATTACH validation helper.
//!
//! Provides verifyAttachConstraints() — queried immediately before PAR-02's
//! partition-creation loop or PAR-03's archival-attach logic issues
//! `ALTER TABLE ... ATTACH PARTITION ...` — and attachPartitionTimed(), the
//! thin wrapper both callers MUST use so the wall-clock 1s observation (AC3)
//! is applied uniformly rather than reimplemented per call site.
//!
//! Design artefact: src/design/par-04-attach-scan-required-check.md
//!
//! Scoping note (see the design doc in full): this is NOT DDL-01/DDL-02.
//! ddl_validate.zig validates migration file statement lists ahead of MIG-01's
//! tenant fanout — a static, pre-flight, file-linting concern with zero DB
//! access. This module answers a live-schema, runtime question ("does this
//! already-existing standalone table carry both required CHECK constraints
//! right now") that can only be answered by querying pg_constraint against a
//! real connection. The two modules solve different problems at different
//! pipeline stages; this one must not be folded into the other.
const std = @import("std");
const db = @import("pool");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A partition's intended range bounds, half-open [start, end).
/// UTC microseconds since epoch, matching store.zig's created_at_us
/// convention — callers format these as timestamptz literals when building
/// the ATTACH PARTITION / CHECK statements.
pub const PartitionRange = struct {
    start: i64,
    end: i64,
};

pub const AttachVerdict = union(enum) {
    ok,
    attach_scan_required: AttachScanRequiredDetail,
};

pub const AttachScanRequiredDetail = struct {
    table_name: []const u8,
    missing_tenant_check: bool,
    missing_or_mismatched_range_check: bool,
    /// Present only when a range CHECK exists but does not match `range` —
    /// distinguishes "no range CHECK at all" from "range CHECK present but
    /// wrong bounds". Owned by the allocator passed to
    /// verifyAttachConstraints()/attachPartitionTimed(); caller frees.
    found_range_check_def: ?[]const u8,
    /// Populated only by attachPartitionTimed()'s retroactive post-attach-
    /// timing path (PAR-04 AC3): the ATTACH PARTITION statement itself took
    /// longer than the 1s budget even though the pre-check returned .ok.
    /// Both missing_* fields are false in this case — this field is what
    /// distinguishes "constraints were fine but the attach was still slow"
    /// from an unreachable "both false, no timing issue either" state
    /// (PAR-04 design doc, Open questions §1).
    observed_duration_ms: ?u64 = null,
};

pub const PartitionAttachError = error{
    PoolExhausted,
    QueryFailed,
    /// candidate_table does not exist in the catalog at all.
    TableNotFound,
};

/// 1-second budget for a single ATTACH PARTITION statement (PAR-04 AC1/AC3).
const ATTACH_BUDGET_MS: i64 = 1000;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Query candidate_table's declared CHECK constraints and verify both
/// PAR-04-required constraints (tenant_id IS NOT NULL, and a range CHECK
/// exactly matching `range`) are present BEFORE the caller issues ATTACH
/// PARTITION. Does not itself run ATTACH PARTITION.
///
/// Schema-agnostic catalog query pitfall (docs/anti-patterns.md, "Database —
/// System Catalog Introspection"): this queries pg_constraint scoped by
/// `conrelid = candidate_table::regclass`, which resolves the table name
/// through the CALLING connection's own `search_path` to a single relation
/// OID — unlike a name-only `pg_class.relname` join (which returns one row
/// per schema containing a same-named relation), `::regclass` cast + `conrelid`
/// equality is inherently schema-scoped to whichever single table search_path
/// resolves `candidate_table` to. No `pg_namespace` join is needed here
/// because the query is anchored on `regclass` resolution, not on a bare
/// `relname` string match.
pub fn verifyAttachConstraints(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    candidate_table: []const u8,
    range: PartitionRange,
) PartitionAttachError!AttachVerdict {
    // Confirm the candidate table exists before querying its constraints —
    // to_regclass() on a nonexistent relation makes the constraint query
    // below return zero rows indistinguishably from "no constraints", which
    // would otherwise be misreported as attach_scan_required rather than
    // the real TableNotFound precondition failure both callers document as
    // "should not occur in practice" (Error taxonomy).
    const exists_row = conn.queryRow(
        allocator,
        "SELECT 1 FROM pg_class WHERE oid = to_regclass($1)",
        &.{candidate_table},
    ) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return PartitionAttachError.PoolExhausted,
        else => return PartitionAttachError.QueryFailed,
    };
    if (exists_row) |row| {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    } else {
        return PartitionAttachError.TableNotFound;
    }

    var result = conn.query(
        allocator,
        \\SELECT pg_get_constraintdef(c.oid)
        \\FROM pg_constraint c
        \\WHERE c.conrelid = $1::regclass AND c.contype = 'c'
    ,
        &.{candidate_table},
    ) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return PartitionAttachError.PoolExhausted,
        else => return PartitionAttachError.QueryFailed,
    };
    defer result.deinit();

    var has_tenant_check = false;
    var range_check_def: ?[]const u8 = null;
    var range_check_matches = false;

    for (result.rows) |row| {
        if (row.len == 0) continue;
        const def = row[0] orelse continue;
        if (std.mem.indexOf(u8, def, "tenant_id") != null and
            std.mem.indexOf(u8, def, "IS NOT NULL") != null)
        {
            has_tenant_check = true;
            continue;
        }
        if (std.mem.indexOf(u8, def, "created_at") != null) {
            // A candidate range CHECK. Verify its bounds textually match the
            // requested range by checking that both formatted microsecond
            // timestamps appear in the constraint definition PostgreSQL
            // echoes back. pg_get_constraintdef() renders the exact literal
            // bounds the CHECK was created with, so an exact substring match
            // against the same formatting this module uses to build CHECKs
            // (see partition_maintenance.zig / partition_retention.zig,
            // which both format range bounds the same way before calling
            // this function) is sufficient — a textual mismatch here means
            // the bounds genuinely differ, not merely a formatting quirk.
            const start_text = formatRangeBoundText(allocator, range.start) catch
                return PartitionAttachError.QueryFailed;
            defer allocator.free(start_text);
            const end_text = formatRangeBoundText(allocator, range.end) catch
                return PartitionAttachError.QueryFailed;
            defer allocator.free(end_text);

            if (std.mem.indexOf(u8, def, start_text) != null and
                std.mem.indexOf(u8, def, end_text) != null)
            {
                range_check_matches = true;
            }
            range_check_def = allocator.dupe(u8, def) catch return PartitionAttachError.QueryFailed;
        }
    }

    if (has_tenant_check and range_check_matches) {
        if (range_check_def) |d| allocator.free(d);
        return AttachVerdict.ok;
    }

    return AttachVerdict{ .attach_scan_required = AttachScanRequiredDetail{
        .table_name = candidate_table,
        .missing_tenant_check = !has_tenant_check,
        .missing_or_mismatched_range_check = !range_check_matches,
        .found_range_check_def = range_check_def,
    } };
}

/// Wraps a single ATTACH PARTITION statement with a wall-clock timer and
/// reinterprets an over-budget duration as AttachScanRequired even when
/// verifyAttachConstraints() returned .ok immediately before (PAR-04 AC3).
/// Callers (PAR-02, PAR-03) MUST use this wrapper rather than issuing the raw
/// ALTER TABLE statement directly.
pub fn attachPartitionTimed(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    parent_table: []const u8,
    partition_table: []const u8,
    range: PartitionRange,
) PartitionAttachError!AttachVerdict {
    const pre_check = try verifyAttachConstraints(allocator, conn, partition_table, range);
    switch (pre_check) {
        .attach_scan_required => return pre_check,
        .ok => {},
    }

    const start_text = formatTimestamptzLiteral(allocator, range.start) catch
        return PartitionAttachError.QueryFailed;
    defer allocator.free(start_text);
    const end_text = formatTimestamptzLiteral(allocator, range.end) catch
        return PartitionAttachError.QueryFailed;
    defer allocator.free(end_text);

    const sql = std.fmt.allocPrint(
        allocator,
        "ALTER TABLE {s} ATTACH PARTITION {s} FOR VALUES FROM ('{s}') TO ('{s}')",
        .{ parent_table, partition_table, start_text, end_text },
    ) catch return PartitionAttachError.QueryFailed;
    defer allocator.free(sql);

    // Table/partition names are never user input at this call site — both
    // PAR-02 and PAR-03 derive them from computed calendar-month boundaries
    // (YYYY_MM suffixes) or from plat_partition_catalog's own already-
    // validated table_name column, never from unsanitised external input.
    // $N placeholders cannot bind identifiers (table/partition names), only
    // values — the same constraint PAR-01's/PAR-02's EXECUTE format(%I, ...)
    // DDL blocks already document.
    //
    // Timer: PAR-04's own design doc flagged uncertainty about which timing
    // primitive survived the Zig 0.16 upgrade (Open questions §2), naming
    // std.time.nanoTimestamp() as one option that predecessor code appeared
    // to use. Confirmed by reading lib/std/time.zig directly: this repo's
    // actual Zig 0.16.0 stdlib declares NEITHER nanoTimestamp() NOR
    // microTimestamp()/milliTimestamp() at all (only unit constants and the
    // `epoch` submodule) — any call site invoking them compiles only because
    // Zig lazily analyzes unreferenced functions; the moment a test or real
    // caller invokes such a function, it fails to compile (confirmed live
    // while wiring PAR-02's own unit tests). std.Io.Clock.real.now(io) is the
    // pattern store.zig/pool.zig actually use throughout this codebase, but
    // it needs an `io` handle this function has no access to (Conn's `_io`
    // field is private by convention per pool.zig's own doc comment, never
    // read outside pool.zig itself). Measuring via the SERVER's own
    // clock_timestamp() instead avoids both problems and additionally
    // measures the statement's true server-side duration rather than
    // client-observed latency (network round-trip is a false positive this
    // budget should not count against).
    const before_us = queryClockTimestampUs(allocator, conn) catch return PartitionAttachError.QueryFailed;
    conn.exec(sql, &.{}) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return PartitionAttachError.PoolExhausted,
        else => return PartitionAttachError.QueryFailed,
    };
    const after_us = queryClockTimestampUs(allocator, conn) catch return PartitionAttachError.QueryFailed;
    const elapsed_ms: i64 = @divFloor(after_us - before_us, 1000);

    if (elapsed_ms > ATTACH_BUDGET_MS) {
        return AttachVerdict{ .attach_scan_required = AttachScanRequiredDetail{
            .table_name = partition_table,
            .missing_tenant_check = false,
            .missing_or_mismatched_range_check = false,
            .found_range_check_def = null,
            .observed_duration_ms = @intCast(elapsed_ms),
        } };
    }

    return AttachVerdict.ok;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Query the server's own clock_timestamp() (not now(), which is fixed for
/// the duration of a transaction) as UTC microseconds since epoch. Used to
/// bracket the ATTACH PARTITION statement in attachPartitionTimed() so the
/// measured duration reflects server-side statement execution time.
fn queryClockTimestampUs(allocator: std.mem.Allocator, conn: *db.Conn) !i64 {
    var result = try conn.query(
        allocator,
        "SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000000)::bigint",
        &.{},
    );
    defer result.deinit();
    if (result.rows.len > 0 and result.rows[0].len > 0) {
        if (result.rows[0][0]) |v| {
            return std.fmt.parseInt(i64, v, 10) catch error.InvalidTimestamp;
        }
    }
    return error.InvalidTimestamp;
}

/// Render a UTC-microseconds timestamp as the ISO-8601 text PostgreSQL's
/// pg_get_constraintdef() echoes back inside a CHECK's literal bounds
/// (matching the %L formatting used by the EXECUTE format(...) DDL blocks in
/// partition_maintenance.zig / partition_retention.zig / the migrations).
fn formatRangeBoundText(allocator: std.mem.Allocator, us: i64) ![]u8 {
    return formatTimestamptzLiteral(allocator, us);
}

/// Render a UTC-microseconds timestamp as `YYYY-MM-DD HH:MM:SS` (seconds
/// precision is sufficient: every range bound this module handles is a
/// calendar-month boundary at 00:00:00).
fn formatTimestamptzLiteral(allocator: std.mem.Allocator, us: i64) ![]u8 {
    const secs = @divFloor(us, 1_000_000);
    const epoch_secs: u64 = @intCast(secs);
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_seconds = epoch_day.getDaySeconds();
    const year_day = epoch_day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB; verifyAttachConstraints()/attachPartitionTimed()
// themselves are DB-bound and covered by integration tests instead)
// ---------------------------------------------------------------------------

test "formatTimestamptzLiteral: renders a calendar-month boundary correctly" {
    // 2026-08-01T00:00:00Z in UTC microseconds.
    const us: i64 = 1785542400_000_000;
    const text = try formatTimestamptzLiteral(std.testing.allocator, us);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2026-08-01 00:00:00", text);
}

test "AttachScanRequiredDetail: observed_duration_ms distinguishes retroactive timing case" {
    const detail = AttachScanRequiredDetail{
        .table_name = "events_2026_08",
        .missing_tenant_check = false,
        .missing_or_mismatched_range_check = false,
        .found_range_check_def = null,
        .observed_duration_ms = 1500,
    };
    try std.testing.expect(detail.observed_duration_ms != null);
    try std.testing.expect(!detail.missing_tenant_check);
    try std.testing.expect(!detail.missing_or_mismatched_range_check);
}
