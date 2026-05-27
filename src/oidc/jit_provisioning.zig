//! OIDC-09 — JIT user provisioning orchestration.
//!
//! This module defines the orchestration layer that bridges the OIDC-08
//! claim-mapping output (`IdentityContext`) and the ADP-04a identity service
//! (`createOrGetJitOidcUser`) so that every successfully verified OIDC bearer
//! token results in a local user record before the request proceeds to route
//! handling.
//!
//! The orchestrator handles:
//! - Per-realm JIT configuration (enabled/disabled, default status, default roles)
//! - Create-vs-existed discrimination for audit tracking
//! - Audit event emission for JIT user creation (OBS-03)
//! - A stable entry point that OIDC-10 (attribute synchronisation) can reuse
//!
//! ## Key invariants
//!
//! 1. JIT provisioning is idempotent — `createOrGetJitOidcUser` guarantees
//!    exactly one local user record per `(tenant_id, external_realm, external_id)`.
//!
//! 2. Provisioning failure is a hard failure — the auth pipeline MUST NOT proceed.
//!
//! 3. JIT config is per-realm, not per-tenant.  Using realm as the config key
//!    avoids a dependency on the tenant-resolution layer.

const std = @import("std");
const pool_mod = @import("pool");
const claim_mapping = @import("claim_mapping");

// Inline types from identity/registry.zig to avoid module conflicts.
// These match the User/UserStatus definitions in identity/registry.zig.
pub const UserStatus = enum {
    ACTIVE,
    INACTIVE,

    pub fn fromString(s: []const u8) ?UserStatus {
        if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
        if (std.mem.eql(u8, s, "INACTIVE")) return .INACTIVE;
        return null;
    }

    pub fn asString(self: UserStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .INACTIVE => "INACTIVE",
        };
    }
};

pub const User = struct {
    user_id: []const u8,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: UserStatus,
    created_at: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.username);
        allocator.free(self.display_name);
        allocator.free(self.email);
        allocator.free(self.created_at);
    }
};

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur during JIT provisioning.
pub const JitProvisioningError = error{
    /// JIT provisioning is disabled for this realm.
    JitDisabled,
    /// The realm is not owned by the resolved tenant.
    RealmTenantMismatch,
    /// Username collision with an existing internal user.
    DuplicateUsername,
    /// External identity collision with a different tenant's user.
    ExternalIdentityCollision,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur when loading JIT configuration.
pub const JitConfigError = error{
    ConfigParseFailed,
    PoolExhausted,
    OutOfMemory,
};

/// Errors that can occur during attribute synchronisation (OIDC-10 stub).
pub const SyncError = error{
    UserNotFound,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Per-realm JIT provisioning configuration.
pub const JitProvisioningConfig = struct {
    /// The realm this configuration applies to (caller-owned).
    realm: []const u8,
    /// Whether JIT user creation is enabled for this realm.
    enabled: bool,
    /// Default status for newly JIT-provisioned users.
    default_status: UserStatus,
    /// Role slugs to assign to newly provisioned users by default.
    /// Roles must exist in the `roles` table for the platform.
    /// If empty, the user gets no platform roles and defaults to VIEWER.
    default_roles: []const []const u8,

    /// Free all owned memory.
    pub fn deinit(self: *JitProvisioningConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.realm);
        for (self.default_roles) |r| allocator.free(r);
        allocator.free(self.default_roles);
    }
};

/// Result of a JIT provisioning operation.
pub const JitProvisioningResult = struct {
    /// The local user record (owned by caller).
    user: User,
    /// True when this call created a new local user record;
    /// false when the user already existed from a previous auth.
    created: bool,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default JIT configuration used when no explicit row exists for a realm.
pub const DEFAULT_JIT_CONFIG: JitProvisioningConfig = .{
    .realm = "",
    .enabled = true,
    .default_status = .ACTIVE,
    .default_roles = &.{},
};

// ---------------------------------------------------------------------------
// Configuration loading
// ---------------------------------------------------------------------------

/// Load the per-realm JIT provisioning configuration from the database.
/// When no explicit config row exists for the realm, returns the default
/// config (enabled=true, status=ACTIVE, roles=[]).
pub fn loadJitConfig(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    realm: []const u8,
) JitConfigError!JitProvisioningConfig {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PoolExhausted,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT enabled::text, default_status, default_roles::text
        \\  FROM jit_provisioning_config
        \\ WHERE realm = $1
    ,
        &[_][]const u8{realm},
    ) catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        pool_mod.PoolError.StaleConnection => return error.PoolExhausted,
        pool_mod.PoolError.QueryFailed => return error.ConfigParseFailed,
        else => return error.ConfigParseFailed,
    };

    const row_data = row orelse {
        // No explicit config: return defaults.
        return JitProvisioningConfig{
            .realm = try allocator.dupe(u8, realm),
            .enabled = true,
            .default_status = .ACTIVE,
            .default_roles = &.{},
        };
    };
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 3) return error.ConfigParseFailed;

    // Parse enabled flag.
    const enabled_text = if (row_data[0]) |v| v else "t";
    const enabled = std.mem.eql(u8, enabled_text, "t") or
        std.mem.eql(u8, enabled_text, "true");

    // Parse default status.
    const status_text = if (row_data[1]) |v| v else "ACTIVE";
    const default_status = UserStatus.fromString(status_text) orelse
        UserStatus.ACTIVE;

    // Parse default roles from JSONB.
    const roles_text = if (row_data[2]) |v| v else "[]";
    const default_roles = try parseRolesJson(allocator, roles_text);

    return JitProvisioningConfig{
        .realm = try allocator.dupe(u8, realm),
        .enabled = enabled,
        .default_status = default_status,
        .default_roles = default_roles,
    };
}

// ---------------------------------------------------------------------------
// Orchestration — provisioning
// ---------------------------------------------------------------------------

/// Process a JIT provisioning result: emit audit event if created.
///
/// The caller (auth middleware) handles loading JIT config, calling
/// identity_service.createOrGetJitOidcUser(), and error mapping.
/// This function handles the post-creation side effects (audit).
///
/// Steps:
///   1. If `created` is true, emit an audit event (OBS-03).
///   2. Return the provisioned user and the created flag.
pub fn processProvisionResult(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    user: User,
    created: bool,
) JitProvisioningError!JitProvisioningResult {
    // Step 1: If created, emit an audit event.
    if (created) {
        emitJitProvisionAuditEvent(pool, user.user_id, "") catch |err| switch (err) {
            error.PoolExhausted => {
                if (!created) user.deinit(allocator);
                return error.PoolExhausted;
            },
            error.PersistenceFailed => {
                if (!created) user.deinit(allocator);
                return error.PersistenceFailed;
            },
            else => {
                if (!created) user.deinit(allocator);
                return error.PersistenceFailed;
            },
        };
    }

    // Step 2: Return the result.
    return JitProvisioningResult{
        .user = user,
        .created = created,
    };
}

// ---------------------------------------------------------------------------
// Audit event emission
// ---------------------------------------------------------------------------

/// Emit an audit entry for a JIT user creation event.
fn emitJitProvisionAuditEvent(
    pool: *pool_mod.Pool,
    user_id: []const u8,
    _: []const u8,
) (error{ PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!void {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    _ = conn.exec(
        \\INSERT INTO audit_entries (actor_id, action, resource_type, resource_id, after_state)
        \\VALUES (NULL, 'user.jit_provision', 'user', $1::uuid,
        \\  jsonb_build_object('auth_source', 'oidc'))
    ,
        &[_][]const u8{user_id},
    ) catch |err| switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => return error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
}

// ---------------------------------------------------------------------------
// Attribute synchronisation (stub for OIDC-10)
// ---------------------------------------------------------------------------

/// Synchronise user attributes from an IdentityContext on every auth.
///
/// This is the function that OIDC-10 will call on subsequent logins.
/// It updates display name, email, and status on the existing local user
/// record when the token claims differ from stored values.
///
/// Precondition: the user MUST already exist (JIT-provisioned on first auth).
/// Returns `error.UserNotFound` if no local record maps to this identity.
pub fn syncAttributesFromIdentityContext(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    identity_ctx: *const claim_mapping.IdentityContext,
    _: []const u8,
) SyncError!User {
    _ = allocator;
    _ = pool;
    _ = identity_ctx;

    // Stub: OIDC-10 will implement attribute synchronisation.
    // For now, return an error indicating this is not yet implemented.
    return error.UserNotFound;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Parse a JSON array of strings into a `[][]const u8`.
fn parseRolesJson(allocator: std.mem.Allocator, json_text: []const u8) JitConfigError![][]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };
    defer parsed.deinit();

    if (parsed.value != .array) return error.ConfigParseFailed;

    const items = parsed.value.array.items;
    const roles = try allocator.alloc([]const u8, items.len);
    errdefer {
        for (roles[0..items.len]) |r| allocator.free(r);
        allocator.free(roles);
    }

    for (items, 0..) |item, i| {
        roles[i] = switch (item) {
            .string => |s| try allocator.dupe(u8, s),
            else => try allocator.dupe(u8, ""),
        };
    }

    return roles;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DEFAULT_JIT_CONFIG: enabled, ACTIVE, no roles" {
    try std.testing.expect(DEFAULT_JIT_CONFIG.enabled);
    try std.testing.expectEqual(UserStatus.ACTIVE, DEFAULT_JIT_CONFIG.default_status);
    try std.testing.expectEqual(@as(usize, 0), DEFAULT_JIT_CONFIG.default_roles.len);
}

test "JitProvisioningConfig.deinit: empty roles" {
    var config = JitProvisioningConfig{
        .realm = try std.testing.allocator.dupe(u8, "test-realm"),
        .enabled = true,
        .default_status = .ACTIVE,
        .default_roles = &.{},
    };
    config.deinit(std.testing.allocator);
}

test "JitProvisioningConfig.deinit: with roles" {
    const roles = try std.testing.allocator.alloc([]const u8, 2);
    roles[0] = try std.testing.allocator.dupe(u8, "PROCESS_DESIGNER");
    roles[1] = try std.testing.allocator.dupe(u8, "TASK_WORKER");
    var config = JitProvisioningConfig{
        .realm = try std.testing.allocator.dupe(u8, "test-realm"),
        .enabled = true,
        .default_status = .ACTIVE,
        .default_roles = roles,
    };
    config.deinit(std.testing.allocator);
}

test "parseRolesJson: empty array" {
    const roles = try parseRolesJson(std.testing.allocator, "[]");
    defer {
        for (roles) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(roles);
    }
    try std.testing.expectEqual(@as(usize, 0), roles.len);
}

test "parseRolesJson: single role" {
    const roles = try parseRolesJson(std.testing.allocator, "[\"VIEWER\"]");
    defer {
        for (roles) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(roles);
    }
    try std.testing.expectEqual(@as(usize, 1), roles.len);
    try std.testing.expectEqualStrings("VIEWER", roles[0]);
}

test "parseRolesJson: multiple roles" {
    const roles = try parseRolesJson(std.testing.allocator, "[\"PLATFORM_ADMIN\",\"VIEWER\"]");
    defer {
        for (roles) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(roles);
    }
    try std.testing.expectEqual(@as(usize, 2), roles.len);
    try std.testing.expectEqualStrings("PLATFORM_ADMIN", roles[0]);
    try std.testing.expectEqualStrings("VIEWER", roles[1]);
}

test "parseRolesJson: invalid JSON returns ConfigParseFailed" {
    try std.testing.expectError(error.ConfigParseFailed, parseRolesJson(std.testing.allocator, "not-json"));
}

test "parseRolesJson: non-array JSON returns ConfigParseFailed" {
    try std.testing.expectError(error.ConfigParseFailed, parseRolesJson(std.testing.allocator, "\"string\""));
}
