const std = @import("std");
const auth = @import("../middleware/auth.zig");
const pool_mod = @import("../../db/pool.zig");
const store = @import("../../webhook/subscription_store.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub fn handleCreateSubscription(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor: auth.AuthContext,
    body: []const u8,
    production_mode: bool,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) return errorResult(allocator, 403, "forbidden");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch
        return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;

    const target_url = switch (obj.get("target_url") orelse return errorResult(allocator, 422, "target_url_required")) {
        .string => |value| value,
        else => return errorResult(allocator, 422, "target_url_invalid"),
    };

    const event_values = switch (obj.get("event_types") orelse return errorResult(allocator, 422, "event_types_required")) {
        .array => |value| value.items,
        else => return errorResult(allocator, 422, "event_types_invalid"),
    };
    if (event_values.len == 0) return errorResult(allocator, 422, "event_types_invalid");

    const event_types = allocator.alloc(store.WebhookEventType, event_values.len) catch
        return errorResult(allocator, 500, "internal_error");
    defer allocator.free(event_types);

    for (event_values, 0..) |item, idx| {
        const as_text = switch (item) {
            .string => |value| value,
            else => return errorResult(allocator, 422, "event_types_invalid"),
        };
        event_types[idx] = store.WebhookEventType.fromWire(as_text) orelse
            return errorResult(allocator, 422, "event_types_invalid");
    }

    const secret: ?[]const u8 = blk: {
        const raw = obj.get("secret") orelse break :blk null;
        break :blk switch (raw) {
            .null => null,
            .string => |value| if (value.len == 0) null else value,
            else => return errorResult(allocator, 422, "secret_invalid"),
        };
    };

    const created = store.createSubscription(
        allocator,
        pool,
        actor.user_id,
        .{
            .target_url = target_url,
            .event_types = event_types,
            .secret = secret,
        },
        production_mode,
    ) catch |err| switch (err) {
        error.ValidationFailed, error.InvalidEventType => return errorResult(allocator, 422, "validation_failed"),
        error.Forbidden => return errorResult(allocator, 403, "forbidden"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    errdefer created.deinit(allocator);

    const response_body = serializeSubscription(allocator, created) catch return errorResult(allocator, 500, "serialization_failed");
    created.deinit(allocator);

    return .{ .status_code = 201, .body = response_body };
}

pub fn handleListSubscriptions(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor: auth.AuthContext,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) return errorResult(allocator, 403, "forbidden");

    const items = store.listSubscriptions(allocator, pool) catch |err| switch (err) {
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (items) |item| item.deinit(allocator);
        allocator.free(items);
    }

    return .{ .status_code = 200, .body = serializeList(allocator, items) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleDeleteSubscription(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor: auth.AuthContext,
    subscription_id: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) return errorResult(allocator, 403, "forbidden");

    expectUuidLike(subscription_id) catch return errorResult(allocator, 422, "subscription_id_invalid");

    store.deleteSubscription(allocator, pool, actor.user_id, subscription_id) catch |err| switch (err) {
        error.NotFound => return errorResult(allocator, 404, "not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    return .{ .status_code = 204, .body = allocator.alloc(u8, 0) catch return errorResult(allocator, 500, "serialization_failed") };
}

fn serializeList(allocator: std.mem.Allocator, items: []const store.WebhookSubscription) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"items\":[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.appendSlice(allocator, ",");
        const one = try serializeSubscription(allocator, item);
        defer allocator.free(one);
        try out.appendSlice(allocator, one);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn serializeSubscription(allocator: std.mem.Allocator, item: store.WebhookSubscription) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendJsonField(allocator, &out, true, "subscription_id", item.subscription_id);
    try appendJsonField(allocator, &out, false, "target_url", item.target_url);

    try out.appendSlice(allocator, ",\"event_types\":[");
    for (item.event_types, 0..) |event_type, idx| {
        if (idx != 0) try out.appendSlice(allocator, ",");
        const wire = try std.json.Stringify.valueAlloc(allocator, .{ .string = event_type.toWire() }, .{});
        defer allocator.free(wire);
        try out.appendSlice(allocator, wire);
    }
    try out.appendSlice(allocator, "]");

    try appendJsonField(allocator, &out, false, "status", if (item.status == .PAUSED) "PAUSED" else "ACTIVE");
    try appendJsonNumberField(allocator, &out, false, "consecutive_failures", item.consecutive_failures);
    try appendJsonNumberField(allocator, &out, false, "max_attempts", item.max_attempts);
    if (item.last_attempt_at) |value| try appendJsonField(allocator, &out, false, "last_attempt_at", value) else try out.appendSlice(allocator, ",\"last_attempt_at\":null");
    if (item.last_failure_at) |value| try appendJsonField(allocator, &out, false, "last_failure_at", value) else try out.appendSlice(allocator, ",\"last_failure_at\":null");
    if (item.paused_at) |value| try appendJsonField(allocator, &out, false, "paused_at", value) else try out.appendSlice(allocator, ",\"paused_at\":null");
    try appendJsonField(allocator, &out, false, "created_at", item.created_at);
    try appendJsonField(allocator, &out, false, "updated_at", item.updated_at);
    try out.appendSlice(allocator, "}");

    return out.toOwnedSlice(allocator);
}

fn appendJsonField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first) try out.appendSlice(allocator, ",");
    try appendJsonString(allocator, out, key);
    try out.appendSlice(allocator, ":");
    try appendJsonString(allocator, out, value);
}

fn appendJsonNumberField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: bool,
    key: []const u8,
    value: anytype,
) !void {
    if (!first) try out.appendSlice(allocator, ",");
    const txt = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(txt);
    try appendJsonString(allocator, out, key);
    try out.appendSlice(allocator, ":");
    try out.appendSlice(allocator, txt);
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

fn expectUuidLike(value: []const u8) !void {
    if (value.len != 36) return error.InvalidUuid;
    if (value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-') return error.InvalidUuid;
}

test "EXT-02 webhooks route rejects non-admin caller" {
    const allocator = std.testing.allocator;
    const actor = auth.AuthContext{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .PROCESS_OPERATOR,
        .is_bootstrap = false,
        .token_id = "tok",
    };

    // Pool pointer is never used because authorization fails first.
    const result = handleListSubscriptions(allocator, undefined, actor);
    defer if (result.body.len > 0) allocator.free(result.body);
    try std.testing.expectEqual(@as(u16, 403), result.status_code);
}

test "TC-EXT-02-U03: route authorization enforces PLATFORM_ADMIN for POST/GET/DELETE" {
    const allocator = std.testing.allocator;
    const actor = auth.AuthContext{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .PROCESS_OPERATOR,
        .is_bootstrap = false,
        .token_id = "tok",
    };

    const create_result = handleCreateSubscription(allocator, undefined, actor, "{\"target_url\":\"https://example.test\",\"event_types\":[\"task.completed\"]}", false);
    defer if (create_result.body.len > 0) allocator.free(create_result.body);
    try std.testing.expectEqual(@as(u16, 403), create_result.status_code);

    const list_result = handleListSubscriptions(allocator, undefined, actor);
    defer if (list_result.body.len > 0) allocator.free(list_result.body);
    try std.testing.expectEqual(@as(u16, 403), list_result.status_code);

    const delete_result = handleDeleteSubscription(allocator, undefined, actor, "00000000-0000-0000-0000-000000000001");
    defer if (delete_result.body.len > 0) allocator.free(delete_result.body);
    try std.testing.expectEqual(@as(u16, 403), delete_result.status_code);
}
