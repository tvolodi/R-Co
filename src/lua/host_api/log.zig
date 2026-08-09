//! platform.log(level, message, [context_table]) -> nil
//!
//! Write a structured log entry. Requires the `audit:log` capability.
//!
//! Returns: nil on success
//! Raises:  capability denial (LUA-06), invalid argument, invalid log level
//!
//! ISS-0169 tranche 1 gated this function. ISS-0624 / GH #591 (LUA-13,
//! design §3.2) implements the body: builds a real `StructuredLogEntry` and
//! calls `ctx.structured_logger.?.log(entry)`. A `null` logger is a
//! fail-open no-op (design §5.2) — a missing logger is not a script
//! failure. The optional third argument (a Lua table) becomes the entry's
//! `context` field; absent or non-table means `context = null` (design
//! §3.1's argument-count contract — this also keeps the pre-fix 2-arg form
//! working unmodified).

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");
const structured_logger = @import("../structured_logger.zig");
const time_source = @import("../time_source.zig");

const FN_NAME = "log";

/// Register platform.log.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformLog, 0);
    bindings.lua_setfield(L, -2, "log");
}

/// Lua C function: platform.log(level, message)
fn platformLog(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: gate before any argument is read.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.AUDIT_LOG);

    // Before ISS-0169, `platform.log('only-one-arg')` raised with NOTHING
    // pushed, so lua_error raised whatever happened to be on the stack top —
    // the caller's own argument. The error read back as 'only-one-arg', which
    // looks like a log line rather than a failure (diagnosis E6/E11). Both
    // arguments now produce a proper §4.2 argument-error message.
    const level_str = host_context.checkString(L, FN_NAME, 1);
    const message_str = host_context.checkString(L, FN_NAME, 2);

    const ctx = host_context.contextFromState(L) orelse {
        // No context installed: nowhere to route the log. Fail-open, same
        // as a null structured_logger (design §5.2).
        bindings.lua_pushnil(L);
        return 1;
    };

    const logger = ctx.structured_logger orelse {
        // §5.2: a missing logger is not a script failure. The script asked
        // to log, the host has nowhere to send it, the script continues.
        bindings.lua_pushnil(L);
        return 1;
    };

    const level = structured_logger.LogLevel.fromString(level_str) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "invalid log level: {s}", .{level_str}) catch "invalid log level";
        host_context.raiseMessage(L, msg);
    };

    // Optional third arg: a Lua table -> ScriptValue. Absent or non-table
    // means context = null (design §3.1's argument-count contract).
    var context_value: ?executor.ScriptValue = null;
    if (bindings.lua_gettop(L) >= 3 and bindings.lua_istable(L, 3) != 0) {
        var extracted: executor.ScriptValue = undefined;
        executor.extractValueInto(L, 3, ctx.allocator, &extracted) catch |err| switch (err) {
            error.OutOfMemory => host_context.raiseMessage(L, "log: out of memory"),
            else => host_context.raiseInvalidArgument(L, FN_NAME, 3, "a string-keyed table"),
        };
        context_value = extracted;
    }

    const timestamp = time_source.TimeSource.now() catch |err| {
        if (context_value) |*cv| cv.deinit(ctx.allocator);
        _ = err;
        host_context.raiseMessage(L, "log: could not read platform time");
    };

    var entry = structured_logger.StructuredLogEntry{
        .timestamp = timestamp,
        .level = level,
        .message = message_str,
        .script_id = "",
        .instance_id = ctx.instance_id,
        .actor_id = ctx.actor_id,
        .trace_id = ctx.trace_id,
        .context = context_value,
        .allocator = ctx.allocator,
    };

    // Fail-open on the write itself too: platform.log's Lua-visible contract
    // is "nil on success" with no documented error surface for a backend
    // write failure (design §3.2 lists only the level-raise as a failure
    // path). A logging sink outage must not abort the script.
    logger.log(entry) catch {};
    entry.deinit();

    bindings.lua_pushnil(L);
    return 1;
}
