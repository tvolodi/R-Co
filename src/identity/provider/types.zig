const std = @import("std");

pub const ProviderRole = enum {
    PLATFORM_ADMIN,
    PROCESS_DESIGNER,
    PROCESS_OPERATOR,
    TASK_WORKER,
    VIEWER,
    AGENT_RUNNER,
};

pub const AuthTokenKind = enum {
    local_api_token,
    oidc_bearer,
    bootstrap_token,
};

pub const TenantSource = enum {
    provider_claim,
    fallback_default,
};

pub const VerifyTokenInput = struct {
    raw_token: []const u8,
    expected_audience: []const u8,
    expected_issuer: ?[]const u8,
    now_unix_seconds: i64,
};

pub const VerifiedPrincipal = struct {
    provider_subject: []const u8,
    username: []const u8,
    display_name: []const u8,
    email: ?[]const u8,
    tenant_id: ?[36]u8,
    roles: []ProviderRole,
    external_realm: ?[]const u8,
    token_id_hint: ?[]const u8,

    pub fn deinit(self: VerifiedPrincipal, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_subject);
        allocator.free(self.username);
        allocator.free(self.display_name);
        if (self.email) |v| allocator.free(v);
        allocator.free(self.roles);
        if (self.external_realm) |v| allocator.free(v);
        if (self.token_id_hint) |v| allocator.free(v);
    }
};

pub const LookupUserInput = struct {
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
};

pub const ProviderUser = struct {
    external_id: []const u8,
    username: []const u8,
    display_name: []const u8,
    email: ?[]const u8,
    active: bool,

    pub fn deinit(self: ProviderUser, allocator: std.mem.Allocator) void {
        allocator.free(self.external_id);
        allocator.free(self.username);
        allocator.free(self.display_name);
        if (self.email) |v| allocator.free(v);
    }
};

pub const ProvisionRealmInput = struct {
    tenant_id: []const u8,
    tenant_slug: []const u8,
    display_name: []const u8,
    desired_realm_id: ?[]const u8,
};

pub const ProvisionRealmResult = struct {
    realm_id: []const u8,
    created: bool,

    pub fn deinit(self: ProvisionRealmResult, allocator: std.mem.Allocator) void {
        allocator.free(self.realm_id);
    }
};

pub const ProvisionUserInput = struct {
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
    preferred_username: []const u8,
    display_name: []const u8,
    email: ?[]const u8,
    initial_roles: []const ProviderRole,
};

pub const ProvisionUserResult = struct {
    external_user_id: []const u8,
    created: bool,

    pub fn deinit(self: ProvisionUserResult, allocator: std.mem.Allocator) void {
        allocator.free(self.external_user_id);
    }
};

pub const GrantRolesInput = struct {
    realm_id: []const u8,
    external_user_id: []const u8,
    roles: []const ProviderRole,
};

pub const GrantRolesResult = struct {
    applied: usize,
};

pub const ProvisionClientInput = struct {
    realm_id: []const u8,
    client_name: []const u8,
    redirect_uris: []const []const u8,
    service_account_enabled: bool,
};

pub const ProvisionClientResult = struct {
    client_id: []const u8,
    created: bool,

    pub fn deinit(self: ProvisionClientResult, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
    }
};

pub const UpsertFederationInput = struct {
    realm_id: []const u8,
    provider_alias: []const u8,
    provider_type: []const u8,
    config_json: []const u8,
    claim_mapping_json: []const u8,
};

pub const DeleteFederationInput = struct {
    realm_id: []const u8,
    provider_alias: []const u8,
};

pub const FederationResult = struct {
    federation_id: []const u8,
    created: bool,

    pub fn deinit(self: FederationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.federation_id);
    }
};

pub const ListAuditEventsInput = struct {
    realm_id: []const u8,
    from_timestamp_ms: i64,
    to_timestamp_ms: i64,
    cursor: ?[]const u8,
    page_size: u16,
};

pub const AuditEvent = struct {
    event_id: []const u8,
    event_type: []const u8,
    actor_id: ?[]const u8,
    timestamp_ms: i64,

    pub fn deinit(self: AuditEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_id);
        allocator.free(self.event_type);
        if (self.actor_id) |v| allocator.free(v);
    }
};

pub const AuditEventPage = struct {
    events: []AuditEvent,
    next_cursor: ?[]const u8,

    pub fn deinit(self: AuditEventPage, allocator: std.mem.Allocator) void {
        for (self.events) |event| event.deinit(allocator);
        allocator.free(self.events);
        if (self.next_cursor) |v| allocator.free(v);
    }
};