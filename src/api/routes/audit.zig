const std = @import("std");
const pool_mod = @import("pool");
const audit_mod = @import("../../obs/audit.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub const ListAuditParams = struct {
    actor_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    pipeline_run_id: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    page_size: ?u16 = null,
};

pub fn handleList(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    params: ListAuditParams,
) HandlerResult {
    if (params.from != null and params.to != null) {
        if (std.mem.order(u8, params.from.?, params.to.?) == .gt) {
            return errorResult(allocator, 422, "invalid_time_range");
        }
    }

    const result = audit_mod.list(allocator, pool, .{
        .actor_id = params.actor_id,
        .resource_type = params.resource_type,
        .resource_id = params.resource_id,
        .pipeline_run_id = params.pipeline_run_id,
        .from_ts = params.from,
        .to_ts = params.to,
        .cursor = params.cursor,
        .page_size = params.page_size,
    }) catch |err| switch (err) {
        error.InvalidCursor => return errorResult(allocator, 422, "invalid_cursor"),
        error.CursorExpired => return errorResult(allocator, 410, "cursor_expired"),
        error.InvalidFilter => return errorResult(allocator, 422, "invalid_filter"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer result.deinit(allocator);

    const body = serializeList(allocator, result) catch return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

fn serializeList(allocator: std.mem.Allocator, page: audit_mod.ListResult) ![]u8 {
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
    const count_str = try std.fmt.allocPrint(allocator, "{d}", .{page.items.len});
    defer allocator.free(count_str);
    try buf.appendSlice(allocator, count_str);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn appendItem(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), item: audit_mod.AuditEntry) !void {
    try buf.append(allocator, '{');

    try buf.appendSlice(allocator, "\"audit_id\":");
    try appendJsonString(allocator, buf, item.audit_id);

    try buf.appendSlice(allocator, ",\"actor_id\":");
    if (item.actor_id) |actor| {
        try appendJsonString(allocator, buf, actor);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"action\":");
    try appendJsonString(allocator, buf, item.action);

    try buf.appendSlice(allocator, ",\"resource_type\":");
    try appendJsonString(allocator, buf, item.resource_type);

    try buf.appendSlice(allocator, ",\"resource_id\":");
    try appendJsonString(allocator, buf, item.resource_id);

    try buf.appendSlice(allocator, ",\"pipeline_run_id\":");
    if (item.pipeline_run_id) |pipeline_run_id| {
        try appendJsonString(allocator, buf, pipeline_run_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"timestamp\":");
    try appendJsonString(allocator, buf, item.timestamp);

    try buf.appendSlice(allocator, ",\"before_state\":");
    if (item.before_state) |before| {
        try buf.appendSlice(allocator, before);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"after_state\":");
    if (item.after_state) |after| {
        try buf.appendSlice(allocator, after);
    } else {
        try buf.appendSlice(allocator, "null");
    }

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

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}
