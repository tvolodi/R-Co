//! HTTP route handlers for PD-07 definition retrieval endpoints.
//!
//! All three handlers require a valid authenticated session (API-08).
//! Auth is enforced by upstream middleware — handlers may assume the caller
//! has already validated the session before invoking these functions.
//!
//! Route registration (wire in router.zig / main.zig once HTTP layer is ready — Stage 4):
//!   GET /api/v1/definitions/:id             → handleGetById
//!   GET /api/v1/definitions                 → handleList
//!   GET /api/v1/definitions/active/:name    → handleGetActiveByName

const std = @import("std");
const definition_store = @import("../../definition/store.zig");
const export_import = @import("../../definition/export_import.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Query parameters accepted by GET /api/v1/definitions.
pub const ListQueryParams = struct {
    /// Exact name filter; null = all names.
    name: ?[]const u8,
    /// Raw status string — validated before calling Store; null = all statuses.
    status: ?[]const u8,
    /// Free-text stage label filter (PD-07); null = all stages.
    stage: ?[]const u8,
    /// Opaque base64url-encoded pagination cursor (API-06).
    cursor: ?[]const u8,
    /// Page size 1–200; null or 0 → default 50.
    page_size: ?u16,
};

/// Result returned by each handler: an HTTP status code and a JSON body
/// string. The body slice is allocated with the caller-supplied allocator.
pub const HandlerResult = struct {
    status_code: u16,
    /// JSON-encoded response body; owned by the caller allocator.
    body: []const u8,
};

// ---------------------------------------------------------------------------
// Public handler functions
// ---------------------------------------------------------------------------

/// GET /api/v1/definitions/:id
///
/// Success:  HTTP 200 + JSON definition body.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleGetById(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const def = store.getById(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// GET /api/v1/definitions
///
/// Query params: ?name=, ?status=, ?stage=, ?cursor=, ?page_size=
/// Success: HTTP 200 + JSON { "items": [...], "cursor": string | null }
/// Invalid params: HTTP 422 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleList(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    params: ListQueryParams,
) HandlerResult {
    // Validate ?status= — must be one of the four known DefinitionStatus values.
    const status_filter: ?definition_store.DefinitionStatus = blk: {
        const raw = params.status orelse break :blk null;
        if (std.mem.eql(u8, raw, "DRAFT")) break :blk .DRAFT;
        if (std.mem.eql(u8, raw, "ACTIVE")) break :blk .ACTIVE;
        if (std.mem.eql(u8, raw, "DEPRECATED")) break :blk .DEPRECATED;
        if (std.mem.eql(u8, raw, "ARCHIVED")) break :blk .ARCHIVED;
        return errorResult(allocator, 422, "invalid status value; must be one of DRAFT, ACTIVE, DEPRECATED, ARCHIVED");
    };

    // Validate ?page_size=.
    const effective_page_size: u8 = blk: {
        const ps = params.page_size orelse break :blk 50;
        if (ps == 0 or ps > 200) return errorResult(allocator, 422, "page_size must be between 1 and 200");
        break :blk @as(u8, @intCast(ps));
    };

    // Decode ?cursor= (base64url → i64 microseconds).
    const after_created: ?i64 = blk: {
        const cursor_str = params.cursor orelse break :blk null;
        const decoded = decodeCursor(allocator, cursor_str) catch
            return errorResult(allocator, 422, "invalid cursor");
        defer allocator.free(decoded);
        const ts = std.fmt.parseInt(i64, decoded, 10) catch
            return errorResult(allocator, 422, "invalid cursor");
        break :blk ts;
    };

    const opts = definition_store.ListOpts{
        .name = params.name,
        .status = status_filter,
        .stage = params.stage,
        .after_created = after_created,
        .limit = effective_page_size,
    };

    const defs = store.list(allocator, opts) catch |err| switch (err) {
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer {
        for (defs) |d| freeDefinition(allocator, d);
        allocator.free(defs);
    }

    // Encode next-page cursor when the full page was returned.
    const next_cursor: ?[]const u8 = if (defs.len == @as(usize, effective_page_size))
        encodeCursor(allocator, defs[defs.len - 1].created_at) catch null
    else
        null;
    defer if (next_cursor) |c| allocator.free(c);

    const body = serializeListResponse(allocator, defs, next_cursor) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// GET /api/v1/definitions/active/:name
///
/// Success:  HTTP 200 + JSON definition body (status = ACTIVE).
/// Not found: HTTP 404 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleGetActiveByName(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    name: []const u8,
) HandlerResult {
    const def = store.getActiveByName(allocator, name) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// Private helpers — UUID
// ---------------------------------------------------------------------------

fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn statusToStr(status: definition_store.DefinitionStatus) []const u8 {
    return switch (status) {
        .DRAFT => "DRAFT",
        .ACTIVE => "ACTIVE",
        .DEPRECATED => "DEPRECATED",
        .ARCHIVED => "ARCHIVED",
    };
}

// ---------------------------------------------------------------------------
// Private helpers — cursor (API-06)
// ---------------------------------------------------------------------------

/// Encode a created_at µs timestamp as a base64url-no-pad cursor string.
/// Caller owns the returned slice.
fn encodeCursor(allocator: std.mem.Allocator, created_at_us: i64) ![]u8 {
    const decimal = try std.fmt.allocPrint(allocator, "{d}", .{created_at_us});
    defer allocator.free(decimal);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = enc.calcSize(decimal.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = enc.encode(buf, decimal);
    return buf;
}

/// Decode a base64url-no-pad cursor into the raw decimal string.
/// Caller owns the returned slice.
fn decodeCursor(allocator: std.mem.Allocator, cursor: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = dec.calcSizeForSlice(cursor) catch return error.InvalidCursor;
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    dec.decode(buf, cursor) catch return error.InvalidCursor;
    return buf;
}

// ---------------------------------------------------------------------------
// Private helpers — JSON serialisation
// ---------------------------------------------------------------------------

/// Free all heap-allocated strings inside a Definition.
fn freeDefinition(allocator: std.mem.Allocator, def: definition_store.Definition) void {
    allocator.free(def.name);
    allocator.free(def.version);
    if (def.description) |d| allocator.free(d);
    if (def.stage) |s| allocator.free(s);
}

/// Append a JSON-encoded string (double-quoted, with escaping) to buf.
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

/// Serialise a single Definition to a JSON string. Caller owns the result.
fn serializeDefinition(allocator: std.mem.Allocator, def: definition_store.Definition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const id_hex = try uuidToHex(allocator, def.id);
    defer allocator.free(id_hex);
    const created_by_hex = try uuidToHex(allocator, def.created_by);
    defer allocator.free(created_by_hex);

    try buf.appendSlice(allocator, "{\"id\":");
    try appendJsonStr(allocator, &buf, id_hex);
    try buf.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(allocator, &buf, def.name);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, def.version);
    try buf.appendSlice(allocator, ",\"description\":");
    if (def.description) |d| {
        try appendJsonStr(allocator, &buf, d);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"status\":");
    try appendJsonStr(allocator, &buf, statusToStr(def.status));
    // Graph: emit the raw graph nodes/edges arrays.
    // When pg.zig delivers real rows this should be replaced with parsed JSONB.
    try buf.appendSlice(allocator, ",\"graph\":{\"nodes\":[],\"edges\":[]}");
    try buf.appendSlice(allocator, ",\"created_by\":");
    try appendJsonStr(allocator, &buf, created_by_hex);
    {
        const ts = try std.fmt.allocPrint(
            allocator,
            ",\"created_at\":{d},\"updated_at\":{d}",
            .{ def.created_at, def.updated_at },
        );
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    }
    try buf.appendSlice(allocator, ",\"archived_at\":");
    if (def.archived_at) |a| {
        const ts = try std.fmt.allocPrint(allocator, "{d}", .{a});
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"stage\":");
    if (def.stage) |s| {
        try appendJsonStr(allocator, &buf, s);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Serialise the paginated list response body. Caller owns the result.
fn serializeListResponse(
    allocator: std.mem.Allocator,
    defs: []const definition_store.Definition,
    cursor: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try buf.append(allocator, ',');
        const item = try serializeDefinition(allocator, def);
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "],\"cursor\":");
    if (cursor) |c| {
        try appendJsonStr(allocator, &buf, c);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Build a static error response. Falls back to a literal string on allocation failure.
fn errorResult(allocator: std.mem.Allocator, code: u16, msg: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch
        "{\"error\":\"internal server error\"}";
    return .{ .status_code = code, .body = body };
}

// ---------------------------------------------------------------------------
// PD-09: Export / import handlers
// ---------------------------------------------------------------------------

/// GET /api/v1/definitions/:id/export
///
/// Exports the definition as a self-contained JSON document.
/// Success: HTTP 200 + JSON ExportDocument.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleExport(
    allocator: std.mem.Allocator,
    store: *export_import.ExportImportStore,
    definition_id_str: []const u8,
) HandlerResult {
    const id = parseUuid(definition_id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const doc = store.exportDefinition(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer {
        allocator.free(doc.name);
        allocator.free(doc.version);
        allocator.free(doc.description);
        allocator.free(doc.exported_at);
        // graph is not freed here — consistent with existing store (pg.zig stub returns empty graph)
    }

    const body = serializeExportDocument(allocator, doc) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// POST /api/v1/definitions/import
///
/// Imports a definition from a previously exported JSON document.
/// Success: HTTP 201 + JSON Definition body (same format as PD-01 create response).
/// Unknown schema version: HTTP 422 + {"error": "unknown_schema_version"}.
/// Name+version conflict: HTTP 409 + {"error": "name_version_conflict"}.
/// Invalid graph (including CEL): HTTP 422 + {"error": "invalid_graph"}.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleImport(
    allocator: std.mem.Allocator,
    store: *export_import.ExportImportStore,
    body: []const u8,
) HandlerResult {
    // Parse body as a generic JSON value for flexible field extraction.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return errorResult(allocator, 422, "invalid import document");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 422, "invalid import document"),
    };

    const schema_ver = jsonObjStr(obj, "bpm_export_schema_version") orelse
        return errorResult(allocator, 422, "missing bpm_export_schema_version");
    const id_str = jsonObjStr(obj, "id") orelse "";
    const name = jsonObjStr(obj, "name") orelse
        return errorResult(allocator, 422, "missing name");
    const ver = jsonObjStr(obj, "version") orelse
        return errorResult(allocator, 422, "missing version");
    const description = jsonObjStr(obj, "description") orelse "";
    const exported_at = jsonObjStr(obj, "exported_at") orelse "";

    // Parse graph from "graph" key: stringify back to JSON then re-parse to DefinitionGraph.
    const graph: export_import.DefinitionGraph = blk: {
        const gv = obj.get("graph") orelse
            break :blk export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
        const graph_json = std.json.Stringify.valueAlloc(allocator, gv, .{}) catch
            break :blk export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
        defer allocator.free(graph_json);
        break :blk parseImportGraph(allocator, graph_json) catch
            export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
    };

    // id is informational only; parseUuid failure falls back to zeroed Uuid.
    const id = parseUuid(id_str) catch std.mem.zeroes(export_import.Uuid);

    const doc = export_import.ExportDocument{
        .bpm_export_schema_version = schema_ver,
        .id = id,
        .name = name,
        .version = ver,
        .description = description,
        .graph = graph,
        .exported_at = exported_at,
    };

    const def = store.importDefinition(allocator, doc) catch |err| switch (err) {
        error.UnknownSchemaVersion => return errorResult(allocator, 422, "unknown_schema_version"),
        error.NameVersionConflict => return errorResult(allocator, 409, "name_version_conflict"),
        error.InvalidGraph => return errorResult(allocator, 422, "invalid_graph"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 201, .body = resp_body };
}

// ---------------------------------------------------------------------------
// Private helpers — PD-09
// ---------------------------------------------------------------------------

/// Serialise an ExportDocument to a JSON string. Caller owns the result.
fn serializeExportDocument(allocator: std.mem.Allocator, doc: export_import.ExportDocument) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const id_hex = try uuidToHex(allocator, doc.id);
    defer allocator.free(id_hex);

    try buf.appendSlice(allocator, "{\"bpm_export_schema_version\":");
    try appendJsonStr(allocator, &buf, doc.bpm_export_schema_version);
    try buf.appendSlice(allocator, ",\"id\":");
    try appendJsonStr(allocator, &buf, id_hex);
    try buf.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(allocator, &buf, doc.name);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, doc.version);
    try buf.appendSlice(allocator, ",\"description\":");
    try appendJsonStr(allocator, &buf, doc.description);
    // Graph: emit nodes/edges arrays. Stub consistent with existing serializeDefinition.
    try buf.appendSlice(allocator, ",\"graph\":{\"nodes\":[],\"edges\":[]}");
    try buf.appendSlice(allocator, ",\"exported_at\":");
    try appendJsonStr(allocator, &buf, doc.exported_at);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Parse a DefinitionGraph from a JSON string slice (used for import body graph field).
fn parseImportGraph(
    allocator: std.mem.Allocator,
    json_str: []const u8,
) error{ OutOfMemory, InvalidGraph }!export_import.DefinitionGraph {
    if (json_str.len == 0) return error.InvalidGraph;
    const parsed = std.json.parseFromSlice(
        export_import.DefinitionGraph,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidGraph;
    defer parsed.deinit();
    return duplicateImportGraph(allocator, parsed.value);
}

fn duplicateImportGraph(
    allocator: std.mem.Allocator,
    src: export_import.DefinitionGraph,
) error{OutOfMemory}!export_import.DefinitionGraph {
    const nodes = try allocator.alloc(export_import.DefinitionGraph.nodes.child, src.nodes.len);
    errdefer allocator.free(nodes);

    for (src.nodes, 0..) |n, i| {
        nodes[i] = .{
            .id = try allocator.dupe(u8, n.id),
            .node_type = n.node_type,
            .label = if (n.label) |l| try allocator.dupe(u8, l) else null,
            .attributes = if (n.attributes) |attr| try allocator.dupe(u8, attr) else null,
        };
    }

    const edges = try allocator.alloc(export_import.DefinitionGraph.edges.child, src.edges.len);
    errdefer allocator.free(edges);

    for (src.edges, 0..) |e, i| {
        edges[i] = .{
            .id = try allocator.dupe(u8, e.id),
            .source = try allocator.dupe(u8, e.source),
            .target = try allocator.dupe(u8, e.target),
            .condition = if (e.condition) |c| try allocator.dupe(u8, c) else null,
            .is_default = e.is_default,
        };
    }

    return export_import.DefinitionGraph{ .nodes = nodes, .edges = edges };
}

/// Extract a string value from a JSON object by key; returns null if absent or non-string.
fn jsonObjStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}
