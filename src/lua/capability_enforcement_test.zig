//! LUA-05 / LUA-06 / LUA-07 capability-enforcement tests (ISS-0169 / GH #495,
//! tranche 1) against a REAL, statically linked LuaJIT.
//!
//! ## Relationship to `execution_test.zig`
//!
//! `execution_test.zig` covers LUA-01..05 sandbox behaviour and the *aggregate*
//! capability claims ("with an EMPTY set every gated function is denied"). This
//! file covers the cases that specification `tests/specs/LUA-05.md`,
//! `LUA-06.md` and `LUA-07.md` require *per function* and *per invariant*, and
//! which an aggregate assertion cannot make:
//!
//! - **Per-function denial with a NON-EMPTY, WRONG grant set.** An empty grant
//!   set cannot distinguish "this gate checks the right capability" from "this
//!   gate refuses everything". Each of the six gated functions is therefore
//!   denied while holding a capability that belongs to a *different* function,
//!   and the denial message is asserted to name the required capability and to
//!   render the wrong grant that was actually held.
//! - **Fail-closed with no context installed (CAP-2).** Nothing else in the
//!   suite reaches a host function through a state whose registry entry is
//!   absent or is the wrong Lua type. This is the invariant that turns a
//!   plumbing failure into a total denial rather than a total bypass.
//! - **Cross-product non-interference.** Granting exactly one capability must
//!   open exactly one function and leave the other five shut. Six aggregate
//!   assertions cannot show that; a 6x6 matrix can.
//! - **LUA-07 through the load-time entry point**, including the
//!   `parseManifest` -> `executeScriptWithManifest` path the repository
//!   actually uses, and rejection *before any state is created*.
//!
//! ## ISS-0172 / GH #500 caveat, honoured deliberately
//!
//! A green `zig build test-lua` does NOT prove a file compiles: `src/lua_test_root.zig`
//! pins files with bare type references (`_ = Module.TypeName;`), which forces
//! neither field-type resolution nor function-body analysis — both limiters
//! carried hard compile errors THROUGH a green target for exactly that reason.
//! Every test below therefore CALLS real functions against a real `lua_State`
//! and asserts on observed output. Nothing here is satisfied by a type pin.
//!
//! ## DIRECTIVE T-1
//!
//! No mocks, no stubs, no in-memory fakes. Every assertion runs a real Lua
//! chunk through the real `executeScript` / `executeScriptWithManifest` against
//! the vendored LuaJIT (`vendor/luajit/`, ISS-0161). There are no credentials
//! of any kind in this file.

const std = @import("std");
const lua = @import("mod.zig");
const bindings = @import("luajit_bindings.zig");
const executor = @import("executor.zig");
const host_context = @import("host_context.zig");
const capabilities = @import("capabilities.zig");
const manifest = @import("manifest.zig");
const stdlib = @import("stdlib.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const memory_limiter = @import("memory_limiter.zig");
const timeout_ctx = @import("timeout.zig");

// ---------------------------------------------------------------------------
// Fixtures
//
// Every fixture is per-test and self-contained: a fresh CapabilitySet, a fresh
// ExecutionContext, a fresh lua_State. Nothing is shared across tests, so no
// test can observe another's state (the Zig analogue of the per-test-UUID rule
// for DB fixtures). std.testing.allocator fails any test that leaks.
// ---------------------------------------------------------------------------

/// The normative Architecture §5.2 capability matrix, design §3.2.
///
/// Adding a ninth host function without adding a row here is a defect: the
/// surface test below asserts the registered table has exactly
/// `GATED.len + UNGATED.len` entries.
const Gated = struct {
    /// The `platform.*` name a script author writes, which the denial message
    /// must contain.
    fn_name: []const u8,
    /// The exact canonical capability string the gate requires.
    capability: []const u8,
    /// A well-formed call: every argument is valid, so a failure can ONLY be
    /// the capability gate. A call with a bad argument would prove nothing
    /// about the gate.
    call: []const u8,
};

const GATED = [_]Gated{
    .{
        .fn_name = "call_service",
        .capability = "service:call:payment_svc",
        .call = "platform.call_service('payment_svc', 'POST', '/pay')",
    },
    .{
        .fn_name = "read_variable",
        .capability = capabilities.StandardCapabilities.VARIABLE_READ,
        .call = "platform.read_variable('amount')",
    },
    .{
        .fn_name = "write_variable",
        .capability = capabilities.StandardCapabilities.VARIABLE_WRITE,
        .call = "platform.write_variable('amount', 'v')",
    },
    .{
        .fn_name = "log",
        .capability = capabilities.StandardCapabilities.AUDIT_LOG,
        .call = "platform.log('info', 'hello')",
    },
    .{
        .fn_name = "emit_event",
        .capability = capabilities.StandardCapabilities.EVENT_EMIT,
        .call = "platform.emit_event('APPROVED', {})",
    },
    .{
        .fn_name = "get_instance_state",
        .capability = capabilities.StandardCapabilities.INSTANCE_READ,
        .call = "platform.get_instance_state()",
    },
};

/// The two functions that are ungated BY DESIGN (design §3.2). `now` is a pure
/// time read with no state reach (LUA-14) and a script may always terminate
/// itself (LUA-15). A test that expects a gate on either is reading the matrix
/// wrong — which is why they are listed rather than merely omitted.
const UNGATED = [_][]const u8{ "now", "fail" };

/// Run `src` through the real `executeScript` with exactly `grants` granted.
/// Caller deinits the result.
///
/// CTX-1: `caps` and `ctx` live in this frame and `executeScript` closes its
/// state before returning, so the context strictly outlives the `lua_State`.
fn runWithGrants(grants: []const []const u8, src: []const u8) !lua.ScriptResult {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    for (grants) |g| try caps.add(g);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-cap-instance",
        .actor_id = "iss0169-cap-actor",
    };
    return executor.executeScript(&ctx, src);
}

/// Assert that `result` is a capability denial naming `fn_name` and `required`.
fn expectDenied(result: lua.ScriptResult, fn_name: []const u8, required: []const u8) !void {
    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;

    // LUA-06: the raised error carries the function name, the capability
    // required, and the capabilities granted.
    try std.testing.expect(std.mem.indexOf(u8, msg, "capability denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, fn_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, required) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "granted:") != null);

    // ERR-1 regression guard: before ISS-0169, `lua_error` was called with
    // nothing pushed, so the message was whatever happened to sit on the stack
    // top — the diagnosis observed '1.0954944061662e-311' (uninitialised
    // memory). A message that does not start with the §4.2 prefix is that bug
    // returning.
    try std.testing.expect(std.mem.startsWith(u8, msg, "capability denied: platform."));
}

// ---------------------------------------------------------------------------
// TC-LUA-06-D01..D06 — per-function denial with a NON-EMPTY, WRONG grant set
//
// The aggregate empty-set test in execution_test.zig cannot distinguish a gate
// that checks the RIGHT capability from a gate that refuses everything. These
// six hold a real capability belonging to a DIFFERENT function and must still
// be denied, with the held grant rendered in the message.
// ---------------------------------------------------------------------------

test "TC-LUA-06-D01..D06: every gated function is denied while holding a wrong capability" {
    for (GATED, 0..) |target, i| {
        // Hold the capability of the NEXT function in the matrix — always a
        // real, non-empty grant, and never the one this function needs.
        const wrong = GATED[(i + 1) % GATED.len].capability;
        try std.testing.expect(!std.mem.eql(u8, wrong, target.capability));

        var result = try runWithGrants(&.{wrong}, target.call);
        defer result.deinit(std.testing.allocator);

        try expectDenied(result, target.fn_name, target.capability);

        // The granted set is rendered, so the denial is diagnosable rather than
        // merely fatal — and it is NOT "(none)", which would mean the gate had
        // not actually read the context it was handed.
        const msg = result.error_message.?;
        try std.testing.expect(std.mem.indexOf(u8, msg, wrong) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "(none)") == null);
    }
}

// ---------------------------------------------------------------------------
// TC-LUA-06-D07 — cross-product non-interference
//
// Granting exactly one capability must open exactly ONE function and leave the
// other five shut. Six independent aggregate assertions cannot demonstrate
// this; the 6x6 matrix can. This is the generalisation of the design's
// "variable:read must not open write_variable".
// ---------------------------------------------------------------------------

test "TC-LUA-06-D07: a single grant opens exactly one function and no other" {
    for (GATED) |granted| {
        for (GATED) |target| {
            var result = try runWithGrants(&.{granted.capability}, target.call);
            defer result.deinit(std.testing.allocator);

            if (std.mem.eql(u8, granted.capability, target.capability)) {
                // The gate must not be a blanket refusal. (The bodies remain
                // unimplemented — LUA-11/12/13 — so "proceeds" means "did not
                // raise", which is exactly the claim this tranche makes.)
                if (!result.success) {
                    std.debug.print(
                        "unexpected denial: {s} with its own grant {s}: {s}\n",
                        .{ target.fn_name, granted.capability, result.error_message orelse "(no message)" },
                    );
                }
                try std.testing.expect(result.success);
            } else {
                try expectDenied(result, target.fn_name, target.capability);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// TC-LUA-06-D08/D09 — fail-closed (invariant CAP-2, design §3.4)
//
// Absence of information is DENIAL. These drive a host function through a state
// whose registry entry has been removed or replaced with the wrong Lua type —
// the two conditions under which `contextFromState` returns null. Nothing else
// in the suite reaches this path, and it is the invariant that turns a plumbing
// failure into a total denial rather than a total bypass.
//
// The registry is not script-reachable (design §2.2), so these tests tamper
// with it from ZIG, through the same C API a future plumbing bug would break.
// That is the realistic failure mode: not a malicious script, but an
// installContext that silently did not land.
// ---------------------------------------------------------------------------

/// Build a real sandboxed state, then remove the context from the registry and
/// run `src` under `lua_pcall`. Returns the error message LuaJIT left on the
/// stack, copied into `out`.
fn runWithoutContext(out: []u8, src: [*:0]const u8, replacement: enum { absent, wrong_type }) ![]const u8 {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    // A FULL grant set: if the call is refused, it can only be because the
    // context was unreadable — never because a capability was missing.
    for (GATED) |g| try caps.add(g.capability);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-failclosed-instance",
        .actor_id = "iss0169-failclosed-actor",
    };

    const limits = executor.RunLimits{
        .max_instructions = manifest.Limits.MAX_INSTRUCTIONS,
        .max_memory_bytes = manifest.Limits.MAX_MEMORY_BYTES,
        .timeout_seconds = manifest.Limits.MAX_TIMEOUT_SECONDS,
    };
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(std.testing.allocator, limits.max_instructions),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(std.testing.allocator, limits.max_memory_bytes);

    const L = try executor.createSandboxedState(&ctx, limits, &limiter_storage, &mem_limiter_storage);
    defer bindings.lua_close(L);

    // Sanity: the context IS installed and readable before we break it.
    try std.testing.expect(host_context.contextFromState(L) != null);

    switch (replacement) {
        // The key is absent — installContext never ran, or ran against a
        // different state.
        .absent => bindings.lua_pushnil(L),
        // The key holds something that is not a light userdata — the registry
        // slot was reused or overwritten by unrelated plumbing.
        .wrong_type => bindings.lua_pushnumber(L, 1),
    }
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, host_context.REGISTRY_KEY);

    // contextFromState must now report null. That is the DECISION INPUT; the
    // assertions below check the decision the gate makes from it.
    try std.testing.expect(host_context.contextFromState(L) == null);

    if (bindings.luaL_loadstring(L, src) != bindings.LUA_OK) return error.CompileFailed;
    const status = bindings.lua_pcall(L, 0, 1, 0);

    // The call MUST have failed. A success here is the E9 bypass returning in
    // its worst form: no context, and the body ran anyway.
    if (status == bindings.LUA_OK) return error.CallSucceededWithoutContext;

    var len: usize = 0;
    const ptr = bindings.lua_tolstring(L, -1, &len);
    const msg = ptr[0..len];
    if (msg.len > out.len) return error.MessageTooLong;
    @memcpy(out[0..msg.len], msg);
    bindings.lua_pop(L, 1);
    return out[0..msg.len];
}

test "TC-LUA-06-D08: an ABSENT context denies every gated function (CAP-2)" {
    var buf: [1024]u8 = undefined;
    for (GATED) |g| {
        // The call sources are comptime string literals in GATED; a NUL
        // terminated copy is needed for luaL_loadstring.
        var src_buf: [256]u8 = undefined;
        @memcpy(src_buf[0..g.call.len], g.call);
        src_buf[g.call.len] = 0;
        const src: [*:0]const u8 = @ptrCast(&src_buf);

        const msg = try runWithoutContext(&buf, src, .absent);

        // Fail-closed renders the SAME §4.2 shape as a normal denial, with an
        // explicit "(none)" granted set — so a single format serves both and a
        // test cannot be fooled by a differently-shaped message.
        try std.testing.expect(std.mem.startsWith(u8, msg, "capability denied: platform."));
        try std.testing.expect(std.mem.indexOf(u8, msg, g.fn_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, g.capability) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "(none)") != null);
    }
}

test "TC-LUA-06-D09: a WRONG-TYPE registry entry denies too, it does not allow" {
    var buf: [1024]u8 = undefined;
    // read_variable is representative: the gate is the shared
    // host_context.requireCapability, so the type check is identical for all six.
    const msg = try runWithoutContext(&buf, "platform.read_variable('k')", .wrong_type);

    try std.testing.expect(std.mem.startsWith(u8, msg, "capability denied: platform."));
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "variable:read") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(none)") != null);
}

// ---------------------------------------------------------------------------
// TC-LUA-05-S01/S02 — the sandbox surface is EXACTLY the eight designed
// functions, and no undeclared function is reachable (LUA-05 acceptance
// criterion 2).
// ---------------------------------------------------------------------------

test "TC-LUA-05-S01: the platform table holds exactly the designed functions and nothing else" {
    // Enumerate the table from Lua and compare against the matrix, so an
    // accidental ninth registration fails here rather than shipping. Building
    // the expected-name list from GATED/UNGATED means the test cannot drift
    // from the normative matrix.
    const a = std.testing.allocator;
    var script = std.ArrayList(u8).empty;
    defer script.deinit(a);

    try script.appendSlice(a, "local expected = {");
    for (GATED) |g| {
        try script.appendSlice(a, "['");
        try script.appendSlice(a, g.fn_name);
        try script.appendSlice(a, "']=true,");
    }
    for (UNGATED) |name| {
        try script.appendSlice(a, "['");
        try script.appendSlice(a, name);
        try script.appendSlice(a, "']=true,");
    }
    try script.appendSlice(a,
        \\}
        \\if type(platform) ~= 'table' then return 'NO_PLATFORM_TABLE' end
        \\-- every expected name must be present AND be a function
        \\for name in pairs(expected) do
        \\  if type(platform[name]) ~= 'function' then return 'MISSING:' .. name end
        \\end
        \\-- and nothing else may be present
        \\for name, v in pairs(platform) do
        \\  if not expected[name] then return 'UNDECLARED:' .. name end
        \\  if type(v) ~= 'function' then return 'NOT_A_FUNCTION:' .. name end
        \\end
        \\return 'OK'
    );

    var result = try runWithGrants(&.{}, script.items);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("OK", value.string);
}

test "TC-LUA-05-S02: an undeclared platform function is nil and calling it raises" {
    var probe = try runWithGrants(&.{},
        \\if platform.undeclared_function ~= nil then return 'PRESENT' end
        \\if platform.exec ~= nil then return 'PRESENT:exec' end
        \\if platform.read_file ~= nil then return 'PRESENT:read_file' end
        \\return 'ABSENT'
    );
    defer probe.deinit(std.testing.allocator);
    try std.testing.expect(probe.success);
    try std.testing.expectEqualStrings("ABSENT", (probe.value orelse return error.NoValue).string);

    // Absent means absent: calling it is a runtime error, not a silent no-op
    // that a caller could mistake for a successful privileged operation.
    var called = try runWithGrants(&.{}, "return platform.undeclared_function()");
    defer called.deinit(std.testing.allocator);
    try std.testing.expect(!called.success);
    try std.testing.expect(called.error_message != null);
}

// ---------------------------------------------------------------------------
// TC-LUA-05-S03 — SBX-1: dangerous globals are absent AFTER luaopen_base
//
// This is the ORDERING invariant, not merely an absence check. Before ISS-0169,
// `luaopen_base` was never called, so `load`/`loadstring`/`loadfile`/`dofile`
// were absent for the wrong reason and the removal code guarded a door that was
// not open. The proof that the ordering is right is that base's SAFE members
// are present in the SAME state where the dangerous ones are gone: if the prune
// ran before the open, base would have reinstalled everything and the dangerous
// names would be back; if base were never opened, the safe names would be
// missing.
// ---------------------------------------------------------------------------

test "TC-LUA-05-S03: base is opened AND pruned — safe globals present, loaders gone (SBX-1)" {
    var result = try runWithGrants(&.{},
        \\-- (a) base WAS opened: these only exist if luaopen_base ran.
        \\local safe = {'pairs','ipairs','next','type','tostring','tonumber',
        \\              'pcall','xpcall','error','assert','select','unpack',
        \\              'rawequal','rawget','rawset','setmetatable','getmetatable'}
        \\for _, n in ipairs(safe) do
        \\  if _G[n] == nil then return 'BASE_NOT_OPENED:' .. n end
        \\end
        \\if _G == nil then return 'BASE_NOT_OPENED:_G' end
        \\if _VERSION == nil then return 'BASE_NOT_OPENED:_VERSION' end
        \\
        \\-- (b) and the dangerous members it installs were pruned AFTER.
        \\local banned = {'load','loadstring','loadfile','dofile','require',
        \\                'getfenv','setfenv','collectgarbage','print',
        \\                'newproxy','module','ffi','io','os','package',
        \\                'debug','jit','bit','coroutine'}
        \\for _, n in ipairs(banned) do
        \\  if _G[n] ~= nil then return 'NOT_PRUNED:' .. n end
        \\end
        \\if string.dump ~= nil then return 'NOT_PRUNED:string.dump' end
        \\return 'OK'
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    // A failure message here says WHICH invariant broke: BASE_NOT_OPENED means
    // §5.2's open was lost; NOT_PRUNED means SBX-1 was inverted.
    try std.testing.expectEqualStrings("OK", value.string);
}

test "TC-LUA-05-S04: a pruned loader cannot be reached through any surviving alias" {
    // The prune sets the globals to nil. Verify there is no second route to the
    // same functions: not via _G indexing, not via string.dump, not via a
    // metatable on _G that some future change might add.
    var result = try runWithGrants(&.{},
        \\if _G['load'] ~= nil then return 'VIA_G:load' end
        \\if _G['loadstring'] ~= nil then return 'VIA_G:loadstring' end
        \\if rawget(_G, 'load') ~= nil then return 'VIA_RAWGET:load' end
        \\if getmetatable(_G) ~= nil then return 'G_HAS_METATABLE' end
        \\local ok = pcall(function() return loadstring('return 1')() end)
        \\if ok then return 'LOADSTRING_CALLABLE' end
        \\return 'OK'
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("OK", (result.value orelse return error.NoValue).string);
}

// ---------------------------------------------------------------------------
// TC-LUA-07-M01..M05 — manifest binding through the LOAD-TIME entry point
//
// manifest.zig's in-file tests cover the hash function in isolation. These
// cover the entry point the repository actually calls, including the property
// that a rejection happens BEFORE any state is created — i.e. that a tampered
// pairing never executes a single instruction.
// ---------------------------------------------------------------------------

/// A manifest fixture bound to `script`. Caller deinits.
fn manifestFor(
    caps: *const capabilities.CapabilitySet,
    declared: []const []const u8,
    script: []const u8,
) !manifest.ScriptManifest {
    return manifest.validateManifest(
        declared,
        caps,
        100_000,
        8_388_608,
        30,
        script,
        std.testing.allocator,
    );
}

test "TC-LUA-07-M01: the registered pairing executes and records the verified hash" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add(capabilities.StandardCapabilities.VARIABLE_READ);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-manifest-instance",
        .actor_id = "iss0169-manifest-actor",
    };

    const script = "platform.read_variable('amount') return 'ran'";
    const declared = [_][]const u8{capabilities.StandardCapabilities.VARIABLE_READ};

    var m = try manifestFor(&caps, &declared, script);
    defer m.deinit();

    var result = try executor.executeScriptWithManifest(&ctx, script, &m, m.manifest_hash);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ran", (result.value orelse return error.NoValue).string);

    // LUA-07 acceptance criterion 2: the hash is recorded ON THE RESULT, which
    // is what the engine persists into the audit record. src/lua/ produces the
    // value and performs no I/O (design §6.4).
    const recorded = result.manifest_hash orelse return error.NoManifestHash;
    try std.testing.expectEqualSlices(u8, &m.manifest_hash, &recorded);
}

test "TC-LUA-07-M02: a manifest modified after registration is rejected at load time" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add(capabilities.StandardCapabilities.VARIABLE_READ);
    try caps.add(capabilities.StandardCapabilities.AUDIT_LOG);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-tamper-instance",
        .actor_id = "iss0169-tamper-actor",
    };

    const script = "return 'unchanged'";
    const declared = [_][]const u8{capabilities.StandardCapabilities.VARIABLE_READ};

    var registered = try manifestFor(&caps, &declared, script);
    defer registered.deinit();
    const registered_hash = registered.manifest_hash;

    // (a) A manifest that gained a capability after registration. The grant is
    //     legitimately held, so this is NOT caught by validateManifest — only
    //     the hash binding catches it. That is the whole point of LUA-07.
    const widened = [_][]const u8{
        capabilities.StandardCapabilities.VARIABLE_READ,
        capabilities.StandardCapabilities.AUDIT_LOG,
    };
    var widened_m = try manifestFor(&caps, &widened, script);
    defer widened_m.deinit();
    try std.testing.expectError(
        manifest.ManifestError.ManifestHashMismatch,
        executor.executeScriptWithManifest(&ctx, script, &widened_m, registered_hash),
    );

    // (b) A manifest whose limits were raised after registration.
    var raised = registered;
    raised.max_instructions = 200_000;
    try std.testing.expectError(
        manifest.ManifestError.ManifestHashMismatch,
        executor.executeScriptWithManifest(&ctx, script, &raised, registered_hash),
    );

    // (c) The registered manifest paired with a SUBSTITUTED script.
    try std.testing.expectError(
        manifest.ManifestError.ManifestHashMismatch,
        executor.executeScriptWithManifest(&ctx, "return 'substituted'", &registered, registered_hash),
    );

    // (d) The untampered pairing still verifies — so (a)-(c) failed for the
    //     right reason and not because verification rejects everything.
    var ok = try executor.executeScriptWithManifest(&ctx, script, &registered, registered_hash);
    defer ok.deinit(std.testing.allocator);
    try std.testing.expect(ok.success);
}

test "TC-LUA-07-M03: rejection happens BEFORE any script instruction runs" {
    // A script with an OBSERVABLE side effect: if it ran at all, it would have
    // to raise (no capabilities are granted), and a raise surfaces as a FAILED
    // ScriptResult rather than a Zig error. Receiving the Zig error
    // ManifestHashMismatch therefore proves execution never began — the design
    // §6.4 ordering claim, checked rather than assumed.
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add(capabilities.StandardCapabilities.VARIABLE_READ);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-order-instance",
        .actor_id = "iss0169-order-actor",
    };

    const registered_script = "return 'clean'";
    const declared = [_][]const u8{capabilities.StandardCapabilities.VARIABLE_READ};
    var m = try manifestFor(&caps, &declared, registered_script);
    defer m.deinit();

    const hostile = "platform.write_variable('leaked', 'yes') return 'RAN'";
    try std.testing.expectError(
        manifest.ManifestError.ManifestHashMismatch,
        executor.executeScriptWithManifest(&ctx, hostile, &m, m.manifest_hash),
    );

    // Bytecode is rejected FIRST (design §6.4 step 1), before any manifest work,
    // so a bytecode artifact can never be validated into acceptance. It reports
    // as a failed ScriptResult, not as a hash mismatch.
    var bytecode_result = try executor.executeScriptWithManifest(
        &ctx,
        "\x1bLua\x51\x00",
        &m,
        m.manifest_hash,
    );
    defer bytecode_result.deinit(std.testing.allocator);
    try std.testing.expect(!bytecode_result.success);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytecode_result.error_message orelse return error.NoErrorMessage,
        "Bytecode",
    ) != null);
}

test "TC-LUA-07-M04: parseManifest feeds the load-time path end to end" {
    // The repository stores the manifest in its serialised JSON form (design
    // §6.2). This is the real path: parse -> validate -> verify -> execute.
    // Nothing is scraped from the script text; the manifest is caller-supplied.
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add(capabilities.StandardCapabilities.VARIABLE_READ);
    try caps.add(capabilities.StandardCapabilities.AUDIT_LOG);

    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-parse-instance",
        .actor_id = "iss0169-parse-actor",
    };

    const script = "platform.log('info', 'audited') return 'done'";

    var parsed = try manifest.parseManifest(std.testing.allocator,
        \\{"capabilities":["audit:log","variable:read"],
        \\ "max_instructions":100000,"max_memory_bytes":8388608,"timeout_seconds":30}
    );
    defer parsed.deinit();

    // parseManifest leaves manifest_hash zeroed: a hash is only meaningful
    // against a specific artifact, which parsing does not have.
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &parsed.manifest_hash);

    const registered_hash = try manifest.computeManifestHash(
        std.testing.allocator,
        parsed.capabilities,
        parsed.max_instructions,
        parsed.max_memory_bytes,
        parsed.timeout_seconds,
        script,
    );

    var result = try executor.executeScriptWithManifest(&ctx, script, &parsed, registered_hash);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("done", (result.value orelse return error.NoValue).string);
    try std.testing.expectEqualSlices(u8, &registered_hash, &(result.manifest_hash orelse return error.NoManifestHash));

    // A manifest declaring MORE than the deployment granted is rejected by
    // validateManifest, and — because the hash covers the capability list —
    // never reaches it with a matching hash either.
    var over = try manifest.parseManifest(std.testing.allocator,
        \\{"capabilities":["audit:log","variable:read","variable:write"],
        \\ "max_instructions":100000,"max_memory_bytes":8388608,"timeout_seconds":30}
    );
    defer over.deinit();
    const over_hash = try manifest.computeManifestHash(
        std.testing.allocator,
        over.capabilities,
        over.max_instructions,
        over.max_memory_bytes,
        over.timeout_seconds,
        script,
    );
    try std.testing.expectError(
        manifest.ManifestError.UnauthorizedCapability,
        executor.executeScriptWithManifest(&ctx, script, &over, over_hash),
    );
}

test "TC-LUA-07-M05: canonical hashing — order-independent, separator-safe, script-bound" {
    const a = std.testing.allocator;
    const script = "return 1";

    // (1) Declaration order must NOT change the hash: the canonical form sorts
    //     the capability strings (design §6.3 step 1).
    const forward = [_][]const u8{ "audit:log", "event:emit", "variable:read" };
    const reversed = [_][]const u8{ "variable:read", "event:emit", "audit:log" };
    const h_forward = try manifest.computeManifestHash(a, &forward, 100_000, 8_388_608, 30, script);
    const h_reversed = try manifest.computeManifestHash(a, &reversed, 100_000, 8_388_608, 30, script);
    try std.testing.expectEqualSlices(u8, &h_forward, &h_reversed);

    // Sorting must not mutate the caller's slice as a side effect.
    try std.testing.expectEqualStrings("audit:log", forward[0]);
    try std.testing.expectEqualStrings("variable:read", reversed[0]);

    // (2) The 0x00 separator removes the concatenation ambiguity: without it,
    //     ["ab","c"] and ["a","bc"] both hash "abc" and collide, so two
    //     DIFFERENT capability sets would share one registration hash.
    const ab_c = [_][]const u8{ "ab", "c" };
    const a_bc = [_][]const u8{ "a", "bc" };
    const h_ab_c = try manifest.computeManifestHash(a, &ab_c, 100_000, 8_388_608, 30, script);
    const h_a_bc = try manifest.computeManifestHash(a, &a_bc, 100_000, 8_388_608, 30, script);
    try std.testing.expect(!std.mem.eql(u8, &h_ab_c, &h_a_bc));

    // (3) The hash BINDS the manifest to the artifact: the same manifest over a
    //     different script must hash differently, or a manifest could be paired
    //     with any script undetected (design §6.1 defect 1).
    const same_caps = [_][]const u8{"variable:read"};
    const h_s1 = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 30, "return 1");
    const h_s2 = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 30, "return 2");
    try std.testing.expect(!std.mem.eql(u8, &h_s1, &h_s2));

    // A one-BYTE difference in the script is enough.
    const h_s3 = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 30, "return 1 ");
    try std.testing.expect(!std.mem.eql(u8, &h_s1, &h_s3));

    // (4) Each limit participates: changing any one changes the hash.
    const h_base = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 30, script);
    const h_instr = try manifest.computeManifestHash(a, &same_caps, 100_001, 8_388_608, 30, script);
    const h_mem = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_609, 30, script);
    const h_timeout = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 31, script);
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_instr));
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_mem));
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_timeout));

    // (5) And it is deterministic: identical input, identical output.
    const h_again = try manifest.computeManifestHash(a, &same_caps, 100_000, 8_388_608, 30, script);
    try std.testing.expectEqualSlices(u8, &h_base, &h_again);
}

// ---------------------------------------------------------------------------
// TC-LUA-06-D10 — the denial is observable by the script itself
//
// LUA-06's semantics are "raises a Lua error". A raise that a script cannot
// catch is indistinguishable from a hard abort, and a nil return would be
// indistinguishable from a successful read of an absent variable — which is
// exactly the ambiguity E9 hid behind. Catching it does NOT grant the
// capability, which is the property asserted here.
// ---------------------------------------------------------------------------

test "TC-LUA-06-D10: a script can pcall its own denial without gaining the capability" {
    var result = try runWithGrants(&.{capabilities.StandardCapabilities.VARIABLE_READ},
        \\-- first call: denied (no variable:write)
        \\local ok1, err1 = pcall(function() platform.write_variable('k', 'v') end)
        \\if ok1 then return 'FIRST_NOT_DENIED' end
        \\-- catching the error must not have opened the gate: retry is denied too
        \\local ok2, err2 = pcall(function() platform.write_variable('k', 'v') end)
        \\if ok2 then return 'SECOND_NOT_DENIED' end
        \\-- and the granted function still works, so the state is not poisoned
        \\platform.read_variable('k')
        \\return err1
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try std.testing.expect(value == .string);
    try std.testing.expect(std.mem.indexOf(u8, value.string, "capability denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.string, "write_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.string, "variable:write") != null);
    // The message renders the grant actually held.
    try std.testing.expect(std.mem.indexOf(u8, value.string, "variable:read") != null);
}

// ---------------------------------------------------------------------------
// TC-LUA-06-D11 — call_service's per-call capability (design §3.3)
//
// The one function whose required capability depends on an argument. Three
// distinct properties: exact matching (no wildcards in this tranche), argument
// errors distinguishable from denials, and no truncation of an over-long id.
// ---------------------------------------------------------------------------

test "TC-LUA-06-D11: call_service is gated per service id, exactly and without truncation" {
    // (a) Exact match only. Holding service:call:payment_svc must not open
    //     shipping_svc — `has()` is exact string containment and
    //     `service:call:*` is NOT honoured in this tranche (design §3.3).
    const grants = [_][]const u8{"service:call:payment_svc"};

    var allowed = try runWithGrants(&grants, "platform.call_service('payment_svc','POST','/pay')");
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.success);

    var denied = try runWithGrants(&grants, "platform.call_service('shipping_svc','POST','/ship')");
    defer denied.deinit(std.testing.allocator);
    try expectDenied(denied, "call_service", "service:call:shipping_svc");
    // The bare svc_id appears too, per the LUA-06 spec's message requirement.
    try std.testing.expect(std.mem.indexOf(u8, denied.error_message.?, "shipping_svc") != null);

    // (b) A wildcard grant does NOT open anything — it is a literal string that
    //     matches only a service literally named "*".
    var wildcard = try runWithGrants(&.{"service:call:*"}, "platform.call_service('payment_svc','POST','/pay')");
    defer wildcard.deinit(std.testing.allocator);
    try expectDenied(wildcard, "call_service", "service:call:payment_svc");

    // (c) A prefix of a granted id must not match: truncation or prefix
    //     matching here would be privilege escalation, not a convenience.
    var prefix = try runWithGrants(&.{"service:call:payment"}, "platform.call_service('payment_svc','POST','/pay')");
    defer prefix.deinit(std.testing.allocator);
    try expectDenied(prefix, "call_service", "service:call:payment_svc");

    // (d) A missing or non-string svc_id is an ARGUMENT error, not a denial —
    //     a test must be able to tell the two apart (design §3.3).
    var bad_arg = try runWithGrants(&grants, "platform.call_service(42,'POST','/pay')");
    defer bad_arg.deinit(std.testing.allocator);
    try std.testing.expect(!bad_arg.success);
    const bad_msg = bad_arg.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.startsWith(u8, bad_msg, "invalid argument: platform."));
    try std.testing.expect(std.mem.indexOf(u8, bad_msg, "call_service") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_msg, "capability denied") == null);
}

test "TC-LUA-06-D12: an over-long service id is rejected, never truncated into a match" {
    // Grant a SHORT id that an over-long id would collide with if the
    // capability string were truncated to the buffer size. Truncating here
    // could make a long id match a shorter grant — privilege escalation, not a
    // diagnostic inconvenience (design §3.3, host_context.serviceCallCapability).
    const short_id = "a" ** 8;
    var grant_buf: [64]u8 = undefined;
    const grant = try std.fmt.bufPrint(&grant_buf, "service:call:{s}", .{short_id});

    const a = std.testing.allocator;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(a);
    try src.appendSlice(a, "platform.call_service('");
    try src.appendNTimes(a, 'a', host_context.MAX_SVC_ID_BYTES + 1);
    try src.appendSlice(a, "','POST','/x')");

    var result = try runWithGrants(&.{grant}, src.items);
    defer result.deinit(std.testing.allocator);

    // It must FAIL. Whether as an argument error (the design's prescribed
    // response) it must never succeed, and must never be reported as a denial
    // of the truncated capability.
    try std.testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.startsWith(u8, msg, "invalid argument: platform."));
    try std.testing.expect(std.mem.indexOf(u8, msg, "call_service") != null);

    // The direct unit-level check of the same rule, so the reason is explicit:
    // an over-long id yields null rather than a truncated string.
    var cap_buf: [host_context.SERVICE_CAP_BUFFER_BYTES]u8 = undefined;
    const too_long = [_]u8{'a'} ** (host_context.MAX_SVC_ID_BYTES + 1);
    try std.testing.expect(host_context.serviceCallCapability(&cap_buf, &too_long) == null);
    // A legal id at exactly the maximum still builds.
    const at_max = [_]u8{'a'} ** host_context.MAX_SVC_ID_BYTES;
    try std.testing.expect(host_context.serviceCallCapability(&cap_buf, &at_max) != null);
}

// ---------------------------------------------------------------------------
// TC-LUA-05-S05 — the ungated pair, asserted as a POSITIVE design statement
// ---------------------------------------------------------------------------

test "TC-LUA-05-S05: now and fail are ungated by design and raise no capability error" {
    // Empty grant set. `now` is a pure time read with no state reach (LUA-14).
    var now_result = try runWithGrants(&.{}, "return platform.now()");
    defer now_result.deinit(std.testing.allocator);
    try std.testing.expect(now_result.success);
    const now_value = now_result.value orelse return error.NoValue;
    try std.testing.expect(now_value == .string);
    // ISO 8601 UTC, millisecond precision: YYYY-MM-DDTHH:MM:SS.sssZ
    try std.testing.expectEqual(@as(usize, 24), now_value.string.len);
    try std.testing.expect(std.mem.endsWith(u8, now_value.string, "Z"));

    // `fail` raises with the script's own reason — a script may always
    // terminate itself (LUA-15) — and NOT with a capability denial.
    var fail_result = try runWithGrants(&.{}, "platform.fail('policy rejected the request')");
    defer fail_result.deinit(std.testing.allocator);
    try std.testing.expect(!fail_result.success);
    const fail_msg = fail_result.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.indexOf(u8, fail_msg, "policy rejected the request") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_msg, "capability denied") == null);
}

// ---------------------------------------------------------------------------
// TC-LUA-05-S06 — CAP-1: the gate precedes argument validation and state touch
//
// A denied call must be indistinguishable from a call that never happened,
// other than by the error it raises. If argument validation ran first, a denied
// call with a bad argument would report an ARGUMENT error — leaking that the
// gate was never consulted, and (worse) implying the arguments were read.
// ---------------------------------------------------------------------------

test "TC-LUA-05-S06: a denied call reports the DENIAL even when its arguments are invalid (CAP-1)" {
    // No variable:write grant AND a numeric (invalid) key. The capability check
    // must win, because it runs first.
    var result = try runWithGrants(&.{capabilities.StandardCapabilities.VARIABLE_READ},
        "platform.write_variable(12345, 1)");
    defer result.deinit(std.testing.allocator);

    try expectDenied(result, "write_variable", capabilities.StandardCapabilities.VARIABLE_WRITE);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "invalid argument") == null);

    // With the grant present, the SAME call now reaches argument validation and
    // reports the argument error — proving the ordering rather than assuming
    // it, and confirming the argument check still exists (E11's coercion hole).
    var with_grant = try runWithGrants(&.{capabilities.StandardCapabilities.VARIABLE_WRITE},
        "platform.write_variable(12345, 1)");
    defer with_grant.deinit(std.testing.allocator);

    try std.testing.expect(!with_grant.success);
    const msg = with_grant.error_message orelse return error.NoErrorMessage;
    try std.testing.expect(std.mem.startsWith(u8, msg, "invalid argument: platform."));
    try std.testing.expect(std.mem.indexOf(u8, msg, "write_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "must be a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "capability denied") == null);
}
