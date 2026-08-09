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
    // WF03-GH592 rebase merge (ISS-0625 rco-sync): both GH-495's
    // active_watchdog (LUA-10) and GH-592's service_catalog + http_client_*
    // + instruction_limiter fields are required. Both fields default to null
    // and are caller-installed, so combining them is non-conflicting.
    /// LUA-10, design §2.5.4. Set by `executeSource` to the active
    /// host-external watchdog for this execution, right after the watchdog
    /// starts and before `createSandboxedState` installs the context — so
    /// `installContext`'s existing CTX-1..CTX-4 invariants apply to it
    /// unchanged (same pointer, same lifetime). Defaulted to `null` so no
    /// existing construction site (tests, other callers) breaks. Read by
    /// `host_context.activeWatchdogFired`, which `call_service.zig` calls
    /// before and after the body of `platformCallService`.
    active_watchdog: ?*const timeout_ctx.WatchdogState = null,
    /// LUA-12 (D-1). The catalog a real (non-simulation) `call_service`
    /// consults to resolve `svc_id` -> `RegisteredService`. Caller-owned,
    /// must outlive the context (CTX-1 invariant). Null when the caller
    /// has no catalog — in that case the real `call_service` path raises
    /// `"no service catalog installed"` for any non-simulation call, and
    /// the simulation path also raises the same. The simulation branch
    /// ALSO reads this field (defense-in-depth — design §3.3): a script
    /// calling `platform.call_service('unknown_svc', ...)` in simulation
    /// mode raises `"service '<id>' not registered"` rather than hitting
    /// the interceptor with a bogus fingerprint.
    service_catalog: ?*const service_catalog.ServiceCatalog = null,
    /// LUA-12 HTTP client. Function pointer; the engine injects the real
    /// implementation in production. Callers (tests) may inject a stub
    /// that returns a deterministic `ServiceCallResponse`. The signature
    /// matches the executor's contract: in arguments `endpoint`, `method`,
    /// `path`, `headers` slice, `body`, `auth_token` slice (or null);
    /// out is a `ServiceCallResponse` and an `HttpError` on transport
    /// failure (the stub returns a successful response).
    ///
    /// When `null`, the real `call_service` path raises `"no HTTP client
    /// installed"` — the engine-side worker is supposed to set this
    /// field; its absence is a misconfiguration, not a soft fallback.
    http_client_fn: ?*const HttpClientFn = null,
    /// LUA-12 HTTP client context. Opaque pointer passed alongside
    /// `http_client_fn` so the client can carry state. Lifetime is the
    /// caller's responsibility (must outlive the context; CTX-1).
    http_client_ctx: ?*const anyopaque = null,
    /// LUA-16 (D-3). Pointer to the limiter the executor reads after a
    /// failed pcall to populate `ScriptResult.script_error.instruction_count`.
    /// If null, the payload's `instruction_count` is 0 and the executor
    /// stamps `capabilities_at_failure` with the literal skip reason
    /// (`SKIP_REASON_NO_INSTRUCTION_LIMITER`). The pointer is set by
    /// `executeScript` itself in a future LUA-08 wiring; this run leaves
    /// it null (the default), so the payload is built in the
    /// "LUA-08 deferred" branch unconditionally.
    instruction_limiter: ?*const instruction_limiter.InstructionLimiter = null,
    // WF03-GH591 / ISS-0624 — LUA-11 + LUA-13 (ISS-0153 stub-era completion).
    // Four new fields on ExecutionContext per src/design/iss0624-gh591-lua-11-13-fix.md §2.
    // All four default to the documented "not configured" state, so the 12
    // existing ExecutionContext construction sites compile unchanged and
    // the pre-fix body of read_variable / write_variable / log (which gate
    // and return nil) continues to be reachable as the body-of-no-config path.
    /// LUA-13, design §18.2. Trace identifier written into every
    /// `StructuredLogEntry` emitted by `platform.log`. Lifetime = the caller's
    /// frame (CTX-1 invariant); pre-generated per-execution. Empty slice ""
    /// is the documented "no trace" state — `platform.log` will write an
    /// empty `trace=` field rather than raise.
    trace_id: []const u8 = "",
    /// LUA-11, design §16.2. Staging map for `write_variable` to land in,
    /// applied atomically on script success and discarded on failure.
    /// Owned by `executeSource`'s frame (stack-allocated there); the
    /// pointer here is into that frame. Null = no staging installed —
    /// `write_variable` becomes a no-op, `read_variable` reads through
    /// to instance_state only (no read-after-write within an execution).
    pending_writes: ?*std.StringHashMap(ScriptValue) = null,
    /// LUA-13, design §23.5. Caller-installed structured logger.
    /// `platform.log` consults this and is fail-open when null (the
    /// fail-open asymmetry vs the capability gate is documented in
    /// design §5.2). Lifetime = caller's frame.
    structured_logger: ?*const structured_logger.StructuredLogger = null,
    /// LUA-11, design §16.2. Caller-installed committed variable map (the
    /// apply target for staged writes). Defaults to a file-scope
    /// `dummy_instance_state` singleton because `StringHashMap(ScriptValue)`
    /// cannot be initialised in a struct literal under Zig 0.16 (it
    /// requires an allocator at construction time); see design §4.5.
    /// The default is unreachable through any code path that has not
    /// opted in: `write_variable` and `read_variable` both gate on
    /// `pending_writes != null` first.
    instance_state: *InstanceState = &dummy_instance_state,
};

/// LUA-11, design §16.2. The per-instance committed variable container.
///
/// `.variables` is a `StringHashMap(ScriptValue)`; `.deinit` walks it,
/// freeing both keys and recursive values via `ScriptValue.deinit` (already
/// fixed by ISS-0161).
///
/// The `init(allocator, instance_id)` constructor is the only safe way to
/// construct one — the `empty` const that would be the natural struct
/// literal cannot work because `StringHashMap`'s constructor takes an
/// `Allocator` (not an optional), so `empty.variables` would have to be
/// `undefined`, which is silently wrong if anyone ever reads it before
/// any write. See design §4.5.
pub const InstanceState = struct {
    instance_id: []const u8,
    variables: std.StringHashMap(ScriptValue),

    pub fn init(allocator: std.mem.Allocator, instance_id: []const u8) InstanceState {
        return .{
            .instance_id = instance_id,
            .variables = std.StringHashMap(ScriptValue).init(allocator),
        };
    }

    /// Free every key and every recursive ScriptValue, then release the
    /// bucket array. Mirrors the same recursive pass as `ScriptValue.deinit`
    /// (ISS-0161 fix).
    pub fn deinit(self: *InstanceState) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.variables.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.variables.allocator);
        }
        self.variables.deinit();
    }
};

/// File-scope dummy InstanceState used as the default value of
/// `ExecutionContext.instance_state` (design §4.5).
///
/// `StringHashMap`'s constructor takes a real allocator, so a struct-literal
/// default would have to leave `.variables` undefined. Using a `page_allocator`
/// singleton is acceptable because the only code path that touches this default
/// is the dummy commit path, and that path's destructor is never called (its
/// `deinit` would free from `page_allocator`, which is acceptable for tests
/// that never read the dummy). The default is unreachable through any
/// caller-opted-in code path (write_variable and read_variable gate on
/// `pending_writes != null` first).
var dummy_instance_state: InstanceState = blk: {
    // Compile-time page allocator is fine: `std.heap.page_allocator` is a
    // function-call wrapper in Zig 0.16; we evaluate it once at static init
    // time via a comptime block. The resulting dummy state is never read by
    // any production code path because `pending_writes == null` short-circuits
    // before the commit/extract sequence reaches it.
    const alloc = std.heap.page_allocator;
    break :blk InstanceState.init(alloc, "dummy-default-instance");
};

/// LUA-12 Response shape returned by the HTTP client function pointer.
/// Heap-allocated by the client; caller (the executor) frees via `deinit`.
pub const ServiceCallResponse = struct {
    status_code: i32,
    body: []const u8,
    headers: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ServiceCallResponse) void {
        self.allocator.free(self.body);
        for (self.headers.items) |h| self.allocator.free(h);
        self.headers.deinit(self.allocator);
    }
};

/// LUA-12 HTTP error. The client returns this on transport-level failure
/// (connection refused, timeout, DNS, TLS). The executor maps it to a
/// structured Lua table `{error = "...", status_code = 0}` and pushes it
/// to the script. A 4xx/5xx is NOT an error here — the executor sees the
/// status code in `status_code` and pushes a normal response table.
pub const HttpError = error{
    ConnectionRefused,
    Timeout,
    DnsFailure,
    TlsFailure,
    UnknownTransportError,
};

/// LUA-12 HTTP client function pointer signature. The engine injects the
/// real implementation; tests inject a stub that returns deterministic
/// responses.
pub const HttpClientFn = fn (
    ctx: ?*const anyopaque,
    endpoint: []const u8,
    method: []const u8,
    path: []const u8,
    headers: []const []const u8,
    body: []const u8,
    auth_token: ?[]const u8,
    allocator: std.mem.Allocator,
) HttpError!ServiceCallResponse;

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
    /// LUA-15: discriminator between runtime Lua errors, explicit
    /// `platform.fail` calls, and load-time compile failures. `.Success` is
    /// the only kind that has `value` set; the others have `error_message`
    /// set (and `.RuntimeError` may additionally have `script_error` set —
    /// see LUA-16).
    error_kind: ErrorKind = .Success,
    /// LUA-16: populated only when `error_kind == .RuntimeError` AND the
    /// LUA-08 instruction-count source was installed in this run. Null
    /// otherwise (the executor still records the skip reason in the
    /// payload's `capabilities_at_failure` slot when the limiter is null).
    script_error: ?events.ScriptErrorPayload = null,

    pub fn deinit(self: *ScriptResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.value) |val| {
            val.deinit(allocator);
        }
        if (self.script_error) |*payload| {
            payload.deinit(allocator);
        }
    }
};

/// LUA-15 / LUA-16 discriminator.
///
/// The order is meaningful: `.Success` first because that is the common
/// path, and the switch in `executeSource` must be exhaustive over all
/// four without a fallthrough. `.CompileError` covers both bytecode
/// rejection and `luaL_loadbuffer` failures; `.RuntimeError` covers
/// everything `lua_pcall` reports; `.ExplicitFailure` is set only when
/// the LUA-15 discriminator reads `bpm.explicit_failure` truthy from the
/// registry.
pub const ErrorKind = enum {
    Success,
    CompileError,
    RuntimeError,
    ExplicitFailure,
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

/// LUA-16: skip reason written to `ScriptErrorPayload.capabilities_at_failure`
/// when the LUA-08 instruction-count source is NOT installed in this run
/// (decision D-3 in src/design/iss0625-gh592-lua-12-15-16.md). Any future
/// edit of this string is a test change — both TC-LUA-16-impl-05 and the
/// executor's payload construction assert against it.
pub const SKIP_REASON_NO_INSTRUCTION_LIMITER: []const u8 =
    "skip: instruction_count source not installed (LUA-08 deferred)";

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
            .error_kind = .CompileError,
        };
    }

    // WF03-GH592 rebase merge (ISS-0625 rco-sync): both GH-495's combined
    // limiter+watchdog (LUA-08/09/10) and GH-592's setActive for the
    // ServiceCatalog+HTTPLClient+LUA-16 instruction-limiter pointer
    // (LUA-12/16) belong in this scope. They are independent initializations
    // — main's block starts the watchdog and binds the local
    // `context_with_watchdog`; branch's block wires the thread-local catalog.
    // Order: storage first (no side effects), then watchdog (so the local
    // context copy can be set), then setActive (which is just a thread-local
    // write). Both scoped by their own defer.
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

    // LUA-12 (D-1): wire the active catalog and http_client_fn for this
    // script invocation. platform.call_service reads them from
    // thread-locals set by host_api.call_service.setActive. The active set
    // is restored to null on scope exit so the next script starts clean.
    host_api.call_service.setActive(
        context.service_catalog,
        context.http_client_fn,
        context.http_client_ctx,
    );
    defer host_api.call_service.setActive(null, null, null);

    // WF03-GH591 / ISS-0624 — LUA-11 (design §16.2). Stack-allocate the
    // staging map, install the pointer on the local context copy (mirrors
    // the active_watchdog pattern two blocks above — same CTX-1..CTX-4
    // invariant, the caller's context is never mutated). The map lives
    // strictly inside this frame. On script SUCCESS the apply step
    // MOVES entries into `context.instance_state.variables` and then
    // `clearRetainingCapacity()` drops the bookkeeping while keeping the
    // bucket array; on script FAILURE the entries are freed by the
    // `defer` chain below (pending_writes_free+deinit) so the staged
    // writes and duped keys are released back to the allocator.
    var pending_writes = std.StringHashMap(ScriptValue).init(context.allocator);
    defer {
        // Free any remaining entries (this is the failure path — the
        // success path has cleared the map via clearRetainingCapacity
        // by the time this defer runs).
        var it = pending_writes.iterator();
        while (it.next()) |entry| {
            context.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(context.allocator);
        }
        pending_writes.deinit();
    }
    context_with_watchdog.pending_writes = &pending_writes;

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
            .error_kind = .CompileError,
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
            .error_kind = .CompileError,
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

        // LUA-15 / LUA-16: classify the failure. The LUA-15 discriminator
        // (`bpm.explicit_failure`) is read FIRST so an explicit failure is
        // never mis-classified as a runtime error. If it is explicit, no
        // stack trace is captured (explicit failure is a deliberate API,
        // not a debug signal). If it is not explicit, capture the stack
        // trace and build a `ScriptErrorPayload` conditionally on the
        // LUA-08 instruction-count source.
        const view = host_context.readExplicitFailure(L, context.allocator);
        defer {
            // Free the owned copies inside the view.
            if (view.reason) |r| context.allocator.free(r);
            if (view.details) |*d| d.deinit(context.allocator);
        }
        // Always clear the discriminator so a subsequent script (or a
        // subsequent fail call from the same call stack) does not inherit
        // stale state.
        host_context.clearExplicitFailure(L);

        if (view.kind == .Explicit) {
            // LUA-15: explicit failure. Use the registry's reason as the
            // authoritative text (defense-in-depth: the script may have
            // raised with a different Lua error message), but the
            // `lua_pcall` error message is what reached the script author
            // — keep that for the side-channel.
            const reason_for_msg = view.reason orelse err_msg;
            return ScriptResult{
                .success = false,
                .value = null,
                .error_message = try context.allocator.dupe(u8, reason_for_msg),
                .manifest_hash = manifest_hash,
                .error_kind = .ExplicitFailure,
                .script_error = null,
            };
        }

        // LUA-16: runtime error. Capture the stack trace and build the
        // payload conditionally (D-3 of the design).
        const stack_trace = captureStackTrace(L, context.allocator) catch "";
        defer if (stack_trace.len > 0) context.allocator.free(stack_trace);

        const payload = events.buildScriptErrorPayload(
            err_msg,
            stack_trace,
            context.instruction_limiter,
            SKIP_REASON_NO_INSTRUCTION_LIMITER,
            context.allocator,
        ) catch {
            // builder failed; report a minimal discriminator so the caller
            // still has the error_message.
            return ScriptResult{
                .success = false,
                .value = null,
                .error_message = try context.allocator.dupe(u8, err_msg),
                .manifest_hash = manifest_hash,
                .error_kind = .RuntimeError,
                .script_error = null,
            };
        };

        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, err_msg),
            .manifest_hash = manifest_hash,
            .error_kind = .RuntimeError,
            .script_error = payload,
        };
    }

    // WF03-GH591 / ISS-0624 — LUA-11 (design §4.3). Apply pending_writes
    // atomically on script success. The map entries are MOVED (not copied)
    // into `instance_state.variables` so the subsequent
    // `defer pending_writes.deinit()` does not double-free them. After the
    // move, `clearRetainingCapacity` drops the bookkeeping while keeping the
    // bucket array, so the deinit runs cleanly on the (now-empty) map.
    //
    // When `instance_state == &dummy_instance_state` (the file-scope
    // page-allocator singleton that is the default for callers that did
    // not install an InstanceState — e.g. the `runWithGrants` helper in
    // execution_test.zig), the entries are FREED instead of moved. The
    // dummy's `StringHashMap` uses page_allocator for its bucket array,
    // so moving duped-with-`context.allocator` keys into it would leak
    // the key/value when the dummy is never deinit'd (it's a static
    // singleton) AND would cross-allocator free the prior entry on the
    // next write. This preserves the design §4.5 "singleton default" but
    // makes the body-of-no-config path correctly free the staged writes
    // instead of leaking them into the dummy.
    if (context.instance_state == &dummy_instance_state) {
        var it = pending_writes.iterator();
        while (it.next()) |entry| {
            context.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(context.allocator);
        }
        pending_writes.clearRetainingCapacity();
    } else {
        var it = pending_writes.iterator();
        while (it.next()) |entry| {
            // entry.key_ptr.* and entry.value_ptr.* are owned by
            // pending_writes; instance_state.variables takes ownership
            // without copying. Any prior entry under the same key is freed
            // first to avoid a leak (the map will replace it).
            //
            // LUA-11 design §6.2 TC-09: a write of nil_value drops the
            // key rather than storing a nil sentinel (the read path
            // cannot distinguish "never written" from "written as nil").
            // We free the staged key here because it is owned by
            // pending_writes and instance_state.variables is not taking
            // ownership.
            if (entry.value_ptr.* == .nil_value) {
                if (context.instance_state.variables.fetchRemove(entry.key_ptr.*)) |prev| {
                    context.instance_state.variables.allocator.free(prev.key);
                    prev.value.deinit(context.instance_state.variables.allocator);
                }
                context.allocator.free(entry.key_ptr.*);
                continue;
            }
            if (context.instance_state.variables.fetchRemove(entry.key_ptr.*)) |prev| {
                context.instance_state.variables.allocator.free(prev.key);
                prev.value.deinit(context.instance_state.variables.allocator);
            }
            try context.instance_state.variables.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        pending_writes.clearRetainingCapacity();
    }

    // Extract result from stack
    var result = ScriptResult{
        .success = true,
        .value = null,
        .error_message = null,
        .manifest_hash = manifest_hash,
    };

    if (bindings.lua_gettop(L) > 0) {
        var extracted: ScriptValue = .{ .nil_value = {} };
        extractValueInto(L, -1, context.allocator, &extracted) catch |err| switch (err) {
            // extractValueInto's error set mirrors extractValue's:
            // LuaError || error{OutOfMemory}. The asymmetry between
            // allocation failure (propagate) and Lua-level type failure
            // (record as a script error) is preserved.
            error.OutOfMemory => return error.OutOfMemory,
            else => |lua_err| {
                result.success = false;
                result.error_message = try context.allocator.dupe(u8, errors.errorDescription(lua_err));
            },
        };
        // Only install the extracted value when extraction succeeded; on
        // a Lua-level type failure the success flag is already cleared
        // and we leave the value as null.
        if (result.success) result.value = extracted;
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

/// LUA-16: capture a stack trace of the failing execution via
/// `lua_getstack` / `lua_getinfo` (decision D-4 in src/design/iss0625-gh592-lua-12-15-16.md).
///
/// Returns a single allocated string of the form
/// `  at <chunk>:<line> in '<name>'\n` per frame, the deepest frame first.
/// Allocator is the caller's `allocator`. Empty walk = empty string (NOT
/// null). On any unwrap failure the function returns an empty string and
/// leaves the cursor at a clean stack depth — the caller must still call
/// `lua_pop` if it expected a value on the stack.
///
/// The walk uses `lua_getinfo`'s `"Sl"` (Source, current Line) field set
/// (LUJIT 2.1 / Lua 5.1 API). `name` is the local function name if
/// available; the chunk is the source name set at `luaL_loadbuffer` time
/// (`"bpm_script"` for our entry point).
pub fn captureStackTrace(L: *bindings.LuaState, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var level: c_int = 0;
    var ar: bindings.lua_Debug = .{
        .event = 0,
        .name = null,
        .namewhat = null,
        .what = null,
        .source = null,
        .currentline = 0,
        .nups = 0,
        .linedefined = 0,
        .lastlinedefined = 0,
        .short_src = [_]u8{0} ** 60,
        .i_ci = 0,
    };

    while (bindings.lua_getstack(L, level, &ar) != 0) : (level += 1) {
        // "Sl" = source + current line. Returns 0 on failure.
        if (bindings.lua_getinfo(L, "Sl", &ar) == 0) {
            continue;
        }

        const source = if (ar.source) |s| std.mem.span(s) else "bpm_script";
        const line = ar.currentline;
        const name = if (ar.name) |n| std.mem.span(n) else "";

        const frame = if (name.len > 0)
            try std.fmt.allocPrint(allocator, "  at {s}:{d} in '{s}'\n", .{ source, line, name })
        else
            try std.fmt.allocPrint(allocator, "  at {s}:{d}\n", .{ source, line });
        defer allocator.free(frame);
        try out.appendSlice(allocator, frame);
    }

    return try out.toOwnedSlice(allocator);
}

/// WF03-GH591 / ISS-0624 — LUA-11 (design §5.4). Recursive value extraction.
///
/// `extractValue` (the script-return helper below) returns an EMPTY
/// StringHashMap when it encounters a table — a documented partial
/// extraction. `write_variable` and `log` cannot use that because the
/// table the script tried to write would be silently dropped.
///
/// This helper writes through a caller-allocated `*ScriptValue`, walking
/// tables recursively with owned copies for string keys/values. It rejects
/// integer table keys (`errors.LuaError.TypeError`) because
/// `instance_state.variables` is a `StringHashMap(ScriptValue)` — integer
/// keys cannot be carried there. (See design §9.2 for the open question on
/// whether stringification should replace strict rejection.)
///
/// Errors:
///   - `errors.LuaError.TypeError` on a non-string table key or on a value
///     type that is not in `ScriptValue`'s type set.
///   - `error.OutOfMemory` on allocation failure.
///
/// On any error, the partial `*out` is left in a state safe to ignore —
/// the caller never reads from `out` after this function returns an error
/// (the only call sites are `write_variable`, where the entry has not yet
/// been put into `pending_writes`, and `log`, where the entry has not yet
/// been passed to `StructuredLogger.log`).
pub fn extractValueInto(
    L: *bindings.LuaState,
    idx: c_int,
    allocator: std.mem.Allocator,
    out: *ScriptValue,
) (errors.LuaError || std.mem.Allocator.Error)!void {
    const rel = if (idx < 0) bindings.lua_gettop(L) + idx + 1 else idx;
    const lua_type = bindings.lua_type(L, idx);
    switch (lua_type) {
        bindings.LUA_TNIL => {
            out.* = ScriptValue{ .nil_value = {} };
            return;
        },
        bindings.LUA_TBOOLEAN => {
            out.* = ScriptValue{ .boolean = bindings.lua_toboolean(L, idx) != 0 };
            return;
        },
        bindings.LUA_TNUMBER => {
            out.* = ScriptValue{ .number = bindings.lua_tonumber(L, idx) };
            return;
        },
        bindings.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = bindings.lua_tolstring(L, idx, &len);
            const str = str_ptr[0..len];
            out.* = ScriptValue{ .string = try allocator.dupe(u8, str) };
            return;
        },
        bindings.LUA_TTABLE => {
            // Two-pass table walk: count, then `ensureTotalCapacity` to
            // pre-size the map (avoids rehashing), then extract. errdefer
            // walks the partial entries to free any keys/values already
            // duped if we fail mid-walk.
            //
            // Stack-balance invariant: `lua_next` POPS the key we pushed
            // (or its predecessor) AND, on success, pushes the next
            // key+value (so the stack grows by one item each iteration).
            // On end-of-iteration (returns 0) it pops the key it was
            // given and pushes nothing — net effect is the stack is back
            // to its state before the matching `lua_pushnil`. Therefore
            // we NEVER pop after the loop: the trailing "pop" some
            // idioms use is only needed when the loop is exited via
            // break/Lua-error mid-iteration, which we don't do here.
            var count: usize = 0;
            bindings.lua_pushnil(L);
            while (bindings.lua_next(L, rel) != 0) {
                count += 1;
                bindings.lua_pop(L, 1); // pop value, keep key for next iteration
            }

            var map = std.StringHashMap(ScriptValue).init(allocator);
            errdefer {
                var it = map.iterator();
                while (it.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    e.value_ptr.deinit(allocator);
                }
                map.deinit();
            }
            try map.ensureTotalCapacity(@intCast(count));

            bindings.lua_pushnil(L);
            while (bindings.lua_next(L, rel) != 0) {
                // stack: key, value
                // Reject non-string keys. lua_tolstring coerces numbers in
                // Lua 5.1 (the same E11 defect that motivated `checkString`);
                // we guard against it explicitly by inspecting the type of
                // the key first.
                if (bindings.lua_type(L, -2) != bindings.LUA_TSTRING) {
                    bindings.lua_pop(L, 2); // pop key + value before raising
                    return errors.LuaError.TypeError;
                }
                var key_len: usize = 0;
                const key_ptr = bindings.lua_tolstring(L, -2, &key_len);
                const key_str = key_ptr[0..key_len];
                const key_owned = try allocator.dupe(u8, key_str);

                var value_owned: ScriptValue = .{ .nil_value = {} };
                try extractValueInto(L, -1, allocator, &value_owned);

                try map.put(key_owned, value_owned);

                bindings.lua_pop(L, 1); // pop value, keep key for next iter
            }

            out.* = ScriptValue{ .table = map };
            return;
        },
        else => return errors.LuaError.TypeError,
    }
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
