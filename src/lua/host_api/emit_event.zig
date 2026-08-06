//! platform.emit_event(event_type, payload) -> nil
//!
//! Append an event to the event store. Requires the `event:emit` capability.
//!
//! Returns: nil on success
//! Raises:  capability denial (LUA-06), invalid argument
//!
//! ISS-0169 tranche 1 gates this function. It does NOT implement it: after the
//! gate passes the body still appends no event. Real event emission is
//! tranche 4.

const std = @import("std");
const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");
const capabilities = @import("../capabilities.zig");
const host_context = @import("../host_context.zig");

const FN_NAME = "emit_event";

/// Register platform.emit_event.
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void {
    _ = context;
    bindings.lua_pushcclosure(L, platformEmitEvent, 0);
    bindings.lua_setfield(L, -2, "emit_event");
}

/// Lua C function: platform.emit_event(event_type, payload)
fn platformEmitEvent(L: *bindings.LuaState) callconv(.c) c_int {
    // CAP-1: gate before any argument is read.
    host_context.requireCapability(L, FN_NAME, capabilities.StandardCapabilities.EVENT_EMIT);

    _ = host_context.checkString(L, FN_NAME, 1);

    // The payload is argument 2 and may be a table or any other value; it must
    // be present. Its shape is validated when the event is actually appended
    // (tranche 4), not here.
    host_context.checkArgCount(L, FN_NAME, 2);

    // Tranche 4 implements the actual append. Gated, not implemented.
    bindings.lua_pushnil(L);
    return 1;
}
