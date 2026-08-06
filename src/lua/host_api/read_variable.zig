//! platform.read_variable(key) -> any
//!
//! Read an instance variable by key. Requires 'variable:read' capability.
//!
//! Returns: Lua value (nil, boolean, number, string, or table)
//! Errors: Capability denied, variable not found

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const errors = @import("../errors.zig");

/// Register platform.read_variable
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, this is a placeholder. In Phase 2, we'll fetch from the database.
    // For now, just create a function that returns nil.

    bindings.lua_pushcclosure(L, platformReadVariable, 0);
    bindings.lua_setfield(L, -2, "read_variable");
}

/// Lua C function: platform.read_variable(key)
fn platformReadVariable(L: *bindings.LuaState) callconv(.c) c_int {
    // Check argument count
    const nargs = bindings.lua_gettop(L);
    if (nargs < 1) {
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

    // Check capability (placeholder)
    _ = key;

    // For MVP: return nil (no-op implementation)
    bindings.lua_pushnil(L);
    return 1;
}
