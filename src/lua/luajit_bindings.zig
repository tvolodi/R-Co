//! LuaJIT C FFI declarations and linking configuration.
//!
//! ISS-0153 / GH #471 — the LuaJIT link decision, recorded here because this is
//! the file the decision is about.
//!
//! ## Why this file no longer `@cImport`s the LuaJIT headers
//!
//! As written in Stage 9 (commit 113bdb3, May 2026) this file did:
//!
//!     pub const c = @cImport({ @cInclude("lua.h"); ... });
//!     pub extern fn lua_newstate(...) ?*c.lua_State;
//!
//! Both halves are unsatisfiable in this repository today, and that was verified
//! empirically rather than assumed (ISS-0153, 2026-08-06):
//!
//!   - `zig test` on a two-line probe containing only `@cInclude("lua.h")` fails
//!     with `'lua.h' not found`, both with and without `-lc`.
//!   - `zig test -lc -lluajit-5.1` fails with `unable to find dynamic system
//!     library 'luajit-5.1' using strategy 'paths_first'. searched paths: none`.
//!   - There is no LuaJIT under `vendor/` (only `pg`, `http`, `cel`), no LuaJIT
//!     entry in `build.zig.zon` `.dependencies`, no `lua.h` anywhere on disk
//!     (`find . -name lua.h` -> empty), and no LuaJIT install step in
//!     `docker-compose.yml` or `.github/workflows/`.
//!
//! So the `@cImport` could not resolve, and the `pub extern fn lua_*`
//! declarations named link-time symbols that no archive in this build provides.
//! Any target that pulled this file in would have failed at translate-C time —
//! which is precisely why the subsystem stayed unreferenced: wiring it up as
//! written was impossible, so nobody did, and the rot compounded unobserved for
//! three months while LUA-01..16 sat marked RELEASED.
//!
//! ## The decision
//!
//! Same disposition ISS-0147 reached for `src/wasm/wasmtime_bindings.zig`:
//! replace the unresolvable C surface with **pure-Zig stubs** that carry the
//! real API shape (types, constants, signatures) but need no linker
//! involvement. That makes the whole subsystem compile and be type-checked on
//! every `zig build test`, so the Zig-side logic in `executor.zig`,
//! `stdlib.zig`, the limiters and the eight `host_api/*.zig` files can no
//! longer rot silently the way it did between May and August 2026.
//!
//! What it does NOT do is execute Lua. Every stub below returns a failure or
//! zero sentinel. `executor.executeScript` therefore reports
//! `LuaAllocFailed` rather than running a script — an honest, loud failure
//! rather than a silent pretence of working (see docs/anti-patterns.md, "A
//! function fetches the state it needs, immediately discards it ... and returns
//! success", ISS-0155: a stub that returns success is a silent false negative).
//!
//! Because of that, LUA-01..16 are **not** backed by executable behaviour and
//! were downgraded from RELEASED under ISS-0153. Restoring them requires
//! vendoring LuaJIT (or adding it as a build.zig.zon dependency) and swapping
//! the stubs below for real `@cImport` bindings plus a static
//! `linkSystemLibrary`/`linkLibrary` — tracked as ISS-0161 / GH #485.
//!
//! ## Fidelity note
//!
//! The signatures below are the LuaJIT 2.1 (Lua 5.1 ABI) ones, kept faithful so
//! that swapping in the real `@cImport` is a drop-in replacement rather than a
//! rewrite of every call site. Three decls that the rest of `src/lua/` calls
//! were MISSING from the original file entirely and are added here:
//! `lua_istable`, `lua_sethook` and the `lua_Debug` type. They were never
//! noticed because no build target ever analysed the callers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Opaque Lua interpreter state. `extern struct` here is a memory-layout
/// qualifier, not a link-time symbol reference — referencing this type pulls in
/// no external symbol.
pub const lua_State = extern struct {};

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

// ---------------------------------------------------------------------------
// Stub implementations
//
// Every function below is an `inline fn` returning a failure/zero sentinel. No
// linker involvement. Swapping in real LuaJIT means deleting this section and
// restoring the `pub extern fn` declarations with the same names and
// signatures — ISS-0161 / GH #485.
// ---------------------------------------------------------------------------

/// Create a new Lua state (stub: always fails, so callers surface
/// `LuaError.LuaAllocFailed` rather than pretending to have a runtime).
pub inline fn lua_newstate(f: lua_Alloc, ud: ?*anyopaque) ?*lua_State {
    _ = f;
    _ = ud;
    return null;
}

pub inline fn lua_close(L: *lua_State) void {
    _ = L;
}

pub inline fn lua_newthread(L: *lua_State) ?*lua_State {
    _ = L;
    return null;
}

// Stack manipulation

pub inline fn lua_gettop(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn lua_settop(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_pushvalue(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_remove(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_insert(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_replace(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_checkstack(L: *lua_State, sz: c_int) c_int {
    _ = L;
    _ = sz;
    return 0;
}

/// `lua_pop` is a macro in lua.h; it stays a real wrapper over `lua_settop`
/// so the relationship survives the stub->real swap unchanged.
pub inline fn lua_pop(L: *lua_State, n: c_int) void {
    lua_settop(L, -n - 1);
}

// Push values

pub inline fn lua_pushnil(L: *lua_State) void {
    _ = L;
}

pub inline fn lua_pushboolean(L: *lua_State, b: c_int) void {
    _ = L;
    _ = b;
}

pub inline fn lua_pushnumber(L: *lua_State, n: f64) void {
    _ = L;
    _ = n;
}

pub inline fn lua_pushinteger(L: *lua_State, i: isize) void {
    _ = L;
    _ = i;
}

pub inline fn lua_pushlstring(L: *lua_State, s: [*]const u8, len: usize) void {
    _ = L;
    _ = s;
    _ = len;
}

pub inline fn lua_pushstring(L: *lua_State, s: [*:0]const u8) void {
    _ = L;
    _ = s;
}

pub inline fn lua_pushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) void {
    _ = L;
    _ = f;
    _ = n;
}

pub inline fn lua_pushlightuserdata(L: *lua_State, p: ?*anyopaque) void {
    _ = L;
    _ = p;
}

// Type queries

pub inline fn lua_type(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return LUA_TNONE;
}

pub inline fn lua_typename(L: *lua_State, tp: c_int) [*:0]const u8 {
    _ = L;
    _ = tp;
    return "no value";
}

pub inline fn lua_isnil(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_isboolean(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_isnumber(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_isstring(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

/// Referenced by host_api/fail.zig but absent from the original file — the
/// caller was never analysed by any build target, so the gap never surfaced.
pub inline fn lua_istable(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_isuserdata(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

// Get values from the stack

pub inline fn lua_toboolean(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_tonumber(L: *lua_State, idx: c_int) f64 {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_tointeger(L: *lua_State, idx: c_int) isize {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_tolstring(L: *lua_State, idx: c_int, len: *usize) [*:0]const u8 {
    _ = L;
    _ = idx;
    len.* = 0;
    return "";
}

pub inline fn lua_tostring(L: *lua_State, idx: c_int) [*:0]const u8 {
    _ = L;
    _ = idx;
    return "";
}

pub inline fn lua_touserdata(L: *lua_State, idx: c_int) ?*anyopaque {
    _ = L;
    _ = idx;
    return null;
}

// Table operations

pub inline fn lua_newtable(L: *lua_State) void {
    _ = L;
}

pub inline fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void {
    _ = L;
    _ = idx;
    _ = k;
}

pub inline fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void {
    _ = L;
    _ = idx;
    _ = k;
}

pub inline fn lua_rawget(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_rawset(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_rawgeti(L: *lua_State, idx: c_int, n: c_int) void {
    _ = L;
    _ = idx;
    _ = n;
}

pub inline fn lua_rawseti(L: *lua_State, idx: c_int, n: c_int) void {
    _ = L;
    _ = idx;
    _ = n;
}

// Globals

pub inline fn lua_getglobal(L: *lua_State, name: [*:0]const u8) void {
    _ = L;
    _ = name;
}

pub inline fn lua_setglobal(L: *lua_State, name: [*:0]const u8) void {
    _ = L;
    _ = name;
}

// Calls

pub inline fn lua_call(L: *lua_State, nargs: c_int, nresults: c_int) void {
    _ = L;
    _ = nargs;
    _ = nresults;
}

/// Stub returns `LUA_ERRRUN` (not `LUA_OK`): with no interpreter present, a
/// protected call has NOT succeeded, and reporting success here would make
/// `executeScript` claim a script ran when nothing did.
pub inline fn lua_pcall(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    _ = L;
    _ = nargs;
    _ = nresults;
    _ = errfunc;
    return LUA_ERRRUN;
}

// Errors

pub inline fn lua_error(L: *lua_State) c_int {
    _ = L;
    return 0;
}

// Debug hooks (LUA-08 instruction limiting)

/// Referenced by instruction_limiter.zig but absent from the original file.
pub inline fn lua_sethook(L: *lua_State, f: lua_Hook, mask: c_int, count: c_int) c_int {
    _ = L;
    _ = f;
    _ = mask;
    _ = count;
    return 0;
}

pub inline fn lua_gethookcount(L: *lua_State) c_int {
    _ = L;
    return 0;
}

// Standard library opens

pub inline fn luaopen_math(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_string(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_table(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_io(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_os(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_debug(L: *lua_State) c_int {
    _ = L;
    return 0;
}

pub inline fn luaopen_package(L: *lua_State) c_int {
    _ = L;
    return 0;
}

// Auxlib

/// Stub returns `LUA_ERRSYNTAX`: nothing was loaded, so reporting `LUA_OK`
/// would let `executeScript` proceed as though a chunk were on the stack.
pub inline fn luaL_loadstring(L: *lua_State, s: [*:0]const u8) c_int {
    _ = L;
    _ = s;
    return LUA_ERRSYNTAX;
}

pub inline fn luaL_loadbuffer(L: *lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8) c_int {
    _ = L;
    _ = buff;
    _ = sz;
    _ = name;
    return LUA_ERRSYNTAX;
}

pub inline fn luaL_setmetatable(L: *lua_State, tname: [*:0]const u8) void {
    _ = L;
    _ = tname;
}

pub inline fn luaL_getmetatable(L: *lua_State, tname: [*:0]const u8) c_int {
    _ = L;
    _ = tname;
    return 0;
}

// User data

pub inline fn lua_setuservalue(L: *lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

pub inline fn lua_getuservalue(L: *lua_State, idx: c_int) c_int {
    _ = L;
    _ = idx;
    return 0;
}

pub inline fn lua_newuserdata(L: *lua_State, sz: usize) ?*anyopaque {
    _ = L;
    _ = sz;
    return null;
}

/// True when this build has a real LuaJIT linked in. Callers and tests read
/// this instead of hardcoding an assumption, so flipping it to `true` under
/// ISS-0161 changes behaviour in one place.
pub const has_real_luajit = false;
