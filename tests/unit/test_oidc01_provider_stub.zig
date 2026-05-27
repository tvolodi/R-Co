const std = @import("std");
const testing = std.testing;
const api = @import("api");

const provider = api.identity_provider;
const manager_mod = provider.manager;
const types = provider.types;
const stub = provider.adapters.stub;
const VALID_OIDC_JWT = "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature";

test "TC-OIDC-01-05a: manager verifyBearerToken delegates through IdentityProvider interface" {
    const alloc = testing.allocator;

    var roles = [_]types.ProviderRole{.PROCESS_OPERATOR};
    var stub_ctx = stub.StubContext{
        .verify_result = .{ .ok = .{
            .provider_subject = "provider-subject-verify",
            .username = "oidc.verify",
            .display_name = "OIDC Verify",
            .email = "oidc.verify@example.com",
            .tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".*,
            .roles = roles[0..],
            .external_realm = "tenant-realm",
            .token_id_hint = "oidc-token-verify",
        } },
    };

    const manager = manager_mod.Manager{
        .provider = stub.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
        .expected_audience = "bpm-api",
        .expected_issuer = "https://issuer.example.com",
    };

    var principal = try manager.verifyBearerToken(alloc, VALID_OIDC_JWT);
    defer principal.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), stub_ctx.verify_call_count);
    try testing.expectEqualStrings("provider-subject-verify", principal.provider_subject);
    try testing.expectEqualStrings("oidc.verify", principal.username);
    try testing.expectEqual(@as(usize, 1), principal.roles.len);
    try testing.expectEqual(types.ProviderRole.PROCESS_OPERATOR, principal.roles[0]);
}

test "TC-OIDC-01-05b: manager exposes all required OIDC-01 operations via interface" {
    const alloc = testing.allocator;
    var stub_ctx = stub.StubContext{};
    const manager = manager_mod.Manager{
        .provider = stub.asIdentityProvider(&stub_ctx),
        .auth_mode = .dual_accept,
    };

    const empty_roles = [_]types.ProviderRole{};
    const empty_redirect_uris = [_][]const u8{};

    try testing.expectError(error.NotImplemented, manager.lookupUser(alloc, .{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .external_realm = "bpm-default",
        .external_id = "external-user-1",
    }));

    try testing.expectError(error.NotImplemented, manager.provisionRealm(alloc, .{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .tenant_slug = "default",
        .display_name = "Default Tenant",
        .desired_realm_id = null,
    }));

    try testing.expectError(error.NotImplemented, manager.provisionUser(alloc, .{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .external_realm = "bpm-default",
        .external_id = "external-user-1",
        .preferred_username = "oidc-user",
        .display_name = "OIDC User",
        .email = null,
        .initial_roles = empty_roles[0..],
    }));

    try testing.expectError(error.NotImplemented, manager.grantRoles(alloc, .{
        .realm_id = "bpm-default",
        .external_user_id = "external-user-1",
        .roles = empty_roles[0..],
    }));

    try testing.expectError(error.NotImplemented, manager.provisionClient(alloc, .{
        .realm_id = "bpm-default",
        .client_name = "bpm-client",
        .redirect_uris = empty_redirect_uris[0..],
        .service_account_enabled = true,
    }));

    try testing.expectError(error.NotImplemented, manager.upsertFederation(alloc, .{
        .realm_id = "bpm-default",
        .provider_alias = "google",
        .provider_type = "oidc",
        .config_json = "{}",
        .claim_mapping_json = "{}",
    }));

    try testing.expectError(error.NotImplemented, manager.deleteFederation(alloc, .{
        .realm_id = "bpm-default",
        .provider_alias = "google",
    }));

    try testing.expectError(error.NotImplemented, manager.listAuditEvents(alloc, .{
        .realm_id = "bpm-default",
        .from_timestamp_ms = 0,
        .to_timestamp_ms = 10,
        .cursor = null,
        .page_size = 10,
    }));
}