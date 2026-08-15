//! PRM-04 + PRM-05: HTTP handlers for promotion review state machine + approval gate.
//!
//! Routes:
//!   POST   /api/v1/promotions              — submit plan, create pending review (PRM-01+PRM-02+PRM-03+PRM-04)
//!   GET    /api/v1/promotions/:id/context  — get review context + stored plan/digest (PRM-05)
//!   POST   /api/v1/promotions/:id/approve  — approve a review (PRM-05)
//!   POST   /api/v1/promotions/:id/reject   — reject a review (PRM-04)
//!   POST   /api/v1/promotions/:id/apply    — apply an approved review (PRM-05 non-skippable gate)
//!
//! Design artefacts:
//!   src/design/prm-04-promotion-review-state-machine.md
//!   src/design/prm-05-non-skippable-approval-gate.md

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const plan_mod = @import("../../definition/promotion_plan.zig");
const conflict_mod = @import("../../definition/promotion_conflict.zig");
const digest_mod = @import("../../definition/promotion_digest.zig");
const review_mod = @import("../../definition/promotion_review.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"message\":\"{s}\"}}",
        .{ code, message },
    ) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

// ── POST /api/v1/promotions — submit plan and create pending review ──────────────

/// Request body for POST /api/v1/promotions
/// Extends PRM-01: adds base_version, target_tenant_id, source_tenant_id.
const SubmitPromotionBody = struct {
    source_tenant_id: []const u8,
    target_tenant_id: []const u8,
    process_key: []const u8,
    base_version: u32,
};

/// POST /api/v1/promotions
///
/// Creates a promotion plan (PRM-01), checks for conflicts (PRM-02),
/// computes digest (PRM-03), and inserts a pending review (PRM-04).
///
/// Success — HTTP 201:
///   { "review_id": "<uuid>", "plan_digest": "<64-char hex>" }
///
/// Error codes:
///   400  MALFORMED_JSON
///   403  FORBIDDEN
///   404  SOURCE_DEFINITION_NOT_FOUND
///   409  PROMOTION_CONFLICT   (PRM-02)
///   409  DUPLICATE_REVIEW     (PRM-04 partial unique index)
///   422  EMPTY_PROMOTION_PLAN
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleSubmitPromotion(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    // Parse request body.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        pa,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object"),
    };

    const source_tenant_id = obj.get("source_tenant_id") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "source_tenant_id is required");
    const source_tenant_id_str: []const u8 = switch (source_tenant_id) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "source_tenant_id must be a string"),
    };

    const target_tenant_id = obj.get("target_tenant_id") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "target_tenant_id is required");
    const target_tenant_id_str: []const u8 = switch (target_tenant_id) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "target_tenant_id must be a string"),
    };

    const process_key = obj.get("process_key") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "process_key is required");
    const process_key_str: []const u8 = switch (process_key) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "process_key must be a string"),
    };

    const base_version_val = obj.get("base_version") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "base_version is required");
    const base_version: u32 = switch (base_version_val) {
        .integer => |v| @intCast(v),
        .string => std.fmt.parseInt(u32, base_version_val.string, 10) catch
            return errorResult(allocator, 422, "INVALID_INPUT", "base_version must be a non-negative integer"),
        else => return errorResult(allocator, 422, "INVALID_INPUT", "base_version must be a non-negative integer"),
    };

    // Step 1: compute plan (PRM-01).
    const plan = plan_mod.computePromotionPlan(
        allocator,
        pool,
        actor.user_id,
        source_tenant_id_str,
        target_tenant_id_str,
        process_key_str,
    ) catch |err| switch (err) {
        plan_mod.PlanError.Forbidden => return errorResult(allocator, 403, "FORBIDDEN", "Caller lacks promotion.submit"),
        plan_mod.PlanError.InvalidPromotionSource => return errorResult(allocator, 422, "INVALID_PROMOTION_SOURCE", "source_tenant_id must name a test tenant"),
        plan_mod.PlanError.EmptyPromotionPlan => return errorResult(allocator, 422, "EMPTY_PROMOTION_PLAN", "Source and target are identical after canonicalisation"),
        plan_mod.PlanError.SourceDefinitionNotFound => return errorResult(allocator, 404, "SOURCE_DEFINITION_NOT_FOUND", "No ACTIVE definition found for process_key in the source tenant"),
        plan_mod.PlanError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        plan_mod.PlanError.TransactionFailed, plan_mod.PlanError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer plan.deinit(allocator);

    // Step 2: conflict check (PRM-02) — runs BEFORE any transaction opens.
    // Use a synthetic promotion_id for the event idempotency key.
    var promotion_id_buf: [36]u8 = undefined;
    const promotion_id = genUuidStr(&promotion_id_buf);

    const rejection = conflict_mod.rejectIfConflicts(
        allocator,
        pool,
        target_tenant_id_str,
        process_key_str,
        base_version,
        promotion_id,
        source_tenant_id_str,
        actor.user_id,
    ) catch |err| switch (err) {
        conflict_mod.ConflictCheckError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        conflict_mod.ConflictCheckError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (rejection) |*r| {
        defer r.deinit(allocator);
        // Conflict detected — return HTTP 409 with details.
        const conflict_body = std.fmt.allocPrint(
            allocator,
            \\{{"error":"PROMOTION_CONFLICT","message":"Target tenant has advanced past base_version","conflicts":[{{"process_key":"{s}","target_definition_id":"{s}","target_version":{d},"source_change":"{s}","target_change":"{s}"}}]}}
        ,
            .{
                process_key_str,
                r.target_definition_id,
                r.target_version,
                r.source_change,
                r.target_change,
            },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");
        return .{ .status_code = 409, .body = conflict_body };
    }

    // Step 3: compute digest (PRM-03).
    const plan_digest = digest_mod.computePlanDigest(allocator, plan);
    defer allocator.free(plan_digest);

    // Step 4: serialise plan for storage.
    const serialised_plan = serialisePlanForStorage(allocator, plan) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to serialise plan");
    defer allocator.free(serialised_plan);

    // Step 5: INSERT promotion_reviews row (PRM-04).
    const review_id = review_mod.submitReview(allocator, pool, .{
        .tenant_id = target_tenant_id_str,
        .plan_digest = plan_digest,
        .def_type = "process",
        .def_id = process_key_str,
        .serialised_plan = serialised_plan,
        .requested_by = actor.user_id,
    }) catch |err| switch (err) {
        review_mod.ReviewTransitionError.DuplicateReview => return errorResult(allocator, 409, "DUPLICATE_REVIEW", "A live review for this plan digest already exists"),
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer allocator.free(review_id);

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"review_id\":\"{s}\",\"plan_digest\":\"{s}\"}}",
        .{ review_id, plan_digest },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");

    return .{ .status_code = 201, .body = response_body };
}

// ── GET /api/v1/promotions/:id/context — stored plan + digest for reviewer ──────

/// GET /api/v1/promotions/{id}/context
///
/// Returns the stored plan, digest, and review metadata.
/// Data comes from the stored serialised_plan on the promotion_reviews row,
/// NEVER from a live re-computation.
///
/// Success — HTTP 200:
///   { "review_id": "<uuid>", "plan_digest": "<64-hex>", "serialised_plan": "<json>",
///     "status": "<status>", "requested_by": "<uuid>", "def_type": "<string>",
///     "def_id": "<string>", "created_at": "<iso8601>" }
///
/// Error codes:
///   404  REVIEW_NOT_FOUND
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleGetPromotionContext(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
) HandlerResult {
    _ = actor;

    const review = review_mod.getReview(allocator, pool, review_id) catch |err| switch (err) {
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (review == null) {
        return errorResult(allocator, 404, "REVIEW_NOT_FOUND", "No review found with the given id");
    }

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

    const status_str = switch (r.status) {
        .pending_review => "pending_review",
        .approved => "approved",
        .rejected => "rejected",
        .applied => "applied",
        .failed => "failed",
        .superseded => "superseded",
    };

    const created_at_iso = timestampToIso(r.created_at);
    defer allocator.free(created_at_iso);

    // PRM-05 AC5: the context response carries the stored plan, `assertions[]`,
    // the `NEEDS_REVIEW` package and `plan_digest` in one document. The
    // assertions are derived from the stored plan (design OQ-2 — the artifact
    // store is not wired in this batch), so the reviewer decides on exactly the
    // diff the digest binds.
    const built = buildContextAssertionsAndPackage(allocator, r.serialised_plan, r.def_type, r.def_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to build context assertions");
    defer {
        allocator.free(built.assertions);
        allocator.free(built.package);
    }

    const response_body = std.fmt.allocPrint(
        allocator,
        \\{{"review_id":"{s}","plan_digest":"{s}","serialised_plan":{s},"assertions":{s},"needs_review_package":{s},"status":"{s}","requested_by":"{s}","def_type":"{s}","def_id":"{s}","created_at":"{s}","row_version":{d}}}
    ,
        .{
            r.id,
            r.plan_digest,
            r.serialised_plan,
            built.assertions,
            built.package,
            status_str,
            r.requested_by,
            r.def_type,
            r.def_id,
            created_at_iso,
            r.row_version,
        },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");

    return .{ .status_code = 200, .body = response_body };
}

// ── POST /api/v1/promotions/:id/approve ───────────────────────────────────────

const ApproveBody = struct {
    plan_digest: []const u8,
};

/// POST /api/v1/promotions/{id}/approve
///
/// Request body: { "plan_digest": "<64-hex>" } — exactly one field.
///
/// INV-2 (server-side field authorisation): the approver identity is NOT
/// accepted from the request body. It is derived from the authenticated
/// principal (`actor.user_id`) server-side, so no caller can fabricate a
/// different `approved_by` to bypass the PRM-05 separation-of-duties gate.
///
/// PRM-05 gates: (1) actor.user_id != requested_by → 403 SelfApprovalForbidden,
/// (2) status == pending_review → 400, (3) digest match → 409.
///
/// Success — HTTP 200: { "review_id": "<uuid>", "status": "approved" }
/// Error codes:
///   400  INVALID_REVIEW_TRANSITION
///   403  SELF_APPROVAL_FORBIDDEN
///   404  REVIEW_NOT_FOUND
///   409  PLAN_DIGEST_MISMATCH
///   409  DUPLICATE_REVIEW
///   422  UNKNOWN_FIELD  (approved_by or any other extra field → 422)
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleApproveReview(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
    body: []const u8,
) HandlerResult {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, pa, body, .{ .allocate = .alloc_always }) catch
        return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object"),
    };

    // Extract plan_digest.
    const pd_val = obj.get("plan_digest") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest is required");
    const plan_digest: []const u8 = switch (pd_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest must be a string"),
    };

    // Check for extra fields (PRM-05 AC3 — no bypass fields allowed).
    // INV-2: `approved_by` is deliberately NOT a legal body field here — the
    // approver is the authenticated actor, so any supplied identity field is
    // rejected with 422 UNKNOWN_FIELD rather than silently ignored.
    for (obj.keys()) |key| {
        if (!std.mem.eql(u8, key, "plan_digest")) {
            return errorResult(allocator, 422, "UNKNOWN_FIELD", "Unknown field in request body");
        }
    }

    // Fetch the review to check self-approval, status, and digest.
    const review = review_mod.getReview(allocator, pool, review_id) catch |err| switch (err) {
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (review == null) {
        return errorResult(allocator, 404, "REVIEW_NOT_FOUND", "No review found with the given id");
    }

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

    // Gate 1: self-approval prevention (PRM-05 AC1).
    // INV-2: the approver is the authenticated actor, so the gate compares
    // two server-side values (actor.user_id vs the stored requested_by) — a
    // caller cannot pick a fabricated approved_by to dodge it.
    if (std.mem.eql(u8, r.requested_by, actor.user_id)) {
        return errorResult(allocator, 403, "SELF_APPROVAL_FORBIDDEN", "A reviewer cannot approve their own promotion request");
    }

    // Gate 2: status must be pending_review (PRM-04 AC1).
    if (r.status != .pending_review) {
        return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review must be in pending_review status to be approved");
    }

    // Gate 3: digest must match (PRM-03).
    if (!digest_mod.verifyDigest(r.plan_digest, plan_digest)) {
        return errorResult(allocator, 409, "PLAN_DIGEST_MISMATCH", "The provided plan_digest does not match the stored digest");
    }

    // Perform the transition under the review's owner tenant, recording the
    // authenticated actor as the approver (INV-2 + INV-1/INV-6).
    review_mod.approveReview(allocator, pool, review_id, r.tenant_id, actor.user_id, r.row_version) catch |err| switch (err) {
        review_mod.ReviewTransitionError.InvalidReviewTransition => return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review transition failed — possible concurrent update"),
        review_mod.ReviewTransitionError.DuplicateReview => return errorResult(allocator, 409, "DUPLICATE_REVIEW", "A live review for this plan digest already exists"),
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"review_id\":\"{s}\",\"status\":\"approved\"}}",
        .{review_id},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");

    return .{ .status_code = 200, .body = response_body };
}

// ── POST /api/v1/promotions/:id/reject ─────────────────────────────────────────

/// POST /api/v1/promotions/{id}/reject
///
/// Request body: {} (empty — no digest needed for rejection per PRM-04 AC1)
///
/// Success — HTTP 200: { "review_id": "<uuid>", "status": "rejected" }
/// Error codes:
///   400  INVALID_REVIEW_TRANSITION
///   404  REVIEW_NOT_FOUND
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleRejectReview(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
    body: []const u8,
) HandlerResult {
    _ = actor;

    // Empty body is OK.
    if (body.len > 0) {
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const pa = parse_arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, pa, body, .{ .allocate = .alloc_always }) catch
            return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");

        if (parsed.value != .null) {
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object or empty"),
            };
            for (obj.keys()) |key| {
                _ = key;
                return errorResult(allocator, 422, "UNKNOWN_FIELD", "Unknown field in request body");
            }
        }
    }

    // Fetch the review to check status and row_version.
    const review = review_mod.getReview(allocator, pool, review_id) catch |err| switch (err) {
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (review == null) {
        return errorResult(allocator, 404, "REVIEW_NOT_FOUND", "No review found with the given id");
    }

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

    // Gate: status must be pending_review.
    if (r.status != .pending_review) {
        return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review must be in pending_review status to be rejected");
    }

    // No self-approval check for rejection (PRM-05: only approval requires separation of duties).
    // The transition runs under the review's owner tenant (INV-1/INV-6).
    review_mod.rejectReview(allocator, pool, review_id, r.tenant_id, r.row_version) catch |err| switch (err) {
        review_mod.ReviewTransitionError.InvalidReviewTransition => return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review transition failed"),
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"review_id\":\"{s}\",\"status\":\"rejected\"}}",
        .{review_id},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");

    return .{ .status_code = 200, .body = response_body };
}

// ── POST /api/v1/promotions/:id/apply ──────────────────────────────────────────

const ApplyBody = struct {
    plan_digest: []const u8,
};

/// POST /api/v1/promotions/{id}/apply
///
/// Request body: { "plan_digest": "<64-hex>" }
///
/// PRM-05 non-skippable gate: status must be 'approved' (NO bypass).
/// Digest must match stored digest.
///
/// Success — HTTP 200: { "review_id": "<uuid>", "status": "applied" }
/// Error codes:
///   400  INVALID_REVIEW_TRANSITION  (status != approved)
///   404  REVIEW_NOT_FOUND
///   409  PLAN_DIGEST_MISMATCH
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleApplyReview(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
    body: []const u8,
) HandlerResult {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, pa, body, .{ .allocate = .alloc_always }) catch
        return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object"),
    };

    const pd_val = obj.get("plan_digest") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest is required");
    const plan_digest: []const u8 = switch (pd_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest must be a string"),
    };

    // Check for extra fields (PRM-05 AC3 — no bypass fields allowed).
    for (obj.keys()) |key| {
        if (!std.mem.eql(u8, key, "plan_digest")) {
            return errorResult(allocator, 422, "UNKNOWN_FIELD", "Unknown field in request body");
        }
    }

    // Fetch the review.
    const review = review_mod.getReview(allocator, pool, review_id) catch |err| switch (err) {
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (review == null) {
        return errorResult(allocator, 404, "REVIEW_NOT_FOUND", "No review found with the given id");
    }

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

    // Gate: status must be approved (PRM-05 — non-skippable, no bypass parameter).
    if (r.status != .approved) {
        return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review must be in approved status to be applied");
    }

    // Gate: digest must match.
    if (!digest_mod.verifyDigest(r.plan_digest, plan_digest)) {
        return errorResult(allocator, 409, "PLAN_DIGEST_MISMATCH", "The provided plan_digest does not match the stored digest");
    }

    // Transition under the review's owner tenant; the DEFINITION_PROMOTION_APPLIED
    // event actor is the authenticated applying principal (INV-1/INV-2).
    review_mod.markReviewApplied(allocator, pool, review_id, r.tenant_id, actor.user_id, r.row_version) catch |err| switch (err) {
        review_mod.ReviewTransitionError.InvalidReviewTransition => return errorResult(allocator, 400, "INVALID_REVIEW_TRANSITION", "Review transition failed"),
        review_mod.ReviewTransitionError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        review_mod.ReviewTransitionError.TransactionFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"review_id\":\"{s}\",\"status\":\"applied\"}}",
        .{review_id},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");

    return .{ .status_code = 200, .body = response_body };
}

// ── Internal helpers ────────────────────────────────────────────────────────────

const ContextAssertions = struct {
    assertions: []const u8, // JSON array fragment — the context `assertions[]` field
    package: []const u8, // JSON object fragment — the `needs_review_package` field
};

/// Derives the `assertions[]` and `needs_review_package` fields of the context
/// response from the STORED plan (PRM-05 AC5): each plan entry becomes a human
/// review assertion naming exactly the change the digest binds. This resolves
/// design Open question 2 ("or whether the artifact is resolved another way"):
/// the promotion artifact store is not yet wired in this batch, so the
/// assertions are derived deterministically from the stored plan rather than an
/// artifact lookup. Both returned slices are caller-owned.
fn buildContextAssertionsAndPackage(
    allocator: std.mem.Allocator,
    serialised_plan: []const u8,
    def_type: []const u8,
    def_id: []const u8,
) !ContextAssertions {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var assertions_buf = std.ArrayList(u8).empty;
    defer assertions_buf.deinit(allocator);
    var package_buf = std.ArrayList(u8).empty;
    defer package_buf.deinit(allocator);

    try assertions_buf.append(allocator, '[');
    try package_buf.appendSlice(allocator, "{\"marker\":\"NEEDS_REVIEW\",\"assertions\":[");

    // The stored plan is canonical JSON: an array of {changes,id,type} objects.
    // A malformed stored plan must not fail the context read — the reviewer
    // still needs the digest + raw plan; return empty assertions in that case.
    const parsed = std.json.parseFromSlice(std.json.Value, aa, serialised_plan, .{ .allocate = .alloc_always }) catch {
        try package_buf.append(allocator, ']');
        try package_buf.append(allocator, '}');
        try assertions_buf.append(allocator, ']');
        return .{
            .assertions = try assertions_buf.toOwnedSlice(allocator),
            .package = try package_buf.toOwnedSlice(allocator),
        };
    };
    const arr: []const std.json.Value = switch (parsed.value) {
        .array => |a| a,
        else => &.{},
    };

    var first = true;
    for (arr) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const id_val = obj.get("id") orelse continue;
        const type_val = obj.get("type") orelse continue;
        const id_str = switch (id_val) {
            .string => |s| s,
            else => continue,
        };
        const type_str = switch (type_val) {
            .string => |s| s,
            else => continue,
        };
        const kind_str: []const u8 = blk: {
            const changes = obj.get("changes") orelse break :blk "unknown";
            const changes_obj = switch (changes) {
                .object => |o| o,
                else => break :blk "unknown",
            };
            const ck = changes_obj.get("change_kind") orelse break :blk "unknown";
            break :blk switch (ck) {
                .string => |s| s,
                else => "unknown",
            };
        };

        if (!first) {
            try assertions_buf.append(allocator, ',');
            try package_buf.append(allocator, ',');
        }
        first = false;

        // assertions[i] = {"id": ..., "type": ..., "change_kind": ...}
        try assertions_buf.appendSlice(allocator, "{\"id\":");
        try appendJsonStr(allocator, &assertions_buf, id_str);
        try assertions_buf.appendSlice(allocator, ",\"type\":");
        try appendJsonStr(allocator, &assertions_buf, type_str);
        try assertions_buf.appendSlice(allocator, ",\"change_kind\":");
        try appendJsonStr(allocator, &assertions_buf, kind_str);
        try assertions_buf.append(allocator, '}');

        // NEEDS_REVIEW package assertion — HumanReviewAssertion shape
        // {id, description, severity, rule, sources: [{file, line}]}
        try package_buf.appendSlice(allocator, "{\"id\":");
        try appendJsonStr(allocator, &package_buf, id_str);
        try package_buf.appendSlice(allocator, ",\"description\":\"Review ");
        try package_buf.appendSlice(allocator, kind_str);
        try package_buf.appendSlice(allocator, " of ");
        try package_buf.appendSlice(allocator, type_str);
        try package_buf.appendSlice(allocator, " ");
        try appendJsonStr(allocator, &package_buf, id_str);
        try package_buf.appendSlice(allocator, "\",\"severity\":\"required\",\"rule\":\"human_review_of_promotion_diff\",\"sources\":[{\"file\":");
        // file = "<def_type>/<def_id>"
        var file_buf = std.ArrayList(u8).empty;
        defer file_buf.deinit(allocator);
        try file_buf.appendSlice(allocator, def_type);
        try file_buf.append(allocator, '/');
        try file_buf.appendSlice(allocator, def_id);
        try appendJsonStr(allocator, &package_buf, file_buf.items);
        try package_buf.appendSlice(allocator, ",\"line\":0}]}");
    }

    try assertions_buf.append(allocator, ']');
    try package_buf.appendSlice(allocator, "]}");
    return .{
        .assertions = try assertions_buf.toOwnedSlice(allocator),
        .package = try package_buf.toOwnedSlice(allocator),
    };
}

fn serialisePlanForStorage(allocator: std.mem.Allocator, plan: plan_mod.PromotionPlan) ![]const u8 {
    // The stored plan is the canonical serialisation over which the digest is
    // computed (PRM-03), so a reviewer can recompute the digest over the stored
    // plan to confirm binding (PRM-03 AC5). No separate 5-key shape: digest and
    // stored plan are one and the same canonical JSON.
    return digest_mod.serialisePlanCanonical(allocator, plan);
}

/// Escapes a string for JSON. Returns an allocated string owned by the caller.
fn appendJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// Generate a synthetic UUID string for a promotion_id.
/// Uses a simple format: a random UUID v4 string.
fn genUuidStr(buf: *[36]u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    const uuid_bytes = std.crypto.random.bytes(16);
    var j: usize = 0;
    for (uuid_bytes, 0..) |b, i| {
        buf[j] = hex_chars[b >> 4];
        buf[j + 1] = hex_chars[b & 0xf];
        j += 2;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            j += 1; // skip for dashes
        }
    }
    // Insert dashes: 8-4-4-4-12
    @memcpy(buf[8..9], "-");
    @memcpy(buf[13..14], "-");
    @memcpy(buf[18..19], "-");
    @memcpy(buf[23..24], "-");
    return buf[0..36];
}

/// Convert a Unix timestamp (seconds) to ISO 8601 string.
fn timestampToIso(ts: i64) []const u8 {
    // This is a simplified version; in production use std.time.Tm for full formatting.
    // Return an approximate ISO string; caller must free.
    // For now, return "1970-01-01T00:00:00Z" placeholder — the real implementation
    // would use std.time.Tm but requires a more complex approach in this context.
    // We use a thread-local buffer approach similar to other codebase patterns.
    var buf: [30]u8 = undefined;
    const len = std.fmt.formatIntBuf(buf[0..], ts, 10, false, .{});
    // Format as Unix epoch — actual ISO conversion needs std.time.
    // Return the raw number as string for now (caller sees this is a rough implementation).
    _ = len;
    return "1970-01-01T00:00:00Z"; // TODO: proper ISO formatting
}
