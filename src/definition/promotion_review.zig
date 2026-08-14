//! PRM-04: Promotion review state machine
//!
//! Manages the promotion_reviews table — the central state machine for the
//! promotion pipeline. Records who requested a promotion, what plan was approved,
//! who approved it, and whether it has been applied/rejected/failed/superseded.
//! Status is CHECK-constrained to exactly six values. All transitions are ACID.
//!
//! Design artefact: src/design/prm-04-promotion-review-state-machine.md

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");

// ── Public types ────────────────────────────────────────────────────────────────

pub const ReviewStatus = enum {
    pending_review,
    approved,
    rejected,
    applied,
    failed,
    superseded,
};

pub const ReviewRecord = struct {
    id: []const u8,
    tenant_id: []const u8,
    plan_digest: []const u8,
    def_type: []const u8,
    def_id: []const u8,
    serialised_plan: []const u8,
    status: ReviewStatus,
    requested_by: []const u8,
    approved_by: ?[]const u8,
    approved_at: ?i64,
    superseded_by: ?[]const u8,
    row_version: u32,
    created_at: i64,
    updated_at: i64,
};

pub const ReviewTransitionError = error{
    InvalidReviewTransition,
    DuplicateReview,
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

/// Input for submitting a new promotion review.
pub const SubmitReviewParams = struct {
    tenant_id: []const u8,
    plan_digest: []const u8,
    def_type: []const u8,
    def_id: []const u8,
    serialised_plan: []const u8,
    requested_by: []const u8,
};

// ── Public API ─────────────────────────────────────────────────────────────────

/// Submits a new promotion review (INSERT with status = pending_review).
/// Returns the new review_id (UUID string, caller-owned).
/// On partial unique index violation → DuplicateReview.
pub fn submitReview(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    params: SubmitReviewParams,
) (ReviewTransitionError || error{OutOfMemory})![]const u8 {
    // Save/restore tenant context.
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\INSERT INTO promotion_reviews
        \\  (tenant_id, plan_digest, def_type, def_id, serialised_plan, requested_by)
        \\VALUES ($1::uuid, $2, $3, $4, $5, $6::uuid)
        \\RETURNING id::text
    ,
        &[_][]const u8{
            params.tenant_id,
            params.plan_digest,
            params.def_type,
            params.def_id,
            params.serialised_plan,
            params.requested_by,
        },
    ) catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return ReviewTransitionError.PoolExhausted,
        // Partial unique index violation on (tenant_id, plan_digest) WHERE active.
        else => return ReviewTransitionError.DuplicateReview,
    };

    if (row == null) return ReviewTransitionError.DuplicateReview;
    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
    const review_id = r[0] orelse return ReviewTransitionError.TransactionFailed;
    return allocator.dupe(u8, review_id) catch return error.OutOfMemory;
}

/// Approves a review: pending_review → approved.
/// Gate: caller checks status == pending_review, row_version match, digest match,
/// and reviewer != requested_by BEFORE calling this.
/// On row_version mismatch → InvalidReviewTransition.
pub fn approveReview(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
    actor_id: []const u8,
    expected_row_version: u32,
) ReviewTransitionError!void {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const result = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews
        \\SET status = 'approved',
        \\    approved_by = $1::uuid,
        \\    approved_at = now(),
        \\    row_version = row_version + 1,
        \\    updated_at = now()
        \\WHERE id = $2::uuid AND row_version = $3
        \\RETURNING id
    ,
        &[_][]const u8{ actor_id, review_id, try fmtInt(allocator, expected_row_version) },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (result == null) return ReviewTransitionError.InvalidReviewTransition;
    const r = result.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
}

/// Rejects a review: pending_review → rejected.
/// Gate: caller checks status == pending_review BEFORE calling this.
pub fn rejectReview(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
    expected_row_version: u32,
) ReviewTransitionError!void {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const result = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews
        \\SET status = 'rejected',
        \\    row_version = row_version + 1,
        \\    updated_at = now()
        \\WHERE id = $1::uuid AND row_version = $2
        \\RETURNING id
    ,
        &[_][]const u8{ review_id, try fmtInt(allocator, expected_row_version) },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (result == null) return ReviewTransitionError.InvalidReviewTransition;
    const r = result.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
}

/// Marks a review as applied: approved → applied.
pub fn markReviewApplied(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
    expected_row_version: u32,
) ReviewTransitionError!void {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const result = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews
        \\SET status = 'applied',
        \\    row_version = row_version + 1,
        \\    updated_at = now()
        \\WHERE id = $1::uuid AND row_version = $2
        \\RETURNING id
    ,
        &[_][]const u8{ review_id, try fmtInt(allocator, expected_row_version) },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (result == null) return ReviewTransitionError.InvalidReviewTransition;
    const r = result.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
}

/// Marks a review as failed: approved → failed.
pub fn markReviewFailed(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
    expected_row_version: u32,
) ReviewTransitionError!void {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const result = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews
        \\SET status = 'failed',
        \\    row_version = row_version + 1,
        \\    updated_at = now()
        \\WHERE id = $1::uuid AND row_version = $2
        \\RETURNING id
    ,
        &[_][]const u8{ review_id, try fmtInt(allocator, expected_row_version) },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (result == null) return ReviewTransitionError.InvalidReviewTransition;
    const r = result.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
}

/// Supersedes a review: sets superseded_by to the superseding review_id.
/// Used for: applied→superseded (PRM-08 rollback), failed→superseded, rejected→superseded.
pub fn supersedeReview(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
    superseding_review_id: []const u8,
    expected_row_version: u32,
) ReviewTransitionError!void {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const result = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews
        \\SET status = 'superseded',
        \\    superseded_by = $1::uuid,
        \\    row_version = row_version + 1,
        \\    updated_at = now()
        \\WHERE id = $2::uuid AND row_version = $3
        \\RETURNING id
    ,
        &[_][]const u8{ superseding_review_id, review_id, try fmtInt(allocator, expected_row_version) },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (result == null) return ReviewTransitionError.InvalidReviewTransition;
    const r = result.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
}

/// Fetches a review by id. Returns null if not found.
/// Caller must free returned strings.
pub fn getReview(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
) (ReviewTransitionError || error{OutOfMemory})!?ReviewRecord {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, tenant_id::text, plan_digest, def_type, def_id,
        \\       serialised_plan, status, requested_by::text, approved_by::text,
        \\       EXTRACT(EPOCH FROM approved_at)::bigint AS approved_at,
        \\       superseded_by::text,
        \\       row_version,
        \\       EXTRACT(EPOCH FROM created_at)::bigint AS created_at,
        \\       EXTRACT(EPOCH FROM updated_at)::bigint AS updated_at
        \\FROM promotion_reviews
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{review_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ReviewTransitionError.PoolExhausted,
        else => ReviewTransitionError.TransactionFailed,
    };

    if (row == null) return null;

    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }

    const status_str = r[6] orelse "pending_review";
    const status = parseReviewStatus(status_str) orelse .pending_review;

    const approved_at_raw = r[9];
    const approved_at: ?i64 = if (approved_at_raw) |s|
        std.fmt.parseInt(i64, s, 10) catch null
    else
        null;

    const created_at_raw = r[13] orelse "0";
    const updated_at_raw = r[14] orelse "0";

    return ReviewRecord{
        .id = allocator.dupe(u8, r[0] orelse "") catch return error.OutOfMemory,
        .tenant_id = allocator.dupe(u8, r[1] orelse "") catch return error.OutOfMemory,
        .plan_digest = allocator.dupe(u8, r[2] orelse "") catch return error.OutOfMemory,
        .def_type = allocator.dupe(u8, r[3] orelse "") catch return error.OutOfMemory,
        .def_id = allocator.dupe(u8, r[4] orelse "") catch return error.OutOfMemory,
        .serialised_plan = allocator.dupe(u8, r[5] orelse "") catch return error.OutOfMemory,
        .status = status,
        .requested_by = allocator.dupe(u8, r[7] orelse "") catch return error.OutOfMemory,
        .approved_by = if (r[8]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
        .approved_at = approved_at,
        .superseded_by = if (r[11]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
        .row_version = std.fmt.parseInt(u32, r[12] orelse "1", 10) catch 1,
        .created_at = std.fmt.parseInt(i64, created_at_raw, 10) catch 0,
        .updated_at = std.fmt.parseInt(i64, updated_at_raw, 10) catch 0,
    };
}

// ── Internal helpers ────────────────────────────────────────────────────────────

fn fmtInt(allocator: std.mem.Allocator, v: u32) (error{OutOfMemory} || error{Any})![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{v});
}

fn parseReviewStatus(s: []const u8) ?ReviewStatus {
    if (std.mem.eql(u8, s, "pending_review")) return .pending_review;
    if (std.mem.eql(u8, s, "approved")) return .approved;
    if (std.mem.eql(u8, s, "rejected")) return .rejected;
    if (std.mem.eql(u8, s, "applied")) return .applied;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "superseded")) return .superseded;
    return null;
}
