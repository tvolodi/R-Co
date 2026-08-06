//! platform.log(level, message) -> nil
//!
//! Write a structured log entry. Requires the `audit:log` capability.
//!
//! Returns: nil on success
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function. It does NOT implement it: after the
//! gate passes the body still writes no structured entry. Real structured
//! logging is LUA-13 (tranche 3).

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

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
    _ = host_context.checkString(L, FN_NAME, 1);
    _ = host_context.checkString(L, FN_NAME, 2);

    // LUA-13 (tranche 3) implements the actual write. Gated, not implemented.
    bindings.lua_pushnil(L);
    return 1;
}
