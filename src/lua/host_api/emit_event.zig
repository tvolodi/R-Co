//! platform.emit_event(event_type, payload) -> nil
//!
//! Append an event to the event store. Requires 'event:emit' capability.
//!
//! Returns: nil on success
//! Errors: Capability denied, unknown event type, invalid payload

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");

/// Register platform.emit_event
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    // For MVP, placeholder implementation.

    bindings.lua_pushcclosure(L, platformEmitEvent, 0);
    bindings.lua_setfield(L, -2, "emit_event");
}

/// Lua C function: platform.emit_event(event_type, payload)
fn platformEmitEvent(L: *bindings.LuaState) callconv(.C) c_int {
    // Check argument count
    const nargs = bindings.lua_gettop(L);
    if (nargs < 2) {
        _ = bindings.lua_error(L);
        return 0;
    }

    // Get event_type argument
    if (bindings.lua_isstring(L, 1) == 0) {
        _ = bindings.lua_error(L);
        return 0;
    }

    var event_type_len: usize = 0;
    _ = bindings.lua_tolstring(L, 1, &event_type_len);

    // Payload at index 2 (any type, can be table)
    // For MVP: verify it exists, ignore details

    // For MVP: no-op, return nil
    bindings.lua_pushnil(L);
    return 1;
}
