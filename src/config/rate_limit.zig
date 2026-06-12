//! Rate-limit configuration validation (ISS-401).
//!
//! Validates BPM_RATE_LIMIT_BACKEND and BPM_RATE_LIMIT_MAX_RPM at startup.
//! The server refuses to start with a clear error message on invalid config.

const std = @import("std");

pub const RateLimitBackend = enum {
    postgres,
    redis,
};

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
        if (self.backend == .redis) {
            return RateLimitConfigError.BackendNotSupported;
        }
        if (self.max_rpm == 0) {
            return RateLimitConfigError.MaxRpmZero;
        }
        if (self.window_seconds == 0) {
            return RateLimitConfigError.WindowSecondsZero;
        }
    }
};

pub const RateLimitConfigError = error{
    BackendNotSupported,
    MaxRpmZero,
    WindowSecondsZero,
};
