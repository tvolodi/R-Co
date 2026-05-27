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
// Attribute synchronisation (OIDC-10)
// ---------------------------------------------------------------------------

/// Result of an attribute sync + role reconciliation operation.
pub const SyncResult = struct {
    /// The updated local user record (owned by caller).
    user: User,
    /// Roles that were added during reconciliation.
    roles_added: []const []const u8,
    /// Roles that were removed during reconciliation.
    roles_removed: []const []const u8,
    /// Whether any profile fields were updated.
    profile_changed: bool,

    pub fn deinit(self: *SyncResult, allocator: std.mem.Allocator) void {
        self.user.deinit(allocator);
        for (self.roles_added) |r| allocator.free(r);
        allocator.free(self.roles_added);
        for (self.roles_removed) |r| allocator.free(r);
        allocator.free(self.roles_removed);
    }
};

/// Synchronise user attributes from an IdentityContext on every auth.
///
/// Steps:
///   1. Resolve the local user record by (tenant_id, realm, external_user_id).
///   2. Compare token claims against stored user profile fields.
///   3. If display_name, email, or status differ, update the user profile
///      via a direct UPDATE query.
///   4. Reconcile role bindings:
///      a. Read current user_roles with role_source.
///      b. Partition into OIDC-sourced vs locally-assigned.
///      c. Compute add_set = token_roles ∖ existing_slugs.
///      d. Compute remove_set = oidc_slugs ∖ token_roles.
///      e. Insert/delete OIDC-sourced bindings; leave local untouched.
///   5. Return SyncResult with the updated user, added/removed roles,
///      and a profile_changed flag.
///
/// Error behaviour:
///   - UserNotFound: No local record maps to this external identity.
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
///   - All errors are considered non-fatal to auth (best-effort).
///
/// Precondition: the user MUST already exist (JIT-provisioned on first auth).
pub fn syncAttributesFromIdentityContext(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    identity_ctx: *const claim_mapping.IdentityContext,
    tenant_id: []const u8,
) SyncError!SyncResult {
    // Step 1: Resolve the local user record by external identity.
    const user_opt = selectUserByExternalIdentity(allocator, pool, tenant_id, identity_ctx.realm, identity_ctx.external_user_id) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        error.PersistenceFailed => return error.PersistenceFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PersistenceFailed,
    };
    const user = user_opt orelse return error.UserNotFound;
    errdefer user.deinit(allocator);

    // Step 2: Compare token claims against stored profile fields.
    const claims_display_name = identity_ctx.display_name orelse identity_ctx.preferred_username;
    const claims_email = identity_ctx.email;

    const display_name_changed = !std.mem.eql(u8, user.display_name, claims_display_name);
    const email_changed = !std.mem.eql(u8, user.email, claims_email);
    // OIDC users are always considered ACTIVE from the IdP perspective.
    const status_changed = user.status != .ACTIVE;
    const profile_changed = display_name_changed or email_changed or status_changed;

    // Step 3: If profile fields differ, update via direct query.
    var updated_user = user;
    if (profile_changed) {
        const new_display_name = if (display_name_changed) claims_display_name else user.display_name;
        const new_email = if (email_changed) claims_email else user.email;

        updated_user = updateUserProfile(allocator, pool, user.user_id, tenant_id, new_display_name, new_email, UserStatus.ACTIVE) catch |err| switch (err) {
            error.NotFound => return error.UserNotFound,
            error.PoolExhausted => return error.PoolExhausted,
            error.PersistenceFailed => return error.PersistenceFailed,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistenceFailed,
        };
    }

    // Step 4: Reconcile role bindings.
    const reconcile_result = reconcileOidcRoles(allocator, pool, updated_user.user_id, identity_ctx.roles) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        error.PersistenceFailed => return error.PersistenceFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PersistenceFailed,
    };

    // Step 5: Build and return SyncResult.
    return SyncResult{
        .user = updated_user,
        .roles_added = reconcile_result.added,
        .roles_removed = reconcile_result.removed,
        .profile_changed = profile_changed,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers — attribute sync & role reconciliation
// ---------------------------------------------------------------------------

/// Result of reconcileOidcRoles.
const ReconcileResult = struct {
    added: []const []const u8,
    removed: []const []const u8,
};

/// Select a user by external identity (tenant_id, realm, external_id).
fn selectUserByExternalIdentity(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    realm: []const u8,
    external_user_id: []const u8,
) (error{ PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!?User {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, username, display_name, email, status, created_at::text
        \\FROM users
        \\WHERE tenant_id = $1::uuid
        \\  AND external_realm = $2
        \\  AND external_id = $3
        \\LIMIT 1
    ,
        &[_][]const u8{ tenant_id, realm, external_user_id },
    ) catch |err| switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => return error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };

    if (row == null) return null;
    return materializeUserFromRow(allocator, row.?);
}

/// Update display_name, email, and status for a user.
fn updateUserProfile(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    user_id: []const u8,
    tenant_id: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: UserStatus,
) (error{ NotFound, PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!User {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const status_str = status.asString();
    const active_str: []const u8 = switch (status) {
        .ACTIVE => "true",
        .INACTIVE => "false",
    };

    const row = conn.queryRow(
        allocator,
        \\UPDATE users
        \\SET display_name = $3, email = $4, status = $5,
        \\    is_active = $6::boolean, updated_at = NOW()
        \\WHERE id::text = $1 AND tenant_id = $2::uuid
        \\RETURNING id::text, username, display_name, email, status, created_at::text
    ,
        &[_][]const u8{ user_id, tenant_id, display_name, email, status_str, active_str },
    ) catch |err| switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => return error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };

    if (row == null) return error.NotFound;
    return materializeUserFromRow(allocator, row.?);
}

/// Reconcile OIDC token roles against local role bindings.
///
/// Algorithm:
///   1. Read current user_roles for the user (with role_source).
///   2. Partition into OIDC-sourced vs locally-assigned.
///   3. Compute add_set = token_roles ∖ existing_role_slugs.
///   4. Compute remove_set = OIDC-sourced_slugs ∖ token_roles.
///   5. Insert role bindings for add_set (role_source = 'oidc').
///   6. Delete role bindings for remove_set (only where role_source = 'oidc').
fn reconcileOidcRoles(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    user_id: []const u8,
    token_roles: []const []const u8,
) (error{ PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!ReconcileResult {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    // 1. Read current role bindings with their source.
    const rows = conn.query(
        allocator,
        \\SELECT r.name AS role_slug, ur.role_source
        \\FROM user_roles ur
        \\JOIN roles r ON r.id = ur.role_id
        \\WHERE ur.user_id = $1::uuid
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
    defer {
        for (rows) |r| {
            for (r) |col| {
                if (col) |v| allocator.free(v);
            }
            allocator.free(r);
        }
        allocator.free(rows);
    }

    // 2. Partition into OIDC-sourced vs locally-assigned.
    var oidc_slugs = std.StringArrayHashMap(void).empty;
    defer oidc_slugs.deinit(allocator);
    var local_slugs = std.StringArrayHashMap(void).empty;
    defer local_slugs.deinit(allocator);

    for (rows) |r| {
        if (r.len < 2) return error.PersistenceFailed;
        const slug = r[0] orelse return error.PersistenceFailed;
        const source = r[1] orelse return error.PersistenceFailed;

        if (std.mem.eql(u8, source, "oidc")) {
            oidc_slugs.put(allocator, slug, {}) catch return error.OutOfMemory;
        } else {
            local_slugs.put(allocator, slug, {}) catch return error.OutOfMemory;
        }
    }

    // 3. Compute add_set = token_roles ∖ (oidc_slugs ∪ local_slugs).
    var add_list = std.ArrayList([]const u8).empty;
    defer add_list.deinit(allocator);

    for (token_roles) |slug| {
        if (!oidc_slugs.contains(slug) and !local_slugs.contains(slug)) {
            add_list.append(allocator, slug) catch return error.OutOfMemory;
        }
    }

    // 4. Compute remove_set = oidc_slugs ∖ token_roles.
    var remove_list = std.ArrayList([]const u8).empty;
    defer remove_list.deinit(allocator);

    {
        var iter = oidc_slugs.keyIterator();
        while (iter.next()) |slug_ptr| {
            const slug = slug_ptr.*;
            var found = false;
            for (token_roles) |ts| {
                if (std.mem.eql(u8, slug, ts)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                remove_list.append(allocator, slug) catch return error.OutOfMemory;
            }
        }
    }

    // 5. Insert OIDC-sourced bindings for add_set.
    for (add_list.items) |slug| {
        _ = conn.exec(
            \\INSERT INTO user_roles (user_id, role_id, role_source)
            \\SELECT $1::uuid, r.id, 'oidc'
            \\FROM roles r
            \\WHERE r.name = $2
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM user_roles ur
            \\    WHERE ur.user_id = $1::uuid AND ur.role_id = r.id
            \\  )
            \\ON CONFLICT (user_id, role_id) DO NOTHING
        ,
            &[_][]const u8{ user_id, slug },
        ) catch |err| switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => return error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
    }

    // 6. Delete OIDC-sourced bindings for remove_set.
    for (remove_list.items) |slug| {
        _ = conn.exec(
            \\DELETE FROM user_roles
            \\WHERE user_id = $1::uuid
            \\  AND role_id = (SELECT id FROM roles WHERE name = $2)
            \\  AND role_source = 'oidc'
        ,
            &[_][]const u8{ user_id, slug },
        ) catch |err| switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => return error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
    }

    // 7. Build result (duplicate to owned memory).
    const added = try allocator.alloc([]const u8, add_list.items.len);
    errdefer {
        for (added) |r| allocator.free(r);
        allocator.free(added);
    }
    for (add_list.items, 0..) |slug, i| {
        added[i] = try allocator.dupe(u8, slug);
    }

    const removed = try allocator.alloc([]const u8, remove_list.items.len);
    errdefer {
        for (removed) |r| allocator.free(r);
        allocator.free(removed);
    }
    for (remove_list.items, 0..) |slug, i| {
        removed[i] = try allocator.dupe(u8, slug);
    }

    return .{ .added = added, .removed = removed };
}

/// Materialize a User from a queryRow result.
fn materializeUserFromRow(allocator: std.mem.Allocator, row: []?[]u8) (error{ PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!User {
    defer {
        for (row) |col| {
            if (col) |v| allocator.free(v);
        }
        allocator.free(row);
    }

    if (row.len < 6) return error.PersistenceFailed;

    const user_id = row[0] orelse return error.PersistenceFailed;
    const username = row[1] orelse return error.PersistenceFailed;
    const display_name = row[2] orelse return error.PersistenceFailed;
    const email = row[3] orelse return error.PersistenceFailed;
    const status_str = row[4] orelse return error.PersistenceFailed;
    const created_at = row[5] orelse return error.PersistenceFailed;

    const status = UserStatus.fromString(status_str) orelse return error.PersistenceFailed;

    return User{
        .user_id = try allocator.dupe(u8, user_id),
        .username = try allocator.dupe(u8, username),
        .display_name = try allocator.dupe(u8, display_name),
        .email = try allocator.dupe(u8, email),
        .status = status,
        .created_at = try allocator.dupe(u8, created_at),
    };
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
