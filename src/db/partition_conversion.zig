//! PAR-05: Online partition conversion — converts an already-populated,
//! unpartitioned `events` table into PAR-01's partitioned target shape,
//! without taking `events` offline.
//!
//! Not a single `zig build migrate` DDL file: this is a long-running,
//! resumable, interruptible operation (backfill windows measured in
//! calendar months) that must NOT run inside one migration-runner
//! transaction. See src/design/par-05-online-partition-conversion.md for the
//! full design (data flow, exact statement shapes, error taxonomy).
//!
//! Scoping note (per the design doc): PAR-05 converts an EXISTING,
//! populated, unpartitioned `events` table — the shape a pre-PAR-01
//! production/bpm_dev database has. A freshly migrated `bpm_test` always
//! takes PAR-01's from-scratch path (1147_par01_events_partitioning.sql)
//! and never reaches this module's guard conditions with anything to
//! convert; this is expected, not a defect (see the design's Scoping note
//! and Open questions §2 for how TEST-DESIGNER should exercise this path).
const std = @import("std");
const db = @import("pool");
// Named module, not a relative @import — see build.zig's partition_attach_mod
// comment: the same Single-Owner Module Rule constraint that already applies
// to partition_maintenance.zig/partition_retention.zig applies here.
const partition_attach = @import("partition_attach");
const partition_maintenance = @import("partition_maintenance");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const ConversionError = error{
    PoolExhausted,
    TransactionFailed,
    /// A calendar month between min(created_at) and the lead horizon has no
    /// planned target partition (PAR-05 AC2). Conversion does not start.
    PartitionRangeGap,
    /// Post-swap per-month row count differs between events_legacy and the
    /// new events partitions (PAR-05 AC5). Inverse rename already executed
    /// by the time this is returned to the caller.
    ConversionRowCountMismatch,
};

pub const ConversionConfig = struct {
    /// Same default horizon PAR-02 proactively maintains, so the converted
    /// events_part starts with the same future-partition supply a freshly
    /// PAR-01-built events table would have.
    lead_months: u8 = 2,
};

pub const MonthRange = partition_maintenance.MonthRange;

pub const PartitionConverter = struct {
    pool: *db.Pool,
    config: ConversionConfig,

    pub fn init(pool: *db.Pool, config: ConversionConfig) PartitionConverter {
        return .{ .pool = pool, .config = config };
    }

    // -----------------------------------------------------------------------
    // Step 1 (PAR-05 AC2): coverage validation
    // -----------------------------------------------------------------------

    /// Read-only; issues no DDL. Returns the ordered list of calendar months
    /// [min(created_at), max(created_at) + lead_months] that Step 4 will need
    /// a target partition for. Raises PartitionRangeGap if `events` is empty
    /// or absent (nothing to convert — the caller should not proceed).
    pub fn validateCoverage(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError![]MonthRange {
        const row = conn.queryRow(
            allocator,
            \\SELECT (EXTRACT(EPOCH FROM MIN(created_at)) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM MAX(created_at)) * 1000000)::bigint
            \\FROM events
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        if (row == null) return ConversionError.PartitionRangeGap;
        const r = row.?;
        defer {
            for (r) |c| if (c) |v| allocator.free(v);
            allocator.free(r);
        }
        if (r.len < 2 or r[0] == null or r[1] == null) {
            // events is empty — nothing to convert. Treated as
            // PartitionRangeGap: there is no populated month range for the
            // caller to have planned partitions for, so conversion cannot
            // meaningfully proceed (and per the Scoping note, an empty
            // `events` should instead go through PAR-01's from-scratch path).
            return ConversionError.PartitionRangeGap;
        }

        const min_us = std.fmt.parseInt(i64, r[0].?, 10) catch return ConversionError.TransactionFailed;
        const max_us = std.fmt.parseInt(i64, r[1].?, 10) catch return ConversionError.TransactionFailed;

        const min_month_start = truncateToMonthStart(min_us);
        const max_month_start = truncateToMonthStart(max_us);

        // Count calendar months from min to max inclusive, plus lead_months.
        const min_ym = partition_maintenance.usToYearMonth(min_month_start);
        const max_ym = partition_maintenance.usToYearMonth(max_month_start);
        const span_months: u32 = @intCast(
            (@as(i64, max_ym.year) * 12 + @as(i64, max_ym.month - 1)) -
                (@as(i64, min_ym.year) * 12 + @as(i64, min_ym.month - 1)),
        );
        const total_months = span_months + 1 + self.config.lead_months;

        var months = allocator.alloc(MonthRange, total_months) catch return ConversionError.TransactionFailed;
        errdefer allocator.free(months);
        var i: u32 = 0;
        while (i < total_months) : (i += 1) {
            months[i] = partition_maintenance.monthRange(min_month_start, i);
        }

        // AC2: confirm every populated month up to the lead horizon is
        // covered with no gap. Since the list above is constructed as a
        // contiguous run from min_month_start through max_month_start +
        // lead_months with no skipped months, coverage is true by
        // construction — this loop is the explicit verification step the
        // design's Step 1 requires, guarding against a future change to the
        // construction above silently introducing a gap.
        i = 1;
        while (i < months.len) : (i += 1) {
            if (months[i].start_us != months[i - 1].end_us) {
                allocator.free(months);
                return ConversionError.PartitionRangeGap;
            }
        }

        return months;
    }

    // -----------------------------------------------------------------------
    // Step 2: CREATE TABLE events_part
    // -----------------------------------------------------------------------

    /// CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING
    /// IDENTITY) PARTITION BY RANGE (created_at), then explicitly adds the
    /// composite PRIMARY KEY (event_id, created_at) — matching how
    /// 1147_par01_events_partitioning.sql declares this PK explicitly on its
    /// own from-scratch `events` table. Postgres' `LIKE ... INCLUDING
    /// DEFAULTS INCLUDING IDENTITY` does NOT copy constraints or indexes
    /// (confirmed live against PostgreSQL 15.14): without this explicit
    /// ALTER TABLE, events_part has zero constraints and every downstream
    /// `INSERT ... ON CONFLICT (event_id, created_at) DO NOTHING` in
    /// backfillOneMonth()/swap() fails with 42P10 ("no unique or exclusion
    /// constraint matching the ON CONFLICT specification") — this was
    /// ISS-0676 / GH-718. Idempotent: a second call when events_part already
    /// exists (partitioned or not) is a no-op.
    pub fn createParent(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void {
        _ = self;
        const exists_row = conn.queryRow(
            allocator,
            "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = 'events_part' AND n.nspname = current_schema()",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        if (exists_row) |row| {
            for (row) |c| if (c) |v| allocator.free(v);
            allocator.free(row);
            return; // already exists — idempotent no-op
        }

        conn.exec(
            "CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY) PARTITION BY RANGE (created_at)",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };

        // events_part needs the SAME composite PK as PAR-01's from-scratch
        // `events` table (PRIMARY KEY (event_id, created_at)) so that the
        // ON CONFLICT (event_id, created_at) clauses in backfillOneMonth()
        // and swap() have a matching unique constraint to target.
        conn.exec(
            "ALTER TABLE events_part ADD PRIMARY KEY (event_id, created_at)",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
    }

    // -----------------------------------------------------------------------
    // Step 3: plat_event_idempotency backfill
    // -----------------------------------------------------------------------

    /// CREATE plat_event_idempotency (same shape PAR-01 Migration 2 defines)
    /// and backfill it from every row currently in events, BEFORE any
    /// events_part row work.
    pub fn createAndBackfillIdempotency(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void {
        _ = self;
        conn.exec(
            \\CREATE TABLE IF NOT EXISTS plat_event_idempotency (
            \\    idempotency_key   TEXT            PRIMARY KEY,
            \\    event_id          UUID            NOT NULL,
            \\    created_at        TIMESTAMPTZ     NOT NULL
            \\)
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        conn.exec(
            "CREATE INDEX IF NOT EXISTS idx_plat_event_idempotency_event ON plat_event_idempotency (event_id, created_at)",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };

        conn.exec(
            \\INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
            \\SELECT idempotency_key, event_id, created_at FROM events
            \\ON CONFLICT (idempotency_key) DO NOTHING
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        _ = allocator;
    }

    // -----------------------------------------------------------------------
    // Step 4 (PAR-05 AC1, AC3; DDL-04 discipline): per-month backfill loop
    // -----------------------------------------------------------------------

    /// Runs the per-month backfill loop. Each month is ONE transaction:
    /// create+attach the month's partition (PAR-04's CHECK-before-ATTACH via
    /// attachPartitionTimed()), then INSERT ... SELECT ... ON CONFLICT DO
    /// NOTHING. Safe to call repeatedly after an interruption.
    pub fn backfillAllMonths(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn, months: []const MonthRange) ConversionError!void {
        for (months) |month| {
            try self.backfillOneMonth(allocator, conn, month);
        }
    }

    fn backfillOneMonth(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn, month: MonthRange) ConversionError!void {
        _ = self;
        const partition_name = std.fmt.allocPrint(allocator, "events_{s}", .{month.suffix}) catch
            return ConversionError.TransactionFailed;
        defer allocator.free(partition_name);

        conn.exec("BEGIN", &.{}) catch return ConversionError.TransactionFailed;
        errdefer conn.exec("ROLLBACK", &.{}) catch {};

        // CREATE + ATTACH the month's partition (idempotent — a re-run after
        // interruption finds it already exists/attached).
        const exists_row = conn.queryRow(
            allocator,
            "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = $1 AND n.nspname = current_schema()",
            &.{partition_name},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        var already_exists = false;
        if (exists_row) |row| {
            already_exists = true;
            for (row) |c| if (c) |v| allocator.free(v);
            allocator.free(row);
        }

        if (!already_exists) {
            const start_text = partition_maintenance.formatTimestamptzLiteral(allocator, month.start_us) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };
            defer allocator.free(start_text);
            const end_text = partition_maintenance.formatTimestamptzLiteral(allocator, month.end_us) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };
            defer allocator.free(end_text);

            const create_sql = std.fmt.allocPrint(
                allocator,
                "CREATE TABLE IF NOT EXISTS {s} (LIKE events_part INCLUDING DEFAULTS, " ++
                    "CHECK (tenant_id IS NOT NULL), " ++
                    "CHECK (created_at >= '{s}' AND created_at < '{s}'))",
                .{ partition_name, start_text, end_text },
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };
            defer allocator.free(create_sql);

            conn.exec(create_sql, &.{}) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };

            const verdict = partition_attach.attachPartitionTimed(
                allocator,
                conn,
                "events_part",
                partition_name,
                .{ .start = month.start_us, .end = month.end_us },
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };
            switch (verdict) {
                .attach_scan_required => {
                    conn.exec("ROLLBACK", &.{}) catch {};
                    return ConversionError.TransactionFailed;
                },
                .ok => {},
            }

            // ISS-0681 / GH-724 (PAR-05 AC5): record this partition in
            // plat_partition_catalog with parent_table='events_part' — the
            // SAME bookkeeping ensurePartitionAttached() performs for PAR-02's
            // daily job, via the shared helper. Without this row,
            // reconcileOrRollback()'s self-join over plat_partition_catalog
            // (filtered on parent_table = 'events_legacy' / 'events') never
            // matches anything for a partition created through this
            // conversion path, so its mismatch-detection loop body never
            // runs and AC5's guarantee silently never fires. Same transaction
            // as the CREATE TABLE + ATTACH above.
            partition_maintenance.upsertPartitionCatalogRow(
                conn,
                partition_name,
                "events_part",
                start_text,
                end_text,
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return ConversionError.TransactionFailed;
            };
        }

        // Backfill INSERT ... SELECT ... ON CONFLICT DO NOTHING for this
        // month's window (PAR-05 AC1, AC3; DDL-04 discipline — idempotent,
        // resumable).
        const start_text2 = partition_maintenance.formatTimestamptzLiteral(allocator, month.start_us) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        defer allocator.free(start_text2);
        const end_text2 = partition_maintenance.formatTimestamptzLiteral(allocator, month.end_us) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        defer allocator.free(end_text2);

        conn.exec(
            \\INSERT INTO events_part
            \\SELECT * FROM events
            \\WHERE created_at >= $1::timestamptz AND created_at < $2::timestamptz
            \\ON CONFLICT (event_id, created_at) DO NOTHING
        ,
            &.{ start_text2, end_text2 },
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        conn.exec("COMMIT", &.{}) catch return ConversionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // Step 5 (PAR-05 AC4): swap transaction
    // -----------------------------------------------------------------------

    /// The swap transaction: replays the catch-up window since the last
    /// backfilled row, then issues the two RENAME statements, all inside one
    /// transaction with lock_timeout = 3s. On a lock-timeout ROLLBACK, both
    /// tables are left exactly as found.
    pub fn swap(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void {
        _ = self;
        // Catch-up window: [max(created_at) already in events_part, NOW()).
        // If events_part is empty (should not occur after Step 4), fall back
        // to epoch start so the catch-up replay still covers every row.
        const last_row = conn.queryRow(
            allocator,
            "SELECT COALESCE((EXTRACT(EPOCH FROM MAX(created_at)) * 1000000)::bigint, 0) FROM events_part",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        var catchup_start_us: i64 = 0;
        if (last_row) |row| {
            defer {
                for (row) |c| if (c) |v| allocator.free(v);
                allocator.free(row);
            }
            if (row.len > 0 and row[0] != null) {
                catchup_start_us = std.fmt.parseInt(i64, row[0].?, 10) catch 0;
            }
        }
        const catchup_start_text = partition_maintenance.formatTimestamptzLiteral(allocator, catchup_start_us) catch
            return ConversionError.TransactionFailed;
        defer allocator.free(catchup_start_text);

        conn.exec("BEGIN", &.{}) catch return ConversionError.TransactionFailed;
        errdefer conn.exec("ROLLBACK", &.{}) catch {};

        conn.exec("SET LOCAL lock_timeout = '3s'", &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        conn.exec(
            \\INSERT INTO events_part
            \\SELECT * FROM events
            \\WHERE created_at >= $1::timestamptz AND created_at < NOW()
            \\ON CONFLICT (event_id, created_at) DO NOTHING
        ,
            &.{catchup_start_text},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        conn.exec("ALTER TABLE events RENAME TO events_legacy", &.{}) catch {
            // Postgres 55P03 lock_timeout expiry aborts the transaction
            // automatically; ROLLBACK is a harmless no-op in that case and
            // required cleanup in every other failure case.
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        conn.exec("ALTER TABLE events_part RENAME TO events", &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        // ISS-0681 / GH-724 (PAR-05 AC5): plat_partition_catalog.parent_table
        // must track the SAME rename that just happened at the table level,
        // in the SAME transaction, or reconcileOrRollback()'s self-join
        // (WHERE lp.parent_table = 'events_legacy' AND np.parent_table =
        // 'events') never matches any real row even after backfillOneMonth()
        // starts populating the catalog — the population gap and this rename
        // gap are two halves of the same defect. Two disjoint predicates (old
        // value 'events' vs old value 'events_part'), so statement order
        // between them does not matter.
        conn.exec(
            "UPDATE plat_partition_catalog SET parent_table = 'events_legacy', updated_at = NOW() WHERE parent_table = 'events'",
            &.{},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        conn.exec(
            "UPDATE plat_partition_catalog SET parent_table = 'events', updated_at = NOW() WHERE parent_table = 'events_part'",
            &.{},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        conn.exec("COMMIT", &.{}) catch return ConversionError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // Step 6 (PAR-05 AC5): reconciliation and inverse-rename
    // -----------------------------------------------------------------------

    /// Per-month COUNT(*) comparison between events_legacy and the new
    /// events partitions. On mismatch, issues the inverse rename before
    /// returning ConversionRowCountMismatch.
    ///
    /// ISS-0681 / GH-724 (REWORK 3): originally self-joined
    /// plat_partition_catalog on TWO catalog-registered families — one for
    /// events (parent_table='events') and one for events_legacy
    /// (parent_table='events_legacy') — matching rows by substring-derived
    /// suffix. That shape can never match in the real scenario this design
    /// targets (see the design doc's own Scoping note and Open questions §5):
    /// `events_legacy` IS the original pre-PAR-01 UNPARTITIONED table after
    /// swap()'s rename — it has no per-month children of its own and is
    /// never itself registered into plat_partition_catalog as a parent, so
    /// `parent_table = 'events_legacy'` never has any row to match, by
    /// construction, not merely by omission. PAR-05's own AC5 text says
    /// "per-month count(*) is compared between events_legacy and the new
    /// partitions" — a comparison against events_legacy AS A WHOLE, filtered
    /// per month, not a second catalog-registered partition family. Fixed
    /// shape: drive the loop from the NEW side's own catalog rows alone
    /// (parent_table='events', populated by backfillOneMonth() + swap()'s
    /// rename-time UPDATE) and use each row's own range_start/range_end to
    /// bound a COUNT(*) query directly against events_legacy for that month.
    pub fn reconcileOrRollback(self: *PartitionConverter, allocator: std.mem.Allocator, conn: *db.Conn) ConversionError!void {
        var rows = conn.query(
            allocator,
            \\SELECT table_name, range_start, range_end
            \\FROM plat_partition_catalog
            \\WHERE parent_table = 'events'
            \\ORDER BY range_start
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
            else => return ConversionError.TransactionFailed,
        };
        defer rows.deinit();

        for (rows.rows) |row| {
            if (row.len < 3 or row[0] == null or row[1] == null or row[2] == null) continue;
            const new_partition = row[0].?;
            const range_start_text = row[1].?;
            const range_end_text = row[2].?;

            const legacy_count = try countRowsInRange(allocator, conn, "events_legacy", range_start_text, range_end_text);
            const new_count = try countRowsInTable(allocator, conn, new_partition);

            if (legacy_count != new_count) {
                try self.inverseRename(conn);
                return ConversionError.ConversionRowCountMismatch;
            }
        }
    }

    fn inverseRename(self: *PartitionConverter, conn: *db.Conn) ConversionError!void {
        _ = self;
        conn.exec("BEGIN", &.{}) catch return ConversionError.TransactionFailed;
        errdefer conn.exec("ROLLBACK", &.{}) catch {};

        conn.exec("ALTER TABLE events RENAME TO events_part_failed", &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };
        conn.exec("ALTER TABLE events_legacy RENAME TO events", &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return ConversionError.TransactionFailed;
        };

        conn.exec("COMMIT", &.{}) catch return ConversionError.TransactionFailed;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Count rows in a specific partition table by name. Table names here come
/// exclusively from plat_partition_catalog's own already-validated
/// table_name column, never from unsanitised external input — %I quoting
/// via EXECUTE format(%I, ...)-style identifier escaping (built with
/// std.fmt.allocPrint, executed via conn.query()), matching
/// partition_maintenance.zig's/partition_retention.zig's existing
/// convention for dynamic identifier interpolation ($N placeholders cannot
/// bind identifiers, only values — this is the SAME textual-quoting
/// approach partition_attach.zig's own attachPartitionTimed() already uses
/// for ATTACH PARTITION statements).
fn countRowsInTable(allocator: std.mem.Allocator, conn: *db.Conn, table_name: []const u8) ConversionError!i64 {
    // Reject any table_name containing a double-quote to keep the identifier
    // quoting below sound even though every real caller sources table_name
    // from plat_partition_catalog, not external input.
    if (std.mem.indexOfScalar(u8, table_name, '"') != null) return ConversionError.TransactionFailed;

    const sql = std.fmt.allocPrint(allocator, "SELECT COUNT(*) FROM \"{s}\"", .{table_name}) catch
        return ConversionError.TransactionFailed;
    defer allocator.free(sql);

    const row = conn.queryRow(allocator, sql, &.{}) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
        else => return ConversionError.TransactionFailed,
    };
    if (row == null) return 0;
    const r = row.?;
    defer {
        for (r) |c| if (c) |v| allocator.free(v);
        allocator.free(r);
    }
    if (r.len == 0 or r[0] == null) return 0;
    return std.fmt.parseInt(i64, r[0].?, 10) catch return ConversionError.TransactionFailed;
}

/// ISS-0681 / GH-724 (REWORK 3): count rows in `table_name` whose created_at
/// falls in [range_start_text, range_end_text) — used by reconcileOrRollback()
/// to compare events_legacy (the whole pre-PAR-01 unpartitioned table, never
/// itself split into catalog-registered monthly children) against each new
/// partition's own row-count for that same month, per PAR-05 AC5's literal
/// text ("per-month count(*) is compared between events_legacy and the new
/// partitions"). table_name is identifier-quoted the same way
/// countRowsInTable() is (always sourced from plat_partition_catalog, never
/// external input); the range bounds are ordinary parameterised values, not
/// identifiers, so they bind via $1/$2 rather than textual interpolation.
fn countRowsInRange(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    table_name: []const u8,
    range_start_text: []const u8,
    range_end_text: []const u8,
) ConversionError!i64 {
    if (std.mem.indexOfScalar(u8, table_name, '"') != null) return ConversionError.TransactionFailed;

    const sql = std.fmt.allocPrint(
        allocator,
        "SELECT COUNT(*) FROM \"{s}\" WHERE created_at >= $1::timestamptz AND created_at < $2::timestamptz",
        .{table_name},
    ) catch return ConversionError.TransactionFailed;
    defer allocator.free(sql);

    const row = conn.queryRow(allocator, sql, &.{ range_start_text, range_end_text }) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return ConversionError.PoolExhausted,
        else => return ConversionError.TransactionFailed,
    };
    if (row == null) return 0;
    const r = row.?;
    defer {
        for (r) |c| if (c) |v| allocator.free(v);
        allocator.free(r);
    }
    if (r.len == 0 or r[0] == null) return 0;
    return std.fmt.parseInt(i64, r[0].?, 10) catch return ConversionError.TransactionFailed;
}

/// Truncate a UTC-microseconds timestamp down to the start of its calendar
/// month (00:00:00 on the 1st).
fn truncateToMonthStart(us: i64) i64 {
    const ymd = partition_maintenance.usToYearMonth(us);
    return partition_maintenance.yearMonthToUs(ymd.year, ymd.month);
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB; PartitionConverter's own methods are DB-bound
// and covered by integration tests instead, per the design's Scoping note)
// ---------------------------------------------------------------------------

test "truncateToMonthStart: mid-month timestamp truncates to the 1st" {
    // 2026-08-15T12:30:00Z in UTC microseconds.
    const mid_month: i64 = 1786797000_000_000;
    const truncated = truncateToMonthStart(mid_month);
    // 2026-08-01T00:00:00Z
    const aug_start: i64 = 1785542400_000_000;
    try std.testing.expectEqual(aug_start, truncated);
}

test "truncateToMonthStart: already-truncated timestamp is a no-op" {
    const aug_start: i64 = 1785542400_000_000;
    try std.testing.expectEqual(aug_start, truncateToMonthStart(aug_start));
}

test "ConversionConfig: default lead_months matches PAR-02's own default" {
    const cfg = ConversionConfig{};
    try std.testing.expectEqual(@as(u8, 2), cfg.lead_months);
}

test "MonthRange contiguity: a run built via monthRange(min_start, i) has no gaps" {
    // Mirrors validateCoverage()'s own gap-verification loop, exercised here
    // directly against the pure month-arithmetic helpers it depends on.
    const start: i64 = 1785542400_000_000; // 2026-08-01T00:00:00Z
    var i: u32 = 0;
    var prev_end: ?i64 = null;
    while (i < 6) : (i += 1) {
        const r = partition_maintenance.monthRange(start, i);
        if (prev_end) |pe| {
            try std.testing.expectEqual(pe, r.start_us);
        }
        prev_end = r.end_us;
    }
}
