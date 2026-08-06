//! Lua standard library loader with security restrictions (LUA-03).
//!
//! Opened: base (then pruned, see below), math, string, table.
//! Never opened: io, os, package, debug, jit, ffi, bit, coroutine.
//!
//! ## ISS-0169 / GH #495 — base is now opened, then pruned (design §5)
//!
//! Before this change `loadSafeStdlib` never called `luaopen_base`, with two
//! consequences the ISS-0169 diagnosis measured directly (evidence E8):
//!
//! 1. **No realistic script could run.** `pairs`, `ipairs`, `pcall`, `error`,
//!    `type`, `tostring`, `setmetatable` and `_G` were ALL absent from any
//!    script executed through `executeScript`. That is over-restriction, not
//!    security. In particular LUA-06's denial semantics are "raises a Lua
//!    error", and without `pcall` a script cannot observe one.
//! 2. **The LUA-03 removals below were no-ops on the product path.** Removing
//!    `load`/`loadstring`/`loadfile`/`dofile` removed nothing, because
//!    `luaopen_base` had never installed them. The ISS-0161 `loadfile` fix was
//!    correct code guarding a door that was not open *on this path*. The
//!    then-green LUA-03 tests proved nothing about the product, because
//!    `execution_test.zig` called `luaopen_base` itself behind the product's
//!    back (diagnosis R4) — a test/implementation divergence now closed by
//!    `executor.createSandboxedState` (invariant SBX-2).
//!
//! ## Invariant SBX-1 — prune strictly AFTER open
//!
//! The ordering in `loadSafeStdlib` is load-bearing, not stylistic. Pruning
//! before opening removes nothing and then `luaopen_base` reinstalls
//! everything: an ordering inversion that silently reopens the sandbox while
//! leaving all the removal code visibly present. Do not reorder.

const std = @import("std");
const bindings = @import("luajit_bindings.zig");

pub const LibraryError = error{
    FailedToLoadLibrary,
};

/// Globals installed by `luaopen_base` that are removed again immediately
/// after (design §5.2). Each is a sandbox escape or a policy violation.
///
/// - `load`/`loadstring`/`loadfile`/`dofile` — build or load executable code,
///   defeating LUA-03 and LUA-04's bytecode gate; the latter two additionally
///   reach the filesystem.
/// - `require` — module loading (`package` is not opened, but `require` may
///   still be present).
/// - `getfenv`/`setfenv` — environment manipulation; `setfenv` can rebind a
///   function's globals table.
/// - `collectgarbage` — lets a script manipulate GC behaviour, which will
///   interact with the tranche-2 memory limiter. Removed now so tranche 2 does
///   not inherit a hole.
/// - `print` — writes to the host's stdout, bypassing structured logging
///   (OBS-01). Scripts log via `platform.log`, which is capability-gated.
/// - `newproxy` — LuaJIT/5.1 userdata-creation extension; no legitimate script
///   use, and userdata interacts with the registry mechanism of host_context.
/// - `module` — Lua 5.1 global-namespace-mutating module declaration.
/// - `ffi` — LuaJIT's FFI is a COMPLETE sandbox escape (arbitrary memory
///   access, arbitrary C calls). It is not opened; it is also removed by name
///   here so that its absence does not depend on a build-configuration detail.
/// - `jit`/`bit`/`coroutine` — LuaJIT preloads these in some configurations;
///   they are not part of the permitted surface.
const PRUNED_GLOBALS = [_][*:0]const u8{
    "load",
    "loadstring",
    "loadfile",
    "dofile",
    "require",
    "getfenv",
    "setfenv",
    "collectgarbage",
    "print",
    "newproxy",
    "module",
    "ffi",
    "jit",
    "bit",
    "coroutine",
};

/// Load the permitted standard libraries and prune the dangerous globals.
///
/// Order is invariant SBX-1: open base FIRST, prune AFTER.
pub fn loadSafeStdlib(L: *bindings.LuaState) LibraryError!void {
    // 1. Base library. Required for pairs/ipairs/pcall/error/type/tostring/
    //    setmetatable/_G — without which no realistic script, and no
    //    capability-denial test that wants pcall to observe the raise, can run.
    //    `_G` is safe to keep precisely BECAUSE the execution context lives in
    //    LUA_REGISTRYINDEX and not in a global (host_context.zig §2.2).
    _ = bindings.luaopen_base(L);

    // 2. math (fully safe).
    _ = bindings.luaopen_math(L);
    bindings.lua_setglobal(L, "math");

    // 3. string.
    _ = bindings.luaopen_string(L);
    bindings.lua_setglobal(L, "string");

    // string.dump serialises a function to BYTECODE, which combined with any
    // surviving loader would defeat LUA-04. The other three never exist on
    // `string` in 5.1 but are removed defensively and idempotently.
    try removeField(L, "string", "dump");
    try removeField(L, "string", "load");
    try removeField(L, "string", "loadfile");
    try removeField(L, "string", "dofile");

    // 4. table (fully safe).
    _ = bindings.luaopen_table(L);
    bindings.lua_setglobal(L, "table");

    // 5. SBX-1: prune AFTER every library above has been opened. Reordering
    //    this block above step 1 silently reopens the sandbox.
    for (PRUNED_GLOBALS) |name| {
        try removeGlobalIfExists(L, name);
    }

    // DO NOT open: io, os, package, debug.
}

/// Remove a field from a module table. Silent if the module is absent.
fn removeField(L: *bindings.LuaState, module: [*:0]const u8, func: [*:0]const u8) LibraryError!void {
    bindings.lua_getglobal(L, module);
    defer bindings.lua_pop(L, 1);

    if (bindings.lua_isnil(L, -1) != 0) {
        return;
    }

    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, -2, func);
}

/// Remove a global if it exists. Idempotent and silent on absence.
fn removeGlobalIfExists(L: *bindings.LuaState, name: [*:0]const u8) LibraryError!void {
    bindings.lua_getglobal(L, name);
    const is_nil = bindings.lua_isnil(L, -1);
    bindings.lua_pop(L, 1);

    if (is_nil == 0) {
        bindings.lua_pushnil(L);
        bindings.lua_setglobal(L, name);
    }
}
