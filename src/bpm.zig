//! Single-root re-export shim used by integration tests.
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when pool.zig is both a named-module root AND imported via a
//! relative path inside store.zig.
pub const pool = @import("db/pool.zig");
pub const registry = @import("event_store/registry.zig");
pub const store = @import("event_store/store.zig");
pub const definition = @import("definition/store.zig");
pub const snapshot = @import("definition/snapshot.zig"); // PD-08
pub const export_import = @import("definition/export_import.zig"); // PD-09
pub const engine = @import("engine/instance.zig"); // EE-01
pub const tasks = @import("tasks/store.zig"); // EE-03
pub const scheduler = @import("scheduler/store.zig"); // SCH-01
pub const scheduler_poller = @import("scheduler/scheduler.zig"); // SCH-02
pub const reconstruction = @import("engine/reconstruction.zig"); // EE-11
pub const transition = @import("engine/transition.zig"); // EE-12
