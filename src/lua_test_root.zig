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

// ISS-0169 / GH #495 tranche 1 — LUA-05/06/07 capability-enforcement tests.
// Same module-boundary reason as execution_test above: it lives under src/lua/
// and is not reachable via refAllDecls from mod.zig, so it is imported here
// explicitly. Its `test` blocks CALL the gate, the registry channel and the
// load-time manifest entry point against the real linked LuaJIT — deliberately
// not a type pin, per the ISS-0172 caveat documented below.
pub const capability_enforcement_test = @import("lua/capability_enforcement_test.zig");

test {
    std.testing.refAllDecls(lua);
    std.testing.refAllDecls(execution_test);
    std.testing.refAllDecls(capability_enforcement_test);
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
    _ = lua.host_context.requireCapability; // host_context.zig  — LUA-05, LUA-06

    // ISS-0172 / GH #500 — a bare TYPE reference does NOT prove a file
    // compiles. Zig resolves struct field types lazily, and `_ = someFn;` takes
    // an address without analysing the body. Both limiters carried hard compile
    // errors (`std.Thread.Mutex` removed in 0.16; a discarded c_int from
    // lua_sethook) THROUGH a green `zig build test-lua` for exactly that
    // reason. The two pins below therefore force real analysis:
    //   - @sizeOf resolves every field type, catching the Mutex class of error.
    //   - a call inside a comptime-false-guarded but reachable branch would
    //     still be elided, so installHook is called for real below instead.
    _ = @sizeOf(lua.instruction_limiter.InstructionLimiter); // LUA-08
    _ = @sizeOf(lua.memory_limiter.MemoryLimiter); // memory_limiter    — LUA-09
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

test "ISS-0169: the limiter FUNCTION BODIES are analysed, not just their types" {
    // ISS-0172 / GH #500: `zig build test-lua` was green while BOTH limiters
    // carried hard compile errors, because src/lua_test_root.zig pinned them
    // with `_ = Module.TypeName;` — which forces neither field-type resolution
    // nor function-body analysis. This test calls them for real, so a break
    // cannot hide behind a green target again.
    //
    // NOTE: this proves the limiters COMPILE. It proves nothing about
    // enforcement, and ISS-0169 tranche 1 installs neither of them:
    // executeScript still creates its state with an unbounded allocator and no
    // instruction hook. LUA-08/LUA-09/LUA-10 enforcement is tranche 2.
    const bindings = lua.luajit_bindings;

    const L = bindings.lua_newstate(realAlloc, null) orelse
        return error.LuaStateAllocFailed;
    defer bindings.lua_close(L);

    var limiter = lua.instruction_limiter.InstructionLimiter.init(
        std.testing.allocator,
        1_000,
    );
    // Calls the body containing the previously-invalid lua_sethook call site.
    try lua.instruction_limiter.installHook(L, &limiter);
    try std.testing.expectEqual(@as(u64, 0), lua.instruction_limiter.getInstructionCount(&limiter));
    try std.testing.expect(!lua.instruction_limiter.wasLimitExceeded(&limiter));

    // Constructs the struct whose `mutex` field type did not exist under
    // Zig 0.16, and drives its allocator body through a real alloc/free pair.
    var mem_limiter = lua.memory_limiter.MemoryLimiter.init(
        std.testing.allocator,
        1_048_576,
    );
    const block = lua.memory_limiter.MemoryLimiter.alloc(&mem_limiter, null, 0, 128) orelse
        return error.MemoryLimiterAllocFailed;
    try std.testing.expect(mem_limiter.getCurrentMemory() >= 128);
    _ = lua.memory_limiter.MemoryLimiter.alloc(&mem_limiter, block, 128, 0);
    try std.testing.expect(!mem_limiter.wasLimitExceeded());
}

test "ISS-0169: host_context and the load-time entry point are analysed" {
    // Same ISS-0172 rationale: call, do not merely reference.
    const bindings = lua.luajit_bindings;

    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-root-instance",
        .actor_id = "iss0169-root-actor",
    };

    // createSandboxedState exercises loadSafeStdlib, installContext and
    // registerAll — i.e. every file changed by this tranche.
    const L = try lua.createSandboxedState(&ctx);
    defer bindings.lua_close(L);

    const read_back = lua.host_context.contextFromState(L) orelse
        return error.ContextNotInstalled;
    try std.testing.expectEqualStrings("iss0169-root-instance", read_back.instance_id);

    var cap_buf: [lua.host_context.SERVICE_CAP_BUFFER_BYTES]u8 = undefined;
    const built = lua.host_context.serviceCallCapability(&cap_buf, "payment_svc") orelse
        return error.CapabilityNotBuilt;
    try std.testing.expectEqualStrings("service:call:payment_svc", built);
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

test "ISS-0174 / GH-502: CapabilitySet.summary() compiles, runs, and renders both branches" {
    // GH-502 / ISS-0174: src/lua/capabilities.zig used the Zig 0.15 managed
    // ArrayList API (init/deinit/appendSlice/toOwnedSlice without an allocator
    // argument), which is invisible to zig build test-lua because the only pin
    // in src/lua_test_root.zig was a bare type reference. The migration below
    // exercises the body for real so a compile error cannot hide again.
    //
    // Deliberate-mutation evidence for MUST-3 / MUST-4 is captured in
    // docs/issue-reports/ISS-0174-gh502-diagnosis.yaml (verification_strategy)
    // and re-verified per BACKEND-DEV step 3 procedure in design §6.
    const gpa = std.testing.allocator;

    // TC-CS-01: empty set -> "(none)"
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();

        const slice = try caps.summary(gpa);
        defer gpa.free(slice);

        try std.testing.expectEqualStrings("(none)", slice);
        try std.testing.expectEqual(@as(usize, 6), slice.len);
    }

    // TC-CS-02: single grant -> grant verbatim, no separator
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();
        try caps.add("service:call:payment");

        const slice = try caps.summary(gpa);
        defer gpa.free(slice);

        try std.testing.expectEqualStrings("service:call:payment", slice);
        try std.testing.expectEqual(@as(usize, 20), slice.len);
        try std.testing.expect(std.mem.indexOf(u8, slice, ",") == null);
    }

    // TC-CS-03: multiple grants -> sorted, comma-separated.
    // std.StringHashMap iteration order is undefined; summary() sorts before
    // joining so this assertion is deterministic.
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();
        try caps.add("variable:write");
        try caps.add("service:call:payment");
        try caps.add("audit:log");

        const slice = try caps.summary(gpa);
        defer gpa.free(slice);

        try std.testing.expectEqualStrings(
            "audit:log, service:call:payment, variable:write",
            slice,
        );
    }

    // TC-CS-04 (implicit): every `defer gpa.free(slice)` above succeeds only
    // if gpa actually owns the returned slice. If summary() were returning a
    // stack-allocated or borrowed buffer, the free would corrupt the heap and
    // zig build test-lua's leak detector would fail the run.

    // TC-CS-05 (implicit): the explicit `free` calls demonstrate the
    // caller-owns-the-slice contract documented on summary()'s doc comment.
    // Changing summary() to return a stack slice would corrupt the test
    // allocator on the first defer free.
}
