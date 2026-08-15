//! Integration tests for PRM-03: plan digest binds approval to a diff.
//!
//! Covers every MUST acceptance criterion of PRM-03:
//!   AC1 — two byte-identical plans -> same 64-char lowercase hex digest
//!   AC2 — approve with mismatching body digest -> HTTP 409, stays pending_review
//!   AC3 — apply with mismatching body digest -> HTTP 409, no sandbox claimed
//!   AC4 — source changes after approval -> new digest + new review; earlier
//!         approval cannot apply the new plan
//!   AC5 — the context endpoint serves the stored plan, never a live diff
//!
//! Tenant strategy: integration tests route through the default tenant
//! (all-zeros UUID -> tenant_default, provisioned by helpers.ensureSchemaReady).
//! Every fixture uses random UUIDs; every test cleans up via `defer`. The pure
//! digest functions (computePlanDigest / serialisePlanCanonical / verifyDigest)
//! are exercised without a DB connection.
//!
//! No error.SkipZigTest on MUST requirements. BPM_TEST_DB_URL must be set for
//! the integration tests; the pure unit tests fail hard if it is absent too
//! because this is an integration binary (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm03`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const digest_mod = bpm.promotion_digest_mod;
const plan_mod = bpm.promotion_plan_mod;
const review_mod = bpm.promotion_review_mod;
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
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-03 integration tests FAILED (env var required)\n", .{});
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
// Cleanup helpers (tenant_default)
// ---------------------------------------------------------------------------

fn cleanupEventByKeyPrefix(pool: *Pool, prefix: []const u8, review_id: []const u8) void {
    const key = std.fmt.allocPrint(testing.allocator, "{s}-{s}", .{ prefix, review_id }) catch return;
    defer testing.allocator.free(key);
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

// ---------------------------------------------------------------------------
// Test plan fixtures
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
        .human_readable = "PRM-03 test plan",
    };
}

// ---------------------------------------------------------------------------
// TC-PRM-03-01: Digest is deterministic — byte-identical plans -> same digest
// ---------------------------------------------------------------------------

test "TC-PRM-03-01: byte-identical plans produce the same 64-char digest" {
    const alloc = testing.allocator;
    var entries_a: [1]plan_mod.PlanEntry = undefined;
    var entries_b: [1]plan_mod.PlanEntry = undefined;
    const plan_a = planWithNode("node-1", &entries_a);
    const plan_b = planWithNode("node-1", &entries_b);

    const digest_a = digest_mod.computePlanDigest(alloc, plan_a);
    defer alloc.free(digest_a);
    const digest_b = digest_mod.computePlanDigest(alloc, plan_b);
    defer alloc.free(digest_b);

    try testing.expectEqual(@as(usize, 64), digest_a.len);
    try testing.expectEqualStrings(digest_a, digest_b);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-02: Digest is 64-char lowercase hexadecimal
// ---------------------------------------------------------------------------

test "TC-PRM-03-02: digest is exactly 64 lowercase hex characters" {
    const alloc = testing.allocator;
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode("node-1", &entries);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    try testing.expectEqual(@as(usize, 64), digest.len);
    for (digest) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-03-03: Canonical form — keys sorted, no whitespace, {type,id,changes}
// ---------------------------------------------------------------------------

test "TC-PRM-03-03: serialisePlanCanonical emits compact sorted-key canonical JSON" {
    const alloc = testing.allocator;
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode("node-1", &entries);

    const canonical = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(canonical);

    try testing.expectEqualStrings(
        \\[{"changes":{"after":null,"before":null,"change_kind":"added"},"id":"node-1","type":"graph_node"}]
    ,
        canonical,
    );
}

// ---------------------------------------------------------------------------
// TC-PRM-03-04: Different plans produce different digests
// ---------------------------------------------------------------------------

test "TC-PRM-03-04: different plan content produces a different digest" {
    const alloc = testing.allocator;
    var entries_a: [1]plan_mod.PlanEntry = undefined;
    var entries_b: [1]plan_mod.PlanEntry = undefined;
    const plan_a = planWithNode("node-1", &entries_a);
    const plan_b = planWithNode("node-2", &entries_b);

    const digest_a = digest_mod.computePlanDigest(alloc, plan_a);
    defer alloc.free(digest_a);
    const digest_b = digest_mod.computePlanDigest(alloc, plan_b);
    defer alloc.free(digest_b);

    try testing.expect(!std.mem.eql(u8, digest_a, digest_b));
}

// ---------------------------------------------------------------------------
// TC-PRM-03-05: null values are emitted as literal null, never omitted
// ---------------------------------------------------------------------------

test "TC-PRM-03-05: null before/after emitted as literal null in canonical form" {
    const alloc = testing.allocator;
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode("node-1", &entries);

    const canonical = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(canonical);

    try testing.expect(std.mem.indexOf(u8, canonical, "\"after\":null") != null);
    try testing.expect(std.mem.indexOf(u8, canonical, "\"before\":null") != null);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-06: verifyDigest — match true, mismatch false, wrong length false
// ---------------------------------------------------------------------------

test "TC-PRM-03-06: verifyDigest distinguishes match, mismatch, and wrong length" {
    const stored = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expect(digest_mod.verifyDigest(stored, stored));
    try testing.expect(!digest_mod.verifyDigest(stored, wrong));
    try testing.expect(!digest_mod.verifyDigest(stored, "short"));
}

// ---------------------------------------------------------------------------
// TC-PRM-03-07: Approve with mismatching body digest -> HTTP 409, stays pending
// ---------------------------------------------------------------------------

test "TC-PRM-03-07: approve with wrong digest returns HTTP 409 and review stays pending_review" {
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

    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm03-proc-07",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{wrong_digest});
    defer alloc.free(body);

    const actor = auth.AuthContext{
        .user_id = approver,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm03-07",
        .principal = "test-token-prm03-07",
    };
    const result = review_routes.handleApproveReview(&pool, alloc, actor, review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    // Review remains pending_review.
    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review = try review_mod.getReview(alloc, &pool, review_id);
    defer if (review) |r| {
        alloc.free(r.id);
        alloc.free(r.tenant_id);
        alloc.free(r.plan_digest);
        alloc.free(r.def_type);
        alloc.free(r.def_id);
        alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .pending_review);
    try testing.expectEqual(@as(u32, 1), review.?.row_version);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-08: Apply with mismatching body digest -> HTTP 409, no sandbox
// ---------------------------------------------------------------------------

test "TC-PRM-03-08: apply with wrong digest returns HTTP 409 and claims no sandbox" {
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

    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm03-proc-08",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupEventByKeyPrefix(&pool, "DEFINITION_PROMOTION_APPROVED", review_id);
    defer cleanupReview(&pool, review_id);

    // Approve with the correct digest first.
    try review_mod.approveReview(alloc, &pool, review_id, DEFAULT_TENANT_ID, approver, 1);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{wrong_digest});
    defer alloc.free(body);

    const actor = auth.AuthContext{
        .user_id = approver,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm03-08",
        .principal = "test-token-prm03-08",
    };
    const result = review_routes.handleApplyReview(&pool, alloc, actor, review_id, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    // No sandbox claimed.
    const runs = try countAssertionRuns(&pool, alloc, review_id);
    try testing.expectEqual(@as(i64, 0), runs);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-09: Digest + serialised plan stored on promotion_reviews at submit
// ---------------------------------------------------------------------------

test "TC-PRM-03-09: digest and serialised_plan stored on promotion_reviews at submit time" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm03-proc-09",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review = try review_mod.getReview(alloc, &pool, review_id);
    defer if (review) |r| {
        alloc.free(r.id);
        alloc.free(r.tenant_id);
        alloc.free(r.plan_digest);
        alloc.free(r.def_type);
        alloc.free(r.def_id);
        alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expectEqualStrings(digest, review.?.plan_digest);
    try testing.expectEqualStrings(serialised, review.?.serialised_plan);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-10: Source changes after approval -> new digest + new review;
// earlier approval cannot apply the new plan
// ---------------------------------------------------------------------------

test "TC-PRM-03-10: earlier approval cannot be applied to a plan with a new digest" {
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

    // Plan A (digest D1) — approved.
    const node_a = try randomUuidStr(alloc);
    defer alloc.free(node_a);
    var entries_a: [1]plan_mod.PlanEntry = undefined;
    const plan_a = planWithNode(node_a, &entries_a);
    const digest_a = digest_mod.computePlanDigest(alloc, plan_a);
    defer alloc.free(digest_a);
    const serialised_a = try digest_mod.serialisePlanCanonical(alloc, plan_a);
    defer alloc.free(serialised_a);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_a = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest_a,
        .def_type = "process",
        .def_id = "prm03-proc-10",
        .serialised_plan = serialised_a,
        .requested_by = requester,
    });
    defer alloc.free(review_a);
    defer cleanupEventByKeyPrefix(&pool, "DEFINITION_PROMOTION_APPROVED", review_a);
    defer cleanupReview(&pool, review_a);

    try review_mod.approveReview(alloc, &pool, review_a, DEFAULT_TENANT_ID, approver, 1);

    // Plan B (digest D2 != D1) — a new submission after the source changed.
    const node_b = try randomUuidStr(alloc);
    defer alloc.free(node_b);
    var entries_b: [1]plan_mod.PlanEntry = undefined;
    const plan_b = planWithNode(node_b, &entries_b);
    const digest_b = digest_mod.computePlanDigest(alloc, plan_b);
    defer alloc.free(digest_b);
    const serialised_b = try digest_mod.serialisePlanCanonical(alloc, plan_b);
    defer alloc.free(serialised_b);

    try testing.expect(!std.mem.eql(u8, digest_a, digest_b));

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_b = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest_b,
        .def_type = "process",
        .def_id = "prm03-proc-10",
        .serialised_plan = serialised_b,
        .requested_by = requester,
    });
    defer alloc.free(review_b);
    defer cleanupEventByKeyPrefix(&pool, "DEFINITION_PROMOTION_APPROVED", review_b);
    defer cleanupReview(&pool, review_b);

    // Approve review B with ITS OWN digest (D2) so the apply gate reaches the
    // digest check (status == approved).
    try review_mod.approveReview(alloc, &pool, review_b, DEFAULT_TENANT_ID, approver, 1);

    // Trying to apply review B with the OLD digest D1 must fail (409) — the
    // earlier approval is bound to D1 and cannot apply the new plan (D2).
    const body = try std.fmt.allocPrint(alloc, "{{\"plan_digest\":\"{s}\"}}", .{digest_a});
    defer alloc.free(body);

    const actor = auth.AuthContext{
        .user_id = approver,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm03-10",
        .principal = "test-token-prm03-10",
    };
    const result = review_routes.handleApplyReview(&pool, alloc, actor, review_b, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-11: Context endpoint serves the stored plan, never a live diff
// ---------------------------------------------------------------------------

test "TC-PRM-03-11: context endpoint serves the stored plan and digest" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const requester = try randomUuidStr(alloc);
    defer alloc.free(requester);

    const node_id = try randomUuidStr(alloc);
    defer alloc.free(node_id);
    var entries: [1]plan_mod.PlanEntry = undefined;
    const plan = planWithNode(node_id, &entries);
    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);
    const serialised = try digest_mod.serialisePlanCanonical(alloc, plan);
    defer alloc.free(serialised);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = DEFAULT_TENANT_ID,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "prm03-proc-11",
        .serialised_plan = serialised,
        .requested_by = requester,
    });
    defer alloc.free(review_id);
    defer cleanupReview(&pool, review_id);

    api_tenant_context.set(DEFAULT_TENANT_ID);
    const actor = auth.AuthContext{
        .user_id = requester,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm03-11",
        .principal = "test-token-prm03-11",
    };
    const result = review_routes.handleGetPromotionContext(&pool, alloc, actor, review_id);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, digest) != null);
    try testing.expect(std.mem.indexOf(u8, result.body, node_id) != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "serialised_plan") != null);
}
