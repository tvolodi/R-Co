const std = @import("std");
const builtin = @import("builtin");
const auth = @import("../api/middleware/auth.zig");
const pagination = @import("../api/pagination.zig");
const registry_mod = @import("registry.zig");
const identity_provider = @import("identity_provider");
const provider_manager_mod = identity_provider.manager;
const provider_types = identity_provider.types;
const provider_errors = identity_provider.errors;

const reserved_username_prefix = "agent:";

pub const CreateUserInput = struct {
    tenant_id: ?[]const u8,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: registry_mod.UserStatus,
    caller_supplied_user_id: bool,
    caller_supplied_created_at: bool,
};

pub const UpdateUserStatusInput = struct {
    user_id: []const u8,
    status: registry_mod.UserStatus,
};

pub const ResolveExternalUserInput = struct {
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
};

pub const ProvisionExternalUserInput = struct {
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
    preferred_username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: registry_mod.UserStatus,
};

pub const ProvisionExternalUserResult = struct {
    user: registry_mod.User,
    created: bool,
};

pub const OidcMode = enum {
    disabled,
    enabled,
};

pub const CreateTenantInput = struct {
    tenant_id: ?[]const u8,
    slug: []const u8,
    display_name: []const u8,
    idp_realm_id: ?[]const u8,
    oidc_mode: OidcMode,
};

pub const CreateGroupInput = struct {
    name: []const u8,
};

pub const AddGroupMemberInput = struct {
    group_id: []const u8,
    user_id: []const u8,
};

pub const GroupMemberResult = struct {
    member: registry_mod.GroupMember,
    created: bool,
};

pub const RemoveGroupMemberInput = struct {
    group_id: []const u8,
    user_id: []const u8,
};

pub const ListGroupMembersParams = struct {
    cursor: ?[]const u8,
    page_size: u16,
};

pub const GroupMemberPage = struct {
    items: []registry_mod.User,
    next_cursor: ?[]const u8,
    count: usize,

    pub fn deinit(self: GroupMemberPage, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        if (self.next_cursor) |c| allocator.free(c);
    }
};

pub const TokenStatus = enum {
    ACTIVE,
    REVOKED,
    EXPIRED,

    pub fn asString(self: TokenStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .REVOKED => "REVOKED",
            .EXPIRED => "EXPIRED",
        };
    }
};

pub const ApiToken = struct {
    token_id: []const u8,
    user_id: []const u8,
    roles: []auth.Role,
    expires_at: ?[]const u8,
    revoked_at: ?[]const u8,
    created_at: []const u8,
    last_used_at: ?[]const u8,
    status: TokenStatus,

    pub fn deinit(self: ApiToken, allocator: std.mem.Allocator) void {
        allocator.free(self.token_id);
        allocator.free(self.user_id);
        allocator.free(self.roles);
        if (self.expires_at) |v| allocator.free(v);
        if (self.revoked_at) |v| allocator.free(v);
        allocator.free(self.created_at);
        if (self.last_used_at) |v| allocator.free(v);
    }
};

pub const IssuedToken = struct {
    token_id: []const u8,
    token_value: []const u8,
    user_id: []const u8,
    roles: []auth.Role,
    expires_at: ?[]const u8,
    created_at: []const u8,

    pub fn deinit(self: IssuedToken, allocator: std.mem.Allocator) void {
        allocator.free(self.token_id);
        allocator.free(self.token_value);
        allocator.free(self.user_id);
        allocator.free(self.roles);
        if (self.expires_at) |v| allocator.free(v);
        allocator.free(self.created_at);
    }
};

pub const CreateTokenInput = struct {
    user_id: []const u8,
    roles: []const auth.Role,
    expires_at: ?[]const u8,
};

pub const TokenListPage = struct {
    items: []ApiToken,

    pub fn deinit(self: TokenListPage, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GroupError = error{
    Forbidden,
    CrossTenantAccessDenied,
    ValidationFailed,
    DuplicateGroupName,
    GroupNotFound,
    UserNotFound,
    InvalidCursor,
    CursorExpired,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const TokenError = error{
    Forbidden,
    UserNotFound,
    InvalidRoleSet,
    ExpiresAtInPast,
    TokenNotFound,
    ValidationFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const IdentityError = error{
    DuplicateUsername,
    DuplicateTenantSlug,
    DuplicateRealmBinding,
    ExternalIdentityCollision,
    InvalidEmail,
    MissingTenantContext,
    MissingExternalRealm,
    MissingExternalId,
    MissingRealmBinding,
    DefaultTenantRealmMismatch,
    RealmOwnershipMismatch,
    TenantNotFound,
    CallerProvidedUserId,
    CallerProvidedCreatedAt,
    ReservedUsernameRequiresPlatformAdmin,
    ReservedUsernameInvalidFormat,
    Forbidden,
    NotFound,
    ValidationFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const ProviderIntegrationError = provider_errors.ProviderError || IdentityError;

pub const Service = struct {
    registry: *registry_mod.Registry,

    pub fn init(registry: *registry_mod.Registry) Service {
        return .{ .registry = registry };
    }

    pub fn verifyExternalToken(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        raw_token: []const u8,
    ) ProviderIntegrationError!provider_types.VerifiedPrincipal {
        return manager.verifyBearerToken(allocator, raw_token);
    }

    pub fn lookupExternalUser(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.LookupUserInput,
    ) ProviderIntegrationError!?provider_types.ProviderUser {
        return manager.lookupUser(allocator, input);
    }

    pub fn provisionTenantRealm(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.ProvisionRealmInput,
    ) ProviderIntegrationError!provider_types.ProvisionRealmResult {
        return manager.provisionRealm(allocator, input);
    }

    pub fn provisionProviderUser(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.ProvisionUserInput,
    ) ProviderIntegrationError!provider_types.ProvisionUserResult {
        return manager.provisionUser(allocator, input);
    }

    pub fn grantProviderRoles(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.GrantRolesInput,
    ) ProviderIntegrationError!provider_types.GrantRolesResult {
        return manager.grantRoles(allocator, input);
    }

    pub fn provisionProviderClient(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.ProvisionClientInput,
    ) ProviderIntegrationError!provider_types.ProvisionClientResult {
        return manager.provisionClient(allocator, input);
    }

    pub fn upsertFederationProvider(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.UpsertFederationInput,
    ) ProviderIntegrationError!provider_types.FederationResult {
        return manager.upsertFederation(allocator, input);
    }

    pub fn deleteFederationProvider(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.DeleteFederationInput,
    ) ProviderIntegrationError!void {
        return manager.deleteFederation(allocator, input);
    }

    pub fn listProviderAuditEvents(
        _: *Service,
        allocator: std.mem.Allocator,
        manager: provider_manager_mod.Manager,
        input: provider_types.ListAuditEventsInput,
    ) ProviderIntegrationError!provider_types.AuditEventPage {
        return manager.listAuditEvents(allocator, input);
    }

    pub fn resolveTenantRealmBinding(input: CreateTenantInput) IdentityError!?[]const u8 {
        const effective_tenant_id = input.tenant_id;
        const is_default_tenant = if (effective_tenant_id) |tenant_id|
            std.mem.eql(u8, tenant_id, auth.DEFAULT_TENANT_ID)
        else
            false;

        const normalized_realm = normalizeOptionalText(input.idp_realm_id);

        if (input.oidc_mode == .enabled) {
            if (is_default_tenant) {
                if (normalized_realm) |realm| {
                    if (!std.mem.eql(u8, realm, "bpm-default")) return error.DefaultTenantRealmMismatch;
                }
            } else if (normalized_realm == null) {
                return error.MissingRealmBinding;
            }
        }

        return if (is_default_tenant)
            "bpm-default"
        else if (normalized_realm) |realm|
            realm
        else
            null;
    }

    pub fn createTenant(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: CreateTenantInput,
    ) IdentityError!registry_mod.Tenant {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.slug.len == 0 or input.display_name.len == 0) return error.ValidationFailed;

        const realm_to_store = try resolveTenantRealmBinding(input);

        return self.registry.createTenant(allocator, .{
            .tenant_id = input.tenant_id,
            .slug = input.slug,
            .display_name = input.display_name,
            .status = .ACTIVE,
            .idp_realm_id = realm_to_store,
        }) catch |err| switch (err) {
            registry_mod.RegistryError.DuplicateTenantSlug => error.DuplicateTenantSlug,
            registry_mod.RegistryError.DuplicateRealmBinding => error.DuplicateRealmBinding,
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
    }

    pub fn createUser(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: CreateUserInput,
    ) IdentityError!registry_mod.User {
        try validateReservedUsernamePolicy(actor, input.username);
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.caller_supplied_user_id) return error.CallerProvidedUserId;
        if (input.caller_supplied_created_at) return error.CallerProvidedCreatedAt;
        if (input.username.len == 0 or input.display_name.len == 0) return error.ValidationFailed;
        if (!isValidEmail(input.email)) return error.InvalidEmail;
        const effective_tenant_id = input.tenant_id orelse actor.tenant_id[0..];

        return self.registry.createUser(allocator, effective_tenant_id, .{
            .username = input.username,
            .display_name = input.display_name,
            .email = input.email,
            .status = input.status,
        }) catch |err| switch (err) {
            registry_mod.RegistryError.DuplicateUsername => error.DuplicateUsername,
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            registry_mod.RegistryError.NotFound => error.NotFound,
            else => error.PersistenceFailed,
        };
    }

    pub fn updateUserStatus(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: UpdateUserStatusInput,
    ) IdentityError!registry_mod.User {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.user_id.len == 0) return error.ValidationFailed;

        return self.registry.updateUserStatus(allocator, actor.tenant_id[0..], input.user_id, input.status) catch |err| switch (err) {
            registry_mod.RegistryError.NotFound => error.NotFound,
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            registry_mod.RegistryError.DuplicateUsername => error.DuplicateUsername,
            else => error.PersistenceFailed,
        };
    }

    pub fn getUserStatusById(
        self: *Service,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        user_id: []const u8,
    ) IdentityError!?registry_mod.UserStatus {
        return self.registry.getUserStatusById(allocator, tenant_id, user_id) catch |err| switch (err) {
            registry_mod.RegistryError.NotFound => error.NotFound,
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            registry_mod.RegistryError.DuplicateUsername => error.DuplicateUsername,
            else => error.PersistenceFailed,
        };
    }

    pub fn resolveUserByExternalIdentity(
        self: *Service,
        allocator: std.mem.Allocator,
        input: ResolveExternalUserInput,
    ) IdentityError!?registry_mod.User {
        if (input.tenant_id.len == 0) return error.MissingTenantContext;
        if (input.external_realm.len == 0) return error.MissingExternalRealm;
        if (input.external_id.len == 0) return error.MissingExternalId;

        try self.assertRealmOwnedByTenant(allocator, input.tenant_id, input.external_realm);

        return self.registry.selectUserByExternalIdentity(
            allocator,
            input.tenant_id,
            input.external_realm,
            input.external_id,
        ) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
    }

    pub fn createOrGetJitOidcUser(
        self: *Service,
        allocator: std.mem.Allocator,
        input: ProvisionExternalUserInput,
    ) IdentityError!ProvisionExternalUserResult {
        try validateReservedUsernameForNonAdmin(input.preferred_username);
        if (input.tenant_id.len == 0) return error.MissingTenantContext;
        if (input.external_realm.len == 0) return error.MissingExternalRealm;
        if (input.external_id.len == 0) return error.MissingExternalId;
        if (input.preferred_username.len == 0 or input.display_name.len == 0) return error.ValidationFailed;
        if (!isValidEmail(input.email)) return error.InvalidEmail;

        try self.assertRealmOwnedByTenant(allocator, input.tenant_id, input.external_realm);

        const result = self.registry.createOrGetJitOidcUser(allocator, input.tenant_id, .{
            .username = input.preferred_username,
            .display_name = input.display_name,
            .email = input.email,
            .status = input.status,
            .external_realm = input.external_realm,
            .external_id = input.external_id,
        }) catch |err| switch (err) {
            registry_mod.RegistryError.DuplicateUsername => return error.DuplicateUsername,
            registry_mod.RegistryError.ExternalIdentityCollision => return error.ExternalIdentityCollision,
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };

        return .{ .user = result.user, .created = result.created };
    }

    pub fn createGroup(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: CreateGroupInput,
    ) GroupError!registry_mod.Group {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.name.len == 0) return error.ValidationFailed;

        return self.registry.createGroup(allocator, actor.tenant_id[0..], input.name) catch |err| switch (err) {
            registry_mod.RegistryError.DuplicateGroupName => error.DuplicateGroupName,
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
    }

    pub fn addGroupMember(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: AddGroupMemberInput,
    ) GroupError!GroupMemberResult {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.group_id.len == 0 or input.user_id.len == 0) return error.ValidationFailed;

        const tenant_id = actor.tenant_id[0..];

        const group_exists = self.registry.groupExists(allocator, tenant_id, input.group_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            else => return error.PersistenceFailed,
        };
        if (!group_exists) {
            return error.GroupNotFound;
        }

        const user_status = self.registry.getUserStatusById(allocator, tenant_id, input.user_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            registry_mod.RegistryError.NotFound => return error.UserNotFound,
            else => return error.PersistenceFailed,
        };
        if (user_status == null) {
            return error.UserNotFound;
        }

        const result = self.registry.addGroupMember(allocator, tenant_id, input.group_id, input.user_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };

        return .{ .member = result.member, .created = result.created };
    }

    pub fn removeGroupMember(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: RemoveGroupMemberInput,
    ) GroupError!void {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.group_id.len == 0 or input.user_id.len == 0) return error.ValidationFailed;

        const tenant_id = actor.tenant_id[0..];

        const group_exists = self.registry.groupExists(allocator, tenant_id, input.group_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            else => return error.PersistenceFailed,
        };
        if (!group_exists) {
            return error.GroupNotFound;
        }

        return self.registry.removeGroupMember(allocator, tenant_id, input.group_id, input.user_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            else => error.PersistenceFailed,
        };
    }

    pub fn listGroupMembers(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        group_id: []const u8,
        params: ListGroupMembersParams,
    ) GroupError!GroupMemberPage {
        if (group_id.len == 0) return error.ValidationFailed;
        const tenant_id = actor.tenant_id[0..];

        const group_exists = self.registry.groupExists(allocator, tenant_id, group_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            else => return error.PersistenceFailed,
        };
        if (!group_exists) {
            return error.GroupNotFound;
        }

        const page_size = pagination.validatePageSize(params.page_size) catch return error.ValidationFailed;

        var cursor_added_at_us: ?i64 = null;
        var cursor_user_id: ?[]u8 = null;
        if (params.cursor) |cursor_str| {
            const cursor = pagination.decodeCursor(allocator, cursor_str, "G:", 2, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
                error.InvalidBase64 => return error.InvalidCursor,
                error.WrongEndpoint => return error.InvalidCursor,
                error.Expired => return error.CursorExpired,
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer cursor.deinit();

            const after_prefix = cursor.inner[2..];
            const first_colon = std.mem.indexOfScalar(u8, after_prefix, ':') orelse return error.InvalidCursor;
            const second_part = after_prefix[first_colon + 1 ..];
            const second_colon = std.mem.indexOfScalar(u8, second_part, ':') orelse return error.InvalidCursor;

            const added_at_str = after_prefix[0..first_colon];
            cursor_added_at_us = std.fmt.parseInt(i64, added_at_str, 10) catch return error.InvalidCursor;
            cursor_user_id = allocator.dupe(u8, second_part[0..second_colon]) catch return error.OutOfMemory;
        }
        defer if (cursor_user_id) |cid| allocator.free(cid);

        const records = self.registry.listGroupMemberRecords(
            allocator,
            tenant_id,
            group_id,
            cursor_added_at_us,
            cursor_user_id,
            page_size,
        ) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };
        errdefer {
            for (records) |record| record.deinit(allocator);
            allocator.free(records);
        }

        const has_next = records.len > @as(usize, page_size);
        const page_records = if (has_next) records[0..page_size] else records;

        const items = allocator.alloc(registry_mod.User, page_records.len) catch return error.OutOfMemory;
        var cloned_count: usize = 0;
        errdefer {
            for (items[0..cloned_count]) |item| item.deinit(allocator);
            allocator.free(items);
        }
        for (page_records, 0..) |record, idx| {
            items[idx] = .{
                .user_id = allocator.dupe(u8, record.member.user_id) catch return error.OutOfMemory,
                .username = allocator.dupe(u8, record.member.username) catch return error.OutOfMemory,
                .display_name = allocator.dupe(u8, record.member.display_name) catch return error.OutOfMemory,
                .email = allocator.dupe(u8, record.member.email) catch return error.OutOfMemory,
                .status = record.member.status,
                .created_at = allocator.dupe(u8, record.member.created_at) catch return error.OutOfMemory,
            };
            cloned_count += 1;
        }

        var next_cursor: ?[]const u8 = null;
        if (has_next and page_records.len > 0) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const last = page_records[page_records.len - 1];
            const raw = pagination.buildRawCursorTimestampKey(
                a,
                "G:",
                last.added_at_us,
                page_records[page_records.len - 1].member.user_id,
                currentMicrosecondTimestamp(),
            ) catch return error.OutOfMemory;
            const encoded = pagination.encodeCursor(a, raw) catch return error.OutOfMemory;
            next_cursor = allocator.dupe(u8, encoded) catch return error.OutOfMemory;
        }

        for (records) |record| record.deinit(allocator);
        allocator.free(records);

        return .{
            .items = items,
            .next_cursor = next_cursor,
            .count = page_records.len,
        };
    }

    pub fn canClaimGroupTask(
        self: *Service,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
        user_id: []const u8,
    ) GroupError!bool {
        if (group_id.len == 0 or user_id.len == 0) return error.ValidationFailed;

        return self.registry.isActiveGroupMember(allocator, tenant_id, group_id, user_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
    }

    pub fn issueToken(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        input: CreateTokenInput,
    ) TokenError!IssuedToken {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (input.user_id.len == 0) return error.ValidationFailed;
        if (input.roles.len == 0) return error.InvalidRoleSet;
        for (input.roles) |role| {
            if (!isIssuableTokenRole(role)) return error.InvalidRoleSet;
        }

        const user_status = self.registry.getUserStatusById(allocator, actor.tenant_id[0..], input.user_id) catch |err| switch (err) {
            registry_mod.RegistryError.NotFound => return error.UserNotFound,
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };
        if (user_status == null) return error.UserNotFound;

        const conn = self.registry.pool.acquire() catch |err| return switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.registry.pool.release(conn);

        if (input.expires_at) |expires_at| {
            const valid_row = conn.queryRow(
                allocator,
                "SELECT ($1::timestamptz > NOW())::text",
                &[_][]const u8{expires_at},
            ) catch return error.ValidationFailed;
            if (valid_row == null) return error.ValidationFailed;
            defer freeRow(allocator, valid_row.?);

            const is_future = valid_row.?[0] orelse "f";
            if (!std.mem.eql(u8, is_future, "t") and !std.mem.eql(u8, is_future, "true")) {
                return error.ExpiresAtInPast;
            }
        }

        const token_value = try generateTokenValue(allocator);
        errdefer allocator.free(token_value);

        const token_hash = try hashToken(allocator, token_value);
        defer allocator.free(token_hash);

        const roles_json = try rolesToJson(allocator, input.roles);
        defer allocator.free(roles_json);

        const token_name = try std.fmt.allocPrint(allocator, "token-{s}", .{token_hash[0..8]});
        defer allocator.free(token_name);

        const row = if (input.expires_at) |expires_at| conn.queryRow(
            allocator,
            \\INSERT INTO api_tokens (user_id, name, token_hash, roles_json, expires_at)
            \\VALUES ($1::uuid, $2, $3, $4::jsonb, $5::timestamptz)
            \\RETURNING id::text, user_id::text, expires_at::text, created_at::text
        ,
            &[_][]const u8{ input.user_id, token_name, token_hash, roles_json, expires_at },
        ) catch |err| switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        } else conn.queryRow(
            allocator,
            \\INSERT INTO api_tokens (user_id, name, token_hash, roles_json)
            \\VALUES ($1::uuid, $2, $3, $4::jsonb)
            \\RETURNING id::text, user_id::text, expires_at::text, created_at::text
        ,
            &[_][]const u8{ input.user_id, token_name, token_hash, roles_json },
        ) catch |err| switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };

        if (row == null) return error.PersistenceFailed;
        defer freeRow(allocator, row.?);

        const token_id = row.?[0] orelse return error.PersistenceFailed;
        const user_id = row.?[1] orelse return error.PersistenceFailed;
        const expires_at_out = row.?[2];
        const created_at = row.?[3] orelse return error.PersistenceFailed;

        const role_copy = allocator.alloc(auth.Role, input.roles.len) catch return error.OutOfMemory;
        @memcpy(role_copy, input.roles);

        return .{
            .token_id = allocator.dupe(u8, token_id) catch return error.OutOfMemory,
            .token_value = token_value,
            .user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
            .roles = role_copy,
            .expires_at = if (expires_at_out) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
        };
    }

    pub fn listTokens(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
    ) TokenError!TokenListPage {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;

        const conn = self.registry.pool.acquire() catch |err| return switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.registry.pool.release(conn);

        var rows = conn.query(
            allocator,
            \\SELECT
            \\    id::text,
            \\    user_id::text,
            \\    COALESCE(roles_json::text, '[]'),
            \\    expires_at::text,
            \\    revoked_at::text,
            \\    created_at::text,
            \\    last_used_at::text,
            \\    CASE
            \\        WHEN revoked_at IS NOT NULL THEN 'REVOKED'
            \\        WHEN expires_at IS NOT NULL AND NOW() >= expires_at THEN 'EXPIRED'
            \\        ELSE 'ACTIVE'
            \\    END
            \\FROM api_tokens
            \\ORDER BY created_at DESC
        ,
            &[_][]const u8{},
        ) catch |err| switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
        defer rows.deinit();

        const items = allocator.alloc(ApiToken, rows.rows.len) catch return error.OutOfMemory;
        var built: usize = 0;
        errdefer {
            for (items[0..built]) |item| item.deinit(allocator);
            allocator.free(items);
        }

        for (rows.rows) |row| {
            if (row.len < 8) return error.PersistenceFailed;
            const token_id = row[0] orelse return error.PersistenceFailed;
            const user_id = row[1] orelse return error.PersistenceFailed;
            const roles_json = row[2] orelse "[]";
            const created_at = row[5] orelse return error.PersistenceFailed;
            const status_str = row[7] orelse return error.PersistenceFailed;

            const roles = parseRolesJson(allocator, roles_json) catch return error.InvalidRoleSet;
            const status = if (std.mem.eql(u8, status_str, "REVOKED"))
                TokenStatus.REVOKED
            else if (std.mem.eql(u8, status_str, "EXPIRED"))
                TokenStatus.EXPIRED
            else
                TokenStatus.ACTIVE;

            items[built] = .{
                .token_id = allocator.dupe(u8, token_id) catch return error.OutOfMemory,
                .user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
                .roles = roles,
                .expires_at = if (row[3]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
                .revoked_at = if (row[4]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
                .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
                .last_used_at = if (row[6]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
                .status = status,
            };
            built += 1;
        }

        return .{ .items = items };
    }

    pub fn revokeToken(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: auth.AuthContext,
        token_id: []const u8,
    ) TokenError!void {
        if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
        if (token_id.len == 0) return error.ValidationFailed;

        const conn = self.registry.pool.acquire() catch |err| return switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.registry.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\UPDATE api_tokens
            \\SET revoked_at = COALESCE(revoked_at, NOW())
            \\WHERE id::text = $1
            \\RETURNING id::text
        ,
            &[_][]const u8{token_id},
        ) catch |err| switch (err) {
            @import("../db/pool.zig").PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };

        if (row == null) return error.TokenNotFound;
        freeRow(allocator, row.?);
    }

    fn assertRealmOwnedByTenant(
        self: *Service,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        external_realm: []const u8,
    ) IdentityError!void {
        const tenant = self.registry.selectTenantById(allocator, tenant_id) catch |err| switch (err) {
            registry_mod.RegistryError.PoolExhausted => return error.PoolExhausted,
            registry_mod.RegistryError.PersistenceFailed => return error.PersistenceFailed,
            registry_mod.RegistryError.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };

        if (tenant == null) return error.TenantNotFound;
        defer tenant.?.deinit(allocator);

        const bound_realm = tenant.?.idp_realm_id orelse return error.MissingRealmBinding;
        if (!std.mem.eql(u8, bound_realm, external_realm)) return error.RealmOwnershipMismatch;
    }
};

fn normalizeOptionalText(input: ?[]const u8) ?[]const u8 {
    if (input) |value| {
        if (value.len == 0) return null;
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
        return value;
    }
    return null;
}

fn isValidEmail(email: []const u8) bool {
    if (email.len < 3) return false;
    const at_idx = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at_idx == 0 or at_idx + 1 >= email.len) return false;

    const domain = email[at_idx + 1 ..];
    const dot_idx = std.mem.indexOfScalar(u8, domain, '.') orelse return false;
    if (dot_idx == 0 or dot_idx + 1 >= domain.len) return false;

    return true;
}

fn validateReservedUsernamePolicy(actor: auth.AuthContext, username: []const u8) IdentityError!void {
    const normalized = std.mem.trim(u8, username, " \t\r\n");
    if (!startsWithIgnoreCase(normalized, reserved_username_prefix)) return;

    if (normalized.len == reserved_username_prefix.len) {
        return error.ReservedUsernameInvalidFormat;
    }

    if (actor.role != .PLATFORM_ADMIN) {
        return error.ReservedUsernameRequiresPlatformAdmin;
    }
}

fn validateReservedUsernameForNonAdmin(username: []const u8) IdentityError!void {
    const normalized = std.mem.trim(u8, username, " \t\r\n");
    if (!startsWithIgnoreCase(normalized, reserved_username_prefix)) return;

    if (normalized.len == reserved_username_prefix.len) {
        return error.ReservedUsernameInvalidFormat;
    }

    return error.ReservedUsernameRequiresPlatformAdmin;
}

fn startsWithIgnoreCase(input: []const u8, prefix: []const u8) bool {
    if (input.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(input[0..prefix.len], prefix);
}

fn currentMicrosecondTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const sec_us: i64 = ts.sec * 1_000_000;
        const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
        return sec_us + nsec_us;
    }
}

fn isIssuableTokenRole(role: auth.Role) bool {
    return switch (role) {
        .PLATFORM_ADMIN, .PROCESS_DESIGNER, .PROCESS_OPERATOR, .TASK_WORKER, .AGENT_RUNNER => true,
        else => false,
    };
}

fn roleToString(role: auth.Role) []const u8 {
    return switch (role) {
        .PLATFORM_ADMIN => "PLATFORM_ADMIN",
        .PROCESS_DESIGNER => "PROCESS_DESIGNER",
        .PROCESS_OPERATOR => "PROCESS_OPERATOR",
        .TASK_WORKER => "TASK_WORKER",
        .VIEWER => "VIEWER",
        .AGENT_RUNNER => "AGENT_RUNNER",
    };
}

fn rolesToJson(allocator: std.mem.Allocator, roles: []const auth.Role) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (roles, 0..) |role, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, roleToString(role));
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');

    return buf.toOwnedSlice(allocator);
}

fn parseRolesJson(allocator: std.mem.Allocator, roles_json: []const u8) ![]auth.Role {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, roles_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidRoleSet;

    const out = try allocator.alloc(auth.Role, parsed.value.array.items.len);
    for (parsed.value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidRoleSet;
        out[idx] = auth.Role.fromString(item.string) orelse return error.InvalidRoleSet;
    }
    return out;
}

fn generateTokenValue(allocator: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    fillRandom(&raw);
    return std.fmt.allocPrint(allocator, "bpm_tok_{s}", .{std.fmt.bytesToHex(&raw, .lower)});
}

fn fillRandom(buf: []u8) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS - add a platform branch"),
    }
}

fn hashToken(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}
