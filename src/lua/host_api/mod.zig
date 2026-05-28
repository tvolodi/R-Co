//! Lua host API module registry.
//!
//! This module coordinates the registration of all platform.* functions.
//! Each function is defined in its own submodule (call_service.zig, read_variable.zig, etc.)

const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");

pub const call_service = @import("call_service.zig");
pub const read_variable = @import("read_variable.zig");
pub const write_variable = @import("write_variable.zig");
pub const log_func = @import("log.zig");
pub const emit_event = @import("emit_event.zig");
pub const get_instance_state = @import("get_instance_state.zig");

/// Register all host API functions into the platform table.
pub fn registerAll(
    L: *bindings.LuaState,
    context: *const executor.ExecutionContext,
) !void {
    // Create platform table
    bindings.lua_newtable(L);

    // Register each function (C closure wrapping is done per function)
    try call_service.register(L, context);
    try read_variable.register(L, context);
    try write_variable.register(L, context);
    try log_func.register(L, context);
    try emit_event.register(L, context);
    try get_instance_state.register(L, context);

    // Assign to global 'platform'
    bindings.lua_setglobal(L, "platform");
}
