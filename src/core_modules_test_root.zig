//! Test root for four leaf modules that carry in-file tests but were the root
//! of a named `b.createModule` only — never of an `addTest`.
//!
//! ISS-0137 / GH #439. Same defect class as ISS-0132 / GH #428
//! (src/engine/transition.zig): Zig compiles a file whenever something imports
//! it, but runs that file's `test` blocks only when the file is reachable from
//! an `addTest` root through *analyzed* declarations. `tenant_context`,
//! `pipeline_context`, `obs_metrics` and `env` were each reachable only as
//! imported modules, so their 15 test blocks never executed while
//! `zig build test` reported green.
//!
//! Reach is by RELATIVE path, and the corresponding named modules are
//! deliberately NOT passed to this addTest target. This is load-bearing and was
//! established the hard way during ISS-0137 implementation:
//!
//!   * Zig collects `test` blocks only from the ROOT MODULE's own file set. A
//!     named-module import (`@import("tenant_context")`) is a separate
//!     compilation unit, so its test blocks are never enrolled in THIS test
//!     binary. A shim written that way compiles, passes, and runs exactly ONE
//!     test — the synthetic container block below — while reporting green.
//!     That is precisely the silent-zero-coverage failure ISS-0137 exists to
//!     catch, so building the fix that way would have re-created the bug.
//!     Measured: named reach → 1/1 tests; relative reach → 16/16.
//!   * `std.testing.refAllDecls` does not change this. It forces *analysis* of
//!     declarations, which is what makes the tests discoverable within a
//!     module — it cannot pull tests across a module boundary.
//!   * Relative reach is only safe because these named modules are absent from
//!     THIS compilation. Passing them via `.imports` as well would put each
//!     file in two modules at once and Zig rejects that with "file exists in
//!     multiple modules". One or the other, never both.
//!
//! This is the same shape as src/transition_test_root.zig, which reaches
//! `engine/transition.zig` relatively and gets all 30 of its tests even though
//! `transition_mod` also exists as a named module elsewhere in build.zig.
//!
//! `.link_libc = true` on this target is required: src/env.zig uses libc's
//! `environ` extern on non-Windows (ISS-0134).
//!
//! ## ISS-0172 / GH #500 — refAllDecls does not resolve struct field types
//!
//! Each `refAllDecls` call below is direct on the leaf file, so function
//! bodies are already analysed. It does not force resolution of a struct's
//! own field types when the struct is merely declared and never instantiated
//! — see src/lua_test_root.zig and src/simulation_test_root.zig for the full
//! rationale and mutation-test evidence. `pinModuleTypes` closes that gap for
//! `tenant_context.StorageMode` and `obs_metrics.QueryType`/`MetricsRegistry`.
//!
//! Run via `zig build test-core-modules` (also reached by `zig build test`).

const std = @import("std");

pub const tenant_context = @import("api/tenant_context.zig");
pub const pipeline_context = @import("api/pipeline_context.zig");
pub const obs_metrics = @import("obs/metrics.zig");
pub const env = @import("env.zig");

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
    std.testing.refAllDecls(tenant_context);
    std.testing.refAllDecls(pipeline_context);
    std.testing.refAllDecls(obs_metrics);
    std.testing.refAllDecls(env);

    // ISS-0172: struct/union/enum field-type resolution per leaf.
    pinModuleTypes(tenant_context);
    pinModuleTypes(pipeline_context);
    pinModuleTypes(obs_metrics);
    pinModuleTypes(env);
}
