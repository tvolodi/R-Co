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
        // ISS-0153: pre-0.16 `{:04d}` format syntax; see host_api/now.zig.
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
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

/// Current wall-clock time as nanoseconds since the Unix epoch.
///
/// ISS-0153: Zig 0.16 removed `std.time.nanoTimestamp()` / `microTimestamp()`
/// from the public API, so the original `std.time.nanoTimestamp()` call here no
/// longer compiled. This mirrors the portable replacement already established
/// in this repo by `src/api/routes/instances.zig::currentMicrosecondTimestamp`
/// — Windows via `RtlGetSystemTimePrecise`, POSIX via `clock_gettime(.REALTIME)`.
pub fn currentNanoTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        // 100-nanosecond intervals since 1601-01-01 00:00:00 UTC.
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        // 116444736000000000 = offset between the Windows and Unix epochs.
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return unix_100ns * 100;
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec * 1_000_000_000 + ts.nsec;
    }
}

pub const TimeSource = struct {
    /// Get current platform time.
    pub fn now() !DateTime {
        return DateTime.fromNanoseconds(currentNanoTimestamp());
    }
};
