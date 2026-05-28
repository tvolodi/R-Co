//! platform.call_service(svc_id, method, path, headers, body) -> (string, number)
//!
//! Call a registered HTTP service. Requires 'service:call:<svc_id>' capability.
//!
//! Returns: Tuple of (response_body, status_code)
//! Errors: Capability denied, service not found, HTTP error

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const simulation_runtime = @import("../../simulation/runtime.zig");
const simulation_types = @import("../../simulation/types.zig");
const simulation_interceptor = @import("../../simulation/service_interceptor.zig");

/// Register platform.call_service
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, placeholder implementation.

    bindings.lua_pushcclosure(L, platformCallService, 0);
    bindings.lua_setfield(L, -2, "call_service");
}

/// Lua C function: platform.call_service(svc_id, method, path, headers, body)
fn platformCallService(L: *bindings.LuaState) callconv(.C) c_int {
    // Check argument count (minimum 3: svc_id, method, path)
    const nargs = bindings.lua_gettop(L);
    if (nargs < 3) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get svc_id
    if (bindings.lua_isstring(L, 1) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    var svc_id_len: usize = 0;
    const svc_id_ptr = bindings.lua_tolstring(L, 1, &svc_id_len);
    const svc_id = svc_id_ptr[0..svc_id_len];

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
        const fingerprint = computeFingerprint(allocator, svc_id, method, path, body) catch {
            _ = bindings.lua_error(L);
            return 0;
        };
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
        ) catch {
            _ = bindings.lua_error(L);
            return 0;
        };
        defer response.deinit(allocator);

        bindings.lua_pushlstring(L, @ptrCast(response.body.ptr), response.body.len);
        bindings.lua_pushnumber(L, @floatFromInt(response.status_code));
        return 2;
    }

    // For non-simulation mode in this stage, keep a deterministic no-op response.
    bindings.lua_pushstring(L, "{}");
    bindings.lua_pushnumber(L, 200);
    return 2;
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

    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return allocator.dupe(u8, &out);
}
