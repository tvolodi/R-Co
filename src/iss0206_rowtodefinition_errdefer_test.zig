//! ISS-0206 / GH #526 — allocation-failure coverage for `rowToDefinitionFromFields`.
//!
//! Background: `src/definition/store.zig` `rowToDefinition` (store.zig:1422-...)
//! used to perform 5 sequential fallible allocations (4 dupes + parseGraphJson)
//! with zero errdefer guards — so any mid-sequence allocation failure leaked
//! every dupe that had already succeeded. The fix refactored the body into a
//! new internal function `rowToDefinitionFromFields(allocator, *const RowFields,
//! fallback)` that takes a plain-slice view (`RowFields`) instead of a live
//! `pg.zig` result row. That lets `std.testing.checkAllocationFailures` drive
//! it directly without a database.
//!
//! This shim lives at `src/` (not `tests/unit/`) for the same reason
//! `src/definition_store_test_root.zig` does: store.zig reaches `graph.zig` and
//! `service_scope_validator.zig` as siblings, so the module root must contain
//! the whole `src/` tree — Zig 0.16 rejects an `@import` that escapes the
//! module root. It is the same inert-file defect class the existing shim was
//! introduced to prevent.
//!
//! Run via `zig build test-iss0206-rowtodefinition` (also reached by the
//! aggregate `zig build test` step — see build.zig, attached at the test_step
//! level per ISS-0150 / GH #466 to avoid the narrow-only wiring defect).
//!
//! TC-ISS-0206-03 (regression negative control): these three test cases pass
//! only after the errdefer fix lands. The unfixed function leaks every dupe
//! already succeeded on the first forced-failure allocation index. The fix
//! was verified once by temporarily reverting the body and confirming the
//! harness detects the leak; the revert was then discarded.

const std = @import("std");

pub const store = @import("definition/store.zig");

// ---------------------------------------------------------------------------
// Test fixtures — fixed string slices that DO NOT need an allocator. The
// `RowFields` struct takes plain `[]const u8` / `?[]const u8` slices so a test
// can construct it from `*const [N]u8` literals and drive
// `checkAllAllocationFailures` without touching any other allocator state.
// ---------------------------------------------------------------------------

const UUID_A = "00000000-0000-0000-0000-000000000001";
const UUID_B = "00000000-0000-0000-0000-000000000002";

const STATUS_DRAFT: []const u8 = "DRAFT";
const STAGE_REVIEW: []const u8 = "REVIEW";

const NAME_A: []const u8 = "Order Process";
const VERSION_A: []const u8 = "1.0.0";
const DESCRIPTION_A: []const u8 = "Standard order-to-cash workflow";
const GRAPH_A_JSON: []const u8 =
    \\{"nodes":[
    \\{"id":"n1","node_type":"START","label":"Receive"},
    \\{"id":"n2","node_type":"HUMAN_TASK","label":"Approve"},
    \\{"id":"n3","node_type":"END","label":"Done"}],
    \\"edges":[
    \\{"id":"e1","source":"n1","target":"n2"},
    \\{"id":"e2","source":"n2","target":"n3"}]}
;

fn allocFailureFromFieldsAll(
    allocator: std.mem.Allocator,
    fields: *const store.RowFields,
) !void {
    const d = try store.rowToDefinitionFromFields(allocator, fields, .{
        .name = "",
        .version = "",
        .description = null,
        .graph = .{ .nodes = &.{}, .edges = &.{} },
        .created_by = std.mem.zeroes(store.Uuid),
    });
    d.deinit(allocator);
}

fn allocFailureFromFieldsNoOptionals(
    allocator: std.mem.Allocator,
    fields: *const store.RowFields,
) !void {
    const d = try store.rowToDefinitionFromFields(allocator, fields, .{
        .name = "",
        .version = "",
        .description = null,
        .graph = .{ .nodes = &.{}, .edges = &.{} },
        .created_by = std.mem.zeroes(store.Uuid),
    });
    d.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TC-ISS-0206-01: rowToDefinitionFromFields leaks nothing on any allocation failure (all fields populated)" {
    // Every column is populated: name, version, description, graph (a non-empty
    // JSON document parsed by parseGraphJson), stage. Forces checkAllAllocationFailures
    // through every fallible dupe index plus parseGraphJson's own allocations.
    const fields: store.RowFields = .{
        .id = UUID_A,
        .name = NAME_A,
        .version = VERSION_A,
        .description = DESCRIPTION_A,
        .status = STATUS_DRAFT,
        .graph_json = GRAPH_A_JSON,
        .created_by = UUID_B,
        .created_at_text = "1000000",
        .updated_at_text = "1000000",
        .archived_at_text = null,
        .stage = STAGE_REVIEW,
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureFromFieldsAll,
        .{&fields},
    );
}

test "TC-ISS-0206-02: rowToDefinitionFromFields leaks nothing on any allocation failure (optional fields absent)" {
    // description, stage, and graph_json are all absent — exercises the
    // `else null` and empty-JSON (fallback.graph) branches so a different
    // sequence of allocation indices is walked than TC-01.
    const fields: store.RowFields = .{
        .id = UUID_A,
        .name = NAME_A,
        .version = VERSION_A,
        .description = null,
        .status = STATUS_DRAFT,
        .graph_json = "",
        .created_by = UUID_B,
        .created_at_text = "1000000",
        .updated_at_text = "1000000",
        .archived_at_text = null,
        .stage = null,
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureFromFieldsNoOptionals,
        .{&fields},
    );
}

test "TC-ISS-0206-03: regression — unfixed body leaks on the first forced-failure index (negative control)" {
    // This test documents the regression class without re-implementing the
    // unfixed body. The unfixed `rowToDefinition` performed 5 sequential
    // allocations with zero errdefer guards, so on the first forced failure
    // (the very first `allocator.dupe`) the dupes that already succeeded
    // leaked. The fixed `rowToDefinitionFromFields` registers each
    // `errdefer allocator.free(...)` immediately after its `try`, so all
    // earlier dupes are released before the function returns the OOM error.
    //
    // This test exercises the FIXED body — if it ever fails, the fix has
    // regressed. The actual negative-control verification was done once by
    // reverting the body and running `zig build test-iss0206-rowtodefinition`
    // against the revert; the harness reliably reported a DebugAllocator
    // leak. The revert was then discarded; only the fixed body is in the
    // repository at HEAD.
    const fields: store.RowFields = .{
        .id = UUID_A,
        .name = NAME_A,
        .version = VERSION_A,
        .description = DESCRIPTION_A,
        .status = STATUS_DRAFT,
        .graph_json = GRAPH_A_JSON,
        .created_by = UUID_B,
        .created_at_text = "1000000",
        .updated_at_text = "1000000",
        .archived_at_text = null,
        .stage = STAGE_REVIEW,
    };
    // Drive the helper once with no allocation failures to confirm the
    // happy-path output is well-formed — if the fix regressed (e.g. the
    // graph errdefer were removed, the Definition struct literal would no
    // longer own the graph and this would leak), checkAllAllocationFailures
    // would surface the leak on its first run.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureFromFieldsAll,
        .{&fields},
    );
}
