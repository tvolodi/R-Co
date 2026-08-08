//! LUA-01..05 execution tests against a REAL, statically linked LuaJIT.
//!
//! Lives under src/lua/ rather than tests/unit/ for the module-boundary reason
//! documented in src/lua_test_root.zig: this subsystem's import chain escapes
//! src/lua/, so it is analysed via that root.
//!
//! ISS-0161 / GH #485. `tests/specs/LUA-01-05.md` has specified these since
//! May 2026, but they could not be written: no LuaJIT existed in the repo, so
//! `docs/issue-reports/MINOR-LUA-001-resolution.md` deferred them and named
//! "add luajit.h to build environment" as the trigger. That trigger has now
//! fired.
//!
//! Every test here would fail against the ISS-0153 stubs — `lua_newstate`
//! returned null and `luaL_loadstring` returned `LUA_ERRSYNTAX`, so no script
//! could run and no sandbox rule could be observed. That is deliberate: these
//! assert *executable* behaviour, which is the whole point of the issue.
const std = @import("std");
const lua = @import("mod.zig");
const bindings = @import("luajit_bindings.zig");
const stdlib = @import("stdlib.zig");
const executor = @import("executor.zig");
const capabilities = @import("capabilities.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const memory_limiter = @import("memory_limiter.zig");
const timeout_ctx = @import("timeout.zig");
const manifest = @import("manifest.zig");

/// Capabilities and context backing `sandboxedState`. File-scope so the
/// pointer satisfies invariant CTX-1 (the context must outlive the state) for
/// every test that uses the helper.
var shared_caps: ?capabilities.CapabilitySet = null;
var shared_context: executor.ExecutionContext = undefined;

/// Storage for a state built by `sandboxedState`, returned alongside `L` so
/// the caller can free it after `lua_close` (ISS-0169 tranche 2:
/// `createSandboxedState` now requires caller-owned limiter storage that
/// outlives `L` — INV-1 — which a plain `!*bindings.lua_State` return cannot
/// carry on its own).
pub const SandboxedState = struct {
    L: *bindings.lua_State,
    limiter_storage: *instruction_limiter.RunLimiter,
    mem_limiter_storage: *memory_limiter.MemoryLimiter,

    /// Close the state and free its limiter storage. Mirrors
    /// `bindings.lua_close(L)` plus the cleanup `executeSource` performs via
    /// its own stack-allocated storage — here heap-allocated because this
    /// helper is called from many independent test bodies and must outlive
    /// the call that constructs it.
    pub fn deinit(self: SandboxedState) void {
        bindings.lua_close(self.L);
        std.testing.allocator.destroy(self.limiter_storage);
        std.testing.allocator.destroy(self.mem_limiter_storage);
    }
};

/// A fresh sandboxed state, built by THE SAME constructor the product uses.
///
/// ISS-0169 (design §5.3, invariant SBX-2): this helper used to build its own
/// state and call `luaopen_base(L)` itself, while `executeScript` never opened
/// base at all. Its doc comment claimed it built the state "exactly as
/// executeScript builds it" — that was FALSE, and it meant every green LUA-03
/// sandbox assertion was made against a more permissive state than the product
/// ever constructed (diagnosis R4). The base-library call is gone and this now
/// delegates to `executor.createSandboxedState`, which is what makes the
/// LUA-03 evidence below mean anything.
///
/// ISS-0169 tranche 2: runs under generous limits (max bounds from
/// `manifest.Limits`) so the LUA-01..05/EDGE tests in this file — none of
/// which exercise limiter behaviour directly — are not incidentally affected
/// by the new instruction/memory/timeout enforcement. Limiter-specific
/// behaviour is exercised by the dedicated LUA-08/09/10 tests
/// (`limiter_wiring_test.zig`).
///
/// Caller must call `.deinit()` on the returned `SandboxedState` (closes `L`
/// and frees its limiter storage).
fn sandboxedState() !SandboxedState {
    if (shared_caps == null) {
        shared_caps = capabilities.CapabilitySet.init(std.testing.allocator);
        shared_context = .{
            .allocator = std.testing.allocator,
            .capabilities = &shared_caps.?,
            .instance_id = "iss0169-sandbox-instance",
            .actor_id = "iss0169-sandbox-actor",
        };
    }

    const limits = executor.RunLimits{
        .max_instructions = manifest.Limits.MAX_INSTRUCTIONS,
        .max_memory_bytes = manifest.Limits.MAX_MEMORY_BYTES,
        .timeout_seconds = manifest.Limits.MAX_TIMEOUT_SECONDS,
    };

    const limiter_storage = try std.testing.allocator.create(instruction_limiter.RunLimiter);
    errdefer std.testing.allocator.destroy(limiter_storage);
    limiter_storage.* = .{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };

    const mem_limiter_storage = try std.testing.allocator.create(memory_limiter.MemoryLimiter);
    errdefer std.testing.allocator.destroy(mem_limiter_storage);
    mem_limiter_storage.* = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    const L = try executor.createSandboxedState(&shared_context, limits, limiter_storage, mem_limiter_storage);
    return .{ .L = L, .limiter_storage = limiter_storage, .mem_limiter_storage = mem_limiter_storage };
}

/// Run `src` and return the numeric result. Errors if it does not compile,
/// does not run, or does not return a number.
fn evalNumber(L: *bindings.lua_State, src: [*:0]const u8) !f64 {
    if (bindings.luaL_loadstring(L, src) != bindings.LUA_OK) return error.CompileFailed;
    if (bindings.lua_pcall(L, 0, 1, 0) != bindings.LUA_OK) return error.RuntimeFailed;
    defer bindings.lua_pop(L, 1);
    if (bindings.lua_isnumber(L, -1) == 0) return error.NotANumber;
    return bindings.lua_tonumber(L, -1);
}

/// True when `expr` evaluates to nil — the shape every "module is not
/// available" assertion takes.
fn evalsToNil(L: *bindings.lua_State, src: [*:0]const u8) !bool {
    if (bindings.luaL_loadstring(L, src) != bindings.LUA_OK) return error.CompileFailed;
    if (bindings.lua_pcall(L, 0, 1, 0) != bindings.LUA_OK) return error.RuntimeFailed;
    defer bindings.lua_pop(L, 1);
    return bindings.lua_isnil(L, -1) != 0;
}

// ---------------------------------------------------------------------------
// LUA-01 — LuaJIT integration
// ---------------------------------------------------------------------------

test "TC-LUA-01-02: Lua C-interop bindings are real, not stubs" {
    // The ISS-0153 stubs set this false. If it is ever false again while these
    // tests exist, the subsystem has silently regressed to non-executing.
    try std.testing.expect(bindings.has_real_luajit);

    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;
    try std.testing.expectEqual(@as(f64, 42), try evalNumber(L, "return 6 * 7"));
}

// ---------------------------------------------------------------------------
// LUA-02 — State isolation per invocation
// ---------------------------------------------------------------------------

test "TC-LUA-02-01: first script sets a global, a second state does not see it" {
    {
        const sb1 = try sandboxedState();
        defer sb1.deinit();
        const L1 = sb1.L;
        try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L1, "leaked = 99 return 1"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L1, 0, 1, 0));
    }

    // A separate state must not observe the first one's global.
    const sb2 = try sandboxedState();
    defer sb2.deinit();
    const L2 = sb2.L;
    try std.testing.expect(try evalsToNil(L2, "return leaked"));
}

test "TC-LUA-02-03: state cleanup after script completes" {
    // Repeated create/destroy must neither leak state nor carry values across.
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const sb = try sandboxedState();
        defer sb.deinit();
        const L = sb.L;
        try std.testing.expect(try evalsToNil(L, "return carried"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L, "carried = 1 return 1"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L, 0, 1, 0));
    }
}

// ---------------------------------------------------------------------------
// LUA-03 — Stdlib restriction (the security-critical sandbox)
// ---------------------------------------------------------------------------

test "TC-LUA-03-01/02/03: math, string and table are available and functional" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    try std.testing.expectEqual(@as(f64, 4), try evalNumber(L, "return math.floor(4.7)"));
    try std.testing.expectEqual(@as(f64, 5), try evalNumber(L, "return string.len('hello')"));
    try std.testing.expectEqual(@as(f64, 3), try evalNumber(L, "return #({1,2,3})"));
    try std.testing.expectEqual(@as(f64, 6), try evalNumber(L,
        "local t = {1,2,3} local s = 0 for _,v in ipairs(t) do s = s + v end return s"));
}

test "TC-LUA-03-04..07: io, os, package and debug are NOT available" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    // loadSafeStdlib never opens these. Each must be nil rather than a usable
    // table -- this is what stops a script reaching the filesystem, the
    // process environment, or the debug introspection API.
    for ([_][*:0]const u8{
        "return io",
        "return os",
        "return package",
        "return debug",
    }) |expr| {
        try std.testing.expect(try evalsToNil(L, expr));
    }
}

test "TC-LUA-03-08..12: load, loadstring, dofile, loadfile and string.dump are removed" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    // These are the escape hatches: each would let a script build new
    // executable code or read a file, defeating LUA-04's bytecode gate.
    for ([_][*:0]const u8{
        "return load",
        "return loadstring",
        "return dofile",
        "return loadfile",
        "return string.dump",
    }) |expr| {
        try std.testing.expect(try evalsToNil(L, expr));
    }
}

test "TC-LUA-03: calling a removed global raises, it does not silently no-op" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    // Attempting to call nil must be a runtime error. If this ever passes,
    // something has re-registered an escape hatch.
    try std.testing.expectEqual(
        bindings.LUA_OK,
        bindings.luaL_loadstring(L, "return loadstring('return 1')()"),
    );
    try std.testing.expect(bindings.lua_pcall(L, 0, 1, 0) != bindings.LUA_OK);
    bindings.lua_pop(L, 1);
}

// ---------------------------------------------------------------------------
// LUA-04 — Bytecode loading disabled
// ---------------------------------------------------------------------------

test "TC-LUA-04-01/03: bytecode is rejected with a bytecode-specific error" {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0161-instance",
        .actor_id = "iss0161-actor",
    };

    // Lua bytecode magic: 0x1b 'L' 'u' 'a'.
    const bytecode = "\x1bLua\x51\x00";

    // executeScript reports bytecode rejection as a FAILED ScriptResult, not as
    // a Zig error — the caller gets a message it can surface to the script
    // author. TC-LUA-04-03 requires that message name bytecode specifically.
    var result = try lua.executeScript(&ctx, bytecode);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Bytecode") != null);
}

test "TC-LUA-04-02: source text still works after the bytecode check" {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0161-instance",
        .actor_id = "iss0161-actor",
    };

    var result = try lua.executeScript(&ctx, "return 1 + 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
}

// ---------------------------------------------------------------------------
// LUA-05 / LUA-06 — capability enforcement (ISS-0169 / GH #495)
//
// These are the direct empirical inverse of diagnosis evidence E9, which
// recorded that with a COMPLETELY EMPTY CapabilitySet all seven
// capability-requiring platform.* calls SUCCEEDED. If any test below ever goes
// green while asserting success on an empty grant set, the gate is gone again.
// ---------------------------------------------------------------------------

/// Run `src` through the real `executeScript` with exactly `grants` granted.
/// Returns the ScriptResult; caller deinits.
fn runWithGrants(grants: []const []const u8, src: []const u8) !lua.ScriptResult {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    for (grants) |g| try caps.add(g);

    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-instance",
        .actor_id = "iss0169-actor",
    };
    return lua.executeScript(&ctx, src);
}

/// The six gated functions of the Architecture §5.2 matrix, each with a call
/// that supplies valid arguments so that ONLY the capability can be the cause
/// of a failure.
const GATED_CALLS = [_]struct {
    fn_name: []const u8,
    capability: []const u8,
    call: []const u8,
}{
    .{ .fn_name = "call_service", .capability = "service:call:payment_svc", .call = "platform.call_service('payment_svc', 'POST', '/pay')" },
    .{ .fn_name = "read_variable", .capability = "variable:read", .call = "platform.read_variable('amount')" },
    .{ .fn_name = "write_variable", .capability = "variable:write", .call = "platform.write_variable('amount', 1)" },
    .{ .fn_name = "log", .capability = "audit:log", .call = "platform.log('info', 'hello')" },
    .{ .fn_name = "emit_event", .capability = "event:emit", .call = "platform.emit_event('APPROVED', {})" },
    .{ .fn_name = "get_instance_state", .capability = "instance:read", .call = "platform.get_instance_state()" },
};

test "TC-LUA-06: with an EMPTY capability set every gated function is DENIED" {
    for (GATED_CALLS) |c| {
        var result = try runWithGrants(&.{}, c.call);
        defer result.deinit(std.testing.allocator);

        // E9's inverse: this MUST fail. Before ISS-0169 every one succeeded.
        try std.testing.expect(!result.success);
        const msg = result.error_message orelse return error.NoErrorMessage;

        // LUA-06: the error names the function, the capability required, and
        // the capabilities granted.
        try std.testing.expect(std.mem.indexOf(u8, msg, "capability denied") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, c.fn_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, c.capability) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "(none)") != null);
    }
}

test "TC-LUA-06: granting exactly the required capability lets the call through" {
    for (GATED_CALLS) |c| {
        var result = try runWithGrants(&.{c.capability}, c.call);
        defer result.deinit(std.testing.allocator);

        // The gate must not be a blanket refusal: with the grant present the
        // call proceeds. (The bodies remain unimplemented — LUA-11/12/13 —
        // so "proceeds" means "did not raise", which is exactly the claim.)
        if (!result.success) {
            std.debug.print("unexpected denial for {s}: {s}\n", .{ c.fn_name, result.error_message orelse "(no message)" });
        }
        try std.testing.expect(result.success);
    }
}

test "TC-LUA-06: an unrelated grant does not open a different function" {
    // Holding variable:read must not permit variable:write. This is what
    // distinguishes a real per-capability gate from a "context is present, so
    // allow" check.
    var result = try runWithGrants(&.{"variable:read"}, "platform.write_variable('k', 1)");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "variable:write") != null);
    // The granted set is rendered, so the denial is diagnosable.
    try std.testing.expect(std.mem.indexOf(u8, msg, "variable:read") != null);
}

test "TC-LUA-06-01/02: call_service is gated per service id, not blanket" {
    // Granted for payment_svc only.
    const grants = [_][]const u8{"service:call:payment_svc"};

    var ok = try runWithGrants(&grants, "platform.call_service('payment_svc','POST','/pay')");
    defer ok.deinit(std.testing.allocator);
    try std.testing.expect(ok.success);

    // A DIFFERENT service must be denied even though a service:call:* grant
    // exists — `has()` is exact match; wildcards are not honoured (design §3.3).
    var denied = try runWithGrants(&grants, "platform.call_service('shipping_svc','POST','/ship')");
    defer denied.deinit(std.testing.allocator);
    try std.testing.expect(!denied.success);
    const msg = denied.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "service:call:shipping_svc") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "shipping_svc") != null);
}

test "TC-LUA-06: a script can observe its own denial with pcall" {
    // LUA-06's semantics are "raises a Lua error", so a script must be able to
    // catch one. This is why §5.2 keeps pcall in the sandbox.
    var result = try runWithGrants(&.{},
        \\local ok, err = pcall(function() return platform.read_variable('k') end)
        \\if ok then return 'NOT_DENIED' end
        \\return err
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expect(std.mem.indexOf(u8, value.string, "capability denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.string, "variable:read") != null);
}

test "TC-LUA-05: argument errors are distinguishable from capability denials" {
    // With the capability granted, a bad argument must produce the §4.2
    // ARGUMENT-error format — not a denial, and not stack garbage.
    var result = try runWithGrants(&.{"variable:write"}, "platform.write_variable(123, 1)");
    defer result.deinit(std.testing.allocator);

    // E11: this call used to SUCCEED, because lua_isstring coerces numbers.
    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "invalid argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "write_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "capability denied") == null);
}

test "TC-LUA-05: a missing argument reports a real message, not stack garbage" {
    // E6/E11: `platform.read_variable()` used to report
    // '1.0954944061662e-311' — uninitialised stack memory — because
    // lua_error was called with nothing pushed (ERR-1).
    var result = try runWithGrants(&.{"variable:read"}, "platform.read_variable()");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "invalid argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "must be a string") != null);
}

test "TC-LUA-05: now and fail are ungated BY DESIGN" {
    // Empty capability set. Both must work: platform.now() is a pure time read
    // and a script may always terminate itself (design §3.2).
    var now_result = try runWithGrants(&.{}, "return platform.now()");
    defer now_result.deinit(std.testing.allocator);
    try std.testing.expect(now_result.success);
    const now_value = now_result.value orelse return error.NoValue;
    try std.testing.expect(now_value == .string);
    // ISO 8601 UTC: YYYY-MM-DDTHH:MM:SS.sssZ
    try std.testing.expectEqual(@as(usize, 24), now_value.string.len);
    try std.testing.expect(std.mem.endsWith(u8, now_value.string, "Z"));

    // platform.fail raises with the reason, and NOT a capability denial.
    var fail_result = try runWithGrants(&.{}, "platform.fail('budget exceeded')");
    defer fail_result.deinit(std.testing.allocator);
    try std.testing.expect(!fail_result.success);
    const fail_msg = fail_result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, fail_msg, "budget exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_msg, "capability denied") == null);
}

test "TC-LUA-05-01..06: exactly the eight Architecture 5.2 functions are registered" {
    var result = try runWithGrants(&.{},
        \\local names = {'call_service','read_variable','write_variable','log',
        \\               'emit_event','get_instance_state','now','fail'}
        \\for _, n in ipairs(names) do
        \\  if type(platform[n]) ~= 'function' then return 'MISSING:' .. n end
        \\end
        \\local count = 0
        \\for _ in pairs(platform) do count = count + 1 end
        \\if count ~= 8 then return 'COUNT:' .. count end
        \\if platform.undeclared_function ~= nil then return 'EXTRA' end
        \\return 'OK'
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("OK", value.string);
}

// ---------------------------------------------------------------------------
// LUA-03 / sandbox — now meaningful, because product and test share a state
// ---------------------------------------------------------------------------

test "ISS-0169: the base library is available through executeScript" {
    // Diagnosis E8: pairs, ipairs, pcall, error, type, tostring and
    // setmetatable were ALL absent from any script run through executeScript,
    // because loadSafeStdlib never called luaopen_base. No realistic script
    // could run, and no denial test could use pcall to observe a raise.
    var result = try runWithGrants(&.{},
        \\local names = {'pairs','ipairs','next','type','tostring','tonumber',
        \\               'pcall','xpcall','error','assert','select','unpack',
        \\               'rawequal','rawget','rawset','setmetatable',
        \\               'getmetatable'}
        \\for _, n in ipairs(names) do
        \\  if _G[n] == nil then return 'MISSING:' .. n end
        \\end
        \\if _G == nil then return 'MISSING:_G' end
        \\return 'OK'
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("OK", value.string);
}

test "ISS-0169: dangerous globals are pruned AFTER base is opened (SBX-1)" {
    // These assertions become meaningful for the first time here. Previously
    // the globals were absent because base was never opened; now they are
    // absent because they were deliberately pruned. Same assertion, real
    // evidence. If SBX-1 were ever inverted (prune before open), luaopen_base
    // would reinstall all of these and this test would go red.
    var result = try runWithGrants(&.{},
        \\local banned = {'load','loadstring','loadfile','dofile','require',
        \\                'getfenv','setfenv','collectgarbage','print',
        \\                'newproxy','module','ffi','io','os','package',
        \\                'debug','jit'}
        \\for _, n in ipairs(banned) do
        \\  if _G[n] ~= nil then return 'PRESENT:' .. n end
        \\end
        \\if string.dump ~= nil then return 'PRESENT:string.dump' end
        \\return 'OK'
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("OK", value.string);
}

// ---------------------------------------------------------------------------
// LUA-07 — manifest binding through the load-time entry point
// ---------------------------------------------------------------------------

test "TC-LUA-07: executeScriptWithManifest rejects a manifest bound to a different script" {
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("variable:read");

    const ctx = lua.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-instance",
        .actor_id = "iss0169-actor",
    };

    const registered_script = "return platform.read_variable('k')";
    const declared = [_][]const u8{"variable:read"};

    var m = try lua.manifest.validateManifest(
        &declared,
        &caps,
        100_000,
        8_388_608,
        30,
        registered_script,
        std.testing.allocator,
    );
    defer m.deinit();

    // The registered pairing executes and records the hash on the result.
    var ok = try lua.executeScriptWithManifest(&ctx, registered_script, &m, m.manifest_hash);
    defer ok.deinit(std.testing.allocator);
    try std.testing.expect(ok.success);
    const recorded = ok.manifest_hash orelse return error.NoManifestHash;
    try std.testing.expectEqualSlices(u8, &m.manifest_hash, &recorded);

    // The SAME manifest against a DIFFERENT script is rejected at load time —
    // before any Lua state is created, so nothing executes.
    try std.testing.expectError(
        lua.manifest.ManifestError.ManifestHashMismatch,
        lua.executeScriptWithManifest(&ctx, "return 'substituted'", &m, m.manifest_hash),
    );
}

test "TC-LUA-07: the plain executeScript path records no manifest hash" {
    var result = try runWithGrants(&.{}, "return 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    // executeScript performs no manifest verification, and says so honestly
    // rather than reporting a hash it never checked.
    try std.testing.expect(result.manifest_hash == null);
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

test "TC-LUA-EDGE-01: empty script executes without error" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;
    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L, ""));
    try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L, 0, 0, 0));
}

test "TC-LUA-EDGE-02: a very long script executes without buffer overflow" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    // ~6k of source: sum 1..500 via generated statements.
    var buf: [8192]u8 = undefined;
    var written: usize = 0;
    written += (try std.fmt.bufPrint(buf[written..], "local s = 0 ", .{})).len;
    var i: usize = 1;
    while (i <= 500) : (i += 1) {
        written += (try std.fmt.bufPrint(buf[written..], "s = s + {d} ", .{i})).len;
    }
    written += (try std.fmt.bufPrint(buf[written..], "return s", .{})).len;
    buf[written] = 0;

    const src: [*:0]const u8 = @ptrCast(&buf);
    try std.testing.expect(written > 5000);
    try std.testing.expectEqual(@as(f64, 125250), try evalNumber(L, src));
}

test "TC-LUA-EDGE-03: syntax error returns a clear error message" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;

    try std.testing.expectEqual(
        bindings.LUA_ERRSYNTAX,
        bindings.luaL_loadstring(L, "this is not valid lua"),
    );
    // LuaJIT leaves the message on the stack; it must be a non-empty string.
    try std.testing.expect(bindings.lua_isstring(L, -1) != 0);
    const msg = std.mem.span(bindings.lua_tostring(L, -1));
    try std.testing.expect(msg.len > 0);
    bindings.lua_pop(L, 1);
}

test "TC-LUA-EDGE-05: Unicode string literals compile and execute" {
    const sb = try sandboxedState();
    defer sb.deinit();
    const L = sb.L;
    // Lua strings are BYTE strings, so string.len returns the UTF-8 byte count,
    // not the codepoint count: 'héllo wörld' is 11 codepoints but 13 bytes
    // (é and ö are two bytes each). Asserting 13 documents the real semantics;
    // asserting 11 would encode a misunderstanding of Lua as a requirement.
    try std.testing.expectEqual(
        @as(f64, 13),
        try evalNumber(L, "return string.len('héllo wörld')"),
    );
}
