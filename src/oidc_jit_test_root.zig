//! Test root for `src/oidc/jit_provisioning.zig` (15 in-file test blocks).
//!
//! ISS-0137 / GH #439. Split out of src/oidc_test_root.zig rather than merged
//! into it, for a hard Zig reason rather than a stylistic one:
//!
//! jit_provisioning.zig reaches `claim_mapping` BY NAME (line 27). To collect
//! its test blocks the file must be a relative member of THIS target's root
//! module — and to compile at all it must be given the `claim_mapping` module.
//! src/oidc_test_root.zig collects claim_mapping.zig's own 11 tests, which
//! requires claim_mapping.zig to be a relative member THERE. Putting both files
//! in one target makes claim_mapping.zig simultaneously a named-module root and
//! a relative member of the same compilation, which Zig rejects:
//! "file exists in modules 'root' and 'claim_mapping'".
//!
//! Two targets is therefore the minimum that runs both files' tests. Splitting
//! is what preserves coverage; merging would have cost one file's 15 tests.
//!
//! ## ISS-0172 / GH #500 — refAllDecls does not resolve struct field types
//!
//! `refAllDecls(jit_provisioning)` is direct on the leaf file, so function
//! bodies are already analysed. It does not, however, force resolution of a
//! struct's own field types when the struct is merely declared and never
//! instantiated — see src/lua_test_root.zig and src/simulation_test_root.zig
//! for the full rationale and mutation-test evidence. `pinModuleTypes` closes
//! that gap for this file's five struct/enum declarations.
//!
//! Run via `zig build test-oidc-jit` (also reached by `zig build test`).

const std = @import("std");

pub const jit_provisioning = @import("oidc/jit_provisioning.zig");

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
    std.testing.refAllDecls(jit_provisioning);

    // ISS-0172: struct/union/enum field-type resolution.
    pinModuleTypes(jit_provisioning);
}
