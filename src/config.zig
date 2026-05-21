const std = @import("std");

/// All configuration read from environment variables at startup.
pub const Config = struct {
    /// PostgreSQL connection URL for the main database. Required.
    db_url: []const u8,

    /// PostgreSQL connection URL used by integration tests. Required for tests.
    test_db_url: ?[]const u8,

    /// TCP port the HTTP server listens on. Default: 8080.
    port: u16,

    /// Log verbosity level. Default: INFO.
    log_level: []const u8,

    /// Runtime environment tag. Default: development.
    env: []const u8,

    /// Bootstrap admin token for initial setup. Dev only.
    bootstrap_token: ?[]const u8,
};

pub const ConfigError = error{
    MissingRequiredVar,
    InvalidPort,
};

/// Load configuration from environment variables.
/// Caller owns the returned Config; all string fields point into env memory.
pub fn load(allocator: std.mem.Allocator) ConfigError!Config {
    _ = allocator; // reserved for future use (e.g. duplicating env strings)

    const db_url = std.posix.getenv("BPM_DB_URL") orelse {
        std.debug.print("ERROR: BPM_DB_URL is required\n", .{});
        return ConfigError.MissingRequiredVar;
    };

    const port_str = std.posix.getenv("BPM_PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("ERROR: BPM_PORT must be a valid port number\n", .{});
        return ConfigError.InvalidPort;
    };

    return Config{
        .db_url = db_url,
        .test_db_url = std.posix.getenv("BPM_TEST_DB_URL"),
        .port = port,
        .log_level = std.posix.getenv("BPM_LOG_LEVEL") orelse "INFO",
        .env = std.posix.getenv("BPM_ENV") orelse "development",
        .bootstrap_token = std.posix.getenv("BPM_BOOTSTRAP_TOKEN"),
    };
}
