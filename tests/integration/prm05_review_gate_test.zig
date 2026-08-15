//! Integration tests for PRM-05: non-skippable human approval gate.
//!
//! Covers every MUST acceptance criterion of PRM-05:
//!   AC1 — apply with status != approved -> HTTP 400, no sandbox claimed
//!   AC2 — approve with principal == requested_by -> HTTP 403, stays pending_review
//!   AC3 — unrecognised body field on approve/apply -> HTTP 422; no skip field exists
//!   AC4 — no bypass mechanism on apply (structural: TC-01/02/03/08/13)
//!   AC5 — context response has stored plan + assertions[] + NEEDS_REVIEW
//!         package + plan_digest in one document
//!
//! Also covers PRM-03 AC2/AC3 through the gate (digest mismatch -> 409).
//!
//! Tenant strategy: reviews route through the default tenant (all-zeros UUID
//! -> tenant_default, provisioned by helpers.ensureSchemaReady). Handlers are
//! called with valid-UUID actors; the approver identity is server-derived
//! (INV-2) so actors only carry user_id/role. Every test uses random UUIDs
//! and cleans up via `defer`. No error.SkipZigTest on MUST requirements.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm05-review-gate`

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
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-05 integration tests FAILED (env var required)\n", .{});
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
        .human_readable = "PRM-05 gate test",
    };
}

/// Submit a pending review under the default tenant; returns review_id + digest.
fn submitPendingReview(
    allocator: std.mem.Allocator,
    pool: *Pool,
    requester: []const u8,
) !struct { review_id: []const u8, digest: []const u8 } {
    // Random node id -> unique plan digest per run (fixture isolation: the
    // partial unique index on (tenant_id, plan_digest) forbids reusing a
    // deterministic digest on the shared default tenant).
    const node_id = try randomUuidStr(allocator);
    defer allocator.free(node_id);
    var entries_buf: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries_buf);
    const digest = digest_mod.computePlanDigest(allocator, plan);
    const serialised = try digest_mod.serialisePlanCanonical(allocator, plan);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(allocator, pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm05-proc",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    allocator.free(serialised);
    return .{ .review_id = review_id, .digest = digest };
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

fn countAssertionRuns(pool: *Pool, allocator: std.mem.Allocator, review_id: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(allocator, "SELECT COUNT(*)::text FROM promotion_assertion_runs WHERE review_id = $1::uuid", &.{review_id});
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

fn actorFor(user_id: []const u8) auth.AuthContext {
    return auth.AuthContext{
        .user_id = user_id,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm05",
        .principal = "test-token-prm05",
    };
}

// ---------------------------------------------------------------------------
// TC-PRM-05-01: Apply blocked when review is pending_review (AC1)
// ---------------------------------------------------------------------------

test "TC-PRM-05-01: apply blocked when review is pending_review returns HTTP 400 and claims no sandbox" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(requester), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);

    // No sandbox claimed, status unchanged.
    const runs = try countAssertionRuns(&pool, alloc, fixture.review_id);
    try testing.expectEqual(@as(i64, 0), runs);
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-02: Apply blocked when review is rejected (AC1)
// ---------------------------------------------------------------------------

test "TC-PRM-05-02: apply blocked when review is rejected returns HTTP 400" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    try review_mod.rejectReview(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, 1);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(requester), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);
    const runs = try countAssertionRuns(&pool, alloc, fixture.review_id);
    try testing.expectEqual(@as(i64, 0), runs);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-03: Apply blocked when review is failed (AC1)
// ---------------------------------------------------------------------------

test "TC-PRM-05-03: apply blocked when review is failed returns HTTP 400" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", fixture.review_id);
    defer cleanupReview(&pool, fixture.review_id);

    try review_mod.approveReview(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, 2);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);
    const runs = try countAssertionRuns(&pool, alloc, fixture.review_id);
    try testing.expectEqual(@as(i64, 0), runs);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-04: Apply succeeds when review is approved with matching digest
// ---------------------------------------------------------------------------

test "TC-PRM-05-04: apply succeeds when review is approved with matching digest" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", fixture.review_id);
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPLIED", fixture.review_id);
    defer cleanupReview(&pool, fixture.review_id);

    try review_mod.approveReview(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, approver, 1);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .applied);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-05: Self-approval → HTTP 403, stays pending_review (AC2)
// ---------------------------------------------------------------------------

test "TC-PRM-05-05: self-approval returns HTTP 403 SELF_APPROVAL_FORBIDDEN and stays pending_review" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    // Actor == requested_by -> self-approval must be forbidden.
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApproveReview(&pool, alloc, actorFor(requester), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "SELF_APPROVAL_FORBIDDEN") != null);

    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-06: A different principal can approve (AC2 positive control)
// ---------------------------------------------------------------------------

test "TC-PRM-05-06: a different principal can approve the review" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", fixture.review_id);
    defer cleanupReview(&pool, fixture.review_id);

    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApproveReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .approved);
    try testing.expect(r.approved_by != null);
    try testing.expectEqualStrings(approver, r.approved_by.?);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-07: Reject does NOT enforce the self-approval restriction
// ---------------------------------------------------------------------------

test "TC-PRM-05-07: a submitter may reject their own review (no self-reject restriction)" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    // Actor == requested_by is allowed to reject.
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleRejectReview(&pool, alloc, actorFor(requester), fixture.review_id, "{}");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .rejected);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-08: Apply body with unknown field → HTTP 422 (AC3, no skip field)
// ---------------------------------------------------------------------------

test "TC-PRM-05-08: apply body with a skip-looking unknown field returns HTTP 422 UNKNOWN_FIELD" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", fixture.review_id);
    defer cleanupReview(&pool, fixture.review_id);

    try review_mod.approveReview(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, approver, 1);

    // Unknown field intended to bypass the gate -> 422 UNKNOWN_FIELD.
    const body = try std.fmt.allocPrint(alloc,
        \\{{"plan_digest":"{s}","skip_approval":true}}
    , .{fixture.digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "UNKNOWN_FIELD") != null);

    // No transition happened.
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .approved);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-09: Approve body with unknown field → HTTP 422 (AC3, INV-2)
// ---------------------------------------------------------------------------

test "TC-PRM-05-09: approve body with an approved_by field returns HTTP 422 UNKNOWN_FIELD" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    // INV-2: the approver identity is server-derived — a supplied approved_by is
    // an unknown field and must be rejected with 422.
    const body = try std.fmt.allocPrint(alloc,
        \\{{"plan_digest":"{s}","approved_by":"{s}"}}
    , .{ fixture.digest, approver });
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApproveReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "UNKNOWN_FIELD") != null);

    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-10: Context endpoint returns one document with plan + assertions
// + NEEDS_REVIEW package + plan_digest (AC5)
// ---------------------------------------------------------------------------

test "TC-PRM-05-10: context endpoint returns plan, assertions, NEEDS_REVIEW package, and digest in one document" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleGetPromotionContext(&pool, alloc, actorFor(requester), fixture.review_id);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, fixture.review_id) != null);
    try testing.expect(std.mem.indexOf(u8, result.body, fixture.digest) != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "serialised_plan") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"assertions\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"needs_review_package\":{") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "NEEDS_REVIEW") != null);
    // The stored plan is embedded verbatim; every canonical plan entry carries
    // a `changes` sub-object (node id is random per run for fixture isolation,
    // so we assert on the invariant shape, not a specific id).
    try testing.expect(std.mem.indexOf(u8, result.body, "\"changes\":{\"after\":") != null);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-11: Digest mismatch on approve → HTTP 409, stays pending_review
// ---------------------------------------------------------------------------

test "TC-PRM-05-11: approve with a mismatching digest returns HTTP 409 and stays pending_review" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{wrong_digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApproveReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-12: Digest mismatch on apply → HTTP 409, no sandbox
// ---------------------------------------------------------------------------

test "TC-PRM-05-12: apply with a mismatching digest returns HTTP 409 and claims no sandbox" {
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

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupEventByKey(&pool, alloc, "DEFINITION_PROMOTION_APPROVED", fixture.review_id);
    defer cleanupReview(&pool, fixture.review_id);

    try review_mod.approveReview(alloc, &pool, fixture.review_id, DEFAULT_TENANT_ID, approver, 1);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{wrong_digest});
    defer alloc.free(body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const result = review_routes.handleApplyReview(&pool, alloc, actorFor(approver), fixture.review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    const runs = try countAssertionRuns(&pool, alloc, fixture.review_id);
    try testing.expectEqual(@as(i64, 0), runs);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-13: No bypass parameter/flag — apply gate is structural (AC4)
// ---------------------------------------------------------------------------

test "TC-PRM-05-13: apply admits no bypass flag — every non-approved path returns 400/422" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const fixture = try submitPendingReview(alloc, &pool, requester);
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }
    defer cleanupReview(&pool, fixture.review_id);

    // (1) Skip-looking unknown field on a PENDING review -> 422 UNKNOWN_FIELD.
    const skip_body = try std.fmt.allocPrint(alloc,
        \\{{"plan_digest":"{s}","force":true}}
    , .{fixture.digest});
    defer alloc.free(skip_body);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const skip_result = review_routes.handleApplyReview(&pool, alloc, actorFor(requester), fixture.review_id, skip_body);
    defer alloc.free(skip_result.body);
    try testing.expectEqual(@as(u16, 422), skip_result.status_code);

    // (2) Correct body on a PENDING review -> 400 INVALID_REVIEW_TRANSITION.
    const plain_body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{fixture.digest});
    defer alloc.free(plain_body);
    const plain_result = review_routes.handleApplyReview(&pool, alloc, actorFor(requester), fixture.review_id, plain_body);
    defer alloc.free(plain_result.body);
    try testing.expectEqual(@as(u16, 400), plain_result.status_code);

    // Status never changed: the gate is structural, not bypassable.
    const r = getReviewOrFail(alloc, &pool, fixture.review_id);
    defer freeReviewRecord(alloc, &r);
    try testing.expect(r.status == .pending_review);
}
