//! Structured logging for Lua scripts (LUA-13).
//!
//! Provides the platform.log() function to emit structured log entries
//! with correlation IDs, script identity, and contextual information.

const std = @import("std");
const time_source = @import("time_source.zig");
const executor = @import("executor.zig");

pub const LogLevel = enum {
    DEBUG,
    INFO,
    WARN,
    ERROR,

    pub fn fromString(s: []const u8) ?LogLevel {
        return std.meta.stringToEnum(LogLevel, s);
    }

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
        };
    }
};

pub const StructuredLogEntry = struct {
    timestamp: time_source.DateTime,
    level: LogLevel,
    message: []const u8,
    script_id: []const u8,
    instance_id: []const u8,
    actor_id: []const u8,
    trace_id: []const u8,
    context: ?executor.ScriptValue,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StructuredLogEntry) void {
        if (self.context) |ctx| {
            ctx.deinit(self.allocator);
        }
    }
};

pub const StructuredLogger = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StructuredLogger {
        return StructuredLogger{
            .allocator = allocator,
        };
    }

    /// Log a structured entry. For MVP, this logs to stderr in JSON format.
    pub fn log(self: *StructuredLogger, entry: StructuredLogEntry) !void {
        const iso_time = try entry.timestamp.formatISO8601(self.allocator);
        defer self.allocator.free(iso_time);

        // Simple JSON-like output (production would serialize fully)
        const message = std.fmt.allocPrint(
            self.allocator,
            "[{s}] {s} | script={s} instance={s} actor={s} trace={s} | {s}\n",
            .{ iso_time, entry.level.toString(), entry.script_id, entry.instance_id, entry.actor_id, entry.trace_id, entry.message },
        ) catch |err| {
            std.debug.print("Log entry formatting error: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(message);

        // Write to stderr (or a real logging backend in production).
        //
        // ISS-0172 / GH #500: `std.io.getStdErr()` does not exist in Zig
        // 0.16 ("root source file struct 'std' has no member named 'io'").
        // This call site had never been analysed — src/lua_test_root.zig
        // pinned StructuredLogger with a bare `_ = StructuredLogger;` type
        // reference, which resolves the type name but neither its fields nor
        // its methods' bodies, so the break stayed invisible through a green
        // `zig build test-lua` until the pin was strengthened to force real
        // analysis of this method. `std.debug.print` is this codebase's
        // established 0.16-era stderr pattern (see the fallback error path
        // immediately above, and src/config.zig/src/expr/benchmark.zig for
        // the same idiom elsewhere).
        std.debug.print("{s}", .{message});
    }
};
