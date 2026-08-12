//! PAR-02: proactive future-partition creation, daily plat_partition_maintenance job.
//!
//! Ensures lead_months future monthly partitions are attached to BOTH `events`
//! and `events_ephemeral` (PAR-03's append-time-routed delete-class table —
//! REWORK 2 widened this loop from `events` alone), is idempotent (a second
//! run within the same day is a safe no-op via
//! plat_partition_maintenance_run_log's UNIQUE(run_date)), and raises
//! WARN/BLOCKER severity as the lead-time buffer shrinks. `events_archive` is
//! deliberately NOT provisioned by this loop — its ongoing partition supply
//! comes from PAR-03's DETACH/ATTACH cycle, not from proactive creation here
//! (see the design doc's Open questions §1).
//!
//! Design artefact: src/design/par-02-partition-maintenance-job.md
const std = @import("std");
const db = @import("pool");
// Named module, not a relative @import — see build.zig's partition_attach_mod
// comment: this file's standalone addTest root (test-partition-maintenance)
// cannot escape its own module root with a relative path that crosses into
// src/db/ (Zig 0.16's single-owner module rule).
const partition_attach = @import("partition_attach");
const event_store = @import("event_store");
const Store = event_store.Store;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const PartitionMaintenanceConfig = struct {
    lead_months: u8 = 2,
    run_hour_utc: u8 = 0,
    run_minute_utc: u8 = 15,
};

pub const MaintenanceSeverity = enum { healthy, warn, blocker };

pub const MaintenanceCycleResult = struct {
    /// false if today's run already happened (idempotent no-op, PAR-02 AC2).
    ran: bool,
    partitions_created: u32,
    future_partition_count: u32,
    severity: MaintenanceSeverity,
};

pub const PartitionMaintenanceError = error{
    PoolExhausted,
    TransactionFailed,
    /// PAR-04's attachPartitionTimed() returned attach_scan_required for a
    /// partition this job itself just created — should not occur in
    /// practice (this job always creates both required CHECKs before
    /// attaching), surfaced as a typed error rather than silently retried.
    UnexpectedAttachScanRequired,
};

/// Parent tables this job proactively provisions future partitions for.
/// events_archive is deliberately excluded — see module doc comment.
const PROVISIONED_PARENTS = [_][]const u8{ "events", "events_ephemeral" };

pub const PartitionMaintenanceScheduler = struct {
    pool: *db.Pool,
    config: PartitionMaintenanceConfig,
    /// Optional: set to emit platform events on partition creation (ISS-0670, PAR-02 AC5).
    store: ?*Store = null,

    pub fn init(pool: *db.Pool, config: PartitionMaintenanceConfig) PartitionMaintenanceScheduler {
        return .{ .pool = pool, .config = config };
    }

    pub fn initWithStore(pool: *db.Pool, config: PartitionMaintenanceConfig, store: *Store) PartitionMaintenanceScheduler {
        return .{ .pool = pool, .config = config, .store = store };
    }

    /// Background loop entry point: sleeps until the next scheduled run (or
    /// runs immediately if today's run is overdue — the SCH-05-style missed-
    /// run recovery path, PAR-02 AC4), then loops forever. Errors from a
    /// single cycle are logged and swallowed so the loop itself never dies —
    /// the same resilience pattern Scheduler.pollDueTimers() uses for its own
    /// per-cycle DB errors.
    pub fn runDailyLoop(self: *PartitionMaintenanceScheduler, allocator: std.mem.Allocator) noreturn {
        var last_run_date_buf: [64]u8 = undefined;
        var last_run_date_len: usize = 0;
        while (true) {
            // std.Io.Clock (not std.time.microTimestamp/nanoTimestamp, which
            // do not exist in this repo's actual Zig 0.16.0 stdlib — confirmed
            // by reading lib/std/time.zig directly, which declares only unit
            // constants and the `epoch` submodule) — same wall-clock source
            // store.zig/pool.zig already use throughout this codebase.
            const now_us: i64 = std.Io.Clock.real.now(self.pool.io).toMicroseconds();
            const last_run_slice: ?[]const u8 = if (last_run_date_len > 0) last_run_date_buf[0..last_run_date_len] else null;
            const delay_ms = self.computeNextRunDelayMs(now_us, last_run_slice);
            if (delay_ms > 0) {
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }

            const result = self.runMaintenanceCycle(allocator) catch |err| {
                std.log.err("partition_maintenance: cycle failed: {}", .{err});
                // Do not update last_run_date on failure — the next loop
                // iteration will treat today as still not-yet-run and retry
                // promptly rather than waiting a full day.
                std.Thread.sleep(60 * std.time.ns_per_s);
                continue;
            };

            if (result.ran) {
                const post_cycle_now_us: i64 = std.Io.Clock.real.now(self.pool.io).toMicroseconds();
                const today = todayUtcDateString(&last_run_date_buf, post_cycle_now_us) catch "";
                last_run_date_len = today.len;

                switch (result.severity) {
                    .blocker => std.log.err(
                        "partition_maintenance: BLOCKER — {d} future partitions remain attached (lead_months={d})",
                        .{ result.future_partition_count, self.config.lead_months },
                    ),
                    .warn => std.log.warn(
                        "partition_maintenance: WARN — {d} future partitions remain attached (lead_months={d})",
                        .{ result.future_partition_count, self.config.lead_months },
                    ),
                    .healthy => {},
                }
            }
        }
    }

    /// Computes milliseconds to sleep until the next scheduled run: either
    /// the next configured UTC boundary, or 0 (run immediately) if today's
    /// run has not yet happened and the current time is already past the
    /// boundary — the SCH-05-style "recovered on restart" path (PAR-02 AC4).
    pub fn computeNextRunDelayMs(self: *PartitionMaintenanceScheduler, now_utc_us: i64, last_run_date: ?[]const u8) u64 {
        var today_buf: [64]u8 = undefined;
        const today = todayUtcDateString(&today_buf, now_utc_us) catch return 0;

        const already_ran_today = if (last_run_date) |lrd| std.mem.eql(u8, lrd, today) else false;

        const now_secs = @divFloor(now_utc_us, 1_000_000);
        const epoch_secs: u64 = @intCast(@max(now_secs, 0));
        const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const day_seconds = epoch_day.getDaySeconds();
        const current_hour = day_seconds.getHoursIntoDay();
        const current_minute = day_seconds.getMinutesIntoHour();
        const current_second = day_seconds.getSecondsIntoMinute();

        const boundary_seconds_into_day: i64 =
            @as(i64, self.config.run_hour_utc) * 3600 + @as(i64, self.config.run_minute_utc) * 60;
        const now_seconds_into_day: i64 =
            @as(i64, current_hour) * 3600 + @as(i64, current_minute) * 60 + @as(i64, current_second);

        if (!already_ran_today and now_seconds_into_day >= boundary_seconds_into_day) {
            // Today's run is overdue (either the boundary already passed, or
            // this is a restart after a missed run) — fire immediately.
            return 0;
        }

        if (now_seconds_into_day < boundary_seconds_into_day) {
            const wait_seconds = boundary_seconds_into_day - now_seconds_into_day;
            return @intCast(wait_seconds * 1000);
        }

        // already_ran_today and boundary passed: wait until tomorrow's boundary.
        const seconds_until_midnight = 86400 - now_seconds_into_day;
        const wait_seconds = seconds_until_midnight + boundary_seconds_into_day;
        return @intCast(wait_seconds * 1000);
    }

    /// Runs one maintenance cycle: claims today's run-log row (idempotency
    /// gate), creates and attaches any missing future partition through
    /// lead_months for both events and events_ephemeral, evaluates lead-time
    /// severity, and returns a summary. Safe to call directly (e.g. from an
    /// integration test) without going through runDailyLoop()'s sleep loop.
    pub fn runMaintenanceCycle(self: *PartitionMaintenanceScheduler, allocator: std.mem.Allocator) PartitionMaintenanceError!MaintenanceCycleResult {
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Step 1: idempotency gate (PAR-02 AC2).
        var claim_result = conn.query(
            allocator,
            \\INSERT INTO plat_partition_maintenance_run_log (run_date, future_partition_count)
            \\VALUES (CURRENT_DATE, 0)
            \\ON CONFLICT (run_date) DO NOTHING
            \\RETURNING id
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };
        defer claim_result.deinit();

        if (claim_result.rows.len == 0) {
            return MaintenanceCycleResult{
                .ran = false,
                .partitions_created = 0,
                .future_partition_count = 0,
                .severity = .healthy,
            };
        }

        // Step 2: create/attach missing future partitions through lead_months,
        // for BOTH events and events_ephemeral (REWORK 2).
        var partitions_created: u32 = 0;
        const month_start_us = try currentMonthStartUs(allocator, conn);

        var month_offset: u32 = 0;
        while (month_offset <= self.config.lead_months) : (month_offset += 1) {
            const range = monthRange(month_start_us, month_offset);

            for (PROVISIONED_PARENTS) |parent| {
                const created = try self.ensurePartitionAttached(allocator, conn, parent, range);
                if (created) partitions_created += 1;
            }
        }

        // Step 3: count attached future `events` partitions (scoped to
        // `events` only, per REWORK 2 — a shortfall in events_ephemeral's own
        // future supply surfaces as PartitionMissingForWrite on the next
        // delete-class append instead of this alarm).
        var count_result = conn.query(
            allocator,
            \\SELECT COUNT(*) FROM plat_partition_catalog
            \\WHERE parent_table = 'events' AND state = 'ATTACHED' AND range_start > NOW()
        ,
            &.{},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };
        defer count_result.deinit();

        const future_count: u32 = blk: {
            if (count_result.rows.len > 0 and count_result.rows[0].len > 0) {
                if (count_result.rows[0][0]) |v| {
                    break :blk std.fmt.parseInt(u32, v, 10) catch 0;
                }
            }
            break :blk 0;
        };

        const severity: MaintenanceSeverity = if (future_count == 0)
            .blocker
        else if (future_count == 1)
            .warn
        else
            .healthy;

        // Step 4: record the observed count on today's run-log row.
        conn.exec(
            "UPDATE plat_partition_maintenance_run_log SET future_partition_count = $1 WHERE run_date = CURRENT_DATE",
            &.{intToStr(allocator, future_count) catch return PartitionMaintenanceError.TransactionFailed},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };

        return MaintenanceCycleResult{
            .ran = true,
            .partitions_created = partitions_created,
            .future_partition_count = future_count,
            .severity = severity,
        };
    }

    /// Ensures a single `<parent>_YYYY_MM` partition exists and is attached.
    /// Returns true if this call created+attached it (false if it already
    /// existed and was already ATTACHED in plat_partition_catalog).
    fn ensurePartitionAttached(
        self: *PartitionMaintenanceScheduler,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        parent: []const u8,
        range: MonthRange,
    ) PartitionMaintenanceError!bool {
        const partition_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ parent, range.suffix });
        defer allocator.free(partition_name);

        // Already tracked as ATTACHED in plat_partition_catalog?
        var existing = conn.query(
            allocator,
            "SELECT 1 FROM plat_partition_catalog WHERE table_name = $1 AND parent_table = $2 AND state = 'ATTACHED'",
            &.{ partition_name, parent },
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };
        defer existing.deinit();
        if (existing.rows.len > 0) return false;

        const start_text = try formatTimestamptzLiteral(allocator, range.start_us);
        defer allocator.free(start_text);
        const end_text = try formatTimestamptzLiteral(allocator, range.end_us);
        defer allocator.free(end_text);

        const create_sql = std.fmt.allocPrint(
            allocator,
            "CREATE TABLE IF NOT EXISTS {s} (LIKE {s} INCLUDING DEFAULTS, " ++
                "CHECK (tenant_id IS NOT NULL), " ++
                "CHECK (created_at >= '{s}' AND created_at < '{s}'))",
            .{ partition_name, parent, start_text, end_text },
        ) catch return PartitionMaintenanceError.TransactionFailed;
        defer allocator.free(create_sql);

        conn.exec(create_sql, &.{}) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };

        const verdict = partition_attach.attachPartitionTimed(
            allocator,
            conn,
            parent,
            partition_name,
            .{ .start = range.start_us, .end = range.end_us },
        ) catch |err| switch (err) {
            partition_attach.PartitionAttachError.PoolExhausted => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };

        switch (verdict) {
            .attach_scan_required => return PartitionMaintenanceError.UnexpectedAttachScanRequired,
            .ok => {},
        }

        conn.exec(
            \\INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end, state)
            \\VALUES ($1, $2, $3::timestamptz, $4::timestamptz, 'ATTACHED')
            \\ON CONFLICT (table_name) DO UPDATE SET state = 'ATTACHED', parent_table = EXCLUDED.parent_table,
            \\  range_start = EXCLUDED.range_start, range_end = EXCLUDED.range_end, updated_at = NOW()
        ,
            &.{ partition_name, parent, start_text, end_text },
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
            else => return PartitionMaintenanceError.TransactionFailed,
        };

        // PAR-02 AC5: emit EXECUTION_PARTITION_CREATED (ISS-0670). Non-fatal.
        if (self.store) |s| {
            const payload_json = std.fmt.allocPrint(
                allocator,
                "{{\"partition_name\":\"{s}\",\"parent_table\":\"{s}\"," ++
                    "\"range_start\":\"{s}\",\"range_end\":\"{s}\"}}",
                .{ partition_name, parent, start_text, end_text },
            ) catch null;
            if (payload_json) |pj| {
                defer allocator.free(pj);
                const ikey = std.fmt.allocPrint(
                    allocator,
                    "EXECUTION_PARTITION_CREATED:{s}",
                    .{partition_name},
                ) catch null;
                if (ikey) |ik| {
                    defer allocator.free(ik);
                    _ = s.appendPlatform(allocator, .{
                        .event_type = "EXECUTION_PARTITION_CREATED",
                        .payload = pj,
                        .idempotency_key = ik,
                    }) catch |err| {
                        std.log.warn(
                            "appendPlatform EXECUTION_PARTITION_CREATED failed for {s}: {any}",
                            .{ partition_name, err },
                        );
                    };
                }
            }
        }

        return true;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

const MonthRange = struct {
    start_us: i64,
    end_us: i64,
    /// "YYYY_MM" suffix.
    suffix: [7]u8,
};

/// Query the database's current month start (00:00:00 UTC on the 1st) so the
/// month grid this job computes is anchored to the SAME clock PAR-01's
/// migration used (NOW(), server-side), not the calling process's own clock —
/// avoiding any drift between server time and Zig-process wall-clock time.
fn currentMonthStartUs(allocator: std.mem.Allocator, conn: *db.Conn) PartitionMaintenanceError!i64 {
    var result = conn.query(
        allocator,
        "SELECT (EXTRACT(EPOCH FROM date_trunc('month', now())) * 1000000)::bigint",
        &.{},
    ) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return PartitionMaintenanceError.PoolExhausted,
        else => return PartitionMaintenanceError.TransactionFailed,
    };
    defer result.deinit();

    if (result.rows.len > 0 and result.rows[0].len > 0) {
        if (result.rows[0][0]) |v| {
            return std.fmt.parseInt(i64, v, 10) catch return PartitionMaintenanceError.TransactionFailed;
        }
    }
    return PartitionMaintenanceError.TransactionFailed;
}

/// Compute the [start, end) range (in UTC microseconds) and "YYYY_MM" suffix
/// for `month_start_us + offset` months.
fn monthRange(month_start_us: i64, offset: u32) MonthRange {
    const start_us = addMonthsUs(month_start_us, @intCast(offset));
    const end_us = addMonthsUs(month_start_us, @as(i64, @intCast(offset)) + 1);

    var suffix: [7]u8 = undefined;
    const ymd = usToYearMonth(start_us);
    _ = std.fmt.bufPrint(&suffix, "{d:0>4}_{d:0>2}", .{ ymd.year, ymd.month }) catch unreachable;

    return .{ .start_us = start_us, .end_us = end_us, .suffix = suffix };
}

const YearMonth = struct { year: u16, month: u8 };

fn usToYearMonth(us: i64) YearMonth {
    const secs = @divFloor(us, 1_000_000);
    const epoch_secs: u64 = @intCast(@max(secs, 0));
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const year_day = epoch_day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{ .year = year_day.year, .month = month_day.month.numeric() };
}

/// Add `n` calendar months (may be negative) to a UTC-microseconds timestamp
/// that is already a month boundary (00:00:00 on the 1st), returning the new
/// month boundary. Only ever called with month-boundary inputs in this file.
fn addMonthsUs(month_start_us: i64, n: i64) i64 {
    const ymd = usToYearMonth(month_start_us);
    var total_months: i64 = @as(i64, ymd.year) * 12 + @as(i64, ymd.month - 1) + n;
    const new_year: i64 = @divFloor(total_months, 12);
    total_months = @mod(total_months, 12);
    if (total_months < 0) total_months += 12;
    const new_month: u8 = @intCast(total_months + 1);

    return yearMonthToUs(@intCast(new_year), new_month);
}

fn yearMonthToUs(year: u16, month: u8) i64 {
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }
    const month_lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += month_lengths[m - 1];
        if (m == 2 and isLeapYear(year)) days += 1;
    }
    return days * 86_400_000_000;
}

fn isLeapYear(year: u16) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn formatTimestamptzLiteral(allocator: std.mem.Allocator, us: i64) ![]u8 {
    const ymd_and_time = usToDateTimeParts(us);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ ymd_and_time.year, ymd_and_time.month, ymd_and_time.day, ymd_and_time.hour, ymd_and_time.minute, ymd_and_time.second },
    );
}

const DateTimeParts = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

fn usToDateTimeParts(us: i64) DateTimeParts {
    const secs = @divFloor(us, 1_000_000);
    const epoch_secs: u64 = @intCast(@max(secs, 0));
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_seconds = epoch_day.getDaySeconds();
    const year_day = epoch_day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

/// Pure: renders `now_us` (UTC microseconds) as a "YYYY-MM-DD" date string.
/// Takes the timestamp as a parameter rather than reading the wall clock
/// itself, so callers that already have a `now_us` (computeNextRunDelayMs())
/// derive "today" from the SAME instant they were passed, rather than a
/// second, independently-read clock value that could disagree near a
/// midnight boundary.
fn todayUtcDateString(buf: *[64]u8, now_us: i64) ![]const u8 {
    const parts = usToDateTimeParts(now_us);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ parts.year, parts.month, parts.day });
}

fn intToStr(allocator: std.mem.Allocator, value: u32) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB)
// ---------------------------------------------------------------------------

test "monthRange: offset 0 covers exactly the given month boundary" {
    // 2026-08-01T00:00:00Z in UTC microseconds.
    const aug_start: i64 = 1785542400_000_000;
    const r = monthRange(aug_start, 0);
    try std.testing.expectEqual(aug_start, r.start_us);
    try std.testing.expectEqualStrings("2026_08", &r.suffix);

    // End should be September 1 2026.
    const sep_start: i64 = 1788220800_000_000;
    try std.testing.expectEqual(sep_start, r.end_us);
}

test "monthRange: offset 2 covers two months ahead, crossing a year boundary correctly" {
    // 2026-12-01T00:00:00Z
    const dec_start: i64 = 1796083200_000_000;
    const r = monthRange(dec_start, 2);
    try std.testing.expectEqualStrings("2027_02", &r.suffix);
}

test "computeNextRunDelayMs: fires immediately when today has not run and boundary passed" {
    var pool: db.Pool = undefined;
    var sched = PartitionMaintenanceScheduler{ .pool = &pool, .config = .{ .run_hour_utc = 0, .run_minute_utc = 15 } };
    // 2026-08-11T12:00:00Z (well past 00:15 UTC boundary).
    const now_us: i64 = 1786449600_000_000;
    const delay = sched.computeNextRunDelayMs(now_us, null);
    try std.testing.expectEqual(@as(u64, 0), delay);
}

test "computeNextRunDelayMs: waits for tomorrow's boundary once today already ran" {
    var pool: db.Pool = undefined;
    var sched = PartitionMaintenanceScheduler{ .pool = &pool, .config = .{ .run_hour_utc = 0, .run_minute_utc = 15 } };
    const now_us: i64 = 1786449600_000_000; // 2026-08-11T12:00:00Z
    const delay = sched.computeNextRunDelayMs(now_us, "2026-08-11");
    try std.testing.expect(delay > 0);
}

test "computeNextRunDelayMs: waits for today's boundary when not yet reached" {
    var pool: db.Pool = undefined;
    var sched = PartitionMaintenanceScheduler{ .pool = &pool, .config = .{ .run_hour_utc = 0, .run_minute_utc = 15 } };
    // 2026-08-11T00:00:00Z (before 00:15 UTC boundary).
    const now_us: i64 = 1786406400_000_000;
    const delay = sched.computeNextRunDelayMs(now_us, null);
    try std.testing.expectEqual(@as(u64, 15 * 60 * 1000), delay);
}
