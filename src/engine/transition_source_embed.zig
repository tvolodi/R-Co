//! Embed shim for `tests/differential/differential_test.zig`'s static
//! import-gate assertions (TC-ISS-602-03 / TC-EXP-102-04).
//!
//! `@embedFile` resolves relative to the *module* that contains the calling
//! file, and cannot escape that module's root directory. The differential test
//! lives under `tests/differential/`, so its own `@embedFile("../../src/engine/
//! transition.zig")` is rejected by the compiler with "embed of file outside
//! package path" — which is why `zig build test-differential` never compiled
//! (ISS-0157 / GH #476).
//!
//! Colocating a one-line shim beside the file being embedded is the pattern
//! already used in this repo for exactly this problem — see
//! `docs/exp701_doc_embed.zig`, which embeds two docs for
//! `tests/unit/exp701_sandbox_threatmodel_test.zig`. The shim is passed to the
//! test as a named module, so the embed happens inside the module that owns
//! `src/engine/`, where the path is legal.
//!
//! This keeps the assertion a compile-time-resolved search over the real
//! `transition.zig` bytes: the gate still reads production source, so it still
//! fails if `transition.zig` regains an `@import("cel")` or loses its
//! `@import("expr")`. Nothing about what the test measures changes.

/// Raw source bytes of `src/engine/transition.zig`.
pub const transition_source = @embedFile("transition.zig");
