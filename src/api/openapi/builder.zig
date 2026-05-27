const std = @import("std");
const model = @import("model.zig");
const path_registry = @import("path_registry.zig");
const schema_registry = @import("schema_registry.zig");
const version_source = @import("version_source.zig");

pub const BuildInput = struct {
    title: []const u8,
    description: []const u8,
    server_urls: []const []const u8,
    route_modules: []const model.RouteModuleDescriptor,
};

pub const OpenApiError = error{
    OutOfMemory,
    DuplicatePathOperation,
    DuplicateSchema,
    DuplicateResponse,
};

pub fn buildOpenApiDocument(
    allocator: std.mem.Allocator,
    input: BuildInput,
) OpenApiError!model.OpenApiDocument {
    var paths = path_registry.PathRegistry.init(allocator);
    defer paths.deinit();

    var schemas = schema_registry.SchemaRegistry.init(allocator);
    defer schemas.deinit();

    for (input.route_modules) |module_desc| {
        paths.addModule(module_desc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicatePathOperation => return error.DuplicatePathOperation,
        };
    }

    schemas.registerStandardProblemSchemas() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateSchema => return error.DuplicateSchema,
        error.DuplicateResponse => return error.DuplicateResponse,
    };
    schemas.registerStandardProblemResponses() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateSchema => return error.DuplicateSchema,
        error.DuplicateResponse => return error.DuplicateResponse,
    };
    schemas.registerDomainSchemas() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateSchema => return error.DuplicateSchema,
        error.DuplicateResponse => return error.DuplicateResponse,
    };

    const info_version = version_source.platformVersion(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(info_version);

    const endpoints = paths.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(endpoints);

    const schema_components = schemas.toOwnedSchemas(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(schema_components);

    const response_components = schemas.toOwnedResponses(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(response_components);

    return .{
        .openapi = "3.1.0",
        .info_title = input.title,
        .info_description = input.description,
        .info_version = info_version,
        .server_urls = input.server_urls,
        .endpoints = endpoints,
        .schemas = schema_components,
        .responses = response_components,
    };
}

pub fn defaultBuildInput() BuildInput {
    return .{
        .title = "BPM Platform API",
        .description = "Code-generated OpenAPI description for BPM Platform endpoints.",
        .server_urls = &.{"/"},
        .route_modules = defaultRouteModules(),
    };
}

pub fn defaultRouteModules() []const model.RouteModuleDescriptor {
    return &route_modules;
}

const route_modules: [6]model.RouteModuleDescriptor = .{
    .{ .module_name = "definitions", .endpoints = &definitions_endpoints },
    .{ .module_name = "instances", .endpoints = &instances_endpoints },
    .{ .module_name = "tasks", .endpoints = &tasks_endpoints },
    .{ .module_name = "idp", .endpoints = &idp_endpoints },
    .{ .module_name = "health", .endpoints = &health_endpoints },
    .{ .module_name = "openapi", .endpoints = &openapi_endpoints },
};

const definitions_endpoints: [13]model.EndpointDescriptor = .{
    endpoint(.GET, "/api/v1/definitions", "listDefinitions", "List definitions", "definitions", true, null, "200", "Definition list", "DefinitionList"),
    endpoint(.GET, "/api/v1/definitions/{id}", "getDefinitionById", "Get definition by id", "definitions", true, null, "200", "Definition", "Definition"),
    endpoint(.GET, "/api/v1/definitions/active/{name}", "getActiveDefinitionByName", "Get active definition by name", "definitions", true, null, "200", "Definition", "Definition"),
    endpoint(.GET, "/api/v1/definitions/search", "searchDefinitions", "Search definitions", "definitions", true, null, "200", "Definition list", "DefinitionList"),
    endpoint(.POST, "/api/v1/definitions", "createDefinition", "Create definition", "definitions", true, "DefinitionCreateRequest", "201", "Created definition", "Definition"),
    endpoint(.PUT, "/api/v1/definitions/{id}", "replaceDefinition", "Replace definition", "definitions", true, "DefinitionCreateRequest", "200", "Updated definition", "Definition"),
    endpoint(.PATCH, "/api/v1/definitions/{id}", "patchDefinition", "Patch definition", "definitions", true, "DefinitionCreateRequest", "200", "Updated definition", "Definition"),
    endpoint(.DELETE, "/api/v1/definitions/{id}", "deleteDefinition", "Delete definition", "definitions", true, null, "204", "No content", null),
    endpoint(.POST, "/api/v1/definitions/{id}/activate", "activateDefinition", "Activate definition", "definitions", true, null, "200", "Updated definition", "Definition"),
    endpoint(.POST, "/api/v1/definitions/{id}/deprecate", "deprecateDefinition", "Deprecate definition", "definitions", true, null, "200", "Updated definition", "Definition"),
    endpoint(.POST, "/api/v1/definitions/{id}/archive", "archiveDefinition", "Archive definition", "definitions", true, null, "200", "Updated definition", "Definition"),
    endpoint(.GET, "/api/v1/definitions/{id}/export", "exportDefinition", "Export definition", "definitions", true, null, "200", "Exported definition", "Definition"),
    endpoint(.POST, "/api/v1/definitions/import", "importDefinition", "Import definition", "definitions", true, "DefinitionImportRequest", "201", "Imported definition", "Definition"),
};

const instances_endpoints: [7]model.EndpointDescriptor = .{
    endpoint(.POST, "/api/v1/instances", "createInstance", "Create instance", "instances", true, "InstanceCreateRequest", "201", "Created instance", "InstanceSummary"),
    endpoint(.GET, "/api/v1/instances", "listInstances", "List instances", "instances", true, null, "200", "Instance list", "InstanceList"),
    endpoint(.GET, "/api/v1/instances/{id}", "getInstanceById", "Get instance by id", "instances", true, null, "200", "Instance", "InstanceSummary"),
    endpoint(.GET, "/api/v1/instances/{id}/history", "getInstanceHistory", "Get instance event history", "instances", true, null, "200", "Event history page", "EventHistoryPage"),
    endpoint(.GET, "/api/v1/instances/{id}/timeline", "getInstanceTimeline", "Get instance timeline", "instances", true, null, "200", "Instance timeline page", "EventHistoryPage"),
    endpoint(.POST, "/api/v1/instances/{id}/cancel", "cancelInstance", "Cancel instance", "instances", true, null, "200", "Instance cancelled", "InstanceSummary"),
    endpoint(.POST, "/api/v1/instances/{id}/reconstruct", "reconstructInstance", "Reconstruct instance state", "instances", true, null, "200", "Reconstructed instance", "InstanceSummary"),
};

const tasks_endpoints: [5]model.EndpointDescriptor = .{
    endpoint(.GET, "/api/v1/tasks", "listTasks", "List tasks", "tasks", true, null, "200", "Task list", "TaskList"),
    endpoint(.GET, "/api/v1/tasks/{id}", "getTaskById", "Get task by id", "tasks", true, null, "200", "Task", "Task"),
    endpoint(.POST, "/api/v1/tasks/{id}/complete", "completeTask", "Complete task", "tasks", true, "TaskCompleteRequest", "200", "Task completion result", "Task"),
    endpoint(.POST, "/api/v1/tasks/{id}/assign", "assignTask", "Assign task", "tasks", true, "TaskAssignRequest", "200", "Task", "Task"),
    endpoint(.POST, "/api/v1/tasks/{id}/reassign", "reassignTask", "Reassign task", "tasks", true, "TaskReassignRequest", "200", "Task", "Task"),
};

const idp_endpoints: [22]model.EndpointDescriptor = .{
    endpoint(.POST, "/api/v1/idp/realms", "createIdpRealm", "Create identity realm", "idp", true, null, "201", "Realm created", null),
    endpoint(.GET, "/api/v1/idp/realms", "listIdpRealms", "List identity realms", "idp", true, null, "200", "Realm list", null),
    endpoint(.GET, "/api/v1/idp/realms/{realmId}", "getIdpRealm", "Get identity realm", "idp", true, null, "200", "Realm", null),
    endpoint(.PATCH, "/api/v1/idp/realms/{realmId}", "updateIdpRealm", "Update identity realm", "idp", true, null, "200", "Realm updated", null),
    endpoint(.DELETE, "/api/v1/idp/realms/{realmId}", "deleteIdpRealm", "Delete identity realm", "idp", true, null, "204", "Realm deleted", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/users", "createIdpUser", "Create user in realm", "idp", true, null, "201", "User created", null),
    endpoint(.GET, "/api/v1/idp/realms/{realmId}/users", "listIdpUsers", "List users in realm", "idp", true, null, "200", "User list", null),
    endpoint(.GET, "/api/v1/idp/realms/{realmId}/users/{userId}", "getIdpUser", "Get user in realm", "idp", true, null, "200", "User", null),
    endpoint(.PATCH, "/api/v1/idp/realms/{realmId}/users/{userId}", "updateIdpUser", "Update user in realm", "idp", true, null, "200", "User updated", null),
    endpoint(.DELETE, "/api/v1/idp/realms/{realmId}/users/{userId}", "deleteIdpUser", "Delete user in realm", "idp", true, null, "204", "User deleted", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/users/{userId}/roles:assign", "assignIdpRoles", "Assign user roles", "idp", true, null, "200", "Roles assigned", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/users/{userId}/roles:revoke", "revokeIdpRoles", "Revoke user roles", "idp", true, null, "200", "Roles revoked", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/clients", "createIdpClient", "Create OIDC client", "idp", true, null, "201", "Client created", null),
    endpoint(.GET, "/api/v1/idp/realms/{realmId}/clients", "listIdpClients", "List OIDC clients", "idp", true, null, "200", "Client list", null),
    endpoint(.PATCH, "/api/v1/idp/realms/{realmId}/clients/{clientId}", "updateIdpClient", "Update OIDC client", "idp", true, null, "200", "Client updated", null),
    endpoint(.DELETE, "/api/v1/idp/realms/{realmId}/clients/{clientId}", "deleteIdpClient", "Delete OIDC client", "idp", true, null, "204", "Client deleted", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/clients/{clientId}/secret:rotate", "rotateIdpClientSecret", "Rotate OIDC client secret", "idp", true, null, "200", "Secret rotated", null),
    endpoint(.POST, "/api/v1/idp/realms/{realmId}/federations", "createIdpFederation", "Create federation", "idp", true, null, "201", "Federation created", null),
    endpoint(.GET, "/api/v1/idp/realms/{realmId}/federations", "listIdpFederations", "List federations", "idp", true, null, "200", "Federation list", null),
    endpoint(.DELETE, "/api/v1/idp/realms/{realmId}/federations/{federationId}", "deleteIdpFederation", "Delete federation", "idp", true, null, "204", "Federation deleted", null),
    endpoint(.PUT, "/api/v1/idp/realms/{realmId}/federations/{federationId}/mapping", "upsertIdpFederationMapping", "Configure federation mapping", "idp", true, null, "200", "Mapping upserted", null),
    endpoint(.POST, "/api/v1/idp/provisioning:bundle", "provisionIdpBundle", "Provision realm/user/client/federation bundle", "idp", true, null, "200", "Bundle result", null),
};

const health_endpoints: [2]model.EndpointDescriptor = .{
    endpoint(.GET, "/health/live", "getHealthLive", "Liveness probe", "health", false, null, "200", "Service process is running", null),
    endpoint(.GET, "/health/ready", "getHealthReady", "Readiness probe", "health", false, null, "200", "Service is ready", null),
};

const openapi_endpoints: [1]model.EndpointDescriptor = .{
    endpoint(
        .GET,
        "/openapi.json",
        "getOpenApiDocument",
        "Get OpenAPI specification",
        "openapi",
        false,
        null,
        "200",
        "OpenAPI 3.1 document",
        null,
    ),
};

fn endpoint(
    method: model.HttpMethod,
    path: []const u8,
    operation_id: []const u8,
    summary: []const u8,
    tag: []const u8,
    auth_required: bool,
    request_body_schema_ref: ?[]const u8,
    success_status: []const u8,
    success_description: []const u8,
    success_schema_ref: ?[]const u8,
) model.EndpointDescriptor {
    return .{
        .method = method,
        .path = path,
        .operation_id = operation_id,
        .summary = summary,
        .tag = tag,
        .auth_required = auth_required,
        .request_body_schema_ref = request_body_schema_ref,
        .success_status = success_status,
        .success_description = success_description,
        .success_schema_ref = success_schema_ref,
        .include_standard_errors = true,
    };
}
