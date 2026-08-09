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

/// WF03-GH591 / ISS-0624 — LUA-13 (design §7.1). Writer injection point.
///
/// The default writer routes through `std.debug.print` (the same
/// ISS-0172-established 0.16-era stderr pattern the prior body used).
/// Tests inject a `Writer` that appends to an `std.ArrayList(u8)` so the
/// captured entry can be asserted on. The signature mirrors the
/// `HttpClientFn` pattern already used by LUA-12 — function pointer
/// plus opaque context — keeping the codebase's dependency-injection
/// convention uniform.
///
/// The bare `fn (...)` type stays at the TYPE level (comptime-only is fine
/// at the type level; what is forbidden is storing a bare fn as a *field*).
/// The FIELD below uses `*const Writer` — pointer to const function pointer —
/// which is the runtime-known form Zig 0.16 accepts. This mirrors the
/// LUA-12 HttpClientFn pattern at src/lua/executor.zig:84.
///
/// Return type is `void` (NOT `anyerror!void`) because function-pointer
/// types whose return includes `anyerror` are comptime-only in Zig 0.16
/// — they cannot be stored as a struct field or loaded through a pointer.
/// The writer never fails in the only path the platform exercises today
/// (`std.debug.print`), and a test writer that appends to an `ArrayList`
/// propagates its own OOM via the arraylist methods which we call from
/// the writer closure; the writer itself never errors.
pub const Writer = fn (ctx: ?*anyopaque, msg: []const u8) void;

fn defaultWriter(ctx: ?*anyopaque, msg: []const u8) void {
    _ = ctx;
    std.debug.print("{s}", .{msg});
}

pub const StructuredLogger = struct {
    allocator: std.mem.Allocator,
    /// *const Writer — pointer to const fn-pointer — is the runtime-known
    /// form Zig 0.16 requires for function-pointer fields. Default
    /// `&defaultWriter` is a real function address; tests override the
    /// pointer via `initWithWriter` with a function that captures into an
    /// ArrayList. Zig auto-derefs the pointer at the call site.
    writer: *const Writer = &defaultWriter,
    /// Opaque pointer passed alongside `writer`. Lifetime is the caller's
    /// responsibility — the logger does not own this pointer.
    writer_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) StructuredLogger {
        return StructuredLogger{
            .allocator = allocator,
        };
    }

    /// WF03-GH591 / ISS-0624 — LUA-13. Initialise with a custom writer +
    /// context for test capture. The `writer` parameter is `*const Writer`
    /// (pointer to const fn), matching the field shape — pass a function
    /// address, e.g. `&BufWriter.f`. The `writer_ctx` pointer must outlive
    /// the logger; the logger does not free it.
    pub fn initWithWriter(
        allocator: std.mem.Allocator,
        writer: *const Writer,
        writer_ctx: ?*anyopaque,
    ) StructuredLogger {
        return StructuredLogger{
            .allocator = allocator,
            .writer = writer,
            .writer_ctx = writer_ctx,
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

        // Route through the injected writer. The default `defaultWriter`
        // reproduces the ISS-0172 stderr path; tests inject a capture
        // writer that appends to an in-memory buffer. Writer signature
        // returns `void` (see Writer type doc) so no error union to
        // unwrap here. `self.writer` is `*const Writer`; the call site
        // auto-derefs the pointer-to-function-pointer and invokes the
        // underlying function (same as the LUA-12 HttpClientFn pattern).
        self.writer(self.writer_ctx, message);
    }
};
