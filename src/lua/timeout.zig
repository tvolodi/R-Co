//! Wall clock timeout enforcement (LUA-10).
//!
//! Tracks elapsed time during script execution and raises an error when timeout is exceeded.
//! This is separate from instruction counting to handle blocking operations.

const std = @import("std");

pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64, // nanoseconds since epoch
    timed_out: bool,

    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @as(u64, timeout_seconds) * 1000,
            .start_time = std.time.nanoTimestamp(),
            .timed_out = false,
        };
    }

    /// Check if timeout has been exceeded. Returns error if so.
    pub fn checkTimeout(self: *TimeoutContext) !void {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divExact(@as(u64, @intCast(now - self.start_time)), 1_000_000);

        if (elapsed_ms > self.timeout_ms) {
            self.timed_out = true;
            return error.WallClockTimeoutExceeded;
        }
    }

    /// Get elapsed time in milliseconds.
    pub fn getElapsedMs(self: *const TimeoutContext) u64 {
        const now = std.time.nanoTimestamp();
        return @divExact(@as(u64, @intCast(now - self.start_time)), 1_000_000);
    }

    /// Get configured timeout in milliseconds.
    pub fn getTimeoutMs(self: *const TimeoutContext) u64 {
        return self.timeout_ms;
    }
};

pub const TimeoutError = error{
    WallClockTimeoutExceeded,
};
