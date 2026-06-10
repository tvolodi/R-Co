//! HTTP route handlers for service catalog endpoints (SVC-01, SVC-04).
//!
//! Routes registered in src/main.zig:
//!   GET  /api/v1/services                      → handleListServices
//!   GET  /api/v1/admin/services                → handleAdminListServices
//!   POST /api/v1/admin/services                → handleAdminRegisterService
//!   PATCH /api/v1/admin/services/:service_id   → handleAdminUpdateService
//!   DELETE /api/v1/admin/services/:service_id  → handleAdminDeleteService
//!
//! Design artefact: src/design/svc-01-04-service-scope.md §2.6

const std = @import("std");
const auth = @import("../middleware/auth.zig");
const catalog = @import("../../repository/service_catalog.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

// ---------------------------------------------------------------------------
// GET /api/v1/services  (SVC-01, SVC-04)
// ---------------------------------------------------------------------------

/// Tenant-scoped service listing: global entries + caller's own tenant-scoped entries.
/// Platform-admins (is_bootstrap or PLATFORM_ADMIN role) see all entries.
pub fn handleListServices(
    allocator: std.mem.Allocator,
    svc_catalog: *catalog.ServiceCatalog,
    actor: auth.AuthContext,
    after_id: ?[]const u8,
    limit: ?u32,
) HandlerResult {
    const eff_limit: u32 = limit orelse 50;

    // Determine caller tenant_id. Platform-admins get null (all entries).
    const caller_tenant_id: ?[16]u8 = blk: {
        if (actor.role == .PLATFORM_ADMIN or actor.is_bootstrap) break :blk null;
        // Parse tenant_id from the 36-char UUID string in actor.tenant_id.
        break :blk parseUuid36(&actor.tenant_id) catch null;
    };

    const records = svc_catalog.listServicesForTenant(allocator, caller_tenant_id, after_id, eff_limit) catch |err| switch (err) {
        catalog.CatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (records) |rec| freeRecord(allocator, rec);
        allocator.free(records);
    }

    const body = serializeRecordList(allocator, records) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// GET /api/v1/admin/services  (SVC-04)
// ---------------------------------------------------------------------------

/// Returns all service catalog entries regardless of scope (platform-admin only).
pub fn handleAdminListServices(
    allocator: std.mem.Allocator,
    svc_catalog: *catalog.ServiceCatalog,
    actor: auth.AuthContext,
    after_id: ?[]const u8,
    limit: ?u32,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");

    const eff_limit: u32 = limit orelse 50;

    const records = svc_catalog.listServicesForTenant(allocator, null, after_id, eff_limit) catch |err| switch (err) {
        catalog.CatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (records) |rec| freeRecord(allocator, rec);
        allocator.free(records);
    }

    const body = serializeRecordList(allocator, records) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// POST /api/v1/admin/services  (SVC-04)
// ---------------------------------------------------------------------------

/// Register a new service entry. Platform-admin only.
pub fn handleAdminRegisterService(
    allocator: std.mem.Allocator,
    svc_catalog: *catalog.ServiceCatalog,
    actor: auth.AuthContext,
    body_bytes: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body_bytes,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;

    const service_id = jsonString(obj, "service_id") orelse
        return errorResult(allocator, 422, "service_id_required");
    const endpoint_url = jsonString(obj, "endpoint_url") orelse
        return errorResult(allocator, 422, "endpoint_url_required");
    const request_schema = jsonString(obj, "request_schema") orelse "{}";
    const response_schema = jsonString(obj, "response_schema") orelse "{}";
    const auth_method_str = jsonString(obj, "auth_method") orelse "NONE";
    const timeout_ms: u32 = blk: {
        const v = obj.get("timeout_ms") orelse break :blk 30000;
        break :blk switch (v) {
            .integer => |n| if (n > 0 and n <= 3_600_000) @intCast(n) else
                return errorResult(allocator, 422, "timeout_invalid"),
            else => return errorResult(allocator, 422, "timeout_invalid"),
        };
    };

    const scope_str = jsonString(obj, "scope") orelse "global";
    const scope: catalog.ServiceScope = if (std.mem.eql(u8, scope_str, "tenant")) .tenant else .global;

    const owner_tenant_id: ?[16]u8 = blk: {
        const s = jsonString(obj, "owner_tenant_id") orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk parseUuid36(s) catch return errorResult(allocator, 422, "owner_tenant_id_invalid");
    };

    const required_auth = parseAuthMethod(auth_method_str) catch
        return errorResult(allocator, 422, "auth_method_invalid");

    const params = catalog.RegisterServiceParams{
        .service_id = service_id,
        .endpoint_url = endpoint_url,
        .request_schema = request_schema,
        .response_schema = response_schema,
        .required_auth = required_auth,
        .timeout_ms = timeout_ms,
        .retry_policy = jsonString(obj, "retry_policy"),
        .scope = scope,
        .owner_tenant_id = owner_tenant_id,
    };

    const rec = svc_catalog.registerService(allocator, params) catch |err| switch (err) {
        catalog.CatalogError.InvalidScopeConstraint => return errorResult(allocator, 422, "invalid_scope_constraint"),
        catalog.CatalogError.TenantNotFound => return errorResult(allocator, 422, "owner_tenant_not_found"),
        catalog.CatalogError.DuplicateService => return errorResult(allocator, 409, "service_id_conflict"),
        catalog.CatalogError.ServiceIdEmpty => return errorResult(allocator, 422, "service_id_empty"),
        catalog.CatalogError.ServiceIdTooLong => return errorResult(allocator, 422, "service_id_too_long"),
        catalog.CatalogError.TimeoutInvalid => return errorResult(allocator, 422, "timeout_invalid"),
        catalog.CatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeRecord(allocator, rec);

    const resp = serializeRecord(allocator, rec) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 201, .body = resp };
}

// ---------------------------------------------------------------------------
// PATCH /api/v1/admin/services/:service_id  (SVC-04)
// ---------------------------------------------------------------------------

/// Update scope and owner_tenant_id for an existing service. Platform-admin only.
pub fn handleAdminUpdateService(
    allocator: std.mem.Allocator,
    svc_catalog: *catalog.ServiceCatalog,
    actor: auth.AuthContext,
    service_id: []const u8,
    body_bytes: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body_bytes,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;

    const scope_str = jsonString(obj, "scope") orelse
        return errorResult(allocator, 422, "scope_required");
    const scope: catalog.ServiceScope = if (std.mem.eql(u8, scope_str, "tenant")) .tenant else .global;

    const owner_tenant_id: ?[16]u8 = blk: {
        const s = jsonString(obj, "owner_tenant_id") orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk parseUuid36(s) catch return errorResult(allocator, 422, "owner_tenant_id_invalid");
    };

    const params = catalog.UpdateServiceScopeParams{
        .scope = scope,
        .owner_tenant_id = owner_tenant_id,
    };

    const rec = svc_catalog.updateServiceScope(allocator, service_id, params) catch |err| switch (err) {
        catalog.CatalogError.ServiceNotFound => return errorResult(allocator, 404, "service_not_found"),
        catalog.CatalogError.InvalidScopeConstraint => return errorResult(allocator, 422, "invalid_scope_constraint"),
        catalog.CatalogError.ConflictingActiveDefinitions => {
            const ids = svc_catalog.lastConflictingTenantIds();
            return conflictResult(allocator, "conflicting_active_definitions", ids);
        },
        catalog.CatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeRecord(allocator, rec);

    const resp = serializeRecord(allocator, rec) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = resp };
}

// ---------------------------------------------------------------------------
// DELETE /api/v1/admin/services/:service_id  (SVC-04)
// ---------------------------------------------------------------------------

/// Remove a service from the catalog. Platform-admin only.
pub fn handleAdminDeleteService(
    allocator: std.mem.Allocator,
    svc_catalog: *catalog.ServiceCatalog,
    actor: auth.AuthContext,
    service_id: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");

    svc_catalog.deleteService(allocator, service_id) catch |err| switch (err) {
        catalog.CatalogError.ServiceNotFound => return errorResult(allocator, 404, "service_not_found"),
        catalog.CatalogError.ServiceInUse => {
            const ids = svc_catalog.lastInUseDefinitionIds();
            return conflictResult(allocator, "service_in_use", ids);
        },
        catalog.CatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    const body = allocator.dupe(u8, "{\"deleted\":true}") catch
        return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn serializeRecord(allocator: std.mem.Allocator, rec: catalog.ServiceCatalogRecord) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{");
    try appendJsonString(allocator, &buf, "service_id", rec.service_id, false);
    try appendJsonString(allocator, &buf, "endpoint_url", rec.endpoint_url, true);
    try appendJsonString(allocator, &buf, "scope",
        if (rec.scope == .global) "global" else "tenant", true);

    if (rec.owner_tenant_id) |tid| {
        var tid_str: [36]u8 = undefined;
        _ = std.fmt.bufPrint(&tid_str, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            tid[0],  tid[1],  tid[2],  tid[3],
            tid[4],  tid[5],  tid[6],  tid[7],
            tid[8],  tid[9],  tid[10], tid[11],
            tid[12], tid[13], tid[14], tid[15],
        }) catch {};
        try appendJsonString(allocator, &buf, "owner_tenant_id", &tid_str, true);
    } else {
        try buf.appendSlice(allocator, ",\"owner_tenant_id\":null");
    }

    try appendJsonString(allocator, &buf, "required_auth", authMethodStr(rec.required_auth), true);
    const timeout_str = try std.fmt.allocPrint(allocator, "{d}", .{rec.timeout_ms});
    defer allocator.free(timeout_str);
    try buf.appendSlice(allocator, ",\"timeout_ms\":");
    try buf.appendSlice(allocator, timeout_str);

    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn serializeRecordList(allocator: std.mem.Allocator, records: []catalog.ServiceCatalogRecord) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (records, 0..) |rec, i| {
        if (i > 0) try buf.append(allocator, ',');
        const item = try serializeRecord(allocator, rec);
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn conflictResult(allocator: std.mem.Allocator, code: []const u8, ids: []const [16]u8) HandlerResult {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"error\":\"") catch {};
    buf.appendSlice(allocator, code) catch {};
    buf.appendSlice(allocator, "\",\"conflicting_ids\":[") catch {};
    for (ids, 0..) |tid, i| {
        if (i > 0) buf.append(allocator, ',') catch {};
        var tid_str: [38]u8 = undefined; // "\"uuid\""
        tid_str[0] = '"';
        _ = std.fmt.bufPrint(tid_str[1..37], "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            tid[0],  tid[1],  tid[2],  tid[3],
            tid[4],  tid[5],  tid[6],  tid[7],
            tid[8],  tid[9],  tid[10], tid[11],
            tid[12], tid[13], tid[14], tid[15],
        }) catch {};
        tid_str[37] = '"';
        buf.appendSlice(allocator, &tid_str) catch {};
    }
    buf.appendSlice(allocator, "]}") catch {};

    const body = buf.toOwnedSlice(allocator) catch
        return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 409, .body = body };
}

fn errorResult(allocator: std.mem.Allocator, status: u16, msg: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch
        return .{ .status_code = status, .body = "{\"error\":\"internal\"}" };
    return .{ .status_code = status, .body = body };
}

fn freeRecord(allocator: std.mem.Allocator, rec: catalog.ServiceCatalogRecord) void {
    allocator.free(rec.service_id);
    allocator.free(rec.endpoint_url);
    allocator.free(rec.request_schema);
    allocator.free(rec.response_schema);
    allocator.free(rec.retry_policy);
}

fn authMethodStr(m: catalog.AuthMethod) []const u8 {
    return switch (m) {
        .NONE => "NONE",
        .API_KEY => "API_KEY",
        .OAUTH2 => "OAUTH2",
        .MUTUAL_TLS => "MUTUAL_TLS",
    };
}

fn parseAuthMethod(s: []const u8) !catalog.AuthMethod {
    if (std.mem.eql(u8, s, "NONE")) return .NONE;
    if (std.mem.eql(u8, s, "API_KEY")) return .API_KEY;
    if (std.mem.eql(u8, s, "OAUTH2")) return .OAUTH2;
    if (std.mem.eql(u8, s, "MUTUAL_TLS")) return .MUTUAL_TLS;
    return error.InvalidAuthMethod;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn parseUuid36(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var src: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c != '-') {
            if (j >= 32) return error.InvalidUuid;
            src[j] = c;
            j += 1;
        }
    }
    if (j != 32) return error.InvalidUuid;
    for (0..16) |i| {
        uuid[i] = try std.fmt.parseInt(u8, src[i * 2 .. i * 2 + 2], 16);
    }
    return uuid;
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try buf.append(allocator, ',');
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    // Escape JSON special chars.
    for (value) |c| {
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
