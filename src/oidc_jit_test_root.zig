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
//! Run via `zig build test-oidc-jit` (also reached by `zig build test`).

const std = @import("std");

pub const jit_provisioning = @import("oidc/jit_provisioning.zig");

test {
    std.testing.refAllDecls(jit_provisioning);
}
