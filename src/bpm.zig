//! Single-root re-export shim used by integration tests.
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when pool.zig is both a named-module root AND imported via a
//! relative path inside store.zig.
pub const pool = @import("db/pool.zig");
pub const registry = @import("event_store/registry.zig");
pub const store = @import("event_store/store.zig");
