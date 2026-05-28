//! Wall-clock timeout enforcement for Wasm module execution.
//!
//! Prevents modules from blocking indefinitely on host function calls
//! or performing unbounded computation.

const std = @import("std");

pub const TimeoutContext = struct {
    timeout_ms: u64,
    // Use a simple counter for now (will be upgraded with real clock in Stage 10)
    start_marker: u64 = 0,
    timed_out: bool = false,

    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @as(u64, timeout_seconds) * 1000,
            .start_marker = getTimeMarker(),
        };
    }

    /// Check if the timeout has been exceeded.
    /// Returns error.WallClockTimeoutExceeded if so.
    pub fn checkTimeout(self: *TimeoutContext) !void {
        const now = getTimeMarker();
        const elapsed_ms: u64 = if (now >= self.start_marker) now - self.start_marker else 0;

        if (elapsed_ms > self.timeout_ms) {
            self.timed_out = true;
            return error.WallClockTimeoutExceeded;
        }
    }

    /// Get elapsed time in milliseconds.
    pub fn elapsedMs(self: *const TimeoutContext) u64 {
        const now = getTimeMarker();
        return if (now >= self.start_marker) now - self.start_marker else 0;
    }
};

/// Get a time marker in milliseconds (placeholder implementation).
fn getTimeMarker() u64 {
    // Placeholder: will use real clock in Stage 10
    return 1000;
}

pub const TimeoutError = error{WallClockTimeoutExceeded};
