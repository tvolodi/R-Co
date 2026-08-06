//! platform.fail(reason, [details]) -> none
//!
//! Terminate script execution with a structured failure.
//! No capability required, but triggers SCRIPT_FAILED event emission.
//! Does not return; raises a Lua error to terminate execution.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");

/// Register platform.fail
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;

    bindings.lua_pushcclosure(L, platformFail, 0);
    bindings.lua_setfield(L, -2, "fail");
}

/// Lua C function: platform.fail(reason, [details])
fn platformFail(L: *bindings.LuaState) callconv(.c) c_int {
    const nargs = bindings.lua_gettop(L);

    if (nargs < 1) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get reason (must be string)
    if (bindings.lua_isstring(L, 1) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    var reason_len: usize = 0;
    const reason_ptr = bindings.lua_tolstring(L, 1, &reason_len);
    const reason = reason_ptr[0..reason_len];

    // Store failure reason in global for error handling
    bindings.lua_pushstring(L, @ptrCast(reason.ptr));
    bindings.lua_setglobal(L, "__failure_reason__");

    // Optional: Store details at index 2
    // ISS-0153: `&&` is not a Zig operator (C habit); Zig spells logical AND
    // as `and`. Never compiled — this file was analysed by no build target.
    if (nargs >= 2 and bindings.lua_istable(L, 2) != 0) {
        bindings.lua_pushvalue(L, 2);
        bindings.lua_setglobal(L, "__failure_details__");
    }

    // Mark as explicit failure
    bindings.lua_pushboolean(L, 1);
    bindings.lua_setglobal(L, "__explicit_failure__");

    // Raise a Lua error to terminate execution
    _ = bindings.lua_error(L);
    return 0;
}
