//! ENV-03: HTTP handler for definition promotion endpoint.
//!
//! POST /api/v1/tenants/:test_tenant_id/promote/:definition_name

const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const promotion_mod = @import("../../definition/promotion.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

/// Handle POST /api/v1/tenants/:test_tenant_id/promote/:definition_name.
pub fn handlePromotion(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    test_tenant_id: []const u8,
    definition_name: []const u8,
) HandlerResult {
    const result = promotion_mod.promoteDefinition(
        allocator,
        pool,
        test_tenant_id,
        definition_name,
        actor.user_id,
    ) catch |err| {
        return switch (err) {
            promotion_mod.PromotionError.TestTenantNotFound,
            promotion_mod.PromotionError.ActiveDefinitionNotFound,
            => errorResult(allocator, 404, "not_found"),
            promotion_mod.PromotionError.NotATestTenant => blk: {
                const body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"not_a_test_tenant\",\"detail\":\"tenant must have tenant_type='test' to promote definitions\"}}",
                    .{},
                ) catch break :blk errorResult(allocator, 422, "not_a_test_tenant");
                break :blk .{ .status_code = 422, .body = body };
            },
            promotion_mod.PromotionError.ProductionTenantInactive => blk: {
                const body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"production_tenant_inactive\",\"detail\":\"production tenant is not active\"}}",
                    .{},
                ) catch break :blk errorResult(allocator, 409, "production_tenant_inactive");
                break :blk .{ .status_code = 409, .body = body };
            },
            promotion_mod.PromotionError.MissingDesignerRoleOnTest,
            promotion_mod.PromotionError.MissingDesignerRoleOnProd,
            => errorResult(allocator, 403, "forbidden"),
            promotion_mod.PromotionError.PoolExhausted => errorResult(allocator, 503, "service_unavailable"),
            promotion_mod.PromotionError.OutOfMemory => errorResult(allocator, 500, "internal_error"),
            else => errorResult(allocator, 500, "internal_error"),
        };
    };
    defer result.deinit(allocator);

    // Serialize result to JSON.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"definition_id\":") catch
        return errorResult(allocator, 500, "serialization_failed");
    appendJsonStr(allocator, &buf, result.definition_id) catch
        return errorResult(allocator, 500, "serialization_failed");
    buf.appendSlice(allocator, ",\"version\":") catch
        return errorResult(allocator, 500, "serialization_failed");
    appendJsonStr(allocator, &buf, result.version) catch
        return errorResult(allocator, 500, "serialization_failed");
    buf.appendSlice(allocator, ",\"status\":") catch
        return errorResult(allocator, 500, "serialization_failed");
    appendJsonStr(allocator, &buf, result.status) catch
        return errorResult(allocator, 500, "serialization_failed");
    buf.appendSlice(allocator, ",\"warnings\":[") catch
        return errorResult(allocator, 500, "serialization_failed");
    for (result.warnings, 0..) |w, idx| {
        if (idx > 0) buf.append(allocator, ',') catch
            return errorResult(allocator, 500, "serialization_failed");
        appendJsonStr(allocator, &buf, w) catch
            return errorResult(allocator, 500, "serialization_failed");
    }
    buf.appendSlice(allocator, "]}") catch
        return errorResult(allocator, 500, "serialization_failed");

    const body = buf.toOwnedSlice(allocator) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 201, .body = body };
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
