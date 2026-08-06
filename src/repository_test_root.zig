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
//! NOTE: this file and `tests/unit/repository_unit_test_root.zig` are two
//! different shims — this one covers src/ in-file tests, that one aggregates
//! the tests/unit/repository_*.zig test FILES. Both are needed.
//!
//! Run via `zig build test-repository-src` (also reached by `zig build test`).

const std = @import("std");

pub const repository = @import("repository/mod.zig");

test {
    std.testing.refAllDecls(repository);
}
