//! Aggregator root for the eight tests/unit/test_oidc*.zig files that were
//! wired into no build target (38 test blocks).
//!
//! ISS-0137 / GH #439, root cause RC-3: each of these files imports a named
//! module (`jwks_cache`, `claim_mapping`, `oidc_bench`, `realm_seed`,
//! `oidc_test_token_helper`, `oidc_coexistence`) that build.zig declared
//! nowhere, so the files could not even compile — let alone run. Cluster C4a
//! declares those modules; this shim gives their tests a root to be reached
//! from.
//!
//! No top-level `test "..."` name collides across the eight files (verified).
//!
//! `setCwd(b.path("."))` on this target's Run artifact is REQUIRED, not
//! cosmetic: test_oidc28_local_dev_realm.zig and
//! test_oidc32_agent_test_identities.zig read docker-compose.yml and
//! infrastructure/keycloak/realms/*.json from disk via Dir.cwd(). Without
//! setCwd they fail with FileNotFound depending on the invocation directory —
//! the same treatment sch303_timer_dlq_unit_test.zig already gets.
//!
//! These two files need NO running Keycloak: their "keycloak" matches are
//! assertions on file *content*, so this group belongs on `zig build test`,
//! not on `test-integration`.
//!
//! Run with: zig build test-oidc-unit (also reached by zig build test).
//!
//! Note: the `test { }` block below is itself counted by Zig's runner as one
//! synthetic container test, so the reported total is 38 + 1.

test {
    _ = @import("test_oidc06_jwks_cache.zig");
    _ = @import("test_oidc08_claim_mapping.zig");
    _ = @import("test_oidc27_verification_benchmark.zig");
    _ = @import("test_oidc28_local_dev_realm.zig");
    _ = @import("test_oidc29_realm_seed.zig");
    _ = @import("test_oidc30_test_token_helper.zig");
    _ = @import("test_oidc32_agent_test_identities.zig");
    _ = @import("test_oidc33_coexistence_auth.zig");
}
