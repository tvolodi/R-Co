//! Unit test stubs for PD-08 — Definition snapshot (SnapshotStore).
//!
//! All `SnapshotStore` methods require a live database connection through
//! `Pool.acquire()`.  There are no pure-function paths in `snapshot.zig`
//! that can be exercised without a real PostgreSQL DB.  All test blocks
//! below return `error.SkipZigTest` and exist for requirement traceability
//! only.
//!
//! Full verification is provided by:
//!   tests/integration/test_snapshot_integration.zig
//!
//! Requirement traceability:
//!   PD-08 → TC-PD-08-01 through TC-PD-08-07
//!   (see tests/specs/PD-08.md for full Given/When/Then specs)
//!
//! Run with: zig build test
const std = @import("std");

comptime {
    _ = std;
}

// ---------------------------------------------------------------------------
// TC-PD-08-01: Create snapshot — happy path
// ---------------------------------------------------------------------------

test "TC-PD-08-01: SnapshotStore.create — happy path returns Snapshot with matching fields" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-02: Snapshot is independent of subsequent definition update
// ---------------------------------------------------------------------------

test "TC-PD-08-02: SnapshotStore.getByInstanceId — returns original graph after definition update" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-03: Duplicate instance_id returns SnapshotAlreadyExists
// ---------------------------------------------------------------------------

test "TC-PD-08-03: SnapshotStore.create — duplicate instance_id returns SnapshotAlreadyExists" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-04: Unknown definition_id returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-08-04: SnapshotStore.create — unknown definition_id returns DefinitionNotFound" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-05: getByInstanceId with no snapshot returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-08-05: SnapshotStore.getByInstanceId — no snapshot returns DefinitionNotFound" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-06: Snapshot includes all graph fields
// ---------------------------------------------------------------------------

test "TC-PD-08-06: SnapshotStore round-trip preserves node types, edge conditions, and is_default" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-08-07: Two instances from same definition have independent snapshots
// ---------------------------------------------------------------------------

test "TC-PD-08-07: SnapshotStore — two instance snapshots from same definition are independent" {
    return error.SkipZigTest;
}
