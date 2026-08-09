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
    /// LUA-13, design §18.2 (ISS-0624 / GH #591). Correlation id threaded
    /// through to every `StructuredLogEntry` this execution emits. Defaults
    /// to `""` (pre-fix behaviour) — callers that need a real trace id
    /// install it explicitly.
    trace_id: []const u8 = "",
    /// LUA-11, design §16.2 (ISS-0624 / GH #591). Staging map for
    /// `platform.write_variable`, installed by `executeSource` onto its own
    /// local context copy (same local-copy-and-pointer-install pattern as
    /// `active_watchdog`, LUA-10). Owned by `executeSource`'s frame. `null`
    /// means "no staging map wired" — both `read_variable` and
    /// `write_variable` become defensive no-ops (design §5.3), which is the
    /// pre-fix, backward-compatible default.
    pending_writes: ?*std.StringHashMap(ScriptValue) = null,
    /// LUA-13, design §23.5 (ISS-0624 / GH #591). Caller-installed structured
    /// logger. `null` means "no logger installed" — `platform.log` is a
    /// fail-open no-op in that case (design §5.2): a missing logger is not a
    /// script failure.
    structured_logger: ?*const structured_logger.StructuredLogger = null,
    /// LUA-11, design §16.2 (ISS-0624 / GH #591). Caller-installed committed
    /// variable map — the apply target for staged writes. Defaults to a
    /// file-scope `dummy_instance_state` singleton (see design §4.5 for why a
    /// plain struct literal default is unsafe for `StringHashMap`). Reads of
    /// `.variables` on the default are unreachable through any code path that
    /// has not opted in by also wiring `pending_writes` — see `read_variable`
    /// / `write_variable`, which both gate on `pending_writes != null` first.
    instance_state: *InstanceState = &dummy_instance_state,
};

/// LUA-11, design §4.4 (ISS-0624 / GH #591). Canonical per-instance variable
/// container — the apply target `executeSource` merges `pending_writes` into
/// on a successful `lua_pcall`. `.variables` always has a valid `Allocator`;
/// `.deinit` must be called exactly once per `init`.
pub const InstanceState = struct {
    instance_id: []const u8,
    variables: std.StringHashMap(ScriptValue),

    pub fn init(allocator: std.mem.Allocator, instance_id: []const u8) InstanceState {
        return .{
            .instance_id = instance_id,
            .variables = std.StringHashMap(ScriptValue).init(allocator),
        };
    }

    /// Frees every key and every (recursively-owned) `ScriptValue` in
    /// `.variables`, then the map's own storage.
    pub fn deinit(self: *InstanceState) void {
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.variables.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.variables.allocator);
        }
        self.variables.deinit();
    }
};

/// LUA-11, design §4.5 (ISS-0624 / GH #591). The safe default for
/// `ExecutionContext.instance_state`.
///
/// `StringHashMap`'s constructor takes an `Allocator`, not a `?Allocator`, so
/// there is no zero-cost `const` literal for `InstanceState` that does not
/// risk a caller reading `.variables` while it is `undefined`. The design
/// (§4.5) rejects both an `undefined`-backed literal and a `var`-marked
/// dummy allocator reference for that reason, and rejects forcing every
/// existing construction site to call `.init()` for scope reasons (~80 line
/// diff). The resolution is this single file-scope singleton, initialised
/// once via `InstanceState.init` against `std.heap.page_allocator`.
///
/// Its `.variables` map is reachable ONLY through code that has also opted
/// in by wiring `pending_writes` (both `read_variable` and `write_variable`
/// gate on `pending_writes != null` before ever touching `instance_state`),
/// so a caller that leaves both fields at their defaults never reads or
/// writes through this singleton in a way that is observable. Its `deinit`
/// is intentionally never called — freeing from `page_allocator` is
/// acceptable for the tests that construct a default `ExecutionContext` and
/// never read the dummy.
var dummy_instance_state: InstanceState = InstanceState.init(
    std.heap.page_allocator,
    "default-empty-instance",
);

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

    // LUA-11, design §4.1 (ISS-0624 / GH #591): the staging map for
    // `platform.write_variable`. Owned by THIS frame, stack-allocated, same
    // local-copy-and-pointer-install pattern already used for
    // `active_watchdog` above. `defer discardPendingWrites` runs on every
    // exit path — success (after the commit loop has drained it via
    // `clearRetainingCapacity`, so the free-loop below finds it already
    // empty and is a no-op) and failure (where it walks and frees every
    // staged key and ScriptValue, discarding them — plain
    // `StringHashMap.deinit()` alone would only free the map's own bucket
    // storage, not the u8 slices/ScriptValues it points at, which is the
    // owning relationship §4.2/§4.6 of the design documents).
    var pending_writes = std.StringHashMap(ScriptValue).init(context.allocator);
    defer discardPendingWrites(&pending_writes);
    context_with_watchdog.pending_writes = &pending_writes;

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

    // ISS-0628 / GH-595 (design §2): push the message handler BEFORE the
    // chunk, and capture its ABSOLUTE stack index via lua_gettop immediately
    // after — before anything else is pushed. The Lua message-handler
    // contract requires the handler to be pushed before the
    // function-to-be-called and its arguments, and requires an absolute
    // index (not relative/negative) as lua_pcall's 4th argument, because by
    // the time lua_pcall is invoked the chunk has already been pushed on
    // top of the handler.
    bindings.lua_pushcclosure(L, errfuncHandler, 0);
    const handler_index = bindings.lua_gettop(L);

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
    //
    // ISS-0628 / GH-595 (design §2.2 step 5): the only line-level change to
    // the call itself — errfunc argument is handler_index instead of the
    // literal 0, so errfuncHandler runs while the erroring frames are still
    // live.
    const call_status = bindings.lua_pcall(L, 0, 1, handler_index);
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

        // LUA-16: runtime error. Read the stack trace errfuncHandler already
        // captured while the erroring frames were still live (ISS-0628 /
        // GH-595, design §3.3 — captureStackTrace can no longer be called
        // here directly: by this point lua_pcall has already returned and
        // the frames are gone) and build the payload conditionally (D-3 of
        // the design).
        const stack_trace = host_context.readStackTrace(L, context.allocator);
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

    // LUA-11, design §3.1/§4.3 (ISS-0624 / GH #591): the script succeeded —
    // atomically merge the staged writes into the committed instance state.
    // This is a MOVE, not a copy: `instance_state.variables.put` takes
    // ownership of the entry's key/value pointees directly out of
    // `pending_writes`, then `clearRetainingCapacity` drains the map's own
    // bookkeeping WITHOUT freeing the (now-moved) entries, so the
    // `defer discardPendingWrites` above finds an empty map and is a no-op.
    //
    // TC-ISS-0624-LUA-11-09 (design §6.2): writing `.nil_value` to a key
    // DROPS the entry from the committed map rather than storing a nil
    // sentinel — `StringHashMap.remove` is cheaper, and `read_variable`
    // already falls through to Lua nil on a missing key, so the two are
    // observationally identical to the script.
    {
        var it = pending_writes.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // If this key already had a committed value, free it before
            // overwriting/removing — otherwise a script that writes the
            // same key across multiple executeScript calls leaks the
            // PREVIOUS execution's committed value. Freed with
            // `context.allocator`: every committed entry currently in
            // `instance_state.variables` was itself put there by THIS same
            // merge loop in a prior call, using a key/value duped from
            // `pending_writes` (i.e. from `context.allocator`) — never from
            // `instance_state.variables`'s own `.allocator` field, which for
            // the `dummy_instance_state` default is `page_allocator` and
            // would panic (wrong allocator) if used to free memory this
            // function actually allocated.
            if (context.instance_state.variables.fetchRemove(key)) |old| {
                context.allocator.free(old.key);
                var old_value = old.value;
                old_value.deinit(context.allocator);
            }

            if (value == .nil_value) {
                // Drop: free the staged key (never inserted), the staged
                // value is `.nil_value` and owns nothing.
                context.allocator.free(key);
            } else {
                try context.instance_state.variables.put(key, value);
            }
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

/// ISS-0628 / GH-595: fixed size of the stack buffer `writeStackFrames`
/// writes into from inside `errfuncHandler`. `errfuncHandler` runs during
/// `lua_pcall`'s own error unwind, before control returns to any Zig frame
/// that owns an allocator reference in scope (design §1.1) — it must never
/// allocate, so the buffer is fixed-size and truncates rather than growing
/// unboundedly. 4096 is not a regression on any currently-passing test:
/// `captureStackTrace` had no depth cap before this change either, and the
/// deepest chain in the existing test suite (4 frames) uses a small
/// fraction of this.
const STACK_TRACE_BUFFER_BYTES: usize = 4096;

/// Append-only writer over a caller-owned fixed buffer, used by
/// `writeStackFrames`. Silent truncation past capacity is an accepted
/// degradation (design §1.1) — a truncated trace, not a failure — the same
/// judgement call `host_context.zig`'s own `Writer` makes for diagnostic
/// text.
const FixedWriter = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) FixedWriter {
        return .{ .buf = buf };
    }

    fn put(self: *FixedWriter, text: []const u8) void {
        if (self.len >= self.buf.len) return;
        const room = self.buf.len - self.len;
        const n = @min(room, text.len);
        @memcpy(self.buf[self.len .. self.len + n], text[0..n]);
        self.len += n;
    }

    fn putInt(self: *FixedWriter, value: c_int) void {
        var scratch: [24]u8 = undefined;
        const rendered = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
        self.put(rendered);
    }

    /// Append one frame in the shared `"  at <chunk>:<line> in '<name>'\n"`
    /// format (or `"  at <chunk>:<line>\n"` when the frame has no name) —
    /// identical shape to `captureStackTrace`'s pre-existing per-frame
    /// output, now the single place this formatting lives (design §1.1).
    fn writeFrame(self: *FixedWriter, ar: *const bindings.lua_Debug) void {
        const source = if (ar.source) |s| std.mem.span(s) else "bpm_script";
        const name = if (ar.name) |n| std.mem.span(n) else "";

        self.put("  at ");
        self.put(source);
        self.put(":");
        self.putInt(ar.currentline);
        if (name.len > 0) {
            self.put(" in '");
            self.put(name);
            self.put("'");
        }
        self.put("\n");
    }
};

/// LUA-16 / ISS-0628: shared, allocator-free walk of the live Lua call
/// stack via `lua_getstack` / `lua_getinfo`, writing formatted frames into
/// `buf`. Used both by `errfuncHandler` (called live, during `lua_pcall`'s
/// unwind, buffer-based per design §1.1) and by `captureStackTrace` below
/// (allocator-based entry point, kept for TC-ISS-0625-LUA-16-02). Returns
/// the number of bytes written.
///
/// The walk uses `lua_getinfo`'s `"Sl"` (Source, current Line) field set
/// (LuaJIT 2.1 / Lua 5.1 API). `name` is the local function name if
/// available; the chunk is the source name set at `luaL_loadbuffer` time
/// (`"bpm_script"` for our entry point).
fn writeStackFrames(L: *bindings.LuaState, buf: []u8) usize {
    var writer = FixedWriter.init(buf);
    var level: c_int = 0;
    var ar: bindings.lua_Debug = .{};

    while (bindings.lua_getstack(L, level, &ar) != 0) : (level += 1) {
        // "Sln" = source + current line + name/namewhat. The "n" selector is
        // required for lj_debug_getinfo to populate ar.name at all
        // (vendor/luajit/src/lj_debug.c: the 'n' branch is the only one that
        // calls lj_debug_funcname; without it ar->name is left as whatever
        // was in the (possibly stale) struct, which for a fresh lua_Debug is
        // always null) — omitting it silently produced frames with no name
        // in every case, which is why writeFrame's `if (name.len > 0)`
        // branch was previously unreachable in practice. Returns 0 on
        // failure to look up the frame.
        if (bindings.lua_getinfo(L, "Sln", &ar) == 0) {
            continue;
        }
        writer.writeFrame(&ar);
    }

    return writer.len;
}

/// ISS-0628 / GH-595: message-handler (`errfunc`) installed as `lua_pcall`'s
/// 4th argument (§2). Per the Lua 5.1 / LuaJIT 2.1 `lua_pcall` contract,
/// this is invoked *at the moment the error is raised*, while the erroring
/// call frames are still live on the stack — unlike `captureStackTrace`
/// called after `lua_pcall` has already returned, where the frames are gone.
///
/// Writes the captured trace into `host_context.STACK_TRACE_KEY` on the Lua
/// registry (design §3.2), then returns the ORIGINAL error value completely
/// unchanged: a transparent pass-through. This function must not allocate
/// (design §1.1) — it runs during `lua_pcall`'s own unwind, before control
/// returns to any Zig frame that owns an allocator reference in scope.
fn errfuncHandler(L: *bindings.LuaState) callconv(.c) c_int {
    var buffer: [STACK_TRACE_BUFFER_BYTES]u8 = undefined;
    const len = writeStackFrames(L, &buffer);

    bindings.lua_pushlstring(L, &buffer, len);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, host_context.STACK_TRACE_KEY);

    // Transparent pass-through: the error value passed as this handler's
    // sole argument (stack index 1) is left exactly where it started — not
    // popped, not replaced — so whatever is on the stack when this function
    // returns becomes lua_pcall's error object, bit-for-bit identical to
    // what the script itself raised (design §3.2).
    return 1;
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
/// ISS-0628 / GH-595: internally delegates to the shared, allocator-free
/// `writeStackFrames` primitive (also used by `errfuncHandler`) via a fixed
/// scratch buffer — kept as the allocator-based entry point for
/// TC-ISS-0625-LUA-16-02 (idle-stack unit test). The *production* call site
/// in `executeSource` no longer calls this function directly; it reads the
/// trace `errfuncHandler` already captured via `host_context.readStackTrace`
/// instead (design §3.3), because by the time `executeSource` would call
/// this function the erroring frames are already gone.
pub fn captureStackTrace(L: *bindings.LuaState, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [STACK_TRACE_BUFFER_BYTES]u8 = undefined;
    const len = writeStackFrames(L, &buffer);
    return try allocator.dupe(u8, buffer[0..len]);
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

/// LUA-11, design §4.1/§4.2 (ISS-0624 / GH #591). Discard every staged
/// write: free each key and each `ScriptValue`'s owned bytes (recursively —
/// `ScriptValue.deinit` already handles nested tables), then release the
/// map's own bucket storage.
///
/// This is the `pending_writes` frame's ONLY cleanup path on every exit —
/// early-return failures (bytecode rejection, setup failure, compile
/// failure, watchdog spawn failure), a failed `lua_pcall`, AND the success
/// path (where the commit loop has already drained every entry via
/// `clearRetainingCapacity`, so the iterator here finds nothing and this is
/// a no-op). Plain `StringHashMap.deinit()` would only free the map's own
/// bucket array, not the u8 slices / ScriptValues the entries point at — the
/// same owning relationship `InstanceState.deinit` implements for the
/// committed map.
fn discardPendingWrites(pending_writes: *std.StringHashMap(ScriptValue)) void {
    var it = pending_writes.iterator();
    while (it.next()) |entry| {
        pending_writes.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(pending_writes.allocator);
    }
    pending_writes.deinit();
}

/// LUA-11, design §5.4 (ISS-0624 / GH #591). Pop a Lua value at `idx` into
/// `out`. Allocates owned copies for string keys/values. Tables are walked
/// recursively (unlike `extractValue`, which is one-level-only and is kept
/// unchanged for the script-return path — see design §5.5).
///
/// Errors:
///   - `errors.LuaError.TypeError` on a non-string table key (Lua allows
///     integer keys; `instance_state.variables` is a `StringHashMap`, so
///     integer keys are rejected rather than silently stringified — design
///     §9 open question 2).
///   - `errors.LuaError.TypeError` on a thread/userdata/function value (not
///     in `ScriptValue`'s type set).
///   - `error.OutOfMemory` on allocation failure; the caller propagates it.
///
/// On a partial-table failure, `out.*` (if already set to `.table`) is
/// cleaned up via `errdefer` so no partially-built map leaks.
///
/// `pub` because `host_api/write_variable.zig` and `host_api/log.zig` (the
/// optional third-arg context table) both call this directly.
pub fn extractValueInto(
    L: *bindings.LuaState,
    idx: c_int,
    allocator: std.mem.Allocator,
    out: *ScriptValue,
) !void {
    const lua_type = bindings.lua_type(L, idx);

    switch (lua_type) {
        bindings.LUA_TNIL => out.* = ScriptValue{ .nil_value = {} },
        bindings.LUA_TBOOLEAN => out.* = ScriptValue{ .boolean = bindings.lua_toboolean(L, idx) != 0 },
        bindings.LUA_TNUMBER => out.* = ScriptValue{ .number = bindings.lua_tonumber(L, idx) },
        bindings.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = bindings.lua_tolstring(L, idx, &len);
            const str = str_ptr[0..len];
            out.* = ScriptValue{ .string = try allocator.dupe(u8, str) };
        },
        bindings.LUA_TTABLE => {
            var map = std.StringHashMap(ScriptValue).init(allocator);
            errdefer {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            }

            // Normalize `idx` to an absolute index BEFORE pushing anything:
            // lua_pushnil below shifts relative (negative) indices, the same
            // hazard host_context.tableToScriptValue documents.
            const abs_idx = if (idx < 0) bindings.lua_gettop(L) + idx + 1 else idx;

            bindings.lua_pushnil(L);
            while (bindings.lua_next(L, abs_idx) != 0) {
                // stack: ..., key, value
                errdefer bindings.lua_pop(L, 2);

                if (bindings.lua_type(L, -2) != bindings.LUA_TSTRING) {
                    // Non-string key (e.g. an integer key). Pop key+value and
                    // unwind — StringHashMap cannot represent this key.
                    bindings.lua_pop(L, 2);
                    return errors.LuaError.TypeError;
                }
                var key_len: usize = 0;
                const key_ptr = bindings.lua_tolstring(L, -2, &key_len);
                const key_copy = try allocator.dupe(u8, key_ptr[0..key_len]);
                errdefer allocator.free(key_copy);

                var value: ScriptValue = undefined;
                try extractValueInto(L, -1, allocator, &value);
                errdefer value.deinit(allocator);

                // If this key was already present (script wrote the same key
                // twice in one table literal — not valid Lua source, but
                // defensive anyway), free the stale entry before overwriting.
                if (map.fetchRemove(key_copy)) |old| {
                    allocator.free(old.key);
                    var old_value = old.value;
                    old_value.deinit(allocator);
                }
                try map.put(key_copy, value);

                // pop value, keep key for lua_next's next iteration
                bindings.lua_pop(L, 1);
            }

            out.* = ScriptValue{ .table = map };
        },
        else => return errors.LuaError.TypeError,
    }
}
