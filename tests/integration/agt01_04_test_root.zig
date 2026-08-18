//! AGT-01..04 test root — scoped shim isolating the agent artifact submission
//! integration tests from main_test.zig.
//!
//! Used as root_source_file for the `test-integration-agt01-04` build step.
//! Mirrors the pin01_test_root.zig pattern (ISS-0639 / GH-629).
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
pub const api_tenant_context = bpm.api_tenant_context;

const agt01_04 = @import("agt01_04_agent_artifacts_test.zig");

comptime {
    _ = std;
    _ = agt01_04;
}
