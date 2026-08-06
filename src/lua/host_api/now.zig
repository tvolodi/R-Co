//! platform.now() -> string
//!
//! Return the platform authoritative time as an ISO 8601 UTC string.
//! Format: YYYY-MM-DDTHH:MM:SS.sssZ
//!
//! ## UNGATED BY DESIGN — no capability required
//!
//! This is a positive design statement, not an omission (design §3.2):
//! `platform.now()` is a pure time read with no reach into instance state, no
//! side effect and no external call, so there is nothing for a capability to
//! protect. LUA-14. A test that expects a gate here is reading the capability
//! matrix in `host_api/mod.zig` wrong.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const host_context = @import("../host_context.zig");
const time_source = @import("../time_source.zig");
const simulation_runtime = @import("../../simulation/runtime.zig");

const FN_NAME = "now";

/// Register platform.now
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformNow, 0);
    bindings.lua_setfield(L, -2, "now");
}

/// Lua C function: platform.now()
fn platformNow(L: *bindings.LuaState) callconv(.c) c_int {
    const now = blk: {
        if (simulation_runtime.get()) |ctx| {
            break :blk time_source.DateTime.fromNanoseconds(ctx.clock.nowMs() * 1_000_000);
        }
        // ERR-1: push a message before raising. A bare lua_error(L) raises
        // whatever is on the stack top — uninitialised memory here.
        break :blk time_source.TimeSource.now() catch
            host_context.raiseMessage(L, "platform.now: the platform time source is unavailable");
    };

    // Format as ISO 8601
    var buffer: [32]u8 = undefined;
    // ISS-0153: `{:04d}` is pre-0.16 format syntax and no longer parses
    // (`expected . or }, found 'd'`). Zig 0.16 spells zero-padding as
    // `{d:0>4}` — specifier first, then fill/alignment/width.
    const formatted = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            now.year, now.month, now.day,
            now.hour, now.minute, now.second,
            now.millisecond,
        },
    ) catch
        host_context.raiseMessage(L, "platform.now: could not format the current time");

    bindings.lua_pushlstring(L, @ptrCast(formatted.ptr), formatted.len);
    return 1;
}
