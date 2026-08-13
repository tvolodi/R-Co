//! PRM-07 AC3: GET endpoint surfacing assertion run state for a promotion review.
//!
//! GET /api/v1/promotions/{id}
//!
//! Returns the most recent promotion_assertion_runs row for the given review_id,
//! including teardown_failed info when present.
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md
//! Section: '## PRM-07 design — ### 4. Read endpoint surfacing (PRM-07 AC3)'

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");

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

/// GET /api/v1/promotions/{id}
///
/// Path parameter `id` is the promotion review UUID (`review_id`).
///
/// Success — HTTP 200:
///   { "assertion_run": {
///       "run_id":              "<uuid>",
///       "status":              "passed|failed|teardown_failed|running",
///       "sandbox_id":          "<uuid or null>",
///       "teardown_error":      "<string or null>",
///       "assertions_passed":   <int>,
///       "assertions_failed":   <int>,
///       "failing_assertion_ids": [...]
///     }
///   }
///   or { "assertion_run": null } when no run row exists for this review_id.
///
/// Error codes:
///   503  SERVICE_UNAVAILABLE
///   500  INTERNAL_ERROR
pub fn handleGetPromotion(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    review_id: []const u8,
) HandlerResult {
    _ = actor;

    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, status, sandbox_id::text, teardown_error,
        \\       assertions_passed::text, assertions_failed::text,
        \\       COALESCE(failing_assertion_ids::text, '[]')
        \\  FROM promotion_assertion_runs
        \\ WHERE review_id = $1::uuid
        \\ ORDER BY created_at DESC
        \\ LIMIT 1
    ,
        &[_][]const u8{review_id},
    ) catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };

    if (row == null) {
        const body = std.fmt.allocPrint(allocator, "{{\"assertion_run\":null}}", .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        return .{ .status_code = 200, .body = body };
    }

    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }

    const run_id = r[0] orelse return errorResult(allocator, 500, "INTERNAL_ERROR", "Null run_id from DB");
    const status = r[1] orelse "unknown";
    const sandbox_id_opt = r[2];
    const teardown_error_opt = r[3];
    const assertions_passed = r[4] orelse "0";
    const assertions_failed = r[5] orelse "0";
    const failing_ids_json = r[6] orelse "[]";

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"assertion_run\":{\"run_id\":\"") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonEscaped(&buf, allocator, run_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, "\",\"status\":\"") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonEscaped(&buf, allocator, status) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, "\",\"sandbox_id\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    if (sandbox_id_opt) |s| {
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        appendJsonEscaped(&buf, allocator, s) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    } else {
        buf.appendSlice(allocator, "null") catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, ",\"teardown_error\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    if (teardown_error_opt) |e| {
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        appendJsonEscaped(&buf, allocator, e) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    } else {
        buf.appendSlice(allocator, "null") catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, ",\"assertions_passed\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, assertions_passed) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"assertions_failed\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, assertions_failed) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"failing_assertion_ids\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, failing_ids_json) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, "}}") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const body = buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    };
    return .{ .status_code = 200, .body = body };
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
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
}
