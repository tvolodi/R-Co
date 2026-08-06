//! platform.write_variable(key, value) -> nil
//!
//! Write an instance variable. Requires the `variable:write` capability.
//!
//! Returns: nil on success
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function and fixes the key type check. It does
//! NOT implement it: after the gate passes the body still stages nothing. Real
//! variable writes are LUA-11 (tranche 3).

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

const FN_NAME = "write_variable";

/// Register platform.write_variable.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformWriteVariable, 0);
    bindings.lua_setfield(L, -2, "write_variable");
}

/// Lua C function: platform.write_variable(key, value)
fn platformWriteVariable(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: gate before any argument is read.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.VARIABLE_WRITE);

    // ISS-0169 E11: `lua_isstring` accepts NUMBERS in Lua 5.1 via implicit
    // coercion, so `platform.write_variable(123, 1)` used to succeed with a
    // numeric key. `checkString` is lua_type == LUA_TSTRING — no coercion.
    _ = host_context.checkString(L, FN_NAME, 1);

    // The value is argument 2 and may be of any type. It must still be
    // PRESENT: a one-argument call is a caller mistake, not a nil write.
    host_context.checkArgCount(L, FN_NAME, 2);

    // LUA-11 (tranche 3) implements the actual staging. Gated, not implemented.
    bindings.lua_pushnil(L);
    return 1;
}
