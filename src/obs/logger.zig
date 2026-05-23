//! Structured logger for the BPM Platform (OBS-01).
//!
//! Every log entry carries a trace_id field sourced from the thread-local
//! trace_context.  This allows all log lines for a single HTTP request to
//! be correlated by trace_id.
//!
//! Background tasks (scheduler, timer poller) MUST call
//! trace_context.set() / trace_context.clear() around the task body so
//! their log entries are also traceable.
//!
//! Usage:
//!   logger.info("definition created", .{ .definition_id = id });
//!   // → {"level":"INFO","msg":"definition created","trace_id":"<uuid>", ...}

const std = @import("std");
const trace_context = @import("../api/trace_context.zig");

// ── Log levels ────────────────────────────────────────────────────────────────

pub const Level = enum {
    DEBUG,
    INFO,
    WARN,
    ERROR,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
        };
    }
};

// ── Public logging functions ──────────────────────────────────────────────────

/// Write a DEBUG-level log entry to stderr.
pub fn debug(comptime msg: []const u8, args: anytype) void {
    log(.DEBUG, msg, args);
}

/// Write an INFO-level log entry to stderr.
pub fn info(comptime msg: []const u8, args: anytype) void {
    log(.INFO, msg, args);
}

/// Write a WARN-level log entry to stderr.
pub fn warn(comptime msg: []const u8, args: anytype) void {
    log(.WARN, msg, args);
}

/// Write an ERROR-level log entry to stderr.
pub fn err(comptime msg: []const u8, args: anytype) void {
    log(.ERROR, msg, args);
}

// ── Internal implementation ───────────────────────────────────────────────────

fn log(level: Level, comptime msg: []const u8, args: anytype) void {
    const trace_id = trace_context.get();
    const stderr = std.io.getStdErr().writer();
    // Write as: {"level":"<LEVEL>","msg":"<formatted msg>","trace_id":"<id>"}
    stderr.writeAll("{\"level\":\"") catch return;
    stderr.writeAll(level.toString()) catch return;
    stderr.writeAll("\",\"msg\":\"") catch return;
    stderr.print(msg, args) catch return;
    stderr.writeAll("\",\"trace_id\":\"") catch return;
    stderr.writeAll(trace_id) catch return;
    stderr.writeAll("\"}\n") catch return;
}

// ── Embedded unit tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "logger: log functions compile and do not crash" {
    // These write to stderr; we only verify they compile and run without panic.
    trace_context.set("test-trace-id");
    defer trace_context.clear();
    debug("test debug {s}", .{"arg"});
    info("test info", .{});
    warn("test warn", .{});
    err("test error", .{});
}
