//! Unit tests for EE-11 — State Reconstruction.
//!
//! Covers the compile-time and structural portions of EE-11:
//!   - ReconstructionError type completeness (all 6 error variants)
//!   - Uuid type alias ([16]u8 — same as snapshot_mod.Uuid)
//!   - reconstructInstance function is publicly accessible
//!
//! These tests run under `zig build test` without a database connection.
//! Integration-layer tests (TC-EE-11-01 through TC-EE-11-09, exercising the
//! full reconstructInstance flow against a real PostgreSQL database) are
//! specified in tests/specs/EE-11.md and belong in
//! tests/integration/ee11_reconstruction_test.zig.
//!
//! Requirement traceability:
//!   EE-11 → TC-EE-11-U01, TC-EE-11-U02, TC-EE-11-U03
//!   (see tests/specs/EE-11.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const reconstruction_mod = bpm.reconstruction;

// ---------------------------------------------------------------------------
// TC-EE-11-U01: ReconstructionError — error set completeness
//
// Given:  The ReconstructionError error set in src/engine/reconstruction.zig
// When:   Each expected variant is assigned to a typed ReconstructionError variable
// Then:   Compile succeeds confirming all 6 variants exist
// ---------------------------------------------------------------------------
test "TC-EE-11-U01: ReconstructionError contains all expected variants" {
    const e1: reconstruction_mod.ReconstructionError = error.InstanceNotFound;
    try testing.expect(e1 == error.InstanceNotFound);

    const e2: reconstruction_mod.ReconstructionError = error.LockContention;
    try testing.expect(e2 == error.LockContention);

    const e3: reconstruction_mod.ReconstructionError = error.PoolExhausted;
    try testing.expect(e3 == error.PoolExhausted);

    const e4: reconstruction_mod.ReconstructionError = error.QueryFailed;
    try testing.expect(e4 == error.QueryFailed);

    const e5: reconstruction_mod.ReconstructionError = error.ReplayFailed;
    try testing.expect(e5 == error.ReplayFailed);

    const e6: reconstruction_mod.ReconstructionError = error.OutOfMemory;
    try testing.expect(e6 == error.OutOfMemory);
}

// ---------------------------------------------------------------------------
// TC-EE-11-U02: Uuid type alias — same underlying [16]u8 type as snapshot_mod.Uuid
//
// Given:  reconstruction_mod.Uuid exported from src/engine/reconstruction.zig
// When:   A zeroed value is created and its length is checked
// Then:   Compile succeeds and len == 16
// ---------------------------------------------------------------------------
test "TC-EE-11-U02: Uuid type alias is [16]u8" {
    const u: reconstruction_mod.Uuid = std.mem.zeroes(reconstruction_mod.Uuid);
    try testing.expectEqual(@as(usize, 16), u.len);
}

// ---------------------------------------------------------------------------
// TC-EE-11-U03: reconstructInstance — publicly accessible in the module
//
// Given:  The reconstructInstance function declared pub in reconstruction.zig
// When:   The function pointer is referenced at compile time
// Then:   Compile succeeds confirming the function is exported via bpm.reconstruction
// ---------------------------------------------------------------------------
test "TC-EE-11-U03: reconstructInstance function is publicly accessible" {
    // Structural check: the function must be pub and reachable from bpm.reconstruction.
    // Without a real Pool/SnapshotStore we cannot invoke it; referencing the
    // function pointer is sufficient to confirm the compile-time API contract.
    _ = reconstruction_mod.reconstructInstance;
    try testing.expect(true);
}
