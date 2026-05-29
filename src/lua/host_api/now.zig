//! platform.now() -> string
//!
//! Return the platform authoritative time as ISO 8601 UTC string.
//! No capability required.
//! Format: YYYY-MM-DDTHH:MM:SS.sssZ

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const time_source = @import("../time_source.zig");
const simulation_runtime = @import("../../simulation/runtime.zig");

/// Register platform.now
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    // Store context as Lua state user data for access in the C function
    _ = context;

    bindings.lua_pushcclosure(L, platformNow, 0);
    bindings.lua_setfield(L, -2, "now");
}

/// Lua C function: platform.now()
fn platformNow(L: *bindings.LuaState) callconv(.C) c_int {
    const now = blk: {
        if (simulation_runtime.get()) |ctx| {
            break :blk time_source.DateTime.fromNanoseconds(ctx.clock.nowMs() * 1_000_000);
        }
        break :blk time_source.TimeSource.now() catch {
            _ = bindings.lua_error(L);
            return 0;
        };
    };

    // Format as ISO 8601
    var buffer: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(
        &buffer,
        "{:04d}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}.{:03d}Z",
        .{
            now.year, now.month, now.day,
            now.hour, now.minute, now.second,
            now.millisecond,
        },
    ) catch {
        _ = bindings.lua_error(L);
        return 0;
    };

    bindings.lua_pushlstring(L, @ptrCast(formatted.ptr), formatted.len);
    return 1;
}
