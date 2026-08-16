//! Test root for `src/validation/` — VLD-01, VLD-02, VLD-03.
//!
//! Aggregates the eight validation-module files (finding, env, scope, site,
//! pd06, typecheck, wire, mod) into a single `zig build test` compile unit.
//!
//! Two constraints force this shim to sit at `src/validation/` rather than
//! beside the files it tests:
//!
//!   1. Each validation file reaches siblings by relative path (e.g.
//!      typecheck.zig's `@import("env.zig")`), and Zig 0.16 rejects an
//!      `@import` that escapes the module root — so the root must be at
//!      `src/validation/`.
//!   2. The `test {}` block at this root is REQUIRED — Zig runs test blocks
//!      only in files reachable through analyzed declarations, and a
//!      bare `pub const` re-export does not force analysis of in-file
//!      `test {...}` blocks (see src/transition_test_root.zig's comment
//!      on the same defect). The `_ = @import(...)` calls below force
//!      analysis of every sibling file, which is what causes their
//!      in-file `test {...}` blocks to be discovered and run.
//!
//! Run via `zig build test-validation` (also reached by `zig build test`).

test {
    _ = @import("finding.zig");
    _ = @import("env.zig");
    _ = @import("scope.zig");
    _ = @import("site.zig");
    _ = @import("pd06.zig");
    _ = @import("typecheck.zig");
    _ = @import("wire.zig");
    _ = @import("mod.zig");
}
