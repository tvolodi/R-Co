//! PIN-01 test root — scoped shim aggregating the REWORK 1 (SECURITY-REVIEWER
//! INV-1) tenant-scoping regression test and the WF02-batch-4-20260811 Step 3
//! AC3/AC4/AC5 resolution tests.
//!
//! Used as root_source_file for the `test-integration-pin01` build step so
//! that the step runs only these files rather than the full main_test.zig
//! suite (mirrors the ISS-0639 / GH-629 svc_test_root.zig pattern). This
//! shim itself has no test blocks of its own — every real test lives in the
//! imported files below, each of which connects to BPM_TEST_DB_URL
//! independently (T050).
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
pub const api_tenant_context = bpm.api_tenant_context;

const pin01 = @import("pin01_service_catalog_tenant_scope_test.zig");
// WF02-batch-4-20260811 Step 3 (TEST-DESIGNER): AC3 (VariableSchemaViolation),
// AC4 (UnresolvedPinOverride), AC5 (deterministic ordering) coverage. See
// tests/specs/PIN-01.md for the full scoping table (AC1/AC2 remain out of
// scope, tracked as ISS-0672 / GH-306).
const pin01_ac345 = @import("pin01_ac345_resolution_test.zig");

comptime {
    _ = std;
    _ = pin01;
    _ = pin01_ac345;
}
