//! platform.log(level, message[, context_table]) -> nil
//!
//! Write a structured log entry. Requires the `audit:log` capability.
//!
//! Returns: nil on success (or on absent logger, see fail-open note below)
//! Raises:  capability denial (LUA-06), invalid argument, invalid log level
//!
//! ISS-0169 tranche 1 gates this function and fixes the argument-count bug.
//! ISS-0624 / WF03-GH591 (tranche 3) implements the body: build a
//! `StructuredLogEntry` from the script args and call `StructuredLogger.log`
//! when the context has a logger installed. When `ctx.structured_logger`
//! is null the call is a silent no-op (fail-open — design §5.2).
//!
//! Argument count contract: index 3 is OPTIONAL. When present and a table, it
//! is extracted via `extractValueInto` and stored as the entry's `context`.
//! When absent or not a table, `context = null`. A bogus level raises
//! `"invalid log level: <name>"`.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");
const time_source = @import("../time_source.zig");
const structured_logger = @import("../structured_logger.zig");

const FN_NAME = "log";

/// Register platform.log.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformLog, 0);
    bindings.lua_setfield(L, -2, "log");
}

/// Lua C function: platform.log(level, message[, context_table])
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

    // WF03-GH591 / ISS-0624 — LUA-13. Look up the logger and the context.
    // As with write_variable, the capability gate already ensures a context
    // is installed; the orelse on context is defensive. structured_logger
    // is fail-open when null: the script can still complete.
    const context = host_context.contextFromState(L) orelse {
        bindings.lua_pushnil(L);
        return 1;
    };
    const logger = context.structured_logger orelse {
        // Fail-open: no logger installed, the script asked to log, we have
        // nowhere to send it. Return nil (the documented "missing logger"
        // observable). Same asymmetry as activeWatchdogFired returning
        // false on null (design §5.2).
        bindings.lua_pushnil(L);
        return 1;
    };

    // Parse the level. An invalid level raises — the script can correct it
    // before retrying. The message is allocated, pushed onto the Lua stack
    // (lua_pushlstring copies the bytes), then freed, then lua_error
    // longjmps. raiseMessage is `noreturn` so we inline the push+free+error
    // dance rather than relying on a defer that will never run.
    const level = structured_logger.LogLevel.fromString(level_str) orelse {
        const msg = std.fmt.allocPrint(
            context.allocator,
            "invalid log level: {s}",
            .{level_str},
        ) catch host_context.raiseMessage(L, "invalid log level");
        bindings.lua_pushlstring(L, msg.ptr, msg.len);
        context.allocator.free(msg);
        _ = bindings.lua_error(L);
        unreachable;
    };

    // Optional third argument: a Lua table -> ScriptValue context. Absent
    // or non-table -> context = null. We must NOT pop it from the stack —
    // the host function returns the value at the top after this returns 1,
    // so leaving the optional arg on the stack is harmless.
    var context_value: ?executor.ScriptValue = null;
    if (bindings.lua_gettop(L) >= 3 and bindings.lua_istable(L, 3) != 0) {
        var extracted: executor.ScriptValue = .{ .nil_value = {} };
        if (executor.extractValueInto(L, 3, context.allocator, &extracted)) |_| {
            context_value = extracted;
        } else |err| switch (err) {
            // OOM or type error during table extraction: degrade to
            // "no context" rather than raising — a malformed context
            // table is not a script error, and the entry's main purpose
            // (level + message + trace) is unaffected. Documented at
            // design §5.4.
            else => {},
        }
    }

    // Build the entry. Free it via `entry.deinit` after `logger.log` —
    // the entry owns the context ScriptValue's heap memory. Declared `var`
    // (not `const`) because `entry.deinit` takes `*StructuredLogEntry`,
    // which requires an addressable LHS.
    const now = time_source.TimeSource.now() catch
        host_context.raiseMessage(L, "log: failed to read platform time");
    var entry: structured_logger.StructuredLogEntry = .{
        .timestamp = now,
        .level = level,
        .message = message_str,
        .script_id = "", // design §8.4 — added in a follow-up run
        .instance_id = context.instance_id,
        .actor_id = context.actor_id,
        .trace_id = context.trace_id,
        .context = context_value,
        .allocator = context.allocator,
    };

    // The context field is `*const StructuredLogger` (CTX-1 invariant:
    // caller-installed const). `log` is declared `*StructuredLogger` even
    // though the method body never mutates `self` (verified by inspection
    // — it only reads `allocator`, `writer`, `writer_ctx`). A const-cast
    // here is the standard Zig idiom for "I know this method is logically
    // const"; design §23.5 explicitly anticipates this for a future
    // follow-up that adds `script_id` propagation.
    const mutable_logger: *structured_logger.StructuredLogger = @constCast(logger);
    mutable_logger.log(entry) catch {
        // Logger failure (allocPrint out of memory, etc.) — degrade to a
        // silent no-op rather than failing the script. The script asked
        // to log; the host says "I cannot right now"; the script continues.
        // The entry's context ScriptValue is freed here.
        entry.deinit();
        bindings.lua_pushnil(L);
        return 1;
    };
    entry.deinit();

    bindings.lua_pushnil(L);
    return 1;
}
