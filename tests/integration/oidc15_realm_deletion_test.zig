//! Integration tests for OIDC-15 — Realm deletion safety.
//!
//! Tests insertDeletionTracker, releaseTenantBinding, markTrackerDeleted,
//! markUsersInactiveByRealm, queryPendingHardDeletions, incrementRetryCount,
//! and the deletion lifecycle invariants against a real PostgreSQL database.
//!
//! Requirement: OIDC-15 — Realm deletion safety [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs — all tests use real PostgreSQL.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const realm_deletion = @import("realm_deletion");
const pg = @import("pg");

const pool_mod = bpm.db_pool;

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

/// GH-512: generate a per-test actor_id UUID. Caller owns the returned slice.
fn randomActorId(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

fn cleanupDeletionTracker(pool: *pool_mod.Pool, realm_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM realm_deletion_tracker WHERE realm_id = $1", &[_][]const u8{realm_id}) catch {};
}

fn cleanupTenantBySlug(pool: *pool_mod.Pool, slug: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.tenant WHERE slug = $1", &[_][]const u8{slug}) catch {};
}

fn cleanupUserByRealm(pool: *pool_mod.Pool, realm: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM users WHERE external_realm = $1", &[_][]const u8{realm}) catch {};
}

fn cleanupUserByUsername(pool: *pool_mod.Pool, username: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        \\DELETE FROM group_members
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    , &[_][]const u8{username}) catch {};
    conn.exec(
        \\DELETE FROM api_tokens
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    , &[_][]const u8{username}) catch {};
    conn.exec(
        \\DELETE FROM user_roles
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    , &[_][]const u8{username}) catch {};
    conn.exec("DELETE FROM users WHERE username = $1", &[_][]const u8{username}) catch {};
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-01: RealmDeletionStatus roundtrip — pure unit test
// ---------------------------------------------------------------------------

test "TC-OIDC-15-01: RealmDeletionStatus roundtrip" {
    try testing.expectEqual(realm_deletion.RealmDeletionStatus.ACTIVE, realm_deletion.RealmDeletionStatus.fromString("ACTIVE").?);
    try testing.expectEqual(realm_deletion.RealmDeletionStatus.MARKED_FOR_DELETION, realm_deletion.RealmDeletionStatus.fromString("MARKED_FOR_DELETION").?);
    try testing.expectEqual(realm_deletion.RealmDeletionStatus.DELETING, realm_deletion.RealmDeletionStatus.fromString("DELETING").?);
    try testing.expectEqual(realm_deletion.RealmDeletionStatus.DELETED, realm_deletion.RealmDeletionStatus.fromString("DELETED").?);
    try testing.expectEqual(@as(?realm_deletion.RealmDeletionStatus, null), realm_deletion.RealmDeletionStatus.fromString("UNKNOWN"));
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-02: GRACE_PERIOD_DEFAULT_SECONDS is 7 days — pure unit test
// ---------------------------------------------------------------------------

test "TC-OIDC-15-02: GRACE_PERIOD_DEFAULT_SECONDS is 7 days" {
    try testing.expectEqual(@as(u64, 604800), realm_deletion.GRACE_PERIOD_DEFAULT_SECONDS);
    try testing.expectEqual(@as(u64, 7 * 24 * 60 * 60), realm_deletion.GRACE_PERIOD_DEFAULT_SECONDS);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-03: insertDeletionTracker creates tracker row
// ---------------------------------------------------------------------------

test "TC-OIDC-15-03: insertDeletionTracker creates tracker row" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id = "kc-oidc15-03-realm";
    const actor_id = try randomActorId(alloc);
    defer alloc.free(actor_id);
    const now: i64 = 1700000000; // Fixed test timestamp

    cleanupDeletionTracker(&pool, realm_id);
    defer cleanupDeletionTracker(&pool, realm_id);

    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id,
        .actor_id = actor_id,
        .reason = "TC-OIDC-15-03 test deletion",
        .grace_period_seconds = 3600, // 1 hour for testing
    }, now);

    // Verify the row was created.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT status, marked_by::text, reason FROM realm_deletion_tracker WHERE realm_id = $1",
        &[_][]const u8{realm_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expectEqualStrings("MARKED_FOR_DELETION", row[0] orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(actor_id, row[1] orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("TC-OIDC-15-03 test deletion", row[2] orelse return error.TestUnexpectedResult);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-04: insertDeletionTracker is idempotent on conflict
// ---------------------------------------------------------------------------

test "TC-OIDC-15-04: insertDeletionTracker idempotent on conflict" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id = "kc-oidc15-04-realm";
    const actor_id = try randomActorId(alloc);
    defer alloc.free(actor_id);
    const now: i64 = 1700000000;

    cleanupDeletionTracker(&pool, realm_id);
    defer cleanupDeletionTracker(&pool, realm_id);

    // First call should succeed.
    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id,
        .actor_id = actor_id,
        .reason = "first attempt",
        .grace_period_seconds = 3600,
    }, now);

    // Second call should also succeed (ON CONFLICT DO NOTHING).
    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id,
        .actor_id = actor_id,
        .reason = "second attempt (should be ignored)",
        .grace_period_seconds = 7200,
    }, now);

    // Verify only one row exists.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const count_row = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM realm_deletion_tracker WHERE realm_id = $1",
        &[_][]const u8{realm_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, count_row);

    const count_raw = count_row[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(u32, count_raw, 10);
    try testing.expectEqual(@as(u32, 1), count);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-05: releaseTenantBinding clears idp_realm_id
// ---------------------------------------------------------------------------

test "TC-OIDC-15-05: releaseTenantBinding clears idp_realm_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_slug = "tc-oidc15-05-tenant";
    const realm_id = "kc-oidc15-05-realm";

    cleanupTenantBySlug(&pool, tenant_slug);
    defer cleanupTenantBySlug(&pool, tenant_slug);

    // Create a tenant with a realm binding.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, 'test', $4::uuid)
            \\ON CONFLICT (slug) DO UPDATE
            \\SET idp_realm_id = EXCLUDED.idp_realm_id,
            \\    updated_at = NOW()
        , &[_][]const u8{ tenant_slug, "OIDC15 Tenant 05", realm_id, "00000000-0000-0000-0000-000000000000" });
    }

    // Release the binding.
    try realm_deletion.releaseTenantBinding(alloc, &pool, realm_id);

    // Verify the binding was cleared.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT idp_realm_id FROM public.tenant WHERE slug = $1",
        &[_][]const u8{tenant_slug},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expect(row[0] == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-06: markTrackerDeleted updates status to DELETED
// ---------------------------------------------------------------------------

test "TC-OIDC-15-06: markTrackerDeleted updates status to DELETED" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id = "kc-oidc15-06-realm";
    const now: i64 = 1700000000;

    cleanupDeletionTracker(&pool, realm_id);
    defer cleanupDeletionTracker(&pool, realm_id);

    const actor_id = try randomActorId(alloc);
    defer alloc.free(actor_id);

    // Insert a tracker row.
    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id,
        .actor_id = actor_id,
        .reason = "TC-OIDC-15-06",
        .grace_period_seconds = 3600,
    }, now);

    // Mark as deleted.
    try realm_deletion.markTrackerDeleted(alloc, &pool, realm_id, now);

    // Verify status.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT status, hard_deleted_at::text FROM realm_deletion_tracker WHERE realm_id = $1",
        &[_][]const u8{realm_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expectEqualStrings("DELETED", row[0] orelse return error.TestUnexpectedResult);
    try testing.expect(row[1] != null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-07: markUsersInactiveByRealm updates affected OIDC users
// ---------------------------------------------------------------------------

test "TC-OIDC-15-07: markUsersInactiveByRealm updates affected OIDC users" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id = "kc-oidc15-07-realm";
    const username = "tc-oidc15-07-user";

    cleanupUserByRealm(&pool, realm_id);
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByRealm(&pool, realm_id);
    defer cleanupUserByUsername(&pool, username);

    // Create an OIDC user with this realm.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        const tenant_a = try randomActorId(alloc);
        defer alloc.free(tenant_a);

        try conn.exec(
            \\INSERT INTO users (id, tenant_id, username, display_name, email,
            \\                   external_realm, external_id, auth_source,
            \\                   password_hash, status, is_active)
            \\VALUES (gen_random_uuid(), $1::uuid, $2, $3, $4, $5, $6, 'oidc',
            \\        '__OIDC_ONLY__', 'ACTIVE', true)
        , &[_][]const u8{ tenant_a, username, "OIDC15 User 07", "oidc15-07@example.com", realm_id, "sub-oidc15-07" });
    }

    // Mark users as inactive.
    try realm_deletion.markUsersInactiveByRealm(alloc, &pool, realm_id);

    // Verify the user was marked inactive.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT status, is_active FROM users WHERE username = $1",
        &[_][]const u8{username},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expectEqualStrings("INACTIVE", row[0] orelse return error.TestUnexpectedResult);
    // is_active is BOOLEAN — PostgreSQL text output is 't' or 'f'.
    try testing.expectEqualStrings("f", row[1] orelse return error.TestUnexpectedResult);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-08: queryPendingHardDeletions returns eligible entries
// ---------------------------------------------------------------------------

test "TC-OIDC-15-08: queryPendingHardDeletions returns eligible entries" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id_past = "kc-oidc15-08-past";
    const realm_id_future = "kc-oidc15-08-future";
    const actor_id = try randomActorId(alloc);
    defer alloc.free(actor_id);

    cleanupDeletionTracker(&pool, realm_id_past);
    cleanupDeletionTracker(&pool, realm_id_future);
    defer cleanupDeletionTracker(&pool, realm_id_past);
    defer cleanupDeletionTracker(&pool, realm_id_future);

    const now: i64 = 1700000000;

    // Insert a past-due entry (grace period already elapsed).
    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id_past,
        .actor_id = actor_id,
        .reason = "past due",
        .grace_period_seconds = 0, // Immediate.
    }, now - 3600); // Marked 1 hour ago.

    // Insert a future entry (grace period not yet elapsed).
    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id_future,
        .actor_id = actor_id,
        .reason = "future",
        .grace_period_seconds = 86400, // 24 hours.
    }, now);

    // Query pending deletions.
    const pending = try realm_deletion.queryPendingHardDeletions(alloc, &pool);
    defer {
        for (pending) |*entry| entry.deinit(alloc);
        alloc.free(pending);
    }

    // At least the past-due entry should be returned.
    try testing.expect(pending.len >= 1);

    var found_past = false;
    for (pending) |entry| {
        if (std.mem.eql(u8, entry.realm_id, realm_id_past)) {
            found_past = true;
            try testing.expectEqual(realm_deletion.RealmDeletionStatus.MARKED_FOR_DELETION, entry.status);
        }
    }
    try testing.expect(found_past);
}

// ---------------------------------------------------------------------------
// TC-OIDC-15-09: incrementRetryCount increments retry counter
// ---------------------------------------------------------------------------

test "TC-OIDC-15-09: incrementRetryCount increments retry counter" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_id = "kc-oidc15-09-realm";
    const now: i64 = 1700000000;

    cleanupDeletionTracker(&pool, realm_id);
    defer cleanupDeletionTracker(&pool, realm_id);

    const actor_id = try randomActorId(alloc);
    defer alloc.free(actor_id);

    try realm_deletion.insertDeletionTracker(alloc, &pool, .{
        .realm_id = realm_id,
        .actor_id = actor_id,
        .reason = "TC-OIDC-15-09",
        .grace_period_seconds = 3600,
    }, now);

    // Increment retry count twice.
    try realm_deletion.incrementRetryCount(alloc, &pool, realm_id);
    try realm_deletion.incrementRetryCount(alloc, &pool, realm_id);

    // Verify retry count.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT retry_count::text, last_retry_at::text FROM realm_deletion_tracker WHERE realm_id = $1",
        &[_][]const u8{realm_id},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const retry_count_raw = row[0] orelse return error.TestUnexpectedResult;
    const retry_count = try std.fmt.parseInt(u32, retry_count_raw, 10);
    try testing.expectEqual(@as(u32, 2), retry_count);
    try testing.expect(row[1] != null); // last_retry_at should be set.
}
