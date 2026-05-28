//! platform.write_variable(key, value) -> nil
//!
//! Write an instance variable. Requires 'variable:write' capability.
//!
//! Returns: nil on success
//! Errors: Capability denied, invalid key/value

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");

/// Register platform.write_variable
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, placeholder implementation.

    bindings.lua_pushcclosure(L, platformWriteVariable, 0);
    bindings.lua_setfield(L, -2, "write_variable");
}

/// Lua C function: platform.write_variable(key, value)
fn platformWriteVariable(L: *bindings.LuaState) callconv(.C) c_int {
    // Check argument count
    const nargs = bindings.lua_gettop(L);
    if (nargs < 2) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get key argument
    if (bindings.lua_isstring(L, 1) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    var key_len: usize = 0;
    const key_ptr = bindings.lua_tolstring(L, 1, &key_len);
    const key = key_ptr[0..key_len];

    // Value is at index 2 (any type accepted for MVP)
    _ = key;

    // For MVP: no-op, return nil
    bindings.lua_pushnil(L);
    return 1;
}
