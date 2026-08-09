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

    // Value (arg 2) is optional: absent or nil both mean "drop the key".
    // In Lua 5.1 / LuaJIT, trailing nil arguments may not be pushed onto
    // the stack by the caller, so lua_gettop(L) can be 1 even for the
    // call `platform.write_variable("k", nil)`. We detect both cases via
    // lua_type: LUA_TNONE (-1) = absent, LUA_TNIL (0) = explicit nil.
    // Both stage a nil_value which the apply step interprets as "delete key".
    // A one-argument call is therefore a valid nil-write, not an error.

    // WF03-GH591 / ISS-0624 — LUA-11. Stage the value in `pending_writes`
    // (design §16.2). The capability gate already ensures a context is
    // installed (host_context.installContext is called before the platform
    // table is registered in createSandboxedState); the orelse on the
    // context itself is defensive. The `pending_writes orelse` short-circuits
    // to a no-op when the executor did not wire staging (legacy
    // executeScript path), keeping the body-of-no-config path free of panics.
    const context = host_context.contextFromState(L) orelse {
        bindings.lua_pushnil(L);
        return 1;
    };
    const pending_writes = context.pending_writes orelse {
        // No staging map — write is silently dropped (fail-open for the
        // body-of-no-config path; the capability gate is still fail-closed).
        bindings.lua_pushnil(L);
        return 1;
    };

    // Extract the Lua value at index 2. LUA_TNONE (absent) and LUA_TNIL
    // (explicit nil) both stage nil_value which drops the key on apply (TC-09).
    // extractValueInto rejects non-string table keys (errors.LuaError.TypeError)
    // and returns error.OutOfMemory on allocator failure.
    var value: executor.ScriptValue = .{ .nil_value = {} };
    const val_type = bindings.lua_type(L, 2);
    if (val_type != bindings.LUA_TNONE and val_type != bindings.LUA_TNIL) {
        if (executor.extractValueInto(L, 2, context.allocator, &value)) |_| {
            // success — fall through to put
        } else |err| switch (err) {
            error.OutOfMemory => host_context.raiseMessage(
                L,
                "write_variable: out of memory staging variable",
            ),
            else => host_context.raiseMessage(
                L,
                "write_variable: value type is not representable (integer table keys are not supported)",
            ),
        }
    }
    // If val_type is NONE or NIL, value stays as nil_value -> key is dropped on apply

    // Dupe the key — `pending_writes` owns its keys outright so the deinit
    // pass can free them. The put itself returns error.OutOfMemory on
    // allocator failure; same propagation as above.
    const key_owned = context.allocator.dupe(u8, key) catch
        host_context.raiseMessage(L, "write_variable: out of memory staging variable");

    // StringHashMap.put replaces an existing entry's value but does NOT free
    // the previous key or call value.deinit on the displaced value. So when
    // the same script key is written multiple times (e.g. three calls of
    // `platform.write_variable("k", v)` with different v's), the intermediate
    // keys+values would leak. Free the displaced entry first via fetchRemove,
    // then re-install the new one. fetchRemove uses the lookup key to find the
    // entry but does not consume it, so key_owned remains usable.
    if (pending_writes.fetchRemove(key_owned)) |prev_entry| {
        context.allocator.free(prev_entry.key);
        prev_entry.value.deinit(context.allocator);
    }

    pending_writes.put(key_owned, value) catch {
        // Allocation failure during the put — free the key we just duped
        // (the value went into the put path and was NOT added, so value.deinit
        // is the caller's responsibility here since the entry was never
        // installed). Then raise.
        value.deinit(context.allocator);
        context.allocator.free(key_owned);
        host_context.raiseMessage(L, "write_variable: out of memory staging variable");
    };

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
