//! Aggregator root for the tests/unit/repository_*.zig test files (13 blocks).
//!
//! ISS-0137 / GH #439, root cause RC-3: both files import the named module
//! `repository`, which build.zig declared nowhere. Cluster C4a declares it
//! (root src/repository/mod.zig); this shim gives these two files a root.
//!
//! Named `repository_unit_test_root.zig`, NOT `repository_test_root.zig`, to
//! avoid a near-collision with `src/repository_test_root.zig` — two files whose
//! basenames differ only by directory invite exactly the kind of mistake this
//! whole issue is about. That shim covers the in-file tests inside
//! src/repository/*.zig; this one covers these two test FILES.
//!
//! Both belong on `zig build test`, not `test-integration`:
//! repository_artifacts_test.zig mentions BPM_TEST_DB_URL only in a comment
//! ("Full DB tests are in test-integration mode") — its single test body is
//! `_ = repository.artifacts;`, with zero DB usage.
//!
//! Run with: zig build test-repository-unit (also reached by zig build test).

test {
    _ = @import("repository_canonicaliser_test.zig");
    _ = @import("repository_artifacts_test.zig");
}
