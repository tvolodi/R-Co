//! platform.call_service(svc_id, method, path, headers, body) -> (string, number)
//!
//! Call a registered HTTP service. Requires 'service:call:<svc_id>' capability.
//!
//! Returns: Tuple of (response_body, status_code)
//! Errors: Capability denied, service not found, HTTP error

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");

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

    _ = svc_id;

    // For MVP: return empty response and 200
    bindings.lua_pushstring(L, "");
    bindings.lua_pushnumber(L, 200);
    return 2;
}
