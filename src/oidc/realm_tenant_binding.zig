//! OIDC-12 — Realm-tenant binding.
//!
//! Defines the data model and service functions that establish and enforce
//! a one-to-one mapping between BPM platform tenants and identity provider
//! realms.  Every BPM tenant MUST be associated with exactly one realm at
//! the IdP.
//!
//! The `tenant` table carries an `idp_realm_id` column (added by ADP-04b)
//! that stores the provider's realm identifier.
//!
//! ## Key invariants
//!
//! 1. One-to-one binding: each tenant has exactly one `idp_realm_id` and
//!    each `idp_realm_id` maps to exactly one tenant.
//! 2. Default tenant binding: `idp_realm_id = 'bpm-default'`.
//! 3. Realm ID is immutable after creation.
//! 4. Tenant creation requires `idp_realm_id` (enforced by the API layer).
//! 5. Realm-to-tenant lookup is the authoritative reverse path.

const std = @import("std");
const pool_mod = @import("pool");

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur during realm-tenant binding operations.
pub const RealmBindingError = error{
    /// The idp_realm_id is already assigned to another tenant.
    DuplicateRealmBinding,
    /// The IdP rejected realm provisioning.
    RealmProvisioningFailed,
    /// Tenant slug already exists.
    DuplicateTenantSlug,
    /// The requested entity was not found.
    NotFound,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur during lookup operations.
pub const LookupError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Extension to the existing Tenant struct with IdP realm binding.
pub const TenantRealmBinding = struct {
    tenant_id: []const u8,
    tenant_slug: []const u8,
    display_name: []const u8,
    /// The identity provider realm identifier associated with this tenant.
    /// For the default tenant this is 'bpm-default' (ADP-04b).
    idp_realm_id: []const u8,
    status: []const u8,
    created_at: []const u8,

    pub fn deinit(self: TenantRealmBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.tenant_slug);
        allocator.free(self.display_name);
        allocator.free(self.idp_realm_id);
        allocator.free(self.status);
        allocator.free(self.created_at);
    }
};

/// Input for creating a new tenant with an IdP realm binding.
pub const CreateTenantWithRealmInput = struct {
    tenant_slug: []const u8,
    display_name: []const u8,
    /// The IdP realm identifier. Required (enforced by the API layer).
    /// Must be unique across all tenants.
    idp_realm_id: []const u8,
    /// If true, also provision the realm at the IdP via OIDC-14 adapter.
    provision_realm: bool,
    /// Optional explicit tenant UUID.
    tenant_id: ?[]const u8 = null,
};

/// Input for resolving a tenant by its IdP realm identifier.
pub const ResolveTenantByRealmInput = struct {
    /// The realm identifier from the token's resolved issuer context.
    idp_realm_id: []const u8,
};

// ---------------------------------------------------------------------------
// Realm-to-tenant lookup
// ---------------------------------------------------------------------------

/// Resolve the BPM tenant associated with a given IdP realm.
///
/// This is called during auth middleware after token verification,
/// to determine which tenant the request should be scoped to.
///
/// Returns error.NotFound if no tenant is bound to this realm (which is
/// an error — the token's realm should always have a tenant binding).
///
/// Error cases:
///   - NotFound / PoolExhausted / PersistenceFailed / OutOfMemory
pub fn resolveTenantByRealm(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    input: ResolveTenantByRealmInput,
) (LookupError || error{NotFound})!TenantRealmBinding {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, slug, display_name, idp_realm_id, status, created_at::text
        \\FROM tenant
        \\WHERE idp_realm_id = $1
        \\LIMIT 1
    ,
        &[_][]const u8{input.idp_realm_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    const row_data = row orelse return error.NotFound;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 6) return error.PersistenceFailed;

    return TenantRealmBinding{
        .tenant_id = try allocator.dupe(u8, row_data[0] orelse return error.PersistenceFailed),
        .tenant_slug = try allocator.dupe(u8, row_data[1] orelse return error.PersistenceFailed),
        .display_name = try allocator.dupe(u8, row_data[2] orelse return error.PersistenceFailed),
        .idp_realm_id = try allocator.dupe(u8, row_data[3] orelse return error.PersistenceFailed),
        .status = try allocator.dupe(u8, row_data[4] orelse "ACTIVE"),
        .created_at = try allocator.dupe(u8, row_data[5] orelse ""),
    };
}

// ---------------------------------------------------------------------------
// Tenant-to-realm reverse lookup
// ---------------------------------------------------------------------------

/// Resolve the IdP realm identifier for a given tenant.
///
/// This is called during realm provisioning (OIDC-14) and during
/// admin operations that need to address the provider realm.
///
/// Returns error.NotFound if the tenant has no IdP realm binding.
///
/// Error cases:
///   - NotFound / PoolExhausted / PersistenceFailed / OutOfMemory
pub fn resolveRealmByTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) (LookupError || error{NotFound})![]const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT idp_realm_id FROM tenant WHERE id = $1::uuid LIMIT 1",
        &[_][]const u8{tenant_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    const row_data = row orelse return error.NotFound;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 1) return error.PersistenceFailed;
    return allocator.dupe(u8, row_data[0] orelse return error.PersistenceFailed);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveTenantByRealm - requires database" {
    return error.SkipZigTest;
}

test "resolveRealmByTenant - requires database" {
    return error.SkipZigTest;
}
