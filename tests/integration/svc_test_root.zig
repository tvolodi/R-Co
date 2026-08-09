//! SVC test root — aggregates SVC-01..SVC-04 integration test files.
//!
//! Used as root_source_file for the `test-integration-svc` build step so that
//! the step runs only Stage 13 SVC tests rather than the full main_test.zig suite.
//!
//! ISS-0639 / GH-629 (mirrors ISS-0104 / GH-362 env_test_root.zig pattern)
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
pub const api_tenant_context = bpm.api_tenant_context;

// Stage 13 — SVC-01: service catalog scope
const svc01 = @import("svc01_service_catalog_scope_test.zig");
// Stage 13 — SVC-02: plugin dispatch scope
const svc02 = @import("svc02_plugin_dispatch_scope_test.zig");
// Stage 13 — SVC-03: definition activation scope
const svc03 = @import("svc03_definition_activation_scope_test.zig");
// Stage 13 — SVC-04: admin API
const svc04 = @import("svc04_admin_api_test.zig");

comptime {
    _ = std;
    _ = svc01;
    _ = svc02;
    _ = svc03;
    _ = svc04;
}
