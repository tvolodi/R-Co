//! Shared-store sliding-window rate limiter (ISS-401, ISS-403).
//!
//! Replaces the legacy in-memory per-node rate limiter with a PostgreSQL-backed
//! sliding-window counter. The shared store ensures global enforcement across
//! all nodes in a multi-node deployment.
//!
//! Key = (tenant_id, principal). Principal is resolved by auth middleware:
//!   - Local API tokens: api_tokens.id UUID
//!   - OIDC tokens:       "{realm}:{sub}" composite (ISS-403)
//!
//! Algorithm: fixed-size window (default 60 seconds). Each bucket is a row
//! in rate_limit_buckets. On each check(), an atomic upsert inside a
//! transaction increments the count. If the count exceeds max_rpm, the
//! request is rate-limited with an HTTP 429 + Retry-After header.
//!
//! Requires GBL-083_rate_limit_buckets migration.

const std = @import("std");
const pool_mod = @import("pool");
const errors = @import("../errors.zig");
// ── Inlined config types (shared with src/config/rate_limit.zig for startup validation) ──

pub const RateLimitBackend = enum { postgres, redis };

pub const RateLimitConfig = struct {
    backend: RateLimitBackend,
    max_rpm: u64,
    window_seconds: u32,

    pub fn fromEnv() (RateLimitConfigError || std.fmt.ParseIntError)!RateLimitConfig {
        const backend_str = std.posix.getenv("BPM_RATE_LIMIT_BACKEND") orelse "postgres";
        const backend: RateLimitBackend = if (std.mem.eql(u8, backend_str, "redis"))
            .redis
        else if (std.mem.eql(u8, backend_str, "postgres"))
            .postgres
        else
            return RateLimitConfigError.BackendNotSupported;

        const max_rpm_str = std.posix.getenv("BPM_RATE_LIMIT_MAX_RPM") orelse "1000";
        const max_rpm = try std.fmt.parseInt(u64, max_rpm_str, 10);

        const window_str = std.posix.getenv("BPM_RATE_LIMIT_WINDOW_SECONDS") orelse "60";
        const window_seconds = try std.fmt.parseInt(u32, window_str, 10);

        return RateLimitConfig{
            .backend = backend,
            .max_rpm = max_rpm,
            .window_seconds = window_seconds,
        };
    }

    pub fn validate(self: *const RateLimitConfig) RateLimitConfigError!void {
        if (self.backend == .redis) return RateLimitConfigError.BackendNotSupported;
        if (self.max_rpm == 0) return RateLimitConfigError.MaxRpmZero;
        if (self.window_seconds == 0) return RateLimitConfigError.WindowSecondsZero;
    }
};

pub const RateLimitConfigError = error{
    BackendNotSupported,
    MaxRpmZero,
    WindowSecondsZero,
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const RateLimitedInfo = struct {
    retry_after: u32,
    body: []const u8,
};

pub const RateLimitResult = union(enum) {
    allowed: void,
    rate_limited: RateLimitedInfo,
};

pub const RateLimitError = error{
    OutOfMemory,
    PersistenceFailed,
    PoolExhausted,
    NotInitialized,
};

// ── Module-level state ────────────────────────────────────────────────────────

var global_config: RateLimitConfig = undefined;
var initialized: bool = false;

// ── Public functions ──────────────────────────────────────────────────────────

/// Initialise the rate limit module. MUST be called once at startup.
/// Reads config from environment via RateLimitConfig.fromEnv().
pub fn init(allocator: std.mem.Allocator) (RateLimitError || std.fmt.ParseIntError || RateLimitConfigError)!void {
    _ = allocator;
    global_config = try RateLimitConfig.fromEnv();
    try global_config.validate();
    initialized = true;
}

pub fn deinit() void {
    initialized = false;
}

/// Check whether (tenant_id, principal) is within rate limit.
///
/// Uses a sliding-window algorithm backed by rate_limit_buckets in PostgreSQL.
/// The upsert is atomic (INSERT ... ON CONFLICT DO UPDATE) inside a transaction
/// so concurrent nodes see the same aggregate count.
///
/// Returns .allowed or .rate_limited with the Retry-After info and pre-built
/// 429 response body.
pub fn check(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    principal: []const u8,
    now_unix: i64,
    pool: *pool_mod.Pool,
) RateLimitError!RateLimitResult {
    if (!initialized) return error.NotInitialized;

    const window_seconds: i64 = @intCast(global_config.window_seconds);
    const window_start = (now_unix / window_seconds) * window_seconds;
    const cleanup_threshold = now_unix - (2 * window_seconds);

    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    // BEGIN transaction.
    conn.begin() catch return error.PersistenceFailed;

    // Upsert: atomically increment the count for this window.
    // ON CONFLICT DO UPDATE ensures serialised access at the unique-index level.
    const window_start_str = std.fmt.allocPrint(allocator, "{d}", .{window_start}) catch return error.OutOfMemory;
    defer allocator.free(window_start_str);

    const row = conn.queryRow(
        allocator,
        \\INSERT INTO rate_limit_buckets (tenant_id, principal, window_start, count)
        \\VALUES ($1::uuid, $2, $3::bigint, 1)
        \\ON CONFLICT (tenant_id, principal, window_start)
        \\DO UPDATE SET count = rate_limit_buckets.count + 1
        \\RETURNING count
    ,
        &[_][]const u8{ tenant_id, principal, window_start_str },
    ) catch |err| {
        _ = conn.rollback() catch {};
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
    };

    const result_row = row orelse {
        _ = conn.rollback() catch {};
        return error.PersistenceFailed;
    };
    defer {
        for (result_row) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(result_row);
    }

    const count_str = result_row[0] orelse {
        _ = conn.rollback() catch {};
        return error.PersistenceFailed;
    };
    const new_count = std.fmt.parseInt(u64, count_str, 10) catch {
        _ = conn.rollback() catch {};
        return error.PersistenceFailed;
    };

    // Best-effort cleanup: remove rows older than 2 windows.
    const cleanup_str = std.fmt.allocPrint(allocator, "{d}", .{cleanup_threshold}) catch "";
    defer if (cleanup_str.len > 0) allocator.free(cleanup_str);
    if (cleanup_str.len > 0) {
        _ = conn.exec("DELETE FROM rate_limit_buckets WHERE window_start < $1::bigint", &[_][]const u8{cleanup_str}) catch {};
    }

    if (new_count > global_config.max_rpm) {
        const diff = window_start + window_seconds - now_unix;
        const retry_after: u32 = if (diff > 0) @intCast(diff) else 0;
        const body = try errors.serialise(allocator, errors.problemRateLimited("rate limit exceeded"));

        // COMMIT the transaction (count was incremented, we just report rate_limited).
        conn.commit() catch |err| {
            allocator.free(body);
            return switch (err) {
                else => error.PersistenceFailed,
            };
        };

        return .{ .rate_limited = .{ .retry_after = retry_after, .body = body } };
    }

    // COMMIT and return allowed.
    conn.commit() catch return error.PersistenceFailed;

    return .allowed;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "init respects defaults" {
    try init(std.testing.allocator);
    defer deinit();
    try std.testing.expect(global_config.max_rpm > 0);
    try std.testing.expect(global_config.window_seconds > 0);
}

test "deinit clears initialized" {
    try init(std.testing.allocator);
    deinit();
    try std.testing.expect(!initialized);
}

test "check returns NotInitialized before init" {
    // Pass undefined pool — must fail with NotInitialized before touching pool.
    const result = check(std.testing.allocator, "00000000-0000-0000-0000-000000000000", "test", 1000, @constCast(@ptrCast(&std.mem.zeroes(pool_mod.Pool))));
    try std.testing.expectError(error.NotInitialized, result);
}

test "validate rejects unsupported backend" {
    const c = RateLimitConfig{ .backend = .redis, .max_rpm = 100, .window_seconds = 60 };
    try std.testing.expectError(RateLimitConfigError.BackendNotSupported, c.validate());
}

test "validate rejects zero max_rpm" {
    const c = RateLimitConfig{ .backend = .postgres, .max_rpm = 0, .window_seconds = 60 };
    try std.testing.expectError(RateLimitConfigError.MaxRpmZero, c.validate());
}

test "validate rejects zero window" {
    const c = RateLimitConfig{ .backend = .postgres, .max_rpm = 100, .window_seconds = 0 };
    try std.testing.expectError(RateLimitConfigError.WindowSecondsZero, c.validate());
}
