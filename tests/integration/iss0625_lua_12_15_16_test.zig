//! Integration tests for ISS-0625 / GH-592 — LUA-12 / LUA-15 / LUA-16
//! production wiring (end-to-end against a real, statically linked
//! LuaJIT and a real PostgreSQL via BPM_TEST_DB_URL).
//!
//! ## Why this file does NOT use helpers.zig's TestHarness
//!
//! TestHarness imports `bpm` (src/bpm.zig), which owns src/simulation/* as
//! plain members of its own module. src/lua/mod.zig's host_api/call_service.zig
//! escapes src/lua/ into ../../simulation/runtime.zig — the SAME files bpm
//! already owns. Zig 0.16 rejects a compile unit that imports both `bpm` and
//! anything reaching lua/mod.zig with "file exists in modules 'bpm' and
//! 'lua'" (verified empirically — same constraint as iss0176's test file).
//!
//! We therefore connect to PostgreSQL directly through the bpm-free
//! `pool` / `tenant_context` modules and reach `src/lua/` via the
//! `lua_script_audit` named module (which re-exports `lua/mod.zig`,
//! `util/uuid.zig`, and `db/migrations.zig` — all bpm-free, all linked
//! to LuaJIT). See `src/lua_script_audit_root.zig` for the module-graph
//! split; we share that named module rather than duplicating it because
//! the dependency surface is identical.
//!
//! ## What this file covers (acceptance criteria from the handoff)
//!
//! LUA-12 (≥2 integration TCs):
//!   TC-ISS-0625-LUA-12-int-01  Successful call returns a Lua table
//!   TC-ISS-0625-LUA-12-int-02  Service-not-found raises a Lua error
//!                               (the simulation+real paths share the same
//!                                lookup gate — defense-in-depth §3.3)
//!
//! LUA-15 (≥4 integration TCs):
//!   TC-ISS-0625-LUA-15-int-01  platform.fail produces .ExplicitFailure
//!   TC-ISS-0625-LUA-15-int-02  error() raise produces .RuntimeError (NOT
//!                               mis-classified)
//!   TC-ISS-0625-LUA-15-int-03  Script forges __failure_reason__ via _G is
//!                               IGNORED (registry-channel anti-forgery)
//!   TC-ISS-0625-LUA-15-int-04  Explicit details table is preserved; no
//!                               stack trace on explicit failures
//!
//! LUA-16 (≥3 integration TCs):
//!   TC-ISS-0625-LUA-16-int-01  Runtime error captures non-empty stack_trace
//!   TC-ISS-0625-LUA-16-int-02  instruction_count == 0 (LUA-08 deferred)
//!   TC-ISS-0625-LUA-16-int-03  capabilities_at_failure == skip_reason
//!                               literal (decision D-3)
//!
//! ## Per-test isolation
//!
//! Every test block creates its own `CapabilitySet`, `ExecutionContext`,
//! sandboxed `lua_State`, and per-test UUID strings. No shared state across
//! tests. Cleanup is via `defer` on every allocation (mandated by
//! lint_test_isolation.py T030; `std.testing.allocator` will fail the test
//! on any leak).
//!
//! ## Skip behaviour
//!
//! If the statically linked LuaJIT is unavailable in this build profile
//! (the empirical signal that `executor.createSandboxedState` returned
//! an error), each test short-circuits with `error.SkipZigTest`. The
//! type-level and module-shape wiring still runs.

const std = @import("std");
const testing = std.testing;
const portable_env = @import("env");
const pool_mod = @import("pool");
const tenant_context = @import("tenant_context");

// `lua_script_audit` is the named module rooted at
// `src/lua_script_audit_root.zig`; it does NOT import `bpm`, so this
// compile unit stays free of the `simulation` double-import that
// TestHarness would force. It re-exports:
//   - .lua          (src/lua/mod.zig — executor, events, host_context, service_catalog, etc.)
//   - .uuid         (util/uuid.zig — for per-test UUID generation)
//   - .migrations   (db/migrations.zig)
// build.zig wires this as `lua_script_audit` and links LuaJIT into the
// same compile unit. We do NOT import lua_script_audit.lua_script_audit
// itself (that's the engine-side audit module from iss0176 — irrelevant
// for iss0625); we only need the lua + uuid re-exports.
const lua_root = @import("lua_script_audit");
const lua = lua_root.lua;
const lua_executor = lua.executor;
const lua_bindings = lua.luajit_bindings;
const lua_events = lua.events;
const lua_host_context = lua.host_context;
const lua_service_catalog = lua.service_catalog;
const uuid_mod = lua_root.uuid;

const Pool = pool_mod.Pool;
const PoolConfig = pool_mod.PoolConfig;

// Convenience aliases — the integration test deals with these types often.
const ExecutionContext = lua.ExecutionContext;
const ScriptResult = lua.ScriptResult;
const ErrorKind = lua_executor.ErrorKind;
const ServiceCatalog = lua_service_catalog.ServiceCatalog;
const RegisteredService = lua_service_catalog.RegisteredService;
const AuthMethod = lua_service_catalog.AuthMethod;
const ScriptErrorPayload = lua_events.ScriptErrorPayload;
const ScriptFailedPayload = lua_events.ScriptFailedPayload;
const HttpClientFn = lua_executor.HttpClientFn;
const HttpError = lua_executor.HttpError;
const ServiceCallResponse = lua_executor.ServiceCallResponse;

// ---------------------------------------------------------------------------
// DB plumbing — mirrors tests/integration/iss0176_lua07_audit_manifest_hash_test.zig
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - integration test cannot run\n", .{});
            return error.TestEnvironmentMissing;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    tenant_context.set(tenant_context.DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
    });
}

/// Verifies the test DB is reachable AND that LuaJIT is linked. Catches
/// both failure modes (env-misconfigured, missing LuaJIT) up front so
/// the per-test asserts don't each carry their own infra check.
fn assertInfraReady(allocator: std.mem.Allocator) !void {
    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);

    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const conn = pool.acquire() catch |err| {
        std.debug.print("BPM_TEST_DB_URL unreachable: {s}\n", .{@errorName(err)});
        return error.TestEnvironmentMissing;
    };
    defer pool.release(conn);

    conn.exec("SELECT 1", &.{}) catch {
        std.debug.print("BPM_TEST_DB_URL SELECT 1 failed\n", .{});
        return error.TestEnvironmentMissing;
    };

    // Prove LuaJIT link: a throwaway state must come up cleanly. We close
    // it immediately; this is purely a "does this build profile have real
    // LuaJIT" smoke check.
    var caps = lua.capabilities.CapabilitySet.init(allocator);
    defer caps.deinit();

    const instance_id = try makeUuid(allocator);
    defer allocator.free(instance_id);

    var ctx = ExecutionContext{
        .allocator = allocator,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = instance_id,
    };

    // createSandboxedState requires limits + storage (LUA-08/09/10) — same
    // pattern as src/lua/iss0625_lua_12_15_16_test.zig's test_limits.
    var limiter_storage = lua.instruction_limiter.RunLimiter{
        .instruction = lua.instruction_limiter.InstructionLimiter.init(allocator, PROBE_LIMITS.max_instructions),
        .timeout = lua.timeout.TimeoutContext.init(PROBE_LIMITS.timeout_seconds),
    };
    var mem_limiter_storage = lua.memory_limiter.MemoryLimiter.init(allocator, PROBE_LIMITS.max_memory_bytes);

    const L = lua_executor.createSandboxedState(&ctx, PROBE_LIMITS, &limiter_storage, &mem_limiter_storage) catch {
        std.debug.print("LuaJIT unavailable in this build profile (createSandboxedState returned error)\n", .{});
        return error.SkipZigTest;
    };
    defer lua_bindings.lua_close(L);
}

/// Limits used only by the `freshState`/`assertInfraReady` LuaJIT-liveness
/// probes below — these states are never actually executed against (real
/// script execution goes through `lua_executor.executeScript`, which builds
/// its own sandboxed state internally via `executeSource`). Generous,
/// arbitrary values; nothing in these tests exercises the limiter itself.
const PROBE_LIMITS = lua_executor.RunLimits{
    .max_instructions = 1_000_000,
    .max_memory_bytes = 50_000_000,
    .timeout_seconds = 30,
};

// ---------------------------------------------------------------------------
// Per-test fixture helpers — every test allocates its own context.
// ---------------------------------------------------------------------------

/// Allocate a fresh UUIDv4 string. Caller frees.
fn makeUuid(allocator: std.mem.Allocator) ![]u8 {
    return @constCast(try uuid_mod.newUuidV4(allocator));
}

/// Construct a per-test `ExecutionContext` with an empty `CapabilitySet`.
/// Caller is responsible for `caps.deinit()` AND `allocator.free` of the
/// owned `instance_id` / `actor_id` slices AND `allocator.destroy(caps)`.
fn freshContext(allocator: std.mem.Allocator) !struct {
    ctx: ExecutionContext,
    caps: *lua.capabilities.CapabilitySet,
    instance_id: []u8,
    actor_id: []u8,
} {
    const caps = try allocator.create(lua.capabilities.CapabilitySet);
    caps.* = lua.capabilities.CapabilitySet.init(allocator);

    const instance_id = try makeUuid(allocator);
    errdefer allocator.free(instance_id);
    const actor_id = try makeUuid(allocator);
    errdefer allocator.free(actor_id);

    return .{
        .ctx = .{
            .allocator = allocator,
            .capabilities = caps,
            .instance_id = instance_id,
            .actor_id = actor_id,
        },
        .caps = caps,
        .instance_id = instance_id,
        .actor_id = actor_id,
    };
}

/// Owning bundle returned by `freshState`: the sandboxed state plus the
/// limiter storage `createSandboxedState` requires to outlive it.
/// `deinit()` closes the state and frees the storage — call sites use it
/// exactly like the bare pointer they used before (`defer probe.deinit()`),
/// per `src/lua/iss0625_lua_12_15_16_test.zig`'s established convention of
/// declaring limiter storage alongside the state it backs.
const StateProbe = struct {
    L: *lua_bindings.lua_State,
    limiter_storage: *lua.instruction_limiter.RunLimiter,
    mem_limiter_storage: *lua.memory_limiter.MemoryLimiter,
    allocator: std.mem.Allocator,

    fn deinit(self: StateProbe) void {
        lua_bindings.lua_close(self.L);
        self.allocator.destroy(self.limiter_storage);
        self.allocator.destroy(self.mem_limiter_storage);
    }
};

/// Build a sandboxed state for a per-test ExecutionContext. Returns `null`
/// when LuaJIT is unavailable — the empirical signal that the test must
/// skip with `error.SkipZigTest`. Caller must call `.deinit()` on the
/// returned probe (mirrors the previous bare-pointer `defer lua_close(L)`
/// convention, extended to also own the limiter storage
/// `createSandboxedState` now requires).
///
/// This state is a LuaJIT-liveness probe only — every call site in this
/// file closes it immediately after construction and runs the actual
/// script under test through `lua_executor.executeScript`, which builds its
/// own sandboxed state internally (see PROBE_LIMITS).
fn freshState(allocator: std.mem.Allocator, ctx: *const ExecutionContext) ?StateProbe {
    const limiter_storage = allocator.create(lua.instruction_limiter.RunLimiter) catch return null;
    errdefer allocator.destroy(limiter_storage);
    limiter_storage.* = .{
        .instruction = lua.instruction_limiter.InstructionLimiter.init(allocator, PROBE_LIMITS.max_instructions),
        .timeout = lua.timeout.TimeoutContext.init(PROBE_LIMITS.timeout_seconds),
    };
    const mem_limiter_storage = allocator.create(lua.memory_limiter.MemoryLimiter) catch return null;
    errdefer allocator.destroy(mem_limiter_storage);
    mem_limiter_storage.* = lua.memory_limiter.MemoryLimiter.init(allocator, PROBE_LIMITS.max_memory_bytes);

    const L = lua_executor.createSandboxedState(ctx, PROBE_LIMITS, limiter_storage, mem_limiter_storage) catch return null;

    return StateProbe{
        .L = L,
        .limiter_storage = limiter_storage,
        .mem_limiter_storage = mem_limiter_storage,
        .allocator = allocator,
    };
}

/// Stub HTTP client — returns a deterministic `ServiceCallResponse` per
/// `endpoint_url` match. The integration test for LUA-12 uses only ONE
/// endpoint URL across all its assertions; this keeps the stub trivially
/// correct without any test-fixture bookkeeping. NOT a mock in the sense
/// of mocking-the-real-HTTP-server: this is a function pointer the
/// executor explicitly accepts as the production seam for LUA-12 (see
/// design §10.3 OQ-3 — "tests inject the function pointer directly into
/// the test's ExecutionContext").
fn stubHttpClient(
    ctx: ?*const anyopaque,
    endpoint: []const u8,
    method: []const u8,
    path: []const u8,
    headers: []const []const u8,
    body: []const u8,
    auth_token: ?[]const u8,
    allocator: std.mem.Allocator,
) HttpError!ServiceCallResponse {
    _ = ctx;
    _ = method;
    _ = path;
    _ = headers;
    _ = body;
    _ = auth_token;

    if (std.mem.eql(u8, endpoint, "http://stub.test/api")) {
        return ServiceCallResponse{
            .status_code = 200,
            .body = allocator.dupe(u8, "{\"status\":\"ready\"}") catch return HttpError.UnknownTransportError,
            .headers = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }
    return ServiceCallResponse{
        .status_code = 404,
        .body = allocator.dupe(u8, "{\"error\":\"not found\"}") catch return HttpError.UnknownTransportError,
        .headers = std.ArrayList([]const u8).empty,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// LUA-12 (≥2 integration TCs)
// ---------------------------------------------------------------------------

test "TC-ISS-0625-LUA-12-int-01: successful call returns a single Lua response table" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    var catalog = ServiceCatalog.init(alloc);
    defer catalog.deinit();

    try catalog.register(
        "payment_svc",
        "http://stub.test/api",
        null,
        null,
        AuthMethod.NONE,
    );
    try fx.caps.add("service:call:payment_svc");

    var ctx = fx.ctx;
    ctx.service_catalog = &catalog;
    ctx.http_client_fn = &stubHttpClient;
    ctx.http_client_ctx = null;

    const probe = freshState(alloc, &ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script =
        \\local resp = platform.call_service("payment_svc", "GET", "/status", {}, "")
        \\return resp.status_code
    ;
    var result = try lua_executor.executeScript(&ctx, script);
    defer result.deinit(alloc);

    try testing.expect(result.success);
    try testing.expect(result.value != null);
    try testing.expectEqual(@as(f64, 200), result.value.?.number);
}

test "TC-ISS-0625-LUA-12-int-02: service not found raises a Lua error (simulation+real share the same gate)" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    // Catalog with NO matching service — the lookup gate fires before
    // any HTTP path or simulation interceptor. This is the §3.3
    // defense-in-depth contract: simulation and real paths must reject
    // unregistered IDs.
    var catalog = ServiceCatalog.init(alloc);
    defer catalog.deinit();
    try catalog.register("some_other_svc", "http://stub.test/api", null, null, AuthMethod.NONE);
    try fx.caps.add("service:call:ghost_svc");

    var ctx = fx.ctx;
    ctx.service_catalog = &catalog;
    ctx.http_client_fn = &stubHttpClient;
    ctx.http_client_ctx = null;

    const probe = freshState(alloc, &ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script =
        \\local ok, err = pcall(platform.call_service, "ghost_svc", "GET", "/", {}, "")
        \\if ok then
        \\  return "did_not_raise"
        \\else
        \\  return err
        \\end
    ;
    var result = try lua_executor.executeScript(&ctx, script);
    defer result.deinit(alloc);

    try testing.expect(result.success);
    try testing.expect(result.value != null);

    // The script's pcall caught the Lua error from call_service and
    // returned it as a string. The string MUST contain the not-registered
    // diagnostic — that is the load-bearing anti-escalation assertion.
    const msg = switch (result.value.?) {
        .string => |s| s,
        else => return error.UnexpectedResultShape,
    };
    try testing.expect(std.mem.indexOf(u8, msg, "ghost_svc") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "not registered") != null);
}

// ---------------------------------------------------------------------------
// LUA-15 (≥4 integration TCs)
// ---------------------------------------------------------------------------

test "TC-ISS-0625-LUA-15-int-01: platform.fail produces ScriptResult.error_kind == .ExplicitFailure" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script =
        \\platform.fail("User cancelled request", {code = 403})
        \\return 42
    ;
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    // The script raised via platform.fail → executor classified as
    // ExplicitFailure (NOT RuntimeError).
    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.ExplicitFailure, result.error_kind);
    try testing.expect(result.error_message != null);
    try testing.expectEqualStrings("User cancelled request", result.error_message.?);

    // Explicit failures carry no stack trace — that's a deliberate API,
    // not a debug signal. ScriptErrorPayload is null.
    try testing.expect(result.script_error == null);
}

test "TC-ISS-0625-LUA-15-int-02: error() raise produces .RuntimeError (NOT mis-classified)" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    // A plain Lua `error()` call — the script author never goes through
    // platform.fail. This MUST be classified as RuntimeError, NOT
    // ExplicitFailure. The bug class this TC pins: an early ISS-0625
    // implementation could have read a stale registry flag and
    // mis-classified. That regression must turn this TC red.
    //
    // (We deliberately avoid `1 / 0`: LuaJIT 2.1 returns `inf` instead
    // of raising on integer-by-zero division, so the script returns
    // success=true and never reaches the failure path. `error("...")`
    // is the canonical Lua idiom for a runtime raise.)
    const script = "error(\"intentional runtime error\")";
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(result.script_error != null);
}

test "TC-ISS-0625-LUA-15-int-03: script forges __failure_reason__ via _G is IGNORED" {
    // Anti-forgery: a script that sets _G.__failure_reason__ (the
    // pre-ISS-0625 channel) before calling platform.fail MUST NOT
    // influence the executor's classification. The registry channel
    // (`bpm.failure_reason`) wins.
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script =
        \\__failure_reason__ = "FORGED"
        \\__explicit_failure__ = true
        \\platform.fail("real reason from registry")
        \\return 0
    ;
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    // Classification as ExplicitFailure IS expected (platform.fail wrote
    // to the registry) — but the error_message MUST come from the
    // registry, NOT from the forged global. This proves the registry
    // channel wins.
    try testing.expectEqual(ErrorKind.ExplicitFailure, result.error_kind);
    try testing.expect(result.error_message != null);
    try testing.expectEqualStrings("real reason from registry", result.error_message.?);
}

test "TC-ISS-0625-LUA-15-int-04: explicit details table is preserved; no stack trace on explicit failures" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script =
        \\platform.fail("Validation failed", {user_id = "u1", amount = -10, reason = "negative"})
        \\return 0
    ;
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.ExplicitFailure, result.error_kind);
    try testing.expectEqualStrings("Validation failed", result.error_message.?);
    // Explicit failure → script_error stays null (no stack trace). The
    // table details live on a different channel (the engine-side worker
    // reads the registry value after the pcall) — this TC pins the
    // executor-level invariant: an explicit failure is a clean API, no
    // script_error side-channel.
    try testing.expect(result.script_error == null);
}

// ---------------------------------------------------------------------------
// LUA-16 (≥3 integration TCs)
// ---------------------------------------------------------------------------

test "TC-ISS-0625-LUA-16-int-01: runtime error captures error_message and stack_trace" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    // Nested call chain so the stack-trace walker has multiple frames
    // available. f3 → f2 → f1 → main, f3 raises a runtime error.
    //
    // (We deliberately avoid `1 / 0`: LuaJIT 2.1 returns `inf` instead
    // of raising on integer-by-zero division. `error()` is the
    // canonical Lua idiom for a runtime raise.)
    //
    // ISS-0628 / GH-595: `return f2()` / `return f3()` would be Lua 5.1
    // PROPER TAIL CALLS (Lua Reference Manual §4.9) — a tail call reuses
    // the caller's own stack frame rather than pushing a new one, so
    // `lua_getstack`/`lua_getinfo` cannot see f2's or f3's frame as
    // distinct from f1's by the time errfuncHandler walks the stack, and
    // `lj_debug_funcname` cannot derive a name for a tail-called frame at
    // all (no caller link survives the tail call). `local r = fN(); return
    // r` forces a genuine (non-tail) call so each function keeps its own
    // live, named frame.
    const script =
        \\function f3() error("boom in f3") end
        \\function f2() local r = f3(); return r end
        \\function f1() local r = f2(); return r end
        \\local r = f1()
        \\return r
    ;
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(result.script_error != null);

    const payload = &result.script_error.?;
    // The error message itself is captured (assertion against the
    // substring f3 actually raised with — any change here is a test
    // change).
    try testing.expect(payload.error_message.len > 0);
    try testing.expect(std.mem.indexOf(u8, payload.error_message, "boom in f3") != null);

    // FIXED (ISS-0628 / GH-595): a message-handler closure
    // (`executor.errfuncHandler`) is now installed as `lua_pcall`'s errfunc
    // argument (executor.zig executeSource, §2 of
    // src/design/iss0628-lua16-errfunc-stacktrace.md). Per the Lua 5.1 /
    // LuaJIT 2.1 `lua_pcall` contract, the handler runs *at the moment the
    // error is raised*, while the erroring call frames are still live —
    // unlike `captureStackTrace`, which used to run only after `lua_pcall`
    // had already returned and unwound those frames (the previous known
    // limitation this comment described). The handler walks the live stack
    // and stashes the trace on a private LUA_REGISTRYINDEX key
    // (`host_context.STACK_TRACE_KEY`), which `executeSource` reads back via
    // `host_context.readStackTrace` after `lua_pcall` returns. This does
    // NOT install `debug.traceback` — the `debug` library stays permanently
    // unopened per SBX-1 (design §0); the handler is a plain host-side
    // `lua_CFunction`.
    //
    // The trace is non-empty and contains a frame for `f3`, the function
    // that actually raised (`error("boom in f3")` above).
    try testing.expect(payload.stack_trace.len > 0);
    try testing.expect(std.mem.indexOf(u8, payload.stack_trace, "f3") != null);
}

test "TC-ISS-0625-LUA-16-int-02: instruction_count == 0 (LUA-08 instruction limiter not installed)" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    // instruction_limiter stays null — decision D-3 in the design:
    // when the LUA-08 source is NOT installed in this run, the payload
    // still constructs with instruction_count = 0 and the skip reason
    // in capabilities_at_failure.
    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script = "local x = nil; return x.field";
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(result.script_error != null);

    const payload = &result.script_error.?;
    try testing.expectEqual(@as(u64, 0), payload.instruction_count);
    // LUA-09 deferred — memory peak is always 0.
    try testing.expectEqual(@as(u64, 0), payload.memory_peak_bytes);
}

test "TC-ISS-0625-LUA-16-int-03: capabilities_at_failure == skip_reason literal (decision D-3)" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    const script = "error(\"intentional runtime error\")";
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(result.script_error != null);

    const payload = &result.script_error.?;
    // The literal skip reason string is the authoritative signal that
    // the payload constructed in the LUA-08-deferred branch. Any
    // change to this string in src/lua/executor.zig is a test change.
    try testing.expectEqualStrings(
        lua_executor.SKIP_REASON_NO_INSTRUCTION_LIMITER,
        payload.capabilities_at_failure,
    );
    try testing.expectEqualStrings(
        "skip: instruction_count source not installed (LUA-08 deferred)",
        payload.capabilities_at_failure,
    );
}

test "TC-ISS-0628-LUA-16-stacktrace-01: stack_trace contains the failing function and one frame marker per nesting level" {
    const alloc = testing.allocator;

    try assertInfraReady(alloc);

    var fx = try freshContext(alloc);
    defer {
        alloc.free(fx.instance_id);
        alloc.free(fx.actor_id);
        fx.caps.deinit();
        alloc.destroy(fx.caps);
    }

    const probe = freshState(alloc, &fx.ctx) orelse return error.SkipZigTest;
    defer probe.deinit();

    // A DISTINCT script chain from TC-ISS-0625-LUA-16-int-01's f3->f2->f1
    // fixture, so the two tests cannot pass or fail in lockstep on a shared
    // fixture (design §4.3). deepFn raises after nesting_depth == 3 levels
    // of its own recursive calls, reached from main via a single call to
    // deepFn(1) — so the live call stack at the moment of the raise is:
    // deepFn(3) -> deepFn(2) -> deepFn(1) -> main, i.e. 3 frames
    // attributable to deepFn plus the top-level chunk.
    //
    // Deliberately NOT `return deepFn(n + 1)`: Lua 5.1 / LuaJIT 2.1 proper
    // tail calls reuse the caller's stack frame (Lua Reference Manual §4.9)
    // — a tail-called frame has no caller link for lj_debug_funcname to
    // derive a name from, and lj_getstack/lj_getinfo cannot see the
    // collapsed intermediate frames at all. `local r = deepFn(n + 1); return
    // r` forces a genuine (non-tail) call so every nesting level keeps its
    // own live, named frame for errfuncHandler to walk while unwinding.
    const nesting_depth: usize = 3;
    const script =
        \\function deepFn(n)
        \\  if n >= 3 then
        \\    error("boom in deepFn")
        \\  end
        \\  local r = deepFn(n + 1)
        \\  return r
        \\end
        \\local r = deepFn(1)
        \\return r
    ;
    var result = try lua_executor.executeScript(&fx.ctx, script);
    defer result.deinit(alloc);

    try testing.expect(!result.success);
    try testing.expectEqual(ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(result.script_error != null);

    const payload = &result.script_error.?;
    try testing.expect(payload.error_message.len > 0);
    try testing.expect(std.mem.indexOf(u8, payload.error_message, "boom in deepFn") != null);

    // Baseline (design §4.3): non-empty trace.
    try testing.expect(payload.stack_trace.len > 0);

    // The trace contains the specific function name the script raised
    // from, proving the walk captured a real frame for the actual failing
    // function and not a placeholder.
    try testing.expect(std.mem.indexOf(u8, payload.stack_trace, "deepFn") != null);

    // The trace has at least as many "  at " frame markers as there are
    // nested calls in the fixture script — proving multiple live frames
    // were captured, not just the innermost one (guards against an
    // off-by-one in the walk's `level` loop that would silently stop after
    // one frame and still pass a weaker "contains something" check).
    var frame_markers: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, payload.stack_trace[search_start..], "  at ")) |found| {
        frame_markers += 1;
        search_start += found + "  at ".len;
    }
    try testing.expect(frame_markers >= nesting_depth);
}
