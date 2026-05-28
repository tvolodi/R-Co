//! platform.get_instance_state() -> table
//!
//! Read the full instance state (read-only). Requires 'instance:read' capability.
//!
//! Returns: Lua table with instance state
//! Errors: Capability denied, instance not found

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");

/// Register platform.get_instance_state
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, placeholder implementation.

    bindings.lua_pushcclosure(L, platformGetInstanceState, 0);
    bindings.lua_setfield(L, -2, "get_instance_state");
}

/// Lua C function: platform.get_instance_state()
fn platformGetInstanceState(L: *bindings.LuaState) callconv(.C) c_int {
    // No arguments expected
    // For MVP: return an empty table
    bindings.lua_newtable(L);
    return 1;
}
