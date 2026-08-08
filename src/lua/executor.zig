//! Core Lua script executor with state isolation and sandboxing.
//!
//! This module provides the main entry point for executing Lua scripts within the BPM platform.
//! Key responsibilities:
//! - Create and manage per-invocation Lua states
//! - Load restricted standard libraries
//! - Register platform.* host API functions
//! - Execute scripts and extract results
//! - Enforce security (bytecode rejection, capability checks)

const std = @import("std");
const bindings = @import("luajit_bindings.zig");
const errors = @import("errors.zig");
const capabilities = @import("capabilities.zig");
const stdlib = @import("stdlib.zig");
const host_api = @import("host_api/mod.zig");
const host_context = @import("host_context.zig");
const manifest = @import("manifest.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const memory_limiter = @import("memory_limiter.zig");
const timeout_ctx = @import("timeout.zig");
const time_source = @import("time_source.zig");
const structured_logger = @import("structured_logger.zig");
const service_catalog = @import("service_catalog.zig");
const events = @import("events.zig");

/// Execution context passed to Lua and used by host API functions.
///
/// ISS-0169 / GH #495: this struct is now reachable from inside every
/// `lua_CFunction` via `host_context.installContext` /
/// `host_context.contextFromState`, which is what makes a capability check
/// possible at call time at all. Before that it was discarded (`_ = context;`)
/// at every registration site.
///
/// LIFETIME (invariant CTX-1, design §2.3): the context handed to
/// `executeScript` MUST outlive the `lua_State`. `executeScript` guarantees
/// this structurally — it creates the state and its `defer lua_close(L)` runs
/// before it returns, strictly inside the caller's frame. Do not heap-allocate
/// and free, or move, an ExecutionContext between state creation and close.
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    capabilities: *const capabilities.CapabilitySet,
    instance_id: []const u8,
    actor_id: []const u8,
    /// LUA-07. Set by `executeScriptWithManifest` to the verified hash of the
    /// manifest that granted `capabilities`. Null on the plain `executeScript`
    /// path, which performs no manifest verification.
    manifest_hash: ?[32]u8 = null,
    /// LUA-10, design §2.5.4. Set by `executeSource` to the active
    /// host-external watchdog for this execution, right after the watchdog
    /// starts and before `createSandboxedState` installs the context — so
    /// `installContext`'s existing CTX-1..CTX-4 invariants apply to it
    /// unchanged (same pointer, same lifetime). Defaulted to `null` so no
    /// existing construction site (tests, other callers) breaks. Read by
    /// `host_context.activeWatchdogFired`, which `call_service.zig` calls
    /// before and after the body of `platformCallService`.
    active_watchdog: ?*const timeout_ctx.WatchdogState = null,
};

/// Result of script execution.
pub const ScriptResult = struct {
    success: bool,
    value: ?ScriptValue,
    error_message: ?[]const u8,
    /// LUA-07 second acceptance criterion. `src/lua/` PRODUCES this value;
    /// persisting it into the execution audit record is the engine's job (the
    /// executor performs no I/O, consistent with the transition.zig precedent).
    /// See design §6.4 and §11 follow-up 2.
    manifest_hash: ?[32]u8 = null,

    pub fn deinit(self: *ScriptResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.value) |val| {
            val.deinit(allocator);
        }
    }
};

/// Script return value (can be nil, bool, number, string, or table).
pub const ScriptValue = union(enum) {
    nil_value: void,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: std.StringHashMap(ScriptValue),

    /// ISS-0153: the original body did not compile and would have leaked and
    /// double-freed if it had. Three separate defects, none ever reported
    /// because no build target analysed this file:
    ///   1. `self.table.allocator orelse allocator` — `StringHashMap.allocator`
    ///      is not optional, so `orelse` is a type error.
    ///   2. The map's own storage was never released (no `t.deinit()`), so
    ///      every table-valued script result leaked its bucket array.
    ///   3. Entries were walked twice — once for keys in the switch, once for
    ///      values below — with the second pass freeing only `.string` values
    ///      non-recursively, so nested tables leaked while the structure
    ///      invited a double free.
    /// Rewritten as a single recursive pass that frees each key and each value
    /// exactly once, then releases the map itself.
    pub fn deinit(self: ScriptValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .table => |t| {
                var map = t;
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
            else => {},
        }
    }
};

/// Bytecode magic number: 0x1b 'L' 'u' 'a'
const BYTECODE_MAGIC = [4]u8{ 0x1b, 0x4c, 0x75, 0x61 };

/// Check if script source looks like Lua bytecode.
fn isBytecode(script: []const u8) bool {
    if (script.len < 4) return false;
    return std.mem.eql(u8, script[0..4], &BYTECODE_MAGIC);
}

/// Resource limits enforced for one script execution (LUA-08/09/10, design
/// §3.1). Every code path that reaches `lua_pcall` carries a finite value for
/// all three fields — see `UNMANIFESTED_DEFAULT_LIMITS` and invariant INV-3.
pub const RunLimits = struct {
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
};

/// Conservative default limits for `executeScript` (the no-manifest path),
/// design §3.2. `executeScript`'s own doc comment says it "must never become
/// a way to bypass a gate" — running unlimited would make it exactly that
/// bypass relative to the manifest path, so it uses the same safe-minimum
/// bounds `manifest.zig` already validates every manifest against, reused
/// rather than duplicated.
pub const UNMANIFESTED_DEFAULT_LIMITS = RunLimits{
    .max_instructions = manifest.Limits.MIN_INSTRUCTIONS,
    .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,
    .timeout_seconds = manifest.Limits.MIN_TIMEOUT_SECONDS,
};

/// The SINGLE constructor for a sandboxed Lua state (invariant SBX-2,
/// design §5.3).
///
/// ISS-0169: before this existed, `executeScript` built its state inline while
/// `execution_test.zig`'s `sandboxedState()` built a DIFFERENT, more permissive
/// one (it called `luaopen_base` itself). Its doc comment claimed it built the
/// state "exactly as executeScript builds it"; that was false, and it meant the
/// green LUA-03 sandbox tests asserted against a state the product never
/// constructed (diagnosis R4). Both paths now go through this function, which
/// is what makes the LUA-03 evidence mean something.
///
/// ISS-0169 tranche 2 (design §3.1): gained `limits`, `limiter_storage`, and
/// `memory_limiter_storage`. Both storage pointers are caller-owned
/// (stack-allocated in `executeSource`), matching the existing `context`
/// parameter's ownership convention — this function never owns what it is
/// given a pointer to.
///
/// Order is load-bearing:
///   1. create the state — now via `MemoryLimiter.alloc`/`memory_limiter_storage`
///      instead of `defaultAlloc` (design §4)
///   2. open + prune the stdlib (invariant SBX-1 lives inside loadSafeStdlib)
///   3. install the execution context — BEFORE any closure exists, so no host
///      function is ever reachable from Lua before its context does (design
///      §2.3). `context.active_watchdog` (if set) rides this same channel.
///   4. install the run limiter + combined instruction/timeout hook (design §2)
///   5. register the platform.* table
///
/// Caller owns the state and must `lua_close` it.
pub fn createSandboxedState(
    context: *const ExecutionContext,
    limits: RunLimits,
    limiter_storage: *instruction_limiter.RunLimiter,
    memory_limiter_storage: *memory_limiter.MemoryLimiter,
) (errors.LuaError || stdlib.LibraryError)!*bindings.LuaState {
    // `limits` itself is not read here: `limiter_storage` and
    // `memory_limiter_storage` arrive already initialized from it by the
    // caller (`executeSource`), and the watchdog's deadline is likewise
    // resolved by the caller before this function runs. The parameter is
    // kept on this signature (design §3.1) so the limits a state was built
    // under are visible at the call site rather than implicit in two opaque
    // pointers.
    _ = limits;
    const L = bindings.lua_newstate(
        memory_limiter.MemoryLimiter.alloc,
        memory_limiter_storage,
    ) orelse return errors.LuaError.LuaAllocFailed;
    errdefer bindings.lua_close(L);

    try stdlib.loadSafeStdlib(L);
    try host_context.installContext(L, context);
    instruction_limiter.installLimiter(L, limiter_storage);
    host_api.registerAll(L, context) catch return errors.LuaError.ContextInstallFailed;

    return L;
}

/// Execute a Lua script with the given context and capabilities.
///
/// Signature unchanged (LUA-04's tests and other callers depend on it). It
/// performs NO manifest verification and reports `manifest_hash = null`. It
/// keeps the sandbox, the context installation and every capability gate — the
/// only thing it lacks relative to `executeScriptWithManifest` is manifest
/// verification. It must never become a way to bypass a gate.
///
/// ISS-0169 tranche 2 (design §3.2): now runs under `UNMANIFESTED_DEFAULT_LIMITS`
/// rather than unbounded — an unmanifested script that could run forever and
/// allocate without bound was a strictly weaker guarantee than the manifest
/// path for no documented reason.
pub fn executeScript(context: *const ExecutionContext, script_source: []const u8) !ScriptResult {
    return executeSource(context, script_source, null, UNMANIFESTED_DEFAULT_LIMITS);
}

/// Load-time entry point (LUA-07, design §6.4).
///
/// Every early exit is a REJECTION, and every rejection happens before any Lua
/// state is created — nothing is executed on a failed integrity check.
///
///   1. reject bytecode (must stay FIRST, so a bytecode artifact can never be
///      validated into acceptance)
///   2. verify the manifest hash against the script source and the hash the
///      repository recorded at registration
///   3. validate the manifest against the granted capability set and the
///      `Limits` bounds
///   4. only then create the sandboxed state and run
///
/// The returned `ScriptResult` carries the verified `manifest_hash`.
///
/// Note (design §6.5): the manifest's `max_instructions` / `max_memory_bytes` /
/// `timeout_seconds` are validated here and carried; NO limiter is installed by
/// this tranche. ISS-0169 tranche 2 (LUA-08/09/10) installs them.
pub fn executeScriptWithManifest(
    context: *const ExecutionContext,
    script_source: []const u8,
    script_manifest: *const manifest.ScriptManifest,
    registered_hash: [32]u8,
) (errors.LuaError || manifest.ManifestError || error{OutOfMemory})!ScriptResult {
    if (isBytecode(script_source)) {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, BYTECODE_REJECTION_MESSAGE),
        };
    }

    // Integrity before anything else: a manifest that does not match this
    // artifact means the pairing was never registered, so nothing runs.
    try manifest.verifyManifestHash(
        context.allocator,
        script_manifest,
        script_source,
        registered_hash,
    );

    // The declared capabilities must be within the granted set, and the limits
    // within the safe bounds. Both reject before any state is created.
    var validated = try manifest.validateManifest(
        script_manifest.capabilities,
        context.capabilities,
        script_manifest.max_instructions,
        script_manifest.max_memory_bytes,
        script_manifest.timeout_seconds,
        script_source,
        context.allocator,
    );
    defer validated.deinit();

    // CTX-2 forbids installing the address of a modified local copy of the
    // caller's context, so the hash is threaded through as a parameter and
    // written onto the result instead.
    //
    // ISS-0169 tranche 2 (design §3.2): RunLimits sourced from the manifest's
    // own already-validated fields — `validateManifest` above already
    // rejected out-of-bound values, so executeSource never re-validates them.
    return executeSource(context, script_source, registered_hash, RunLimits{
        .max_instructions = script_manifest.max_instructions,
        .max_memory_bytes = script_manifest.max_memory_bytes,
        .timeout_seconds = script_manifest.timeout_seconds,
    });
}

const BYTECODE_REJECTION_MESSAGE =
    "Bytecode is not allowed; only source text scripts are permitted";

/// Shared body of both entry points. `manifest_hash` is recorded on the result
/// and is null on the plain `executeScript` path. `limits` is resolved by the
/// caller (§3.2: `UNMANIFESTED_DEFAULT_LIMITS` or the verified manifest).
fn executeSource(
    context: *const ExecutionContext,
    script_source: []const u8,
    manifest_hash: ?[32]u8,
    limits: RunLimits,
) !ScriptResult {
    // Reject bytecode
    if (isBytecode(script_source)) {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, BYTECODE_REJECTION_MESSAGE),
            .manifest_hash = manifest_hash,
        };
    }

    // ISS-0169 tranche 2 (design §1.2/§3.3): storage for the combined
    // instruction+timeout limiter and the memory limiter, stack-allocated
    // here so both outlive the `lua_State` they are installed into (INV-1) —
    // `defer bindings.lua_close(L)` below runs strictly before this frame
    // returns.
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(
            context.allocator,
            limits.max_instructions,
        ),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(
        context.allocator,
        limits.max_memory_bytes,
    );

    // NEW (design §2.5.3): started before any Lua bytecode can possibly run
    // (state construction has not even begun yet), stopped via `defer` on
    // every exit path below. Spawn failure is a genuine new fallible step
    // this design introduces (`std.Thread.spawn` can fail) — treated the
    // same as any other setup failure: an early `ScriptResult` return rather
    // than silently running with no watchdog or propagating a raw
    // `SpawnError` past this function's all-failures-are-a-message
    // convention.
    var watchdog_state = timeout_ctx.WatchdogState.init(limits.timeout_seconds);
    var watchdog_handle = timeout_ctx.WatchdogHandle.start(&watchdog_state) catch {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, "could not start execution watchdog"),
            .manifest_hash = manifest_hash,
        };
    };
    defer watchdog_handle.stop();

    // NEW (design §2.5.4): a local copy carries the watchdog pointer onward.
    // The caller's `context.*` is never mutated (CTX-1..CTX-4 preserved) —
    // only this local copy's `active_watchdog` field is set, and it is this
    // local copy's address that gets installed into the registry below.
    var context_with_watchdog = context.*;
    context_with_watchdog.active_watchdog = &watchdog_state;

    // Create the sandboxed state through the single constructor (SBX-2).
    const L = createSandboxedState(
        &context_with_watchdog,
        limits,
        &limiter_storage,
        &mem_limiter_storage,
    ) catch |err| {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, describeSetupError(err)),
            .manifest_hash = manifest_hash,
        };
    };
    defer bindings.lua_close(L);

    // Compile the script.
    //
    // luaL_loadbuffer with an EXPLICIT length, not luaL_loadstring: the latter
    // takes [*:0]const u8, and `@ptrCast(script_source.ptr)` on a Zig slice
    // that carries no NUL terminator reads past the end of the buffer. The same
    // class of defect as fail.zig's lua_pushstring (design §4.4).
    const status = bindings.luaL_loadbuffer(
        L,
        script_source.ptr,
        script_source.len,
        "bpm_script",
    );
    if (status != 0) {
        const err_str = bindings.lua_tostring(L, -1);
        const err_msg = std.mem.span(err_str);
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, err_msg),
            .manifest_hash = manifest_hash,
        };
    }

    // Execute with protected call (0 args, 1 return value).
    //
    // A capability denial raised by a host function (host_context.requireCapability)
    // unwinds to here unless the script caught it with its own pcall, and
    // arrives as a non-zero status with the structured denial message on the
    // stack. That is how LUA-06's "raises a Lua error carrying function name,
    // capability required and capabilities granted" reaches the caller.
    const call_status = bindings.lua_pcall(L, 0, 1, 0);
    if (call_status != 0) {
        const err_str = bindings.lua_tostring(L, -1);
        const err_msg = std.mem.span(err_str);
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, err_msg),
            .manifest_hash = manifest_hash,
        };
    }

    // Extract result from stack
    var result = ScriptResult{
        .success = true,
        .value = null,
        .error_message = null,
        .manifest_hash = manifest_hash,
    };

    if (bindings.lua_gettop(L) > 0) {
        result.value = extractValue(L, -1, context.allocator) catch |err| switch (err) {
            // ISS-0161: extractValue's error set is LuaError || error{OutOfMemory}.
            // errorDescription takes LuaError only, so OutOfMemory must be split
            // out rather than described. An allocation failure is not a script
            // error and must propagate, not be recorded as one — the stubs hid
            // this because executeScript never reached here with a live state.
            error.OutOfMemory => return error.OutOfMemory,
            else => |lua_err| blk: {
                result.success = false;
                result.error_message = try context.allocator.dupe(u8, errors.errorDescription(lua_err));
                break :blk null;
            },
        };
    }

    return result;
}

/// Default allocator for Lua.
///
/// Uses the C allocator directly because LuaJIT calls this through a C ABI
/// function pointer and may realloc/free across the FFI boundary, which Zig's
/// allocator interface cannot service without the original slice length. This
/// is why the `lua` build module sets `link_libc = true` (build.zig).
///
/// ISS-0169 tranche 2 (design §4.2): `createSandboxedState` now calls
/// `bindings.lua_newstate` directly with `memory_limiter.MemoryLimiter.alloc`,
/// removing the `createState()` indirection this function used to sit behind.
/// `defaultAlloc` is deliberately RETAINED (not deleted): it remains useful as
/// a plain, unbounded allocator for any future test harness that wants to
/// construct a raw `lua_State` without limiter overhead. No test in this
/// tranche relies on it being the active allocator, so keeping it
/// unused-by-default is not a coverage gap.
fn defaultAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;

    if (nsize == 0) {
        if (ptr) |p| {
            std.c.free(p);
        }
        return null;
    }

    if (ptr) |p| {
        return std.c.realloc(p, nsize);
    } else {
        return std.c.malloc(nsize);
    }
}

/// Describe a state-setup failure. Split from `errors.errorDescription`
/// because `createSandboxedState`'s error set unions in `stdlib.LibraryError`,
/// which that exhaustive switch does not cover.
fn describeSetupError(err: (errors.LuaError || stdlib.LibraryError)) []const u8 {
    return switch (err) {
        error.FailedToLoadLibrary => "Failed to load the sandboxed standard library",
        else => |lua_err| errors.errorDescription(lua_err),
    };
}

/// Extract a value from the Lua stack at the given index.
fn extractValue(L: *bindings.LuaState, idx: c_int, allocator: std.mem.Allocator) !ScriptValue {
    const lua_type = bindings.lua_type(L, idx);

    return switch (lua_type) {
        bindings.LUA_TNIL => ScriptValue{ .nil_value = {} },
        bindings.LUA_TBOOLEAN => ScriptValue{ .boolean = bindings.lua_toboolean(L, idx) != 0 },
        bindings.LUA_TNUMBER => ScriptValue{ .number = bindings.lua_tonumber(L, idx) },
        bindings.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = bindings.lua_tolstring(L, idx, &len);
            const str = str_ptr[0..len];
            return ScriptValue{ .string = try allocator.dupe(u8, str) };
        },
        bindings.LUA_TTABLE => {
            const table = std.StringHashMap(ScriptValue).init(allocator);
            // Simplified table extraction (one level only for MVP)
            return ScriptValue{ .table = table };
        },
        else => errors.LuaError.TypeError,
    };
}
