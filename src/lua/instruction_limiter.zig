//! Instruction count enforcement via Lua hooks (LUA-08).
//!
//! Tracks Lua instruction execution and raises an error when the limit is exceeded.
//! Uses a Lua hook callback invoked periodically to count instructions.

const std = @import("std");
const bindings = @import("luajit_bindings.zig");

pub const InstructionLimiter = struct {
    max_instructions: u64,
    instructions_executed: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_instructions: u64) InstructionLimiter {
        return InstructionLimiter{
            .max_instructions = max_instructions,
            .instructions_executed = 0,
            .allocator = allocator,
        };
    }
};

pub const InstructionLimitError = struct {
    instruction_limit: u64,
    instructions_executed: u64,
};

/// Install instruction limit on a Lua state.
/// The hook will be called periodically (every N instructions).
pub fn installHook(L: *bindings.LuaState, limiter: *InstructionLimiter) !void {
    // Store limiter as Lua state user data (light userdata)
    // Note: This is a simplified implementation; in production, use proper userdata
    bindings.lua_pushlightuserdata(L, limiter);
    bindings.lua_setglobal(L, "__limiter__");

    // Register hook callback invoked every ~100 instructions
    // LUA_MASKCOUNT = 0x08 (from lua.h)
    const LUA_MASKCOUNT = 0x08;
    bindings.lua_sethook(L, hookCallback, LUA_MASKCOUNT, 100);
}

/// Hook callback invoked periodically during script execution.
/// Checks if instruction limit is exceeded; raises error if so.
fn hookCallback(L: *bindings.LuaState, ar: ?*bindings.lua_Debug) callconv(.C) void {
    _ = ar; // Unused in basic implementation

    // Retrieve limiter from global state
    bindings.lua_getglobal(L, "__limiter__");
    const ud = bindings.lua_touserdata(L, -1);
    bindings.lua_pop(L, 1);

    if (ud == null) return;

    const limiter = @ptrCast(*InstructionLimiter, ud);
    limiter.instructions_executed += 100; // Approximate (hook interval)

    if (limiter.instructions_executed >= limiter.max_instructions) {
        // Raise a Lua error; execution terminates
        _ = bindings.lua_error(L);
    }
}

/// Get the current instruction count from a limiter.
pub fn getInstructionCount(limiter: *const InstructionLimiter) u64 {
    return limiter.instructions_executed;
}

/// Check if instruction limit was exceeded.
pub fn wasLimitExceeded(limiter: *const InstructionLimiter) bool {
    return limiter.instructions_executed >= limiter.max_instructions;
}
