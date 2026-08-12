//! PRM-01: HTTP handler for the promotion plan endpoint.
//!
//! POST /api/v1/promotions

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const plan_mod = @import("../../definition/promotion_plan.zig");

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

/// POST /api/v1/promotions
///
/// Request body (application/json):
///   {
///     "source_tenant_id": "<UUID>",
///     "target_tenant_id": "<UUID>",
///     "process_key": "<string>"
///   }
///
/// Success — HTTP 200:
///   { "entries": [ {type, id, change_kind, before, after}, ... ],
///     "human_readable": "<string>" }
///
/// Error codes:
///   400  MALFORMED_JSON
///   403  FORBIDDEN                  (PRM-01 AC1 — caller lacks promotion.submit)
///   404  SOURCE_DEFINITION_NOT_FOUND
///   422  INVALID_INPUT
///   422  INVALID_PROMOTION_SOURCE   (PRM-01 AC4)
///   422  EMPTY_PROMOTION_PLAN       (PRM-01 AC3)
///   500  INTERNAL_ERROR
///   503  SERVICE_UNAVAILABLE
pub fn handleCreatePromotionPlan(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
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

    const source_tenant_id: []const u8 = switch (obj.get("source_tenant_id") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "source_tenant_id is required")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "source_tenant_id must be a string"),
    };
    const target_tenant_id: []const u8 = switch (obj.get("target_tenant_id") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "target_tenant_id is required")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "target_tenant_id must be a string"),
    };
    const process_key: []const u8 = switch (obj.get("process_key") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "process_key is required")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "process_key must be a string"),
    };

    const plan = plan_mod.computePromotionPlan(
        allocator,
        pool,
        actor.user_id,
        source_tenant_id,
        target_tenant_id,
        process_key,
    ) catch |err| switch (err) {
        plan_mod.PlanError.Forbidden => return errorResult(allocator, 403, "FORBIDDEN", "Caller lacks promotion.submit"),
        plan_mod.PlanError.InvalidPromotionSource => return errorResult(allocator, 422, "INVALID_PROMOTION_SOURCE", "source_tenant_id must name a test tenant"),
        plan_mod.PlanError.EmptyPromotionPlan => return errorResult(allocator, 422, "EMPTY_PROMOTION_PLAN", "Source and target are identical after canonicalisation"),
        plan_mod.PlanError.SourceDefinitionNotFound => return errorResult(allocator, 404, "SOURCE_DEFINITION_NOT_FOUND", "No ACTIVE definition found for process_key in the source tenant"),
        plan_mod.PlanError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        plan_mod.PlanError.TransactionFailed, plan_mod.PlanError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer plan.deinit(allocator);

    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(allocator, "{\"entries\":[") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (plan.entries, 0..) |e, i| {
        if (i > 0) buf.append(allocator, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, "{\"type\":\"") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, planEntryTypeStr(e.type)) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, "\",\"id\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        appendJsonStr(allocator, &buf, e.id) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, ",\"change_kind\":\"") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, changeKindStr(e.change_kind)) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        buf.appendSlice(allocator, "\",\"before\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        if (e.before) |b| {
            appendJsonStr(allocator, &buf, b) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        } else {
            buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        }
        buf.appendSlice(allocator, ",\"after\":") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        if (e.after) |af| {
            appendJsonStr(allocator, &buf, af) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        } else {
            buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        }
        buf.append(allocator, '}') catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, "],\"human_readable\":") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    appendJsonStr(allocator, &buf, plan.human_readable) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.append(allocator, '}') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const out_body = buf.toOwnedSlice(allocator) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    return .{ .status_code = 200, .body = out_body };
}

fn planEntryTypeStr(t: plan_mod.PlanEntryType) []const u8 {
    return switch (t) {
        .graph_node => "graph_node",
        .graph_edge => "graph_edge",
        .variable_schema => "variable_schema",
        .service_binding => "service_binding",
        .module_ref => "module_ref",
        .permission_rule => "permission_rule",
    };
}

fn changeKindStr(k: plan_mod.ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .modified => "modified",
        .removed => "removed",
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
