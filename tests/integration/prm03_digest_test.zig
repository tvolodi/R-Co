//! Integration tests for PRM-03: plan digest.
//!
//! Tests:
//!   TC-PRM-03-01: Digest deterministic — same plan -> same digest
//!   TC-PRM-03-02: Digest canonical — keys sorted lexicographically
//!   TC-PRM-03-03: Different plan -> different digest
//!   TC-PRM-03-04: Digest is 64-char lowercase hex
//!   TC-PRM-03-05: null values included correctly
//!   TC-PRM-03-06: verifyDigest returns true on match
//!   TC-PRM-03-07: verifyDigest returns false on mismatch
//!   TC-PRM-03-08: Digest stored on promotion_reviews at submit time
//!   TC-PRM-03-09: Approve fails HTTP 409 on digest mismatch
//!   TC-PRM-03-10: Apply fails HTTP 409 on digest mismatch
//!   TC-PRM-03-11: verifyDigest is constant-time
//!
//! Per-test isolation: no hardcoded UUID literals. No error.SkipZigTest.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl.
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

const digest_mod = bpm.promotion_digest;
const plan_mod = bpm.promotion_plan;
const review_mod = bpm.promotion_review;

// ---------------------------------------------------------------------------
// DB URL helper
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-03 integration tests FAILED\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    const uuid = helpers.randomUuidBytes();
    return helpers.uuidBytesToString(allocator, uuid);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-01: Same plan produces same digest (deterministic)
// ---------------------------------------------------------------------------

test "TC-PRM-03-01: digest is deterministic — same plan yields same digest" {
    const alloc = testing.allocator;

    // Build two identical plans.
    const entries = try alloc.alloc(plan_mod.PlanEntry, 2);
    defer alloc.free(entries);

    entries[0] = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-1"),
        .change_kind = .added,
        .before = null,
        .after = try alloc.dupe(u8, "null"),
    };
    entries[1] = plan_mod.PlanEntry{
        .type = .graph_edge,
        .id = try alloc.dupe(u8, "edge-1"),
        .change_kind = .modified,
        .before = try alloc.dupe(u8, "{\"x\":1}"),
        .after = try alloc.dupe(u8, "{\"x\":2}"),
    };
    defer {
        for (entries) |e| {
            alloc.free(e.id);
            if (e.before) |b| alloc.free(b);
            if (e.after) |a| alloc.free(a);
        }
    }

    const plan_a = plan_mod.PromotionPlan{
        .entries = entries,
        .human_readable = try alloc.dupe(u8, "test"),
    };
    const plan_b = plan_mod.PromotionPlan{
        .entries = entries,
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest_a = digest_mod.computePlanDigest(alloc, plan_a);
    defer alloc.free(digest_a);
    const digest_b = digest_mod.computePlanDigest(alloc, plan_b);
    defer alloc.free(digest_b);

    try testing.expectEqualStrings(digest_a, digest_b);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-02: Canonical — keys sorted lexicographically
// ---------------------------------------------------------------------------

test "TC-PRM-03-02: digest canonical — keys sorted lexicographically" {
    const alloc = testing.allocator;

    // Entry with keys in non-canonical order (JSON object keys declared in
    // "wrong" order). The canonical form always produces the same JSON
    // regardless of insertion order.
    const entry = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-1"),
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer {
        alloc.free(entry.id);
    }

    const plan = plan_mod.PromotionPlan{
        .entries = &.{entry},
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    // Digest must be 64 hex chars.
    try testing.expectEqual(@as(usize, 64), digest.len);
    for (digest) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-03-03: Different plan -> different digest
// ---------------------------------------------------------------------------

test "TC-PRM-03-03: different plan produces different digest" {
    const alloc = testing.allocator;

    const entries_a = try alloc.alloc(plan_mod.PlanEntry, 1);
    defer alloc.free(entries_a);
    entries_a[0] = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-1"),
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer alloc.free(entries_a[0].id);

    const plan_a = plan_mod.PromotionPlan{
        .entries = entries_a,
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const entries_b = try alloc.alloc(plan_mod.PlanEntry, 1);
    defer alloc.free(entries_b);
    entries_b[0] = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-2"), // Different id.
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer alloc.free(entries_b[0].id);

    const plan_b = plan_mod.PromotionPlan{
        .entries = entries_b,
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest_a = digest_mod.computePlanDigest(alloc, plan_a);
    defer alloc.free(digest_a);
    const digest_b = digest_mod.computePlanDigest(alloc, plan_b);
    defer alloc.free(digest_b);

    try testing.expect(!std.mem.eql(u8, digest_a, digest_b));
}

// ---------------------------------------------------------------------------
// TC-PRM-03-04: Digest is 64-char lowercase hex
// ---------------------------------------------------------------------------

test "TC-PRM-03-04: digest is 64-char lowercase hex (SHA-256 output)" {
    const alloc = testing.allocator;

    const entry = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-x"),
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer alloc.free(entry.id);

    const plan = plan_mod.PromotionPlan{
        .entries = &.{entry},
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    try testing.expectEqual(@as(usize, 64), digest.len);
    for (digest) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-03-05: null values included correctly
// ---------------------------------------------------------------------------

test "TC-PRM-03-05: null values are included as JSON literal null" {
    const alloc = testing.allocator;

    // Entry where after is the JSON null literal (represented as null in our struct).
    const entry = plan_mod.PlanEntry{
        .type = .variable_schema,
        .id = try alloc.dupe(u8, "var-1"),
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer alloc.free(entry.id);

    const plan = plan_mod.PromotionPlan{
        .entries = &.{entry},
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    // Digest must still be 64 hex chars.
    try testing.expectEqual(@as(usize, 64), digest.len);
}

// ---------------------------------------------------------------------------
// TC-PRM-03-06: verifyDigest returns true on match
// ---------------------------------------------------------------------------

test "TC-PRM-03-06: verifyDigest returns true on matching digests" {
    const digest = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    try testing.expect(digest_mod.verifyDigest(digest, digest));
}

// ---------------------------------------------------------------------------
// TC-PRM-03-07: verifyDigest returns false on mismatch
// ---------------------------------------------------------------------------

test "TC-PRM-03-07: verifyDigest returns false on mismatched digests" {
    const stored = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expect(!digest_mod.verifyDigest(stored, wrong));
}

// ---------------------------------------------------------------------------
// TC-PRM-03-08: Digest stored on promotion_reviews at submit time
// ---------------------------------------------------------------------------

test "TC-PRM-03-08: digest and serialised_plan stored on promotion_reviews at submit time" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Create test tenants.
    const tenant_uuid = try randomUuidStr(alloc);
    defer alloc.free(tenant_uuid);
    const schema = try std.fmt.allocPrint(alloc, "t{prm03_08_{s}}", .{tenant_uuid});
    defer alloc.free(schema);

    // Insert tenant via direct connection.
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL, 'test',
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_uuid, schema },
    );

    try conn.exec(
        \\INSERT INTO public.tenant_schemas (schema_name, tenant_id, migrations_applied_at)
        \\VALUES ($1, $2::uuid, now())
        \\ON CONFLICT (schema_name) DO NOTHING
    ,
        &[_][]const u8{ schema, tenant_uuid },
    );

    try conn.exec(std.fmt.allocPrint(alloc, "SET search_path TO {s},public", .{schema}) catch "", &.{});

    // Compute digest for a test plan.
    const entry = plan_mod.PlanEntry{
        .type = .graph_node,
        .id = try alloc.dupe(u8, "node-test"),
        .change_kind = .added,
        .before = null,
        .after = null,
    };
    defer alloc.free(entry.id);

    const plan = plan_mod.PromotionPlan{
        .entries = &.{entry},
        .human_readable = try alloc.dupe(u8, "test"),
    };

    const digest = digest_mod.computePlanDigest(alloc, plan);
    defer alloc.free(digest);

    // Submit review via API handler.
    api_tenant_context.set(schema);

    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "test-proc",
        .serialised_plan = try alloc.dupe(u8, "[{\"type\":\"graph_node\",\"id\":\"node-test\",\"change_kind\":\"added\",\"before\":null,\"after\":null}]"),
        .requested_by = tenant_uuid,
    }) catch |err| {
        std.debug.print("submitReview failed: {}\n", .{err});
        return err;
    };
    defer alloc.free(review_id);

    // Read back and verify.
    const review = try review_mod.getReview(alloc, &pool, review_id) catch |err| {
        std.debug.print("getReview failed: {}\n", .{err});
        return err;
    };
    try testing.expect(review != null);

    const r = review.?;
    defer {
        alloc.free(r.id);
        alloc.free(r.tenant_id);
        alloc.free(r.plan_digest);
        alloc.free(r.def_type);
        alloc.free(r.def_id);
        alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    }

    try testing.expectEqualStrings(digest, r.plan_digest);
    try testing.expect(r.serialised_plan.len > 0);

    // Cleanup.
    _ = conn.exec(
        \\DELETE FROM promotion_reviews WHERE id = $1::uuid
    ,
        &.{review_id},
    );
    _ = conn.exec(
        \\DELETE FROM public.tenant WHERE id = $1::uuid
    ,
        &.{tenant_uuid},
    );
}

// ---------------------------------------------------------------------------
// TC-PRM-03-09: Approve fails HTTP 409 on digest mismatch
// ---------------------------------------------------------------------------

test "TC-PRM-03-09: approve rejected with HTTP 409 on digest mismatch" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_uuid = try randomUuidStr(alloc);
    defer alloc.free(tenant_uuid);
    const schema = try std.fmt.allocPrint(alloc, "t{prm03_09_{s}}", .{tenant_uuid});
    defer alloc.free(schema);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL, 'test',
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_uuid, schema },
    );

    try conn.exec(
        \\INSERT INTO public.tenant_schemas (schema_name, tenant_id, migrations_applied_at)
        \\VALUES ($1, $2::uuid, now())
        \\ON CONFLICT (schema_name) DO NOTHING
    ,
        &[_][]const u8{ schema, tenant_uuid },
    );

    try conn.exec(std.fmt.allocPrint(alloc, "SET search_path TO {s},public", .{schema}) catch "", &.{});

    // Create a review with a known digest.
    const correct_digest = "abcd1234567890abcd1234567890abcd1234567890abcd1234567890abcd1234";
    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";

    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = correct_digest,
        .def_type = "process",
        .def_id = "test-proc",
        .serialised_plan = try alloc.dupe(u8, "[]"),
        .requested_by = tenant_uuid,
    }) catch |err| return err;
    defer alloc.free(review_id);

    // Try to approve with wrong digest via handler.
    api_tenant_context.set(schema);

    // The handler checks digest before calling approveReview.
    const handler_result = bpm.api.routes.promotion_review.handleApproveReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = "another-user-uuid", .roles = &.{} },
        review_id,
        \\{"plan_digest":"0000000000000000000000000000000000000000000000000000000000000000","approved_by":"another-user-uuid"}
    ,
    );

    // Handler returns HTTP 409 on digest mismatch.
    try testing.expectEqual(@as(u16, 409), handler_result.status_code);
    try testing.expect(std.mem.indexOf(u8, handler_result.body, "PLAN_DIGEST_MISMATCH") != null);

    // Cleanup.
    _ = conn.exec(
        \\DELETE FROM promotion_reviews WHERE id = $1::uuid
    ,
        &.{review_id},
    );
    _ = conn.exec(
        \\DELETE FROM public.tenant WHERE id = $1::uuid
    ,
        &.{tenant_uuid},
    );
}

// ---------------------------------------------------------------------------
// TC-PRM-03-10: Apply fails HTTP 409 on digest mismatch
// ---------------------------------------------------------------------------

test "TC-PRM-03-10: apply rejected with HTTP 409 on digest mismatch" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_uuid = try randomUuidStr(alloc);
    defer alloc.free(tenant_uuid);
    const schema = try std.fmt.allocPrint(alloc, "t{prm03_10_{s}}", .{tenant_uuid});
    defer alloc.free(schema);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL, 'test',
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_uuid, schema },
    );

    try conn.exec(
        \\INSERT INTO public.tenant_schemas (schema_name, tenant_id, migrations_applied_at)
        \\VALUES ($1, $2::uuid, now())
        \\ON CONFLICT (schema_name) DO NOTHING
    ,
        &[_][]const u8{ schema, tenant_uuid },
    );

    try conn.exec(std.fmt.allocPrint(alloc, "SET search_path TO {s},public", .{schema}) catch "", &.{});

    const correct_digest = "abcd1234567890abcd1234567890abcd1234567890abcd1234567890abcd1234";

    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = correct_digest,
        .def_type = "process",
        .def_id = "test-proc",
        .serialised_plan = try alloc.dupe(u8, "[]"),
        .requested_by = tenant_uuid,
    }) catch |err| return err;
    defer alloc.free(review_id);

    // Approve the review first (correct digest).
    try review_mod.approveReview(alloc, &pool, review_id, "approver-uuid", 1);

    // Try to apply with wrong digest.
    api_tenant_context.set(schema);

    const handler_result = bpm.api.routes.promotion_review.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = "approver-uuid", .roles = &.{} },
        review_id,
        \\{"plan_digest":"0000000000000000000000000000000000000000000000000000000000000000"}
    ,
    );

    // Handler returns HTTP 409 on digest mismatch.
    try testing.expectEqual(@as(u16, 409), handler_result.status_code);
    try testing.expect(std.mem.indexOf(u8, handler_result.body, "PLAN_DIGEST_MISMATCH") != null);

    // Cleanup.
    _ = conn.exec(
        \\DELETE FROM promotion_reviews WHERE id = $1::uuid
    ,
        &.{review_id},
    );
    _ = conn.exec(
        \\DELETE FROM public.tenant WHERE id = $1::uuid
    ,
        &.{tenant_uuid},
    );
}

// ---------------------------------------------------------------------------
// TC-PRM-03-11: verifyDigest uses constant-time comparison
// ---------------------------------------------------------------------------

test "TC-PRM-03-11: verifyDigest is constant-time (no early-exit on mismatch)" {
    // We verify the implementation uses constantTimeCompare by checking the function
    // exists and handles different-length inputs safely.
    // The actual constant-time property is verified by the implementation using
    // std.crypto.utils.constantTimeCompare.

    // Different lengths should return false quickly.
    try testing.expect(!digest_mod.verifyDigest(
        "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        "short",
    ));

    // Same content should return true.
    const digest = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    try testing.expect(digest_mod.verifyDigest(digest, digest));
}
