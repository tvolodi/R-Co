//! OIDC-15 — Realm deletion safety.
//!
//! Defines the two-phase realm deletion protocol that prevents accidental
//! or irreversible data loss at the identity provider.  Realm deletion
//! proceeds through a soft "mark for deletion" phase (no new tokens issued;
//! existing tokens accepted until expiry), followed by a configurable grace
//! period (default 7 days), after which a hard delete irreversibly removes
//! all provider-side realm data.
//!
//! ## Key invariants
//!
//! 1. Two-phase protocol is mandatory — realm MUST NOT be hard-deleted
//!    without first being marked for deletion.
//! 2. Tokens issued before marking remain valid until expiry.
//! 3. Grace period is configurable per realm (default 7 days).
//! 4. Active tenant with running instances blocks marking.
//! 5. Hard deletion is irreversible.
//! 6. All steps are audit-logged.

const std = @import("std");
const pool_mod = @import("pool");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default grace period: 7 days in seconds.
pub const GRACE_PERIOD_DEFAULT_SECONDS: u64 = 604800;

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur during the mark-for-deletion phase.
pub const MarkForDeletionError = error{
    /// The realm does not exist at the provider.
    RealmNotFound,
    /// The realm is already in MARKED_FOR_DELETION status.
    AlreadyMarked,
    /// The realm is bound to a tenant with active process instances.
    ActiveTenantBound,
    /// Cannot delete the default tenant's realm.
    CannotDeleteDefaultRealm,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur during the hard-delete phase.
pub const HardDeleteError = error{
    /// Realm already deleted or never existed.
    RealmNotFound,
    /// Realm is still ACTIVE — caller must mark it first.
    NotMarkedForDeletion,
    /// Attempted hard delete before grace period ended without force=true.
    GracePeriodNotElapsed,
    /// Keycloak returned an error during DELETE.
    ProviderSideDeletionFailed,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur during grace-period scheduler processing.
pub const ProcessError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Status of a realm in the deletion lifecycle.
pub const RealmDeletionStatus = enum {
    /// Realm is active — normal operation.
    ACTIVE,
    /// Realm is marked for deletion — no new logins, existing tokens accepted.
    MARKED_FOR_DELETION,
    /// Hard deletion is in progress.
    DELETING,
    /// Realm has been hard-deleted from the provider.
    DELETED,

    pub fn fromString(s: []const u8) ?RealmDeletionStatus {
        if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
        if (std.mem.eql(u8, s, "MARKED_FOR_DELETION")) return .MARKED_FOR_DELETION;
        if (std.mem.eql(u8, s, "DELETING")) return .DELETING;
        if (std.mem.eql(u8, s, "DELETED")) return .DELETED;
        return null;
    }

    pub fn asString(self: RealmDeletionStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .MARKED_FOR_DELETION => "MARKED_FOR_DELETION",
            .DELETING => "DELETING",
            .DELETED => "DELETED",
        };
    }
};

/// Input for marking a realm for deletion (phase 1).
pub const MarkForDeletionInput = struct {
    /// The IdP realm identifier to mark.
    realm_id: []const u8,
    /// Who initiated the deletion (for audit).
    actor_id: []const u8,
    /// Reason for deletion (for audit).
    reason: []const u8,
    /// Grace period in seconds before hard delete is allowed.
    /// Default: 604800 (7 days).
    grace_period_seconds: u64 = GRACE_PERIOD_DEFAULT_SECONDS,
};

/// Result of marking a realm for deletion.
pub const MarkForDeletionResult = struct {
    realm_id: []const u8,
    deletion_status: RealmDeletionStatus,
    /// The timestamp after which hard deletion is allowed (Unix epoch seconds).
    hard_delete_after: i64,
    /// Number of currently active sessions (approximate, from provider).
    active_session_count: u64,

    pub fn deinit(self: MarkForDeletionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.realm_id);
    }
};

/// Input for hard-deleting a realm (phase 2).
pub const HardDeleteRealmInput = struct {
    /// The IdP realm identifier to hard-delete.
    realm_id: []const u8,
    /// Who initiated the deletion (for audit).
    actor_id: []const u8,
    /// Force deletion even if grace period has not elapsed.
    /// Only allowed for PLATFORM_ADMIN.
    force: bool,
};

/// Result of hard-deleting a realm.
pub const HardDeleteRealmResult = struct {
    realm_id: []const u8,
    deletion_status: RealmDeletionStatus,
    /// Timestamp of the hard deletion (Unix epoch seconds).
    deleted_at: i64,
    /// True if the tenant binding was also removed.
    tenant_binding_released: bool,

    pub fn deinit(self: HardDeleteRealmResult, allocator: std.mem.Allocator) void {
        allocator.free(self.realm_id);
    }
};

/// A single entry from the realm_deletion_tracker table.
pub const RealmDeletionTrackerEntry = struct {
    realm_id: []const u8,
    status: RealmDeletionStatus,
    marked_at: i64,
    marked_by: []const u8,
    reason: []const u8,
    grace_period_seconds: u64,
    hard_delete_after: i64,
    hard_deleted_at: ?i64,
    retry_count: u32,
    last_retry_at: ?i64,
    metadata_json: ?[]const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: RealmDeletionTrackerEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.realm_id);
        allocator.free(self.marked_by);
        allocator.free(self.reason);
        if (self.metadata_json) |v| allocator.free(v);
    }
};

/// Result of the grace-period scheduler processing.
pub const ProcessResult = struct {
    processed: u32,
    succeeded: u32,
    failed: u32,
    skipped: u32,
};

// ---------------------------------------------------------------------------
// Phase 1: Mark for deletion (DB-level tracking)
// ---------------------------------------------------------------------------

/// Insert a realm_deletion_tracker row indicating the realm has been
/// marked for deletion.
///
/// This is called by the auth middleware / admin API *after* the provider
/// adapter has disabled the realm.
pub fn insertDeletionTracker(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    input: MarkForDeletionInput,
    now_unix_seconds: i64,
) MarkForDeletionError!void {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const hard_delete_after = now_unix_seconds + @as(i64, @intCast(input.grace_period_seconds));

    const grace_str = try std.fmt.allocPrint(allocator, "{d}", .{input.grace_period_seconds});
    defer allocator.free(grace_str);
    const hard_delete_str = try std.fmt.allocPrint(allocator, "{d}", .{hard_delete_after});
    defer allocator.free(hard_delete_str);

    _ = conn.exec(
        \\INSERT INTO realm_deletion_tracker
        \\  (realm_id, status, marked_by, reason, grace_period_seconds,
        \\   hard_delete_after, created_at, updated_at)
        \\VALUES ($1, 'MARKED_FOR_DELETION', $2::uuid, $3, $4::bigint,
        \\        to_timestamp($5::double precision), NOW(), NOW())
        \\ON CONFLICT (realm_id) DO NOTHING
    ,
        &[_][]const u8{
            input.realm_id,
            input.actor_id,
            input.reason,
            grace_str,
            hard_delete_str,
        },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
}

// ---------------------------------------------------------------------------
// Phase 2: Hard delete (release tenant binding)
// ---------------------------------------------------------------------------

/// Release the tenant's idp_realm_id binding after a realm has been
/// hard-deleted.
pub fn releaseTenantBinding(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    realm_id: []const u8,
) HardDeleteError!void {
    _ = allocator;
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    _ = conn.exec(
        \\UPDATE tenant
        \\SET idp_realm_id = NULL, updated_at = NOW()
        \\WHERE idp_realm_id = $1
    ,
        &[_][]const u8{realm_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
}

/// Update the tracker status to DELETED after a successful hard delete.
pub fn markTrackerDeleted(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    realm_id: []const u8,
    now_unix_seconds: i64,
) HardDeleteError!void {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const now_str = try std.fmt.allocPrint(allocator, "{d}", .{now_unix_seconds});
    defer allocator.free(now_str);

    _ = conn.exec(
        \\UPDATE realm_deletion_tracker
        \\SET status = 'DELETED',
        \\    hard_deleted_at = to_timestamp($2::double precision),
        \\    updated_at = NOW()
        \\WHERE realm_id = $1
    ,
        &[_][]const u8{
            realm_id,
            now_str,
        },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
}

/// Mark inactive all OIDC users whose external_realm matches the deleted realm.
pub fn markUsersInactiveByRealm(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    realm_id: []const u8,
) HardDeleteError!void {
    _ = allocator;
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    _ = conn.exec(
        \\UPDATE users
        \\SET status = 'INACTIVE', is_active = false, updated_at = NOW()
        \\WHERE external_realm = $1
        \\  AND auth_source = 'oidc'
    ,
        &[_][]const u8{realm_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
}

// ---------------------------------------------------------------------------
// Grace period scheduler
// ---------------------------------------------------------------------------

/// Query the realm_deletion_tracker for entries that are ready for hard
/// deletion (status = 'MARKED_FOR_DELETION' AND hard_delete_after <= NOW()).
pub fn queryPendingHardDeletions(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
) ProcessError![]RealmDeletionTrackerEntry {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    var rows = conn.query(
        allocator,
        \\SELECT realm_id, status, marked_at::text, marked_by::text, reason,
        \\       grace_period_seconds::text, hard_delete_after::text,
        \\       hard_deleted_at::text, retry_count::text, last_retry_at::text,
        \\       metadata_json::text, created_at::text, updated_at::text
        \\FROM realm_deletion_tracker
        \\WHERE status = 'MARKED_FOR_DELETION'
        \\  AND hard_delete_after <= NOW()
        \\ORDER BY hard_delete_after ASC
        \\LIMIT 50
    ,
        &.{},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer rows.deinit();

    const result = try allocator.alloc(RealmDeletionTrackerEntry, rows.rows.len);
    errdefer {
        for (result) |*entry| entry.deinit(allocator);
        allocator.free(result);
    }

    for (rows.rows, 0..) |row, i| {
        if (row.len < 13) {
            for (result[0..i]) |*entry| entry.deinit(allocator);
            allocator.free(result);
            return error.PersistenceFailed;
        }
        result[i] = RealmDeletionTrackerEntry{
            .realm_id = try allocator.dupe(u8, row[0] orelse return error.PersistenceFailed),
            .status = RealmDeletionStatus.fromString(row[1] orelse "MARKED_FOR_DELETION") orelse .MARKED_FOR_DELETION,
            .marked_at = std.fmt.parseInt(i64, row[2] orelse "0", 10) catch 0,
            .marked_by = try allocator.dupe(u8, row[3] orelse return error.PersistenceFailed),
            .reason = try allocator.dupe(u8, row[4] orelse ""),
            .grace_period_seconds = std.fmt.parseInt(u64, row[5] orelse "604800", 10) catch 604800,
            .hard_delete_after = std.fmt.parseInt(i64, row[6] orelse "0", 10) catch 0,
            .hard_deleted_at = if (row[7]) |v| std.fmt.parseInt(i64, v, 10) catch null else null,
            .retry_count = std.fmt.parseInt(u32, row[8] orelse "0", 10) catch 0,
            .last_retry_at = if (row[9]) |v| std.fmt.parseInt(i64, v, 10) catch null else null,
            .metadata_json = if (row[10]) |v| try allocator.dupe(u8, v) else null,
            .created_at = std.fmt.parseInt(i64, row[11] orelse "0", 10) catch 0,
            .updated_at = std.fmt.parseInt(i64, row[12] orelse "0", 10) catch 0,
        };
    }

    return result;
}

/// Increment the retry count for a deletion tracker entry.
pub fn incrementRetryCount(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    realm_id: []const u8,
) ProcessError!void {
    _ = allocator;
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    _ = conn.exec(
        \\UPDATE realm_deletion_tracker
        \\SET retry_count = retry_count + 1,
        \\    last_retry_at = NOW(),
        \\    updated_at = NOW()
        \\WHERE realm_id = $1
    ,
        &[_][]const u8{realm_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RealmDeletionStatus roundtrip" {
    const testing = std.testing;
    try testing.expectEqual(RealmDeletionStatus.ACTIVE, RealmDeletionStatus.fromString("ACTIVE").?);
    try testing.expectEqual(RealmDeletionStatus.MARKED_FOR_DELETION, RealmDeletionStatus.fromString("MARKED_FOR_DELETION").?);
    try testing.expectEqual(RealmDeletionStatus.DELETING, RealmDeletionStatus.fromString("DELETING").?);
    try testing.expectEqual(RealmDeletionStatus.DELETED, RealmDeletionStatus.fromString("DELETED").?);
    try testing.expectEqual(@as(?RealmDeletionStatus, null), RealmDeletionStatus.fromString("UNKNOWN"));
}

test "GRACE_PERIOD_DEFAULT_SECONDS is 7 days" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 604800), GRACE_PERIOD_DEFAULT_SECONDS);
    try testing.expectEqual(@as(u64, 7 * 24 * 60 * 60), GRACE_PERIOD_DEFAULT_SECONDS);
}

test "insertDeletionTracker - requires database" {
    return error.SkipZigTest;
}

test "queryPendingHardDeletions - requires database" {
    return error.SkipZigTest;
}
