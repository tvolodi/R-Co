//! platform.call_service(svc_id, method, path, headers, body) -> (string, number)
//!
//! Call a registered HTTP service. Requires the `service:call:<svc_id>`
//! capability — the ONE capability in the matrix that is computed per call
//! rather than constant.
//!
//! Returns: Tuple of (response_body, status_code)
//! Raises:  capability denial (LUA-05/LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function. It does NOT implement it: after the
//! gate passes it keeps its simulation path and its hardcoded `{}`
//! non-simulation branch, does not consult `service_catalog.zig`, and still
//! returns `(string, number)` rather than a table. That is LUA-12 (tranche 3).

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const host_context = @import("../host_context.zig");
const simulation_runtime = @import("../../simulation/runtime.zig");
const simulation_types = @import("../../simulation/types.zig");
const simulation_interceptor = @import("../../simulation/service_interceptor.zig");

const FN_NAME = "call_service";

/// Register platform.call_service
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformCallService, 0);
    bindings.lua_setfield(L, -2, "call_service");
}

/// Lua C function: platform.call_service(svc_id, method, path, headers, body)
fn platformCallService(L: *bindings.LuaState) callconv(.c) c_int {
    // svc_id must be read and type-validated BEFORE the capability check,
    // because it IS the capability. This is the only permitted exception to
    // CAP-1's "check before touching arguments" (design §3.3), and it touches
    // argument 1 only.
    //
    // A non-string or missing svc_id is an ARGUMENT error, not a capability
    // denial: the two must stay distinguishable so a test can tell which one
    // fired.
    const svc_id = host_context.checkString(L, FN_NAME, 1);

    // Build "service:call:<svc_id>" into a fixed stack buffer. No allocator:
    // the denial path longjmps, so any outstanding heap allocation would leak
    // (ERR-2). An over-long svc_id is rejected as InvalidArgument and is NEVER
    // truncated — a truncated capability could match a shorter grant, which is
    // privilege escalation rather than a diagnostic inconvenience.
    var cap_buffer: [host_context.SERVICE_CAP_BUFFER_BYTES]u8 = undefined;
    const required = host_context.serviceCallCapability(&cap_buffer, svc_id) orelse
        host_context.raiseInvalidArgument(L, FN_NAME, 1, "a service id of at most 256 bytes");

    // No wildcard matching in this tranche: `has()` is exact string
    // containment, so `service:call:*` is not honoured. Reconciling that with
    // ADP-08's wildcard model is a cross-cutting follow-up (design §11.1).
    host_context.requireCapability(L, FN_NAME, required);

    // LUA-10, design §2.5.4: pre-call deadline check. `call_service` is the
    // one host function this tranche's LUA-10 acceptance criteria require to
    // respect the timeout while blocked — the count hook (instruction_limiter.zig)
    // cannot fire while a lua_CFunction is running, so this and the post-call
    // check below are what makes the watchdog's detection operationally
    // meaningful for a slow host call, not just a flag nothing ever reads.
    if (host_context.activeWatchdogFired(L)) {
        host_context.raiseMessage(L, "platform.call_service: wall-clock timeout exceeded");
    }

    // Remaining arguments (minimum 3 overall: svc_id, method, path).
    host_context.checkArgCount(L, FN_NAME, 3);
    const nargs = bindings.lua_gettop(L);

    var method: []const u8 = "POST";
    if (nargs >= 2 and bindings.lua_isstring(L, 2) != 0) {
        var method_len: usize = 0;
        const method_ptr = bindings.lua_tolstring(L, 2, &method_len);
        method = method_ptr[0..method_len];
    }

    var path: []const u8 = "";
    if (nargs >= 3 and bindings.lua_isstring(L, 3) != 0) {
        var path_len: usize = 0;
        const path_ptr = bindings.lua_tolstring(L, 3, &path_len);
        path = path_ptr[0..path_len];
    }

    var body: []const u8 = "";
    if (nargs >= 5 and bindings.lua_isstring(L, 5) != 0) {
        var body_len: usize = 0;
        const body_ptr = bindings.lua_tolstring(L, 5, &body_len);
        body = body_ptr[0..body_len];
    }

    if (simulation_runtime.get()) |ctx| {
        const allocator = std.heap.page_allocator;
        // ERR-1: every raise pushes its message first. A bare lua_error(L)
        // raises whatever happens to be on the stack top, which is how the
        // diagnosis observed errors reading as '1.0954944061662e-311'
        // (uninitialised stack memory).
        const fingerprint = computeFingerprint(allocator, svc_id, method, path, body) catch
            host_context.raiseMessage(L, "platform.call_service: could not compute the request fingerprint");
        defer allocator.free(fingerprint);

        const response = simulation_interceptor.executeMockedServiceCall(
            allocator,
            ctx.simulation_context,
            ctx.catalog,
            svc_id,
            simulation_types.ServiceRequest{
                .request_fingerprint = fingerprint,
                .method = method,
                .path = path,
                .body = body,
            },
        ) catch
            // The fingerprint above is freed by its `defer`, which does NOT run
            // across lua_error's longjmp — so it is freed explicitly here
            // first, then the raise happens (ERR-2).
            freeThenRaise(L, allocator, fingerprint, "platform.call_service: the service call failed");

        // LUA-10, design §2.5.4: post-call deadline check, re-checked
        // immediately before returning a result. A call that took long enough
        // to cross the deadline while it ran must not report success — this
        // is what stops a script from ever observing a stale successful
        // result past its configured timeout.
        //
        // ERR-2: `response` is heap-allocated (executeMockedServiceCall's
        // caller-owns-it contract) and `lua_error`'s longjmp does NOT run any
        // `defer` in this frame, so a plain `defer response.deinit(allocator)`
        // registered before this check would leak on the raise path — same
        // class of bug the `fingerprint`/`freeThenRaise` pattern above already
        // guards against. Both `fingerprint` and `response` are therefore
        // freed explicitly on this path before raising, not via `defer`.
        if (host_context.activeWatchdogFired(L)) {
            response.deinit(allocator);
            host_context.raiseMessage(L, "platform.call_service: wall-clock timeout exceeded");
        }

        defer response.deinit(allocator);
        bindings.lua_pushlstring(L, @ptrCast(response.body.ptr), response.body.len);
        bindings.lua_pushnumber(L, @floatFromInt(response.status_code));
        return 2;
    }

    // LUA-10, design §2.5.4: post-call deadline check for the non-simulation
    // path too — same rationale as the simulation path above.
    if (host_context.activeWatchdogFired(L)) {
        host_context.raiseMessage(L, "platform.call_service: wall-clock timeout exceeded");
    }

    // For non-simulation mode in this stage, keep a deterministic no-op response.
    bindings.lua_pushstring(L, "{}");
    bindings.lua_pushnumber(L, 200);
    return 2;
}

/// Release a heap allocation and then raise (ERR-2).
///
/// `lua_error` longjmps, so Zig `defer`/`errdefer` in the raising frame never
/// run. Anything allocated by a host function must therefore be freed BEFORE
/// the raise or never allocated at all.
fn freeThenRaise(
    L: *bindings.LuaState,
    allocator: std.mem.Allocator,
    owned: []u8,
    message: []const u8,
) noreturn {
    allocator.free(owned);
    host_context.raiseMessage(L, message);
}

fn computeFingerprint(
    allocator: std.mem.Allocator,
    svc_id: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(svc_id);
    hasher.update("|");
    hasher.update(method);
    hasher.update("|");
    hasher.update(path);
    hasher.update("|");
    hasher.update(body);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // ISS-0161: std.fmt.fmtSliceHexLower was removed in Zig 0.16; the `{x}`
    // specifier on a byte slice now produces lowercase hex directly. This file
    // had not been compiled since Zig 0.10, so the stale call survived until
    // linking real LuaJIT made this module reachable.
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return allocator.dupe(u8, &out);
}
