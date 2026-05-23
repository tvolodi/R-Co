const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

pub const EndpointDescriptor = struct {
    method: HttpMethod,
    path: []const u8,
    operation_id: []const u8,
    summary: []const u8,
    description: ?[]const u8 = null,
    tag: []const u8,
    auth_required: bool,
    request_body_schema_ref: ?[]const u8 = null,
    success_status: []const u8,
    success_description: []const u8,
    success_schema_ref: ?[]const u8 = null,
    include_standard_errors: bool = true,
};

pub const RouteModuleDescriptor = struct {
    module_name: []const u8,
    endpoints: []const EndpointDescriptor,
};

pub const SchemaComponent = struct {
    name: []const u8,
    schema_json: []const u8,
};

pub const ResponseComponent = struct {
    name: []const u8,
    description: []const u8,
    schema_ref: ?[]const u8,
};

pub const OpenApiDocument = struct {
    openapi: []const u8,
    info_title: []const u8,
    info_description: []const u8,
    info_version: []const u8,
    server_urls: []const []const u8,
    endpoints: []const EndpointDescriptor,
    schemas: []const SchemaComponent,
    responses: []const ResponseComponent,

    pub fn deinit(self: *OpenApiDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.info_version);
        allocator.free(self.endpoints);
        allocator.free(self.schemas);
        allocator.free(self.responses);
        self.* = undefined;
    }
};
