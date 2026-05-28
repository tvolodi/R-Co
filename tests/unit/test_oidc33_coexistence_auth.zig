const std = @import("std");
const coexist = @import("oidc_coexistence");

test "OIDC-33 equivalence passes for same subject tenant and roles" {
    const roles = [_][]const u8{ "TASK_WORKER", "VIEWER" };
    const legacy = coexist.UnifiedAuthContext{
        .subject_id = "user-1",
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .roles = roles[0..],
        .token_kind = .legacy_internal,
        .issued_at_unix = 1,
    };
    const oidc = coexist.UnifiedAuthContext{
        .subject_id = "user-1",
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .roles = roles[0..],
        .token_kind = .oidc_bearer,
        .issued_at_unix = 2,
    };

    try coexist.assertAuthEquivalence(std.testing.allocator, legacy, oidc);
}

test "OIDC-33 equivalence fails for different tenant" {
    const roles = [_][]const u8{"TASK_WORKER"};
    const legacy = coexist.UnifiedAuthContext{
        .subject_id = "user-1",
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .roles = roles[0..],
        .token_kind = .legacy_internal,
        .issued_at_unix = 1,
    };
    const oidc = coexist.UnifiedAuthContext{
        .subject_id = "user-1",
        .tenant_id = "11111111-1111-1111-1111-111111111111",
        .roles = roles[0..],
        .token_kind = .oidc_bearer,
        .issued_at_unix = 2,
    };

    try std.testing.expectError(error.TenantContextMismatch, coexist.assertAuthEquivalence(std.testing.allocator, legacy, oidc));
}
