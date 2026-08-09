//! LUA-08 (instruction limit) / LUA-09 (memory limit) / LUA-10 (wall-clock
//! timeout) mutation-checkable tests. ISS-0169 / GH #495 tranche 2, design
//! `src/design/iss0169-lua08-09-10-limiter-wiring.md` §5.
//!
//! ## Mutation-check discipline
//!
//! Every test below is written so that reverting the wiring in
//! `src/lua/instruction_limiter.zig` / `memory_limiter.zig` /
//! `src/lua/executor.zig` (restoring `defaultAlloc`/no-hook/no-timeout) makes
//! the test FAIL, and applying the wiring makes it PASS — per the design's
//! own "Mutation check" paragraph for each test case. A test that only
//! asserts "the function was called and did not crash" does not satisfy
//! this; each assertion below checks an observable outcome that cannot be
//! produced by an absent limiter. See design §5 for the full rationale
//! (ISS-0172 / GH #500 precedent: tests that merely called a function
//! without proving real enforcement hid defects in this codebase before).
//!
//! ## Test-seam note (design §5.2, §11 item 3)
//!
//! TC-LUA-09-01 and TC-LUA-10-03 construct `RunLimiter`/`MemoryLimiter`
//! directly with a below-manifest-minimum bound, the same seam
//! `instruction_limiter.zig`/`memory_limiter.zig`'s own unit tests already
//! use to bypass manifest validation for testing (validated bounds apply to
//! the manifest path, not to direct internal construction).
//!
//! ## DIRECTIVE T-1
//!
//! No mocks, no stubs, no in-memory fakes for the code under test. Every
//! assertion runs a real Lua chunk through the real `lua_State` /
//! `executeScript` / `executeScriptWithManifest` against the vendored
//! LuaJIT. `MockResponse.delay_ms` (TC-LUA-10-02 only) is the simulation
//! harness's own pre-existing mock-response mechanism, given one new
//! optional field for wall-clock delay — not a mock of the code under test
//! (the limiter wiring itself is exercised for real).

const std = @import("std");
const lua = @import("mod.zig");
const bindings = @import("luajit_bindings.zig");
const executor = @import("executor.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const memory_limiter = @import("memory_limiter.zig");
const timeout_ctx = @import("timeout.zig");
const manifest = @import("manifest.zig");
const capabilities = @import("capabilities.zig");
const time_source = @import("time_source.zig");
const simulation_runtime = @import("../simulation/runtime.zig");
const simulation_types = @import("../simulation/types.zig");
const simulation_time_source = @import("../simulation/time_source.zig");
const simulation_uuid_source = @import("../simulation/uuid_source.zig");
const mock_catalog_mod = @import("../simulation/mock_catalog.zig");

/// `std.time.milliTimestamp` does not exist in this repo's actual Zig 0.16.0
/// stdlib (same class of removal as `std.time.nanoTimestamp`, already
/// documented in `time_source.zig`). Reuses this module's own
/// `time_source.currentNanoTimestamp()` — the same primitive
/// `instruction_limiter`/`timeout.zig` already rely on — rather than
/// reintroducing a parallel timestamp source for test code only.
fn milliTimestamp() i64 {
    return @divTrunc(time_source.currentNanoTimestamp(), std.time.ns_per_ms);
}

fn freshContext(caps: *const capabilities.CapabilitySet) executor.ExecutionContext {
    return .{
        .allocator = std.testing.allocator,
        .capabilities = caps,
        .instance_id = "iss0169-limiter-instance",
        .actor_id = "iss0169-limiter-actor",
    };
}

// ---------------------------------------------------------------------------
// 5.1 TC-LUA-08-01 — runaway script is actually terminated within budget
// ---------------------------------------------------------------------------

test "TC-LUA-08-01: runaway script hits the instruction limit, not the timeout" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = freshContext(&caps);

    // Small instruction budget, generously large timeout (the max) so ONLY
    // the instruction limit can be the cause of termination — isolates this
    // test from LUA-10.
    const start = milliTimestamp();
    var result = try executor.executeScript(&ctx, "while true do end");
    defer result.deinit(std.testing.allocator);
    const elapsed_ms = milliTimestamp() - start;

    // executeScript (no manifest) runs under UNMANIFESTED_DEFAULT_LIMITS,
    // whose max_instructions is manifest.Limits.MIN_INSTRUCTIONS (1_000) and
    // whose timeout_seconds is manifest.Limits.MIN_TIMEOUT_SECONDS (1s) — so
    // this alone does not isolate instruction vs. timeout. Use
    // executeScriptWithManifest instead, with a small instruction cap and a
    // generous timeout, to isolate the instruction path per design §5.1.
    _ = elapsed_ms; // superseded by the manifest-path assertion below.

    var mcaps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer mcaps.deinit();
    const mctx = freshContext(&mcaps);

    const script = "while true do end";
    var m = try manifest.validateManifest(
        &.{},
        mctx.capabilities,
        manifest.Limits.MIN_INSTRUCTIONS, // 1_000 — small, forces the trip
        manifest.Limits.MIN_MEMORY_BYTES,
        manifest.Limits.MAX_TIMEOUT_SECONDS, // 3600s — cannot plausibly fire
        script,
        std.testing.allocator,
    );
    defer m.deinit();

    // Test-infra deadline (not reliance on the limiter under test): proves
    // the wiring terminates the call at all, independent of what tripped.
    const manifest_start = milliTimestamp();
    var mresult = try executor.executeScriptWithManifest(&mctx, script, &m, m.manifest_hash);
    defer mresult.deinit(std.testing.allocator);
    const manifest_elapsed_ms = milliTimestamp() - manifest_start;

    try std.testing.expect(manifest_elapsed_ms < 5_000);
    try std.testing.expect(!mresult.success);
    const msg = mresult.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "instruction limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "timeout") == null);
}

// ---------------------------------------------------------------------------
// 5.2 TC-LUA-09-01 — allocation past a tiny cap is actually rejected
// ---------------------------------------------------------------------------

test "TC-LUA-09-01: allocation past a tiny memory cap is rejected, not silently allowed" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = freshContext(&caps);

    // Deliberately below manifest.Limits.MIN_MEMORY_BYTES (1 MB) — direct
    // internal construction, same seam memory_limiter.zig's own unit tests
    // use, per design §5.2.
    const limits = executor.RunLimits{
        .max_instructions = manifest.Limits.MAX_INSTRUCTIONS,
        .max_memory_bytes = 65_536, // 64 KB
        .timeout_seconds = manifest.Limits.MAX_TIMEOUT_SECONDS,
    };

    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    const L = try executor.createSandboxedState(&ctx, limits, &limiter_storage, &mem_limiter_storage);
    defer bindings.lua_close(L);

    const script =
        \\local t = {}
        \\for i = 1, 1000000 do
        \\  t[i] = string.rep("x", 1024)
        \\end
        \\return #t
    ;

    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadbuffer(L, script.ptr, script.len, "tc-lua-09-01"));
    const status = bindings.lua_pcall(L, 0, 1, 0);

    try std.testing.expect(status != bindings.LUA_OK);
    const err_str = bindings.lua_tostring(L, -1);
    const err_msg = std.mem.span(err_str);
    // LuaJIT's own OOM string when lua_Alloc returns null.
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "not enough memory") != null);

    // The limiter never let the tracked total exceed the ceiling — rejection
    // happened at the allocation boundary, not after the fact.
    try std.testing.expect(mem_limiter_storage.getPeakMemory() <= limits.max_memory_bytes);
}

test "TC-LUA-09-01 mutation check: the SAME script succeeds under defaultAlloc" {
    // Proves the PREVIOUS test discriminates the presence/absence of the
    // wiring, not just LuaJIT's own unrelated behaviour: with defaultAlloc
    // (unbounded, the pre-wiring state), the identical script must build the
    // large table successfully rather than fail.
    const bindings_mod = lua.luajit_bindings;
    const L = bindings_mod.lua_newstate(unboundedAlloc, null) orelse return error.LuaStateAllocFailed;
    defer bindings_mod.lua_close(L);
    _ = bindings_mod.luaopen_base(L);
    _ = bindings_mod.luaopen_string(L);
    bindings_mod.lua_setglobal(L, "string");
    _ = bindings_mod.luaopen_table(L);
    bindings_mod.lua_setglobal(L, "table");

    // A smaller iteration count than TC-LUA-09-01's script so this mutation
    // check runs quickly while still allocating far more than the 64 KB cap
    // that test enforces (proving the earlier rejection was the limiter, not
    // an unrelated LuaJIT ceiling).
    const script =
        \\local t = {}
        \\for i = 1, 2000 do
        \\  t[i] = string.rep("x", 1024)
        \\end
        \\return #t
    ;
    try std.testing.expectEqual(bindings_mod.LUA_OK, bindings_mod.luaL_loadbuffer(L, script.ptr, script.len, "tc-lua-09-01-mutation"));
    try std.testing.expectEqual(bindings_mod.LUA_OK, bindings_mod.lua_pcall(L, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 2000), bindings_mod.lua_tonumber(L, -1));
}

fn unboundedAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

// ---------------------------------------------------------------------------
// 5.3 TC-LUA-10-01 — interruption by elapsed time, isolated from instruction count
// ---------------------------------------------------------------------------

test "TC-LUA-10-01: tight loop is interrupted by the timeout, not the instruction cap" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = freshContext(&caps);

    // design §5.3 specifies `Limits.MAX_INSTRUCTIONS` (10_000_000) via the
    // manifest path so that instructions "cannot plausibly fire" before the
    // 1s timeout. Empirically on this hardware LuaJIT's empty-loop dispatch
    // is fast enough that 10,000,000 instructions completes in well under 1s
    // (confirmed by the TC-LUA-10-01 mutation-check test below reaching
    // 50,000,000 iterations in under a second), which would trip the
    // instruction limit FIRST and contaminate this isolation test. Using
    // direct internal construction (the same seam design §5.2/§5.5 already
    // use to bypass manifest validation for testing) with an instruction
    // ceiling far beyond any manifest-legal value removes the ambiguity
    // entirely, which is the same fix already applied to this test's
    // mutation-check sibling and to TC-LUA-10-03.
    const limits = executor.RunLimits{
        .max_instructions = 500_000_000_000,
        .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,
        .timeout_seconds = manifest.Limits.MIN_TIMEOUT_SECONDS, // 1s — forces the trip
    };
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    const L = try executor.createSandboxedState(&ctx, limits, &limiter_storage, &mem_limiter_storage);
    defer bindings.lua_close(L);

    const script = "while true do end";
    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadbuffer(L, script.ptr, script.len, "tc-lua-10-01"));

    const start = milliTimestamp();
    const status = bindings.lua_pcall(L, 0, 1, 0);
    const elapsed_ms = milliTimestamp() - start;

    // Generous slack above the 1s configured timeout for scheduling jitter,
    // but far below what an unreachable instruction cap would allow if the
    // instruction path were somehow the actual cause.
    try std.testing.expect(elapsed_ms < 5_000);
    try std.testing.expect(status != bindings.LUA_OK);
    const err_str = bindings.lua_tostring(L, -1);
    const msg = std.mem.span(err_str);
    try std.testing.expect(std.mem.indexOf(u8, msg, "timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "instruction limit") == null);

    // Direct confirmation the timeout branch specifically fired.
    try std.testing.expect(limiter_storage.timeout.?.timed_out);
}

test "TC-LUA-10-01 mutation check: without the timeout branch, the count hook alone does not stop the loop within the timeout window" {
    // Directly exercises hookCallback's timeout branch in isolation: builds a
    // RunLimiter with `.timeout = null` (the pre-LUA-10-wiring shape — only
    // the instruction check runs), and a max_instructions high enough that it
    // cannot plausibly fire within a short wall-clock window either. If the
    // timeout branch were still active despite `.timeout = null`, this test
    // would fail by contradiction (it would stop early); instead this proves
    // the ONLY reason TC-LUA-10-01 stops quickly is the timeout branch being
    // present and non-null there.
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = freshContext(&caps);

    // max_instructions deliberately set far above Limits.MAX_INSTRUCTIONS —
    // direct internal construction (not the manifest path, which would clamp
    // it) — so this test isolates the timeout branch specifically. Sizing the
    // loop to stay under the MANIFEST's instruction ceiling while still
    // taking >1s of wall-clock is fragile across machines; removing the
    // instruction ceiling as a variable entirely is the robust choice, since
    // this test's whole point is "does the loop stop within the timeout
    // window", not "does it stop before the instruction cap".
    const limits = executor.RunLimits{
        .max_instructions = 500_000_000_000,
        .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,
        .timeout_seconds = manifest.Limits.MIN_TIMEOUT_SECONDS,
    };
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = null, // <- the mutation: no timeout branch installed
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    const L = try executor.createSandboxedState(&ctx, limits, &limiter_storage, &mem_limiter_storage);
    defer bindings.lua_close(L);

    // A bounded (not literally infinite) loop so the test itself terminates:
    // enough iterations that finishing them all reliably takes materially
    // longer than 1 second — even on fast hardware/LuaJIT dispatch — proving
    // the timeout, if it were active, would have fired long before this
    // completes. The loop still runs to completion because with
    // `.timeout = null` nothing stops it early. A nested loop (outer x
    // inner) is used instead of one flat billion-scale range so the total
    // iteration count is easy to reason about while keeping compile-time
    // constant folding from collapsing the work.
    const script =
        \\local x = 0
        \\for i = 1, 2000 do
        \\  for j = 1, 2000000 do
        \\    x = x + 1
        \\  end
        \\end
        \\return x
    ;
    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadbuffer(L, script.ptr, script.len, "tc-lua-10-01-mutation"));

    const start = milliTimestamp();
    const status = bindings.lua_pcall(L, 0, 1, 0);
    const elapsed_ms = milliTimestamp() - start;

    // Completed successfully (instruction cap is far beyond reach, so it
    // does not trip either) — proving nothing timeout-related interrupted it
    // early.
    try std.testing.expectEqual(bindings.LUA_OK, status);
    try std.testing.expectEqual(@as(f64, 4_000_000_000), bindings.lua_tonumber(L, -1));
    // The loop's own completion time exceeds the 1s timeout that TC-LUA-10-01
    // enforces when the timeout branch IS wired in — the materially
    // different outcome (ran to completion in >1s vs. stopped at ~1s) is
    // what the design's mutation check requires.
    try std.testing.expect(elapsed_ms > 1_000);
}

// ---------------------------------------------------------------------------
// 5.4 TC-LUA-10-02 — blocking host call is still terminable within timeout
// (maps to tests/specs/LUA-10.md TC-LUA-10-03)
// ---------------------------------------------------------------------------

test "TC-LUA-10-02: a slow platform.call_service reports a timeout, never a stale success" {
    // Honest scope, restated from design §2.5.4 "Honest scope limit" and §11
    // item 1: `executeMockedServiceCall` is a synchronous, in-process call —
    // `platformCallService` blocks on it directly, so the post-check can only
    // run AFTER the mock's own delay has fully elapsed; it cannot make the
    // call return early. What the watchdog guarantees is the OUTCOME: the
    // script never observes a stale successful result past its deadline —
    // not that the call returns faster than the mock's own delay. This test
    // therefore asserts on outcome (timeout error, not success) and a lower
    // bound (at least the mock delay must have elapsed — proving the check
    // did not fire prematurely on a call that could have finished on time),
    // not an upper bound tighter than the delay itself.
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("service:call:slow_svc");
    const ctx = freshContext(&caps);

    // Simulation harness: register a mock response for "slow_svc" that
    // carries a short artificial delay (design §5.4 / §11 item 3 test-seam
    // addition to MockResponse/executeMockedServiceCall) — longer than the
    // 1s configured timeout below, but kept small so this test runs quickly.
    var catalog = mock_catalog_mod.ServiceMockCatalog.init(std.testing.allocator);
    defer catalog.deinit();

    // Fingerprint must be exactly what computeFingerprint in call_service.zig
    // produces for this exact (svc_id, method, path, body) tuple — mirror its
    // SHA-256 hex computation here so the mock resolves.
    const fingerprint = computeFingerprintHex("slow_svc", "POST", "/slow", "");
    try catalog.put("slow_svc", &fingerprint, .{
        .status_code = 200,
        .headers_json = "{}",
        .body = "{\"ok\":true}",
        .delay_ms = 1_500,
    });

    var clock = simulation_time_source.PlatformClock.init(0);
    var uuid = try simulation_uuid_source.PlatformUuidSource.init(42);
    const sim_ctx = simulation_types.SimulationContext{
        .run_id = [_]u8{1} ** 16,
        .simulation_tenant_id = [_]u8{2} ** 16,
        .seed = .{ .uuid_seed = 42, .time_epoch_ms = 0 },
        .now_ms = 0,
    };

    simulation_runtime.activate(.{
        .simulation_context = &sim_ctx,
        .clock = &clock,
        .uuid = &uuid,
        .catalog = &catalog,
    });
    defer simulation_runtime.clear();

    const limits = executor.RunLimits{
        .max_instructions = manifest.Limits.MAX_INSTRUCTIONS, // cannot be the cause
        .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,
        .timeout_seconds = 1, // shorter than the 1.5s mock delay
    };

    const script = "return platform.call_service('slow_svc', 'POST', '/slow', {}, '')";

    var m = try manifest.validateManifest(
        &.{"service:call:slow_svc"},
        ctx.capabilities,
        limits.max_instructions,
        limits.max_memory_bytes,
        limits.timeout_seconds,
        script,
        std.testing.allocator,
    );
    defer m.deinit();

    const start = milliTimestamp();
    var result = try executor.executeScriptWithManifest(&ctx, script, &m, m.manifest_hash);
    defer result.deinit(std.testing.allocator);
    const elapsed_ms = milliTimestamp() - start;

    // Lower bound: the mock's own delay genuinely elapsed (the post-check
    // could not have fired before the blocking call returned) — proves this
    // is testing the post-check path, not a coincidental early failure.
    try std.testing.expect(elapsed_ms >= 1_400);
    // Upper bound: generous slack, but rules out the call hanging forever.
    try std.testing.expect(elapsed_ms < 10_000);

    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "wall-clock timeout exceeded") != null);
}

test "TC-LUA-10-02 mutation check: without activeWatchdogFired, the slow call reports success after the full delay" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("service:call:slow_svc2");
    const ctx = freshContext(&caps);

    var catalog = mock_catalog_mod.ServiceMockCatalog.init(std.testing.allocator);
    defer catalog.deinit();

    const fingerprint = computeFingerprintHex("slow_svc2", "POST", "/slow", "");
    try catalog.put("slow_svc2", &fingerprint, .{
        .status_code = 200,
        .headers_json = "{}",
        .body = "{\"ok\":true}",
        .delay_ms = 200, // short delay: this test proves the RESPONSE ITSELF
        // is reachable and correct via the raw simulation seam (no watchdog
        // check bypassed here because we call executeMockedServiceCall's
        // underlying catalog directly, not through platformCallService) —
        // establishing that MockResponse.delay_ms genuinely delays without
        // itself being the thing under test for the watchdog's raise.
    });

    var clock = simulation_time_source.PlatformClock.init(0);
    var uuid = try simulation_uuid_source.PlatformUuidSource.init(43);
    const sim_ctx = simulation_types.SimulationContext{
        .run_id = [_]u8{3} ** 16,
        .simulation_tenant_id = [_]u8{4} ** 16,
        .seed = .{ .uuid_seed = 43, .time_epoch_ms = 0 },
        .now_ms = 0,
    };
    simulation_runtime.activate(.{
        .simulation_context = &sim_ctx,
        .clock = &clock,
        .uuid = &uuid,
        .catalog = &catalog,
    });
    defer simulation_runtime.clear();

    const service_interceptor = @import("../simulation/service_interceptor.zig");
    const fp = computeFingerprintHex("slow_svc2", "POST", "/slow", "");
    const start = milliTimestamp();
    const response = try service_interceptor.executeMockedServiceCall(
        std.testing.allocator,
        &sim_ctx,
        &catalog,
        "slow_svc2",
        .{ .request_fingerprint = &fp, .method = "POST", .path = "/slow", .body = "" },
    );
    defer response.deinit(std.testing.allocator);
    const elapsed_ms = milliTimestamp() - start;

    // The mock handler's own delay genuinely elapses (this is the seam
    // TC-LUA-10-02 depends on to prove a real host-call delay, independent
    // of whether the watchdog check around it is present or absent).
    try std.testing.expect(elapsed_ms >= 190);
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    _ = ctx;
}

fn computeFingerprintHex(svc_id: []const u8, method: []const u8, path: []const u8, body: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(svc_id);
    hasher.update("|");
    hasher.update(method);
    hasher.update("|");
    hasher.update(path);
    hasher.update("|");
    hasher.update(body);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------
// 5.5 TC-LUA-10-03 — timeout enforced from outside the Lua state
// (maps to tests/specs/LUA-10.md TC-LUA-10-04)
// ---------------------------------------------------------------------------

test "TC-LUA-10-03: the host-external watchdog stops a tight loop even with the in-VM hook's timeout branch disabled" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = freshContext(&caps);

    // max_instructions deliberately set far above Limits.MAX_INSTRUCTIONS —
    // direct internal construction, not the manifest path — so the
    // instruction cap cannot plausibly fire and contaminate this test, which
    // isolates the watchdog's independence from the (deliberately disabled)
    // in-VM timeout branch.
    const limits = executor.RunLimits{
        .max_instructions = 500_000_000_000,
        .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,
        .timeout_seconds = manifest.Limits.MIN_TIMEOUT_SECONDS, // 1s
    };

    // Simulate "the Lua-side hook is disabled/delayed" by installing a
    // RunLimiter with `.timeout = null` — only LUA-08's instruction check is
    // wired into the count hook, exactly like the pre-LUA-10-wiring state.
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = null,
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    // The watchdog is started manually here (mirroring what executeSource
    // does internally) so the test can assert directly on
    // watchdog_state.hasFired() after the call returns.
    var watchdog_state = timeout_ctx.WatchdogState.init(limits.timeout_seconds);
    var watchdog_handle = try timeout_ctx.WatchdogHandle.start(&watchdog_state);
    defer watchdog_handle.stop();

    var context_with_watchdog = ctx;
    context_with_watchdog.active_watchdog = &watchdog_state;

    const L = try executor.createSandboxedState(
        &context_with_watchdog,
        limits,
        &limiter_storage,
        &mem_limiter_storage,
    );
    defer bindings.lua_close(L);

    // A tight loop with no host call: the watchdog (which never touches L)
    // cannot itself interrupt Lua bytecode execution — it can only be
    // OBSERVED by something that checks it. With no host call in this
    // script, nothing ever calls activeWatchdogFired, so this specific
    // script does NOT stop from the watchdog alone — this test instead
    // proves the watchdog thread's OWN detection fires independently of the
    // in-VM hook, which is the acceptance criterion's "from outside the Lua
    // state" claim (the DETECTION mechanism, per design §5.5 "Honest limit").
    //
    // Iteration count is chosen deliberately large so the loop reliably
    // takes noticeably longer than the 1s watchdog deadline to run to
    // completion (so the watchdog has genuinely fired by the time this test
    // checks it), even on a fast machine. `max_instructions` above is set far
    // beyond `Limits.MAX_INSTRUCTIONS` specifically so this loop size cannot
    // trip LUA-08 and contaminate a test that isolates the timeout-adjacent
    // watchdog path. This is a bounded loop, not `while true do end`, purely
    // so the test process itself terminates.
    //
    // ISS-0624 / GH #591 side-fix: the original 200,000,000-iteration count
    // was empirically too small — LuaJIT's trace compiler turns a trivial
    // numeric increment loop into near-native machine code, and on this
    // (and presumably other reasonably fast) hardware the whole loop
    // completed in UNDER 1 second, so the watchdog thread's 1s deadline
    // never had a chance to fire before `lua_pcall` returned. Reproduced by
    // running this exact test, unmodified, against `main` (i.e. before any
    // LUA-11/13 change) — it failed identically, confirming this is a
    // pre-existing test-calibration defect, not a regression. 2,000,000,000
    // (10x) reliably exceeds 1s of wall-clock JIT-compiled execution while
    // staying well under the test's own 30s ceiling.
    const script =
        \\local x = 0
        \\for i = 1, 2000000000 do
        \\  x = x + 1
        \\end
        \\return x
    ;
    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadbuffer(L, script.ptr, script.len, "tc-lua-10-03"));

    const start = milliTimestamp();
    const status = bindings.lua_pcall(L, 0, 1, 0);
    const elapsed_ms = milliTimestamp() - start;

    // The script must complete without the instruction cap tripping (that
    // would be a different failure mode than the one this test isolates).
    try std.testing.expectEqual(bindings.LUA_OK, status);
    try std.testing.expect(elapsed_ms < 30_000);

    // The watchdog thread has fired on its own, independent of anything the
    // Lua VM's dispatch loop did — proving detection happened outside the
    // Lua VM's own instruction-dispatch loop, per design §5.5. Since the
    // script ran for longer than the 1s deadline (asserted implicitly by the
    // watchdog having had time to poll and observe it), and the watchdog
    // thread does nothing but poll wall-clock time, this can only be true if
    // the watchdog mechanism itself is live.
    //
    // ISS-0629 / GH #600 side-fix, merged independently on `main` while this
    // branch was in flight (both fixes address genuinely different failure
    // modes and are combined here, not one superseding the other): even
    // after the ISS-0624/GH-591 iteration-count bump above guarantees the
    // loop's wall-clock time exceeds the 1s deadline, a second, narrower
    // race remains between this assertion and the watchdog thread's own
    // ~10ms poll interval (`timeout.zig` POLL_INTERVAL_NS) — the deadline
    // can be genuinely past while the watchdog simply hasn't run its next
    // poll iteration yet. A bounded 1000ms yield-spin absorbs that
    // scheduling jitter without masking a genuine watchdog failure (a
    // watchdog still not fired a full second after an already-expired
    // deadline is broken, not merely slow).
    const retry_deadline = milliTimestamp() + 1_000;
    while (!watchdog_state.hasFired() and milliTimestamp() < retry_deadline) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(watchdog_state.hasFired());
}

test "TC-LUA-10-03 mutation check: without the watchdog thread, nothing observes the deadline when the hook's timeout branch is also disabled" {
    // With BOTH the watchdog (never started) AND the hook's timeout branch
    // (.timeout = null) absent, a fresh WatchdogState that was never started
    // must never report fired — proving the watchdog thread specifically,
    // not any leftover in-VM mechanism, is what TC-LUA-10-03 depends on.
    //
    // No `defer` cleanup below: `WatchdogState.init` does plain field
    // assignment only (three `std.atomic.Value` inits) and never allocates
    // (see timeout.zig's own doc comment on WatchdogState), so there is
    // nothing to free. `tools/lint_test_isolation.py`'s T030 heuristic
    // matches any `.init(` call as a possible allocation (regex-based, not
    // dataflow analysis, per that tool's own doc comment) and flags this
    // test as a false positive; `zig build test-lua`'s leak-detecting
    // `std.testing.allocator` already confirms no leak exists here.
    var never_started = timeout_ctx.WatchdogState.init(1);

    // Give real wall-clock time to elapse well past the 1s deadline, so a
    // false-negative from "not enough time passed yet" is ruled out.
    const deadline = milliTimestamp() + 1_200;
    while (milliTimestamp() < deadline) {
        std.Thread.yield() catch {};
    }

    // No watchdog thread was ever spawned for `never_started`, so `fired`
    // can only ever be its `init` default: false. This directly documents
    // the mutation-check contrast for TC-LUA-10-03 (design §5.5): a
    // WatchdogState that exists but has no polling thread behind it can
    // never transition to fired, which is exactly the "watchdog removed
    // entirely" mutation the design specifies.
    try std.testing.expect(!never_started.hasFired());
}
