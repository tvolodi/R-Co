//! Test root for `src/definition/store.zig`.
//!
//! ISS-0132 / GH #427: store.zig's `parseGraphJson` leaked on allocation-failure
//! paths. GH #406 patched one such leak and the signature recurred — because the
//! file contained ZERO `test` blocks and was reachable from no `addTest` root at
//! all, so none of its error paths had ever been executed. That is the same
//! inert-file defect class as ISS-0102 (integration files wired into no build
//! target) and the transition.zig half of GH #428.
//!
//! This shim exists so store.zig's ISS-0132 `checkAllAllocationFailures` tests
//! actually run. Two constraints force it to sit at `src/` rather than beside
//! the file it tests:
//!
//!   1. store.zig reaches `graph.zig` and `service_scope_validator.zig` as
//!      siblings and is itself reached by callers via `src/`, so the module root
//!      must contain the whole `src/` tree — Zig 0.16 rejects an `@import` that
//!      escapes the module root.
//!   2. `addTest` on `src/bpm.zig` does not work: Zig runs test blocks only in
//!      files reachable through *analyzed* declarations, and bpm.zig has neither
//!      a `test` block nor `refAllDecls`, so that target compiles and silently
//!      runs zero tests — exactly the failure mode this shim exists to prevent.
//!
//! `refAllDecls` below forces analysis of every declaration in store.zig, which
//! is what causes its test blocks to be discovered and run.
//!
//! store.zig imports the `pool` module (DB access), so this target takes the
//! same `pool` import the production module graph uses. The ISS-0132 tests
//! themselves are pure — they call `parseGraphJson` directly and never open a
//! connection — so this target needs no `BPM_TEST_DB_URL` and belongs in the
//! unit layer.
//!
//! Run via `zig build test-definition-store` (also reached by `zig build test`).

const std = @import("std");

pub const store = @import("definition/store.zig");

test {
    std.testing.refAllDecls(store);
}
