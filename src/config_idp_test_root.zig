//! Test root for `src/config/identity_provider.zig` (3 in-file test blocks).
//!
//! ISS-0137 / GH #439. The file was the root of the named module
//! `idp_config_mod` but of no `addTest`, so its tests never ran.
//!
//! Reached by RELATIVE path with the named `idp_config` module deliberately NOT
//! passed to this target — see src/core_modules_test_root.zig's doc comment for
//! the full reasoning. In short: Zig enrolls test blocks only from the root
//! module's own file set, so a named-module import would run zero of this
//! file's three tests while reporting green.
//!
//! identity_provider.zig imports `portable_env`, which must still be supplied as
//! a named module — that file is NOT one whose tests we are collecting here, so
//! there is no dual-ownership conflict.
//!
//! Deliberately NOT merged into src/core_modules_test_root.zig: that shim owns
//! src/env.zig as a relative member, and this one binds the same file through
//! `portable_env`. Merging would put env.zig in two modules at once.
//!
//! `.link_libc = true` required — same ISS-0134 reason as core_modules.
//!
//! ## ISS-0172 / GH #500 — refAllDecls does not resolve struct field types
//!
//! `refAllDecls(idp_config)` is direct on the leaf file, so function bodies
//! are already analysed. It does not force resolution of a struct's own
//! field types when the struct is merely declared and never instantiated —
//! see src/lua_test_root.zig and src/simulation_test_root.zig for the full
//! rationale and mutation-test evidence. `pinModuleTypes` closes that gap for
//! `ProviderType`/`IdentityProviderConfig`/`EnvReader`.
//!
//! Run via `zig build test-config-idp` (also reached by `zig build test`).

const std = @import("std");

pub const idp_config = @import("config/identity_provider.zig");

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
    std.testing.refAllDecls(idp_config);

    // ISS-0172: struct/union/enum field-type resolution.
    pinModuleTypes(idp_config);
}
