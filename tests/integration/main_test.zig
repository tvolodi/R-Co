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
// Stage 2 — Definition lifecycle (PD-04)
const pd04_lifecycle_integration = @import("pd04_lifecycle_test.zig");
// Stage 2 — Node types (PD-05)
const pd05_node_types_integration = @import("pd05_node_types_test.zig");
// Stage 2 — Definition snapshot (PD-08)
const test_snapshot_integration = @import("test_snapshot_integration.zig");
// Stage 2 — Definition import/export (PD-09)
const test_export_import_integration = @import("test_export_import_integration.zig");
// Stage 2 — Definition search (PD-10)
const pd10_search_integration = @import("pd10_search_test.zig");
// Stage 3 — Start instance (EE-01)
const ee01_start_instance_integration = @import("ee01_start_instance_test.zig");
// Stage 3 — Instance cancellation (EE-08)
const ee08_cancel_instance_integration = @import("ee08_cancel_instance_test.zig");
// Stage 3 — Variable scoping and merge (EE-09)
const ee09_merge_variables_integration = @import("ee09_merge_variables_test.zig");
// Stage 3 — Execution error handling (EE-10)
const ee10_instance_error_integration = @import("instance_error_test.zig");
// Stage 3 — Concurrent instance safety (EE-12)
const ee12_concurrent = @import("concurrent_instances_test.zig");
// Stage 5 — Durable timer creation (SCH-01)
const sch01_timer_creation_integration = @import("sch01_timer_creation_test.zig");
// Stage 4 — Process definition CRUD API (API-02)
const api02_crud_integration = @import("api02_crud_test.zig");
// Stage 4 — Instance read endpoints (API-03)
const api03_instance_read_integration = @import("api03_instance_read_test.zig");
// Stage 4 — Request tracing (API-09)
const api09_trace_integration = @import("trace_test.zig");

comptime {
    _ = std;
    _ = helpers;
    _ = db_integration;
    _ = event_store_integration;
    _ = definition_integration;
    _ = pd03_version_integration;
    _ = pd04_lifecycle_integration;
    _ = pd05_node_types_integration;
    _ = test_snapshot_integration;
    _ = test_export_import_integration;
    _ = pd10_search_integration;
    _ = ee01_start_instance_integration;
    _ = ee08_cancel_instance_integration;
    _ = ee09_merge_variables_integration;
    _ = ee10_instance_error_integration;
    _ = ee12_concurrent;
    _ = sch01_timer_creation_integration;
    _ = api02_crud_integration;
    _ = api03_instance_read_integration;
    _ = api09_trace_integration;
}

test "integration placeholder" {
    _ = std;
}
