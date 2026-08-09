//! platform.read_variable(key) -> any
//!
//! Read an instance variable by key. Requires the `variable:read` capability.
//!
//! Returns: Lua value (nil, boolean, number, string, or table)
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gated this function. ISS-0624 / GH #591 (LUA-11,
//! design §3.1) implements the body: read-after-write against
//! `ctx.pending_writes` first, then fall through to the committed
//! `ctx.instance_state.variables`, then nil on a total miss.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");
const errors = @import("../errors.zig");

const FN_NAME = "read_variable";

// ISS-0624 / GH #591 (LUA-11, design §3.1): read-after-write against
// ctx.pending_writes first, then fall through to ctx.instance_state.variables,
// then nil on a total miss. Both a null pending_writes and a plain miss are
// permissive no-ops (design §5.3) — the capability gate is the only
// fail-closed control in this function.

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
    const key = host_context.checkString(L, FN_NAME, 1);

    const ctx = host_context.contextFromState(L) orelse {
        // Fail-closed for capability (already checked above); the state
        // read below is defensive-by-construction (design §5.3) — no
        // context means no state reach, not an error.
        bindings.lua_pushnil(L);
        return 1;
    };

    // Read-after-write: a pending (uncommitted) write in THIS execution
    // wins over the committed state.
    if (ctx.pending_writes) |pw| {
        if (pw.getPtr(key)) |entry| {
            pushScriptValue(L, entry.*);
            return 1;
        }
    }

    // Fall through to committed state.
    if (ctx.instance_state.variables.getPtr(key)) |value| {
        pushScriptValue(L, value.*);
        return 1;
    }

    // Total miss.
    bindings.lua_pushnil(L);
    return 1;
}

/// Push a `ScriptValue` onto the Lua stack. Mirrors the shapes
/// `extractValue`/`extractValueInto` can produce.
fn pushScriptValue(L: *bindings.LuaState, value: executor.ScriptValue) void {
    switch (value) {
        .nil_value => bindings.lua_pushnil(L),
        .boolean => |b| bindings.lua_pushboolean(L, if (b) 1 else 0),
        .number => |n| bindings.lua_pushnumber(L, n),
        .string => |s| bindings.lua_pushlstring(L, s.ptr, s.len),
        .table => |t| {
            bindings.lua_newtable(L);
            var mutable_t = t;
            var it = mutable_t.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                bindings.lua_pushlstring(L, key.ptr, key.len);
                pushScriptValue(L, entry.value_ptr.*);
                bindings.lua_settable(L, -3);
            }
        },
    }
}
