//! Integration tests for PRM-04: promotion review state machine.
//!
//! Covers every MUST acceptance criterion of PRM-04:
//!   AC1 — pending_review -> approved sets approved_by/approved_at; any other
//!         source status -> HTTP 400 InvalidReviewTransition
//!   AC2 — live review for (tenant_id, plan_digest); second same-digest submit
//!         -> DuplicateReview (partial unique index)
//!   AC3 — approved -> failed on assertion re-run failure
//!   AC4 — approved -> applied with DEFINITION_PROMOTION_APPLIED appended in
//!         the same transaction
//!   AC5 — transitions outside the edge set rejected by CHECK at the DB and
//!         with HTTP 400 at the API
//!
//! Tenant strategy: all reviews route through the default tenant (all-zeros
//! UUID -> tenant_default, provisioned by helpers.ensureSchemaReady). The
//! rework-1 signatures are used throughout: approveReview/rejectReview/
//! markReviewApplied/markReviewFailed/supersedeReview take an explicit
//! tenant_id (markReviewApplied also actor_id). Every test uses random UUIDs
//! and cleans up via `defer`. No error.SkipZigTest on MUST requirements.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm04-review-sm`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const review_mod = bpm.promotion_review_mod;
const digest_mod = bpm.promotion_digest_mod;
const plan_mod = bpm.promotion_plan_mod;
const review_routes = bpm.promotion_review_routes;
const auth = bpm.api_auth;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// DB URL + pool helpers
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-04 integration tests FAILED (env var required)\n", .{});
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
        .human_readable = "PRM-04 state machine test",
    };
}

/// Submit a pending review under the default tenant; returns the review_id.
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
    return review_mod.submitReview(allocator, pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-proc",
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

fn freeReviewRecord(allocator: std.mem.Allocator, r: *const review_mod.ReviewRecord) void {
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

fn getReviewOrFail(allocator: std.mem.Allocator, pool: *Pool, review_id: []const u8) review_mod.ReviewRecord {
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review = review_mod.getReview(allocator, pool, review_id) catch |err| {
        std.debug.print("getReview failed: {}\n", .{err});
        @panic("getReview failed in test");
    };
    if (review == null) @panic("review not found");
    return review.?;
}

// ---------------------------------------------------------------------------
// TC-PRM-04-01: pending_review → approved
// ---------------------------------------------------------------------------

test "TC-PRM-04-01: pending_review transitions to approved with approved_by and approved_at" {
    try helpers.ensureSchemaReady(testing.allocator);
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

    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .approved);
    try testing.expectEqual(@as(u32, 2), r.row_version);
    try testing.expect(r.approved_by != null);
    try testing.expectEqualStrings(approver, r.approved_by.?);
    try testing.expect(r.approved_at != null);

    // AC1/PRM-04 event: DEFINITION_PROMOTION_APPROVED appended.
    const ev = try countEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    try testing.expectEqual(@as(i64, 1), ev);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-02: pending_review → rejected
// ---------------------------------------------------------------------------

test "TC-PRM-04-02: pending_review transitions to rejected" {
    try helpers.ensureSchemaReady(testing.allocator);
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

    try review_mod.rejectReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, 1);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .rejected);
    try testing.expectEqual(@as(u32, 2), r.row_version);
    try testing.expect(r.approved_by == null);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-03: second same-digest submit → DuplicateReview (AC2)
// ---------------------------------------------------------------------------

test "TC-PRM-04-03: second submit with the same digest returns DuplicateReview" {
    try helpers.ensureSchemaReady(testing.allocator);
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
    const review_id_1 = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id_1);
    defer cleanupReview(&pool, review_id_1);

    // Second submission with the same plan/digest -> DuplicateReview.
    const result = review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    try testing.expectError(review_mod.ReviewTransitionError.DuplicateReview, result);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-04: approved → applied with DEFINITION_PROMOTION_APPLIED event (AC4)
// ---------------------------------------------------------------------------

test "TC-PRM-04-04: approved transitions to applied and appends the apply event" {
    try helpers.ensureSchemaReady(testing.allocator);
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

    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try review_mod.markReviewApplied(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 2);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .applied);
    try testing.expectEqual(@as(u32, 3), r.row_version);

    // AC4: DEFINITION_PROMOTION_APPLIED appended in the same transaction.
    const ev = try countEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPLIED", review_id);
    try testing.expectEqual(@as(i64, 1), ev);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-05: approved → failed (AC3)
// ---------------------------------------------------------------------------

test "TC-PRM-04-05: approved transitions to failed on assertion re-run failure" {
    try helpers.ensureSchemaReady(testing.allocator);
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

    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, review_id, DEFAULT_TENANT_ID, 2);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .failed);
    try testing.expectEqual(@as(u32, 3), r.row_version);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-06: applied → superseded
// ---------------------------------------------------------------------------

test "TC-PRM-04-06: applied transitions to superseded" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);
    const superseding = try randomUuidStr(alloc);
    defer alloc.free(superseding);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPLIED", review_id);
    defer cleanupReview(&pool, review_id);

    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try review_mod.markReviewApplied(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 2);
    try review_mod.supersedeReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, superseding, 3);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .superseded);
    try testing.expectEqual(@as(u32, 4), r.row_version);
    try testing.expect(r.superseded_by != null);
    try testing.expectEqualStrings(superseding, r.superseded_by.?);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-07: failed → superseded
// ---------------------------------------------------------------------------

test "TC-PRM-04-07: failed transitions to superseded" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);
    const superseding = try randomUuidStr(alloc);
    defer alloc.free(superseding);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupReview(&pool, review_id);

    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, review_id, DEFAULT_TENANT_ID, 2);
    try review_mod.supersedeReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, superseding, 3);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .superseded);
    try testing.expectEqual(@as(u32, 4), r.row_version);
    try testing.expectEqualStrings(superseding, r.superseded_by.?);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-08: rejected → superseded
// ---------------------------------------------------------------------------

test "TC-PRM-04-08: rejected transitions to superseded" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const superseding = try randomUuidStr(alloc);
    defer alloc.free(superseding);

    const review_id = try submitTestReview(alloc, &pool, requester);
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    try review_mod.rejectReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, 1);
    try review_mod.supersedeReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, superseding, 2);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .superseded);
    try testing.expectEqual(@as(u32, 3), r.row_version);
    try testing.expectEqualStrings(superseding, r.superseded_by.?);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-09: invalid transition (pending_review → applied) returns error
// ---------------------------------------------------------------------------

test "TC-PRM-04-09: pending_review to applied directly returns InvalidReviewTransition" {
    try helpers.ensureSchemaReady(testing.allocator);
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

    const result = review_mod.markReviewApplied(alloc, &pool, review_id, DEFAULT_TENANT_ID, actor, 1);
    try testing.expectError(review_mod.ReviewTransitionError.InvalidReviewTransition, result);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
    try testing.expectEqual(@as(u32, 1), r.row_version);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-10: optimistic locking — stale row_version fails the transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-10: stale row_version causes the transition to fail" {
    try helpers.ensureSchemaReady(testing.allocator);
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
    defer cleanupReview(&pool, review_id);

    // Expected row_version is 2 but actual is 1 -> stale -> InvalidReviewTransition.
    const result = review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 2);
    try testing.expectError(review_mod.ReviewTransitionError.InvalidReviewTransition, result);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
    try testing.expectEqual(@as(u32, 1), r.row_version);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-11: CHECK constraint rejects an invalid status at the database (AC5)
// ---------------------------------------------------------------------------

test "TC-PRM-04-11: CHECK constraint rejects an invalid status value" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_uuid = try randomUuidStr(alloc);
    defer alloc.free(tenant_uuid);
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
            "prm04-proc-11",
            "[]",
            tenant_uuid,
        },
    );
    // The pool Conn wraps pg errors as QueryFailed; the SQLSTATE still says
    // 23514 (check_violation).
    try testing.expectError(error.QueryFailed, insert_result);
    try testing.expect(conn.lastSqlState() != null);
    if (conn.lastSqlState()) |code| {
        try testing.expectEqualStrings("23514", code); // check_violation
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-04-12: invalid transition rejected with HTTP 400 at the API (AC1/AC5)
// ---------------------------------------------------------------------------

test "TC-PRM-04-12: approve from a non-pending status returns HTTP 400 INVALID_REVIEW_TRANSITION" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Build the plan ourselves so the approve-body digest matches the stored one.
    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries_buf: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries_buf);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupReview(&pool, review_id);

    // Approve once -> status = approved.
    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{digest});
    defer alloc.free(body);

    const actor = auth.AuthContext{
        .user_id = approver,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm04-12",
        .principal = "test-token-prm04-12",
    };
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApproveReview(&pool, alloc, actor, review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);

    // Status unchanged (still approved).
    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .approved);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-13: getReview returns stored plan_digest and serialised_plan
// ---------------------------------------------------------------------------

test "TC-PRM-04-13: getReview returns stored plan_digest and serialised_plan" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    // Build and submit the plan ourselves so the stored digest is known.
    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries_buf: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries_buf);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm04-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    const r = getReviewOrFail(alloc, &pool, review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expectEqualStrings(digest, r.plan_digest);
    try testing.expectEqualStrings(serialised, r.serialised_plan);
    try testing.expectEqualStrings("process", r.def_type);
    try testing.expectEqualStrings("prm04-proc", r.def_id);
    try testing.expect(r.status == .pending_review);
}
