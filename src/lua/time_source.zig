//! Platform time source for Lua scripts (LUA-14).
//!
//! Provides the authoritative platform time to Lua scripts via platform.now().
//! This ensures determinism and prevents scripts from accessing system time directly.

const std = @import("std");

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,

    /// Format as ISO 8601 UTC string (YYYY-MM-DDTHH:MM:SS.sssZ).
    pub fn formatISO8601(self: *const DateTime, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{:04d}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}.{:03d}Z",
            .{
                self.year, self.month, self.day,
                self.hour, self.minute, self.second,
                self.millisecond,
            },
        );
    }

    /// Create DateTime from Unix nanosecond timestamp.
    pub fn fromNanoseconds(nanos: i64) DateTime {
        const secs = @divTrunc(nanos, 1_000_000_000);
        const millis = @divTrunc(@rem(nanos, 1_000_000_000), 1_000_000);

        // Simplified: use epoch-based calculation
        // For production, integrate with proper datetime library
        const days_since_epoch = @divTrunc(secs, 86400);
        const secs_today = @rem(secs, 86400);

        const hour = @divTrunc(secs_today, 3600);
        const minute = @divTrunc(@rem(secs_today, 3600), 60);
        const second = @rem(secs_today, 60);

        // Simplified year/month/day calculation (approx)
        const year: u16 = 1970 + @as(u16, @intCast(@divTrunc(days_since_epoch, 365)));
        const day_of_year = @rem(days_since_epoch, 365);
        const month: u8 = @as(u8, @intCast(@divTrunc(day_of_year, 30))) + 1;
        const day: u8 = @as(u8, @intCast(@rem(day_of_year, 30))) + 1;

        return DateTime{
            .year = year,
            .month = month,
            .day = day,
            .hour = @as(u8, @intCast(hour)),
            .minute = @as(u8, @intCast(minute)),
            .second = @as(u8, @intCast(second)),
            .millisecond = @as(u16, @intCast(millis)),
        };
    }
};

pub const TimeSource = struct {
    /// Get current platform time.
    pub fn now() !DateTime {
        const nanos = std.time.nanoTimestamp();
        return DateTime.fromNanoseconds(nanos);
    }
};
