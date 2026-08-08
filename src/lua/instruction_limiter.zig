//! Instruction count + wall-clock-timeout enforcement via a combined Lua hook
//! (LUA-08, LUA-10). ISS-0169 / GH #495 tranche 2, design
//! `src/design/iss0169-lua08-09-10-limiter-wiring.md` §1-2.
//!
//! ## Registry-based storage (§1), replacing the `__limiter__` global
//!
//! The previous `installHook` stored the limiter pointer via
//! `lua_setglobal(L, "__limiter__")` — writable and readable by any sandboxed
//! script (`_G.__limiter__ = nil` defeats LUA-08 entirely; overwriting it with
//! a bogus light userdata turns the hook's `@ptrCast` into a type-confused
//! read of arbitrary memory). This reuses `host_context.zig`'s exact
//! `LUA_REGISTRYINDEX` pattern instead: `lua_pushlightuserdata` +
//! `lua_setfield(L, LUA_REGISTRYINDEX, KEY)` to install, `lua_getfield` +
//! `lua_type` guard + `lua_touserdata` + `lua_pop` to read back. The registry
//! is not reachable from script code (`debug` and `package` are never opened,
//! and Lua source syntax has no way to name a pseudo-index) — invariant INV-2.
//!
//! ## One combined hook (§2)
//!
//! `lua_sethook` accepts exactly one callback per `lua_State` — LUA-08's
//! instruction count and LUA-10's in-VM elapsed-time check share the single
//! `LUA_MASKCOUNT` callback below (invariant INV-4). Folding the elapsed-time
//! check into the per-N-instruction callback is the only mechanism in this
//! codebase that can interrupt a tight `while true do end` loop, because that
//! loop contains no host call and no allocation for anything else to observe.

const std = @import("std");
const bindings = @import("luajit_bindings.zig");
const timeout_ctx = @import("timeout.zig");

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

/// Combined limiter context installed into the registry (design §1.2).
/// `timeout` is null when no wall-clock check should run inside the hook
/// (used by TC-LUA-10-03/§5.5 to isolate the host-external watchdog).
pub const RunLimiter = struct {
    instruction: InstructionLimiter,
    timeout: ?timeout_ctx.TimeoutContext,
};

/// Private registry key. Not reachable from script code — same channel
/// `host_context.zig` uses for `ExecutionContext` (`"bpm.execution_context"`).
pub const REGISTRY_KEY: [*:0]const u8 = "bpm.run_limiter";

/// Hook fires every N instructions (unchanged interval — see design §2.4 for
/// the worst-case-overrun justification against `MIN_TIMEOUT_SECONDS`).
pub const HOOK_INSTRUCTION_INTERVAL: c_int = 100;

/// Install the combined limiter into `LUA_REGISTRYINDEX` and register the
/// single `LUA_MASKCOUNT` hook. Caller owns `limiter` (stack-allocated in
/// `executeSource`) and must keep it alive for the lifetime of `L` (INV-1).
pub fn installLimiter(L: *bindings.LuaState, limiter: *RunLimiter) void {
    bindings.lua_pushlightuserdata(L, limiter);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);
    _ = bindings.lua_sethook(L, hookCallback, bindings.LUA_MASKCOUNT, HOOK_INSTRUCTION_INTERVAL);
}

/// Read the limiter back from inside the hook callback. `null` on any
/// doubt (absent key or wrong Lua type) — defensive-only, see design §2.2:
/// this is a programmer-error guard, not a security gate, because
/// `installLimiter` sets the registry key and registers the hook in the same
/// call, so by the time LuaJIT can invoke `hookCallback` the key already
/// exists.
fn limiterFromState(L: *bindings.LuaState) ?*RunLimiter {
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);
    defer bindings.lua_pop(L, 1);
    if (bindings.lua_type(L, -1) != bindings.LUA_TLIGHTUSERDATA) return null;
    const raw = bindings.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Combined hook callback (design §2.2): checks the instruction count, then
/// (if a timeout context is installed) the elapsed wall-clock time. Whichever
/// trip condition is reached first raises and unwinds via `lua_error`'s
/// longjmp, so the other check in the same tick is never reached once one has
/// raised (INV-7).
fn hookCallback(L: *bindings.LuaState, ar: ?*bindings.lua_Debug) callconv(.c) void {
    _ = ar;
    const limiter = limiterFromState(L) orelse return;

    limiter.instruction.instructions_executed += HOOK_INSTRUCTION_INTERVAL;
    if (limiter.instruction.instructions_executed >= limiter.instruction.max_instructions) {
        raiseLimit(L, "instruction limit exceeded");
    }

    if (limiter.timeout) |*t| {
        t.checkTimeout() catch {
            raiseLimit(L, "wall-clock timeout exceeded");
        };
    }
}

/// Push a message and raise. Never returns — `lua_error` longjmps (same
/// pattern as `host_context.raiseMessage`).
fn raiseLimit(L: *bindings.LuaState, message: [:0]const u8) noreturn {
    bindings.lua_pushstring(L, message.ptr);
    _ = bindings.lua_error(L);
    unreachable;
}

/// Get the current instruction count from a limiter.
pub fn getInstructionCount(limiter: *const InstructionLimiter) u64 {
    return limiter.instructions_executed;
}

/// Check if instruction limit was exceeded.
pub fn wasLimitExceeded(limiter: *const InstructionLimiter) bool {
    return limiter.instructions_executed >= limiter.max_instructions;
}
