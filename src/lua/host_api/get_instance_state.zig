//! platform.get_instance_state() -> table
//!
//! Read the full instance state (read-only). Requires the `instance:read`
//! capability.
//!
//! Returns: Lua table with instance state
//! Raises:  capability denial (LUA-06)
//!
//! ISS-0169 tranche 1 gates this function. It does NOT implement it: after the
//! gate passes the body still returns an empty table. Real instance state is
//! LUA-11 (tranche 3).

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

const FN_NAME = "get_instance_state";

/// Register platform.get_instance_state.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformGetInstanceState, 0);
    bindings.lua_setfield(L, -2, "get_instance_state");
}

/// Lua C function: platform.get_instance_state()
fn platformGetInstanceState(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: gate before anything. This function takes no arguments, so the
    // gate is the entire prologue.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.INSTANCE_READ);

    // LUA-11 (tranche 3) populates this. Gated, not implemented.
    bindings.lua_newtable(L);
    return 1;
}
