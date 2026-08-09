//! platform.read_variable(key) -> any
//!
//! Read an instance variable by key. Requires the `variable:read` capability.
//!
//! Returns: Lua value (nil, boolean, number, string, or table)
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function. ISS-0624 / WF03-GH591 wired the
//! body: read-after-write within a single execution (look in
//! `context.pending_writes` first), then fall through to the committed
//! `instance_state.variables`. A missing key at both layers returns nil.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

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

/// Push a `ScriptValue` onto the Lua stack. Mirrors `extractValueInto`'s
/// table branch but is the inverse direction (ScriptValue -> Lua stack
/// push). Strings are pushed via `lua_pushlstring` (explicit length).
/// Tables are walked recursively; nil/bool/number are pushed directly.
///
/// Returns `error.OutOfMemory` on allocation failure. Tables: `{key=value,...}`.
fn pushScriptValue(
    L: *bindings.LuaState,
    value: executor.ScriptValue,
) std.mem.Allocator.Error!void {
    switch (value) {
        .nil_value => bindings.lua_pushnil(L),
        .boolean => |b| bindings.lua_pushboolean(L, if (b) 1 else 0),
        .number => |n| bindings.lua_pushnumber(L, n),
        .string => |s| bindings.lua_pushlstring(L, s.ptr, s.len),
        .table => |t| {
            bindings.lua_newtable(L);
            var it = t.iterator();
            while (it.next()) |entry| {
                // key
                bindings.lua_pushlstring(L, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
                // value
                try pushScriptValue(L, entry.value_ptr.*);
                bindings.lua_settable(L, -3);
            }
        },
    }
}

/// Lua C function: platform.read_variable(key)
fn platformReadVariable(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: the capability check precedes every argument read and every state
    // touch. A denied call must be indistinguishable from a call that never
    // happened, other than by the error it raises.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.VARIABLE_READ);

    // A real string, not lua_isstring's number coercion (E11).
    const key = host_context.checkString(L, FN_NAME, 1);

    // WF03-GH591 / ISS-0624 — LUA-11. Read-after-write within an execution:
    // look first in `pending_writes`, then fall through to the committed
    // `instance_state.variables`. A null context (defensive — the
    // capability gate already ensures one is installed) means "not
    // configured"; a null `pending_writes` means "no staging this run"
    // (skip directly to instance_state).
    const context = host_context.contextFromState(L) orelse {
        bindings.lua_pushnil(L);
        return 1;
    };

    if (context.pending_writes) |pw| {
        if (pw.get(key)) |value| {
            // Zig 0.16 StringHashMap.get returns the value directly, not an
            // entry struct; see `pw.getPtr` for the entry-shaped alternative.
            pushScriptValue(L, value) catch {
                // OOM during push: treat as "not found" rather than
                // raising — a script that triggered an allocation failure
                // during a log call is no better off when reading; the
                // script can check the type of the result. Pushing nil
                // preserves the "no information leak" property (a missing
                // key and an allocation failure both look like nil).
                bindings.lua_pushnil(L);
                return 1;
            };
            return 1;
        }
    }

    if (context.instance_state.variables.get(key)) |value| {
        pushScriptValue(L, value) catch {
            bindings.lua_pushnil(L);
            return 1;
        };
        return 1;
    }

    bindings.lua_pushnil(L);
    return 1;
}
