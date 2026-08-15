//! Integration tests for PRM-04 (promotion_reviews table state machine).
//!
//! Umbrella-wired binary (runs as part of `zig build test-integration`).
//! Covers:
//!   PRM-04 AC1  — pending_review -> approved/rejected transitions
//!   PRM-04 AC2  — partial unique index on (tenant_id, plan_digest) WHERE active
//!   PRM-04 AC3  — approved -> failed transition (assertion rerun failure)
//!   PRM-04 AC4  — approved -> applied transition + DEFINITION_PROMOTION_APPLIED event
//!   PRM-04 AC5  — CHECK constraint + invalid transition rejected
//!
//! Uses helpers.TestHarness (provisions tenant_default, holds the cross-binary
//! advisory lock for its lifetime) plus a local pool that routes through the
//! default tenant. All transitions use the rework-1 signatures (tenant_id +
//! actor_id). Fixtures are created through the pool (committed) and cleaned up
//! via `defer`; the harness transaction is rolled back on deinit.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const promotion_review = bpm.promotion_review_mod;
const digest_mod = bpm.promotion_digest_mod;
const plan_mod = bpm.promotion_plan_mod;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// DB URL + pool helpers
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — promotion_reviews integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    api_tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]const u8 {
    return helpers.uuidBytesToString(allocator, helpers.randomUuidBytes());
}

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

/// Build a one-entry PromotionPlan whose entries array lives in the CALLER's
/// frame (written into `entries_buf`), so the returned plan never holds a
/// slice into this function's own stack (which would dangle on return).
fn planWithNode(id: []const u8, entries_buf: *[1]plan_mod.PlanEntry) plan_mod.PromotionPlan {
    entries_buf[0] = .{
        .type = .graph_node,
        .id = id,
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    return plan_mod.PromotionPlan{
        .entries = entries_buf[0..],
        .human_readable = "PRM-04 umbrella test",
    };
}

fn submitTestReview(allocator: std.mem.Allocator, pool: *Pool, requester: []const u8) ![]const u8 {
    // Random node id -> unique plan digest per run (fixture isolation: the
    // partial unique index on (tenant_id, plan_digest) forbids reusing a
    // deterministic digest on the shared default tenant).
    const node_id = try randomUuidStr(allocator);
    defer allocator.free(node_id);
    var entries_buf: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries_buf);
    const digest = digest_mod.computePlanDigest(allocator, plan);
    defer allocator.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(allocator, plan);
    defer allocator.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    return promotion_review.submitReview(allocator, pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-umbrella-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
}

fn cleanupEventByKey(pool: *Pool, allocator: std.mem.Allocator, event_type: []const u8, review_id: []const u8) void {
    const key = std.fmt.allocPrint(allocator, "{s}-{s}", .{ event_type, review_id }) catch return;
    defer allocator.free(key);
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{key}) catch {};
    conn.exec("DELETE FROM plat_event_idempotency WHERE idempotency_key = $1", &.{key}) catch {};
}

fn cleanupReview(pool: *Pool, review_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM promotion_assertion_runs WHERE review_id = $1::uuid", &.{review_id}) catch {};
    conn.exec("DELETE FROM promotion_reviews WHERE id = $1::uuid", &.{review_id}) catch {};
}

fn getReviewStatus(pool: *Pool, allocator: std.mem.Allocator, review_id: []const u8) !struct { status: []const u8, row_version: u32 } {
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review = try promotion_review.getReview(allocator, pool, review_id);
    if (review == null) return .{ .status = "missing", .row_version = 0 };
    const r = review.?;
    defer {
        allocator.free(r.id);
        allocator.free(r.tenant_id);
        allocator.free(r.plan_digest);
        allocator.free(r.def_type);
        allocator.free(r.def_id);
        allocator.free(r.serialised_plan);
        allocator.free(r.requested_by);
        if (r.approved_by) |v| allocator.free(v);
        if (r.superseded_by) |v| allocator.free(v);
    }
    const status = switch (r.status) {
        .pending_review => "pending_review",
        .approved => "approved",
        .rejected => "rejected",
        .applied => "applied",
        .failed => "failed",
        .superseded => "superseded",
    };
    return .{ .status = status, .row_version = r.row_version };
}

fn countEventByKey(pool: *Pool, allocator: std.mem.Allocator, event_type: []const u8, review_id: []const u8) !i64 {
    const key = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ event_type, review_id });
    defer allocator.free(key);
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(allocator, "SELECT COUNT(*)::text FROM events WHERE event_type = $1 AND idempotency_key = $2", &.{ event_type, key });
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0].?, 10) catch 0;
}

// ---------------------------------------------------------------------------
// PRM-04 AC1 — pending_review -> approved
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_approve_review" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupReview(&pool, review_id);

    try promotion_review.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);

    const result = try getReviewStatus(&pool, alloc, review_id);
    try std.testing.expectEqualStrings("approved", result.status);
    try std.testing.expectEqual(@as(u32, 2), result.row_version);
}

// ---------------------------------------------------------------------------
// PRM-04 AC1 — pending_review -> rejected
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_reject_review" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    try promotion_review.rejectReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, 1);

    const result = try getReviewStatus(&pool, alloc, review_id);
    try std.testing.expectEqualStrings("rejected", result.status);
    try std.testing.expectEqual(@as(u32, 2), result.row_version);
}

// ---------------------------------------------------------------------------
// PRM-04 AC2 — partial unique index -> DuplicateReview
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_duplicate_review_unique_index" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    // One random plan/digest shared by both submissions.
    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries_buf: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries_buf);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    // First submission.
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id_1 = try promotion_review.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-umbrella-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id_1);
    defer cleanupReview(&pool, review_id_1);

    // Second submission with the same plan/digest -> DuplicateReview.
    const result = promotion_review.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-umbrella-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    try std.testing.expectError(promotion_review.ReviewTransitionError.DuplicateReview, result);
}

// ---------------------------------------------------------------------------
// PRM-04 AC3 — approved -> failed
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_mark_review_failed" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupReview(&pool, review_id);

    try promotion_review.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try promotion_review.markReviewFailed(alloc, &pool, review_id, DEFAULT_TENANT_ID, 2);

    const result = try getReviewStatus(&pool, alloc, review_id);
    try std.testing.expectEqualStrings("failed", result.status);
    try std.testing.expectEqual(@as(u32, 3), result.row_version);
}

// ---------------------------------------------------------------------------
// PRM-04 AC4 — approved -> applied + DEFINITION_PROMOTION_APPLIED event
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_mark_review_applied" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPLIED", review_id);
    defer cleanupReview(&pool, review_id);

    try promotion_review.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try promotion_review.markReviewApplied(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 2);

    const result = try getReviewStatus(&pool, alloc, review_id);
    try std.testing.expectEqualStrings("applied", result.status);
    try std.testing.expectEqual(@as(u32, 3), result.row_version);

    // AC4: the apply event is appended in the same transaction.
    const ev = try countEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPLIED", review_id);
    try std.testing.expectEqual(@as(i64, 1), ev);
}

// ---------------------------------------------------------------------------
// PRM-04 AC5 — CHECK constraint rejects an invalid status at the DB
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_check_constraint_rejects_invalid_status" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const conn = try pool.acquire();
    defer pool.release(conn);

    const insert_result = conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, plan_digest, def_type, def_id, serialised_plan, status, requested_by, row_version)
        \\VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, 'invalid_status', $7::uuid, 1)
    ,
        &[_][]const u8{
            def_id,
            DEFAULT_TENANT_ID,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "process",
            "prm04-umbrella-proc",
            "[]",
            requester,
        },
    );
    // The pool Conn wraps pg errors as QueryFailed; the SQLSTATE still says
    // 23514 (check_violation).
    try std.testing.expectError(error.QueryFailed, insert_result);
    try std.testing.expect(conn.lastSqlState() != null);
    if (conn.lastSqlState()) |code| {
        try std.testing.expectEqualStrings("23514", code); // check_violation
    }
}

// ---------------------------------------------------------------------------
// PRM-04 AC5 — invalid transition rejected (pending_review -> applied)
// ---------------------------------------------------------------------------

test "promotion_reviews: prm04_invalid_transition_rejected" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const actor = try randomUuidStr(alloc);
    defer alloc.free(actor);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    // Applying directly from pending_review is outside the edge set.
    const result = promotion_review.markReviewApplied(alloc, &pool, review_id, DEFAULT_TENANT_ID, actor, 1);
    try std.testing.expectError(promotion_review.ReviewTransitionError.InvalidReviewTransition, result);

    const status = try getReviewStatus(&pool, alloc, review_id);
    try std.testing.expectEqualStrings("pending_review", status.status);
}
