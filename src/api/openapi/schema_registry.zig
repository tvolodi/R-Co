const std = @import("std");
const model = @import("model.zig");

pub const ComponentSchemaId = enum {
    ProblemDetails,
    ValidationProblem,
    Definition,
    DefinitionList,
    DefinitionCreateRequest,
    DefinitionImportRequest,
    InstanceCreateRequest,
    InstanceSummary,
    InstanceList,
    Task,
    TaskList,
    TaskCompleteRequest,
    TaskAssignRequest,
    TaskReassignRequest,
    EventHistoryPage,
};

pub const SharedResponseId = enum {
    Error400,
    Error401,
    Error403,
    Error404,
    Error409,
    Error415,
    Error422,
    Error429,
    Error500,
    Error503,
};

pub const SchemaRegistryError = error{
    DuplicateSchema,
    DuplicateResponse,
};

pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    schemas: std.ArrayList(model.SchemaComponent),
    responses: std.ArrayList(model.ResponseComponent),

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .schemas = .empty,
            .responses = .empty,
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        self.schemas.deinit(self.allocator);
        self.responses.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerSchema(self: *SchemaRegistry, name: []const u8, schema_json: []const u8) (SchemaRegistryError || error{OutOfMemory})!void {
        for (self.schemas.items) |schema| {
            if (std.mem.eql(u8, schema.name, name)) return error.DuplicateSchema;
        }
        try self.schemas.append(self.allocator, .{ .name = name, .schema_json = schema_json });
    }

    pub fn registerResponse(self: *SchemaRegistry, name: []const u8, description: []const u8, schema_ref: ?[]const u8) (SchemaRegistryError || error{OutOfMemory})!void {
        for (self.responses.items) |response| {
            if (std.mem.eql(u8, response.name, name)) return error.DuplicateResponse;
        }
        try self.responses.append(self.allocator, .{
            .name = name,
            .description = description,
            .schema_ref = schema_ref,
        });
    }

    pub fn registerStandardProblemSchemas(self: *SchemaRegistry) (SchemaRegistryError || error{OutOfMemory})!void {
        try self.registerSchema(
            "ProblemDetails",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"type\",\"title\",\"status\",\"detail\",\"trace_id\"]," ++
                "\"properties\":{" ++
                "\"type\":{\"type\":\"string\",\"format\":\"uri\"}," ++
                "\"title\":{\"type\":\"string\"}," ++
                "\"status\":{\"type\":\"integer\"}," ++
                "\"detail\":{\"type\":\"string\"}," ++
                "\"trace_id\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "ValidationProblem",
            "{" ++
                "\"allOf\":[{" ++
                "\"$ref\":\"#/components/schemas/ProblemDetails\"" ++
                "}]," ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"violations\":{" ++
                "\"type\":\"array\"," ++
                "\"items\":{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"field\":{\"type\":\"string\"}," ++
                "\"message\":{\"type\":\"string\"}" ++
                "}" ++
                "}" ++
                "}" ++
                "}" ++
                "}",
        );
    }

    pub fn registerStandardProblemResponses(self: *SchemaRegistry) (SchemaRegistryError || error{OutOfMemory})!void {
        try self.registerResponse("Error400", "Bad Request", "ProblemDetails");
        try self.registerResponse("Error401", "Unauthorized", "ProblemDetails");
        try self.registerResponse("Error403", "Forbidden", "ProblemDetails");
        try self.registerResponse("Error404", "Not Found", "ProblemDetails");
        try self.registerResponse("Error409", "Conflict", "ProblemDetails");
        try self.registerResponse("Error415", "Unsupported Media Type", "ProblemDetails");
        try self.registerResponse("Error422", "Unprocessable Entity", "ValidationProblem");
        try self.registerResponse("Error429", "Too Many Requests", "ProblemDetails");
        try self.registerResponse("Error500", "Internal Server Error", "ProblemDetails");
        try self.registerResponse("Error503", "Service Unavailable", "ProblemDetails");
    }

    pub fn registerDomainSchemas(self: *SchemaRegistry) (SchemaRegistryError || error{OutOfMemory})!void {
        try self.registerSchema(
            "Definition",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"definition_id\":{\"type\":\"string\",\"format\":\"uuid\"}," ++
                "\"name\":{\"type\":\"string\"}," ++
                "\"version\":{\"type\":\"string\"}," ++
                "\"status\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "DefinitionList",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"items\":{" ++
                "\"type\":\"array\"," ++
                "\"items\":{\"$ref\":\"#/components/schemas/Definition\"}" ++
                "}," ++
                "\"cursor\":{\"type\":[\"string\",\"null\"]}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "DefinitionCreateRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"name\",\"version\",\"graph\"]," ++
                "\"properties\":{" ++
                "\"name\":{\"type\":\"string\"}," ++
                "\"version\":{\"type\":\"string\"}," ++
                "\"description\":{\"type\":[\"string\",\"null\"]}," ++
                "\"graph\":{\"type\":\"object\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "DefinitionImportRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"definition\"]," ++
                "\"properties\":{" ++
                "\"definition\":{\"type\":\"object\"}" ++
                "}" ++
                "}",
        );

        try self.registerSchema(
            "InstanceCreateRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"definition_id\",\"initial_variables\"]," ++
                "\"properties\":{" ++
                "\"definition_id\":{\"type\":\"string\",\"format\":\"uuid\"}," ++
                "\"correlation_key\":{\"type\":[\"string\",\"null\"]}," ++
                "\"initial_variables\":{\"type\":\"object\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "InstanceSummary",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"instance_id\":{\"type\":\"string\",\"format\":\"uuid\"}," ++
                "\"status\":{\"type\":\"string\"}," ++
                "\"created_at\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "InstanceList",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"items\":{" ++
                "\"type\":\"array\"," ++
                "\"items\":{\"$ref\":\"#/components/schemas/InstanceSummary\"}" ++
                "}," ++
                "\"next_cursor\":{\"type\":[\"string\",\"null\"]}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "EventHistoryPage",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}}," ++
                "\"next_cursor\":{\"type\":[\"string\",\"null\"]}" ++
                "}" ++
                "}",
        );

        try self.registerSchema(
            "Task",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"task_id\":{\"type\":\"string\",\"format\":\"uuid\"}," ++
                "\"instance_id\":{\"type\":\"string\",\"format\":\"uuid\"}," ++
                "\"status\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "TaskList",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"items\":{" ++
                "\"type\":\"array\"," ++
                "\"items\":{\"$ref\":\"#/components/schemas/Task\"}" ++
                "}," ++
                "\"next_cursor\":{\"type\":[\"string\",\"null\"]}," ++
                "\"count\":{\"type\":\"integer\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "TaskCompleteRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"properties\":{" ++
                "\"output_variables\":{\"type\":\"object\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "TaskAssignRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"assignee_type\",\"assignee_ref\"]," ++
                "\"properties\":{" ++
                "\"assignee_type\":{\"type\":\"string\"}," ++
                "\"assignee_ref\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
        try self.registerSchema(
            "TaskReassignRequest",
            "{" ++
                "\"type\":\"object\"," ++
                "\"required\":[\"assignee_type\",\"assignee_ref\"]," ++
                "\"properties\":{" ++
                "\"assignee_type\":{\"type\":\"string\"}," ++
                "\"assignee_ref\":{\"type\":\"string\"}" ++
                "}" ++
                "}",
        );
    }

    pub fn toOwnedSchemas(self: *SchemaRegistry, allocator: std.mem.Allocator) error{OutOfMemory}![]model.SchemaComponent {
        return try allocator.dupe(model.SchemaComponent, self.schemas.items);
    }

    pub fn toOwnedResponses(self: *SchemaRegistry, allocator: std.mem.Allocator) error{OutOfMemory}![]model.ResponseComponent {
        return try allocator.dupe(model.ResponseComponent, self.responses.items);
    }
};
