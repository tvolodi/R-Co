//! HTTP route handlers for process module catalog endpoints (PLC-01, PLC-02, PLC-04).

const std = @import("std");
const auth = @import("../middleware/auth.zig");
const pmc = @import("../../repository/process_module_catalog.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub fn handleListModules(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    after_module_version: ?[]const u8,
    limit: ?u32,
) HandlerResult {
    const caller_tenant_id: ?[16]u8 = blk: {
        if (actor.role == .PLATFORM_ADMIN or actor.is_bootstrap) break :blk null;
        break :blk parseUuid36(&actor.tenant_id) catch null;
    };
    if (caller_tenant_id == null) {
        return errorResult(allocator, 403, "forbidden");
    }
    const eff_limit: u32 = limit orelse 50;
    const result = catalog.listVisibleModules(
        allocator, caller_tenant_id.?, after_module_version, eff_limit,
    ) catch |err| switch (err) {
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (result.records) |rec| freeEntry(allocator, rec);
        allocator.free(result.records);
        if (result.next_cursor) |c| allocator.free(c);
    }
    const body = serializeModuleList(allocator, result.records, result.next_cursor) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

pub fn handleRegisterModule(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    body_bytes: []const u8,
) HandlerResult {
    if (actor.role != .PROCESS_DESIGNER and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");
    const parsed = std.json.parseFromSlice(
        std.json.Value, allocator, body_bytes, .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;
    const module_id = jsonString(obj, "module_id") orelse
        return errorResult(allocator, 422, "module_id_required");
    const version = jsonString(obj, "version") orelse
        return errorResult(allocator, 422, "version_required");
    const owning_definition_id_str = jsonString(obj, "owning_definition_id") orelse
        return errorResult(allocator, 422, "owning_definition_id_required");
    const exportable = obj.get("exportable") != null and obj.get("exportable").?.bool;
    const tenant_id = parseUuid36(&actor.tenant_id) catch
        return errorResult(allocator, 422, "tenant_id_invalid");
    const owning_def_id = parseUuid36(owning_definition_id_str) catch
        return errorResult(allocator, 422, "owning_definition_id_invalid");
    const interface_schema_json = blk: {
        const v = obj.get("interface_schema") orelse break :blk "{}";
        break :blk (std.json.Stringify.valueAlloc(allocator, v, .{}) catch "{}");
    };
    const params = pmc.RegisterModuleParams{
        .module_id = module_id,
        .version = version,
        .owning_tenant_id = tenant_id,
        .owning_definition_id = owning_def_id,
        .interface_schema_json = interface_schema_json,
        .exportable = exportable,
    };
    const entry = catalog.registerModule(allocator, params) catch |err| switch (err) {
        pmc.ModuleCatalogError.DuplicateModuleVersion => return errorResult(allocator, 409, "module_version_conflict"),
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeEntry(allocator, entry);
    const resp = serializeEntry(allocator, entry) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 201, .body = resp };
}

pub fn handleGetModuleVersion(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    module_id: []const u8,
    version: []const u8,
) HandlerResult {
    const caller_tenant_id: ?[16]u8 = blk: {
        if (actor.role == .PLATFORM_ADMIN or actor.is_bootstrap) break :blk null;
        break :blk parseUuid36(&actor.tenant_id) catch null;
    };
    if (caller_tenant_id == null) return errorResult(allocator, 403, "forbidden");
    const ref = pmc.ModuleRef{ .module_id = module_id, .version_constraint = version };
    const resolution = catalog.resolveModuleRef(allocator, ref, caller_tenant_id.?) catch |err| switch (err) {
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    if (!resolution.resolved or resolution.entry == null) {
        return errorResult(allocator, 404, "module_not_found");
    }
    const entry = resolution.entry.?;
    const resp = serializeEntry(allocator, entry) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = resp };
}

pub fn handlePublishModule(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    module_id: []const u8,
    version: []const u8,
) HandlerResult {
    if (actor.role != .PROCESS_DESIGNER and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");
    const actor_id = parseUuid36(&actor.tenant_id) catch
        return errorResult(allocator, 422, "actor_id_invalid");
    const result = catalog.publishModule(allocator, module_id, version, actor_id) catch |err| switch (err) {
        pmc.ModuleCatalogError.ModuleNotFound => return errorResult(allocator, 404, "module_not_found"),
        pmc.ModuleCatalogError.InterfaceNotDeclared => return errorResult(allocator, 422, "interface_not_declared"),
        pmc.ModuleCatalogError.ModuleAlreadyActive => return errorResult(allocator, 409, "module_already_active"),
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeEntry(allocator, result.entry);
    const resp = serializePublishResult(allocator, result) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = resp };
}

pub fn handleGrantShare(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    body_bytes: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");
    const parsed = std.json.parseFromSlice(
        std.json.Value, allocator, body_bytes, .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(allocator, 422, "invalid_body");
    const obj = parsed.value.object;
    const granting_tenant_id_str = jsonString(obj, "granting_tenant_id") orelse
        return errorResult(allocator, 422, "granting_tenant_id_required");
    const module_id = jsonString(obj, "module_id") orelse
        return errorResult(allocator, 422, "module_id_required");
    const receiving_tenant_id_str = jsonString(obj, "receiving_tenant_id") orelse
        return errorResult(allocator, 422, "receiving_tenant_id_required");
    const granting_tenant_id = parseUuid36(granting_tenant_id_str) catch
        return errorResult(allocator, 422, "granting_tenant_id_invalid");
    const receiving_tenant_id = parseUuid36(receiving_tenant_id_str) catch
        return errorResult(allocator, 422, "receiving_tenant_id_invalid");
    const granted_by = parseUuid36(&actor.tenant_id) catch
        return errorResult(allocator, 422, "granted_by_invalid");
    const params = pmc.ShareGrantParams{
        .granting_tenant_id = granting_tenant_id,
        .module_id = module_id,
        .receiving_tenant_id = receiving_tenant_id,
        .granted_by = granted_by,
    };
    catalog.grantModuleVisibility(allocator, params) catch |err| switch (err) {
        pmc.ModuleCatalogError.SharingGrantAlreadyExists => return errorResult(allocator, 409, "share_already_exists"),
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    return .{ .status_code = 201, .body = "{\"status\":\"ok\"}" };
}

pub fn handleRevokeShare(
    allocator: std.mem.Allocator,
    catalog: *pmc.ProcessModuleCatalog,
    actor: auth.AuthContext,
    grant_id: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN and !actor.is_bootstrap)
        return errorResult(allocator, 403, "forbidden");
    const gid = parseUuid36String(grant_id) catch
        return errorResult(allocator, 422, "grant_id_invalid");
    const actor_id = parseUuid36(&actor.tenant_id) catch
        return errorResult(allocator, 422, "actor_id_invalid");
    catalog.revokeModuleVisibility(allocator, gid, actor_id) catch |err| switch (err) {
        pmc.ModuleCatalogError.SharingGrantNotFound => return errorResult(allocator, 404, "share_not_found"),
        pmc.ModuleCatalogError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    return .{ .status_code = 204, .body = "" };
}

fn serializeEntry(allocator: std.mem.Allocator, entry: pmc.ProcessModuleCatalogEntry) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try serializeEntryTo(&buf, entry, allocator);
    return buf.toOwnedSlice(allocator);
}

fn serializeEntryTo(buf: *std.ArrayList(u8), entry: pmc.ProcessModuleCatalogEntry, allocator: std.mem.Allocator) !void {
    try buf.appendSlice(allocator, "{\"module_id\":");
    try jsonEscape(buf, entry.module_id, allocator);
    try buf.appendSlice(allocator, ",\"version\":");
    try jsonEscape(buf, entry.version, allocator);
    try buf.appendSlice(allocator, ",\"owning_tenant_id\":");
    try buf.appendSlice(allocator, try uuidToHexStr(allocator, entry.owning_tenant_id));
    try buf.appendSlice(allocator, ",\"owning_definition_id\":");
    try buf.appendSlice(allocator, try uuidToHexStr(allocator, entry.owning_definition_id));
    try buf.appendSlice(allocator, ",\"interface_schema\":");
    try buf.appendSlice(allocator, entry.interface_schema_json);
    try buf.appendSlice(allocator, ",\"exportable\":");
    try buf.appendSlice(allocator, if (entry.exportable) "true" else "false");
    try buf.appendSlice(allocator, ",\"status\":");
    try buf.appendSlice(allocator, switch (entry.status) {
        .draft => "draft",
        .active => "active",
        .deprecated => "deprecated",
    });
    {
        const ts = try std.fmt.allocPrint(allocator, ",\"created_at\":{d},\"updated_at\":{d}", .{ entry.created_at, entry.updated_at });
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    }
    try buf.append(allocator, '}');
}

fn serializeModuleList(allocator: std.mem.Allocator, records: []pmc.ProcessModuleCatalogEntry, next_cursor: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"records\":[");
    for (records, 0..) |rec, i| {
        if (i > 0) try buf.append(allocator, ',');
        try serializeEntryTo(&buf, rec, allocator);
    }
    try buf.appendSlice(allocator, "],\"next_cursor\":");
    if (next_cursor) |c| {
        try buf.append(allocator, '"');
        try jsonEscape(&buf, c, allocator);
        try buf.append(allocator, '"');
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn serializePublishResult(allocator: std.mem.Allocator, result: pmc.PublishModuleResult) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"entry\":");
    try serializeEntryTo(&buf, result.entry, allocator);
    if (result.compatibility_warning) |w| {
        try buf.appendSlice(allocator, ",\"compatibility_warning\":{\"module_id\":");
        try jsonEscape(&buf, w.module_id, allocator);
        try buf.appendSlice(allocator, ",\"new_version\":");
        try jsonEscape(&buf, w.new_version, allocator);
        try buf.appendSlice(allocator, ",\"previous_version\":");
        try jsonEscape(&buf, w.previous_version, allocator);
        try buf.appendSlice(allocator, ",\"breaking_changes\":[");
        for (w.breaking_changes, 0..) |change, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try jsonEscape(&buf, change, allocator);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "]}");
    } else {
        try buf.appendSlice(allocator, ",\"compatibility_warning\":null");
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn jsonEscape(buf: *std.ArrayList(u8), s: []const u8, allocator: std.mem.Allocator) !void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => try buf.append(allocator, c),
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn parseUuid36(s: []const u8) ![16]u8 { return hexToUuid(s); }
fn parseUuid36String(s: []const u8) ![16]u8 { return hexToUuid(s); }

fn hexToUuid(s: []const u8) ![16]u8 {
    var uuid: [16]u8 = undefined;
    var src: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= 32) return error.InvalidUuid;
        src[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    for (0..16) |i| {
        const high = hexChar(src[i * 2]);
        const low = hexChar(src[i * 2 + 1]);
        if (high == 255 or low == 255) return error.InvalidUuid;
        uuid[i] = high * 16 + low;
    }
    return uuid;
}

fn hexChar(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 255;
}

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    var buf: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
        uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15],
    }) catch return error.InvalidUuid;
    return try allocator.dupe(u8, &buf);
}

fn freeEntry(allocator: std.mem.Allocator, entry: pmc.ProcessModuleCatalogEntry) void {
    allocator.free(entry.module_id);
    allocator.free(entry.version);
}

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8) HandlerResult {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "{\"error\":{\"code\":\"") catch return .{ .status_code = 500, .body = "{}" };
    buf.appendSlice(allocator, code) catch return .{ .status_code = 500, .body = "{}" };
    buf.appendSlice(allocator, "\"}}") catch return .{ .status_code = 500, .body = "{}" };
    return .{ .status_code = status, .body = buf.toOwnedSlice(allocator) catch "{}" };
}