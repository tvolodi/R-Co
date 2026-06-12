const std = @import("std");
const pool_mod = @import("pool");
const authorization = @import("../authorization.zig");
const dlq_store = @import("../../dlq/store.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub const Actor = struct {
    user_id: []const u8,
    roles: ?[]const authorization.Role = null,
    is_operator_or_above: bool,
    is_platform_admin: bool,
};

pub const ListDlqParams = struct {
    cursor: ?[]const u8 = null,
    page_size: ?u16 = null,
    instance_id: ?[]const u8 = null,
    item_type: ?dlq_store.DlqItemType = null,
};

pub fn handleList(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: Actor,
    params: ListDlqParams,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .DlqReadRetryDiscard,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to access dead letter queue");
    }

    const page = dlq_store.list(allocator, pool, .{
        .cursor = params.cursor,
        .page_size = params.page_size,
        .instance_id = params.instance_id,
        .item_type = params.item_type,
    }) catch |err| switch (err) {
        error.InvalidCursor => return errorResult(allocator, 422, "INVALID_CURSOR", "cursor is invalid for this endpoint"),
        error.CursorExpired => return errorResult(allocator, 410, "CURSOR_EXPIRED", "cursor has expired"),
        error.InvalidFilter => return errorResult(allocator, 422, "INVALID_FILTER", "one or more filters are invalid"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "database connection pool exhausted"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "failed to list dead letter queue items"),
    };
    defer page.deinit(allocator);

    const body = serializeList(allocator, page) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");
    return .{ .status_code = 200, .body = body };
}

pub fn handleRetry(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: Actor,
    dlq_id: []const u8,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .DlqReadRetryDiscard,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to retry dead letter items");
    }

    const result = dlq_store.retry(allocator, pool, actor.user_id, dlq_id) catch |err| switch (err) {
        error.ItemNotFound => return errorResult(allocator, 404, "NOT_FOUND", "dead letter item not found"),
        error.InstanceCancelled => return errorResult(allocator, 409, "INSTANCE_CANCELLED", "instance is cancelled; dead letter item was discarded"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "database connection pool exhausted"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "failed to retry dead letter item"),
    };
    defer result.deinit(allocator);

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"item_type\":\"{s}\",\"retry_count\":0,\"status\":\"accepted\"}}",
        .{ result.id, dlq_store.itemTypeToString(result.item_type) },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");

    return .{ .status_code = 202, .body = body };
}

// ---------------------------------------------------------------------------
// ISS-207: handleRetryConvergent — bare retry (changed-cause check)
// ---------------------------------------------------------------------------

/// POST /api/v1/dlq/:item_id/retry
/// Requires changed cause (new definition version or EXECUTION_CORRECTION event).
/// Returns HTTP 409 + hint if cause unchanged.
pub fn handleRetryConvergent(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: Actor,
    dlq_id: []const u8,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .DlqReadRetryDiscard,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to retry dead letter items");
    }

    const result = dlq_store.retryConvergent(allocator, pool, actor.user_id, dlq_id) catch |err| switch (err) {
        error.ItemNotFound => return errorResult(allocator, 404, "NOT_FOUND", "dead letter item not found"),
        error.InstanceNotFound => return errorResult(allocator, 404, "INSTANCE_NOT_FOUND", "associated instance not found"),
        error.InstanceNotInError => return errorResult(allocator, 409, "INSTANCE_NOT_IN_ERROR", "instance is not in ERROR status"),
        error.RetryWithoutChange => return errorResult(allocator, 409, "RETRY_WITHOUT_CHANGE", "Instance has not changed since the error; promote a new definition version or submit a correction event before retrying."),
        error.InvalidInput => return errorResult(allocator, 422, "INVALID_INPUT", "invalid input"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "database connection pool exhausted"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "failed to retry dead letter item"),
    };
    defer result.deinit(allocator);

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"instance_id\":\"{s}\",\"status\":\"{s}\"}}",
        .{ result.dlq_id, result.instance_id, result.status },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");

    return .{ .status_code = 202, .body = body };
}

// ---------------------------------------------------------------------------
// ISS-207: handleRetryWithInput — retry with corrected payload
// ---------------------------------------------------------------------------

/// POST /api/v1/dlq/:item_id/retry-with-input
/// Body: { "payload": { ... } }  (corrected trigger payload)
pub fn handleRetryWithInput(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: Actor,
    dlq_id: []const u8,
    body: []const u8,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .DlqReadRetryDiscard,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to retry dead letter items");
    }

    // Parse body: must be { "payload": { ... } }
    const body_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 422, "INVALID_INPUT", "request body is not valid JSON");
    defer body_parsed.deinit();

    if (body_parsed.value != .object) {
        return errorResult(allocator, 422, "INVALID_INPUT", "request body must be a JSON object");
    }

    const payload_val = body_parsed.value.object.get("payload") orelse {
        return errorResult(allocator, 422, "INVALID_INPUT", "payload field is required");
    };

    if (payload_val != .object) {
        return errorResult(allocator, 422, "INVALID_INPUT", "payload must be a JSON object");
    }

    const corrected_payload_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = payload_val.object },
        .{},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");
    defer allocator.free(corrected_payload_json);

    const result = dlq_store.retryWithInput(allocator, pool, actor.user_id, dlq_id, corrected_payload_json) catch |err| switch (err) {
        error.ItemNotFound => return errorResult(allocator, 404, "NOT_FOUND", "dead letter item not found"),
        error.InstanceNotFound => return errorResult(allocator, 404, "INSTANCE_NOT_FOUND", "associated instance not found"),
        error.InstanceNotInError => return errorResult(allocator, 409, "INSTANCE_NOT_IN_ERROR", "instance is not in ERROR status"),
        error.RetryWithoutChange => return errorResult(allocator, 409, "RETRY_WITHOUT_CHANGE", "instance cause unchanged"),
        error.InvalidInput => return errorResult(allocator, 422, "INVALID_INPUT", "payload is not a valid JSON object"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "database connection pool exhausted"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "failed to retry dead letter item with input"),
    };
    defer result.deinit(allocator);

    const resp_body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"instance_id\":\"{s}\",\"status\":\"{s}\"}}",
        .{ result.dlq_id, result.instance_id, result.status },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");

    return .{ .status_code = 202, .body = resp_body };
}

pub fn handleDiscard(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: Actor,
    dlq_id: []const u8,
    reason: ?[]const u8,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .DlqReadRetryDiscard,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to discard dead letter items");
    }

    const result = dlq_store.discard(allocator, pool, actor.user_id, dlq_id, reason) catch |err| switch (err) {
        error.ItemNotFound => return errorResult(allocator, 404, "NOT_FOUND", "dead letter item not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "database connection pool exhausted"),
        else => return errorResult(allocator, 500, "INTERNAL_ERROR", "failed to discard dead letter item"),
    };
    defer result.deinit(allocator);

    const body = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"status\":\"discarded\"}}", .{result.id}) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "serialization failed");
    return .{ .status_code = 200, .body = body };
}

fn resolveActorRoles(actor: Actor, derived: *[3]authorization.Role) []const authorization.Role {
    if (actor.roles) |roles| return roles;

    if (actor.is_platform_admin) {
        derived[0] = .PLATFORM_ADMIN;
        return derived[0..1];
    }
    if (actor.is_operator_or_above) {
        derived[0] = .PROCESS_OPERATOR;
        return derived[0..1];
    }
    derived[0] = .TASK_WORKER;
    return derived[0..1];
}

fn serializeList(allocator: std.mem.Allocator, page: dlq_store.ListResult) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (page.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendItem(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "],\"next_cursor\":");
    if (page.next_cursor) |cursor| {
        try appendJsonString(allocator, &buf, cursor);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"count\":");
    const count_text = try std.fmt.allocPrint(allocator, "{d}", .{page.items.len});
    defer allocator.free(count_text);
    try buf.appendSlice(allocator, count_text);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn appendItem(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), item: dlq_store.DlqItem) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"id\":");
    try appendJsonString(allocator, buf, item.id);

    try buf.appendSlice(allocator, ",\"instance_id\":");
    if (item.instance_id) |instance_id| {
        try appendJsonString(allocator, buf, instance_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"item_type\":");
    try appendJsonString(allocator, buf, dlq_store.itemTypeToString(item.item_type));

    const retry_count_text = try std.fmt.allocPrint(allocator, "{d}", .{item.retry_count});
    defer allocator.free(retry_count_text);
    try buf.appendSlice(allocator, ",\"retry_count\":");
    try buf.appendSlice(allocator, retry_count_text);

    const retry_limit_text = try std.fmt.allocPrint(allocator, "{d}", .{item.retry_limit});
    defer allocator.free(retry_limit_text);
    try buf.appendSlice(allocator, ",\"retry_limit\":");
    try buf.appendSlice(allocator, retry_limit_text);

    try buf.appendSlice(allocator, ",\"original_payload\":");
    try buf.appendSlice(allocator, item.original_payload_json);
    try buf.appendSlice(allocator, ",\"error_chain\":");
    try buf.appendSlice(allocator, item.error_chain_json);
    try buf.appendSlice(allocator, ",\"processor_metadata\":");
    try buf.appendSlice(allocator, item.processor_metadata_json);

    try buf.appendSlice(allocator, ",\"first_failed_at\":");
    try appendJsonString(allocator, buf, item.first_failed_at);
    try buf.appendSlice(allocator, ",\"last_failed_at\":");
    try appendJsonString(allocator, buf, item.last_failed_at);
    try buf.appendSlice(allocator, ",\"created_at\":");
    try appendJsonString(allocator, buf, item.created_at);
    try buf.append(allocator, '}');
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
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

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8, detail: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"about:blank\",\"title\":\"{s}\",\"status\":{d},\"detail\":\"{s}\"}}",
        .{ code, status, detail },
    ) catch "{\"type\":\"about:blank\",\"title\":\"INTERNAL_ERROR\",\"status\":500,\"detail\":\"internal error\"}";
    return .{ .status_code = status, .body = body };
}
