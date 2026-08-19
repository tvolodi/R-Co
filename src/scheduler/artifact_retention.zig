//! AGT-06 — Dual-sweep staging artifact retention.
//!
//! Sweep 1: delete needs_review artifacts older than BPM_STAGING_REVIEW_TTL_DAYS (default 30).
//! Sweep 2: delete verified artifacts whose version pin has been collected AND
//!           verified_at is older than BPM_STAGING_VERIFIED_TTL_DAYS (default 365).
//!
//! Both sweeps are idempotent. Failures are logged at ERROR level and retried
//! on the next daily run. The scheduler fires at 03:00 UTC with sweep 1
//! running before sweep 2 so that needs_review rows aged out in sweep 1 never
//! enter the sweep-2 predicate.

const std = @import("std");
const db = @import("pool");

pub const RetentionConfig = struct {
    run_hour_utc: u8 = 3,
    run_minute_utc: u8 = 0,
    review_ttl_days: u32 = 30,
    verified_ttl_days: u32 = 365,
};

/// Delete needs_review artifacts older than review_ttl_days. Returns rows deleted.
pub fn runArtifactRetentionSweep1(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    review_ttl_days: u32,
) !u64 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const days_str = try std.fmt.allocPrint(allocator, "{d}", .{review_ttl_days});
    defer allocator.free(days_str);

    const row = try conn.queryRow(
        allocator,
        \\WITH deleted AS (
        \\    DELETE FROM staging.agent_artifacts
        \\    WHERE status = 'needs_review'
        \\      AND created_at < NOW() - ($1::integer * INTERVAL '1 day')
        \\    RETURNING 1
        \\)
        \\SELECT COUNT(*)::text FROM deleted
    ,
        &.{days_str},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |c| allocator.free(c);
        allocator.free(r);
    };

    if (row) |r| {
        if (r[0]) |count_str| {
            return std.fmt.parseInt(u64, count_str, 10) catch 0;
        }
    }
    return 0;
}

/// Delete verified artifacts whose pin has been collected AND verified_at is older
/// than verified_ttl_days. Returns rows deleted.
pub fn runArtifactRetentionSweep2(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    verified_ttl_days: u32,
) !u64 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const days_str = try std.fmt.allocPrint(allocator, "{d}", .{verified_ttl_days});
    defer allocator.free(days_str);

    const row = try conn.queryRow(
        allocator,
        \\WITH deleted AS (
        \\    DELETE FROM staging.agent_artifacts a
        \\    USING staging.artifact_version_pins p
        \\    WHERE a.artifact_id = p.artifact_id
        \\      AND p.collected_at IS NOT NULL
        \\      AND a.verified_at < NOW() - ($1::integer * INTERVAL '1 day')
        \\    RETURNING 1
        \\)
        \\SELECT COUNT(*)::text FROM deleted
    ,
        &.{days_str},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |c| allocator.free(c);
        allocator.free(r);
    };

    if (row) |r| {
        if (r[0]) |count_str| {
            return std.fmt.parseInt(u64, count_str, 10) catch 0;
        }
    }
    return 0;
}

pub const ArtifactRetentionScheduler = struct {
    pool: *db.Pool,
    config: RetentionConfig,

    pub fn init(pool: *db.Pool, config: RetentionConfig) ArtifactRetentionScheduler {
        return .{ .pool = pool, .config = config };
    }

    /// Background loop: sleeps until the next configured UTC boundary, runs
    /// both sweeps in order, then repeats. Errors from a single cycle are
    /// logged and swallowed; the loop never terminates.
    pub fn runDailyLoop(self: *ArtifactRetentionScheduler, allocator: std.mem.Allocator) noreturn {
        while (true) {
            const now_us: i64 = std.Io.Clock.real.now(self.pool.io).toMicroseconds();
            const delay_ms = self.computeNextRunDelayMs(now_us);
            if (delay_ms > 0) {
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }

            const n1 = runArtifactRetentionSweep1(allocator, self.pool, self.config.review_ttl_days) catch |err| {
                std.log.err("artifact_retention: sweep1 failed: {}", .{err});
                std.Thread.sleep(60 * std.time.ns_per_s);
                continue;
            };

            const n2 = runArtifactRetentionSweep2(allocator, self.pool, self.config.verified_ttl_days) catch |err| blk: {
                std.log.err("artifact_retention: sweep2 failed: {}", .{err});
                break :blk @as(u64, 0);
            };

            std.log.info("artifact_retention: cycle complete — sweep1 deleted {d}, sweep2 deleted {d}", .{ n1, n2 });
        }
    }

    /// Returns milliseconds to sleep until the next scheduled run at run_hour_utc:run_minute_utc.
    /// Returns 0 if the scheduled time for today has not yet passed and we are
    /// already past it (run immediately).
    fn computeNextRunDelayMs(self: *const ArtifactRetentionScheduler, now_us: i64) u64 {
        const seconds_in_day: i64 = 86400;
        const now_s = @divFloor(now_us, 1_000_000);
        const midnight_offset_s: i64 = @as(i64, self.config.run_hour_utc) * 3600 +
            @as(i64, self.config.run_minute_utc) * 60;
        const today_run_s = @divFloor(now_s, seconds_in_day) * seconds_in_day + midnight_offset_s;
        const next_run_s: i64 = if (now_s < today_run_s) today_run_s else today_run_s + seconds_in_day;
        const diff_s = next_run_s - now_s;
        if (diff_s <= 0) return 0;
        return @as(u64, @intCast(diff_s)) * 1000;
    }
};
