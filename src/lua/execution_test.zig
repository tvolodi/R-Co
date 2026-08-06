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

/// C-ABI allocator matching `lua_Alloc`.
fn luaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

/// A fresh state with the sandboxed stdlib applied, exactly as executeScript
/// builds it. Caller must `lua_close`.
fn sandboxedState() !*bindings.lua_State {
    const L = bindings.lua_newstate(luaAlloc, null) orelse return error.LuaStateAllocFailed;
    errdefer bindings.lua_close(L);
    _ = bindings.luaopen_base(L);
    try stdlib.loadSafeStdlib(L);
    return L;
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

    const L = try sandboxedState();
    defer bindings.lua_close(L);
    try std.testing.expectEqual(@as(f64, 42), try evalNumber(L, "return 6 * 7"));
}

// ---------------------------------------------------------------------------
// LUA-02 — State isolation per invocation
// ---------------------------------------------------------------------------

test "TC-LUA-02-01: first script sets a global, a second state does not see it" {
    {
        const L1 = try sandboxedState();
        defer bindings.lua_close(L1);
        try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L1, "leaked = 99 return 1"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L1, 0, 1, 0));
    }

    // A separate state must not observe the first one's global.
    const L2 = try sandboxedState();
    defer bindings.lua_close(L2);
    try std.testing.expect(try evalsToNil(L2, "return leaked"));
}

test "TC-LUA-02-03: state cleanup after script completes" {
    // Repeated create/destroy must neither leak state nor carry values across.
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const L = try sandboxedState();
        defer bindings.lua_close(L);
        try std.testing.expect(try evalsToNil(L, "return carried"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L, "carried = 1 return 1"));
        try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L, 0, 1, 0));
    }
}

// ---------------------------------------------------------------------------
// LUA-03 — Stdlib restriction (the security-critical sandbox)
// ---------------------------------------------------------------------------

test "TC-LUA-03-01/02/03: math, string and table are available and functional" {
    const L = try sandboxedState();
    defer bindings.lua_close(L);

    try std.testing.expectEqual(@as(f64, 4), try evalNumber(L, "return math.floor(4.7)"));
    try std.testing.expectEqual(@as(f64, 5), try evalNumber(L, "return string.len('hello')"));
    try std.testing.expectEqual(@as(f64, 3), try evalNumber(L, "return #({1,2,3})"));
    try std.testing.expectEqual(@as(f64, 6), try evalNumber(L,
        "local t = {1,2,3} local s = 0 for _,v in ipairs(t) do s = s + v end return s"));
}

test "TC-LUA-03-04..07: io, os, package and debug are NOT available" {
    const L = try sandboxedState();
    defer bindings.lua_close(L);

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
    const L = try sandboxedState();
    defer bindings.lua_close(L);

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
    const L = try sandboxedState();
    defer bindings.lua_close(L);

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
// Edge cases
// ---------------------------------------------------------------------------

test "TC-LUA-EDGE-01: empty script executes without error" {
    const L = try sandboxedState();
    defer bindings.lua_close(L);
    try std.testing.expectEqual(bindings.LUA_OK, bindings.luaL_loadstring(L, ""));
    try std.testing.expectEqual(bindings.LUA_OK, bindings.lua_pcall(L, 0, 0, 0));
}

test "TC-LUA-EDGE-02: a very long script executes without buffer overflow" {
    const L = try sandboxedState();
    defer bindings.lua_close(L);

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
    const L = try sandboxedState();
    defer bindings.lua_close(L);

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
    const L = try sandboxedState();
    defer bindings.lua_close(L);
    // Lua strings are BYTE strings, so string.len returns the UTF-8 byte count,
    // not the codepoint count: 'héllo wörld' is 11 codepoints but 13 bytes
    // (é and ö are two bytes each). Asserting 13 documents the real semantics;
    // asserting 11 would encode a misunderstanding of Lua as a requirement.
    try std.testing.expectEqual(
        @as(f64, 13),
        try evalNumber(L, "return string.len('héllo wörld')"),
    );
}
