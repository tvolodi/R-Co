// main_test.zig — integration test entry point.
// Each comptime import below pulls its test blocks into zig build test-integration.
const std = @import("std");

// Integration test helpers (TestHarness with rollback-on-deinit isolation).
const helpers = @import("helpers.zig");
// Stage 1 — DB layer
const db_integration = @import("db_integration_test.zig");
// Stage 1 — Event store layer
const event_store_integration = @import("event_store_integration_test.zig");
// Stage 2 — Process definition layer (PD-01, PD-02)
const definition_integration = @import("definition_test.zig");
// Stage 2 — Version management (PD-03)
const pd03_version_integration = @import("pd03_version_test.zig");
// Stage 2 — Node types (PD-05)
const pd05_node_types_integration = @import("pd05_node_types_test.zig");
// Stage 2 — Definition snapshot (PD-08)
const test_snapshot_integration = @import("test_snapshot_integration.zig");
// Stage 2 — Definition import/export (PD-09)
const test_export_import_integration = @import("test_export_import_integration.zig");

comptime {
    _ = std;
    _ = helpers;
    _ = db_integration;
    _ = event_store_integration;
    _ = definition_integration;
    _ = pd03_version_integration;
    _ = pd05_node_types_integration;
    _ = test_snapshot_integration;
    _ = test_export_import_integration;
}

test "integration placeholder" {
    _ = std;
}
