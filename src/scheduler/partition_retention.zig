//! PAR-03: partition-scoped retention — archival aging (events -> events_archive
//! via DETACH/ATTACH) and ephemeral dropping (events_ephemeral partitions
//! DROPped after the ADP-11 protected-family guard passes).
//!
//! Runs as part of the same daily plat_partition_maintenance job PAR-02
//! defines: PartitionMaintenanceScheduler.runMaintenanceCycle() calls this
//! module's runArchivalAging() then runEphemeralDrop() after its own creation
//! loop completes (see the design doc's Scoping note — there is no separate
//! cron entry for retention).
//!
//! Design artefact: src/design/par-03-partition-scoped-retention.md
const std = @import("std");
const db = @import("pool");
// Named module, not a relative @import — see build.zig's partition_attach_mod
// comment: this file's standalone addTest root (test-partition-retention)
// cannot escape its own module root with a relative path that crosses into
// src/db/ (Zig 0.16's single-owner module rule).
const partition_attach = @import("partition_attach");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const RetentionConfig = struct {
    archive_after_months: u8 = 13,
    ephemeral_drop_after_months: u8 = 3,
};

pub const PartitionState = enum { attached, detached, orphan_partition, dropped };

pub const ArchivalAgingResult = struct {
    detached_and_reattached: u32 = 0,
    orphaned: u32 = 0,
};

pub const EphemeralDropResult = struct {
    dropped: u32 = 0,
    guard_tripped: u32 = 0,
};

pub const RetentionError = error{
    PoolExhausted,
    TransactionFailed,
    /// The pre-drop guard found protected-family rows in an events_ephemeral
    /// partition (PAR-03 AC4) — the partition stays attached, no DROP runs.
    /// This should be structurally impossible (ADP-11/PAR-03's
    /// RetentionClassForbidden guard refuses `delete` retention_class for
    /// protected-family types at configuration time) — surfaced as a typed
    /// error, not silently retried, since it indicates a routing bug
    /// elsewhere if it ever fires.
    Adp11GuardTripped,
};

/// PAR-03's own body, verbatim: the protected replay-critical event-type
/// prefixes that must never be dropped. Matches store.zig's
/// isProtectedEventFamily (private there) and registry.zig's
/// isProtectedEventFamilyName (private there) — this is a THIRD, intentional
/// duplication as a SQL predicate rather than a per-row Zig check, because the
/// ephemeral-drop guard is a whole-partition aggregate COUNT(*), which cannot
/// be expressed as a per-row Zig call without reading every row first
/// (defeating the point of a cheap pre-drop guard). See the design doc's Open
/// questions §4 for why this duplication is accepted rather than factored
/// out.
const PROTECTED_FAMILY_GUARD_SQL =
    \\SELECT COUNT(*) FROM {s}
    \\WHERE split_part(event_type, '_', 1) IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')
;

pub const PartitionRetention = struct {
    pool: *db.Pool,
    config: RetentionConfig,

    pub fn init(pool: *db.Pool, config: RetentionConfig) PartitionRetention {
        return .{ .pool = pool, .config = config };
    }

    /// DETACH-then-ATTACH every `events` partition older than
    /// archive_after_months. Calls PAR-04's attachPartitionTimed() for the
    /// re-attach step. A failed re-attach after a successful detach is
    /// recorded ORPHAN_PARTITION, not retried within this same call — the
    /// NEXT call's retryOrphanedAttaches() picks it up (PAR-03 AC5).
    pub fn runArchivalAging(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn) RetentionError!ArchivalAgingResult {
        var result = ArchivalAgingResult{};

        // PAR-03 AC5: retry any partition currently ORPHAN_PARTITION first,
        // before evaluating newly-aged partitions this cycle.
        try self.retryOrphanedAttaches(allocator, conn, &result);

        const archive_after_months_text = uintToStr(allocator, self.config.archive_after_months) catch return RetentionError.TransactionFailed;
        defer allocator.free(archive_after_months_text);

        var aged = conn.query(
            allocator,
            \\SELECT table_name, range_start, range_end FROM plat_partition_catalog
            \\WHERE parent_table = 'events' AND state = 'ATTACHED'
            \\  AND range_end < NOW() - ($1 || ' months')::interval
            \\ORDER BY range_end ASC
        ,
            &.{archive_after_months_text},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
            else => return RetentionError.TransactionFailed,
        };
        defer aged.deinit();

        for (aged.rows) |row| {
            if (row.len < 3) continue;
            const table_name = row[0] orelse continue;
            const range_start_text = row[1] orelse continue;
            const range_end_text = row[2] orelse continue;

            try self.archiveOnePartition(allocator, conn, table_name, range_start_text, range_end_text, &result);
        }

        return result;
    }

    /// Retries any partition currently in ORPHAN_PARTITION state — called at
    /// the START of runArchivalAging() each cycle, before evaluating newly-
    /// aged partitions, per PAR-03 AC5 ("retried on the next maintenance
    /// run").
    fn retryOrphanedAttaches(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn, result: *ArchivalAgingResult) RetentionError!void {
        _ = self;
        var orphans = conn.query(
            allocator,
            "SELECT table_name, range_start, range_end FROM plat_partition_catalog WHERE parent_table = 'events' AND state = 'ORPHAN_PARTITION'",
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
            else => return RetentionError.TransactionFailed,
        };
        defer orphans.deinit();

        for (orphans.rows) |row| {
            if (row.len < 3) continue;
            const table_name = row[0] orelse continue;
            const range_start_text = row[1] orelse continue;
            const range_end_text = row[2] orelse continue;

            const range_start_us = parseTimestamptzToUs(allocator, conn, range_start_text) catch continue;
            const range_end_us = parseTimestamptzToUs(allocator, conn, range_end_text) catch continue;

            // Same archived_at backfill archiveOnePartition() performs — an
            // orphan may have failed BEFORE that step ran (or on an earlier
            // build predating this fix), so ensure it here too,
            // idempotently. See archiveOnePartition()'s comment for the full
            // rationale.
            const add_archived_at_sql = std.fmt.allocPrint(
                allocator,
                "ALTER TABLE {s} ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()",
                .{table_name},
            ) catch continue;
            defer allocator.free(add_archived_at_sql);
            conn.exec(add_archived_at_sql, &.{}) catch continue;

            const verdict = partition_attach.attachPartitionTimed(
                allocator,
                conn,
                "events_archive",
                table_name,
                .{ .start = range_start_us, .end = range_end_us },
            ) catch {
                continue; // still orphaned; try again next cycle.
            };

            switch (verdict) {
                .ok => {
                    conn.exec(
                        "UPDATE plat_partition_catalog SET state = 'ATTACHED', parent_table = 'events_archive', updated_at = NOW() WHERE table_name = $1",
                        &.{table_name},
                    ) catch continue;
                    result.detached_and_reattached += 1;
                },
                .attach_scan_required => {
                    // Still not attachable; remains ORPHAN_PARTITION, retried
                    // again next cycle.
                },
            }
        }
    }

    fn archiveOnePartition(
        self: *PartitionRetention,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        table_name: []const u8,
        range_start_text: []const u8,
        range_end_text: []const u8,
        result: *ArchivalAgingResult,
    ) RetentionError!void {
        _ = self;

        const detach_sql = std.fmt.allocPrint(allocator, "ALTER TABLE events DETACH PARTITION {s} CONCURRENTLY", .{table_name}) catch
            return RetentionError.TransactionFailed;
        defer allocator.free(detach_sql);

        conn.exec(detach_sql, &.{}) catch {
            // Detach itself failed — partition remains ATTACHED to events;
            // leave state untouched, log error, retry next cycle.
            return;
        };

        conn.exec(
            "UPDATE plat_partition_catalog SET state = 'DETACHED', updated_at = NOW() WHERE table_name = $1",
            &.{table_name},
        ) catch return RetentionError.TransactionFailed;

        // events_archive carries one column events does not: archived_at
        // TIMESTAMPTZ NOT NULL DEFAULT NOW() (migration 1147). PostgreSQL's
        // ATTACH PARTITION requires the child relation's column set to be a
        // superset of the parent's — a column present in events_archive but
        // ABSENT from this (events-shaped) physical relation is rejected
        // with 42P04 "child table is missing column archived_at", regardless
        // of that column having a default on the parent side. Add it here,
        // on the now-standalone (detached) relation, before attempting the
        // attach. IF NOT EXISTS makes this safe to retry (e.g. via
        // retryOrphanedAttaches on a partition that already got this far in
        // an earlier, since-failed cycle).
        const add_archived_at_sql = std.fmt.allocPrint(
            allocator,
            "ALTER TABLE {s} ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()",
            .{table_name},
        ) catch {
            markOrphan(conn, table_name);
            result.orphaned += 1;
            return;
        };
        defer allocator.free(add_archived_at_sql);
        conn.exec(add_archived_at_sql, &.{}) catch {
            markOrphan(conn, table_name);
            result.orphaned += 1;
            return;
        };

        const range_start_us = parseTimestamptzToUs(allocator, conn, range_start_text) catch {
            markOrphan(conn, table_name);
            result.orphaned += 1;
            return;
        };
        const range_end_us = parseTimestamptzToUs(allocator, conn, range_end_text) catch {
            markOrphan(conn, table_name);
            result.orphaned += 1;
            return;
        };

        const verdict = partition_attach.attachPartitionTimed(
            allocator,
            conn,
            "events_archive",
            table_name,
            .{ .start = range_start_us, .end = range_end_us },
        ) catch {
            markOrphan(conn, table_name);
            result.orphaned += 1;
            return;
        };

        switch (verdict) {
            .ok => {
                conn.exec(
                    "UPDATE plat_partition_catalog SET state = 'ATTACHED', parent_table = 'events_archive', updated_at = NOW() WHERE table_name = $1",
                    &.{table_name},
                ) catch return RetentionError.TransactionFailed;
                result.detached_and_reattached += 1;
            },
            .attach_scan_required => {
                markOrphan(conn, table_name);
                result.orphaned += 1;
            },
        }
    }

    /// Runs the ADP-11 pre-drop guard and DROP TABLE for every
    /// events_ephemeral partition older than ephemeral_drop_after_months.
    /// Returns Adp11GuardTripped on the FIRST guard trip encountered (does
    /// not continue past a blocked drop to try later partitions in the same
    /// call — a tripped guard indicates a routing bug elsewhere, not a
    /// transient condition, so continuing risks masking it across multiple
    /// partitions in one cycle).
    pub fn runEphemeralDrop(self: *PartitionRetention, allocator: std.mem.Allocator, conn: *db.Conn) RetentionError!EphemeralDropResult {
        var result = EphemeralDropResult{};

        const ephemeral_drop_after_months_text = uintToStr(allocator, self.config.ephemeral_drop_after_months) catch return RetentionError.TransactionFailed;
        defer allocator.free(ephemeral_drop_after_months_text);

        var aged = conn.query(
            allocator,
            \\SELECT table_name FROM plat_partition_catalog
            \\WHERE parent_table = 'events_ephemeral' AND state = 'ATTACHED'
            \\  AND range_end < NOW() - ($1 || ' months')::interval
            \\ORDER BY range_end ASC
        ,
            &.{ephemeral_drop_after_months_text},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
            else => return RetentionError.TransactionFailed,
        };
        defer aged.deinit();

        for (aged.rows) |row| {
            if (row.len == 0) continue;
            const table_name = row[0] orelse continue;

            const guard_sql = std.fmt.allocPrint(allocator, PROTECTED_FAMILY_GUARD_SQL, .{table_name}) catch
                return RetentionError.TransactionFailed;
            defer allocator.free(guard_sql);

            var guard_result = conn.query(allocator, guard_sql, &.{}) catch |err| switch (err) {
                db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
                else => return RetentionError.TransactionFailed,
            };
            defer guard_result.deinit();

            const protected_count: i64 = blk: {
                if (guard_result.rows.len > 0 and guard_result.rows[0].len > 0) {
                    if (guard_result.rows[0][0]) |v| {
                        break :blk std.fmt.parseInt(i64, v, 10) catch 0;
                    }
                }
                break :blk 0;
            };

            if (protected_count > 0) {
                result.guard_tripped += 1;
                return RetentionError.Adp11GuardTripped;
            }

            const drop_sql = std.fmt.allocPrint(allocator, "DROP TABLE {s}", .{table_name}) catch
                return RetentionError.TransactionFailed;
            defer allocator.free(drop_sql);

            conn.exec(drop_sql, &.{}) catch |err| switch (err) {
                db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
                else => return RetentionError.TransactionFailed,
            };

            conn.exec(
                "UPDATE plat_partition_catalog SET state = 'DROPPED', updated_at = NOW() WHERE table_name = $1",
                &.{table_name},
            ) catch return RetentionError.TransactionFailed;

            result.dropped += 1;
        }

        return result;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn markOrphan(conn: *db.Conn, table_name: []const u8) void {
    conn.exec(
        "UPDATE plat_partition_catalog SET state = 'ORPHAN_PARTITION', updated_at = NOW() WHERE table_name = $1",
        &.{table_name},
    ) catch {};
}

/// Parse a Postgres timestamptz text value (as returned in QueryResult rows,
/// e.g. "2026-08-01 00:00:00+00") into UTC microseconds, by round-tripping
/// through the server (EXTRACT(EPOCH ...)) rather than hand-parsing the text
/// format — avoids depending on a specific timestamptz text rendering.
fn parseTimestamptzToUs(allocator: std.mem.Allocator, conn: *db.Conn, timestamptz_text: []const u8) !i64 {
    var result = try conn.query(
        allocator,
        "SELECT (EXTRACT(EPOCH FROM $1::timestamptz) * 1000000)::bigint",
        &.{timestamptz_text},
    );
    defer result.deinit();
    if (result.rows.len > 0 and result.rows[0].len > 0) {
        if (result.rows[0][0]) |v| {
            return std.fmt.parseInt(i64, v, 10) catch error.InvalidTimestamp;
        }
    }
    return error.InvalidTimestamp;
}

fn uintToStr(allocator: std.mem.Allocator, value: u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB)
// ---------------------------------------------------------------------------

test "ArchivalAgingResult: default-initializes to zero counts" {
    const r = ArchivalAgingResult{};
    try std.testing.expectEqual(@as(u32, 0), r.detached_and_reattached);
    try std.testing.expectEqual(@as(u32, 0), r.orphaned);
}

test "EphemeralDropResult: default-initializes to zero counts" {
    const r = EphemeralDropResult{};
    try std.testing.expectEqual(@as(u32, 0), r.dropped);
    try std.testing.expectEqual(@as(u32, 0), r.guard_tripped);
}

test "RetentionConfig: defaults match PAR-03's documented defaults" {
    const c = RetentionConfig{};
    try std.testing.expectEqual(@as(u8, 13), c.archive_after_months);
    try std.testing.expectEqual(@as(u8, 3), c.ephemeral_drop_after_months);
}

test "PROTECTED_FAMILY_GUARD_SQL: formats against a candidate table name" {
    var buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, PROTECTED_FAMILY_GUARD_SQL, .{"events_ephemeral_2026_01"});
    try std.testing.expect(std.mem.indexOf(u8, sql, "events_ephemeral_2026_01") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INSTANCE") != null);
}
