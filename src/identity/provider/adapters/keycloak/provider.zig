const std = @import("std");
const provider_interface = @import("../../interface.zig");
const provider_types = @import("../../types.zig");
const provider_errors = @import("../../errors.zig");
const keycloak_config = @import("config.zig");
const keycloak_urls = @import("urls.zig");
const standards_verifier = @import("../../oidc/standards_verifier.zig");
const jwks_cache_mod = @import("../../oidc/jwks_cache.zig");

pub const Config = keycloak_config.Config;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: Method,
    url: []const u8,
    bearer_token: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const HttpResponse = struct {
    status: u16,
    body: []const u8 = "",
    headers: []const Header = &.{},

    pub fn header(self: HttpResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }
};

pub const HttpTransport = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse,

    pub fn send(self: HttpTransport, allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse {
        return self.sendFn(self.ctx, allocator, request);
    }
};

pub const SecretResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, secret_ref: []const u8) anyerror![]const u8,

    pub fn resolve(self: SecretResolver, allocator: std.mem.Allocator, secret_ref: []const u8) anyerror![]const u8 {
        return self.resolveFn(self.ctx, allocator, secret_ref);
    }
};

pub const Clock = struct {
    ctx: *anyopaque,
    nowUnixSecondsFn: *const fn (ctx: *anyopaque) i64,

    pub fn nowUnixSeconds(self: Clock) i64 {
        return self.nowUnixSecondsFn(self.ctx);
    }
};

pub const InitDeps = struct {
    transport: HttpTransport,
    clock: Clock,
    secret_resolver: SecretResolver,
};

const CachedAdminToken = struct {
    access_token: []u8,
    expires_at: i64,
};

const DiscoveryDocument = struct {
    issuer: []const u8,
    jwks_uri: []const u8,
};

const KeycloakRoleRepresentation = struct {
    id: []const u8,
    name: []const u8,
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    transport: HttpTransport,
    clock: Clock,
    admin_client_secret: []u8,
    cached_admin_token: ?CachedAdminToken = null,
    jwks_cache: jwks_cache_mod.JwksCache,

    pub fn init(allocator: std.mem.Allocator, config: Config, deps: InitDeps) provider_errors.ProviderError!Adapter {
        var owned_config = keycloak_config.Config.clone(allocator, config) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.Internal,
        };
        errdefer owned_config.deinit(allocator);

        const resolved_secret = deps.secret_resolver.resolve(allocator, owned_config.admin_client_secret_ref) catch |err| {
            return mapExternalError(err);
        };
        defer allocator.free(resolved_secret);
        const admin_client_secret = allocator.dupe(u8, resolved_secret) catch return error.OutOfMemory;

        const jwks_cache = jwks_cache_mod.JwksCache.init(
            allocator,
            @intCast(owned_config.jwks_ttl_seconds),
            @intCast(owned_config.jwks_min_refresh_seconds),
        );

        return .{
            .allocator = allocator,
            .config = owned_config,
            .transport = deps.transport,
            .clock = deps.clock,
            .admin_client_secret = admin_client_secret,
            .jwks_cache = jwks_cache,
        };
    }

    pub fn deinit(self: *Adapter) void {
        if (self.cached_admin_token) |cache| self.allocator.free(cache.access_token);
        self.allocator.free(self.admin_client_secret);
        self.jwks_cache.deinit();
        self.config.deinit(self.allocator);
    }

    pub fn asIdentityProvider(self: *Adapter) provider_interface.IdentityProvider {
        return .{
            .ctx = self,
            .verifyTokenFn = verifyToken,
            .lookupUserFn = lookupUser,
            .provisionRealmFn = provisionRealm,
            .provisionUserFn = provisionUser,
            .grantRolesFn = grantRoles,
            .provisionClientFn = provisionClient,
            .upsertFederationFn = upsertFederation,
            .deleteFederationFn = deleteFederation,
            .listAuditEventsFn = listAuditEvents,
            .createProtocolMapperFn = createProtocolMapper,
            .toggleRealmFn = toggleRealmKeycloak,
            .deleteRealmFn = deleteRealmKeycloak,
            .updateClientFn = updateClientKeycloak,
            .updateRealmFrontendUrlFn = updateRealmFrontendUrlKeycloak,
            .checkRealmExistsFn = checkRealmExistsKeycloak,
        };
    }
};

fn verifyToken(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.VerifyTokenInput) provider_errors.ProviderError!provider_types.VerifiedPrincipal {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));

    const preview_payload = try parseJwtSegment(allocator, input.raw_token, 1);
    defer preview_payload.deinit();
    const preview_payload_obj = payloadlessObject(preview_payload.value);
    const issuer_hint = valueString(preview_payload_obj, "iss");
    const realm_name = if (issuer_hint) |issuer| realmFromIssuer(issuer) orelse self.config.bootstrap_realm else self.config.bootstrap_realm;
    const discovery_url = if (issuer_hint) |issuer|
        try deriveDiscoveryUrlFromIssuer(allocator, issuer)
    else
        keycloak_urls.discovery(allocator, self.config, realm_name) catch return error.OutOfMemory;
    defer allocator.free(discovery_url);

    const expected_issuer = input.expected_issuer orelse self.config.expected_issuer;
    const audience = if (input.expected_audience.len != 0) input.expected_audience else self.config.expected_audience;
    const now_unix_seconds = if (input.now_unix_seconds > 0) input.now_unix_seconds else self.clock.nowUnixSeconds();

    var verified = try standards_verifier.verify(allocator, .{
        .discovery_resolver = .{ .ctx = self, .resolveFn = resolveDiscoveryDocument },
        .jwks_resolver = .{ .ctx = self, .containsKidFn = resolveJwksKid },
    }, .{
        .discovery_url = discovery_url,
        .raw_token = input.raw_token,
        .expected_audience = audience,
        .expected_issuer = expected_issuer,
        .now_unix_seconds = now_unix_seconds,
        .allowed_clock_skew_seconds = self.config.clock_skew_seconds,
    });
    defer verified.deinit();

    const payload_obj = payloadlessObject(verified.payload.value);
    const roles = try extractRoles(allocator, verified.payload.value);
    errdefer allocator.free(roles);

    const username_claim = valueString(payload_obj, "preferred_username") orelse verified.subject;
    const display_name_claim = valueString(payload_obj, "name") orelse username_claim;

    const provider_subject = allocator.dupe(u8, verified.subject) catch return error.OutOfMemory;
    errdefer allocator.free(provider_subject);
    const username = allocator.dupe(u8, username_claim) catch return error.OutOfMemory;
    errdefer allocator.free(username);
    const display_name = allocator.dupe(u8, display_name_claim) catch return error.OutOfMemory;
    errdefer allocator.free(display_name);
    const email = try dupeOptional(allocator, valueString(payload_obj, "email"));
    errdefer if (email) |value| allocator.free(value);
    const external_realm = allocator.dupe(u8, realm_name) catch return error.OutOfMemory;
    errdefer allocator.free(external_realm);
    const token_id_hint = try dupeOptional(allocator, verified.token_id);
    errdefer if (token_id_hint) |value| allocator.free(value);

    return .{
        .provider_subject = provider_subject,
        .username = username,
        .display_name = display_name,
        .email = email,
        .tenant_id = extractTenantId(verified.payload.value),
        .roles = roles,
        .external_realm = external_realm,
        .token_id_hint = token_id_hint,
    };
}

fn lookupUser(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.LookupUserInput) provider_errors.ProviderError!?provider_types.ProviderUser {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const url = keycloak_urls.userById(allocator, self.config, input.external_realm, input.external_id) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = url,
        .bearer_token = bearer,
    });
    if (response.status == 404) return null;
    if (response.status != 200) return mapStatus(response.status, .lookup_user);

    return try parseProviderUser(allocator, response.body);
}

fn provisionRealm(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.ProvisionRealmInput) provider_errors.ProviderError!provider_types.ProvisionRealmResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);
    const realm_id = input.desired_realm_id orelse input.tenant_slug;

    const existing_url = keycloak_urls.realm(allocator, self.config, realm_id) catch return error.OutOfMemory;
    defer allocator.free(existing_url);

    const existing = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = existing_url,
        .bearer_token = bearer,
    });

    if (existing.status == 200) {
        // Realm already exists — apply full configuration (ensure pass).
        _ = applyRealmConfiguration(self, allocator, bearer, realm_id, input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnauthorizedAdminCall => return error.UnauthorizedAdminCall,
            error.UpstreamProtocolError => return error.UpstreamProtocolError,
            else => {},
        };
        return .{
            .realm_id = allocator.dupe(u8, realm_id) catch return error.OutOfMemory,
            .created = false,
        };
    }
    if (existing.status != 404) return mapStatus(existing.status, .provision_realm);

    // Step 1: Create realm with basic config plus extended OIDC-14 settings.
    const body = try buildRealmCreateBodyExtended(allocator, realm_id, input);
    defer allocator.free(body);
    const collection_url = keycloak_urls.realmsCollection(allocator, self.config) catch return error.OutOfMemory;
    defer allocator.free(collection_url);

    const create_response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = collection_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });
    if (create_response.status != 201 and create_response.status != 204) return mapStatus(create_response.status, .provision_realm);

    // The creation body (buildRealmCreateBodyExtended) already includes all
    // configuration fields (token lifetimes, password policy, etc.), so a
    // separate PUT update step is not required for fresh realms.

    // Flush the cached admin token: Keycloak issues JWTs that embed the set of
    // realms the service account can manage. A token obtained BEFORE realm
    // creation does not carry cross-realm admin grants for the new realm.
    // Clearing the cache here forces a fresh token to be issued post-creation,
    // which Keycloak will populate with the correct admin grants.
    if (self.cached_admin_token) |cache| {
        self.allocator.free(cache.access_token);
        self.cached_admin_token = null;
    }
    const fresh_bearer = try ensureAdminToken(self, allocator);

    // Step 2: Create standard platform roles in the new realm.
    try createStandardRoles(self, allocator, fresh_bearer, realm_id);

    // Step 9: Create tenant_id protocol mapper (OIDC-13).
    const mapper_body = try buildTenantIdMapperBodySimple(allocator, input.tenant_id);
    defer allocator.free(mapper_body);
    const mappers_url = keycloak_urls.protocolMappersCollection(allocator, self.config, realm_id) catch return error.OutOfMemory;
    defer allocator.free(mappers_url);

    _ = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = mappers_url,
        .bearer_token = fresh_bearer,
        .content_type = "application/json",
        .body = mapper_body,
    });

    // Step 10: Add realm-roles mapper so role claims appear in JWT (ISS-UAT-V6-001).
    // 201 = created, 409 = already exists — both are acceptable (idempotent).
    const roles_mapper_resp = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = mappers_url,
        .bearer_token = fresh_bearer,
        .content_type = "application/json",
        .body =
        \\{"name":"realm roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper","config":{"claim.name":"realm_access.roles","jsonType.label":"String","access.token.claim":"true","id.token.claim":"false","multivalued":"true"}}
        ,
    });
    if (roles_mapper_resp.status != 201 and roles_mapper_resp.status != 204 and roles_mapper_resp.status != 409) {
        return mapStatus(roles_mapper_resp.status, .provision_realm);
    }

    // Step 11: Add audience mapper so JWT aud claim includes 'bpm-platform-api' (ISS-UAT-V7-001).
    // 201 = created, 409 = already exists — both are acceptable (idempotent).
    const audience_mapper_resp = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = mappers_url,
        .bearer_token = fresh_bearer,
        .content_type = "application/json",
        .body =
        \\{"name":"bpm-platform-api audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"bpm-platform-api","access.token.claim":"true","id.token.claim":"false"}}
        ,
    });
    if (audience_mapper_resp.status != 201 and audience_mapper_resp.status != 204 and audience_mapper_resp.status != 409) {
        return mapStatus(audience_mapper_resp.status, .provision_realm);
    }

    return .{
        .realm_id = allocator.dupe(u8, realm_id) catch return error.OutOfMemory,
        .created = true,
    };
}

/// Create all standard platform roles in a freshly provisioned realm.
/// Keycloak does not create custom roles automatically — each role must be
/// POSTed to /admin/realms/{realm}/roles. 409 Conflict means the role already
/// exists and is safely ignored (idempotent).
fn createStandardRoles(
    self: *Adapter,
    allocator: std.mem.Allocator,
    bearer: []const u8,
    realm_id: []const u8,
) (provider_errors.ProviderError || error{OutOfMemory})!void {
    const roles_url = keycloak_urls.rolesCollection(allocator, self.config, realm_id) catch return error.OutOfMemory;
    defer allocator.free(roles_url);

    const all_roles = comptime std.meta.tags(provider_types.ProviderRole);
    inline for (all_roles) |role_tag| {
        const role_name = @tagName(role_tag);
        const role_body = std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{role_name}) catch return error.OutOfMemory;
        defer allocator.free(role_body);
        const resp = try sendRequest(self, allocator, .{
            .method = .POST,
            .url = roles_url,
            .bearer_token = bearer,
            .content_type = "application/json",
            .body = role_body,
        });
        // 201 = created, 409 = already exists (idempotent) — both OK.
        if (resp.status != 201 and resp.status != 409) {
            return mapStatus(resp.status, .provision_realm);
        }
    }
}

/// Apply extended realm configuration (token lifetimes, password policy, etc.)
fn applyRealmConfiguration(
    self: *Adapter,
    allocator: std.mem.Allocator,
    bearer: []const u8,
    realm_id: []const u8,
    input: provider_types.ProvisionRealmInput,
) (provider_errors.ProviderError || error{OutOfMemory})!void {
    // Build password policy string.
    const pw_policy = std.fmt.allocPrint(allocator, "length({d}) and upperCase(1) and digits(1)", .{input.min_password_length}) catch return error.OutOfMemory;
    defer allocator.free(pw_policy);

    // Update realm with full config.
    const update_body = try buildRealmUpdateBody(allocator, realm_id, input);
    defer allocator.free(update_body);
    const realm_url = keycloak_urls.realm(allocator, self.config, realm_id) catch return error.OutOfMemory;
    defer allocator.free(realm_url);

    const update_response = try sendRequest(self, allocator, .{
        .method = .PUT,
        .url = realm_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = update_body,
    });
    if (update_response.status != 204 and update_response.status != 200) {
        return mapStatus(update_response.status, .provision_realm);
    }
}

// --- OIDC-13: Protocol mapper ---

fn createProtocolMapper(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.CreateProtocolMapperInput) provider_errors.ProviderError!provider_types.CreateProtocolMapperResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const url = keycloak_urls.protocolMappersCollection(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = input.config_json,
    });

    if (response.status == 201 or response.status == 204) {
        return .{
            .mapper_id = allocator.dupe(u8, input.mapper_name) catch return error.OutOfMemory,
            .created = true,
        };
    }
    if (response.status == 409) {
        return .{
            .mapper_id = allocator.dupe(u8, input.mapper_name) catch return error.OutOfMemory,
            .created = false,
        };
    }
    return mapStatus(response.status, .provision_realm);
}

// --- OIDC-15: Realm lifecycle ---

fn toggleRealmKeycloak(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.ToggleRealmInput) provider_errors.ProviderError!provider_types.RealmLifecycleResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const body = std.json.Stringify.valueAlloc(allocator, .{
        .enabled = input.enabled,
    }, .{}) catch return error.OutOfMemory;
    defer allocator.free(body);

    const url = keycloak_urls.realm(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .PUT,
        .url = url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });

    if (response.status == 204 or response.status == 200) {
        return .{
            .realm_id = allocator.dupe(u8, input.realm_id) catch return error.OutOfMemory,
            .success = true,
        };
    }
    if (response.status == 404) return error.RealmNotFound;
    return mapStatus(response.status, .provision_realm);
}

fn deleteRealmKeycloak(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.DeleteRealmInput) provider_errors.ProviderError!void {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const url = keycloak_urls.realm(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .DELETE,
        .url = url,
        .bearer_token = bearer,
    });

    if (response.status == 204 or response.status == 200) return;
    if (response.status == 404) return error.RealmNotFound;
    return mapStatus(response.status, .provision_realm);
}

// --- ISS-0071: Realm-existence guard ---

fn checkRealmExistsKeycloak(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.CheckRealmExistsInput) provider_errors.ProviderError!bool {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const url = keycloak_urls.realm(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = url,
        .bearer_token = bearer,
    });

    if (response.status == 200) return true;
    if (response.status == 404) return false;
    return error.UpstreamProtocolError;
}

// --- F8: Tenant management ---

fn updateClientKeycloak(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.UpdateClientInput) provider_errors.ProviderError!provider_types.UpdateClientResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    // Step 1: Resolve the internal Keycloak client UUID by clientId.
    const lookup_url = keycloak_urls.clientsByName(allocator, self.config, input.realm_id, input.client_name) catch return error.OutOfMemory;
    defer allocator.free(lookup_url);

    const lookup_resp = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = lookup_url,
        .bearer_token = bearer,
    });
    if (lookup_resp.status != 200) return mapStatus(lookup_resp.status, .provision_client);

    const client_uuid = (try firstClientUuidFromSearch(allocator, lookup_resp.body)) orelse return error.ClientNotFound;
    defer allocator.free(client_uuid);

    // Step 2: Fetch the full client representation.
    const client_url = keycloak_urls.clientById(allocator, self.config, input.realm_id, client_uuid) catch return error.OutOfMemory;
    defer allocator.free(client_url);

    const get_resp = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = client_url,
        .bearer_token = bearer,
    });
    if (get_resp.status != 200) return mapStatus(get_resp.status, .provision_client);

    // Step 3: Merge redirect_uris into the representation.
    const merged_body = try mergeClientRedirectUris(allocator, get_resp.body, input.redirect_uris);
    defer allocator.free(merged_body);

    // Step 4: PUT the updated representation.
    const put_resp = try sendRequest(self, allocator, .{
        .method = .PUT,
        .url = client_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = merged_body,
    });
    if (put_resp.status != 204 and put_resp.status != 200) return mapStatus(put_resp.status, .provision_client);

    return .{
        .client_id = allocator.dupe(u8, input.client_name) catch return error.OutOfMemory,
    };
}

fn updateRealmFrontendUrlKeycloak(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.UpdateRealmFrontendUrlInput) provider_errors.ProviderError!void {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    // Step 1: Fetch current realm representation.
    const realm_url = keycloak_urls.realm(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(realm_url);

    const get_resp = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = realm_url,
        .bearer_token = bearer,
    });
    if (get_resp.status == 404) return error.RealmNotFound;
    if (get_resp.status != 200) return mapStatus(get_resp.status, .provision_realm);

    // Step 2: Merge frontendUrl into the realm representation.
    const merged_body = try mergeRealmFrontendUrl(allocator, get_resp.body, input.frontend_url);
    defer allocator.free(merged_body);

    // Step 3: PUT the updated representation.
    const put_resp = try sendRequest(self, allocator, .{
        .method = .PUT,
        .url = realm_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = merged_body,
    });
    if (put_resp.status != 204 and put_resp.status != 200) return mapStatus(put_resp.status, .provision_realm);
}

fn firstClientUuidFromSearch(allocator: std.mem.Allocator, body: []const u8) provider_errors.ProviderError!?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .array) return error.UpstreamProtocolError;
    if (parsed.value.array.items.len == 0) return null;
    const first = parsed.value.array.items[0];
    if (first != .object) return error.UpstreamProtocolError;
    const id = valueString(first.object, "id") orelse return error.UpstreamProtocolError;
    return allocator.dupe(u8, id) catch return error.OutOfMemory;
}

fn mergeClientRedirectUris(allocator: std.mem.Allocator, body: []const u8, redirect_uris: []const []const u8) provider_errors.ProviderError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.UpstreamProtocolError;

    // Build the merged object: copy all fields, override redirectUris.
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    var first_field = true;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (!first_field) try buf.append(allocator, ',');
        first_field = false;

        const key_json = std.fmt.allocPrint(allocator, "\"{s}\":", .{entry.key_ptr.*}) catch return error.OutOfMemory;
        defer allocator.free(key_json);
        try buf.appendSlice(allocator, key_json);

        if (std.mem.eql(u8, entry.key_ptr.*, "redirectUris")) {
            // Replaced by input redirect_uris.
            try buf.append(allocator, '[');
            for (redirect_uris, 0..) |uri, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try buf.append(allocator, '"');
                for (uri) |c| {
                    if (c == '"') try buf.appendSlice(allocator, "\\\"") else try buf.append(allocator, c);
                }
                try buf.append(allocator, '"');
            }
            try buf.append(allocator, ']');
        } else {
            // Copy the existing value as raw JSON.
            const val_json = try valueToJson(allocator, entry.value_ptr.*);
            defer allocator.free(val_json);
            try buf.appendSlice(allocator, val_json);
        }
    }
    // If redirectUris was not present in the original, append it.
    if (!parsed.value.object.contains("redirectUris")) {
        if (!first_field) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"redirectUris\":[");
        for (redirect_uris, 0..) |uri, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            for (uri) |c| {
                if (c == '"') try buf.appendSlice(allocator, "\\\"") else try buf.append(allocator, c);
            }
            try buf.append(allocator, '"');
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn mergeRealmFrontendUrl(allocator: std.mem.Allocator, body: []const u8, frontend_url: []const u8) provider_errors.ProviderError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.UpstreamProtocolError;

    // Build merged object: copy all fields, upsert attributes.frontendUrl.
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // Escape the frontend_url for JSON.
    var escaped_url = std.ArrayList(u8).empty;
    defer escaped_url.deinit(allocator);
    for (frontend_url) |c| {
        if (c == '"') try escaped_url.appendSlice(allocator, "\\\"") else try escaped_url.append(allocator, c);
    }

    try buf.append(allocator, '{');
    var first_field = true;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (!first_field) try buf.append(allocator, ',');
        first_field = false;

        const key_json = std.fmt.allocPrint(allocator, "\"{s}\":", .{entry.key_ptr.*}) catch return error.OutOfMemory;
        defer allocator.free(key_json);
        try buf.appendSlice(allocator, key_json);

        if (std.mem.eql(u8, entry.key_ptr.*, "attributes") and entry.value_ptr.* == .object) {
            // Merge frontendUrl into attributes.
            try buf.append(allocator, '{');
            var attr_first = true;
            var attr_it = entry.value_ptr.object.iterator();
            while (attr_it.next()) |attr_entry| {
                if (std.mem.eql(u8, attr_entry.key_ptr.*, "frontendUrl")) continue; // will be appended at end
                if (!attr_first) try buf.append(allocator, ',');
                attr_first = false;
                const attr_key = std.fmt.allocPrint(allocator, "\"{s}\":", .{attr_entry.key_ptr.*}) catch return error.OutOfMemory;
                defer allocator.free(attr_key);
                try buf.appendSlice(allocator, attr_key);
                const attr_val = try valueToJson(allocator, attr_entry.value_ptr.*);
                defer allocator.free(attr_val);
                try buf.appendSlice(allocator, attr_val);
            }
            if (!attr_first) try buf.append(allocator, ',');
            const frontend_entry = std.fmt.allocPrint(allocator, "\"frontendUrl\":\"{s}\"", .{escaped_url.items}) catch return error.OutOfMemory;
            defer allocator.free(frontend_entry);
            try buf.appendSlice(allocator, frontend_entry);
            try buf.append(allocator, '}');
        } else {
            const val_json = try valueToJson(allocator, entry.value_ptr.*);
            defer allocator.free(val_json);
            try buf.appendSlice(allocator, val_json);
        }
    }
    // If "attributes" was absent, add it.
    if (!parsed.value.object.contains("attributes")) {
        if (!first_field) try buf.append(allocator, ',');
        const attr_block = std.fmt.allocPrint(allocator, "\"attributes\":{{\"frontendUrl\":\"{s}\"}}", .{escaped_url.items}) catch return error.OutOfMemory;
        defer allocator.free(attr_block);
        try buf.appendSlice(allocator, attr_block);
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn valueToJson(allocator: std.mem.Allocator, value: std.json.Value) provider_errors.ProviderError![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    appendJsonValue(allocator, &buf, value) catch return error.OutOfMemory;
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendJsonValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try appendJsonValue(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, "\":");
                try appendJsonValue(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn provisionUser(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.ProvisionUserInput) provider_errors.ProviderError!provider_types.ProvisionUserResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    if (try findUser(self, allocator, bearer, input.external_realm, input.external_id, .external_id)) |existing_user_id| {
        return .{ .external_user_id = existing_user_id, .created = false };
    }
    if (try findUser(self, allocator, bearer, input.external_realm, input.preferred_username, .username)) |existing_user_id| {
        return .{ .external_user_id = existing_user_id, .created = false };
    }

    const body = try buildUserCreateBody(allocator, input);
    defer allocator.free(body);
    const url = keycloak_urls.usersCollection(allocator, self.config, input.external_realm) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });
    if (response.status != 201 and response.status != 204) return mapStatus(response.status, .provision_user);

    const location = response.header("Location") orelse return error.UpstreamProtocolError;
    const user_id = lastPathSegment(location) orelse return error.UpstreamProtocolError;
    return .{
        .external_user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
        .created = true,
    };
}

fn grantRoles(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.GrantRolesInput) provider_errors.ProviderError!provider_types.GrantRolesResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    if (input.roles.len == 0) return .{ .applied = 0 };

    const bearer = try ensureAdminToken(self, allocator);
    var unique_roles: std.ArrayList(KeycloakRoleRepresentation) = .empty;
    defer {
        for (unique_roles.items) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
        }
        unique_roles.deinit(allocator);
    }

    for (input.roles) |role| {
        const role_name = providerRoleName(role);
        var seen = false;
        for (unique_roles.items) |existing| {
            if (std.mem.eql(u8, existing.name, role_name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        const url = keycloak_urls.role(allocator, self.config, input.realm_id, role_name) catch return error.OutOfMemory;
        defer allocator.free(url);
        const response = try sendRequest(self, allocator, .{
            .method = .GET,
            .url = url,
            .bearer_token = bearer,
        });
        if (response.status != 200) return mapStatus(response.status, .grant_roles);
        const representation = try parseRoleRepresentation(allocator, response.body);
        errdefer {
            allocator.free(representation.id);
            allocator.free(representation.name);
        }
        unique_roles.append(allocator, representation) catch return error.OutOfMemory;
    }

    const body = try buildRoleMappingsBody(allocator, unique_roles.items);
    defer allocator.free(body);
    const mapping_url = keycloak_urls.userRoleMappings(allocator, self.config, input.realm_id, input.external_user_id) catch return error.OutOfMemory;
    defer allocator.free(mapping_url);

    const apply_response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = mapping_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });
    if (apply_response.status != 204) return mapStatus(apply_response.status, .grant_roles);

    return .{ .applied = unique_roles.items.len };
}

fn provisionClient(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.ProvisionClientInput) provider_errors.ProviderError!provider_types.ProvisionClientResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);

    const lookup_url = keycloak_urls.clientsByName(allocator, self.config, input.realm_id, input.client_name) catch return error.OutOfMemory;
    defer allocator.free(lookup_url);
    const lookup_response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = lookup_url,
        .bearer_token = bearer,
    });
    if (lookup_response.status != 200) return mapStatus(lookup_response.status, .provision_client);
    if (try hasClient(allocator, lookup_response.body, input.client_name)) {
        return .{
            .client_id = allocator.dupe(u8, input.client_name) catch return error.OutOfMemory,
            .created = false,
        };
    }

    const body = try buildClientCreateBody(allocator, input);
    defer allocator.free(body);
    const create_url = keycloak_urls.clientsCollection(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(create_url);
    const create_response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = create_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });
    if (create_response.status != 201 and create_response.status != 204) return mapStatus(create_response.status, .provision_client);

    return .{
        .client_id = allocator.dupe(u8, input.client_name) catch return error.OutOfMemory,
        .created = true,
    };
}

fn upsertFederation(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.UpsertFederationInput) provider_errors.ProviderError!provider_types.FederationResult {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);
    const instance_url = keycloak_urls.federationInstance(allocator, self.config, input.realm_id, input.provider_alias) catch return error.OutOfMemory;
    defer allocator.free(instance_url);
    const body = try buildFederationBody(allocator, input);
    defer allocator.free(body);

    const existing = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = instance_url,
        .bearer_token = bearer,
    });
    if (existing.status == 200) {
        const update_response = try sendRequest(self, allocator, .{
            .method = .PUT,
            .url = instance_url,
            .bearer_token = bearer,
            .content_type = "application/json",
            .body = body,
        });
        if (update_response.status != 204) return mapStatus(update_response.status, .upsert_federation);
        return .{
            .federation_id = allocator.dupe(u8, input.provider_alias) catch return error.OutOfMemory,
            .created = false,
        };
    }
    if (existing.status != 404) return mapStatus(existing.status, .upsert_federation);

    const collection_url = keycloak_urls.federationCollection(allocator, self.config, input.realm_id) catch return error.OutOfMemory;
    defer allocator.free(collection_url);
    const create_response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = collection_url,
        .bearer_token = bearer,
        .content_type = "application/json",
        .body = body,
    });
    if (create_response.status != 201 and create_response.status != 204) return mapStatus(create_response.status, .upsert_federation);

    return .{
        .federation_id = allocator.dupe(u8, input.provider_alias) catch return error.OutOfMemory,
        .created = true,
    };
}

fn deleteFederation(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.DeleteFederationInput) provider_errors.ProviderError!void {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);
    const url = keycloak_urls.federationInstance(allocator, self.config, input.realm_id, input.provider_alias) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .DELETE,
        .url = url,
        .bearer_token = bearer,
    });
    if (response.status == 404) return error.FederationNotFound;
    if (response.status != 204) return mapStatus(response.status, .delete_federation);
}

fn listAuditEvents(raw_ctx: *anyopaque, allocator: std.mem.Allocator, input: provider_types.ListAuditEventsInput) provider_errors.ProviderError!provider_types.AuditEventPage {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    const bearer = try ensureAdminToken(self, allocator);
    const first = parseCursor(input.cursor) catch return error.ClaimValidationFailed;
    const url = keycloak_urls.auditEvents(allocator, self.config, input.realm_id, first, input.page_size, input.from_timestamp_ms, input.to_timestamp_ms) catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = url,
        .bearer_token = bearer,
    });
    if (response.status != 200) return mapStatus(response.status, .list_audit_events);

    return try parseAuditEventPage(allocator, response.body, first, input.page_size);
}

const LookupMode = enum {
    external_id,
    username,
};

fn findUser(self: *Adapter, allocator: std.mem.Allocator, bearer: []const u8, realm_id: []const u8, lookup_value: []const u8, mode: LookupMode) provider_errors.ProviderError!?[]u8 {
    const url = switch (mode) {
        .external_id => keycloak_urls.usersByExternalId(allocator, self.config, realm_id, lookup_value),
        .username => keycloak_urls.usersByUsername(allocator, self.config, realm_id, lookup_value),
    } catch return error.OutOfMemory;
    defer allocator.free(url);

    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = url,
        .bearer_token = bearer,
    });
    if (response.status != 200) return mapStatus(response.status, .provision_user);
    return try firstUserIdFromSearch(allocator, response.body);
}

fn resolveDiscoveryDocument(raw_ctx: *anyopaque, allocator: std.mem.Allocator, discovery_url: []const u8) provider_errors.ProviderError!standards_verifier.DiscoveryDocument {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));

    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = discovery_url,
    });
    if (response.status == 404) return error.RealmNotFound;
    if (response.status != 200) return mapStatus(response.status, .verify_token);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    const obj = payloadlessObject(parsed.value);
    const issuer = valueString(obj, "issuer") orelse return error.UpstreamProtocolError;
    const jwks_uri = valueString(obj, "jwks_uri") orelse return error.UpstreamProtocolError;

    return .{
        .issuer = allocator.dupe(u8, issuer) catch return error.OutOfMemory,
        .jwks_uri = allocator.dupe(u8, jwks_uri) catch return error.OutOfMemory,
    };
}

fn resolveJwksKid(raw_ctx: *anyopaque, allocator: std.mem.Allocator, jwks_uri: []const u8, kid: []const u8) provider_errors.ProviderError!bool {
    const self: *Adapter = @ptrCast(@alignCast(raw_ctx));
    return jwksContainsKidCached(self, allocator, jwks_uri, kid);
}

fn fetchJwksBody(self: *Adapter, allocator: std.mem.Allocator, jwks_uri: []const u8) provider_errors.ProviderError![]u8 {
    const response = try sendRequest(self, allocator, .{
        .method = .GET,
        .url = jwks_uri,
    });
    if (response.status != 200) return mapStatus(response.status, .verify_token);
    return allocator.dupe(u8, response.body) catch return error.OutOfMemory;
}

fn jwksContainsKidCached(self: *Adapter, allocator: std.mem.Allocator, jwks_uri: []const u8, kid: []const u8) provider_errors.ProviderError!bool {
    const now = self.clock.nowUnixSeconds();
    if (self.jwks_cache.lookupKid(jwks_uri, kid, now)) |found| {
        if (found) return true;
        // Cache valid but kid not present — try one refresh if not rate-limited
        if (self.jwks_cache.isRateLimited(now)) return false;
        const body = try fetchJwksBody(self, allocator, jwks_uri);
        defer allocator.free(body);
        self.jwks_cache.store(jwks_uri, body, now) catch return error.UpstreamProtocolError;
        self.jwks_cache.markRefreshed(now);
        return self.jwks_cache.lookupKid(jwks_uri, kid, now) orelse false;
    } else {
        // No entry or stale — fetch and store
        const body = try fetchJwksBody(self, allocator, jwks_uri);
        defer allocator.free(body);
        self.jwks_cache.store(jwks_uri, body, now) catch return error.UpstreamProtocolError;
        self.jwks_cache.markRefreshed(now);
        return self.jwks_cache.lookupKid(jwks_uri, kid, now) orelse false;
    }
}

fn ensureAdminToken(self: *Adapter, allocator: std.mem.Allocator) provider_errors.ProviderError![]const u8 {
    const now = self.clock.nowUnixSeconds();
    if (self.cached_admin_token) |cache| {
        if (cache.expires_at > now + 30) return cache.access_token;
        self.allocator.free(cache.access_token);
        self.cached_admin_token = null;
    }

    const url = keycloak_urls.adminToken(allocator, self.config) catch return error.OutOfMemory;
    defer allocator.free(url);
    const body = try buildAdminTokenBody(allocator, self.config.admin_client_id, self.admin_client_secret);
    defer allocator.free(body);

    const response = try sendRequest(self, allocator, .{
        .method = .POST,
        .url = url,
        .content_type = "application/x-www-form-urlencoded",
        .body = body,
    });
    if (response.status != 200) return mapStatus(response.status, .admin_token);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    const obj = payloadlessObject(parsed.value);
    const access_token = valueString(obj, "access_token") orelse return error.UpstreamProtocolError;
    const expires_in = valueInteger(obj.get("expires_in") orelse return error.UpstreamProtocolError) orelse return error.UpstreamProtocolError;
    // Always allocate the cached token with self.allocator (the adapter's
    // long-lived allocator) so that self.allocator.free(cache.access_token)
    // is valid across multiple requests. Using the per-request arena here
    // causes a crash when the arena is freed at the end of the request while
    // the cached token is still referenced.
    const owned_token = self.allocator.dupe(u8, access_token) catch return error.OutOfMemory;
    self.cached_admin_token = .{
        .access_token = owned_token,
        .expires_at = now + expires_in,
    };
    return owned_token;
}

fn sendRequest(self: *Adapter, allocator: std.mem.Allocator, request: HttpRequest) provider_errors.ProviderError!HttpResponse {
    return self.transport.send(allocator, request) catch |err| return mapExternalError(err);
}

fn parseJwtSegment(allocator: std.mem.Allocator, raw_token: []const u8, segment_index: usize) provider_errors.ProviderError!std.json.Parsed(std.json.Value) {
    var start: usize = 0;
    var index: usize = 0;
    while (index < segment_index) : (index += 1) {
        const dot = std.mem.indexOfScalarPos(u8, raw_token, start, '.') orelse return error.InvalidToken;
        start = dot + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, raw_token, start, '.') orelse raw_token.len;
    const encoded = raw_token[start..end];
    if (encoded.len == 0) return error.InvalidToken;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.InvalidToken;
    const decoded = allocator.alloc(u8, decoded_len) catch return error.OutOfMemory;
    defer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidToken;

    return std.json.parseFromSlice(std.json.Value, allocator, decoded, .{ .allocate = .alloc_always }) catch return error.InvalidToken;
}

fn ensureAudience(payload: std.json.Value, expected_audience: []const u8) provider_errors.ProviderError!void {
    const obj = payloadlessObject(payload);
    const aud = obj.get("aud") orelse return error.TokenAudienceMismatch;
    switch (aud) {
        .string => |value| {
            if (!std.mem.eql(u8, value, expected_audience)) return error.TokenAudienceMismatch;
        },
        .array => |items| {
            for (items.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, expected_audience)) return;
            }
            return error.TokenAudienceMismatch;
        },
        else => return error.TokenAudienceMismatch,
    }
}

fn ensureTokenWindow(payload: std.json.Value, now_unix_seconds: i64) provider_errors.ProviderError!void {
    const obj = payloadlessObject(payload);
    if (obj.get("exp")) |exp_value| {
        const exp = valueInteger(exp_value) orelse return error.ClaimValidationFailed;
        if (exp < now_unix_seconds) return error.TokenExpired;
    }
    if (obj.get("nbf")) |nbf_value| {
        const nbf = valueInteger(nbf_value) orelse return error.ClaimValidationFailed;
        if (nbf > now_unix_seconds) return error.InvalidToken;
    }
}

fn extractRoles(allocator: std.mem.Allocator, payload: std.json.Value) provider_errors.ProviderError![]provider_types.ProviderRole {
    const obj = payloadlessObject(payload);
    var roles = std.ArrayList(provider_types.ProviderRole).empty;
    defer roles.deinit(allocator);

    if (obj.get("realm_access")) |realm_access| {
        if (realm_access == .object) {
            if (realm_access.object.get("roles")) |realm_roles| try appendRoleValues(allocator, &roles, realm_roles);
        }
    }
    if (roles.items.len == 0) {
        if (obj.get("roles")) |top_level_roles| try appendRoleValues(allocator, &roles, top_level_roles);
    }
    return roles.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendRoleValues(allocator: std.mem.Allocator, roles: *std.ArrayList(provider_types.ProviderRole), value: std.json.Value) provider_errors.ProviderError!void {
    if (value != .array) return error.ClaimValidationFailed;
    for (value.array.items) |item| {
        if (item != .string) continue;
        const mapped = mapRole(item.string) orelse continue;
        var seen = false;
        for (roles.items) |existing| {
            if (existing == mapped) {
                seen = true;
                break;
            }
        }
        if (!seen) roles.append(allocator, mapped) catch return error.OutOfMemory;
    }
}

fn extractTenantId(payload: std.json.Value) ?[36]u8 {
    const obj = payloadlessObject(payload);
    const claim = obj.get("tenant_id") orelse return null;
    if (claim != .string) return null;
    if (claim.string.len != 36) return null;
    var tenant_id: [36]u8 = undefined;
    @memcpy(&tenant_id, claim.string[0..36]);
    return tenant_id;
}

fn parseProviderUser(allocator: std.mem.Allocator, body: []const u8) provider_errors.ProviderError!provider_types.ProviderUser {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    const obj = payloadlessObject(parsed.value);
    const external_id = valueString(obj, "id") orelse return error.UpstreamProtocolError;
    const username = valueString(obj, "username") orelse return error.UpstreamProtocolError;
    const first_name = valueString(obj, "firstName");
    const last_name = valueString(obj, "lastName");
    const display_name_source = try joinDisplayName(allocator, first_name, last_name, username);
    defer allocator.free(display_name_source);

    return .{
        .external_id = allocator.dupe(u8, external_id) catch return error.OutOfMemory,
        .username = allocator.dupe(u8, username) catch return error.OutOfMemory,
        .display_name = allocator.dupe(u8, display_name_source) catch return error.OutOfMemory,
        .email = try dupeOptional(allocator, valueString(obj, "email")),
        .active = valueBool(obj.get("enabled")) orelse true,
    };
}

fn parseRoleRepresentation(allocator: std.mem.Allocator, body: []const u8) provider_errors.ProviderError!KeycloakRoleRepresentation {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    const obj = payloadlessObject(parsed.value);
    const id = valueString(obj, "id") orelse return error.UpstreamProtocolError;
    const name = valueString(obj, "name") orelse return error.UpstreamProtocolError;
    return .{
        .id = allocator.dupe(u8, id) catch return error.OutOfMemory,
        .name = allocator.dupe(u8, name) catch return error.OutOfMemory,
    };
}

fn firstUserIdFromSearch(allocator: std.mem.Allocator, body: []const u8) provider_errors.ProviderError!?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .array) return error.UpstreamProtocolError;
    if (parsed.value.array.items.len == 0) return null;
    const first = parsed.value.array.items[0];
    if (first != .object) return error.UpstreamProtocolError;
    const id = valueString(first.object, "id") orelse return error.UpstreamProtocolError;
    return allocator.dupe(u8, id) catch return error.OutOfMemory;
}

fn hasClient(allocator: std.mem.Allocator, body: []const u8, client_name: []const u8) provider_errors.ProviderError!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .array) return error.UpstreamProtocolError;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const existing_client_id = valueString(item.object, "clientId") orelse continue;
        if (std.mem.eql(u8, existing_client_id, client_name)) return true;
    }
    return false;
}

fn parseAuditEventPage(allocator: std.mem.Allocator, body: []const u8, first: usize, page_size: u16) provider_errors.ProviderError!provider_types.AuditEventPage {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
    defer parsed.deinit();
    if (parsed.value != .array) return error.UpstreamProtocolError;

    const events = allocator.alloc(provider_types.AuditEvent, parsed.value.array.items.len) catch return error.OutOfMemory;
    errdefer {
        for (events[0..parsed.value.array.items.len]) |event| event.deinit(allocator);
        allocator.free(events);
    }

    for (parsed.value.array.items, 0..) |item, idx| {
        if (item != .object) return error.UpstreamProtocolError;
        const event_id_text = valueString(item.object, "id") orelse synthesizeAuditEventId(allocator, item.object) catch return error.OutOfMemory;
        defer if (!item.object.contains("id")) allocator.free(event_id_text);
        const operation_type = valueString(item.object, "operationType") orelse "unknown";
        const resource_type = valueString(item.object, "resourceType") orelse "resource";
        const event_type = std.fmt.allocPrint(allocator, "{s}:{s}", .{ operation_type, resource_type }) catch return error.OutOfMemory;
        errdefer allocator.free(event_type);

        const actor_id = if (item.object.get("authDetails")) |auth_details|
            try parseAuditActorId(allocator, auth_details)
        else
            null;
        errdefer if (actor_id) |value| allocator.free(value);

        const timestamp_ms = valueInteger(item.object.get("time") orelse return error.UpstreamProtocolError) orelse return error.UpstreamProtocolError;
        events[idx] = .{
            .event_id = allocator.dupe(u8, event_id_text) catch return error.OutOfMemory,
            .event_type = event_type,
            .actor_id = actor_id,
            .timestamp_ms = timestamp_ms,
        };
    }

    const next_cursor = if (parsed.value.array.items.len == page_size)
        std.fmt.allocPrint(allocator, "{d}", .{first + parsed.value.array.items.len}) catch return error.OutOfMemory
    else
        null;

    return .{
        .events = events,
        .next_cursor = next_cursor,
    };
}

fn parseAuditActorId(allocator: std.mem.Allocator, auth_details: std.json.Value) provider_errors.ProviderError!?[]u8 {
    if (auth_details != .object) return null;
    const user_id = valueString(auth_details.object, "userId");
    if (user_id) |value| return allocator.dupe(u8, value) catch return error.OutOfMemory;
    const client_id = valueString(auth_details.object, "clientId");
    if (client_id) |value| return allocator.dupe(u8, value) catch return error.OutOfMemory;
    return null;
}

fn synthesizeAuditEventId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const operation_type = valueString(obj, "operationType") orelse "event";
    const resource_path = valueString(obj, "resourcePath") orelse "resource";
    const timestamp = valueInteger(obj.get("time") orelse return error.OutOfMemory) orelse 0;
    return std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ operation_type, resource_path, timestamp });
}

fn buildAdminTokenBody(allocator: std.mem.Allocator, client_id: []const u8, client_secret: []const u8) provider_errors.ProviderError![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "grant_type=client_credentials&client_id={s}&client_secret={s}",
        .{ client_id, client_secret },
    ) catch return error.OutOfMemory;
}

fn buildRealmCreateBody(allocator: std.mem.Allocator, realm_id: []const u8, display_name: []const u8) provider_errors.ProviderError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .realm = realm_id,
        .displayName = display_name,
        .enabled = true,
    }, .{}) catch return error.OutOfMemory;
}

/// Extended realm creation body with OIDC-14 configuration.
fn buildRealmCreateBodyExtended(allocator: std.mem.Allocator, realm_id: []const u8, input: provider_types.ProvisionRealmInput) provider_errors.ProviderError![]u8 {
    const pw_policy = std.fmt.allocPrint(allocator, "length({d}) and upperCase(1) and digits(1)", .{input.min_password_length}) catch return error.OutOfMemory;
    defer allocator.free(pw_policy);

    return std.json.Stringify.valueAlloc(allocator, .{
        .realm = realm_id,
        .displayName = input.display_name,
        .enabled = true,
        .accessTokenLifespan = input.default_token_lifetime_seconds,
        .accessCodeLifespan = input.default_id_token_lifetime_seconds,
        .ssoSessionMaxLifespan = input.session_max_lifetime_seconds,
        .ssoSessionIdleTimeout = input.default_refresh_token_lifetime_seconds,
        .passwordPolicy = pw_policy,
    }, .{}) catch return error.OutOfMemory;
}

/// Build a PUT body for updating realm configuration.
fn buildRealmUpdateBody(allocator: std.mem.Allocator, realm_id: []const u8, input: provider_types.ProvisionRealmInput) provider_errors.ProviderError![]u8 {
    const pw_policy = std.fmt.allocPrint(allocator, "length({d}) and upperCase(1) and digits(1)", .{input.min_password_length}) catch return error.OutOfMemory;
    defer allocator.free(pw_policy);

    return std.json.Stringify.valueAlloc(allocator, .{
        .realm = realm_id,
        .displayName = input.display_name,
        .enabled = true,
        .accessTokenLifespan = input.default_token_lifetime_seconds,
        .accessCodeLifespan = input.default_id_token_lifetime_seconds,
        .ssoSessionMaxLifespan = input.session_max_lifetime_seconds,
        .ssoSessionIdleTimeout = input.default_refresh_token_lifetime_seconds,
        .passwordPolicy = pw_policy,
    }, .{}) catch return error.OutOfMemory;
}

/// Build the JSON body for creating a tenant_id hardcoded-claim protocol mapper.
fn buildTenantIdMapperBodySimple(allocator: std.mem.Allocator, tenant_id: []const u8) provider_errors.ProviderError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .name = "tenant-id-mapper",
        .protocol = "openid-connect",
        .protocolMapper = "oidc-hardcoded-claim-mapper",
        .config = .{
            .claimName = "tenant_id",
            .claimValue = tenant_id,
            .jsonTypeLabel = "String",
            .accessTokenClaim = "true",
            .idTokenClaim = "true",
            .userinfoTokenClaim = "true",
        },
    }, .{}) catch return error.OutOfMemory;
}

fn buildUserCreateBody(allocator: std.mem.Allocator, input: provider_types.ProvisionUserInput) provider_errors.ProviderError![]u8 {
    const names = splitDisplayName(input.display_name, input.preferred_username);
    const external_ids = [_][]const u8{input.external_id};
    return std.json.Stringify.valueAlloc(allocator, .{
        .username = input.preferred_username,
        .email = input.email,
        .enabled = true,
        .firstName = names.first_name,
        .lastName = names.last_name,
        .attributes = .{
            .external_id = external_ids[0..],
        },
    }, .{}) catch return error.OutOfMemory;
}

fn buildRoleMappingsBody(allocator: std.mem.Allocator, roles: []const KeycloakRoleRepresentation) provider_errors.ProviderError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, roles, .{}) catch return error.OutOfMemory;
}

/// Platform callback URLs added to every provisioned Keycloak client (ISS-UAT-V6-003).
/// These are additive to the user-specified redirect_uris from the onboarding form.
const PLATFORM_REDIRECT_URIS = [_][]const u8{
    "http://127.0.0.1:8080/*",
    "http://127.0.0.1:4173/*",
    "http://localhost:8080/*",
    "http://localhost:4173/*",
};

fn buildClientCreateBody(allocator: std.mem.Allocator, input: provider_types.ProvisionClientInput) provider_errors.ProviderError![]u8 {
    // Merge user-specified redirect_uris with platform callback URLs.
    const platform: []const []const u8 = &PLATFORM_REDIRECT_URIS;
    const merged = allocator.alloc([]const u8, input.redirect_uris.len + platform.len) catch return error.OutOfMemory;
    defer allocator.free(merged);
    @memcpy(merged[0..input.redirect_uris.len], input.redirect_uris);
    @memcpy(merged[input.redirect_uris.len..], platform);

    return std.json.Stringify.valueAlloc(allocator, .{
        .clientId = input.client_name,
        .redirectUris = merged,
        .serviceAccountsEnabled = input.service_account_enabled,
        .protocol = "openid-connect",
    }, .{}) catch return error.OutOfMemory;
}

fn buildFederationBody(allocator: std.mem.Allocator, input: provider_types.UpsertFederationInput) provider_errors.ProviderError![]u8 {
    const config_value = try parseEmbeddedJson(allocator, input.config_json);
    defer config_value.deinit();
    const mapper_value = try parseEmbeddedJson(allocator, input.claim_mapping_json);
    defer mapper_value.deinit();

    return std.json.Stringify.valueAlloc(allocator, .{
        .alias = input.provider_alias,
        .providerId = input.provider_type,
        .config = config_value.value,
        .claimMappings = mapper_value.value,
    }, .{}) catch return error.OutOfMemory;
}

fn parseEmbeddedJson(allocator: std.mem.Allocator, raw: []const u8) provider_errors.ProviderError!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch return error.ClaimValidationFailed;
}

fn parseCursor(cursor: ?[]const u8) error{InvalidCursor}!usize {
    const raw = cursor orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch error.InvalidCursor;
}

fn splitDisplayName(display_name: []const u8, fallback_username: []const u8) struct { first_name: []const u8, last_name: []const u8 } {
    const trimmed = std.mem.trim(u8, display_name, " ");
    if (trimmed.len == 0) return .{ .first_name = fallback_username, .last_name = "" };
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
        return .{
            .first_name = trimmed[0..space_idx],
            .last_name = trimLeftSpaces(trimmed[space_idx + 1 ..]),
        };
    }
    return .{ .first_name = trimmed, .last_name = "" };
}

fn joinDisplayName(allocator: std.mem.Allocator, first_name: ?[]const u8, last_name: ?[]const u8, fallback_username: []const u8) ![]u8 {
    const first = if (first_name) |value| std.mem.trim(u8, value, " ") else "";
    const last = if (last_name) |value| std.mem.trim(u8, value, " ") else "";
    if (first.len == 0 and last.len == 0) return allocator.dupe(u8, fallback_username);
    if (first.len == 0) return allocator.dupe(u8, last);
    if (last.len == 0) return allocator.dupe(u8, first);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ first, last });
}

fn mapRole(raw_role: []const u8) ?provider_types.ProviderRole {
    if (std.ascii.eqlIgnoreCase(raw_role, "PLATFORM_ADMIN")) return .PLATFORM_ADMIN;
    if (std.ascii.eqlIgnoreCase(raw_role, "PROCESS_DESIGNER")) return .PROCESS_DESIGNER;
    if (std.ascii.eqlIgnoreCase(raw_role, "PROCESS_OPERATOR")) return .PROCESS_OPERATOR;
    if (std.ascii.eqlIgnoreCase(raw_role, "TASK_WORKER")) return .TASK_WORKER;
    if (std.ascii.eqlIgnoreCase(raw_role, "VIEWER")) return .VIEWER;
    if (std.ascii.eqlIgnoreCase(raw_role, "AGENT_RUNNER")) return .AGENT_RUNNER;
    return null;
}

fn providerRoleName(role: provider_types.ProviderRole) []const u8 {
    return @tagName(role);
}

fn realmFromIssuer(issuer: []const u8) ?[]const u8 {
    const marker = "/realms/";
    const idx = std.mem.lastIndexOf(u8, issuer, marker) orelse return null;
    const realm = issuer[idx + marker.len ..];
    if (realm.len == 0) return null;
    return realm;
}

fn lastPathSegment(url: []const u8) ?[]const u8 {
    const trimmed = trimRightSlashes(url);
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    if (idx + 1 >= trimmed.len) return null;
    return trimmed[idx + 1 ..];
}

fn trimLeftSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    while (start < input.len and input[start] == ' ') : (start += 1) {}
    return input[start..];
}

fn trimRightSlashes(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '/') : (end -= 1) {}
    return input[0..end];
}

fn payloadlessObject(value: std.json.Value) std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => unreachable,
    };
}

fn valueString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn valueBool(value: ?std.json.Value) ?bool {
    const inner = value orelse return null;
    return switch (inner) {
        .bool => |flag| flag,
        else => null,
    };
}

fn valueInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn dupeOptional(allocator: std.mem.Allocator, input: ?[]const u8) provider_errors.ProviderError!?[]u8 {
    const value = input orelse return null;
    return allocator.dupe(u8, value) catch return error.OutOfMemory;
}

const StatusContext = enum {
    admin_token,
    verify_token,
    lookup_user,
    provision_realm,
    provision_user,
    grant_roles,
    provision_client,
    upsert_federation,
    delete_federation,
    list_audit_events,
};

fn mapStatus(status: u16, context: StatusContext) provider_errors.ProviderError {
    return switch (status) {
        401 => error.UnauthorizedAdminCall,
        403 => error.ForbiddenAdminCall,
        404 => switch (context) {
            .lookup_user => error.UserNotFound,
            .provision_realm => error.RealmNotFound,
            .provision_client => error.ClientNotFound,
            .upsert_federation, .delete_federation => error.FederationNotFound,
            else => error.RealmNotFound,
        },
        409 => error.Conflict,
        429 => error.RateLimited,
        500...599 => error.UpstreamUnavailable,
        else => error.UpstreamProtocolError,
    };
}

fn mapExternalError(err: anyerror) provider_errors.ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UpstreamUnavailable,
    };
}

fn deriveDiscoveryUrlFromIssuer(allocator: std.mem.Allocator, issuer: []const u8) provider_errors.ProviderError![]u8 {
    const trimmed = trimRightSlashes(issuer);
    return std.fmt.allocPrint(allocator, "{s}/.well-known/openid-configuration", .{trimmed}) catch return error.OutOfMemory;
}
