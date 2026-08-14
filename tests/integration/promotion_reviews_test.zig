//! Integration tests for PRM-04 (promotion_reviews table state machine).
//!
//! Covers:
//!   PRM-04 AC1  — pending_review -> approved/rejected transitions
//!   PRM-04 AC2  — partial unique index on (tenant_id, plan_digest) WHERE active
//!   PRM-04 AC3  — approved -> failed transition (assertion rerun failure)
//!   PRM-04 AC4  — approved -> applied transition
//!   PRM-04 AC5  — superseded transitions (applied/failed/rejected -> superseded)
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).

const std = @import("std");
const portable_env = @import("env");
const build_options = @import("build_options");

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const promotion_review = bpm.promotion_review_mod;

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => |e| return e,
    };
}

/// Insert a promotion_reviews row directly via SQL for test setup.
fn insertPendingReview(
    conn: *bpm.pg.Conn,
    tenant_id: []const u8,
    review_id: []const u8,
    plan_digest: []const u8,
    requested_by: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\  (id, tenant_id, plan_digest, def_type, def_id, serialised_plan,
        \\   status, requested_by, row_version, created_at, updated_at)
        \\VALUES (::uuid, ::uuid, , 'process', , '[]',
        \\        'pending_review', ::uuid, 1, NOW(), NOW())
    ,
        &[_][]const u8{ review_id, tenant_id, plan_digest, review_id, requested_by },
    );
}

/// Insert a promotion_reviews row in approved status.
fn insertApprovedReview(
    conn: *bpm.pg.Conn,
    tenant_id: []const u8,
    review_id: []const u8,
    plan_digest: []const u8,
    requested_by: []const u8,
    approved_by: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\  (id, tenant_id, plan_digest, def_type, def_id, serialised_plan,
        \\   status, requested_by, approved_by, approved_at, row_version,
        \\   created_at, updated_at)
        \\VALUES (::uuid, ::uuid, , 'process', , '[]',
        \\        'approved', ::uuid, ::uuid, NOW(), 2, NOW(), NOW())
    ,
        &[_][]const u8{ review_id, tenant_id, plan_digest, review_id, requested_by, approved_by },
    );
}

/// Insert a promotion_reviews row in rejected status.
fn insertRejectedReview(
    conn: *bpm.pg.Conn,
    tenant_id: []const u8,
    review_id: []const u8,
    plan_digest: []const u8,
    requested_by: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\  (id, tenant_id, plan_digest, def_type, def_id, serialised_plan,
        \\   status, requested_by, row_version, created_at, updated_at)
        \\VALUES (::uuid, ::uuid, , 'process', , '[]',
        \\        'rejected', ::uuid, 2, NOW(), NOW())
    ,
        &[_][]const u8{ review_id, tenant_id, plan_digest, review_id, requested_by },
    );
}

/// Fetch status and row_version of a review.
fn getReviewStatus(pool: *Pool, review_id: []const u8) !struct { status: []const u8, row_version: u32 } {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        std.testing.allocator,
        \\SELECT status, row_version::text FROM promotion_reviews WHERE id = ::uuid
    ,
        &.{review_id},
    );
    defer {
        for (row.?) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(row.?);
    }
    const status = row.?[0] orelse "missing";
    const rv_str = row.?[1] orelse "0";
    const row_version = std.fmt.parseInt(u32, rv_str, 10) catch 0;
    return .{ .status = status, .row_version = row_version };
}

// ── Test cases ────────────────────────────────────────────────────────────────

test "promotion_reviews: prm04_insert_pending_review" {
    // GIVEN no promotion_reviews rows exist for this tenant,
    // WHEN a plan is submitted and inserted,
    // THEN the row is created with status = pending_review and row_version = 1.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const user_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(user_id);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertPendingReview(h.conn, tenant_id, review_id, digest, user_id);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("pending_review", result.status);
    try std.testing.expectEqual(@as(u32, 1), result.row_version);
}

test "promotion_reviews: prm04_approve_review" {
    // GIVEN a review in pending_review,
    // WHEN approveReview transitions it to approved,
    // THEN status becomes approved with approved_by and approved_at set and row_version = 2.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const approver = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertPendingReview(h.conn, tenant_id, review_id, digest, requested_by);
    try promotion_review.approveReview(std.testing.allocator, h.pool, review_id, approver, 1);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("approved", result.status);
    try std.testing.expectEqual(@as(u32, 2), result.row_version);

    const conn = try h.pool.acquire();
    defer h.pool.release(conn);
    const row = try conn.queryRow(std.testing.allocator,
        \\SELECT approved_by::text FROM promotion_reviews WHERE id = ::uuid
    , &.{review_id});
    defer {
        for (row.?) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(row.?);
    }
    try std.testing.expectEqualStrings(approver, row.?[0] orelse "");
}

test "promotion_reviews: prm04_reject_review" {
    // GIVEN a review in pending_review,
    // WHEN rejectReview transitions it to rejected,
    // THEN status becomes rejected with no approved_by/approved_at set and row_version = 2.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertPendingReview(h.conn, tenant_id, review_id, digest, requested_by);
    try promotion_review.rejectReview(std.testing.allocator, h.pool, review_id, 1);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("rejected", result.status);
    try std.testing.expectEqual(@as(u32, 2), result.row_version);

    const conn = try h.pool.acquire();
    defer h.pool.release(conn);
    const row = try conn.queryRow(std.testing.allocator,
        \\SELECT approved_by::text, approved_at::text FROM promotion_reviews WHERE id = ::uuid
    , &.{review_id});
    defer {
        for (row.?) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(row.?);
    }
    try std.testing.expect(row.?[0] == null);
    try std.testing.expect(row.?[1] == null);
}

test "promotion_reviews: prm04_duplicate_review_unique_index" {
    // GIVEN a live review for (tenant_id, plan_digest) in pending_review,
    // WHEN a second submission produces the same digest,
    // THEN the platform returns DuplicateReview from the partial unique index.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id_1 = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id_1);
    const review_id_2 = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id_2);
    const user_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(user_id);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertPendingReview(h.conn, tenant_id, review_id_1, digest, user_id);

    const result = promotion_review.submitReview(std.testing.allocator, h.pool, .{
        .tenant_id = tenant_id,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "test-def",
        .serialised_plan = "[]",
        .requested_by = user_id,
    });

    try std.testing.expectError(promotion_review.ReviewTransitionError.DuplicateReview, result);
}

test "promotion_reviews: prm04_mark_review_failed" {
    // GIVEN a review in approved,
    // WHEN assertion re-run fails and markReviewFailed is called,
    // THEN status becomes failed and row_version = 3.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const approver = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertApprovedReview(h.conn, tenant_id, review_id, digest, requested_by, approver);
    try promotion_review.markReviewFailed(std.testing.allocator, h.pool, review_id, 2);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("failed", result.status);
    try std.testing.expectEqual(@as(u32, 3), result.row_version);
}

test "promotion_reviews: prm04_mark_review_applied" {
    // GIVEN a review in approved,
    // WHEN markReviewApplied is called after successful assertion re-run,
    // THEN status becomes applied and row_version = 3.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const approver = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertApprovedReview(h.conn, tenant_id, review_id, digest, requested_by, approver);
    try promotion_review.markReviewApplied(std.testing.allocator, h.pool, review_id, 2);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("applied", result.status);
    try std.testing.expectEqual(@as(u32, 3), result.row_version);
}

test "promotion_reviews: prm04_supersede_review" {
    // GIVEN a review in applied,
    // WHEN supersedeReview is called with a superseding_review_id,
    // THEN status becomes superseded with superseded_by set and row_version = 4.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const superseding_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(superseding_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const approver = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertApprovedReview(h.conn, tenant_id, review_id, digest, requested_by, approver);
    try promotion_review.markReviewApplied(std.testing.allocator, h.pool, review_id, 2);
    try promotion_review.supersedeReview(std.testing.allocator, h.pool, review_id, superseding_id, 3);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("superseded", result.status);
    try std.testing.expectEqual(@as(u32, 4), result.row_version);

    const conn = try h.pool.acquire();
    defer h.pool.release(conn);
    const row = try conn.queryRow(std.testing.allocator,
        \\SELECT superseded_by::text FROM promotion_reviews WHERE id = ::uuid
    , &.{review_id});
    defer {
        for (row.?) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(row.?);
    }
    try std.testing.expectEqualStrings(superseding_id, row.?[0] orelse "");
}

test "promotion_reviews: prm04_invalid_transition_rejected" {
    // GIVEN a review in rejected,
    // WHEN supersedeReview is called with a superseding_review_id,
    // THEN rejected -> superseded edge is permitted (NEW edge per PRM-04 AC4 note).
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const superseding_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(superseding_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertRejectedReview(h.conn, tenant_id, review_id, digest, requested_by);
    try promotion_review.supersedeReview(std.testing.allocator, h.pool, review_id, superseding_id, 2);

    const result = try getReviewStatus(h.pool, review_id);
    try std.testing.expectEqualStrings("superseded", result.status);
    try std.testing.expectEqual(@as(u32, 3), result.row_version);
}

test "promotion_reviews: prm04_optimistic_locking" {
    // GIVEN a review in pending_review with row_version = 1,
    // WHEN two concurrent approve requests both use row_version = 1,
    // THEN only one succeeds and the other gets InvalidReviewTransition.
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(tenant_id);
    const review_id = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(review_id);
    const requested_by = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(requested_by);
    const approver1 = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver1);
    const approver2 = try h.newUuidString(std.testing.allocator);
    defer std.testing.allocator.free(approver2);
    const digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    try insertPendingReview(h.conn, tenant_id, review_id, digest, requested_by);

    try promotion_review.approveReview(std.testing.allocator, h.pool, review_id, approver1, 1);

    const second_result = promotion_review.approveReview(std.testing.allocator, h.pool, review_id, approver2, 1);
    try std.testing.expectError(promotion_review.ReviewTransitionError.InvalidReviewTransition, second_result);
}
