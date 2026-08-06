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
    bindings.lua_pushlightuserdata(L, @constCast(@ptrCast(context)));
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
