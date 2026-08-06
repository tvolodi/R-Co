//! ISS-0153 / GH #471 — test root for the `src/lua/` scripting subsystem.
//!
//! ## Why this file exists
//!
//! `src/lua/` (14 files, implementing LUA-01..16 — all MUST, all marked
//! RELEASED) was reachable from no `b.addTest(...)` root, re-exported by
//! neither `src/bpm.zig` nor `src/main.zig`, and imported by nothing. No build
//! path ever asked Zig to analyse it. It carried zero `test` blocks, so
//! `tools/lint_test_wiring.py` (which only tracks test-BEARING files) could not
//! see it either — the same blind spot that hid `src/wasm/` until ISS-0147.
//!
//! Consequence: the subsystem stopped compiling somewhere around Zig 0.11 and
//! nobody found out for three months. When finally analysed it produced errors
//! in seven distinct categories (see §Rot below), none of which any gate had
//! ever reported.
//!
//! ## Placement is load-bearing (Single-Owner Module Rule, design §1.2)
//!
//! This shim sits at `src/`, NOT at `src/lua/`. `src/lua/host_api/call_service.zig`
//! and `host_api/now.zig` import `../../simulation/*.zig`, escaping `src/lua/`;
//! `src/simulation/types.zig` in turn imports `../event_store/store.zig`. A
//! module rooted at `src/lua/mod.zig` rejects those with "import of file
//! outside module path" — verified empirically, not assumed. Rooting at `src/`
//! contains the entire import chain, exactly as
//! `src/simulation_test_root.zig` and `src/transition_test_root.zig` do for the
//! same reason.
//!
//! Correspondingly, `src/lua/mod.zig` is deliberately NOT a named-module root
//! anywhere in `build.zig`, so reaching it by relative path here is the correct
//! form (relative reach is permitted only for files that are no module's root).
//! This is why `src/bpm.zig` does NOT re-export lua the way it re-exports
//! `wasm` — see the note in bpm.zig.
//!
//! ## What is actually verified here
//!
//! `refAllDecls` alone is not enough to trust: it is shallow over containers.
//! But because every host_api function is referenced from a `register()` decl
//! that `refAllDecls` does reach, analysis does descend into function bodies —
//! confirmed by a deliberate mutation (a type error injected into the body of
//! `get_instance_state.platformGetInstanceState`) turning this target red. The
//! explicit decl references below pin one concrete symbol per file so a break
//! anywhere under `src/lua/` fails `zig build test`.
//!
//! ## Rot this wiring caught (all previously invisible)
//!
//! 1. `c_void` (removed in Zig 0.11) — 5 sites.
//! 2. `callconv(.C)` (tagged union, now `.c` in 0.16) — 12 sites.
//! 3. Two-argument `@ptrCast` (single-arg since 0.11) — 4 sites.
//! 4. `&&` used as logical AND (never valid Zig) — host_api/fail.zig.
//! 5. `std.time.nanoTimestamp()` (removed in 0.16) — time_source, timeout.
//! 6. `{:04d}` format syntax (now `{d:0>4}`) — time_source, host_api/now.
//! 7. Three decls CALLED but never declared: `lua_istable`, `lua_sethook`,
//!    `lua_Debug`. Plus `@divExact` on elapsed nanoseconds in timeout.zig,
//!    which would panic for any non-whole-millisecond duration.
//!
//! ## What does NOT execute
//!
//! No Lua script runs. LuaJIT is not available in this repository (no vendored
//! copy, no build.zig.zon dependency, no `lua.h` on disk, no system library —
//! see `src/lua/luajit_bindings.zig` for the empirical evidence), so the C
//! bindings are pure-Zig stubs returning failure sentinels. This target proves
//! the subsystem COMPILES and is type-checked; it does not prove Lua works,
//! and LUA-01..16 were downgraded from RELEASED accordingly. Real execution is
//! tracked by ISS-0161 / GH #485.
//!
//! Run via `zig build test-lua` (also reached by `zig build test`).

const std = @import("std");

pub const lua = @import("lua/mod.zig");

// ISS-0161 / GH #485 — LUA-01..05 execution tests against the real, statically
// linked LuaJIT. Pulled in explicitly: it lives under src/lua/ (module-boundary
// reason above) and is not reachable via refAllDecls from mod.zig.
pub const execution_test = @import("lua/execution_test.zig");

test {
    std.testing.refAllDecls(lua);
    std.testing.refAllDecls(execution_test);
}

test "ISS-0153: every file in the src/lua subsystem is analysed" {
    // One concrete decl per file, so a compile break anywhere under src/lua/
    // fails this target rather than going unnoticed as it did for 3 months.
    _ = lua.executor.ExecutionContext; // executor.zig      — LUA-02, LUA-04
    _ = lua.capabilities.CapabilitySet; // capabilities.zig  — LUA-06
    _ = lua.errors.LuaError; // errors.zig        — LUA-16
    _ = lua.stdlib.loadSafeStdlib; // stdlib.zig        — LUA-03
    _ = lua.luajit_bindings.lua_State; // luajit_bindings   — LUA-01
    _ = lua.manifest.validateManifest; // manifest.zig      — LUA-07
    _ = lua.instruction_limiter.InstructionLimiter; // LUA-08
    _ = lua.memory_limiter.MemoryLimiter; // memory_limiter    — LUA-09
    _ = lua.timeout.TimeoutContext; // timeout.zig       — LUA-10
    _ = lua.time_source.TimeSource; // time_source.zig   — LUA-14
    _ = lua.structured_logger.StructuredLogger; // structured_logger — LUA-13
    _ = lua.service_catalog.ServiceCatalog; // service_catalog   — LUA-12
    _ = lua.events.Event; // events.zig        — LUA-15, LUA-16

    // All eight host_api/*.zig files (LUA-05, LUA-11, LUA-12, LUA-13, LUA-15).
    const host_api = lua.host_api;
    try std.testing.expect(@hasDecl(host_api, "registerAll"));
    _ = host_api.call_service.register;
    _ = host_api.read_variable.register;
    _ = host_api.write_variable.register;
    _ = host_api.log_func.register;
    _ = host_api.emit_event.register;
    _ = host_api.get_instance_state.register;
    _ = host_api.now_func.register;
    _ = host_api.fail_func.register;
}

test "ISS-0161: LuaJIT is linked and the bindings say so honestly" {
    const bindings = lua.luajit_bindings;

    // ISS-0161 / GH #485 inverted this assertion. Under ISS-0153 it read
    // `expect(!has_real_luajit)` and asserted that lua_newstate returned null
    // and that load/pcall reported failure -- the honest description of a
    // stubbed subsystem. LuaJIT is now vendored and statically linked, so the
    // guarantee to protect is the opposite one: a real state is created and a
    // real script runs.
    try std.testing.expect(bindings.has_real_luajit);

    const L = bindings.lua_newstate(realAlloc, null) orelse
        return error.LuaStateAllocFailed;
    defer bindings.lua_close(L);
    _ = bindings.luaopen_base(L);

    try std.testing.expectEqual(
        bindings.LUA_OK,
        bindings.luaL_loadstring(L, "return 42"),
    );
    try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 42), bindings.lua_tonumber(L, -1));
}

/// C-ABI allocator matching `lua_Alloc`. Replaces ISS-0153's `stubAlloc`, which
/// always returned null because no allocation could ever succeed.
fn realAlloc(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

test "ISS-0161: executeScript actually executes a script and returns its value" {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();

    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0161-instance",
        .actor_id = "iss0161-actor",
    };

    var result = try lua.executeScript(&ctx, "return 42");
    defer result.deinit(std.testing.allocator);

    // Under ISS-0153 this asserted !result.success, because state creation
    // could not succeed. The whole point of ISS-0161 is that it now does.
    try std.testing.expect(result.success);
    try std.testing.expect(result.error_message == null);
}

test "ISS-0153: bytecode is rejected before any runtime is needed (LUA-04)" {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();

    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0153-instance",
        .actor_id = "iss0153-actor",
    };

    // Lua bytecode magic: 0x1b 'L' 'u' 'a'. This path is pure Zig and does not
    // depend on LuaJIT, so it is genuinely enforced today.
    var result = try lua.executeScript(&ctx, "\x1b\x4c\x75\x61rest");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.error_message.?,
        "Bytecode is not allowed",
    ) != null);
}

test "ISS-0153: timeout elapsed-ms no longer uses @divExact (would panic)" {
    // The original code computed @divExact(elapsed_ns, 1_000_000), which panics
    // for any elapsed time that is not a whole number of milliseconds.
    var ctx = lua.timeout.TimeoutContext.init(3600);
    // Simply calling this would have crashed the test binary before the fix.
    _ = ctx.getElapsedMs();
    try ctx.checkTimeout();
    try std.testing.expectEqual(@as(u64, 3_600_000), ctx.getTimeoutMs());
}
