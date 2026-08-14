//! PRM-08: HTTP handler for the promotion rollback endpoint.
//!
//! POST /api/v1/definitions/{process_key}/rollback
//!
//! Maps RollbackError to HTTP:
//!   Forbidden                       → 403
//!   VersionNeverActive / AlreadyActive → 422
//!   ProcessKeyNotFound              → 404
//!   PoolExhausted                   → 503
//!   TransactionFailed / OutOfMemory → 500

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const rollback_mod = @import("../../definition/rollback.zig");

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

/// POST /api/v1/definitions/{process_key}/rollback
///
/// Request body (application/json):
///   { "tenant_id": "<UUID>", "target_version": 42 }
///
/// Success — HTTP 200:
///   { "definition_id": "<uuid>", "version": 42,
///     "rolled_back_from_version": 45,
///     "superseded_review_id": "<uuid or null>",
///     "event_id": "<uuid>" }
pub fn handleRollback(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    process_key: []const u8,
    body: []const u8,
) HandlerResult {
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
    const target_version: u32 = switch (obj.get("target_version") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "target_version is required")) {
        .integer => |i| std.math.cast(u32, i) orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "target_version must fit in u32"),
        else => return errorResult(allocator, 422, "INVALID_INPUT", "target_version must be an integer"),
    };

    const result = rollback_mod.rollbackDefinitionVersion(
        allocator,
        pool,
        tenant_id,
        process_key,
        target_version,
        actor.user_id,
    ) catch |err| switch (err) {
        rollback_mod.RollbackError.Forbidden => return errorResult(allocator, 403, "FORBIDDEN", "Caller lacks platform.admin"),
        rollback_mod.RollbackError.VersionNeverActive => return errorResult(allocator, 422, "VERSION_NEVER_ACTIVE", "target_version was never active"),
        rollback_mod.RollbackError.AlreadyActive => return errorResult(allocator, 422, "ALREADY_ACTIVE", "target_version is already the active version"),
        rollback_mod.RollbackError.ProcessKeyNotFound => return errorResult(allocator, 404, "PROCESS_KEY_NOT_FOUND", "No definitions found for process_key"),
        rollback_mod.RollbackError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        rollback_mod.RollbackError.TransactionFailed, rollback_mod.RollbackError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer result.deinit(allocator);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"definition_id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonStr(allocator, &buf, result.definition_id) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"version\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    const version_str = std.fmt.allocPrint(allocator, "{d}", .{result.version}) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    defer allocator.free(version_str);
    buf.appendSlice(allocator, version_str) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"rolled_back_from_version\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    const from_str = std.fmt.allocPrint(allocator, "{d}", .{result.rolled_back_from_version}) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    defer allocator.free(from_str);
    buf.appendSlice(allocator, from_str) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, ",\"superseded_review_id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    if (result.superseded_review_id) |s| {
        appendJsonStr(allocator, &buf, s) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    } else {
        buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, ",\"event_id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonStr(allocator, &buf, result.event_id) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.append(allocator, '}') catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const out_body = buf.toOwnedSlice(allocator) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    return .{ .status_code = 200, .body = out_body };
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
