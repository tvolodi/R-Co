const std = @import("std");
const testing = std.testing;

const provider_types = @import("types.zig");
const keycloak = @import("adapters/keycloak/provider.zig");

const ScriptStep = struct {
    method: keycloak.Method,
    url: []const u8,
    bearer_token: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    body_contains: []const []const u8 = &.{},
    response: keycloak.HttpResponse,
};

const ScriptTransport = struct {
    steps: []const ScriptStep,
    index: usize = 0,

    fn send(raw_ctx: *anyopaque, allocator: std.mem.Allocator, request: keycloak.HttpRequest) anyerror!keycloak.HttpResponse {
        _ = allocator;
        const self: *ScriptTransport = @ptrCast(@alignCast(raw_ctx));
        try testing.expect(self.index < self.steps.len);
        const step = self.steps[self.index];
        self.index += 1;

        try testing.expectEqual(step.method, request.method);
        try testing.expectEqualStrings(step.url, request.url);
        if (step.bearer_token) |expected| {
            try testing.expect(request.bearer_token != null);
            try testing.expectEqualStrings(expected, request.bearer_token.?);
        } else {
            try testing.expect(request.bearer_token == null);
        }

        if (step.content_type) |expected| {
            try testing.expect(request.content_type != null);
            try testing.expectEqualStrings(expected, request.content_type.?);
        } else {
            try testing.expect(request.content_type == null);
        }

        for (step.body_contains) |needle| {
            try testing.expect(request.body != null);
            try testing.expect(std.mem.indexOf(u8, request.body.?, needle) != null);
        }

        return step.response;
    }
};

const StaticSecretResolver = struct {
    secret: []const u8,

    fn resolve(raw_ctx: *anyopaque, allocator: std.mem.Allocator, secret_ref: []const u8) anyerror![]const u8 {
        _ = secret_ref;
        const self: *StaticSecretResolver = @ptrCast(@alignCast(raw_ctx));
        return allocator.dupe(u8, self.secret);
    }
};

const FixedClock = struct {
    now: i64,

    fn nowUnixSeconds(raw_ctx: *anyopaque) i64 {
        const self: *FixedClock = @ptrCast(@alignCast(raw_ctx));
        return self.now;
    }
};

test "TC-OIDC-02-02: keycloak adapter verifyToken uses discovery and jwks endpoints while mapping principal fields" {
    const allocator = testing.allocator;
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .GET,
                .url = "https://kc.example.com/realms/acme/.well-known/openid-configuration",
                .response = .{ .status = 200, .body =
                    \\{"issuer":"https://kc.example.com/realms/acme","jwks_uri":"https://kc.example.com/realms/acme/protocol/openid-connect/certs"}
                },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/realms/acme/protocol/openid-connect/certs",
                .response = .{ .status = 200, .body =
                    \\{"keys":[{"kid":"kid-1","kty":"RSA"}]}
                },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };

    var adapter = try keycloak.Adapter.init(allocator, .{
        .base_url = "https://kc.example.com",
        .admin_base_url = null,
        .admin_realm = "master",
        .bootstrap_realm = "master",
        .admin_client_id = "bpm-admin",
        .admin_client_secret_ref = "secret://keycloak/admin",
        .expected_audience = "bpm-api",
        .expected_issuer = "https://kc.example.com/realms/acme",
        .connect_timeout_ms = 5_000,
        .request_timeout_ms = 10_000,
        .jwks_ttl_seconds = keycloak.Config.defaults.jwks_ttl_seconds,
        .jwks_min_refresh_seconds = keycloak.Config.defaults.jwks_min_refresh_seconds,
    }, .{
        .transport = .{ .ctx = &transport, .sendFn = ScriptTransport.send },
        .clock = .{ .ctx = &clock, .nowUnixSecondsFn = FixedClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = &resolver, .resolveFn = StaticSecretResolver.resolve },
    });
    defer adapter.deinit();

    const token = try makeUnsignedJwt(allocator,
        \\{"alg":"RS256","kid":"kid-1"}
    ,
        \\{"iss":"https://kc.example.com/realms/acme","sub":"user-123","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800,"tenant_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","preferred_username":"alice","name":"Alice Adams","email":"alice@example.com","realm_access":{"roles":["PROCESS_OPERATOR","VIEWER"]},"jti":"jwt-123"}
    );
    defer allocator.free(token);

    var principal = try adapter.asIdentityProvider().verifyToken(allocator, .{
        .raw_token = token,
        .expected_audience = "bpm-api",
        .expected_issuer = "https://kc.example.com/realms/acme",
        .now_unix_seconds = clock.now,
    });
    defer principal.deinit(allocator);

    try testing.expectEqualStrings("user-123", principal.provider_subject);
    try testing.expectEqualStrings("alice", principal.username);
    try testing.expectEqualStrings("Alice Adams", principal.display_name);
    try testing.expectEqualStrings("alice@example.com", principal.email.?);
    try testing.expectEqualStrings("acme", principal.external_realm.?);
    try testing.expectEqualStrings("jwt-123", principal.token_id_hint.?);
    try testing.expectEqual(@as(usize, 2), principal.roles.len);
    try testing.expectEqual(provider_types.ProviderRole.PROCESS_OPERATOR, principal.roles[0]);
    try testing.expectEqual(provider_types.ProviderRole.VIEWER, principal.roles[1]);
    try testing.expectEqual(@as(usize, 2), transport.index);
}

test "TC-OIDC-04-02: standards-only token verifies without provider-specific claim extensions" {
    const allocator = testing.allocator;
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-a/.well-known/openid-configuration",
                .response = .{ .status = 200, .body =
                    \\{"issuer":"https://idp.example.com/tenant-a","jwks_uri":"https://idp.example.com/tenant-a/keys"}
                },
            },
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-a/keys",
                .response = .{ .status = 200, .body =
                    \\{"keys":[{"kid":"std-kid-1","kty":"RSA"}]}
                },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };

    var adapter = try keycloak.Adapter.init(allocator, .{
        .base_url = "https://kc.example.com",
        .admin_base_url = null,
        .admin_realm = "master",
        .bootstrap_realm = "master",
        .admin_client_id = "bpm-admin",
        .admin_client_secret_ref = "secret://keycloak/admin",
        .expected_audience = "bpm-api",
        .expected_issuer = null,
        .connect_timeout_ms = 5_000,
        .request_timeout_ms = 10_000,
        .jwks_ttl_seconds = keycloak.Config.defaults.jwks_ttl_seconds,
        .jwks_min_refresh_seconds = keycloak.Config.defaults.jwks_min_refresh_seconds,
    }, .{
        .transport = .{ .ctx = &transport, .sendFn = ScriptTransport.send },
        .clock = .{ .ctx = &clock, .nowUnixSecondsFn = FixedClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = &resolver, .resolveFn = StaticSecretResolver.resolve },
    });
    defer adapter.deinit();

    const token = try makeUnsignedJwt(allocator,
        \\{"alg":"RS256","kid":"std-kid-1"}
    ,
        \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800,"preferred_username":"standards-user"}
    );
    defer allocator.free(token);

    var principal = try adapter.asIdentityProvider().verifyToken(allocator, .{
        .raw_token = token,
        .expected_audience = "bpm-api",
        .expected_issuer = null,
        .now_unix_seconds = clock.now,
    });
    defer principal.deinit(allocator);

    try testing.expectEqualStrings("std-user-1", principal.provider_subject);
    try testing.expectEqualStrings("standards-user", principal.username);
    try testing.expectEqual(@as(usize, 0), principal.roles.len);
    try testing.expectEqual(transport.steps.len, transport.index);
}

test "TC-OIDC-04-03: standards claim validation rejects issuer audience exp nbf and iat violations" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        payload_json: []const u8,
        expected_error: anyerror,
        expected_requests: usize,
    }{
        .{
            .payload_json =
            \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["wrong-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800}
            ,
            .expected_error = error.TokenAudienceMismatch,
            .expected_requests = 1,
        },
        .{
            .payload_json =
            \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1699990000,"nbf":1699989900,"iat":1699989800}
            ,
            .expected_error = error.TokenExpired,
            .expected_requests = 0,
        },
        .{
            .payload_json =
            \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1700001000,"iat":1699999800}
            ,
            .expected_error = error.TokenNotYetValid,
            .expected_requests = 0,
        },
        .{
            .payload_json =
            \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1700001000}
            ,
            .expected_error = error.ClaimValidationFailed,
            .expected_requests = 0,
        },
    };

    for (cases) |case| {
        var transport = ScriptTransport{
            .steps = &.{
                .{
                    .method = .GET,
                    .url = "https://idp.example.com/tenant-a/.well-known/openid-configuration",
                    .response = .{ .status = 200, .body =
                        \\{"issuer":"https://idp.example.com/tenant-a","jwks_uri":"https://idp.example.com/tenant-a/keys"}
                    },
                },
                .{
                    .method = .GET,
                    .url = "https://idp.example.com/tenant-a/keys",
                    .response = .{ .status = 200, .body =
                        \\{"keys":[{"kid":"std-kid-1","kty":"RSA"}]}
                    },
                },
            },
        };
        var resolver = StaticSecretResolver{ .secret = "super-secret" };
        var clock = FixedClock{ .now = 1_700_000_000 };
        var adapter = try initTestAdapter(allocator, &transport, &clock, &resolver, null);
        defer adapter.deinit();

        const token = try makeUnsignedJwt(allocator,
            \\{"alg":"RS256","kid":"std-kid-1"}
        ,
            case.payload_json
        );
        defer allocator.free(token);

        try testing.expectError(case.expected_error, adapter.asIdentityProvider().verifyToken(allocator, .{
            .raw_token = token,
            .expected_audience = "bpm-api",
            .expected_issuer = null,
            .now_unix_seconds = clock.now,
        }));
        try testing.expectEqual(case.expected_requests, transport.index);
    }
}

test "TC-OIDC-04-06: explicit issuer override rejects mismatched iss claim" {
    const allocator = testing.allocator;
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-b/.well-known/openid-configuration",
                .response = .{ .status = 200, .body =
                    \\{"issuer":"https://idp.example.com/tenant-b","jwks_uri":"https://idp.example.com/tenant-b/keys"}
                },
            },
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-b/keys",
                .response = .{ .status = 200, .body =
                    \\{"keys":[{"kid":"std-kid-1","kty":"RSA"}]}
                },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };
    var adapter = try initTestAdapter(allocator, &transport, &clock, &resolver, null);
    defer adapter.deinit();

    const token = try makeUnsignedJwt(allocator,
        \\{"alg":"RS256","kid":"std-kid-1"}
    ,
        \\{"iss":"https://idp.example.com/tenant-b","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800}
    );
    defer allocator.free(token);

    try testing.expectError(error.TokenIssuerMismatch, adapter.asIdentityProvider().verifyToken(allocator, .{
        .raw_token = token,
        .expected_audience = "bpm-api",
        .expected_issuer = "https://idp.example.com/tenant-a",
        .now_unix_seconds = clock.now,
    }));
    try testing.expectEqual(@as(usize, 1), transport.index);
}

test "TC-OIDC-04-04: discovery contract failure rejects verification before JWKS resolution" {
    const allocator = testing.allocator;
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-a/.well-known/openid-configuration",
                .response = .{ .status = 200, .body =
                    \\{"issuer":"https://idp.example.com/tenant-a"}
                },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };
    var adapter = try initTestAdapter(allocator, &transport, &clock, &resolver, null);
    defer adapter.deinit();

    const token = try makeUnsignedJwt(allocator,
        \\{"alg":"RS256","kid":"std-kid-1"}
    ,
        \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800}
    );
    defer allocator.free(token);

    try testing.expectError(error.UpstreamProtocolError, adapter.asIdentityProvider().verifyToken(allocator, .{
        .raw_token = token,
        .expected_audience = "bpm-api",
        .expected_issuer = null,
        .now_unix_seconds = clock.now,
    }));
    try testing.expectEqual(transport.steps.len, transport.index);
}

test "TC-OIDC-04-05: signature verification fails when JWKS has no matching kid" {
    const allocator = testing.allocator;
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-a/.well-known/openid-configuration",
                .response = .{ .status = 200, .body =
                    \\{"issuer":"https://idp.example.com/tenant-a","jwks_uri":"https://idp.example.com/tenant-a/keys"}
                },
            },
            .{
                .method = .GET,
                .url = "https://idp.example.com/tenant-a/keys",
                .response = .{ .status = 200, .body =
                    \\{"keys":[{"kid":"different-kid","kty":"RSA"}]}
                },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };
    var adapter = try initTestAdapter(allocator, &transport, &clock, &resolver, null);
    defer adapter.deinit();

    const token = try makeUnsignedJwt(allocator,
        \\{"alg":"RS256","kid":"std-kid-1"}
    ,
        \\{"iss":"https://idp.example.com/tenant-a","sub":"std-user-1","aud":["bpm-api"],"exp":1700000600,"nbf":1699999900,"iat":1699999800}
    );
    defer allocator.free(token);

    try testing.expectError(error.SignatureVerificationFailed, adapter.asIdentityProvider().verifyToken(allocator, .{
        .raw_token = token,
        .expected_audience = "bpm-api",
        .expected_issuer = null,
        .now_unix_seconds = clock.now,
    }));
    try testing.expectEqual(transport.steps.len, transport.index);
}

test "TC-OIDC-02-03: keycloak adapter admin contract stays inside adapter-specific routes and payloads" {
    const allocator = testing.allocator;
    const user_location_headers = [_]keycloak.Header{.{ .name = "Location", .value = "https://kc.example.com/admin/realms/acme/users/user-99" }};
    var transport = ScriptTransport{
        .steps = &.{
            .{
                .method = .POST,
                .url = "https://kc.example.com/realms/master/protocol/openid-connect/token",
                .content_type = "application/x-www-form-urlencoded",
                .body_contains = &.{ "grant_type=client_credentials", "client_id=bpm-admin", "client_secret=super-secret" },
                .response = .{ .status = 200, .body = "{\"access_token\":\"admin-token\",\"expires_in\":300}" },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/users/user-42",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "{\"id\":\"user-42\",\"username\":\"bob\",\"firstName\":\"Bob\",\"lastName\":\"Builder\",\"email\":\"bob@example.com\",\"enabled\":true}" },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme",
                .bearer_token = "admin-token",
                .response = .{ .status = 404 },
            },
            .{
                .method = .POST,
                .url = "https://kc.example.com/admin/realms",
                .bearer_token = "admin-token",
                .content_type = "application/json",
                .body_contains = &.{ "\"realm\":\"acme\"", "\"displayName\":\"Acme Corp\"" },
                .response = .{ .status = 201 },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/users?q=external_id:ext-7&exact=true",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "[]" },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/users?username=bob&exact=true",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "[]" },
            },
            .{
                .method = .POST,
                .url = "https://kc.example.com/admin/realms/acme/users",
                .bearer_token = "admin-token",
                .content_type = "application/json",
                .body_contains = &.{ "\"username\":\"bob\"", "\"external_id\":[\"ext-7\"]" },
                .response = .{ .status = 201, .headers = user_location_headers[0..] },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/roles/PROCESS_OPERATOR",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "{\"id\":\"role-1\",\"name\":\"PROCESS_OPERATOR\"}" },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/roles/VIEWER",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "{\"id\":\"role-2\",\"name\":\"VIEWER\"}" },
            },
            .{
                .method = .POST,
                .url = "https://kc.example.com/admin/realms/acme/users/user-99/role-mappings/realm",
                .bearer_token = "admin-token",
                .content_type = "application/json",
                .body_contains = &.{ "PROCESS_OPERATOR", "VIEWER" },
                .response = .{ .status = 204 },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/clients?clientId=bpm-web",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "[]" },
            },
            .{
                .method = .POST,
                .url = "https://kc.example.com/admin/realms/acme/clients",
                .bearer_token = "admin-token",
                .content_type = "application/json",
                .body_contains = &.{ "\"clientId\":\"bpm-web\"", "\"serviceAccountsEnabled\":true" },
                .response = .{ .status = 201 },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/identity-provider/instances/google",
                .bearer_token = "admin-token",
                .response = .{ .status = 404 },
            },
            .{
                .method = .POST,
                .url = "https://kc.example.com/admin/realms/acme/identity-provider/instances",
                .bearer_token = "admin-token",
                .content_type = "application/json",
                .body_contains = &.{ "\"alias\":\"google\"", "\"providerId\":\"oidc\"" },
                .response = .{ .status = 201 },
            },
            .{
                .method = .DELETE,
                .url = "https://kc.example.com/admin/realms/acme/identity-provider/instances/google",
                .bearer_token = "admin-token",
                .response = .{ .status = 204 },
            },
            .{
                .method = .GET,
                .url = "https://kc.example.com/admin/realms/acme/admin-events?first=0&max=1&dateFrom=0&dateTo=1000",
                .bearer_token = "admin-token",
                .response = .{ .status = 200, .body = "[{\"operationType\":\"CREATE\",\"resourceType\":\"USER\",\"time\":500,\"authDetails\":{\"userId\":\"user-42\"},\"resourcePath\":\"users/user-42\"}]" },
            },
        },
    };
    var resolver = StaticSecretResolver{ .secret = "super-secret" };
    var clock = FixedClock{ .now = 1_700_000_000 };

    var adapter = try keycloak.Adapter.init(allocator, .{
        .base_url = "https://kc.example.com",
        .admin_base_url = null,
        .admin_realm = "master",
        .bootstrap_realm = "master",
        .admin_client_id = "bpm-admin",
        .admin_client_secret_ref = "secret://keycloak/admin",
        .expected_audience = "bpm-api",
        .expected_issuer = null,
        .connect_timeout_ms = 5_000,
        .request_timeout_ms = 10_000,
        .jwks_ttl_seconds = keycloak.Config.defaults.jwks_ttl_seconds,
        .jwks_min_refresh_seconds = keycloak.Config.defaults.jwks_min_refresh_seconds,
    }, .{
        .transport = .{ .ctx = &transport, .sendFn = ScriptTransport.send },
        .clock = .{ .ctx = &clock, .nowUnixSecondsFn = FixedClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = &resolver, .resolveFn = StaticSecretResolver.resolve },
    });
    defer adapter.deinit();

    var user = (try adapter.asIdentityProvider().lookupUser(allocator, .{
        .tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .external_realm = "acme",
        .external_id = "user-42",
    })).?;
    defer user.deinit(allocator);
    try testing.expectEqualStrings("Bob Builder", user.display_name);

    var realm = try adapter.asIdentityProvider().provisionRealm(allocator, .{
        .tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .tenant_slug = "acme",
        .display_name = "Acme Corp",
        .desired_realm_id = null,
    });
    defer realm.deinit(allocator);
    try testing.expect(realm.created);

    var created_user = try adapter.asIdentityProvider().provisionUser(allocator, .{
        .tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .external_realm = "acme",
        .external_id = "ext-7",
        .preferred_username = "bob",
        .display_name = "Bob Builder",
        .email = "bob@example.com",
        .initial_roles = &.{ .PROCESS_OPERATOR, .VIEWER },
    });
    defer created_user.deinit(allocator);
    try testing.expect(created_user.created);
    try testing.expectEqualStrings("user-99", created_user.external_user_id);

    const grant_result = try adapter.asIdentityProvider().grantRoles(allocator, .{
        .realm_id = "acme",
        .external_user_id = "user-99",
        .roles = &.{ .PROCESS_OPERATOR, .VIEWER },
    });
    try testing.expectEqual(@as(usize, 2), grant_result.applied);

    var client = try adapter.asIdentityProvider().provisionClient(allocator, .{
        .realm_id = "acme",
        .client_name = "bpm-web",
        .redirect_uris = &.{ "https://bpm.example.com/callback" },
        .service_account_enabled = true,
    });
    defer client.deinit(allocator);
    try testing.expect(client.created);

    var federation = try adapter.asIdentityProvider().upsertFederation(allocator, .{
        .realm_id = "acme",
        .provider_alias = "google",
        .provider_type = "oidc",
        .config_json = "{\"clientId\":\"google-client\"}",
        .claim_mapping_json = "{\"tenant_id\":\"tenant\"}",
    });
    defer federation.deinit(allocator);
    try testing.expect(federation.created);

    try adapter.asIdentityProvider().deleteFederation(allocator, .{
        .realm_id = "acme",
        .provider_alias = "google",
    });

    var events = try adapter.asIdentityProvider().listAuditEvents(allocator, .{
        .realm_id = "acme",
        .from_timestamp_ms = 0,
        .to_timestamp_ms = 1000,
        .cursor = null,
        .page_size = 1,
    });
    defer events.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), events.events.len);
    try testing.expectEqualStrings("CREATE:USER", events.events[0].event_type);
    try testing.expectEqualStrings("user-42", events.events[0].actor_id.?);
    try testing.expectEqualStrings("1", events.next_cursor.?);

    try testing.expectEqual(transport.steps.len, transport.index);
}

fn makeUnsignedJwt(allocator: std.mem.Allocator, header_json: []const u8, payload_json: []const u8) ![]u8 {
    const header = try encodeBase64Url(allocator, header_json);
    defer allocator.free(header);
    const payload = try encodeBase64Url(allocator, payload_json);
    defer allocator.free(payload);
    return std.fmt.allocPrint(allocator, "{s}.{s}.signature", .{ header, payload });
}

fn encodeBase64Url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const out = try allocator.alloc(u8, out_len);
    _ = encoder.encode(out, input);
    return out;
}

fn initTestAdapter(
    allocator: std.mem.Allocator,
    transport: *ScriptTransport,
    clock: *FixedClock,
    resolver: *StaticSecretResolver,
    expected_issuer: ?[]const u8,
) !keycloak.Adapter {
    return keycloak.Adapter.init(allocator, .{
        .base_url = "https://kc.example.com",
        .admin_base_url = null,
        .admin_realm = "master",
        .bootstrap_realm = "master",
        .admin_client_id = "bpm-admin",
        .admin_client_secret_ref = "secret://keycloak/admin",
        .expected_audience = "bpm-api",
        .expected_issuer = expected_issuer,
        .connect_timeout_ms = 5_000,
        .request_timeout_ms = 10_000,
        .jwks_ttl_seconds = keycloak.Config.defaults.jwks_ttl_seconds,
        .jwks_min_refresh_seconds = keycloak.Config.defaults.jwks_min_refresh_seconds,
    }, .{
        .transport = .{ .ctx = transport, .sendFn = ScriptTransport.send },
        .clock = .{ .ctx = clock, .nowUnixSecondsFn = FixedClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = resolver, .resolveFn = StaticSecretResolver.resolve },
    });
}