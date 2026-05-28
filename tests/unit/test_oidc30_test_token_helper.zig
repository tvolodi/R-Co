const std = @import("std");
const helper = @import("oidc_test_token_helper");

test "OIDC-30 helper blocks production" {
    try std.testing.expectError(error.HelperDisabledInProduction, helper.assertTestTokenHelperAllowed(.production));
}

test "OIDC-30 helper reports token unavailable when env token is missing" {
    try std.testing.expectError(error.TokenUnavailable, helper.issueTestOidcToken(
        std.testing.allocator,
        .{
            .realm_id = "bpm-default",
            .grant_type = .password,
            .username = "admin-user",
            .password = "admin-pass",
            .client_id = "bpm-platform-api",
            .requested_scopes = &.{"openid"},
        },
        .testing,
    ));
}
