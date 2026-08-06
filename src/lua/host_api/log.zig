//! platform.log(level, message) -> nil
//!
//! Write a structured log entry. Requires 'audit:log' capability.
//!
//! Returns: nil on success
//! Errors: Capability denied, invalid level

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");

/// Register platform.log
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, placeholder implementation.

    bindings.lua_pushcclosure(L, platformLog, 0);
    bindings.lua_setfield(L, -2, "log");
}

/// Lua C function: platform.log(level, message)
fn platformLog(L: *bindings.LuaState) callconv(.c) c_int {
    // Check argument count
    const nargs = bindings.lua_gettop(L);
    if (nargs < 2) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get level argument
    if (bindings.lua_isstring(L, 1) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get message argument
    if (bindings.lua_isstring(L, 2) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    var level_len: usize = 0;
    _ = bindings.lua_tolstring(L, 1, &level_len);

    var msg_len: usize = 0;
    _ = bindings.lua_tolstring(L, 2, &msg_len);

    // For MVP: no-op, return nil
    bindings.lua_pushnil(L);
    return 1;
}
