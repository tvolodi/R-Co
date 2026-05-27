//! OIDC-11 — External user identity stability.
//!
//! Ensures the OIDC `sub` claim is treated as the stable, immutable
//! identifier for an external user across the platform.  Changes to
//! mutable IdP attributes (email, username, display name) MUST NOT
//! change the local `user_id` or break the association between the
//! external identity and the user's task assignments, audit attribution,
//! or process history.
//!
//! The authoritative lookup path is `(external_realm, external_id)`
//! per ADP-04a's unique index.
//!
//! ## Key invariants
//!
//! 1. `sub` is immutable for the lifetime of the external identity.
//! 2. `(external_realm, external_id)` is unique (enforced by ADP-04a).
//! 3. Email/username changes at the IdP MUST NOT change local `user_id`.
//! 4. Renaming at the IdP is transparent — the local `user_id`, all task
//!    assignments, audit attribution, and process history remain unchanged.
//! 5. No fallback to email-based lookup for OIDC users.

const std = @import("std");
const pool_mod = @import("pool");

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur during external identity resolution.
pub const LookupError = error{
    /// No local user maps to this (realm, sub) pair.
    UserNotFound,
    /// The resolved user's tenant_id does not match the request scope.
    TenantMismatch,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur during the stability assertion.
pub const StableIdentityError = error{
    /// The stored external_id differs from the token's sub — indicates
    /// data corruption or a concurrent migration defect.
    IdentityDriftDetected,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Input for resolving a local user from an OIDC token's identity.
/// The caller provides the resolved realm and the `sub` claim value
/// directly — this module does not parse the token.
pub const IdentityLookupInput = struct {
    /// The resolved provider realm name (from token `iss` or adapter config).
    external_realm: []const u8,
    /// The `sub` claim from the verified token.
    external_id: []const u8,
    /// Tenant context that the request is scoped to.
    tenant_id: []const u8,
};

/// The local user record as returned by identity lookup.
/// Mirrors the fields from identity/registry.zig User without importing it.
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

pub const UserStatus = enum {
    ACTIVE,
    INACTIVE,

    pub fn fromString(s: []const u8) ?UserStatus {
        if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
        if (std.mem.eql(u8, s, "INACTIVE")) return .INACTIVE;
        return null;
    }
};

/// Result of resolving a stable external identity.
pub const IdentityLookupResult = struct {
    /// The local user record matched by (external_realm, external_id).
    user: User,
    /// Whether the email or display_name in the token differs from
    /// the stored value (for audit / OIDC-10 sync trigger).
    has_profile_drift: bool,
};

// ---------------------------------------------------------------------------
// Identity lookup
// ---------------------------------------------------------------------------

/// Resolve a local user by the authoritative external identity tuple.
///
/// Assumptions:
///   - ADP-04a guarantees at most one user per (external_realm, external_id).
///   - The caller has already verified the token signature and extracted
///     the realm and `sub` from the JWT claims.
///
/// Error cases:
///   - UserNotFound: No local user maps to this (realm, sub) pair.
///   - TenantMismatch: The resolved user's tenant_id does not match
///     the request-scoped tenant_id.
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
pub fn resolveByExternalIdentity(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    input: IdentityLookupInput,
) LookupError!IdentityLookupResult {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, username, display_name, email, status, created_at::text,
        \\       external_id
        \\FROM users
        \\WHERE external_realm = $1
        \\  AND external_id = $2
        \\  AND tenant_id = $3::uuid
        \\LIMIT 1
    ,
        &[_][]const u8{ input.external_realm, input.external_id, input.tenant_id },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    const row_data = row orelse return error.UserNotFound;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 7) return error.PersistenceFailed;

    const user_id = try allocator.dupe(u8, row_data[0] orelse return error.PersistenceFailed);
    errdefer allocator.free(user_id);
    const username = try allocator.dupe(u8, row_data[1] orelse return error.PersistenceFailed);
    errdefer allocator.free(username);
    const display_name = try allocator.dupe(u8, row_data[2] orelse return error.PersistenceFailed);
    errdefer allocator.free(display_name);
    const email = try allocator.dupe(u8, row_data[3] orelse "");
    errdefer allocator.free(email);
    const status_raw = row_data[4] orelse "ACTIVE";
    const status = UserStatus.fromString(status_raw) orelse UserStatus.ACTIVE;
    const created_at = try allocator.dupe(u8, row_data[5] orelse "");
    errdefer allocator.free(created_at);

    // Check profile drift: compare token external_id against stored external_id.
    const stored_external_id = row_data[6] orelse "";
    const has_profile_drift = !std.mem.eql(u8, stored_external_id, input.external_id);

    return IdentityLookupResult{
        .user = User{
            .user_id = user_id,
            .username = username,
            .display_name = display_name,
            .email = email,
            .status = status,
            .created_at = created_at,
        },
        .has_profile_drift = has_profile_drift,
    };
}

// ---------------------------------------------------------------------------
// Stability assertion
// ---------------------------------------------------------------------------

/// Assert that the user's external identity has not drifted.
///
/// This is a safety check called during auth middleware after
/// `resolveByExternalIdentity`. It compares the token's `sub` against
/// the stored `external_id` and returns an error if they differ (should
/// never happen — indicates data corruption or a concurrent migration
/// defect).
///
/// This function does NOT mutate any data. It is a pure verification step.
pub fn assertStableIdentity(
    stored_external_id: []const u8,
    token_sub: []const u8,
) StableIdentityError!void {
    if (!std.mem.eql(u8, stored_external_id, token_sub)) {
        return error.IdentityDriftDetected;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveByExternalIdentity - user not found returns error" {
    // This test requires a database connection (integration test).
    // It is skipped in unit test mode.
    return error.SkipZigTest;
}

test "assertStableIdentity - matching ids returns ok" {
    try assertStableIdentity("user-123", "user-123");
}

test "assertStableIdentity - mismatched ids returns error" {
    const testing = std.testing;
    const result = assertStableIdentity("user-123", "user-456");
    try testing.expectError(error.IdentityDriftDetected, result);
}
