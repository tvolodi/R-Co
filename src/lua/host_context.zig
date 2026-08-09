//! Execution-context channel and capability gate for Lua host functions
//! (ISS-0169 / GH #495 tranche 1 — LUA-05, LUA-06).
//!
//! ## Why this module exists
//!
//! Before ISS-0169, every `register()` under `src/lua/host_api/` did
//! `_ = context;` and then `lua_pushcclosure(L, fn, 0)` — zero upvalues. A
//! `lua_CFunction` receives only `*lua_State`, so with zero upvalues and
//! nothing in the registry the `CapabilitySet` was **not in scope at call
//! time**: there was no channel through which a capability check could read
//! it. The ISS-0169 diagnosis proved the consequence empirically — with a
//! completely EMPTY `CapabilitySet`, all seven capability-requiring
//! `platform.*` calls succeeded (evidence E9). LUA-06 was not "implemented but
//! untested"; it was an absent security control.
//!
//! This module creates that channel (§2 of `src/design/lua-capability-enforcement.md`),
//! and provides the single shared gate every host function opens with (§3).
//!
//! ## The channel: LUA_REGISTRYINDEX, not `_G`, not upvalues
//!
//! The `*const ExecutionContext` lives in `LUA_REGISTRYINDEX` under the private
//! key `"bpm.execution_context"` as a light userdata.
//!
//! - **Not `_G`** — a global is script-writable, so a script could forge or nil
//!   the very value meant to constrain it. That defect is already present in
//!   `fail.zig` (`__failure_reason__`) and `instruction_limiter.zig`
//!   (`__limiter__`); it is not repeated here.
//! - **Not an upvalue** — an upvalue requires every registration site to
//!   remember `1` instead of `0`, and a site that forgets reads stack garbage
//!   rather than failing. "One site forgot" is exactly the defect class that
//!   produced this issue.
//! - **The registry is not script-reachable**: `debug` is not opened, `package`
//!   is not opened, and Lua source syntax has no way to name a pseudo-index.
//!
//! ## Lifetime (invariants CTX-1..CTX-4, design §2.3)
//!
//! A light userdata is a raw, non-owning, non-traced pointer. Lua neither
//! copies the pointee nor keeps it alive nor knows when it dies.
//!
//! - **CTX-1** the `*const ExecutionContext` MUST outlive the `lua_State`.
//!   `executeScript` guarantees this structurally: it creates the state and its
//!   `defer lua_close(L)` runs before it returns, strictly inside the caller's
//!   frame where `context` is still live.
//! - **CTX-2** the pointer installed is the *same* pointer the caller passed —
//!   never the address of a local copy, whose `capabilities` field could
//!   diverge and which dies at a different time.
//! - **CTX-3** the pointee is `const` through the whole Lua call path.
//! - **CTX-4** one `lua_State` per invocation, exactly one context, never
//!   swapped mid-execution.
//!
//! ## Fail-closed (invariant CAP-2, design §3.4)
//!
//! `contextFromState` returns an optional and `null` means DENY, never ALLOW.
//! There is no code path here in which a gated function reaches its body
//! without an affirmative `has() == true`. A gate that cannot determine the
//! answer denies.
//!
//! ## Raising (invariants ERR-1, ERR-2, design §4.3/§4.4)
//!
//! `lua_error` raises whatever is currently on the stack top, and it
//! `longjmp`s — Zig `defer`/`errdefer` in the raising frame do NOT run. Every
//! pre-ISS-0169 call site called `lua_error` with nothing pushed, which is why
//! the diagnosis observed `platform.read_variable()` reporting
//! `'1.0954944061662e-311'` (uninitialised stack memory) and
//! `platform.log('only-one-arg')` reporting `'only-one-arg'` (the caller's own
//! argument).
//!
//! The `raise*` helpers below are the only sanctioned way to raise from a host
//! function. They are typed `noreturn`, which makes ERR-1 structural: a host
//! function cannot fall through past a raise, and cannot raise without going
//! through a helper that pushes first. They format into a **fixed stack
//! buffer** and use `lua_pushlstring` (explicit length), so nothing is
//! heap-allocated and nothing can leak across the longjmp.

const std = @import("std");
const bindings = @import("luajit_bindings.zig");
const errors = @import("errors.zig");
const capabilities = @import("capabilities.zig");
const executor = @import("executor.zig");

/// Private registry key holding the execution context. Not reachable from
/// script code: a script has no `debug` library and cannot name a pseudo-index.
pub const REGISTRY_KEY: [*:0]const u8 = "bpm.execution_context";

/// LUA-15: private registry keys for the structured-failure channel. Same
/// `LUA_REGISTRYINDEX` channel as `REGISTRY_KEY` — not in `_G`, not in
/// upvalues, not script-reachable. The pre-ISS-0625 implementation used
/// `__failure_reason__` / `__failure_details__` / `__explicit_failure__` as
/// ordinary globals, which a script could forge or nil; this is the same
/// defect class that made `_G` unusable as the execution-context channel and
/// is fixed by routing through the registry.
pub const FAILURE_REASON_KEY: [*:0]const u8 = "bpm.failure_reason";
pub const FAILURE_DETAILS_KEY: [*:0]const u8 = "bpm.failure_details";
pub const FAILURE_EXPLICIT_KEY: [*:0]const u8 = "bpm.explicit_failure";

/// ISS-0628 / GH-595: private registry key holding the stack trace captured
/// by `executor.errfuncHandler` while the erroring call frames were still
/// live (installed as `lua_pcall`'s message handler). Same channel pattern
/// as `FAILURE_REASON_KEY` above — not in `_G`, not in upvalues, not
/// script-reachable.
pub const STACK_TRACE_KEY: [*:0]const u8 = "bpm.stack_trace";

/// Maximum length of a formatted diagnostic message. Generous: a denial message
/// renders the whole granted set so the failure is diagnosable rather than
/// merely fatal. Overflow truncates the *message* with an ellipsis — never a
/// capability string used for comparison (see `serviceCallCapability`).
pub const MESSAGE_BUFFER_BYTES = 2048;

/// Maximum `svc_id` length accepted by `call_service`. A longer id is an
/// `InvalidArgument`, never a silent truncation: truncating here could make a
/// long id match a shorter granted capability, which is privilege escalation.
pub const MAX_SVC_ID_BYTES = 256;

/// Buffer size a caller must provide to `serviceCallCapability`.
pub const SERVICE_CAP_BUFFER_BYTES =
    capabilities.StandardCapabilities.SERVICE_CALL_PREFIX.len + MAX_SVC_ID_BYTES;

// ---------------------------------------------------------------------------
// Context plumbing (design §2)
// ---------------------------------------------------------------------------

/// Install the context pointer into `LUA_REGISTRYINDEX`.
///
/// Call AFTER `lua_newstate` and BEFORE `registerAll`, so no closure is ever
/// reachable from Lua before its context exists. Invariants CTX-1..CTX-4.
///
/// Verifies the round trip and returns `ContextInstallFailed` if the value did
/// not land — a silent install failure would make every gate deny, which is
/// safe but undiagnosable.
pub fn installContext(
    L: *bindings.LuaState,
    context: *const executor.ExecutionContext,
) errors.LuaError!void {
    // CTX-2: install the caller's pointer itself. @constCast is confined to
    // this one line because lua_pushlightuserdata takes ?*anyopaque; the
    // pointee is never mutated through it (CTX-3) — contextFromState hands
    // back a *const.
    bindings.lua_pushlightuserdata(L, @ptrCast(@constCast(context)));
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);

    if (contextFromState(L) == null) return errors.LuaError.ContextInstallFailed;
}

/// Read the context back from inside a `lua_CFunction`.
///
/// Returns `null` when — and only when — the key is absent or is not a light
/// userdata. Callers MUST treat `null` as DENY (invariant CAP-2). Nothing in
/// this design permits an "allow if no context" path.
pub fn contextFromState(L: *bindings.LuaState) ?*const executor.ExecutionContext {
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);
    defer bindings.lua_pop(L, 1);

    if (bindings.lua_type(L, -1) != bindings.LUA_TLIGHTUSERDATA) return null;

    const raw = bindings.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// LUA-10, design §2.5.4: has the active watchdog for this execution already
/// observed its deadline pass? Reads `context.active_watchdog` off the SAME
/// `ExecutionContext` `contextFromState` already returns — no new registry
/// key, the watchdog pointer rides the existing `"bpm.execution_context"`
/// channel as one more field on the struct already installed there, same as
/// every other `ExecutionContext` field host functions already read (e.g.
/// `.capabilities`).
///
/// Returns `false` (not an error) if `contextFromState` itself returns `null`
/// or `active_watchdog` is `null` — this is a liveness check, not a security
/// gate, so it fails open on "no context installed" (unlike
/// `requireCapability`'s fail-closed CAP-2 rule, which governs authorization
/// decisions, not deadline observation — the same distinction
/// `instruction_limiter.limiterFromState`'s `orelse return` note draws).
pub fn activeWatchdogFired(L: *bindings.LuaState) bool {
    const context = contextFromState(L) orelse return false;
    const wd = context.active_watchdog orelse return false;
    return wd.hasFired();
}

// ---------------------------------------------------------------------------
// LUA-15: structured-failure channel (failure_reason / failure_details /
// explicit_failure) on LUA_REGISTRYINDEX. Same anti-forgery pattern as the
// execution-context channel above: not in `_G`, not in upvalues, not
// script-reachable.
// ---------------------------------------------------------------------------

/// Shape of the optional details table passed to `platform.fail`. The current
/// implementation only distinguishes "no details" from "table details". A
/// future addition (e.g. string details) extends this enum, not the helper
/// signatures.
pub const DetailsKind = enum { None, Table };

/// Owned view of the explicit-failure state. `reason` and `details` are
/// heap-allocated copies in `allocator` — caller frees after consuming.
/// `kind == .None` means the script raised without going through
/// `platform.fail`: a genuine runtime error, not an explicit failure.
pub const ExplicitFailureView = struct {
    kind: enum { None, Explicit },
    reason: ?[]const u8,
    details: ?executor.ScriptValue,
};

/// Set the explicit-failure discriminator on the registry channel. Called by
/// `platform.fail` BEFORE raising so the executor's failed-pcall branch can
/// read it back.
///
/// `reason` is pushed directly to the Lua registry (Lua owns the string
/// copy, no host-allocator allocation needed). `details_value` = `.Table`
/// means the value at index 2 of the host function is a real Lua table;
/// `.None` means no value (or a non-table value) — the discriminator is set
/// but no details are captured.
pub fn setExplicitFailure(
    L: *bindings.LuaState,
    allocator: std.mem.Allocator,
    reason: []const u8,
    details_value: DetailsKind,
) void {
    _ = allocator; // reason lives in Lua's heap, not on the host allocator.

    // reason: pushed to the registry as a Lua string. lua_pushlstring copies
    // the bytes into Lua-managed storage; the script's stack string can pop
    // free without us losing the reason.
    bindings.lua_pushlstring(L, reason.ptr, reason.len);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_REASON_KEY);

    // details: copy the table to a ScriptValue so the registry does not hold a
    // live Lua reference (which the failed-pcall path will unwind). `.None`
    // means nil/absent.
    switch (details_value) {
        .None => {
            bindings.lua_pushnil(L);
            bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_DETAILS_KEY);
        },
        .Table => {
            // The table is at the host function's arg 2. lua_pushvalue copies
            // the table reference into the registry; the executor's
            // readExplicitFailure copies it AGAIN into a ScriptValue so the
            // Lua-side GC can reclaim it on clearExplicitFailure.
            bindings.lua_pushvalue(L, 2);
            bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_DETAILS_KEY);
        },
    }

    // explicit flag: a Lua boolean (true) on the registry.
    bindings.lua_pushboolean(L, 1);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_EXPLICIT_KEY);
}

/// Build a `ScriptValue` (table form) from a Lua table at `idx`. Best-effort:
/// on any conversion failure the caller nils the channel. Bounded to
/// string-keyed, string/float/bool-valued entries so the conversion is
/// deterministic and does not chase Lua objects past the table.
fn tableToScriptValue(
    L: *bindings.LuaState,
    idx: c_int,
    allocator: std.mem.Allocator,
) !executor.ScriptValue {
    var map = std.StringHashMap(executor.ScriptValue).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
        }
        map.deinit();
    }
    bindings.lua_pushnil(L);
    // After lua_pushnil, `idx` (a relative index computed BEFORE the push)
    // no longer points to the table — it now points to the nil we just
    // pushed. lua_next(L, idx) on a non-table raises a segfault in LuaJIT
    // (verified in the LUA-12/15/16 integration tests on 2026-08-08: the
    // path that triggered a registry-backed details table from
    // platform.fail() crashed in lj_tab_next because idx resolved to nil
    // and not to the table).
    while (bindings.lua_next(L, idx - 1) != 0) {
        // stack: key, value
        var key_len: usize = 0;
        const key_ptr = bindings.lua_tolstring(L, -2, &key_len);
        const key = key_ptr[0..key_len];
        const key_copy = try allocator.dupe(u8, key);

        const value: executor.ScriptValue = blk: {
            const vt = bindings.lua_type(L, -1);
            switch (vt) {
                bindings.LUA_TSTRING => {
                    var vlen: usize = 0;
                    const vp = bindings.lua_tolstring(L, -1, &vlen);
                    const v = vp[0..vlen];
                    break :blk executor.ScriptValue{ .string = try allocator.dupe(u8, v) };
                },
                bindings.LUA_TNUMBER => {
                    break :blk executor.ScriptValue{ .number = bindings.lua_tonumber(L, -1) };
                },
                bindings.LUA_TBOOLEAN => {
                    break :blk executor.ScriptValue{ .boolean = bindings.lua_toboolean(L, -1) != 0 };
                },
                bindings.LUA_TNIL => {
                    break :blk executor.ScriptValue{ .nil_value = {} };
                },
                else => {
                    break :blk executor.ScriptValue{ .nil_value = {} };
                },
            }
        };

        try map.put(key_copy, value);

        // pop value, keep key for next iteration
        bindings.lua_pop(L, 1);
    }

    return executor.ScriptValue{ .table = map };
}

/// Read the explicit-failure discriminator back from the registry. Called
/// from `executor.executeSource` in the failed-pcall branch.
///
/// On `.None`, both `reason` and `details` are null. On `.Explicit`, both are
/// heap-allocated copies owned by `allocator` — caller frees after consuming.
///
/// The function is robust against stale state: a previous script's failure
/// left a flag set is unreadable here because the script author would have
/// to have gone through `platform.fail`, which is the exact thing that
/// caused the failure. `clearExplicitFailure` is called immediately after
/// reading to keep the invariant clean.
pub fn readExplicitFailure(
    L: *bindings.LuaState,
    allocator: std.mem.Allocator,
) ExplicitFailureView {
    // explicit flag first — short-circuit if absent.
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_EXPLICIT_KEY);
    defer bindings.lua_pop(L, 1);
    if (bindings.lua_type(L, -1) != bindings.LUA_TBOOLEAN) {
        return .{ .kind = .None, .reason = null, .details = null };
    }
    if (bindings.lua_toboolean(L, -1) == 0) {
        return .{ .kind = .None, .reason = null, .details = null };
    }

    // reason: a Lua string on the registry. Dupe so the caller owns the slice.
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_REASON_KEY);
    var reason_owned: ?[]const u8 = null;
    if (bindings.lua_type(L, -1) == bindings.LUA_TSTRING) {
        var rlen: usize = 0;
        const rptr = bindings.lua_tolstring(L, -1, &rlen);
        reason_owned = allocator.dupe(u8, rptr[0..rlen]) catch null;
    }
    bindings.lua_pop(L, 1);

    // details: a Lua table copied into a ScriptValue. Dupe via the table
    // walker so the caller's ScriptValue owns its strings.
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_DETAILS_KEY);
    var details_owned: ?executor.ScriptValue = null;
    if (bindings.lua_type(L, -1) == bindings.LUA_TTABLE) {
        details_owned = tableToScriptValue(L, -1, allocator) catch null;
    }
    bindings.lua_pop(L, 1);

    return .{ .kind = .Explicit, .reason = reason_owned, .details = details_owned };
}

/// Clear the explicit-failure discriminator. Called by `executeSource` immediately
/// after `readExplicitFailure` so a subsequent `platform.fail` from the same
/// script does not inherit stale state.
pub fn clearExplicitFailure(L: *bindings.LuaState) void {
    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_EXPLICIT_KEY);

    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_REASON_KEY);

    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, FAILURE_DETAILS_KEY);
}

// ---------------------------------------------------------------------------
// ISS-0628 / GH-595: stack-trace side channel (design §3.3)
// ---------------------------------------------------------------------------

/// Read the stack trace `executor.errfuncHandler` stashed on
/// `STACK_TRACE_KEY` while the erroring call frames were still live, and
/// clear the key immediately after — mirrors `readExplicitFailure`'s exact
/// shape (`lua_getfield` + `LUA_TSTRING` type guard + `lua_tolstring` +
/// `allocator.dupe` + `lua_pop`), so a script that succeeds after a prior
/// script's failure never observes a stale trace (same "never let stale
/// state leak into the next script" discipline as `clearExplicitFailure`).
///
/// Fail-soft (design's Error taxonomy, §"Error taxonomy"): a missing or
/// malformed value degrades to an empty string rather than propagating an
/// error, matching the production call site's prior
/// `captureStackTrace(...) catch ""` convention.
pub fn readStackTrace(L: *bindings.LuaState, allocator: std.mem.Allocator) []const u8 {
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, STACK_TRACE_KEY);
    var trace_owned: []const u8 = "";
    if (bindings.lua_type(L, -1) == bindings.LUA_TSTRING) {
        var tlen: usize = 0;
        const tptr = bindings.lua_tolstring(L, -1, &tlen);
        trace_owned = allocator.dupe(u8, tptr[0..tlen]) catch "";
    }
    bindings.lua_pop(L, 1);

    // Clear so a subsequent script never inherits a stale trace.
    bindings.lua_pushnil(L);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, STACK_TRACE_KEY);

    return trace_owned;
}

// ---------------------------------------------------------------------------
// The capability gate (design §3)
// ---------------------------------------------------------------------------

/// The capability gate. Returns normally only when the call may proceed.
///
/// On denial it has ALREADY pushed the structured denial message and raised,
/// so control does not return to the caller in that case (LuaJIT longjmps to
/// the nearest protected boundary).
///
/// Fail-closed: a missing or unreadable context denies with `(none)` rendered
/// as the granted set (CAP-2).
pub fn requireCapability(
    L: *bindings.LuaState,
    function_name: []const u8,
    required: []const u8,
) void {
    const context = contextFromState(L) orelse
        raiseCapabilityDeniedNoContext(L, function_name, required);

    if (!context.capabilities.has(required)) {
        raiseCapabilityDenied(L, function_name, required, context.capabilities);
    }
}

// ---------------------------------------------------------------------------
// Raise helpers — the ONLY sanctioned way to raise from a host function (ERR-1)
// ---------------------------------------------------------------------------

/// Push a formatted capability-denial message and raise. Never returns.
///
/// Format (design §4.2):
///   `capability denied: platform.<fn> requires '<required>'; granted: <summary>`
///
/// Fixed stack buffer only — no allocator (ERR-2). `CapabilitySet.summary()`
/// allocates, so it must NOT be used here: its result would be leaked by the
/// longjmp. The grant set is walked directly into the same buffer instead.
pub fn raiseCapabilityDenied(
    L: *bindings.LuaState,
    function_name: []const u8,
    required: []const u8,
    granted: *const capabilities.CapabilitySet,
) noreturn {
    var buffer: [MESSAGE_BUFFER_BYTES]u8 = undefined;
    var w = Writer.init(&buffer);

    w.put("capability denied: platform.");
    w.put(function_name);
    w.put(" requires '");
    w.put(required);
    w.put("'; granted: ");
    writeGrants(&w, granted);

    raiseMessage(L, w.slice());
}

/// Denial when the registry held no context at all. Rendered with an explicit
/// `(none)` granted set so the message shape is identical to a normal denial
/// and a test can assert on one format.
fn raiseCapabilityDeniedNoContext(
    L: *bindings.LuaState,
    function_name: []const u8,
    required: []const u8,
) noreturn {
    var buffer: [MESSAGE_BUFFER_BYTES]u8 = undefined;
    var w = Writer.init(&buffer);

    w.put("capability denied: platform.");
    w.put(function_name);
    w.put(" requires '");
    w.put(required);
    w.put("'; granted: (none)");

    raiseMessage(L, w.slice());
}

/// Push a formatted argument-error message and raise. Never returns.
///
/// Format (design §4.2), deliberately distinct from a denial so a test cannot
/// confuse the two:
///   `invalid argument: platform.<fn> argument <n> must be <type>`
pub fn raiseInvalidArgument(
    L: *bindings.LuaState,
    function_name: []const u8,
    arg_index: c_int,
    expected_type: []const u8,
) noreturn {
    var buffer: [MESSAGE_BUFFER_BYTES]u8 = undefined;
    var w = Writer.init(&buffer);

    w.put("invalid argument: platform.");
    w.put(function_name);
    w.put(" argument ");
    w.putInt(arg_index);
    w.put(" must be ");
    w.put(expected_type);

    raiseMessage(L, w.slice());
}

/// Push a plain, already-formatted message and raise. Never returns.
/// `lua_pushlstring` (explicit length) — NOT `lua_pushstring`, which takes
/// `[*:0]const u8` and would read past the end of a Zig slice (§4.4).
pub fn raiseMessage(L: *bindings.LuaState, message: []const u8) noreturn {
    bindings.lua_pushlstring(L, message.ptr, message.len);
    _ = bindings.lua_error(L);
    // lua_error longjmps and never returns. If LuaJIT ever did return here the
    // state would be corrupt, so refusing to continue is the only safe act.
    unreachable;
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// True string check.
///
/// `lua_isstring` accepts NUMBERS in Lua 5.1 (implicit coercion), which is why
/// `platform.write_variable(123, 1)` silently succeeded before ISS-0169
/// (evidence E11). This is `lua_type(L, idx) == LUA_TSTRING` — no coercion.
pub fn isRealString(L: *bindings.LuaState, idx: c_int) bool {
    return bindings.lua_type(L, idx) == bindings.LUA_TSTRING;
}

/// Read argument `idx` as a real string, or raise `InvalidArgument`.
/// The returned slice points into Lua's own string storage, which stays valid
/// for as long as the value remains on the stack (i.e. for the call).
pub fn checkString(
    L: *bindings.LuaState,
    function_name: []const u8,
    idx: c_int,
) []const u8 {
    if (bindings.lua_gettop(L) < idx or !isRealString(L, idx)) {
        raiseInvalidArgument(L, function_name, idx, "a string");
    }
    var len: usize = 0;
    const ptr = bindings.lua_tolstring(L, idx, &len);
    return ptr[0..len];
}

/// Raise `InvalidArgument` unless at least `n` arguments were supplied.
pub fn checkArgCount(
    L: *bindings.LuaState,
    function_name: []const u8,
    n: c_int,
) void {
    if (bindings.lua_gettop(L) < n) {
        raiseInvalidArgument(L, function_name, n, "present");
    }
}

/// Build `"service:call:<svc_id>"` into a caller-provided fixed buffer.
///
/// Returns `null` if `svc_id` exceeds `MAX_SVC_ID_BYTES` or the buffer is too
/// small — the caller then raises `InvalidArgument`. MUST NOT truncate (§3.3):
/// a truncated capability could match a shorter grant, which is privilege
/// escalation, not a diagnostic inconvenience.
pub fn serviceCallCapability(buffer: []u8, svc_id: []const u8) ?[]const u8 {
    const prefix = capabilities.StandardCapabilities.SERVICE_CALL_PREFIX;
    if (svc_id.len > MAX_SVC_ID_BYTES) return null;
    if (buffer.len < prefix.len + svc_id.len) return null;

    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + svc_id.len], svc_id);
    return buffer[0 .. prefix.len + svc_id.len];
}

// ---------------------------------------------------------------------------
// Fixed-buffer writer (no allocator — ERR-2)
// ---------------------------------------------------------------------------

/// Append-only writer over a caller-owned stack buffer. Silently stops at the
/// end of the buffer and records the overflow so `slice()` can append an
/// ellipsis. Truncating a *diagnostic* is safe; that is the only thing this is
/// ever used for.
const Writer = struct {
    buf: []u8,
    len: usize = 0,
    overflowed: bool = false,

    const ELLIPSIS = "...";

    fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    fn put(self: *Writer, text: []const u8) void {
        if (self.overflowed) return;
        // Keep room for the ellipsis so an overflowing message stays honest.
        const limit = self.buf.len - ELLIPSIS.len;
        if (self.len + text.len > limit) {
            const room = limit - self.len;
            @memcpy(self.buf[self.len .. self.len + room], text[0..room]);
            self.len += room;
            self.overflowed = true;
            return;
        }
        @memcpy(self.buf[self.len .. self.len + text.len], text);
        self.len += text.len;
    }

    fn putInt(self: *Writer, value: c_int) void {
        var scratch: [24]u8 = undefined;
        const rendered = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
        self.put(rendered);
    }

    fn slice(self: *Writer) []const u8 {
        if (self.overflowed) {
            @memcpy(self.buf[self.len .. self.len + ELLIPSIS.len], ELLIPSIS);
            self.len += ELLIPSIS.len;
            self.overflowed = false;
        }
        return self.buf[0..self.len];
    }
};

/// Render the granted capabilities directly into the message buffer.
/// Deliberately NOT `CapabilitySet.summary()`, which allocates: its result
/// would be leaked by `lua_error`'s longjmp (ERR-2).
fn writeGrants(w: *Writer, granted: *const capabilities.CapabilitySet) void {
    if (granted.grants.count() == 0) {
        w.put("(none)");
        return;
    }
    var iter = granted.grants.keyIterator();
    var first = true;
    while (iter.next()) |key| {
        if (!first) w.put(", ");
        w.put(key.*);
        first = false;
    }
}

// ---------------------------------------------------------------------------
// Tests — these genuinely CALL the functions above.
//
// ISS-0172 / GH #500: `zig build test-lua` going green does NOT prove a file
// compiles. src/lua_test_root.zig pins files with bare TYPE references
// (`_ = Module.TypeName;`), and Zig resolves struct field types lazily while
// `_ = someFn;` takes an address without analysing the body. Both compile
// errors in the limiters survived a green test-lua for exactly that reason.
// The tests below invoke real functions against a real LuaJIT state, so a
// break here cannot hide.
// ---------------------------------------------------------------------------

fn testAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

test "ISS-0169: the context round-trips through the registry" {
    const L = bindings.lua_newstate(testAlloc, null) orelse return error.LuaStateAllocFailed;
    defer bindings.lua_close(L);

    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const ctx = executor.ExecutionContext{
        .allocator = std.testing.allocator,
        .capabilities = &caps,
        .instance_id = "iss0169-instance",
        .actor_id = "iss0169-actor",
    };

    // Before install: fail-closed — absent key reads back as null.
    try std.testing.expect(contextFromState(L) == null);

    try installContext(L, &ctx);

    const read_back = contextFromState(L) orelse return error.ContextNotInstalled;
    // CTX-2: the SAME pointer, not a copy.
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(read_back));
    try std.testing.expectEqualStrings("iss0169-instance", read_back.instance_id);

    // The stack must be balanced after both operations.
    try std.testing.expectEqual(@as(c_int, 0), bindings.lua_gettop(L));
}

test "ISS-0169: serviceCallCapability concatenates and never truncates" {
    var buf: [SERVICE_CAP_BUFFER_BYTES]u8 = undefined;

    const built = serviceCallCapability(&buf, "payment_svc") orelse
        return error.CapabilityNotBuilt;
    try std.testing.expectEqualStrings("service:call:payment_svc", built);

    // An over-long svc_id must be REJECTED, not truncated: a truncated
    // capability could match a shorter grant (privilege escalation).
    const too_long = [_]u8{'a'} ** (MAX_SVC_ID_BYTES + 1);
    try std.testing.expect(serviceCallCapability(&buf, &too_long) == null);

    // A buffer that cannot hold the result must also be rejected.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(serviceCallCapability(&tiny, "payment_svc") == null);
}

test "ISS-0169: denial messages render the granted set without allocating" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add(capabilities.StandardCapabilities.VARIABLE_READ);

    var buffer: [MESSAGE_BUFFER_BYTES]u8 = undefined;
    var w = Writer.init(&buffer);
    w.put("capability denied: platform.write_variable requires '");
    w.put(capabilities.StandardCapabilities.VARIABLE_WRITE);
    w.put("'; granted: ");
    writeGrants(&w, &caps);

    const msg = w.slice();
    try std.testing.expect(std.mem.indexOf(u8, msg, "write_variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "variable:write") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "variable:read") != null);
}

test "ISS-0169: an empty grant set renders as (none)" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();

    var buffer: [MESSAGE_BUFFER_BYTES]u8 = undefined;
    var w = Writer.init(&buffer);
    writeGrants(&w, &caps);
    try std.testing.expectEqualStrings("(none)", w.slice());
}

test "ISS-0169: an oversized message truncates with an ellipsis, not a buffer overrun" {
    var buffer: [64]u8 = undefined;
    var w = Writer.init(&buffer);
    const long = [_]u8{'x'} ** 200;
    w.put(&long);
    const out = w.slice();
    try std.testing.expectEqual(buffer.len, out.len);
    try std.testing.expect(std.mem.endsWith(u8, out, "..."));
}
