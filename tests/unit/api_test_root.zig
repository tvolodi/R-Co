//! Aggregator root for the api_mod unit test group (API-01, API-06, API-07,
//! API-09, OIDC-01).
//!
//! Combines api_conventions_test.zig, test_api06_pagination.zig,
//! test_api07_validation.zig, test_api09_tracing.zig,
//! test_oidc01_provider_boundary.zig, and test_oidc01_provider_stub.zig into
//! a single `zig build test` compile unit. Each file imports only `std` and
//! `api`, with no file-scope mutable state and no duplicate top-level test
//! names across the group (verified by inspection).
//!
//! Run with: zig build test (or zig build test-api for this group only)
//!
//! Note: the `test { }` block below is itself counted as one test by Zig's
//! runner (a synthetic "container" test) — see graph_test_root.zig for the
//! full explanation of this idiom.

test {
    _ = @import("api_conventions_test.zig");
    _ = @import("test_api06_pagination.zig");
    _ = @import("test_api07_validation.zig");
    _ = @import("test_api09_tracing.zig");
    _ = @import("test_oidc01_provider_boundary.zig");
    _ = @import("test_oidc01_provider_stub.zig");
}
