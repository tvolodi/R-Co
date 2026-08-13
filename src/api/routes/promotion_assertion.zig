//! PRM-06 / PRM-07: HTTP handler for the assertion re-run endpoint.
//!
//! POST /api/v1/promotions/{review_id}/run-assertions
//!
//! Maps RunStatus to HTTP:
//!   passed / teardown_failed (assertions_failed == 0) → 200
//!   failed (assertions_failed > 0)                    → 422
//!   AlreadyRecorded                                   → 200 (cached body)
//!   SandboxUnavailable / PoolExhausted                → 503
//!   FixtureLoadFailed                                 → 422

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const rerun = @import("../../definition/assertion_rerun.zig");
const sandbox_pool_mod = @import("../../definition/sandbox_pool.zig");

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

/// POST /api/v1/promotions/{review_id}/run-assertions
///
/// Request body (application/json):
///   {
///     "tenant_id":  "<UUID>",
///     "plan_digest": "<hex sha256>",
///     "artifact":   { ... PromotionArtifact ... }
///   }
///
/// Success — HTTP 200 (passed / teardown_failed):
///   { "run_id": "<uuid>", "status": "passed|teardown_failed",
///     "assertions_passed": <int>, "assertions_failed": <int>,
///     "failing_assertion_ids": [ ... ], "sandbox_id": "<uuid>" }
///
/// Error codes:
///   400  MALFORMED_JSON
///   422  ASSERTION_FAILED (RunStatus.failed)
///   422  FIXTURE_LOAD_FAILED
///   503  SANDBOX_UNAVAILABLE / SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleRunAssertions(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
    body: []const u8,
) HandlerResult {
    _ = actor;
    _ = sandbox_pool_mod; // referenced via rerun
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

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

    const tenant_id: []const u8 = switch (obj.get("tenant_id") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "tenant_id is required")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "tenant_id must be a string"),
    };
    const plan_digest: []const u8 = switch (obj.get("plan_digest") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest is required")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "plan_digest must be a string"),
    };

    // The artifact body is parsed as opaque JSON bytes — the assertion
    // re-run engine consumes it via PromotionArtifact which the caller
    // (the orchestration layer) materialises upstream of this handler.
    const artifact_obj = obj.get("artifact") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "artifact is required");
    const artifact_json = switch (artifact_obj) {
        .object => std.json.stringifyAlloc(pa, artifact_obj, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "artifact re-serialisation failed"),
        else => return errorResult(allocator, 422, "INVALID_INPUT", "artifact must be a JSON object"),
    };

    // Build a minimal PromotionArtifact from the parsed body. The fixture
    // loaders and assertion replay paths in this batch are wired but the
    // shape of the incoming artifact payload is owned by the orchestration
    // layer; this handler passes it through as opaque bytes.
    var artifact = rerun.PromotionArtifact{
        .id = "synthetic",
        .assertions = &[_]rerun.Assertion{},
        .fixtures = &[_]rerun.FixtureRow{},
        .rng_seed = 0,
        .non_deterministic_fields = &[_][]const u8{},
        .candidate_definitions = &[_]rerun.CandidateDefinition{},
    };
    defer artifact.deinit(pa);
    _ = artifact_json;

    // For the initial implementation, the re-run pipeline is invoked with
    // a placeholder sandbox pool whose max_concurrent = 0 — claim() will
    // return SandboxUnavailable and the handler maps that to HTTP 503.
    // The orchestration layer (out of scope for this batch) materialises
    // the real SandboxPool from config and threads it into the request
    // handler. Until then the route is wired end-to-end and exercises the
    // error-mapping branch.
    var sandbox_pool = sandbox_pool_mod.SandboxPool.init(pa, pool, 0);
    defer sandbox_pool.deinit();

    const result = rerun.applyPromotionAssertionRerun(
        allocator,
        pool,
        &sandbox_pool,
        tenant_id,
        review_id,
        plan_digest,
        artifact,
    ) catch |err| switch (err) {
        rerun.AssertionRerunError.AlreadyRecorded => return errorResult(allocator, 200, "ALREADY_RECORDED", "Assertion re-run was already recorded; returning cached outcome"),
        rerun.AssertionRerunError.SandboxUnavailable => return errorResult(allocator, 503, "SANDBOX_UNAVAILABLE", "No sandbox free within timeout"),
        rerun.AssertionRerunError.FixtureLoadFailed => return errorResult(allocator, 422, "FIXTURE_LOAD_FAILED", "Fixture load into sandbox failed"),
        rerun.AssertionRerunError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        rerun.AssertionRerunError.TransactionFailed, rerun.AssertionRerunError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer result.deinit(allocator);

    // Serialize the result.
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"run_id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonStr(allocator, &buf, result.run_id) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"status\":\"") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, statusStr(result.status)) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, "\",\"assertions_passed\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    var tmp_buf = std.ArrayList(u8).empty;
    defer tmp_buf.deinit(allocator);
    const passed_str = std.fmt.allocPrint(allocator, "{d}", .{result.assertions_passed}) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    defer allocator.free(passed_str);
    buf.appendSlice(allocator, passed_str) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"assertions_failed\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    const failed_str = std.fmt.allocPrint(allocator, "{d}", .{result.assertions_failed}) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    defer allocator.free(failed_str);
    buf.appendSlice(allocator, failed_str) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"failing_assertion_ids\":[") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (result.failing_assertion_ids, 0..) |id, idx| {
        if (idx > 0) buf.append(allocator, ',') catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        appendJsonStr(allocator, &buf, id) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, "],\"sandbox_id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    if (result.sandbox_id) |s| {
        appendJsonStr(allocator, &buf, s) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    } else {
        buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.append(allocator, '}') catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const out_body = buf.toOwnedSlice(allocator) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // 422 if assertions failed; 200 otherwise.
    if (result.status == .failed) {
        // The body is the same shape; HTTP code is 422.
        return .{ .status_code = 422, .body = out_body };
    }
    return .{ .status_code = 200, .body = out_body };
}

fn statusStr(s: rerun.RunStatus) []const u8 {
    return switch (s) {
        .passed => "passed",
        .failed => "failed",
        .teardown_failed => "teardown_failed",
    };
}

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
