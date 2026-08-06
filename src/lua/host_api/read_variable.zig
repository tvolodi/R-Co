//! platform.read_variable(key) -> any
//!
//! Read an instance variable by key. Requires the `variable:read` capability.
//!
//! Returns: Lua value (nil, boolean, number, string, or table)
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function. It does NOT implement it: after the
//! gate passes the body still returns nil. Real variable reads are LUA-11
//! (tranche 3). The claim this file makes is exactly "a script without
//! `variable:read` cannot reach the body" — nothing more.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");
const errors = @import("../errors.zig");

const FN_NAME = "read_variable";

/// Register platform.read_variable.
///
/// The context reaches the closure through LUA_REGISTRYINDEX (installed by
/// executor.createSandboxedState), not through an upvalue — hence
/// `lua_pushcclosure(..., 0)` is correct here and is NOT the old
/// zero-upvalue-with-no-channel defect.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformReadVariable, 0);
    bindings.lua_setfield(L, -2, "read_variable");
}

/// Lua C function: platform.read_variable(key)
fn platformReadVariable(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: the capability check precedes every argument read and every state
    // touch. A denied call must be indistinguishable from a call that never
    // happened, other than by the error it raises.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.VARIABLE_READ);

    // A real string, not lua_isstring's number coercion (E11).
    _ = host_context.checkString(L, FN_NAME, 1);

    // LUA-11 (tranche 3) implements the actual read. Gated, not implemented.
    bindings.lua_pushnil(L);
    return 1;
}
