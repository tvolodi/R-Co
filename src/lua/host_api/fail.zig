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
//! ## LUA-15 (iss0625-gh592-lua-12-15-16.md): bytes go through the REGISTRY,
//! not `_G`.
//!
//! The pre-ISS-0625 implementation wrote `__failure_reason__`,
//! `__failure_details__` and `__explicit_failure__` as ordinary globals.
//! Any script could forge or nil them — the same defect class that made `_G`
//! unusable as the execution-context channel. These globals are no longer
//! read by anything (the executor reads `bpm.failure_*` from the registry
//! via `host_context.readExplicitFailure`), so the writes themselves are
//! deleted, not migrated. The `host_context` helper `setExplicitFailure` is
//! the single sanctioned entry point.

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

    // Optional details: a real Lua table at index 2, else no details.
    const details_kind: host_context.DetailsKind = blk: {
        if (bindings.lua_gettop(L) >= 2 and bindings.lua_istable(L, 2) != 0) {
            break :blk host_context.DetailsKind.Table;
        }
        break :blk host_context.DetailsKind.None;
    };

    // LUA-15: write the discriminator to the REGISTRYINDEX channel, not to
    // `_G`. The script cannot name the registry key (no `debug`, no
    // `package`), so a forged reason/details/explicit-failure is structurally
    // impossible. The executor reads it back via
    // `host_context.readExplicitFailure` after the failed pcall.
    const ctx = host_context.contextFromState(L) orelse
        host_context.raiseMessage(L, "platform.fail: no execution context installed");
    host_context.setExplicitFailure(L, ctx.allocator, reason, details_kind);

    // ERR-1: raise with the reason as the error value, not with whatever
    // happened to be on the stack top.
    host_context.raiseMessage(L, reason);
}
