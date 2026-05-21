const std = @import("std");

// Module references — imported here so that `zig build` and `zig build test`
// compile and validate all Stage 1 modules.
pub const db_pool = @import("db/pool.zig");
pub const db_migrations = @import("db/migrations.zig");
pub const event_store = @import("event_store/store.zig");
pub const event_registry = @import("event_store/registry.zig");
pub const definition_graph = @import("definition/graph.zig");
pub const definition_store = @import("definition/store.zig");
pub const definition_snapshot = @import("definition/snapshot.zig");
pub const definition_export_import = @import("definition/export_import.zig"); // PD-09
pub const definition_routes = @import("api/routes/definitions.zig");

pub fn main() !void {
    std.debug.print("BPM Platform — not yet implemented\n", .{});
}
