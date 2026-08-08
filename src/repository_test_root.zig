//! Test root for the in-file tests inside `src/repository/` (5 blocks across
//! artifacts.zig, schemas.zig and activation.zig).
//!
//! ISS-0137 / GH #439. The whole src/repository tree was orphaned: mod.zig was
//! declared as no module and reachable from no addTest root, so none of its
//! in-file tests ran.
//!
//! Reached by RELATIVE path, with the named `repository` module deliberately NOT
//! passed to this target. Zig enrolls `test` blocks only from the root module's
//! own file set, so a named-module reach would run zero of these five tests
//! while reporting green — see src/core_modules_test_root.zig's doc comment for
//! the measured evidence. The `repository` named module still exists and is
//! still required by tests/unit/repository_*.zig, which is a different
//! compilation.
//!
//! `pool` IS supplied as a named module: four repository files import it, and
//! src/db/pool.zig is not a file whose tests this target collects.
//!
//! `refAllDecls(repository)` forces analysis of mod.zig's five `pub const`
//! re-exports, which is what causes the tests inside those files to be
//! discovered and run.
//!
//! ## ISS-0172 / GH #500 — refAllDecls through mod.zig does not reach leaves
//!
//! `refAllDecls(repository)` alone pins only mod.zig's own top-level decls,
//! each of which is a `pub const x = @import("x.zig")` module reference.
//! Taking the address of a module reference does not descend into it: it
//! resolves neither the leaf files' struct field types nor their function
//! bodies (empirically confirmed — see src/simulation_test_root.zig's header
//! for the mutation-test evidence against this exact aggregator shape). Fixed
//! the same way: `refAllDecls` called directly on every leaf file, plus
//! `pinModuleTypes` to force struct/union/enum field-type resolution per leaf.
//!
//! NOTE: this file and `tests/unit/repository_unit_test_root.zig` are two
//! different shims — this one covers src/ in-file tests, that one aggregates
//! the tests/unit/repository_*.zig test FILES. Both are needed.
//!
//! Run via `zig build test-repository-src` (also reached by `zig build test`).

const std = @import("std");

pub const repository = @import("repository/mod.zig");

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
    std.testing.refAllDecls(repository);

    // ISS-0172: direct refAllDecls on every leaf, not just the mod.zig
    // aggregator.
    std.testing.refAllDecls(repository.canonicaliser);
    std.testing.refAllDecls(repository.artifacts);
    std.testing.refAllDecls(repository.schemas);
    std.testing.refAllDecls(repository.service_catalog);
    std.testing.refAllDecls(repository.activation);

    // ISS-0172: struct/union/enum field-type resolution per leaf.
    pinModuleTypes(repository.canonicaliser);
    pinModuleTypes(repository.artifacts);
    pinModuleTypes(repository.schemas);
    pinModuleTypes(repository.service_catalog);
    pinModuleTypes(repository.activation);
}
