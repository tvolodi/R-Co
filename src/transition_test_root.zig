//! Test root for `src/engine/transition.zig`.
//!
//! ISS-0132 / GH #428: transition.zig carries 30 in-file tests plus the
//! ISS-0132 `checkAllAllocationFailures` harness. For months none of them
//! executed — build.zig referenced the file only as an imported module
//! (`transition_mod`), never as the root of an `addTest`, so `zig build test`
//! compiled it and ran none of its test blocks — the same defect class as
//! ISS-0102 (integration test files wired into no build target), here in the
//! engine's purest and most safety-critical module. Once wired in (this
//! shim), 7 of the 30 rotted against ownership-model drift; all 30 now pass
//! with zero leaks/crashes — see the GH #428 fix and build.zig's comment on
//! the `test-engine` wiring for the root-cause summary.
//!
//! Two constraints force this shim to sit at `src/` rather than beside the
//! file it tests:
//!
//!   1. transition.zig reaches `../definition/graph.zig` by relative path, and
//!      Zig 0.16 rejects an `@import` that escapes the module root — so the
//!      root must be at `src/`, not `src/engine/`.
//!   2. `addTest` on `src/bpm.zig` does not work either: Zig runs test blocks
//!      only in files reachable through *analyzed* declarations, and bpm.zig
//!      has neither a `test` block nor `refAllDecls`, so the target compiles
//!      and silently runs zero tests.
//!
//! `refAllDecls` below forces analysis of every declaration in transition.zig,
//! which is what causes its test blocks to be discovered and run.
//!
//! ## ISS-0172 / GH #500 — refAllDecls does not resolve struct field types
//!
//! `refAllDecls(transition)` is direct on the leaf file, so function bodies
//! (including the 30 `test` blocks themselves) are already analysed. It does
//! not, however, force resolution of a struct's own field types when that
//! struct is merely declared and never instantiated by any reached code path
//! — see src/lua_test_root.zig and src/simulation_test_root.zig for the full
//! rationale and mutation-test evidence. `pinModuleTypes` closes that gap for
//! transition.zig's dozen-plus struct/union/enum declarations
//! (`InstanceState`, `TransitionResult`, `PendingEvent`, etc.).
//!
//! Run via `zig build test-transition` (also reached by `zig build test-engine`
//! and `zig build test`).

const std = @import("std");

pub const transition = @import("engine/transition.zig");

/// ISS-0172 / GH #500 — forces field-type resolution AND method-body analysis
/// for every struct/union/enum declared at `T`'s top level; see
/// src/simulation_test_root.zig for the full rationale and mutation-test
/// evidence (including why `refAllDecls(field)` is needed in addition to
/// `@sizeOf` — a type's own methods are declarations of the TYPE, not of the
/// enclosing module, so `refAllDecls` on the module alone never reaches them).
fn pinModuleTypes(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"union", .@"enum" => {
                    _ = @sizeOf(field);
                    std.testing.refAllDecls(field);
                },
                else => {},
            }
        }
    }
}

test {
    std.testing.refAllDecls(transition);

    // ISS-0172: struct/union/enum field-type resolution.
    pinModuleTypes(transition);
}
