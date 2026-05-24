const std = @import("std");
const builtin = @import("builtin");
const logger = @import("obs/logger.zig");

/// All configuration read from environment variables at startup.
pub const Config = struct {
    /// PostgreSQL connection URL for the main database. Required.
    db_url: []const u8,

    /// PostgreSQL connection URL used by integration tests. Required for tests.
    test_db_url: ?[]const u8,

    /// TCP port the HTTP server listens on. Default: 8080.
    port: u16,

    /// Log verbosity level. Default: INFO.
    log_level: logger.LogLevel,

    /// Runtime environment tag. Default: development.
    env: []const u8,

    /// Bootstrap admin token for initial setup. Dev only.
    bootstrap_token: ?[]const u8,
};

pub const ConfigError = error{
    MissingRequiredVar,
    InvalidPort,
    InvalidLogLevel,
    OutOfMemory,
};

fn getEnvAlloc(allocator: std.mem.Allocator, name: []const u8) ConfigError!?[]const u8 {
    const environ: std.process.Environ = .{ .block = .global };
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    };
}

/// Load configuration from environment variables.
/// Caller owns the returned Config; dynamic string fields are allocated with allocator.
pub fn load(allocator: std.mem.Allocator) ConfigError!Config {
    const db_url = (try getEnvAlloc(allocator, "BPM_DB_URL")) orelse {
        std.debug.print("ERROR: BPM_DB_URL is required\n", .{});
        return ConfigError.MissingRequiredVar;
    };

    const port_str = try getEnvAlloc(allocator, "BPM_PORT");
    defer if (port_str) |value| allocator.free(value);
    const port = std.fmt.parseInt(u16, port_str orelse "8080", 10) catch {
        std.debug.print("ERROR: BPM_PORT must be a valid port number\n", .{});
        return ConfigError.InvalidPort;
    };

    const raw_log_level = try getEnvAlloc(allocator, "BPM_LOG_LEVEL");
    defer if (raw_log_level) |value| allocator.free(value);
    const log_level = logger.parseLogLevel(raw_log_level orelse "INFO") catch {
        std.debug.print(
            "FATAL: invalid BPM_LOG_LEVEL '{s}'. Allowed values: DEBUG, INFO, WARN, ERROR\n",
            .{raw_log_level orelse "INFO"},
        );
        return ConfigError.InvalidLogLevel;
    };

    return Config{
        .db_url = db_url,
        .test_db_url = try getEnvAlloc(allocator, "BPM_TEST_DB_URL"),
        .port = port,
        .log_level = log_level,
        .env = (try getEnvAlloc(allocator, "BPM_ENV")) orelse "development",
        .bootstrap_token = try getEnvAlloc(allocator, "BPM_BOOTSTRAP_TOKEN"),
    };
}

const testing = std.testing;

const WinEnv = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpValue: ?[*:0]const u16,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

fn freeLoadedConfig(allocator: std.mem.Allocator, config: Config) void {
    allocator.free(config.db_url);
    if (config.test_db_url) |value| allocator.free(value);
    if (!std.mem.eql(u8, config.env, "development")) allocator.free(config.env);
    if (config.bootstrap_token) |value| allocator.free(value);
}

fn setWindowsEnv(comptime name: []const u8, comptime value: ?[]const u8) void {
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral(name);
    if (value) |literal| {
        _ = WinEnv.SetEnvironmentVariableW(name_w, std.unicode.utf8ToUtf16LeStringLiteral(literal));
    } else {
        _ = WinEnv.SetEnvironmentVariableW(name_w, null);
    }
}

test "TC-OBS-01-01a: config.load defaults BPM_LOG_LEVEL to INFO when unset" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    setWindowsEnv("BPM_DB_URL", "postgres://bpm:bpm@localhost:5432/bpm");
    defer setWindowsEnv("BPM_DB_URL", null);
    setWindowsEnv("BPM_LOG_LEVEL", null);
    defer setWindowsEnv("BPM_LOG_LEVEL", null);

    const config = try load(testing.allocator);
    defer freeLoadedConfig(testing.allocator, config);

    try testing.expectEqual(logger.LogLevel.INFO, config.log_level);
}

test "TC-OBS-01-01b: config.load rejects invalid BPM_LOG_LEVEL" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    setWindowsEnv("BPM_DB_URL", "postgres://bpm:bpm@localhost:5432/bpm");
    defer setWindowsEnv("BPM_DB_URL", null);
    setWindowsEnv("BPM_LOG_LEVEL", "TRACE");
    defer setWindowsEnv("BPM_LOG_LEVEL", null);

    try testing.expectError(ConfigError.InvalidLogLevel, load(testing.allocator));
}
