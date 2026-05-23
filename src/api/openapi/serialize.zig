const std = @import("std");
const model = @import("model.zig");

pub fn toJson(
    allocator: std.mem.Allocator,
    doc: model.OpenApiDocument,
) error{OutOfMemory}![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendFieldName(allocator, &out, "openapi");
    try appendJsonString(allocator, &out, doc.openapi);
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "info");
    try out.append(allocator, '{');
    try appendFieldName(allocator, &out, "title");
    try appendJsonString(allocator, &out, doc.info_title);
    try out.append(allocator, ',');
    try appendFieldName(allocator, &out, "version");
    try appendJsonString(allocator, &out, doc.info_version);
    try out.append(allocator, ',');
    try appendFieldName(allocator, &out, "description");
    try appendJsonString(allocator, &out, doc.info_description);
    try out.append(allocator, '}');
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "servers");
    try out.append(allocator, '[');
    for (doc.server_urls, 0..) |url, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try appendFieldName(allocator, &out, "url");
        try appendJsonString(allocator, &out, url);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "paths");
    try appendPaths(allocator, &out, doc.endpoints);
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "components");
    try appendComponents(allocator, &out, doc.schemas, doc.responses);
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "security");
    try out.appendSlice(allocator, "[{\"BearerAuth\":[]}]");
    try out.append(allocator, ',');

    try appendFieldName(allocator, &out, "tags");
    try appendTags(allocator, &out, doc.endpoints);

    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendPaths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    endpoints: []const model.EndpointDescriptor,
) error{OutOfMemory}!void {
    try out.append(allocator, '{');

    var seen_paths = std.ArrayList([]const u8).empty;
    defer seen_paths.deinit(allocator);

    var wrote_path = false;
    for (endpoints) |endpoint| {
        if (containsPath(seen_paths.items, endpoint.path)) continue;
        try seen_paths.append(allocator, endpoint.path);

        if (wrote_path) try out.append(allocator, ',');
        wrote_path = true;

        try appendJsonString(allocator, out, endpoint.path);
        try out.append(allocator, ':');
        try out.append(allocator, '{');

        try appendPathOperation(allocator, out, endpoints, endpoint.path, .GET);
        try appendPathOperation(allocator, out, endpoints, endpoint.path, .POST);
        try appendPathOperation(allocator, out, endpoints, endpoint.path, .PUT);
        try appendPathOperation(allocator, out, endpoints, endpoint.path, .PATCH);
        try appendPathOperation(allocator, out, endpoints, endpoint.path, .DELETE);

        const last = out.items[out.items.len - 1];
        if (last == ',') _ = out.pop();

        try out.append(allocator, '}');
    }

    try out.append(allocator, '}');
}

fn appendPathOperation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    endpoints: []const model.EndpointDescriptor,
    path: []const u8,
    method: model.HttpMethod,
) error{OutOfMemory}!void {
    const endpoint = findEndpoint(endpoints, path, method) orelse return;

    try appendJsonString(allocator, out, methodName(method));
    try out.append(allocator, ':');
    try out.append(allocator, '{');

    try appendFieldName(allocator, out, "operationId");
    try appendJsonString(allocator, out, endpoint.operation_id);
    try out.append(allocator, ',');

    try appendFieldName(allocator, out, "summary");
    try appendJsonString(allocator, out, endpoint.summary);
    if (endpoint.description) |description| {
        try out.append(allocator, ',');
        try appendFieldName(allocator, out, "description");
        try appendJsonString(allocator, out, description);
    }
    try out.append(allocator, ',');

    try appendFieldName(allocator, out, "tags");
    try out.append(allocator, '[');
    try appendJsonString(allocator, out, endpoint.tag);
    try out.append(allocator, ']');
    try out.append(allocator, ',');

    if (endpoint.request_body_schema_ref) |schema_ref| {
        try appendFieldName(allocator, out, "requestBody");
        try out.append(allocator, '{');
        try appendFieldName(allocator, out, "required");
        try out.appendSlice(allocator, "true,");
        try appendFieldName(allocator, out, "content");
        try out.appendSlice(allocator, "{\"application/json\":{");
        try appendFieldName(allocator, out, "schema");
        try out.append(allocator, '{');
        try appendFieldName(allocator, out, "$ref");
        try appendRefString(allocator, out, "#/components/schemas/", schema_ref);
        try out.appendSlice(allocator, "}}}");
        try out.append(allocator, ',');
    }

    try appendFieldName(allocator, out, "responses");
    try out.append(allocator, '{');

    try appendJsonString(allocator, out, endpoint.success_status);
    try out.append(allocator, ':');
    try out.append(allocator, '{');
    try appendFieldName(allocator, out, "description");
    try appendJsonString(allocator, out, endpoint.success_description);
    if (endpoint.success_schema_ref) |schema_ref| {
        try out.append(allocator, ',');
        try appendFieldName(allocator, out, "content");
        try out.appendSlice(allocator, "{\"application/json\":{");
        try appendFieldName(allocator, out, "schema");
        try out.append(allocator, '{');
        try appendFieldName(allocator, out, "$ref");
        try appendRefString(allocator, out, "#/components/schemas/", schema_ref);
        try out.appendSlice(allocator, "}}}");
    }
    try out.append(allocator, '}');

    if (endpoint.include_standard_errors) {
        try appendErrorResponseRef(allocator, out, "400", "Error400");
        try appendErrorResponseRef(allocator, out, "401", "Error401");
        try appendErrorResponseRef(allocator, out, "403", "Error403");
        try appendErrorResponseRef(allocator, out, "404", "Error404");
        try appendErrorResponseRef(allocator, out, "409", "Error409");
        try appendErrorResponseRef(allocator, out, "415", "Error415");
        try appendErrorResponseRef(allocator, out, "422", "Error422");
        try appendErrorResponseRef(allocator, out, "429", "Error429");
        try appendErrorResponseRef(allocator, out, "500", "Error500");
        try appendErrorResponseRef(allocator, out, "503", "Error503");
    }

    try out.append(allocator, '}');
    try out.append(allocator, ',');

    try appendFieldName(allocator, out, "security");
    if (endpoint.auth_required) {
        try out.appendSlice(allocator, "[{\"BearerAuth\":[]}]");
    } else {
        try out.appendSlice(allocator, "[]");
    }

    try out.append(allocator, '}');
    try out.append(allocator, ',');
}

fn appendComponents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    schemas: []const model.SchemaComponent,
    responses: []const model.ResponseComponent,
) error{OutOfMemory}!void {
    try out.append(allocator, '{');

    try appendFieldName(allocator, out, "schemas");
    try out.append(allocator, '{');
    for (schemas, 0..) |schema, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, schema.name);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, schema.schema_json);
    }
    try out.append(allocator, '}');
    try out.append(allocator, ',');

    try appendFieldName(allocator, out, "responses");
    try out.append(allocator, '{');
    for (responses, 0..) |response, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, response.name);
        try out.append(allocator, ':');
        try out.append(allocator, '{');
        try appendFieldName(allocator, out, "description");
        try appendJsonString(allocator, out, response.description);
        if (response.schema_ref) |schema_ref| {
            try out.append(allocator, ',');
            try appendFieldName(allocator, out, "content");
            try out.appendSlice(allocator, "{\"application/problem+json\":{");
            try appendFieldName(allocator, out, "schema");
            try out.append(allocator, '{');
            try appendFieldName(allocator, out, "$ref");
            try appendRefString(allocator, out, "#/components/schemas/", schema_ref);
            try out.appendSlice(allocator, "}}}");
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, '}');
    try out.append(allocator, ',');

    try appendFieldName(allocator, out, "securitySchemes");
    try out.appendSlice(
        allocator,
        "{\"BearerAuth\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}}",
    );

    try out.append(allocator, '}');
}

fn appendTags(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    endpoints: []const model.EndpointDescriptor,
) error{OutOfMemory}!void {
    try out.append(allocator, '[');

    var seen = std.ArrayList([]const u8).empty;
    defer seen.deinit(allocator);

    var wrote = false;
    for (endpoints) |endpoint| {
        if (containsPath(seen.items, endpoint.tag)) continue;
        try seen.append(allocator, endpoint.tag);
        if (wrote) try out.append(allocator, ',');
        wrote = true;
        try out.append(allocator, '{');
        try appendFieldName(allocator, out, "name");
        try appendJsonString(allocator, out, endpoint.tag);
        try out.append(allocator, '}');
    }

    try out.append(allocator, ']');
}

fn appendErrorResponseRef(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    status_code: []const u8,
    response_name: []const u8,
) error{OutOfMemory}!void {
    try out.append(allocator, ',');
    try appendJsonString(allocator, out, status_code);
    try out.append(allocator, ':');
    try out.append(allocator, '{');
    try appendFieldName(allocator, out, "$ref");
    try appendRefString(allocator, out, "#/components/responses/", response_name);
    try out.append(allocator, '}');
}

fn appendFieldName(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
) error{OutOfMemory}!void {
    try appendJsonString(allocator, out, key);
    try out.append(allocator, ':');
}

fn appendRefString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    name: []const u8,
) error{OutOfMemory}!void {
    const value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
    defer allocator.free(value);
    try appendJsonString(allocator, out, value);
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) error{OutOfMemory}!void {
    const encoded = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = value },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(encoded);

    try out.appendSlice(allocator, encoded);
}

fn containsPath(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn findEndpoint(
    endpoints: []const model.EndpointDescriptor,
    path: []const u8,
    method: model.HttpMethod,
) ?model.EndpointDescriptor {
    for (endpoints) |endpoint| {
        if (std.mem.eql(u8, endpoint.path, path) and endpoint.method == method) {
            return endpoint;
        }
    }
    return null;
}

fn methodName(method: model.HttpMethod) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
    };
}
