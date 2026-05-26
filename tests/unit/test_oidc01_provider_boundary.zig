const std = @import("std");
const testing = std.testing;
const api = @import("api");

const manager_mod = api.identity_provider.manager;
const stub = api.identity_provider.adapters.stub;

test "TC-OIDC-01-03: manager routes only JWT-like tokens to external provider verification" {
    var stub_ctx = stub.StubContext{};

    const no_provider = manager_mod.Manager{
        .provider = null,
        .auth_mode = .dual_accept,
    };
    try testing.expect(!no_provider.shouldVerifyExternalToken("a.b.c"));

    const with_provider = manager_mod.Manager{
        .provider = stub.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    };
    try testing.expect(with_provider.shouldVerifyExternalToken("a.b.c"));
    try testing.expect(!with_provider.shouldVerifyExternalToken("opaque-token"));
}

test "TC-OIDC-01-04: manager local_only mode preserves non-provider auth path" {
    var stub_ctx = stub.StubContext{};
    const manager = manager_mod.Manager{
        .provider = stub.asIdentityProvider(&stub_ctx),
        .auth_mode = .local_only,
    };

    try testing.expect(!manager.shouldVerifyExternalToken("a.b.c"));
    try testing.expect(!manager.shouldVerifyExternalToken("opaque-token"));
}