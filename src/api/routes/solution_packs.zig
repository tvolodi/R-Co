//! HTTP handlers for solution pack export and install endpoints.
//!
//! SOL-01: POST /api/v1/tenants/{tenant_id}/solution-packs/export
//! SOL-02: POST /api/v1/tenants/{tenant_id}/solution-packs/install
//!
//! Design artefact: src/design/sol-batch1-solution-pack.md
const std = @import("std");
const db = @import("pool");
const sol = @import("../../solution/store.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

// ---------------------------------------------------------------------------
// SOL-01: handleExport
// ---------------------------------------------------------------------------

/// POST /api/v1/tenants/{tenant_id}/solution-packs/export
///
/// Request body: {"definition_ids":["<uuid>",...], "version":"1.0.0"}
///
/// Response 200: SolutionPackDocument JSON.
/// Response 422: one or more definition_ids not found.
/// Response 400: malformed JSON body.
/// Response 503: pool exhausted.
/// Response 500: internal error.
pub fn handleExport(
    pool: *db.Pool,
    allocator: std.mem.Allocator,
    body: []const u8,
) HandlerResult {
    // Parse request body.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_if_needed },
    ) catch return errorResult(allocator, 400, "malformed_json");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "invalid_body"),
    };

    // Extract definition_ids.
    const ids_val = obj.get("definition_ids") orelse
        return errorResult(allocator, 422, "missing_definition_ids");
    const ids_arr = switch (ids_val) {
        .array => |a| a,
        else => return errorResult(allocator, 422, "definition_ids_must_be_array"),
    };
    if (ids_arr.items.len == 0) {
        return errorResult(allocator, 422, "definition_ids_empty");
    }

    // Extract optional version.
    const version: []const u8 = blk: {
        const v = obj.get("version") orelse break :blk "1.0.0";
        break :blk switch (v) {
            .string => |s| s,
            else => "1.0.0",
        };
    };

    // Build definition_ids slice.
    var def_ids: std.ArrayList([]const u8) = .empty;
    defer def_ids.deinit(allocator);
    for (ids_arr.items) |id_val| {
        const id_str = switch (id_val) {
            .string => |s| s,
            else => return errorResult(allocator, 422, "definition_id_must_be_string"),
        };
        def_ids.append(allocator, id_str) catch return errorResult(allocator, 500, "out_of_memory");
    }

    var store = sol.SolutionPackStore.init(pool);
    const doc = store.exportPack(allocator, version, def_ids.items) catch |err| {
        return switch (err) {
            sol.SolutionPackError.DefinitionNotFound => errorResult(allocator, 422, "DEFINITION_NOT_FOUND"),
            sol.SolutionPackError.ModuleNonExportable => errorResult(allocator, 422, "MODULE_NON_EXPORTABLE"),
            sol.SolutionPackError.PoolExhausted => errorResult(allocator, 503, "service_unavailable"),
            sol.SolutionPackError.OutOfMemory => errorResult(allocator, 500, "out_of_memory"),
            else => errorResult(allocator, 500, "internal_error"),
        };
    };
    defer freeDocument(allocator, doc);

    const resp_body = serializeDocument(allocator, doc) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = resp_body };
}

// ---------------------------------------------------------------------------
// SOL-02: handleInstall
// ---------------------------------------------------------------------------

/// POST /api/v1/tenants/{tenant_id}/solution-packs/install
///
/// Request body: SolutionPackDocument JSON.
///
/// Response 200: InstallResult JSON.
/// Response 409: CatalogConflict, VariableSchemaConflict, or TenantInactive.
/// Response 422: InvalidPackDocument.
/// Response 400: malformed JSON body.
/// Response 503: pool exhausted.
/// Response 500: internal error.
pub fn handleInstall(
    pool: *db.Pool,
    allocator: std.mem.Allocator,
    user_id: []const u8,
    body: []const u8,
) HandlerResult {
    if (body.len == 0) return errorResult(allocator, 400, "empty_body");

    // Parse the SolutionPackDocument from the request body.
    const doc_parsed = parseDocument(allocator, body) catch
        return errorResult(allocator, 422, "INVALID_PACK_DOCUMENT");
    defer freeDocument(allocator, doc_parsed);

    var store = sol.SolutionPackStore.init(pool);
    const result = store.installPack(allocator, doc_parsed, user_id) catch |err| {
        return switch (err) {
            sol.SolutionPackError.InvalidPackDocument => errorResult(allocator, 422, "INVALID_PACK_DOCUMENT"),
            sol.SolutionPackError.TenantInactive => errorResult(allocator, 409, "TENANT_INACTIVE"),
            sol.SolutionPackError.CatalogConflict => errorResult(allocator, 409, "CATALOG_CONFLICT"),
            sol.SolutionPackError.VariableSchemaConflict => errorResult(allocator, 409, "VARIABLE_SCHEMA_CONFLICT"),
            sol.SolutionPackError.PoolExhausted => errorResult(allocator, 503, "service_unavailable"),
            sol.SolutionPackError.OutOfMemory => errorResult(allocator, 500, "out_of_memory"),
            else => errorResult(allocator, 500, "internal_error"),
        };
    };
    defer freeInstallResult(allocator, result);

    const resp_body = serializeInstallResult(allocator, result) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = resp_body };
}

// ---------------------------------------------------------------------------
// Document parsing (install path)
// ---------------------------------------------------------------------------

fn parseDocument(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !sol.SolutionPackDocument {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_if_needed },
    );
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidPackDocument,
    };

    const schema_ver_raw = jsonStr(obj, "bpm_export_schema_version") orelse
        return error.InvalidPackDocument;
    const pack_id_raw = jsonStr(obj, "pack_id") orelse return error.InvalidPackDocument;
    const version_raw = jsonStr(obj, "version") orelse return error.InvalidPackDocument;
    const exported_at_raw = jsonStr(obj, "exported_at") orelse "2000-01-01T00:00:00Z";

    if (!std.mem.eql(u8, schema_ver_raw, sol.PACK_SCHEMA_VERSION)) {
        return error.InvalidPackDocument;
    }

    const schema_ver = try allocator.dupe(u8, schema_ver_raw);
    errdefer allocator.free(schema_ver);
    const pack_id = try allocator.dupe(u8, pack_id_raw);
    errdefer allocator.free(pack_id);
    const version = try allocator.dupe(u8, version_raw);
    errdefer allocator.free(version);
    const exported_at = try allocator.dupe(u8, exported_at_raw);
    errdefer allocator.free(exported_at);

    var defs: std.ArrayList(sol.PackedDefinition) = .empty;
    errdefer {
        for (defs.items) |d| {
            allocator.free(d.definition_id);
            allocator.free(d.process_key);
            allocator.free(d.name);
            allocator.free(d.version);
            allocator.free(d.graph);
            allocator.free(d.variable_schema);
        }
        defs.deinit(allocator);
    }

    if (obj.get("definitions")) |defs_val| {
        if (defs_val == .array) {
            for (defs_val.array.items) |def_val| {
                const d = switch (def_val) {
                    .object => |o| o,
                    else => continue,
                };
                const def_id = try allocator.dupe(u8, jsonStr(d, "definition_id") orelse "");
                errdefer allocator.free(def_id);
                const process_key = try allocator.dupe(u8, jsonStr(d, "process_key") orelse "");
                errdefer allocator.free(process_key);
                const def_name = try allocator.dupe(u8, jsonStr(d, "name") orelse "");
                errdefer allocator.free(def_name);
                const def_ver = try allocator.dupe(u8, jsonStr(d, "version") orelse "1.0.0");
                errdefer allocator.free(def_ver);
                const graph_json: []u8 = blk: {
                    const gv = d.get("graph") orelse break :blk try allocator.dupe(u8, "{}");
                    break :blk std.json.Stringify.valueAlloc(allocator, gv, .{}) catch
                        try allocator.dupe(u8, "{}");
                };
                errdefer allocator.free(graph_json);
                const vschema = try allocator.dupe(u8, jsonStr(d, "variable_schema") orelse "{}");
                errdefer allocator.free(vschema);
                try defs.append(allocator, .{
                    .definition_id = def_id,
                    .process_key = process_key,
                    .name = def_name,
                    .version = def_ver,
                    .graph = graph_json,
                    .variable_schema = vschema,
                });
            }
        }
    }

    var catalog: std.ArrayList(sol.PackedCatalogEntry) = .empty;
    errdefer {
        for (catalog.items) |e| {
            allocator.free(e.service_id);
            allocator.free(e.endpoint_url);
            allocator.free(e.request_schema);
            allocator.free(e.response_schema);
            allocator.free(e.required_auth);
            allocator.free(e.retry_policy);
        }
        catalog.deinit(allocator);
    }

    if (obj.get("service_catalog_entries")) |svc_val| {
        if (svc_val == .array) {
            for (svc_val.array.items) |ev| {
                const e = switch (ev) {
                    .object => |o| o,
                    else => continue,
                };
                const sid = try allocator.dupe(u8, jsonStr(e, "service_id") orelse "");
                errdefer allocator.free(sid);
                const url = try allocator.dupe(u8, jsonStr(e, "endpoint_url") orelse "");
                errdefer allocator.free(url);
                const req_s = try allocator.dupe(u8, jsonStr(e, "request_schema") orelse "{}");
                errdefer allocator.free(req_s);
                const resp_s = try allocator.dupe(u8, jsonStr(e, "response_schema") orelse "{}");
                errdefer allocator.free(resp_s);
                const auth = try allocator.dupe(u8, jsonStr(e, "required_auth") orelse "NONE");
                errdefer allocator.free(auth);
                const retry = try allocator.dupe(u8, jsonStr(e, "retry_policy") orelse "{}");
                errdefer allocator.free(retry);
                const tms: u32 = blk: {
                    const tv = e.get("timeout_ms") orelse break :blk 30000;
                    break :blk switch (tv) {
                        .integer => |n| @as(u32, @intCast(@max(0, n))),
                        else => 30000,
                    };
                };
                try catalog.append(allocator, .{
                    .service_id = sid,
                    .endpoint_url = url,
                    .request_schema = req_s,
                    .response_schema = resp_s,
                    .required_auth = auth,
                    .timeout_ms = tms,
                    .retry_policy = retry,
                });
            }
        }
    }

    var var_schemas: std.ArrayList(sol.PackedVariableSchema) = .empty;
    errdefer {
        for (var_schemas.items) |v| {
            allocator.free(v.definition_id);
            allocator.free(v.schema_name);
            allocator.free(v.schema_content);
        }
        var_schemas.deinit(allocator);
    }

    if (obj.get("variable_schemas")) |vsv| {
        if (vsv == .array) {
            for (vsv.array.items) |vv| {
                const v = switch (vv) {
                    .object => |o| o,
                    else => continue,
                };
                const did = try allocator.dupe(u8, jsonStr(v, "definition_id") orelse "");
                errdefer allocator.free(did);
                const sname = try allocator.dupe(u8, jsonStr(v, "schema_name") orelse "");
                errdefer allocator.free(sname);
                const scontent = try allocator.dupe(u8, jsonStr(v, "schema_content") orelse "{}");
                errdefer allocator.free(scontent);
                try var_schemas.append(allocator, .{
                    .definition_id = did,
                    .schema_name = sname,
                    .schema_content = scontent,
                });
            }
        }
    }

    var roles: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roles.items) |r| allocator.free(r);
        roles.deinit(allocator);
    }

    if (obj.get("manifest")) |mv| {
        if (mv == .object) {
            if (mv.object.get("required_roles")) |rrv| {
                if (rrv == .array) {
                    for (rrv.array.items) |rv| {
                        if (rv != .string) continue;
                        const r = try allocator.dupe(u8, rv.string);
                        try roles.append(allocator, r);
                    }
                }
            }
        }
    }

    return sol.SolutionPackDocument{
        .pack_id = pack_id,
        .version = version,
        .bpm_export_schema_version = schema_ver,
        .exported_at = exported_at,
        .definitions = try defs.toOwnedSlice(allocator),
        .service_catalog_entries = try catalog.toOwnedSlice(allocator),
        .variable_schemas = try var_schemas.toOwnedSlice(allocator),
        .manifest = .{ .required_roles = try roles.toOwnedSlice(allocator) },
    };
}

// ---------------------------------------------------------------------------
// JSON serialisation
// ---------------------------------------------------------------------------

fn serializeDocument(allocator: std.mem.Allocator, doc: sol.SolutionPackDocument) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"pack_id\":");
    try appendJsonStr(allocator, &buf, doc.pack_id);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, doc.version);
    try buf.appendSlice(allocator, ",\"bpm_export_schema_version\":");
    try appendJsonStr(allocator, &buf, doc.bpm_export_schema_version);
    try buf.appendSlice(allocator, ",\"exported_at\":");
    try appendJsonStr(allocator, &buf, doc.exported_at);
    try buf.appendSlice(allocator, ",\"definitions\":[");
    for (doc.definitions, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"definition_id\":");
        try appendJsonStr(allocator, &buf, d.definition_id);
        try buf.appendSlice(allocator, ",\"process_key\":");
        try appendJsonStr(allocator, &buf, d.process_key);
        try buf.appendSlice(allocator, ",\"name\":");
        try appendJsonStr(allocator, &buf, d.name);
        try buf.appendSlice(allocator, ",\"version\":");
        try appendJsonStr(allocator, &buf, d.version);
        try buf.appendSlice(allocator, ",\"graph\":");
        try buf.appendSlice(allocator, d.graph);
        try buf.appendSlice(allocator, ",\"variable_schema\":");
        try appendJsonStr(allocator, &buf, d.variable_schema);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"service_catalog_entries\":[");
    for (doc.service_catalog_entries, 0..) |e, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"service_id\":");
        try appendJsonStr(allocator, &buf, e.service_id);
        try buf.appendSlice(allocator, ",\"endpoint_url\":");
        try appendJsonStr(allocator, &buf, e.endpoint_url);
        try buf.appendSlice(allocator, ",\"request_schema\":");
        try buf.appendSlice(allocator, e.request_schema);
        try buf.appendSlice(allocator, ",\"response_schema\":");
        try buf.appendSlice(allocator, e.response_schema);
        try buf.appendSlice(allocator, ",\"required_auth\":");
        try appendJsonStr(allocator, &buf, e.required_auth);
        const tms_str = try std.fmt.allocPrint(allocator, ",\"timeout_ms\":{d}", .{e.timeout_ms});
        defer allocator.free(tms_str);
        try buf.appendSlice(allocator, tms_str);
        try buf.appendSlice(allocator, ",\"retry_policy\":");
        try buf.appendSlice(allocator, e.retry_policy);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"variable_schemas\":[");
    for (doc.variable_schemas, 0..) |v, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"definition_id\":");
        try appendJsonStr(allocator, &buf, v.definition_id);
        try buf.appendSlice(allocator, ",\"schema_name\":");
        try appendJsonStr(allocator, &buf, v.schema_name);
        try buf.appendSlice(allocator, ",\"schema_content\":");
        try buf.appendSlice(allocator, v.schema_content);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"manifest\":{\"required_roles\":[");
    for (doc.manifest.required_roles, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendJsonStr(allocator, &buf, r);
    }
    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

fn serializeInstallResult(allocator: std.mem.Allocator, result: sol.InstallResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"pack_id\":");
    try appendJsonStr(allocator, &buf, result.pack_id);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, result.version);
    try buf.appendSlice(allocator, ",\"installed_definitions\":[");
    for (result.installed_definitions, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"source_definition_id\":");
        try appendJsonStr(allocator, &buf, d.source_definition_id);
        try buf.appendSlice(allocator, ",\"new_definition_id\":");
        try appendJsonStr(allocator, &buf, d.new_definition_id);
        try buf.appendSlice(allocator, ",\"process_key\":");
        try appendJsonStr(allocator, &buf, d.process_key);
        try buf.appendSlice(allocator, ",\"status\":");
        try appendJsonStr(allocator, &buf, d.status);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"role_mapping_checklist\":[");
    for (result.role_mapping_checklist, 0..) |e, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"role_name\":");
        try appendJsonStr(allocator, &buf, e.role_name);
        try buf.appendSlice(allocator, ",\"bound\":");
        try buf.appendSlice(allocator, if (e.bound) "true" else "false");
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"warnings\":[");
    for (result.warnings, 0..) |w, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendJsonStr(allocator, &buf, w);
    }
    try buf.appendSlice(allocator, "]}");
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
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                const esc = try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{c});
                defer allocator.free(esc);
                try buf.appendSlice(allocator, esc);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn errorResult(allocator: std.mem.Allocator, code: u16, msg: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = code, .body = body };
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Memory cleanup
// ---------------------------------------------------------------------------

pub fn freeDocument(allocator: std.mem.Allocator, doc: sol.SolutionPackDocument) void {
    allocator.free(doc.pack_id);
    allocator.free(doc.version);
    allocator.free(doc.bpm_export_schema_version);
    allocator.free(doc.exported_at);
    for (doc.definitions) |d| {
        allocator.free(d.definition_id);
        allocator.free(d.process_key);
        allocator.free(d.name);
        allocator.free(d.version);
        allocator.free(d.graph);
        allocator.free(d.variable_schema);
    }
    allocator.free(doc.definitions);
    for (doc.service_catalog_entries) |e| {
        allocator.free(e.service_id);
        allocator.free(e.endpoint_url);
        allocator.free(e.request_schema);
        allocator.free(e.response_schema);
        allocator.free(e.required_auth);
        allocator.free(e.retry_policy);
    }
    allocator.free(doc.service_catalog_entries);
    for (doc.variable_schemas) |v| {
        allocator.free(v.definition_id);
        allocator.free(v.schema_name);
        allocator.free(v.schema_content);
    }
    allocator.free(doc.variable_schemas);
    for (doc.manifest.required_roles) |r| allocator.free(r);
    allocator.free(doc.manifest.required_roles);
}

fn freeInstallResult(allocator: std.mem.Allocator, result: sol.InstallResult) void {
    allocator.free(result.pack_id);
    allocator.free(result.version);
    for (result.installed_definitions) |d| {
        allocator.free(d.source_definition_id);
        allocator.free(d.new_definition_id);
        allocator.free(d.process_key);
        // d.status is a string literal — not freed
    }
    allocator.free(result.installed_definitions);
    for (result.role_mapping_checklist) |e| allocator.free(e.role_name);
    allocator.free(result.role_mapping_checklist);
    for (result.warnings) |w| allocator.free(w);
    allocator.free(result.warnings);
}
