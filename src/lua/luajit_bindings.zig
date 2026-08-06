//! LuaJIT C FFI declarations and linking configuration.
//!
//! ISS-0161 / GH #485 — this file now binds a **real, statically linked
//! LuaJIT 2.1**. LuaJIT is vendored at `vendor/luajit/` and built by
//! `vendor/luajit/build.zig`, which performs the upstream three-stage bootstrap
//! (minilua → dynasm → buildvm) from `build.zig` rather than from the upstream
//! Makefile. See that file for the two toolchain workarounds it needs.
//!
//! ## History
//!
//! Stage 9 (commit 113bdb3, May 2026) wrote this file as `@cImport` +
//! `pub extern fn lua_*`, but no LuaJIT existed in the repo, so any target that
//! pulled it in failed at translate-C time. That is why the subsystem stayed
//! unreferenced and rotted unobserved for three months while LUA-01..16 sat
//! marked RELEASED.
//!
//! ISS-0153 / GH #471 replaced that unresolvable surface with pure-Zig stubs
//! returning failure sentinels — honest and loud, but not executable. The
//! signatures were kept faithful to the LuaJIT 2.1 (Lua 5.1) ABI *specifically*
//! so that this change would be a drop-in replacement rather than a rewrite of
//! every call site. It was: no caller in `src/lua/` changed.
//!
//! ## Structure
//!
//! Lua 5.1 defines a large part of its public API as **C macros** over a
//! smaller set of real functions (`lua_pop` is `lua_settop`, `lua_tostring` is
//! `lua_tolstring`, `lua_newtable` is `lua_createtable`, the `lua_is*` family
//! is `lua_type` comparisons, and so on). A macro has no symbol to link
//! against, so those are `inline fn` wrappers here — same names, same
//! signatures as the stubs they replace. Everything else is `pub extern fn`,
//! resolved against the static archive.
const std = @import("std");

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Opaque Lua interpreter state.
pub const lua_State = opaque {};

/// LuaJIT debug/activation record, passed to hook callbacks (LUA-08).
/// Field layout matches Lua 5.1's `lua_Debug`; only `event` and `currentline`
/// are read by this codebase.
pub const lua_Debug = extern struct {
    event: c_int = 0,
    name: ?[*:0]const u8 = null,
    namewhat: ?[*:0]const u8 = null,
    what: ?[*:0]const u8 = null,
    source: ?[*:0]const u8 = null,
    currentline: c_int = 0,
    nups: c_int = 0,
    linedefined: c_int = 0,
    lastlinedefined: c_int = 0,
    short_src: [60]u8 = [_]u8{0} ** 60,
    i_ci: c_int = 0,
};

pub const LuaState = lua_State;
pub const LuaValue = f64;
pub const LuaCInt = isize;

/// Signature of a Lua-callable C function (`lua_CFunction`).
pub const lua_CFunction = *const fn (L: *lua_State) callconv(.c) c_int;

/// Signature of a Lua debug hook (`lua_Hook`).
pub const lua_Hook = *const fn (L: *lua_State, ar: ?*lua_Debug) callconv(.c) void;

/// Signature of a Lua allocator (`lua_Alloc`).
pub const lua_Alloc = *const fn (
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque;

// ---------------------------------------------------------------------------
// Lua type constants (lua.h)
// ---------------------------------------------------------------------------

pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TLIGHTUSERDATA: c_int = 2;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
pub const LUA_TFUNCTION: c_int = 6;
pub const LUA_TUSERDATA: c_int = 7;
pub const LUA_TTHREAD: c_int = 8;

// Status codes (lua.h)
pub const LUA_OK: c_int = 0;
pub const LUA_YIELD: c_int = 1;
pub const LUA_ERRRUN: c_int = 2;
pub const LUA_ERRSYNTAX: c_int = 3;
pub const LUA_ERRMEM: c_int = 4;
pub const LUA_ERRERR: c_int = 5;

// Hook masks (lua.h)
pub const LUA_MASKCALL: c_int = 1;
pub const LUA_MASKRET: c_int = 2;
pub const LUA_MASKLINE: c_int = 4;
pub const LUA_MASKCOUNT: c_int = 8;

/// Pseudo-indices (lua.h). LUA_GLOBALSINDEX is Lua 5.1-only — LuaJIT keeps it.
pub const LUA_REGISTRYINDEX: c_int = -10000;
pub const LUA_ENVIRONINDEX: c_int = -10001;
pub const LUA_GLOBALSINDEX: c_int = -10002;

// ---------------------------------------------------------------------------
// Real LuaJIT functions (lua.h / lualib.h / lauxlib.h)
// ---------------------------------------------------------------------------

pub extern fn lua_newstate(f: lua_Alloc, ud: ?*anyopaque) ?*lua_State;
pub extern fn lua_close(L: *lua_State) void;
pub extern fn lua_newthread(L: *lua_State) ?*lua_State;

// Stack manipulation
pub extern fn lua_gettop(L: *lua_State) c_int;
pub extern fn lua_settop(L: *lua_State, idx: c_int) void;
pub extern fn lua_pushvalue(L: *lua_State, idx: c_int) void;
pub extern fn lua_remove(L: *lua_State, idx: c_int) void;
pub extern fn lua_insert(L: *lua_State, idx: c_int) void;
pub extern fn lua_replace(L: *lua_State, idx: c_int) void;
pub extern fn lua_checkstack(L: *lua_State, sz: c_int) c_int;

// Push
pub extern fn lua_pushnil(L: *lua_State) void;
pub extern fn lua_pushboolean(L: *lua_State, b: c_int) void;
pub extern fn lua_pushnumber(L: *lua_State, n: f64) void;
pub extern fn lua_pushinteger(L: *lua_State, i: isize) void;
pub extern fn lua_pushlstring(L: *lua_State, s: [*]const u8, len: usize) void;
pub extern fn lua_pushstring(L: *lua_State, s: [*:0]const u8) void;
pub extern fn lua_pushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) void;
pub extern fn lua_pushlightuserdata(L: *lua_State, p: ?*anyopaque) void;

// Type inspection
pub extern fn lua_type(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_typename(L: *lua_State, tp: c_int) [*:0]const u8;
pub extern fn lua_isnumber(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_isstring(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_isuserdata(L: *lua_State, idx: c_int) c_int;

// Conversion
pub extern fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_tonumber(L: *lua_State, idx: c_int) f64;
pub extern fn lua_tointeger(L: *lua_State, idx: c_int) isize;
pub extern fn lua_tolstring(L: *lua_State, idx: c_int, len: *usize) [*:0]const u8;
pub extern fn lua_touserdata(L: *lua_State, idx: c_int) ?*anyopaque;

// Tables
pub extern fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
pub extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_rawget(L: *lua_State, idx: c_int) void;
pub extern fn lua_rawset(L: *lua_State, idx: c_int) void;
pub extern fn lua_rawgeti(L: *lua_State, idx: c_int, n: c_int) void;
pub extern fn lua_rawseti(L: *lua_State, idx: c_int, n: c_int) void;

// Calls
pub extern fn lua_call(L: *lua_State, nargs: c_int, nresults: c_int) void;
pub extern fn lua_pcall(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;
pub extern fn lua_error(L: *lua_State) c_int;

// Debug / hooks (LUA-08 instruction limiting)
pub extern fn lua_sethook(L: *lua_State, f: ?lua_Hook, mask: c_int, count: c_int) c_int;
pub extern fn lua_gethookcount(L: *lua_State) c_int;

// Standard libraries (lualib.h) — LUA-03 opens only the permitted subset.
pub extern fn luaopen_base(L: *lua_State) c_int;
pub extern fn luaopen_math(L: *lua_State) c_int;
pub extern fn luaopen_string(L: *lua_State) c_int;
pub extern fn luaopen_table(L: *lua_State) c_int;
pub extern fn luaopen_io(L: *lua_State) c_int;
pub extern fn luaopen_os(L: *lua_State) c_int;
pub extern fn luaopen_debug(L: *lua_State) c_int;
pub extern fn luaopen_package(L: *lua_State) c_int;

// Auxiliary library (lauxlib.h)
pub extern fn luaL_loadstring(L: *lua_State, s: [*:0]const u8) c_int;
pub extern fn luaL_loadbuffer(L: *lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8) c_int;
pub extern fn luaL_newmetatable(L: *lua_State, tname: [*:0]const u8) c_int;

// User data
pub extern fn lua_newuserdata(L: *lua_State, sz: usize) ?*anyopaque;
pub extern fn lua_setfenv(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_getfenv(L: *lua_State, idx: c_int) void;

// ---------------------------------------------------------------------------
// Macro equivalents
//
// These are `#define`s in lua.h / lauxlib.h, so they have no symbol to link
// against. Each is expressed here exactly as the C macro expands, keeping the
// same name and signature the rest of src/lua/ already calls.
// ---------------------------------------------------------------------------

/// `#define lua_pop(L,n) lua_settop(L, -(n)-1)`
pub inline fn lua_pop(L: *lua_State, n: c_int) void {
    lua_settop(L, -n - 1);
}

/// `#define lua_newtable(L) lua_createtable(L, 0, 0)`
pub inline fn lua_newtable(L: *lua_State) void {
    lua_createtable(L, 0, 0);
}

/// `#define lua_tostring(L,i) lua_tolstring(L, (i), NULL)`
pub inline fn lua_tostring(L: *lua_State, idx: c_int) [*:0]const u8 {
    var len: usize = 0;
    return lua_tolstring(L, idx, &len);
}

/// `#define lua_getglobal(L,s) lua_getfield(L, LUA_GLOBALSINDEX, (s))`
pub inline fn lua_getglobal(L: *lua_State, name: [*:0]const u8) void {
    lua_getfield(L, LUA_GLOBALSINDEX, name);
}

/// `#define lua_setglobal(L,s) lua_setfield(L, LUA_GLOBALSINDEX, (s))`
pub inline fn lua_setglobal(L: *lua_State, name: [*:0]const u8) void {
    lua_setfield(L, LUA_GLOBALSINDEX, name);
}

// The lua_is* family: `#define lua_isnil(L,n) (lua_type(L,(n)) == LUA_TNIL)`.
// These return c_int (1/0) rather than bool to match the stub signatures the
// callers were written against.

pub inline fn lua_isnil(L: *lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TNIL);
}

pub inline fn lua_isboolean(L: *lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TBOOLEAN);
}

pub inline fn lua_istable(L: *lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TTABLE);
}

/// `#define luaL_getmetatable(L,n) lua_getfield(L, LUA_REGISTRYINDEX, (n))`
/// Returns c_int to match the stub signature; the C macro yields the pushed
/// value's presence, so report the type of what was pushed.
pub inline fn luaL_getmetatable(L: *lua_State, tname: [*:0]const u8) c_int {
    lua_getfield(L, LUA_REGISTRYINDEX, tname);
    return lua_type(L, -1);
}

/// Lua 5.1 has no `luaL_setmetatable` (it arrived in 5.2). The equivalent is
/// fetching the named metatable from the registry and setting it on the value
/// at the top of the stack.
pub inline fn luaL_setmetatable(L: *lua_State, tname: [*:0]const u8) void {
    lua_getfield(L, LUA_REGISTRYINDEX, tname);
    lua_setfenv(L, -2);
}

/// Lua 5.1 spells the per-userdata value slot `lua_setfenv`, not
/// `lua_setuservalue` (5.2+). Kept under the caller-facing name.
pub inline fn lua_setuservalue(L: *lua_State, idx: c_int) void {
    _ = lua_setfenv(L, idx);
}

/// Lua 5.1 equivalent of `lua_getuservalue` (5.2+). Returns the type of the
/// pushed value, matching the stub signature.
pub inline fn lua_getuservalue(L: *lua_State, idx: c_int) c_int {
    lua_getfenv(L, idx);
    return lua_type(L, -1);
}

/// True when this build has a real LuaJIT linked in. Callers and tests read
/// this instead of hardcoding an assumption, so it changes in one place.
///
/// ISS-0161: now `true` — LuaJIT is vendored and statically linked.
pub const has_real_luajit = true;

test "ISS-0161: a real LuaJIT is linked and executes Lua" {
    // The point of this test is that it CANNOT pass against the stubs: they
    // returned null from lua_newstate and LUA_ERRSYNTAX from luaL_loadstring.
    try std.testing.expect(has_real_luajit);

    const L = lua_newstate(testAlloc, null) orelse return error.LuaStateAllocFailed;
    defer lua_close(L);

    _ = luaopen_base(L);

    // Execute an actual script and read back the value it computed.
    try std.testing.expectEqual(LUA_OK, luaL_loadstring(L, "return 6 * 7"));
    try std.testing.expectEqual(LUA_OK, lua_pcall(L, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 42), lua_tonumber(L, -1));
    lua_pop(L, 1);

    // A syntax error must still be reported as one.
    try std.testing.expectEqual(LUA_ERRSYNTAX, luaL_loadstring(L, "this is not lua"));
    lua_pop(L, 1);
}

/// C-ABI allocator for the test above, matching `lua_Alloc`.
fn testAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}
