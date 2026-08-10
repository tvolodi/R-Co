//! Integration tests for OIDC-34 migration helper candidate enumeration.
//!
//! Requirement: OIDC-34 [SHOULD]
//!
//! DIRECTIVE T-1: Uses real PostgreSQL via BPM_TEST_DB_URL.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const migration_helper = @import("oidc_migration_helper");
const pg = @import("pg");
const helpers = @import("helpers.zig");

const pool_mod = bpm.db_pool;

// GH-512 retention: doc-identity fixture (matched against substring assertions in payload/correlation_id checks)
const tenant_a = "11111111-1111-1111-1111-111111111111";
// GH-512 retention: doc-identity fixture (matched against substring assertions in payload/correlation_id checks)
const tenant_b = "22222222-2222-2222-2222-222222222222";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

/// ISS-0659 / GH-681: self-managed-pool binary must serialize against
/// TestHarness peers via the bpm_test_migrations_public advisory lock for the
/// binary's full lifetime. PR #494 / ISS-0162 extended this lock inside
/// TestHarness.init(); this entry point lets a makePool-based binary acquire
/// the same lock around its own test block. Pair with
/// `helpers.releaseIntegrationLock(&lock_conn)` via defer at the top of every
/// `test` block.
fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

fn cleanupUserByUsername(pool: *pool_mod.Pool, username: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM users
        \\WHERE username = $1
    , &[_][]const u8{username}) catch {};
}

fn insertInternalUser(pool: *pool_mod.Pool, username: []const u8, email: []const u8, tenant_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, $3, '', TRUE, $4, 'ACTIVE')
    , &[_][]const u8{ tenant_id, email, username, username });
}

fn userExistsInCandidates(candidates: []const migration_helper.UnlinkedUserCandidate, username: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.username, username)) return true;
    }
    return false;
}

fn freeCandidates(allocator: std.mem.Allocator, candidates: []migration_helper.UnlinkedUserCandidate) void {
    for (candidates) |candidate| candidate.deinit(allocator);
    allocator.free(candidates);
}

test "TC-OIDC-34-01: listUnlinkedInternalUsers returns internal users without external linkage" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-oidc34-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    try insertInternalUser(&pool, username, "tc-oidc34-01@example.com", tenant_a);

    const candidates = try migration_helper.listUnlinkedInternalUsers(alloc, &pool, .{ .page_size = 200 });
    defer freeCandidates(alloc, candidates);

    try testing.expect(userExistsInCandidates(candidates, username));
}

test "TC-OIDC-34-02: listUnlinkedInternalUsers excludes agent-prefixed usernames" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "agent-tc-oidc34-02";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    try insertInternalUser(&pool, username, "tc-oidc34-02@example.com", tenant_a);

    const candidates = try migration_helper.listUnlinkedInternalUsers(alloc, &pool, .{ .page_size = 200 });
    defer freeCandidates(alloc, candidates);

    try testing.expect(!userExistsInCandidates(candidates, username));
}

test "TC-OIDC-34-03: tenant filter scopes candidate list" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const user_a = "tc-oidc34-03-user-a";
    const user_b = "tc-oidc34-03-user-b";

    cleanupUserByUsername(&pool, user_a);
    cleanupUserByUsername(&pool, user_b);
    defer cleanupUserByUsername(&pool, user_a);
    defer cleanupUserByUsername(&pool, user_b);

    try insertInternalUser(&pool, user_a, "tc-oidc34-03-a@example.com", tenant_a);
    try insertInternalUser(&pool, user_b, "tc-oidc34-03-b@example.com", tenant_b);

    const scoped = try migration_helper.listUnlinkedInternalUsers(alloc, &pool, .{
        .tenant_id = tenant_a,
        .page_size = 200,
    });
    defer freeCandidates(alloc, scoped);

    try testing.expect(userExistsInCandidates(scoped, user_a));
    try testing.expect(!userExistsInCandidates(scoped, user_b));

    // Sanity check user B really exists in the database and was not filtered out by setup mistakes.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM users WHERE username = $1",
        &[_][]const u8{user_b},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    const count_raw = row[0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(u32, count_raw, 10);
    try testing.expectEqual(@as(u32, 1), count);
}
