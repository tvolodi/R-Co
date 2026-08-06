//! Lua standard library loader with security restrictions.
//!
//! This module loads only the safe standard library modules:
//! - math (fully loaded)
//! - string (loaded with dangerous functions removed)
//! - table (fully loaded)
//!
//! Blocked modules:
//! - io (file I/O forbidden)
//! - os (system execution forbidden)
//! - package (module loading forbidden; sandboxing depends on this)
//! - debug (introspection forbidden)

const std = @import("std");
const bindings = @import("luajit_bindings.zig");

pub const LibraryError = error{
    FailedToLoadLibrary,
};

/// Load only the safe standard libraries (math, string, table).
/// Dangerous functions are removed from the string module.
pub fn loadSafeStdlib(L: *bindings.LuaState) !void {
    // Load math library (fully safe)
    _ = bindings.luaopen_math(L);
    bindings.lua_setglobal(L, "math");

    // Load string library
    _ = bindings.luaopen_string(L);
    bindings.lua_setglobal(L, "string");

    // Remove dangerous string functions
    try removeGlobal(L, "string", "dump");
    try removeGlobal(L, "string", "load");
    try removeGlobal(L, "string", "loadfile");
    try removeGlobal(L, "string", "dofile");

    // Also remove top-level load* functions that might have been loaded.
    //
    // ISS-0161 / GH #485: `loadfile` was MISSING from this list. luaopen_base
    // installs it as a global, and nothing here removed it, so a sandboxed
    // script could call loadfile() to read and compile an arbitrary file from
    // disk — defeating both LUA-03 (no filesystem reach) and LUA-04 (the
    // bytecode gate, since loadfile happily loads a bytecode file). The gap was
    // invisible for as long as the bindings were stubs: no script could run, so
    // no test could observe which globals actually survived. It was found the
    // moment a real interpreter was linked and the survivors were enumerated.
    try removeGlobalIfExists(L, "load");
    try removeGlobalIfExists(L, "loadstring");
    try removeGlobalIfExists(L, "loadfile");
    try removeGlobalIfExists(L, "dofile");

    // Load table library (fully safe)
    _ = bindings.luaopen_table(L);
    bindings.lua_setglobal(L, "table");

    // DO NOT load: io, os, package, debug
}

/// Remove a function from a module table.
fn removeGlobal(L: *bindings.LuaState, module: [*:0]const u8, func: [*:0]const u8) !void {
    bindings.lua_getglobal(L, module);
    defer bindings.lua_pop(L, 1);

    if (bindings.lua_isnil(L, -1) != 0) {
        return;
    }

    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, -2, func);
}

/// Remove a global function if it exists (doesn't error if not found).
fn removeGlobalIfExists(L: *bindings.LuaState, name: [*:0]const u8) !void {
    bindings.lua_getglobal(L, name);
    const is_nil = bindings.lua_isnil(L, -1);
    bindings.lua_pop(L, 1);

    if (is_nil == 0) {
        bindings.lua_pushnil(L);
        bindings.lua_setglobal(L, name);
    }
}
