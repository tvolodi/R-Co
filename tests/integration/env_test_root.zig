//! ENV test root — aggregates ENV-01..ENV-05 integration test files.
//!
//! Used as root_source_file for the `test-integration-env` build step so that
//! step runs only Stage 14 ENV tests rather than the full main_test.zig suite.
//!
//! ISS-0104 / GH-362
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
// (same pattern as ext02_webhook_dispatch_test.zig)
pub const api_tenant_context = bpm.api_tenant_context;

// Stage 14 — ENV-01: tenant type field (production vs test)
const env01 = @import("env01_test.zig");
// Stage 14 — ENV-01 variant: tenant type field (dedicated narrow step)
const env01_tt = @import("env01_tenant_type_field_test.zig");
// Stage 14 — ENV-02: tenant isolation
const env02 = @import("env02_test.zig");
// Stage 14 — ENV-03: definition promotion
const env03 = @import("env03_test.zig");
// Stage 14 — ENV-05: tenant lifecycle
const env05 = @import("env05_test.zig");

comptime {
    _ = std;
    _ = env01;
    _ = env01_tt;
    _ = env02;
    _ = env03;
    _ = env05;
}
