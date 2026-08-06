//! Wall clock timeout enforcement (LUA-10).
//!
//! Tracks elapsed time during script execution and raises an error when timeout is exceeded.
//! This is separate from instruction counting to handle blocking operations.

const std = @import("std");
const time_source = @import("time_source.zig");

pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64, // nanoseconds since epoch
    timed_out: bool,

    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @as(u64, timeout_seconds) * 1000,
            // ISS-0153: std.time.nanoTimestamp() was removed in Zig 0.16.
            .start_time = time_source.currentNanoTimestamp(),
            .timed_out = false,
        };
    }

    /// Check if timeout has been exceeded. Returns error if so.
    pub fn checkTimeout(self: *TimeoutContext) !void {
        if (self.elapsedMs() > self.timeout_ms) {
            self.timed_out = true;
            return error.WallClockTimeoutExceeded;
        }
    }

    /// Get elapsed time in milliseconds.
    pub fn getElapsedMs(self: *const TimeoutContext) u64 {
        return self.elapsedMs();
    }

    /// ISS-0153: the original code used `@divExact(elapsed_ns, 1_000_000)`,
    /// which panics with "exact division produced remainder" for every elapsed
    /// time that is not a whole number of milliseconds — i.e. essentially
    /// always. `@divTrunc` is the correct operation for "how many whole ms have
    /// passed". A clock that runs backwards (NTP step) clamps to 0 rather than
    /// wrapping the unsigned cast.
    fn elapsedMs(self: *const TimeoutContext) u64 {
        const now = time_source.currentNanoTimestamp();
        if (now <= self.start_time) return 0;
        return @divTrunc(@as(u64, @intCast(now - self.start_time)), 1_000_000);
    }

    /// Get configured timeout in milliseconds.
    pub fn getTimeoutMs(self: *const TimeoutContext) u64 {
        return self.timeout_ms;
    }
};

pub const TimeoutError = error{
    WallClockTimeoutExceeded,
};
