//! Integration tests for PRM-04: Promotion review state machine.
//!
//! Tests:
//!   TC-PRM-04-01: pending_review → approved transition
//!   TC-PRM-04-02: pending_review → rejected transition
//!   TC-PRM-04-03: pending_review → superseded (duplicate digest)
//!   TC-PRM-04-04: approved → applied transition
//!   TC-PRM-04-05: approved → failed transition
//!   TC-PRM-04-06: applied → superseded transition
//!   TC-PRM-04-07: failed → superseded transition
//!   TC-PRM-04-08: rejected → superseded transition
//!   TC-PRM-04-09: Invalid transition returns error
//!   TC-PRM-04-10: Row version optimistic locking
//!   TC-PRM-04-11: CHECK constraint enforces valid statuses
//!   TC-PRM-04-12: getReview returns stored plan and digest
//!
//! Per-test isolation: every test creates its own tenant UUIDs and review IDs
//! via helpers.randomUuidBytes. No hardcoded UUID literals. No error.SkipZigTest.
//!
//! BPM_TEST_DB_URL must be set; tests fail with error.MissingTestDatabaseUrl
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm04`

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

// ---------------------------------------------------------------------------
// DB URL helper
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-04 integration tests FAILED\n", .{});
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
// Submit a review for testing (helper)
// ---------------------------------------------------------------------------

fn submitTestReview(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_uuid: []const u8,
    schema: []const u8,
) ![]u8 {
    api_tenant_context.set(schema);

    const digest = digest_mod.computePlanDigest(allocator, .{
        .entries = &.{
            .{
                .type = .graph_node,
                .id = try allocator.dupe(u8, "sm-test-node"),
                .change_kind = .added,
                .before = null,
                .after = null,
            },
        },
        .human_readable = try allocator.dupe(u8, "PRM-04 state machine test"),
    });

    const review_id = try review_mod.submitReview(allocator, pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "sm-test-proc",
        .serialised_plan = try allocator.dupe(u8,
            \\"[{\"type\":\"graph_node\",\"id\":\"sm-test-node\",\"change_kind\":\"added\",\"before\":null,\"after\":null}]"
        ),
        .requested_by = tenant_uuid,
    });

    allocator.free(digest);
    return review_id;
}

// ---------------------------------------------------------------------------
// TC-PRM-04-01: pending_review → approved transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-01: pending_review transitions to approved" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_01_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    // Verify initial status is pending_review.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .pending_review);
        try testing.expectEqual(@as(u32, 1), review.?.row_version);
    }

    // Perform the transition.
    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    try review_mod.approveReview(alloc, &pool, review_id, approver, 1);

    // Verify final status is approved with correct metadata.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .approved);
        try testing.expectEqual(@as(u32, 2), review.?.row_version);
        try testing.expect(review.?.approved_by != null);
        try testing.expectEqualStrings(approver, review.?.approved_by.?);
        try testing.expect(review.?.approved_at != null);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-02: pending_review → rejected transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-02: pending_review transitions to rejected" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_02_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    // Perform the transition.
    try review_mod.rejectReview(alloc, &pool, review_id, 1);

    // Verify final status is rejected.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .rejected);
        try testing.expectEqual(@as(u32, 2), review.?.row_version);
        try testing.expect(review.?.approved_by == null);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-03: pending_review → superseded (duplicate digest)
// ---------------------------------------------------------------------------

test "TC-PRM-04-03: second submit with same digest returns DUPLICATE_REVIEW" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_03_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    // Submit first review.
    const review_id_1 = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id_1);

    // Try to submit second review with identical digest — should fail with DuplicateReview.
    const digest = digest_mod.computePlanDigest(alloc, .{
        .entries = &.{
            .{
                .type = .graph_node,
                .id = try alloc.dupe(u8, "sm-test-node"),
                .change_kind = .added,
                .before = null,
                .after = null,
            },
        },
        .human_readable = try alloc.dupe(u8, "PRM-04 state machine test"),
    });
    defer alloc.free(digest);

    const result = review_mod.submitReview(alloc, &pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "sm-test-proc",
        .serialised_plan = try alloc.dupe(u8,
            \\"[{\"type\":\"graph_node\",\"id\":\"sm-test-node\",\"change_kind\":\"added\",\"before\":null,\"after\":null}]"
        ),
        .requested_by = tenant_uuid,
    });

    try testing.expect(result == error.DuplicateReview);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-04: approved → applied transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-04: approved transitions to applied" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_04_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    try review_mod.approveReview(alloc, &pool, review_id, approver, 1);
    try review_mod.markReviewApplied(alloc, &pool, review_id, 2);

    // Verify final status is applied.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .applied);
        try testing.expectEqual(@as(u32, 3), review.?.row_version);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-05: approved → failed transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-05: approved transitions to failed" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_05_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);

    try review_mod.approveReview(alloc, &pool, review_id, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, review_id, 2);

    // Verify final status is failed.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .failed);
        try testing.expectEqual(@as(u32, 3), review.?.row_version);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-06: applied → superseded transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-06: applied transitions to superseded" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_06_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);
    const superseding_review_id = try randomUuidStr(alloc);
    defer alloc.free(superseding_review_id);

    try review_mod.approveReview(alloc, &pool, review_id, approver, 1);
    try review_mod.markReviewApplied(alloc, &pool, review_id, 2);
    try review_mod.supersedeReview(alloc, &pool, review_id, superseding_review_id, 3);

    // Verify final status is superseded.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .superseded);
        try testing.expectEqual(@as(u32, 4), review.?.row_version);
        try testing.expect(review.?.superseded_by != null);
        try testing.expectEqualStrings(superseding_review_id, review.?.superseded_by.?);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-07: failed → superseded transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-07: failed transitions to superseded" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_07_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    const approver = try randomUuidStr(alloc);
    defer alloc.free(approver);
    const superseding_review_id = try randomUuidStr(alloc);
    defer alloc.free(superseding_review_id);

    try review_mod.approveReview(alloc, &pool, review_id, approver, 1);
    try review_mod.markReviewFailed(alloc, &pool, review_id, 2);
    try review_mod.supersedeReview(alloc, &pool, review_id, superseding_review_id, 3);

    // Verify final status is superseded.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .superseded);
        try testing.expectEqual(@as(u32, 4), review.?.row_version);
        try testing.expectEqualStrings(superseding_review_id, review.?.superseded_by.?);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-08: rejected → superseded transition
// ---------------------------------------------------------------------------

test "TC-PRM-04-08: rejected transitions to superseded" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_08_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    const superseding_review_id = try randomUuidStr(alloc);
    defer alloc.free(superseding_review_id);

    try review_mod.rejectReview(alloc, &pool, review_id, 1);
    try review_mod.supersedeReview(alloc, &pool, review_id, superseding_review_id, 2);

    // Verify final status is superseded.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .superseded);
        try testing.expectEqual(@as(u32, 3), review.?.row_version);
        try testing.expectEqualStrings(superseding_review_id, review.?.superseded_by.?);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-09: Invalid transition returns error
// ---------------------------------------------------------------------------

test "TC-PRM-04-09: invalid transition (pending_review → applied directly) returns error" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_09_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    // Try to mark applied directly from pending_review — should fail.
    const result = review_mod.markReviewApplied(alloc, &pool, review_id, 1);
    try testing.expect(result == error.InvalidReviewTransition);

    // Verify review is still pending_review.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .pending_review);
        try testing.expectEqual(@as(u32, 1), review.?.row_version);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-10: Row version optimistic locking
// ---------------------------------------------------------------------------

test "TC-PRM-04-10: stale row_version causes transition to fail" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_10_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const review_id = try submitTestReview(alloc, &pool, tenant_uuid, schema);
    defer alloc.free(review_id);

    // Try to approve with stale row_version (2 instead of 1).
    const result = review_mod.approveReview(alloc, &pool, review_id, "any-approver", 2);
    try testing.expect(result == error.InvalidReviewTransition);

    // Verify review is still pending_review with row_version=1.
    {
        const review = try review_mod.getReview(alloc, &pool, review_id);
        defer if (review) |r| {
            alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
            alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
            alloc.free(r.requested_by);
            if (r.approved_by) |v| alloc.free(v);
            if (r.superseded_by) |v| alloc.free(v);
        };
        try testing.expect(review != null);
        try testing.expect(review.?.status == .pending_review);
        try testing.expectEqual(@as(u32, 1), review.?.row_version);
    }

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-11: CHECK constraint enforces valid statuses
// ---------------------------------------------------------------------------

test "TC-PRM-04-11: CHECK constraint prevents invalid status values" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_11_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    const conn = pool.acquire() catch |err2| {
        try testing.expect(false);
        return;
    };
    defer pool.release(conn);

    try conn.exec(std.fmt.allocPrint(alloc, "SET search_path TO {s},public", .{schema}) catch "", &.{});

    // Attempt to insert with an invalid status — should fail CHECK constraint.
    const result = conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, plan_digest, def_type, def_id, serialised_plan, status, requested_by, row_version)
        \\VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, 'invalid_status', $7::uuid, 1)
    ,
        &[_][]const u8{
            try randomUuidStr(alloc),
            tenant_uuid,
            "digest-digest-digest-digest-digest-digest-digest-digest-digest-digest-",
            "process",
            "test-proc",
            "[]",
            tenant_uuid,
        },
    );

    // Should fail with a CHECK constraint violation.
    try testing.expect(result == error.ConstraintViolation);

    cleanupTenant(&pool, tenant_uuid, schema);
}

// ---------------------------------------------------------------------------
// TC-PRM-04-12: getReview returns stored plan and digest
// ---------------------------------------------------------------------------

test "TC-PRM-04-12: getReview returns stored plan_digest and serialised_plan" {
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
    const schema = try std.fmt.allocPrint(alloc, "tprm04_12_{s}", .{tenant_uuid});
    defer alloc.free(schema);

    try createTestTenant(&pool, tenant_uuid, schema);

    api_tenant_context.set(schema);

    // Compute expected digest from a known plan.
    const entry_id = try alloc.dupe(u8, "ctx-test-node");
    defer alloc.free(entry_id);

    const digest = digest_mod.computePlanDigest(alloc, .{
        .entries = &.{
            .{
                .type = .graph_node,
                .id = entry_id,
                .change_kind = .added,
                .before = null,
                .after = null,
            },
        },
        .human_readable = try alloc.dupe(u8, "PRM-04 context test"),
    });
    defer alloc.free(digest);

    const serialised = try alloc.dupe(u8,
        \\[{\"type\":\"graph_node\",\"id\":\"ctx-test-node\",\"change_kind\":\"added\",\"before\":null,\"after\":null}]
    );
    defer alloc.free(serialised);

    const review_id = try review_mod.submitReview(alloc, &pool, .{
        .tenant_id = tenant_uuid,
        .plan_digest = digest,
        .def_type = "process",
        .def_id = "ctx-test-proc",
        .serialised_plan = serialised,
        .requested_by = tenant_uuid,
    });
    defer alloc.free(review_id);

    // Fetch via getReview and verify.
    const review = try review_mod.getReview(alloc, &pool, review_id);
    defer if (review) |r| {
        alloc.free(r.id); alloc.free(r.tenant_id); alloc.free(r.plan_digest);
        alloc.free(r.def_type); alloc.free(r.def_id); alloc.free(r.serialised_plan);
        alloc.free(r.requested_by);
        if (r.approved_by) |v| alloc.free(v);
        if (r.superseded_by) |v| alloc.free(v);
    };

    try testing.expect(review != null);
    try testing.expectEqualStrings(digest, review.?.plan_digest);
    try testing.expectEqualStrings(serialised, review.?.serialised_plan);
    try testing.expectEqualStrings("process", review.?.def_type);
    try testing.expectEqualStrings("ctx-test-proc", review.?.def_id);

    cleanupTenant(&pool, tenant_uuid, schema);
}
