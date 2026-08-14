//! Integration tests for PRM-05: Non-skippable approval gate.
//!
//! Tests:
//!   TC-PRM-05-01: Apply blocked when review status is pending_review
//!   TC-PRM-05-02: Apply blocked when review status is rejected
//!   TC-PRM-05-03: Apply blocked when review status is failed
//!   TC-PRM-05-04: Apply succeeds when review status is approved
//!   TC-PRM-05-05: Self-approval returns HTTP 403
//!   TC-PRM-05-06: Different principal can approve
//!   TC-PRM-05-07: Reject does NOT enforce self-approval restriction
//!   TC-PRM-05-08: Apply request body rejects unknown fields (HTTP 422)
//!   TC-PRM-05-09: Approve request body rejects unknown fields (HTTP 422)
//!   TC-PRM-05-10: Context endpoint returns stored plan (not live recomputed)
//!   TC-PRM-05-11: Digest mismatch on approve blocks transition (HTTP 409)
//!   TC-PRM-05-12: Digest mismatch on apply blocks transition (HTTP 409)
//!
//! Per-test isolation: every test creates its own tenant UUIDs and review IDs
//! via helpers.randomUuidBytes. No hardcoded UUID literals. No error.SkipZigTest.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm05`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const review_mod = bpm.promotion_review;
const digest_mod = bpm.promotion_digest;
const plan_mod = bpm.promotion_plan;
const review_routes = bpm.api.routes.promotion_review;

// ---------------------------------------------------------------------------
// DB URL helper
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-05 integration tests FAILED\n", .{});
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
// Tenant + schema fixture helpers
// ---------------------------------------------------------------------------

fn createTestTenant(pool: *Pool, tenant_uuid: []const u8, schema: []const u8) !void {
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
}

fn cleanupTenant(pool: *Pool, tenant_uuid: []const u8, schema: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    _ = conn.exec(
        \\DELETE FROM promotion_reviews WHERE tenant_id = $1::uuid
    ,
        &.{tenant_uuid},
    ) catch {};
    _ = conn.exec(
        \\DELETE FROM plat_events WHERE tenant_id = $1::uuid
    ,
        &.{tenant_uuid},
    ) catch {};
    _ = conn.exec(
        \\DELETE FROM public.tenant WHERE id = $1::uuid
    ,
        &.{tenant_uuid},
    ) catch {};
    _ = conn.exec(
        \\DROP SCHEMA IF EXISTS {s} CASCADE
    ,
        &.{schema},
    ) catch {};
}

// ---------------------------------------------------------------------------
// Review + digest fixture helpers
// ---------------------------------------------------------------------------

/// Submit a pending review and return the review_id and the computed digest.
fn submitPendingReview(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_uuid: []const u8,
    schema: []const u8,
    node_id: []const u8,
) !struct { review_id: []u8, digest: []u8 } {
    api_tenant_context.set(schema);

    const digest = digest_mod.computePlanDigest(allocator, .{
        .entries = &.{
            .{
                .type = .graph_node,
                .id = try allocator.dupe(u8, node_id),
                .change_kind = .added,
                .before = null,
                .after = null,
            },
        },
        .human_readable = try allocator.dupe(u8, "PRM-05 gate test"),
    });

    const serialised = try std.fmt.allocPrint(allocator,
        \\[{{"type":"graph_node","id":"{s}","change_kind":"added","before":null,"after":null}}],
        .{node_id}
    );

    const review_id = try review_mod.submitReview(allocator, pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "gate-test-proc",
        .serialised_plan = serialised,
        .requested_by = tenant_uuid,
    });

    return .{ .review_id = review_id, .digest = digest };
}

// ---------------------------------------------------------------------------
// TC-PRM-05-01: Apply blocked when review status is pending_review
// ---------------------------------------------------------------------------

test "TC-PRM-05-01: apply blocked when review is pending_review" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_01_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-01");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    // Try to apply — should return HTTP 400 INVALID_REVIEW_TRANSITION.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = "any-user", .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}"}},
            .{fixture.digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);

    // Verify review is still pending_review.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .pending_review);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-02: Apply blocked when review status is rejected
// ---------------------------------------------------------------------------

test "TC-PRM-05-02: apply blocked when review is rejected" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_02_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-02");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    // Reject the review first.
    try review_mod.rejectReview(alloc, &pool, fixture.review_id, 1);

    // Try to apply — should return HTTP 400.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = "any-user", .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}"}},
            .{fixture.digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-03: Apply blocked when review status is failed
// ---------------------------------------------------------------------------

test "TC-PRM-05-03: apply blocked when review is failed" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_03_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-03");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Approve then mark failed.
    try review_mod.approveReview(alloc, &pool, fixture.review_id, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, fixture.review_id, 2);

    // Try to apply — should return HTTP 400.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = "any-user", .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}"}},
            .{fixture.digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_REVIEW_TRANSITION") != null);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-04: Apply succeeds when review status is approved
// ---------------------------------------------------------------------------

test "TC-PRM-05-04: apply succeeds when review is approved with matching digest" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_04_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-04");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Approve the review.
    try review_mod.approveReview(alloc, &pool, fixture.review_id, approver, 1);

    // Apply with matching digest — should succeed.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}"}},
            .{fixture.digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    // Verify review is now applied.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .applied);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-05: Self-approval returns HTTP 403
// ---------------------------------------------------------------------------

test "TC-PRM-05-05: self-approval returns HTTP 403 SELF_APPROVAL_FORBIDDEN" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_05_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-05");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    // Try to approve as the same principal who requested — must be rejected.
    const result = review_routes.handleApproveReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = tenant_uuid, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}","approved_by":"{s}"}},
            .{ fixture.digest, tenant_uuid }
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "SELF_APPROVAL_FORBIDDEN") != null);

    // Verify review is still pending_review.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .pending_review);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-06: Different principal can approve
// ---------------------------------------------------------------------------

test "TC-PRM-05-06: different principal can successfully approve" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_06_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-06");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Approve as a different principal — should succeed.
    const result = review_routes.handleApproveReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}","approved_by":"{s}"}},
            .{ fixture.digest, approver }
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "approved") != null);

    // Verify review is approved.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .approved);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-07: Reject does NOT enforce self-approval restriction
// ---------------------------------------------------------------------------

test "TC-PRM-05-07: reject by same principal is allowed (no self-approval gate on reject)" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_07_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-07");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    // Reject as the same principal who requested — must succeed (no self-approval on reject).
    const result = review_routes.handleRejectReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = tenant_uuid, .roles = &.{} },
        fixture.review_id,
        "{}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "rejected") != null);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-08: Apply request body rejects unknown fields (HTTP 422)
// ---------------------------------------------------------------------------

test "TC-PRM-05-08: apply with unknown field returns HTTP 422 UNKNOWN_FIELD" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_08_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-08");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Approve the review first.
    try review_mod.approveReview(alloc, &pool, fixture.review_id, approver, 1);

    // Try to apply with an unknown bypass field — must return HTTP 422.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}","bypass":true}},
            .{fixture.digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "UNKNOWN_FIELD") != null);

    // Verify review is still approved (not applied).
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .approved);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-09: Approve request body rejects unknown fields (HTTP 422)
// ---------------------------------------------------------------------------

test "TC-PRM-05-09: approve with unknown field returns HTTP 422 UNKNOWN_FIELD" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_09_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-09");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Try to approve with an unknown force_approve field — must return HTTP 422.
    const result = review_routes.handleApproveReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}","approved_by":"{s}","force_approve":true}},
            .{ fixture.digest, approver }
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "UNKNOWN_FIELD") != null);

    // Verify review is still pending_review.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .pending_review);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-10: Context endpoint returns stored plan (not live recomputed)
// ---------------------------------------------------------------------------

test "TC-PRM-05-10: context endpoint returns stored plan_digest and serialised_plan" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_10_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-10");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    // Call context endpoint.
    const result = review_routes.handleGetPromotionContext(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = tenant_uuid, .roles = &.{} },
        fixture.review_id,
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    // The stored digest must appear in the response.
    try testing.expect(std.mem.indexOf(u8, result.body, fixture.digest) != null);

    // The stored serialised_plan must appear in the response.
    try testing.expect(std.mem.indexOf(u8, result.body, "gate-node-10") != null);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-11: Digest mismatch on approve blocks transition (HTTP 409)
// ---------------------------------------------------------------------------

test "TC-PRM-05-11: approve with wrong digest returns HTTP 409 PLAN_DIGEST_MISMATCH" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_11_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-11");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";

    // Try to approve with wrong digest — must return HTTP 409.
    const result = review_routes.handleApproveReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}","approved_by":"{s}"}},
            .{ wrong_digest, approver }
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    // Verify review is still pending_review.
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .pending_review);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-05-12: Digest mismatch on apply blocks transition (HTTP 409)
// ---------------------------------------------------------------------------

test "TC-PRM-05-12: apply with wrong digest returns HTTP 409 PLAN_DIGEST_MISMATCH" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm05_12_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const fixture = try submitPendingReview(alloc, &pool, tenant_uuid, schema, "gate-node-12");
    defer {
        alloc.free(fixture.review_id);
        alloc.free(fixture.digest);
    }

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    // Approve first with correct digest.
    try review_mod.approveReview(alloc, &pool, fixture.review_id, approver, 1);

    const wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";

    // Try to apply with wrong digest — must return HTTP 409.
    const result = review_routes.handleApplyReview(
        &pool,
        alloc,
        bpm.auth.AuthContext{ .user_id = approver, .roles = &.{} },
        fixture.review_id,
        try std.fmt.allocPrint(alloc,
            \\{{"plan_digest":"{s}"}},
            .{wrong_digest}
        ),
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PLAN_DIGEST_MISMATCH") != null);

    // Verify review is still approved (not applied).
    const review = try review_mod.getReview(alloc, &pool, fixture.review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };
    try testing.expect(review != null);
    try testing.expect(review.?.status == .approved);

    cleanupTenant(&pool, tenant_uuid, schema);
}
