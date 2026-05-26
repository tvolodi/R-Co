const std = @import("std");
const auth = @import("../middleware/auth.zig");
const identity_service = @import("../../identity/service.zig");
const identity_registry = @import("../../identity/registry.zig");
const pool_mod = @import("../../db/pool.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub fn handleCreateUser(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;

    const username_val = obj.get("username") orelse return errorResult(allocator, 422, "username_required");
    const display_name_val = obj.get("display_name") orelse return errorResult(allocator, 422, "display_name_required");
    const email_val = obj.get("email") orelse return errorResult(allocator, 422, "email_required");

    const username = switch (username_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "username_invalid"),
    };
    const display_name = switch (display_name_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "display_name_invalid"),
    };
    const email = switch (email_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "email_invalid"),
    };

    const status = blk: {
        const raw = obj.get("status") orelse break :blk identity_registry.UserStatus.ACTIVE;
        const s = switch (raw) {
            .string => |value| value,
            else => return errorResult(allocator, 422, "status_invalid"),
        };
        break :blk identity_registry.UserStatus.fromString(s) orelse
            return errorResult(allocator, 422, "status_invalid");
    };

    const tenant_id: ?[]const u8 = blk: {
        const raw = obj.get("tenant_id") orelse break :blk null;
        break :blk switch (raw) {
            .null => null,
            .string => |s| s,
            else => return errorResult(allocator, 422, "tenant_id_invalid"),
        };
    };

    const user = service.createUser(allocator, actor, .{
        .tenant_id = tenant_id,
        .username = username,
        .display_name = display_name,
        .email = email,
        .status = status,
        .caller_supplied_user_id = obj.get("user_id") != null,
        .caller_supplied_created_at = obj.get("created_at") != null,
    }) catch |err| switch (err) {
        identity_service.IdentityError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.IdentityError.DuplicateUsername => return errorResult(allocator, 409, "duplicate_username"),
        identity_service.IdentityError.InvalidEmail,
        identity_service.IdentityError.CallerProvidedUserId,
        identity_service.IdentityError.CallerProvidedCreatedAt,
        identity_service.IdentityError.ValidationFailed,
        => return errorResult(allocator, 422, "validation_failed"),
        identity_service.IdentityError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer user.deinit(allocator);

    return .{ .status_code = 201, .body = serializeUser(allocator, user) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleUpdateUserStatus(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    user_id: []const u8,
    body: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const status_val = parsed.value.object.get("status") orelse return errorResult(allocator, 422, "status_required");
    const status_raw = switch (status_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "status_invalid"),
    };
    const status = identity_registry.UserStatus.fromString(status_raw) orelse
        return errorResult(allocator, 422, "status_invalid");

    const user = service.updateUserStatus(allocator, actor, .{
        .user_id = user_id,
        .status = status,
    }) catch |err| switch (err) {
        identity_service.IdentityError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.IdentityError.NotFound => return errorResult(allocator, 404, "not_found"),
        identity_service.IdentityError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.IdentityError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer user.deinit(allocator);

    return .{ .status_code = 200, .body = serializeUser(allocator, user) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleCreateGroup(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const name_val = parsed.value.object.get("name") orelse return errorResult(allocator, 422, "name_required");
    const name = switch (name_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "name_invalid"),
    };

    const group = service.createGroup(allocator, actor, .{ .name = name }) catch |err| switch (err) {
        identity_service.GroupError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.GroupError.DuplicateGroupName => return errorResult(allocator, 409, "duplicate_group_name"),
        identity_service.GroupError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.GroupError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer group.deinit(allocator);

    return .{ .status_code = 201, .body = serializeGroup(allocator, group) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleAddGroupMember(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    group_id: []const u8,
    body: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const user_id_val = parsed.value.object.get("user_id") orelse return errorResult(allocator, 422, "user_id_required");
    const user_id = switch (user_id_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "user_id_invalid"),
    };

    const result = service.addGroupMember(allocator, actor, .{ .group_id = group_id, .user_id = user_id }) catch |err| switch (err) {
        identity_service.GroupError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.GroupError.GroupNotFound => return errorResult(allocator, 404, "group_not_found"),
        identity_service.GroupError.UserNotFound => return errorResult(allocator, 404, "user_not_found"),
        identity_service.GroupError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.GroupError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer result.member.deinit(allocator);

    const status_code: u16 = if (result.created) 201 else 200;
    return .{ .status_code = status_code, .body = serializeGroupMemberResult(allocator, result.member, result.created) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleListGroupMembers(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    group_id: []const u8,
    params: identity_service.ListGroupMembersParams,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) return errorResult(allocator, 403, "forbidden");

    const page = service.listGroupMembers(allocator, actor, group_id, params) catch |err| switch (err) {
        identity_service.GroupError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.GroupError.GroupNotFound => return errorResult(allocator, 404, "group_not_found"),
        identity_service.GroupError.CrossTenantAccessDenied => return errorResult(allocator, 404, "group_not_found"),
        identity_service.GroupError.InvalidCursor => return errorResult(allocator, 422, "invalid_cursor"),
        identity_service.GroupError.CursorExpired => return errorResult(allocator, 410, "cursor_expired"),
        identity_service.GroupError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.GroupError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer page.deinit(allocator);

    return .{ .status_code = 200, .body = serializeGroupMembersPage(allocator, page) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleRemoveGroupMember(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    group_id: []const u8,
    user_id: []const u8,
) HandlerResult {
    const result = service.removeGroupMember(allocator, actor, .{ .group_id = group_id, .user_id = user_id }) catch |err| switch (err) {
        identity_service.GroupError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.GroupError.GroupNotFound => return errorResult(allocator, 404, "group_not_found"),
        identity_service.GroupError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.GroupError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    _ = result;

    return .{ .status_code = 204, .body = allocator.alloc(u8, 0) catch return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleCreateToken(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;

    const user_id_val = obj.get("user_id") orelse return errorResult(allocator, 422, "user_id_required");
    const user_id = switch (user_id_val) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "user_id_invalid"),
    };

    const roles_val = obj.get("roles") orelse return errorResult(allocator, 422, "roles_required");
    if (roles_val != .array) return errorResult(allocator, 422, "roles_invalid");
    if (roles_val.array.items.len == 0) return errorResult(allocator, 422, "roles_invalid");

    const roles = allocator.alloc(auth.Role, roles_val.array.items.len) catch return errorResult(allocator, 500, "internal_error");
    defer allocator.free(roles);

    for (roles_val.array.items, 0..) |item, idx| {
        if (item != .string) return errorResult(allocator, 422, "roles_invalid");
        roles[idx] = auth.Role.fromString(item.string) orelse return errorResult(allocator, 422, "roles_invalid");
    }

    const expires_at: ?[]const u8 = blk: {
        const raw = obj.get("expires_at") orelse break :blk null;
        break :blk switch (raw) {
            .null => null,
            .string => |s| s,
            else => return errorResult(allocator, 422, "expires_at_invalid"),
        };
    };

    const issued = service.issueToken(allocator, actor, .{
        .user_id = user_id,
        .roles = roles,
        .expires_at = expires_at,
    }) catch |err| switch (err) {
        identity_service.TokenError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.TokenError.UserNotFound => return errorResult(allocator, 404, "user_not_found"),
        identity_service.TokenError.InvalidRoleSet,
        identity_service.TokenError.ExpiresAtInPast,
        identity_service.TokenError.ValidationFailed,
        => return errorResult(allocator, 422, "validation_failed"),
        identity_service.TokenError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer issued.deinit(allocator);

    return .{ .status_code = 201, .body = serializeIssuedToken(allocator, issued) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleListTokens(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
) HandlerResult {
    const page = service.listTokens(allocator, actor) catch |err| switch (err) {
        identity_service.TokenError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.TokenError.InvalidRoleSet => return errorResult(allocator, 500, "internal_error"),
        identity_service.TokenError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer page.deinit(allocator);

    return .{ .status_code = 200, .body = serializeTokenPage(allocator, page) catch
        return errorResult(allocator, 500, "serialization_failed") };
}

pub fn handleRevokeToken(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    token_id: []const u8,
) HandlerResult {
    service.revokeToken(allocator, actor, token_id) catch |err| switch (err) {
        identity_service.TokenError.Forbidden => return errorResult(allocator, 403, "forbidden"),
        identity_service.TokenError.TokenNotFound => return errorResult(allocator, 404, "token_not_found"),
        identity_service.TokenError.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        identity_service.TokenError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    return .{ .status_code = 204, .body = allocator.alloc(u8, 0) catch return errorResult(allocator, 500, "serialization_failed") };
}

fn serializeUser(allocator: std.mem.Allocator, user: identity_registry.User) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"user_id\":");
    try appendJsonStr(allocator, &buf, user.user_id);
    try buf.appendSlice(allocator, ",\"username\":");
    try appendJsonStr(allocator, &buf, user.username);
    try buf.appendSlice(allocator, ",\"display_name\":");
    try appendJsonStr(allocator, &buf, user.display_name);
    try buf.appendSlice(allocator, ",\"email\":");
    try appendJsonStr(allocator, &buf, user.email);
    try buf.appendSlice(allocator, ",\"status\":");
    try appendJsonStr(allocator, &buf, user.status.asString());
    try buf.appendSlice(allocator, ",\"created_at\":");
    try appendJsonStr(allocator, &buf, user.created_at);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
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

fn serializeGroup(allocator: std.mem.Allocator, group: identity_registry.Group) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"group_id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\"}}",
        .{ group.group_id, group.name, group.created_at },
    );
}

fn serializeGroupMemberResult(allocator: std.mem.Allocator, member: identity_registry.GroupMember, created: bool) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"group_id\":\"{s}\",\"user_id\":\"{s}\",\"added_at\":\"{s}\",\"created\":{s}}}",
        .{ member.group_id, member.user_id, member.added_at, if (created) "true" else "false" },
    );
}

fn serializeGroupMembersPage(allocator: std.mem.Allocator, page: identity_service.GroupMemberPage) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var items_buf: std.ArrayList(u8) = .empty;
    try items_buf.append(a, '[');
    for (page.items, 0..) |member, idx| {
        if (idx > 0) try items_buf.append(a, ',');
        const user_json = try serializeUser(a, member);
        try items_buf.appendSlice(a, user_json);
    }
    try items_buf.append(a, ']');

    const next_cursor_json: []const u8 = if (page.next_cursor) |cursor|
        try std.fmt.allocPrint(a, "\"{s}\"", .{cursor})
    else
        "null";

    return std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"count\":{d}}}",
        .{ items_buf.items, next_cursor_json, page.count },
    );
}

fn serializeIssuedToken(allocator: std.mem.Allocator, issued: identity_service.IssuedToken) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"token_id\":");
    try appendJsonStr(allocator, &buf, issued.token_id);
    try buf.appendSlice(allocator, ",\"token_value\":");
    try appendJsonStr(allocator, &buf, issued.token_value);
    try buf.appendSlice(allocator, ",\"user_id\":");
    try appendJsonStr(allocator, &buf, issued.user_id);
    try buf.appendSlice(allocator, ",\"roles\":");
    try appendRoleArray(allocator, &buf, issued.roles);
    try buf.appendSlice(allocator, ",\"expires_at\":");
    try appendNullableJsonStr(allocator, &buf, issued.expires_at);
    try buf.appendSlice(allocator, ",\"created_at\":");
    try appendJsonStr(allocator, &buf, issued.created_at);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn serializeTokenPage(allocator: std.mem.Allocator, page: identity_service.TokenListPage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (page.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendTokenItem(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendTokenItem(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), item: identity_service.ApiToken) !void {
    try buf.appendSlice(allocator, "{\"token_id\":");
    try appendJsonStr(allocator, buf, item.token_id);
    try buf.appendSlice(allocator, ",\"user_id\":");
    try appendJsonStr(allocator, buf, item.user_id);
    try buf.appendSlice(allocator, ",\"roles\":");
    try appendRoleArray(allocator, buf, item.roles);
    try buf.appendSlice(allocator, ",\"expires_at\":");
    try appendNullableJsonStr(allocator, buf, item.expires_at);
    try buf.appendSlice(allocator, ",\"status\":");
    try appendJsonStr(allocator, buf, item.status.asString());
    try buf.appendSlice(allocator, ",\"created_at\":");
    try appendJsonStr(allocator, buf, item.created_at);
    try buf.appendSlice(allocator, ",\"revoked_at\":");
    try appendNullableJsonStr(allocator, buf, item.revoked_at);
    try buf.appendSlice(allocator, ",\"last_used_at\":");
    try appendNullableJsonStr(allocator, buf, item.last_used_at);
    try buf.append(allocator, '}');
}

fn appendRoleArray(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), roles: []const auth.Role) !void {
    try buf.append(allocator, '[');
    for (roles, 0..) |role, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendJsonStr(allocator, buf, roleToString(role));
    }
    try buf.append(allocator, ']');
}

fn roleToString(role: auth.Role) []const u8 {
    return switch (role) {
        .PLATFORM_ADMIN => "PLATFORM_ADMIN",
        .PROCESS_DESIGNER => "PROCESS_DESIGNER",
        .PROCESS_OPERATOR => "PROCESS_OPERATOR",
        .TASK_WORKER => "TASK_WORKER",
        .VIEWER => "VIEWER",
    };
}

fn appendNullableJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: ?[]const u8) !void {
    if (s) |value| {
        try appendJsonStr(allocator, buf, value);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn errorResult(allocator: std.mem.Allocator, status_code: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = status_code, .body = body };
}

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn adminActor() auth.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "idn01-route-test",
    };
}

fn cleanupUserByUsername(pool: *pool_mod.Pool, username: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec(
        \\DELETE FROM api_tokens
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec(
        \\DELETE FROM user_roles
        \\WHERE user_id IN (SELECT id FROM users WHERE username = $1)
    ,
        &[_][]const u8{username},
    ) catch {};

    conn.exec("DELETE FROM users WHERE username = $1", &[_][]const u8{username}) catch {};
}

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

fn expectUuidLike(value: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 36), value.len);
    try std.testing.expectEqual(@as(u8, '-'), value[8]);
    try std.testing.expectEqual(@as(u8, '-'), value[13]);
    try std.testing.expectEqual(@as(u8, '-'), value[18]);
    try std.testing.expectEqual(@as(u8, '-'), value[23]);
}

test "TC-IDN-01-01: handleCreateUser returns 201 with platform-assigned user_id and created_at" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-01-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const body =
        "{" ++
        "\"username\":\"tc-idn-01-01-user\"," ++
        "\"display_name\":\"IDN 01 User\"," ++
        "\"email\":\"tc-idn-01-01@example.com\"," ++
        "\"status\":\"ACTIVE\"" ++
        "}";

    const result = handleCreateUser(&service, alloc, adminActor(), body);
    defer freeRouteBody(alloc, result.body);
    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const user_id = obj.get("user_id") orelse return error.TestUnexpectedResult;
    const created_at = obj.get("created_at") orelse return error.TestUnexpectedResult;
    const status = obj.get("status") orelse return error.TestUnexpectedResult;

    try std.testing.expect(user_id == .string);
    try std.testing.expect(created_at == .string);
    try std.testing.expect(status == .string);
    try expectUuidLike(user_id.string);
    try std.testing.expect(created_at.string.len > 0);
    try std.testing.expectEqualStrings("ACTIVE", status.string);
}

test "TC-IDN-01-02: handleCreateUser duplicate username returns 409" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-02-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const first = handleCreateUser(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"username\":\"tc-idn-01-02-user\"," ++
            "\"display_name\":\"Duplicate One\"," ++
            "\"email\":\"tc-idn-01-02-a@example.com\"," ++
            "\"status\":\"ACTIVE\"" ++
            "}",
    );
    defer freeRouteBody(alloc, first.body);
    try std.testing.expectEqual(@as(u16, 201), first.status_code);

    const second = handleCreateUser(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"username\":\"tc-idn-01-02-user\"," ++
            "\"display_name\":\"Duplicate Two\"," ++
            "\"email\":\"tc-idn-01-02-b@example.com\"," ++
            "\"status\":\"ACTIVE\"" ++
            "}",
    );
    defer freeRouteBody(alloc, second.body);

    try std.testing.expectEqual(@as(u16, 409), second.status_code);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "duplicate_username") != null);
}

test "TC-IDN-01-03: handleCreateUser invalid email returns 422" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-03-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = handleCreateUser(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"username\":\"tc-idn-01-03-user\"," ++
            "\"display_name\":\"Invalid Email\"," ++
            "\"email\":\"not-an-email\"," ++
            "\"status\":\"ACTIVE\"" ++
            "}",
    );
    defer freeRouteBody(alloc, result.body);

    try std.testing.expectEqual(@as(u16, 422), result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "validation_failed") != null);
}

test "TC-IDN-01-04: handleCreateUser rejects caller-provided user_id and created_at with 422" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-04-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = handleCreateUser(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"user_id\":\"11111111-1111-1111-1111-111111111111\"," ++
            "\"created_at\":\"2026-01-01T00:00:00Z\"," ++
            "\"username\":\"tc-idn-01-04-user\"," ++
            "\"display_name\":\"Caller Fields\"," ++
            "\"email\":\"tc-idn-01-04@example.com\"," ++
            "\"status\":\"ACTIVE\"" ++
            "}",
    );
    defer freeRouteBody(alloc, result.body);

    try std.testing.expectEqual(@as(u16, 422), result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "validation_failed") != null);
}

test "TC-IDN-01-05: handleCreateUser allows status INACTIVE and returns 201" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const username = "tc-idn-01-05-user";
    cleanupUserByUsername(&pool, username);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const result = handleCreateUser(
        &service,
        alloc,
        adminActor(),
        "{" ++
            "\"username\":\"tc-idn-01-05-user\"," ++
            "\"display_name\":\"Inactive Allowed\"," ++
            "\"email\":\"tc-idn-01-05@example.com\"," ++
            "\"status\":\"INACTIVE\"" ++
            "}",
    );
    defer freeRouteBody(alloc, result.body);

    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const status = parsed.value.object.get("status") orelse return error.TestUnexpectedResult;
    try std.testing.expect(status == .string);
    try std.testing.expectEqualStrings("INACTIVE", status.string);
}

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const value = parsed.value.object.get(key) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return allocator.dupe(u8, value.string);
}

fn createTestUserId(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"username\":\"{s}\",\"display_name\":\"{s}\",\"email\":\"{s}\",\"status\":\"{s}\"}}",
        .{ username, display_name, email, status },
    );
    defer allocator.free(body);

    const result = handleCreateUser(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    return extractStringField(allocator, result.body, "user_id");
}

fn createTestGroupId(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{name});
    defer allocator.free(body);

    const result = handleCreateGroup(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try std.testing.expectEqual(@as(u16, 201), result.status_code);

    return extractStringField(allocator, result.body, "group_id");
}

fn cleanupGroupByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM group_members WHERE group_id IN (SELECT id FROM groups WHERE name = $1)", &[_][]const u8{name}) catch {};
    conn.exec("DELETE FROM groups WHERE name = $1", &[_][]const u8{name}) catch {};
}

test "TC-IDN-02-01: handleCreateGroup returns 201 and duplicate name returns 409" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-01-group";
    cleanupGroupByName(&pool, group_name);
    defer cleanupGroupByName(&pool, group_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createTestGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);

    const duplicate_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\"}}", .{group_name});
    defer alloc.free(duplicate_body);

    const duplicate = handleCreateGroup(&service, alloc, adminActor(), duplicate_body);
    defer freeRouteBody(alloc, duplicate.body);
    try std.testing.expectEqual(@as(u16, 409), duplicate.status_code);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.body, "duplicate_group_name") != null);
}

test "TC-IDN-02-02: handleAddGroupMember is idempotent and maps missing user or group to 404" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-02-group";
    const username = "tc-idn-02-02-user";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, username);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createTestGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id = try createTestUserId(&service, alloc, username, "Group User", "tc-idn-02-02@example.com", "ACTIVE");
    defer alloc.free(user_id);

    const add_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id});
    defer alloc.free(add_body);

    const first = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);
    defer freeRouteBody(alloc, first.body);
    try std.testing.expectEqual(@as(u16, 201), first.status_code);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"created\":true") != null);

    const second = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);
    defer freeRouteBody(alloc, second.body);
    try std.testing.expectEqual(@as(u16, 200), second.status_code);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"created\":false") != null);

    const missing_user = handleAddGroupMember(
        &service,
        alloc,
        adminActor(),
        group_id,
        "{\"user_id\":\"11111111-1111-1111-1111-111111111111\"}",
    );
    defer freeRouteBody(alloc, missing_user.body);
    try std.testing.expectEqual(@as(u16, 404), missing_user.status_code);

    const missing_group = handleAddGroupMember(
        &service,
        alloc,
        adminActor(),
        "11111111-1111-1111-1111-111111111111",
        add_body,
    );
    defer freeRouteBody(alloc, missing_group.body);
    try std.testing.expectEqual(@as(u16, 404), missing_group.status_code);
}

test "TC-IDN-02-03: handleListGroupMembers pages through members and returns next_cursor" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-03-group";
    const user_one = "tc-idn-02-03-user-1";
    const user_two = "tc-idn-02-03-user-2";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, user_one);
    cleanupUserByUsername(&pool, user_two);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, user_one);
    defer cleanupUserByUsername(&pool, user_two);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createTestGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id_one = try createTestUserId(&service, alloc, user_one, "Group One", "tc-idn-02-03-1@example.com", "ACTIVE");
    defer alloc.free(user_id_one);
    const user_id_two = try createTestUserId(&service, alloc, user_two, "Group Two", "tc-idn-02-03-2@example.com", "ACTIVE");
    defer alloc.free(user_id_two);

    const add_one = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id_one});
    defer alloc.free(add_one);
    const add_two = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id_two});
    defer alloc.free(add_two);

    _ = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_one);
    _ = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_two);

    const first_page = handleListGroupMembers(&service, alloc, adminActor(), group_id, .{ .cursor = null, .page_size = 1 });
    defer freeRouteBody(alloc, first_page.body);
    try std.testing.expectEqual(@as(u16, 200), first_page.status_code);

    const first_parsed = try std.json.parseFromSlice(std.json.Value, alloc, first_page.body, .{ .allocate = .alloc_always });
    defer first_parsed.deinit();
    const first_obj = first_parsed.value.object;
    const first_items = first_obj.get("items") orelse return error.TestUnexpectedResult;
    const first_next = first_obj.get("next_cursor") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_items == .array);
    try std.testing.expectEqual(@as(usize, 1), first_items.array.items.len);
    try std.testing.expect(first_next == .string);
    try std.testing.expect(first_next.string.len > 0);

    const first_user = first_items.array.items[0].object.get("username") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_user == .string);
    try std.testing.expectEqualStrings(user_two, first_user.string);

    const second_page = handleListGroupMembers(&service, alloc, adminActor(), group_id, .{ .cursor = first_next.string, .page_size = 1 });
    defer freeRouteBody(alloc, second_page.body);
    try std.testing.expectEqual(@as(u16, 200), second_page.status_code);

    const second_parsed = try std.json.parseFromSlice(std.json.Value, alloc, second_page.body, .{ .allocate = .alloc_always });
    defer second_parsed.deinit();
    const second_obj = second_parsed.value.object;
    const second_items = second_obj.get("items") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_items == .array);
    try std.testing.expectEqual(@as(usize, 1), second_items.array.items.len);

    const second_user = second_items.array.items[0].object.get("username") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_user == .string);
    try std.testing.expectEqualStrings(user_one, second_user.string);
}

test "TC-IDN-02-04: handleRemoveGroupMember is idempotent and missing group returns 404" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-04-group";
    const username = "tc-idn-02-04-user";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, username);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, username);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createTestGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const user_id = try createTestUserId(&service, alloc, username, "Remove User", "tc-idn-02-04@example.com", "ACTIVE");
    defer alloc.free(user_id);

    const add_body = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{user_id});
    defer alloc.free(add_body);
    _ = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_body);

    const first_remove = handleRemoveGroupMember(&service, alloc, adminActor(), group_id, user_id);
    defer freeRouteBody(alloc, first_remove.body);
    try std.testing.expectEqual(@as(u16, 204), first_remove.status_code);

    const second_remove = handleRemoveGroupMember(&service, alloc, adminActor(), group_id, user_id);
    defer freeRouteBody(alloc, second_remove.body);
    try std.testing.expectEqual(@as(u16, 204), second_remove.status_code);

    const missing_group = handleRemoveGroupMember(&service, alloc, adminActor(), "11111111-1111-1111-1111-111111111111", user_id);
    defer freeRouteBody(alloc, missing_group.body);
    try std.testing.expectEqual(@as(u16, 404), missing_group.status_code);
}

test "TC-IDN-02-05: active group members can claim group tasks" {
    const alloc = std.testing.allocator;
    const url = testDbUrl(alloc) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn-02-05-group";
    const active_user = "tc-idn-02-05-active";
    const inactive_user = "tc-idn-02-05-inactive";
    cleanupGroupByName(&pool, group_name);
    cleanupUserByUsername(&pool, active_user);
    cleanupUserByUsername(&pool, inactive_user);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupUserByUsername(&pool, active_user);
    defer cleanupUserByUsername(&pool, inactive_user);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createTestGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);
    const active_user_id = try createTestUserId(&service, alloc, active_user, "Active User", "tc-idn-02-05-a@example.com", "ACTIVE");
    defer alloc.free(active_user_id);
    const inactive_user_id = try createTestUserId(&service, alloc, inactive_user, "Inactive User", "tc-idn-02-05-i@example.com", "INACTIVE");
    defer alloc.free(inactive_user_id);

    const add_active = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{active_user_id});
    defer alloc.free(add_active);
    const add_inactive = try std.fmt.allocPrint(alloc, "{{\"user_id\":\"{s}\"}}", .{inactive_user_id});
    defer alloc.free(add_inactive);

    _ = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_active);
    _ = handleAddGroupMember(&service, alloc, adminActor(), group_id, add_inactive);

    try std.testing.expect(try service.canClaimGroupTask(alloc, auth.DEFAULT_TENANT_ID, group_id, active_user_id));
    try std.testing.expect(!(try service.canClaimGroupTask(alloc, auth.DEFAULT_TENANT_ID, group_id, inactive_user_id)));
    try std.testing.expect(!(try service.canClaimGroupTask(alloc, auth.DEFAULT_TENANT_ID, group_id, "11111111-1111-1111-1111-111111111111")));
}
