//! PIN-01 test root — scoped shim for the REWORK 1 (SECURITY-REVIEWER INV-1)
//! tenant-scoping regression test.
//!
//! Used as root_source_file for the `test-integration-pin01` build step so
//! that the step runs only this file rather than the full main_test.zig
//! suite (mirrors the ISS-0639 / GH-629 svc_test_root.zig pattern).
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
pub const api_tenant_context = bpm.api_tenant_context;

const pin01 = @import("pin01_service_catalog_tenant_scope_test.zig");

comptime {
    _ = std;
    _ = pin01;
}
