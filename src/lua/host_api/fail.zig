//! platform.fail(reason, [details]) -> none
//!
//! Terminate script execution with a structured failure. Does not return; it
//! raises a Lua error carrying the reason.
//!
//! ## UNGATED BY DESIGN — no capability required
//!
//! A positive design statement, not an omission (design §3.2): a script may
//! always terminate itself, and denying that would only force it to `error()`
//! instead. LUA-15.
//!
//! ## Known follow-up, deliberately NOT fixed here (design §11.3)
//!
//! `__failure_reason__`, `__failure_details__` and `__explicit_failure__` are
//! ordinary GLOBALS, so a script can forge or nil them — the same defect class
//! that made `_G` unusable as the execution-context channel. They are also
//! never read back by anything. Moving them into `LUA_REGISTRYINDEX` following
//! the `host_context.zig` pattern belongs to tranche 4 (LUA-15); ISS-0169
//! tranche 1 fixes only the read-past-end bug below.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const host_context = @import("../host_context.zig");

const FN_NAME = "fail";

/// Register platform.fail
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformFail, 0);
    bindings.lua_setfield(L, -2, "fail");
}

/// Lua C function: platform.fail(reason, [details])
fn platformFail(L: *bindings.LuaState) callconv(.c) c_int {
    // Ungated by design — no requireCapability call here.
    const reason = host_context.checkString(L, FN_NAME, 1);

    // ISS-0169 §4.4: `lua_pushstring` takes [*:0]const u8, so
    // `@ptrCast(reason.ptr)` on a Zig slice with no NUL terminator read past
    // the end of Lua's string buffer. `lua_pushlstring` carries the length.
    bindings.lua_pushlstring(L, reason.ptr, reason.len);
    bindings.lua_setglobal(L, "__failure_reason__");

    // Optional details at index 2.
    // ISS-0153: `&&` is not a Zig operator (C habit); Zig spells logical AND
    // as `and`. Never compiled — this file was analysed by no build target.
    if (bindings.lua_gettop(L) >= 2 and bindings.lua_istable(L, 2) != 0) {
        bindings.lua_pushvalue(L, 2);
        bindings.lua_setglobal(L, "__failure_details__");
    }

    bindings.lua_pushboolean(L, 1);
    bindings.lua_setglobal(L, "__explicit_failure__");

    // ERR-1: raise with the reason as the error value, not with whatever
    // happened to be on the stack top.
    host_context.raiseMessage(L, reason);
}
