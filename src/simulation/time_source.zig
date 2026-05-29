const std = @import("std");
const types = @import("types.zig");

pub const PlatformClock = struct {
    now_ms: i64,

    pub fn init(start_ms: i64) PlatformClock {
        return .{ .now_ms = start_ms };
    }

    pub fn nowMs(self: *const PlatformClock) i64 {
        return self.now_ms;
    }

    pub fn advanceMs(self: *PlatformClock, delta_ms: i64) types.SimulationError!void {
        if (delta_ms < 0) return error.InvalidSimulationTimeAdvance;
        const next, const overflow = @addWithOverflow(self.now_ms, delta_ms);
        if (overflow != 0) return error.SimulationTimeOverflow;
        self.now_ms = next;
    }

    pub fn setMs(self: *PlatformClock, absolute_ms: i64) types.SimulationError!void {
        self.now_ms = absolute_ms;
    }
};

test "PlatformClock: deterministic advancement" {
    var clock = PlatformClock.init(1000);
    try std.testing.expectEqual(@as(i64, 1000), clock.nowMs());
    try clock.advanceMs(25);
    try std.testing.expectEqual(@as(i64, 1025), clock.nowMs());
    try clock.setMs(10);
    try std.testing.expectEqual(@as(i64, 10), clock.nowMs());
}

test "PlatformClock: rejects negative advance" {
    var clock = PlatformClock.init(0);
    try std.testing.expectError(error.InvalidSimulationTimeAdvance, clock.advanceMs(-1));
}
