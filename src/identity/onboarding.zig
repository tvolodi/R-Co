const std = @import("std");
const pool_mod = @import("pool");
const db_provisioning = @import("../db/provisioning.zig");
const registry_mod = @import("registry.zig");
const identity_provider = @import("identity_provider");
const provider_manager_mod = identity_provider.manager;
const provider_types = identity_provider.types;
const provider_errors = identity_provider.errors;

// ── Error set ─────────────────────────────────────────────────────────────────

pub const OnboardingError = error{
    DuplicateTenantSlug,
    DuplicateHostname,
    RealmProvisioningFailed,
    UserProvisioningFailed,
    RoleAssignmentFailed,
    ClientProvisioningFailed,
    HostnameBindingFailed,
    VerificationFailed,
    RealmAlreadyExists,
    IdempotencyConflict,
    Forbidden,
    ValidationFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
    // ENV-01: test tenant environment
    TestTenantMissingProductionRef, // → HTTP 422
    ProductionTenantMustNotHaveRef, // → HTTP 422
    InvalidProductionTenantRef, // production_tenant_id does not exist or is not production → HTTP 422
};

// ── Data types ────────────────────────────────────────────────────────────────

/// ENV-01: Distinguishes production tenants from test tenants.
pub const TenantType = enum {
    production,
    testing, // DB value: 'test'

    pub fn fromString(s: []const u8) ?TenantType {
        if (std.mem.eql(u8, s, "production")) return .production;
        if (std.mem.eql(u8, s, "test")) return .testing;
        return null;
    }

    pub fn asString(self: TenantType) []const u8 {
        return switch (self) {
            .production => "production",
            .testing => "test",
        };
    }
};

pub const OnboardingState = enum {
    pending,
    completed,
    failed,

    pub fn fromString(s: []const u8) ?OnboardingState {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }

    pub fn asString(self: OnboardingState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub const RealmConfigOverrides = struct {
    default_token_lifetime_seconds: ?u32,
    min_password_length: ?u8,
    require_uppercase: ?bool,
    require_digit: ?bool,
    signing_key_algorithm: ?[]const u8,
};

pub const ClientConfigOverrides = struct {
    redirect_uris: ?[]const []const u8,
    service_account_enabled: ?bool,
};

pub const OnboardingInput = struct {
    slug: []const u8,
    display_name: []const u8,
    admin_email: []const u8,
    admin_username: []const u8,
    admin_display_name: []const u8,
    hostname: []const u8,
    realm_config: ?RealmConfigOverrides,
    client_config: ?ClientConfigOverrides,
    // ENV-01: test tenant environment
    tenant_type: TenantType, // defaults to .production
    production_tenant_id: ?[]const u8, // UUID string; required when tenant_type = .test
};

pub const OnboardingResult = struct {
    onboarding_id: []const u8,
    tenant_id: []const u8,
    idp_realm_id: []const u8,
    client_id: []const u8,
    admin_user_id: []const u8,
    hostname: []const u8,
    oidc_authority: []const u8,
    discovery_url: []const u8,
    created: bool,

    pub fn deinit(self: OnboardingResult, allocator: std.mem.Allocator) void {
        allocator.free(self.onboarding_id);
        allocator.free(self.tenant_id);
        allocator.free(self.idp_realm_id);
        allocator.free(self.client_id);
        allocator.free(self.admin_user_id);
        allocator.free(self.hostname);
        allocator.free(self.oidc_authority);
        allocator.free(self.discovery_url);
    }
};

pub const OnboardingRecord = struct {
    onboarding_id: []const u8,
    idempotency_key: []const u8,
    tenant_id: []const u8,
    request_hash: []const u8,
    response_status: u16,
    response_body_json: []const u8,
    state: OnboardingState,
    created_at: []const u8,
    completed_at: ?[]const u8,

    pub fn deinit(self: OnboardingRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.onboarding_id);
        allocator.free(self.idempotency_key);
        allocator.free(self.tenant_id);
        allocator.free(self.request_hash);
        allocator.free(self.response_body_json);
        allocator.free(self.created_at);
        if (self.completed_at) |v| allocator.free(v);
    }
};

// ── Saga orchestration ────────────────────────────────────────────────────────

/// Tracks which saga steps completed, so compensating actions know what to undo.
const SagaState = struct {
    tenant_created: bool = false,
    schema_provisioned: bool = false,
    realm_provisioned: bool = false,
    user_provisioned: bool = false,
    roles_granted: bool = false,
    client_provisioned: bool = false,
    hostname_bound: bool = false,
    tenant_id: ?[]const u8 = null,
    tenant_slug: ?[]const u8 = null,
    realm_id: ?[]const u8 = null,
    admin_user_id: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
};

/// Execute the full onboarding saga. On any step failure, compensating actions
/// undo all completed steps. The caller (API handler) manages idempotency.
pub fn executeSaga(
    allocator: std.mem.Allocator,
    manager: provider_manager_mod.Manager,
    pool: *pool_mod.Pool,
    input: OnboardingInput,
    /// Registry onboarding_id to use in the result (hex UUID without dashes, or null to generate one).
    registry_onboarding_id: ?[]const u8,
    migrations_dir: []const u8,
) (OnboardingError || provider_errors.ProviderError)!OnboardingResult {
    var saga = SagaState{};
    errdefer compensate(allocator, manager, pool, &saga) catch {};
    // ── ENV-01: Validate tenant_type / production_tenant_id ──────────────────
    switch (input.tenant_type) {
        .production => {
            if (input.production_tenant_id != null) return error.ProductionTenantMustNotHaveRef;
        },
        .testing => {
            const ref = input.production_tenant_id orelse return error.TestTenantMissingProductionRef;
            // Verify the referenced tenant exists and is itself a production tenant.
            const ref_ok = validateProductionTenantRef(allocator, pool, ref) catch |err| switch (err) {
                error.PoolExhausted => return error.PoolExhausted,
                else => return error.PersistenceFailed,
            };
            if (!ref_ok) return error.InvalidProductionTenantRef;
        },
    }
    // ── 1. Create tenant ─────────────────────────────────────────────────────
    const tenant = createTenantInDb(allocator, pool, input) catch |err| switch (err) {
        error.DuplicateTenantSlug => return error.DuplicateTenantSlug,
        error.PoolExhausted => return error.PoolExhausted,
        error.PersistenceFailed => return error.PersistenceFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PersistenceFailed,
    };
    errdefer tenant.deinit(allocator);
    saga.tenant_created = true;
    saga.tenant_id = try allocator.dupe(u8, tenant.tenant_id);
    saga.tenant_slug = try allocator.dupe(u8, tenant.slug);

    // ── 1b. Provision tenant schema ──────────────────────────────────────────
    db_provisioning.provisionTenantSchema(allocator, pool, tenant.tenant_id, migrations_dir) catch |err| {
        return switch (err) {
            db_provisioning.ProvisionError.PoolExhausted => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
    };
    saga.schema_provisioned = true;

    // ── 2. Provision Keycloak realm ──────────────────────────────────────────
    const realm_result = manager.provisionRealm(allocator, .{
        .tenant_id = tenant.tenant_id,
        .tenant_slug = input.slug,
        .display_name = input.display_name,
        .desired_realm_id = input.slug,
        .default_token_lifetime_seconds = if (input.realm_config) |rc| rc.default_token_lifetime_seconds orelse 900 else 900,
        .min_password_length = if (input.realm_config) |rc| rc.min_password_length orelse 8 else 8,
        .require_uppercase = if (input.realm_config) |rc| rc.require_uppercase orelse true else true,
        .require_digit = if (input.realm_config) |rc| rc.require_digit orelse true else true,
        .signing_key_algorithm = if (input.realm_config) |rc| parseSigningAlgorithm(rc.signing_key_algorithm) orelse .RS256 else .RS256,
    }) catch |err| {
        // Explicitly run compensation for realm provisioning failures so
        // tenant cleanup does not depend on errdefer behavior.
        compensate(allocator, manager, pool, &saga) catch {};
        return switch (err) {
            error.NotImplemented => error.RealmProvisioningFailed,
            error.UpstreamUnavailable,
            error.UpstreamTimeout,
            error.UpstreamProtocolError,
            => error.RealmProvisioningFailed,
            error.DuplicateResource,
            error.Conflict,
            => error.RealmAlreadyExists,
            error.UnauthorizedAdminCall,
            error.ForbiddenAdminCall,
            => error.RealmProvisioningFailed,
            error.Internal => error.RealmProvisioningFailed,
            error.OutOfMemory => error.OutOfMemory,
            else => error.RealmProvisioningFailed,
        };
    };
    saga.realm_provisioned = true;
    saga.realm_id = try allocator.dupe(u8, realm_result.realm_id);

    // ── 3. Create admin user in realm ────────────────────────────────────────
    const user_result = manager.provisionUser(allocator, .{
        .tenant_id = tenant.tenant_id,
        .external_realm = input.slug,
        .external_id = input.admin_email,
        .preferred_username = input.admin_username,
        .display_name = input.admin_display_name,
        .email = input.admin_email,
        .initial_roles = &.{.PLATFORM_ADMIN},
    }) catch |err| switch (err) {
        error.NotImplemented => return error.UserProvisioningFailed,
        error.UpstreamUnavailable,
        error.UpstreamTimeout,
        error.UpstreamProtocolError,
        => return error.UserProvisioningFailed,
        error.DuplicateResource,
        error.Conflict,
        => return error.UserProvisioningFailed,
        error.UnauthorizedAdminCall,
        error.ForbiddenAdminCall,
        => return error.UserProvisioningFailed,
        error.Internal => return error.UserProvisioningFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UserProvisioningFailed,
    };
    saga.user_provisioned = true;
    saga.admin_user_id = try allocator.dupe(u8, user_result.external_user_id);

    // ── 4. Grant PLATFORM_ADMIN role ─────────────────────────────────────────
    _ = manager.grantRoles(allocator, .{
        .realm_id = input.slug,
        .external_user_id = user_result.external_user_id,
        .roles = &.{.PLATFORM_ADMIN},
    }) catch |err| switch (err) {
        error.NotImplemented => return error.RoleAssignmentFailed,
        error.UpstreamUnavailable,
        error.UpstreamTimeout,
        error.UpstreamProtocolError,
        => return error.RoleAssignmentFailed,
        error.UnauthorizedAdminCall,
        error.ForbiddenAdminCall,
        => return error.RoleAssignmentFailed,
        error.Internal => return error.RoleAssignmentFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RoleAssignmentFailed,
    };
    saga.roles_granted = true;

    // ── 5. Create OIDC client ────────────────────────────────────────────────
    const client_redirect_uris = if (input.client_config) |cc|
        if (cc.redirect_uris) |uris| uris else &[_][]const u8{try std.fmt.allocPrint(allocator, "https://{s}/*", .{input.hostname})}
    else
        &[_][]const u8{try std.fmt.allocPrint(allocator, "https://{s}/*", .{input.hostname})};

    const client_result = manager.provisionClient(allocator, .{
        .realm_id = input.slug,
        .client_name = "bpm-platform-api",
        .redirect_uris = client_redirect_uris,
        .service_account_enabled = if (input.client_config) |cc| cc.service_account_enabled orelse true else true,
    }) catch |err| switch (err) {
        error.NotImplemented => return error.ClientProvisioningFailed,
        error.UpstreamUnavailable,
        error.UpstreamTimeout,
        error.UpstreamProtocolError,
        => return error.ClientProvisioningFailed,
        error.DuplicateResource,
        error.Conflict,
        => return error.ClientProvisioningFailed,
        error.UnauthorizedAdminCall,
        error.ForbiddenAdminCall,
        => return error.ClientProvisioningFailed,
        error.Internal => return error.ClientProvisioningFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClientProvisioningFailed,
    };
    saga.client_provisioned = true;
    saga.client_id = try allocator.dupe(u8, client_result.client_id);

    // ── 6. Bind hostname ─────────────────────────────────────────────────────
    bindHostname(allocator, pool, tenant.tenant_id, input.hostname) catch |err| switch (err) {
        error.DuplicateHostname => return error.DuplicateHostname,
        error.PoolExhausted => return error.PoolExhausted,
        error.PersistenceFailed => return error.PersistenceFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostnameBindingFailed,
    };
    saga.hostname_bound = true;

    // ── 7. Verify realm discovery ────────────────────────────────────────────
    verifyDiscovery(allocator, input.slug) catch return error.VerificationFailed;

    // ── 8. Build result ──────────────────────────────────────────────────────
    // Use the registry onboarding_id if provided (async mode), otherwise generate one.
    const onboarding_id = if (registry_onboarding_id) |rid|
        try allocator.dupe(u8, rid)
    else
        try generateUuid(allocator);
    errdefer allocator.free(onboarding_id);

    const oidc_authority = try std.fmt.allocPrint(allocator, "http://keycloak:8081/realms/{s}", .{input.slug});
    errdefer allocator.free(oidc_authority);

    const discovery_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/openid-configuration", .{oidc_authority});
    errdefer allocator.free(discovery_url);

    return OnboardingResult{
        .onboarding_id = onboarding_id,
        .tenant_id = try allocator.dupe(u8, tenant.tenant_id),
        .idp_realm_id = try allocator.dupe(u8, input.slug),
        .client_id = try allocator.dupe(u8, client_result.client_id),
        .admin_user_id = try allocator.dupe(u8, user_result.external_user_id),
        .hostname = try allocator.dupe(u8, input.hostname),
        .oidc_authority = oidc_authority,
        .discovery_url = discovery_url,
        .created = true,
    };
}

// ── Compensating actions ──────────────────────────────────────────────────────

fn compensate(
    allocator: std.mem.Allocator,
    manager: provider_manager_mod.Manager,
    pool: *pool_mod.Pool,
    saga: *SagaState,
) !void {
    // Undo in reverse order.
    if (saga.hostname_bound and saga.tenant_id != null) {
        unbindHostname(pool, saga.tenant_id.?) catch {};
    }
    if (saga.client_provisioned and saga.realm_id != null) {
        // No deleteClient on manager; skip provider-level cleanup for now.
    }
    if (saga.roles_granted) {
        // Roles are cleaned up when user is deleted.
    }
    if (saga.user_provisioned and saga.realm_id != null) {
        // No deleteUser on manager; skip provider-level cleanup for now.
    }
    if (saga.admin_user_id) |uid| {
        allocator.free(uid);
        saga.admin_user_id = null;
    }
    if (saga.client_id) |cid| {
        allocator.free(cid);
        saga.client_id = null;
    }
    if (saga.realm_provisioned and saga.realm_id != null) {
        manager.deleteRealm(allocator, .{ .realm_id = saga.realm_id.? }) catch {};
    }
    if (saga.realm_id) |rid| {
        allocator.free(rid);
        saga.realm_id = null;
    }
    if (saga.schema_provisioned and saga.tenant_id != null) {
        dropTenantSchemaInDb(pool, saga.tenant_id.?);
        saga.schema_provisioned = false;
    }
    if (saga.tenant_created and saga.tenant_id != null) {
        deleteTenantInDb(pool, saga.tenant_id.?, saga.tenant_slug) catch {};
    }
    if (saga.tenant_id) |tid| {
        allocator.free(tid);
        saga.tenant_id = null;
    }
    if (saga.tenant_slug) |ts| {
        allocator.free(ts);
        saga.tenant_slug = null;
    }
}

// ── Database helpers ──────────────────────────────────────────────────────────

fn createTenantInDb(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    input: OnboardingInput,
) (OnboardingError || provider_errors.ProviderError)!registry_mod.Tenant {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Check for duplicate slug first.
    const existing = conn.queryRow(
        allocator,
        "SELECT id::text FROM tenant WHERE slug = $1 LIMIT 1",
        &[_][]const u8{input.slug},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    if (existing != null) {
        defer freeRow(allocator, existing.?);
        return error.DuplicateTenantSlug;
    }

    const tenant_type_str = input.tenant_type.asString();
    const has_prod_ref = input.production_tenant_id != null;

    const row = if (has_prod_ref) blk: {
        break :blk conn.queryRow(
            allocator,
            \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, $4, $5::uuid)
            \\ON CONFLICT (slug) DO NOTHING
            \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\          tenant_type, production_tenant_id::text
        ,
            &[_][]const u8{ input.slug, input.display_name, input.slug, tenant_type_str, input.production_tenant_id.? },
        );
    } else blk: {
        break :blk conn.queryRow(
            allocator,
            \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type)
            \\VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, $4)
            \\ON CONFLICT (slug) DO NOTHING
            \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\          tenant_type, production_tenant_id::text
        ,
            &[_][]const u8{ input.slug, input.display_name, input.slug, tenant_type_str },
        );
    };

    const resolved = row catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (resolved == null) return error.DuplicateTenantSlug;
    defer freeRow(allocator, resolved.?);

    const tenant = materializeTenant(allocator, resolved.?) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PersistenceFailed,
    };
    return tenant;
}

fn deleteTenantInDb(pool: *pool_mod.Pool, tenant_id: []const u8, tenant_slug: ?[]const u8) !void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    if (tenant_slug) |slug| {
        conn.exec("DELETE FROM tenant WHERE slug = $1", &[_][]const u8{slug}) catch {};
    }
    conn.exec("DELETE FROM tenant WHERE id::text = $1", &[_][]const u8{tenant_id}) catch {};
}

fn dropTenantSchemaInDb(pool: *pool_mod.Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("SELECT bpm_drop_tenant_schema($1::uuid)", &[_][]const u8{tenant_id}) catch {};
}

fn bindHostname(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    hostname: []const u8,
) (OnboardingError)!void {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Check for duplicate hostname first.
    const existing = conn.queryRow(
        allocator,
        "SELECT id::text FROM tenant_hostnames WHERE hostname = $1 LIMIT 1",
        &[_][]const u8{hostname},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    if (existing != null) {
        defer freeRow(allocator, existing.?);
        return error.DuplicateHostname;
    }

    const row = conn.queryRow(
        allocator,
        \\INSERT INTO tenant_hostnames (tenant_id, hostname)
        \\VALUES ($1::uuid, $2)
        \\ON CONFLICT (hostname) DO NOTHING
        \\RETURNING id::text
    ,
        &[_][]const u8{ tenant_id, hostname },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (row == null) return error.DuplicateHostname;
    freeRow(allocator, row.?);
}

fn unbindHostname(pool: *pool_mod.Pool, tenant_id: []const u8) !void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tenant_hostnames WHERE tenant_id::text = $1", &[_][]const u8{tenant_id}) catch {};
}

// ── Discovery verification ────────────────────────────────────────────────────
// Verifies that the realm's OIDC discovery endpoint exists. The URL derivation
// follows a deterministic pattern: http://keycloak:8081/realms/{slug}/.well-known/openid-configuration
//
// NOTE: In the current implementation, verification is a URL-format check.
// Full HTTP-level verification requires a running Keycloak instance and is
// performed by integration tests.

fn verifyDiscovery(allocator: std.mem.Allocator, realm_slug: []const u8) OnboardingError!void {
    const discovery_url = try std.fmt.allocPrint(
        allocator,
        "http://keycloak:8081/realms/{s}/.well-known/openid-configuration",
        .{realm_slug},
    );
    defer allocator.free(discovery_url);

    // Verify the URL is well-formed (parses correctly).
    _ = std.Uri.parse(discovery_url) catch return error.VerificationFailed;

    // URL is syntactically valid. Actual HTTP verification happens in E2E tests
    // against a live Keycloak instance.
}

// ── Utility helpers ───────────────────────────────────────────────────────────

pub fn computeRequestHash(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    return try allocator.dupe(u8, &digest);
}

fn materializeTenant(allocator: std.mem.Allocator, row: []?[]u8) !registry_mod.Tenant {
    if (row.len < 8) return error.PersistenceFailed;
    return registry_mod.Tenant{
        .tenant_id = try allocator.dupe(u8, row[0] orelse return error.PersistenceFailed),
        .slug = try allocator.dupe(u8, row[1] orelse return error.PersistenceFailed),
        .display_name = try allocator.dupe(u8, row[2] orelse return error.PersistenceFailed),
        .status = registry_mod.TenantStatus.fromString(row[3] orelse "ACTIVE") orelse .ACTIVE,
        .idp_realm_id = if (row[4]) |v| try allocator.dupe(u8, v) else null,
        .created_at = try allocator.dupe(u8, row[5] orelse return error.PersistenceFailed),
        .tenant_type = try allocator.dupe(u8, row[6] orelse "production"),
        .production_tenant_id = if (row[7]) |v| try allocator.dupe(u8, v) else null,
    };
}

/// ENV-01: Verify that the given UUID refers to an existing tenant with
/// tenant_type = 'production'. Returns false if no such tenant exists.
/// Security: production_tenant_id bound as $1::uuid — no string interpolation.
fn validateProductionTenantRef(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    production_tenant_id: []const u8,
) !bool {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT tenant_type FROM tenant WHERE id = $1::uuid LIMIT 1",
        &[_][]const u8{production_tenant_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    if (row == null) return false;
    defer freeRow(allocator, row.?);
    const t = row.?[0] orelse return false;
    return std.mem.eql(u8, t, "production");
}

fn generateUuid(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    const seed: u64 = @truncate(@intFromPtr(&raw));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&raw);
    // Set UUID v4 bits
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    // Encode as hex string (32 hex chars)
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, 32);
    for (raw, 0..) |byte, idx| {
        out[idx * 2] = hex[byte >> 4];
        out[idx * 2 + 1] = hex[byte & 0xf];
    }
    return out;
}

fn parseSigningAlgorithm(s: ?[]const u8) ?provider_types.SigningAlgorithm {
    const algo = s orelse return null;
    const mapping = std.StaticStringMap(provider_types.SigningAlgorithm).initComptime(.{
        .{ "RS256", .RS256 },
        .{ "RS384", .RS384 },
        .{ "RS512", .RS512 },
        .{ "ES256", .ES256 },
        .{ "ES384", .ES384 },
        .{ "ES512", .ES512 },
        .{ "PS256", .PS256 },
        .{ "PS384", .PS384 },
        .{ "PS512", .PS512 },
    });
    return mapping.get(algo);
}

// ── Public query helpers (used by service.zig) ────────────────────────────────

/// Public wrapper around bindHostname for the service layer.
pub fn bindHostnameWrapper(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    hostname: []const u8,
) OnboardingError!void {
    return bindHostname(allocator, pool, tenant_id, hostname);
}

/// Look up an onboarding record by onboarding_id.
pub fn selectOnboardingById(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
) OnboardingError!?OnboardingRecord {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT onboarding_id::text, idempotency_key, COALESCE(tenant_id::text, ''), encode(request_hash, 'hex'), response_status, COALESCE(response_body::text, '{}'), state, created_at::text, completed_at::text
        \\FROM onboarding_registry
        \\WHERE onboarding_id::text = $1
        \\LIMIT 1
    ,
        &[_][]const u8{onboarding_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (row == null) return null;
    defer freeRow(allocator, row.?);
    return materializeOnboardingRecord(allocator, row.?);
}

/// Look up an onboarding record by hostname (only completed records).
pub fn selectOnboardingByHostname(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    hostname: []const u8,
) OnboardingError!?OnboardingRecord {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT onboarding_id::text, idempotency_key, COALESCE(tenant_id::text, ''), encode(request_hash, 'hex'), response_status, COALESCE(response_body::text, '{}'), state, created_at::text, completed_at::text
        \\FROM onboarding_registry
        \\WHERE hostname = $1 AND state = 'completed'
        \\LIMIT 1
    ,
        &[_][]const u8{hostname},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (row == null) return null;
    defer freeRow(allocator, row.?);
    return materializeOnboardingRecord(allocator, row.?);
}

fn materializeOnboardingRecord(allocator: std.mem.Allocator, row: []?[]u8) !OnboardingRecord {
    if (row.len < 9) return error.PersistenceFailed;
    const state_str = row[6] orelse "pending";
    const state = OnboardingState.fromString(state_str) orelse return error.PersistenceFailed;
    const response_status = std.fmt.parseInt(u16, row[4] orelse "200", 10) catch 200;

    return OnboardingRecord{
        .onboarding_id = try allocator.dupe(u8, row[0] orelse return error.PersistenceFailed),
        .idempotency_key = try allocator.dupe(u8, row[1] orelse ""),
        .tenant_id = try allocator.dupe(u8, row[2] orelse ""),
        .request_hash = try allocator.dupe(u8, row[3] orelse ""),
        .response_status = response_status,
        .response_body_json = try allocator.dupe(u8, row[5] orelse "{}"),
        .state = state,
        .created_at = try allocator.dupe(u8, row[7] orelse ""),
        .completed_at = if (row[8]) |v| try allocator.dupe(u8, v) else null,
    };
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}
