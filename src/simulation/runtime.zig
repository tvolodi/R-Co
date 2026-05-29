const time_source = @import("time_source.zig");
const uuid_source = @import("uuid_source.zig");
const mock_catalog = @import("mock_catalog.zig");
const types = @import("types.zig");

pub const RuntimeContext = struct {
    simulation_context: *const types.SimulationContext,
    clock: *time_source.PlatformClock,
    uuid: *uuid_source.PlatformUuidSource,
    catalog: *const mock_catalog.ServiceMockCatalog,
};

threadlocal var active_context: ?RuntimeContext = null;

pub fn activate(ctx: RuntimeContext) void {
    active_context = ctx;
}

pub fn clear() void {
    active_context = null;
}

pub fn isActive() bool {
    return active_context != null;
}

pub fn get() ?*const RuntimeContext {
    if (active_context == null) return null;
    return &active_context.?;
}
