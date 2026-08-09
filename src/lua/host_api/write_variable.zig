//! platform.write_variable(key, value) -> nil
//!
//! Write an instance variable. Requires the `variable:write` capability.
//!
//! Returns: nil on success
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gated this function and fixed the key type check.
//! ISS-0624 / GH #591 (LUA-11, design §3.1) implements the body: the value
//! is staged into `ctx.pending_writes`, committed atomically on script
//! success or discarded on failure by `executor.executeSource`.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

const FN_NAME = "write_variable";

// ISS-0624 / GH #591 (LUA-11, design §3.1): stages into ctx.pending_writes
// (gated on non-null — a null pending_writes makes the write a no-op per
// design §5.3). The value at index 2 is extracted via executor's
// extractValueInto, which recursively walks tables and rejects non-string
// keys (design §5.4). Committed on success / discarded on failure by
// executeSource (design §4).

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
    const key = host_context.checkString(L, FN_NAME, 1);

    // The value is argument 2 and may be of any type. It must still be
    // PRESENT: a one-argument call is a caller mistake, not a nil write.
    host_context.checkArgCount(L, FN_NAME, 2);

    const ctx = host_context.contextFromState(L) orelse {
        // No context installed: nothing to stage into. Same permissive
        // no-op as a null pending_writes (design §5.3).
        bindings.lua_pushnil(L);
        return 1;
    };

    const pw = ctx.pending_writes orelse {
        // Caller did not wire the staging map. No-op (design §5.3).
        bindings.lua_pushnil(L);
        return 1;
    };

    const key_copy = ctx.allocator.dupe(u8, key) catch {
        host_context.raiseMessage(L, "write_variable: out of memory");
    };
    errdefer ctx.allocator.free(key_copy);

    var value: executor.ScriptValue = undefined;
    executor.extractValueInto(L, 2, ctx.allocator, &value) catch |err| switch (err) {
        error.OutOfMemory => {
            ctx.allocator.free(key_copy);
            host_context.raiseMessage(L, "write_variable: out of memory");
        },
        else => {
            ctx.allocator.free(key_copy);
            host_context.raiseInvalidArgument(L, FN_NAME, 2, "a Lua-representable value (string-keyed table, string, number, boolean, or nil)");
        },
    };

    // Writing the same key twice within one execution: the later call
    // wins. Free the stale staged entry (if any) before overwriting so we
    // never leak the earlier key/value.
    if (pw.fetchRemove(key_copy)) |old| {
        ctx.allocator.free(old.key);
        var old_value = old.value;
        old_value.deinit(ctx.allocator);
    }
    pw.put(key_copy, value) catch {
        var v = value;
        v.deinit(ctx.allocator);
        ctx.allocator.free(key_copy);
        host_context.raiseMessage(L, "write_variable: out of memory");
    };

    bindings.lua_pushnil(L);
    return 1;
}
