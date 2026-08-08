//! Test root for the seven `src/oidc/*.zig` production files that carry
//! in-file tests (44 blocks total).
//!
//! ISS-0137 / GH #439. Before this run none of these files was declared as a
//! module in build.zig at all, so their test blocks were reachable from no
//! `addTest` root and the tests/unit + tests/integration suites that import
//! them by name could not compile either (root cause RC-3).
//!
//! Reach is by RELATIVE path, and the seven named modules created in cluster
//! C4a are deliberately NOT passed to this addTest target. Zig enrolls `test`
//! blocks only from the root module's own file set, so reaching these files by
//! their named modules would run ZERO of their 44 tests while reporting green —
//! re-creating the very defect ISS-0137 exists to catch. See
//! src/core_modules_test_root.zig's doc comment for the measured evidence.
//!
//! Those seven named modules still exist and are still required: the
//! tests/unit/test_oidc*.zig and tests/integration/oidc*.zig suites import them
//! by name, and those are different compilations from this one. A file may be a
//! named-module root in one compilation and a relative member in another; what
//! Zig forbids is both roles in the SAME compilation.
//!
//! `pool` IS supplied as a named module below: five of these seven files import
//! it, and src/db/pool.zig is not a file whose tests this target collects.
//!
//! `jit_provisioning.zig` is NOT collected here — it is split into its own
//! target, src/oidc_jit_test_root.zig. It imports `claim_mapping` BY NAME, so
//! any compilation that collects jit_provisioning's tests must be given the
//! `claim_mapping` module, which would make claim_mapping.zig both a named-module
//! root and a relative member here ("file exists in modules 'root' and
//! 'claim_mapping'"). Two targets is the only way to collect both files' tests.
//!
//! Placement at `src/` is a naming convention here (matching
//! src/transition_test_root.zig) — src/oidc/*.zig files reach no sibling by
//! relative path, so no module-root escape constrains this shim.
//!
//! No live services: every import here is `std` plus named modules, and the
//! `pool` reference in claim_mapping.zig is a function-parameter type, not a
//! test-body connection. These 44 blocks are correct on `zig build test`.
//!
//! ## ISS-0172 / GH #500 — refAllDecls does not resolve struct field types
//!
//! Each `refAllDecls` call below IS direct on the leaf file (no `mod.zig`
//! aggregator in between), so function bodies in these six files are already
//! analysed. But `refAllDecls` still does not force resolution of a struct's
//! OWN field types when that struct is merely declared, never instantiated —
//! the same blind spot ISS-0172 found in src/lua/memory_limiter.zig's
//! `mutex: std.Thread.Mutex` field (see src/lua_test_root.zig and
//! src/simulation_test_root.zig for the full rationale and mutation-test
//! evidence). `pinModuleTypes` closes that gap for every struct/union/enum
//! these six files declare (~50 types across realm_deletion.zig,
//! tenant_claim_source.zig, realm_tenant_binding.zig, realm_provisioning.zig,
//! identity_stability.zig and claim_mapping.zig).
//!
//! Run via `zig build test-oidc-src` (also reached by `zig build test`).

const std = @import("std");

pub const claim_mapping = @import("oidc/claim_mapping.zig");
pub const identity_stability = @import("oidc/identity_stability.zig");
pub const realm_tenant_binding = @import("oidc/realm_tenant_binding.zig");
pub const tenant_claim_source = @import("oidc/tenant_claim_source.zig");
pub const realm_provisioning = @import("oidc/realm_provisioning.zig");
pub const realm_deletion = @import("oidc/realm_deletion.zig");

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
    std.testing.refAllDecls(claim_mapping);
    std.testing.refAllDecls(identity_stability);
    std.testing.refAllDecls(realm_tenant_binding);
    std.testing.refAllDecls(tenant_claim_source);
    std.testing.refAllDecls(realm_provisioning);
    std.testing.refAllDecls(realm_deletion);

    // ISS-0172: struct/union/enum field-type resolution per leaf.
    pinModuleTypes(claim_mapping);
    pinModuleTypes(identity_stability);
    pinModuleTypes(realm_tenant_binding);
    pinModuleTypes(tenant_claim_source);
    pinModuleTypes(realm_provisioning);
    pinModuleTypes(realm_deletion);
}
