//! LuaJIT C FFI bindings — low-level interface to embedded Lua runtime.
//!
//! This module provides FFI declarations for LuaJIT C APIs. All C function declarations
//! are imported here; implementation details are hidden in the C library.
//!
//! Build requirement: Link against static LuaJIT archive (libluajit.a).

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
    @cInclude("luajit.h");
});

pub const LuaState = c.lua_State;
pub const LuaValue = c.lua_Number;
pub const LuaCInt = c.lua_Integer;

// Lua type constants
pub const LUA_TNONE = c.LUA_TNONE;
pub const LUA_TNIL = c.LUA_TNIL;
pub const LUA_TBOOLEAN = c.LUA_TBOOLEAN;
pub const LUA_TLIGHTUSERDATA = c.LUA_TLIGHTUSERDATA;
pub const LUA_TNUMBER = c.LUA_TNUMBER;
pub const LUA_TSTRING = c.LUA_TSTRING;
pub const LUA_TTABLE = c.LUA_TTABLE;
pub const LUA_TFUNCTION = c.LUA_TFUNCTION;
pub const LUA_TUSERDATA = c.LUA_TUSERDATA;
pub const LUA_TTHREAD = c.LUA_TTHREAD;

// Lua status codes
pub const LUA_OK = c.LUA_OK;
pub const LUA_YIELD = c.LUA_YIELD;
pub const LUA_ERRRUN = c.LUA_ERRRUN;
pub const LUA_ERRSYNTAX = c.LUA_ERRSYNTAX;
pub const LUA_ERRMEM = c.LUA_ERRMEM;
pub const LUA_ERRERR = c.LUA_ERRERR;

// FFI declarations for public Lua C APIs
pub extern fn lua_newstate(f: *const fn (u: ?*c_void, p: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void, ud: ?*c_void) ?*c.lua_State;
pub extern fn lua_close(L: *c.lua_State) void;
pub extern fn lua_newthread(L: *c.lua_State) ?*c.lua_State;

// Stack manipulation
pub extern fn lua_gettop(L: *c.lua_State) c_int;
pub extern fn lua_settop(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_pushvalue(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_remove(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_insert(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_replace(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_checkstack(L: *c.lua_State, sz: c_int) c_int;

// Convenience macro wrappers
pub inline fn lua_pop(L: *c.lua_State, n: c_int) void {
    lua_settop(L, -n - 1);
}

// Push values
pub extern fn lua_pushnil(L: *c.lua_State) void;
pub extern fn lua_pushboolean(L: *c.lua_State, b: c_int) void;
pub extern fn lua_pushnumber(L: *c.lua_State, n: f64) void;
pub extern fn lua_pushinteger(L: *c.lua_State, i: c_int) void;
pub extern fn lua_pushlstring(L: *c.lua_State, s: [*]const u8, len: usize) [*]const u8;
pub extern fn lua_pushstring(L: *c.lua_State, s: [*:0]const u8) [*]const u8;
pub extern fn lua_pushcclosure(L: *c.lua_State, f: c.lua_CFunction, n: c_int) void;
pub extern fn lua_pushlightuserdata(L: *c.lua_State, p: ?*c_void) void;

// Type queries
pub extern fn lua_type(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_typename(L: *c.lua_State, tp: c_int) [*:0]const u8;
pub extern fn lua_isnil(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_isboolean(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_isnumber(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_isstring(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_isuserdata(L: *c.lua_State, idx: c_int) c_int;

// Get values from stack
pub extern fn lua_toboolean(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_tonumber(L: *c.lua_State, idx: c_int) f64;
pub extern fn lua_tointeger(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: *c.lua_State, idx: c_int, len: *usize) [*:0]const u8;
pub extern fn lua_tostring(L: *c.lua_State, idx: c_int) [*:0]const u8;
pub extern fn lua_touserdata(L: *c.lua_State, idx: c_int) ?*c_void;

// Table operations
pub extern fn lua_newtable(L: *c.lua_State) void;
pub extern fn lua_getfield(L: *c.lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_setfield(L: *c.lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_rawget(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_rawset(L: *c.lua_State, idx: c_int) void;

// Global operations
pub extern fn lua_getglobal(L: *c.lua_State, name: [*:0]const u8) void;
pub extern fn lua_setglobal(L: *c.lua_State, name: [*:0]const u8) void;

// Function calls
pub extern fn lua_call(L: *c.lua_State, nargs: c_int, nresults: c_int) void;
pub extern fn lua_pcall(L: *c.lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;

// Errors
pub extern fn lua_error(L: *c.lua_State) c_int;

// Standard library opens
pub extern fn luaopen_math(L: *c.lua_State) c_int;
pub extern fn luaopen_string(L: *c.lua_State) c_int;
pub extern fn luaopen_table(L: *c.lua_State) c_int;
pub extern fn luaopen_io(L: *c.lua_State) c_int;
pub extern fn luaopen_os(L: *c.lua_State) c_int;
pub extern fn luaopen_debug(L: *c.lua_State) c_int;
pub extern fn luaopen_package(L: *c.lua_State) c_int;

// Auxlib functions
pub extern fn luaL_loadstring(L: *c.lua_State, s: [*:0]const u8) c_int;
pub extern fn luaL_loadbuffer(L: *c.lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8) c_int;
pub extern fn luaL_setmetatable(L: *c.lua_State, tname: [*:0]const u8) void;
pub extern fn luaL_getmetatable(L: *c.lua_State, tname: [*:0]const u8) c_int;

// User data
pub extern fn lua_setuservalue(L: *c.lua_State, idx: c_int) void;
pub extern fn lua_getuservalue(L: *c.lua_State, idx: c_int) c_int;
pub extern fn lua_newuserdata(L: *c.lua_State, sz: usize) ?*c_void;

// Registry
pub extern fn lua_rawgeti(L: *c.lua_State, idx: c_int, n: c_int) void;
pub extern fn lua_rawseti(L: *c.lua_State, idx: c_int, n: c_int) void;
