const std = @import("std");
const errors = @import("../errors.zig");
const response = @import("../response.zig");
const scenario_runner = @import("../../simulation/scenario_runner.zig");

pub const HandlerResult = response.HandlerResult;

pub fn handleValidateScenario(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
    user_id: ?[]const u8,
    tenant_id: ?[]const u8,
    permissions_header: ?[]const u8,
    body: []const u8,
) HandlerResult {
    const actor = authenticate(allocator, authorization, user_id, tenant_id, permissions_header, "simulation:validate") catch |err| {
        return switch (err) {
            error.Unauthorized => response.problemResponse(allocator, errors.problemUnauthorized("Bearer token required")),
            error.Forbidden => response.problemResponse(allocator, errors.problemForbidden("missing permission: simulation:validate")),
            error.OutOfMemory => response.problemResponse(allocator, errors.problemInternalError("out of memory")),
        };
    };
    defer actor.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return response.problemResponse(allocator, errors.problemBadRequest("malformed_json"));
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return response.problemResponse(allocator, errors.problemUnprocessable("request body must be an object"));
    }

    const schema_name, const schema_version = extractSchemaRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("schema.name and schema.version are required"));
    };
    const definition_id, const definition_version = extractDefinitionRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("definitionRef.definitionId and definitionRef.version are required"));
    };

    var report = scenario_runner.validateScenarioSubmissionDetailed(allocator, .{
        .actor_user_id = actor.user_id,
        .actor_tenant_id = actor.tenant_id,
        .actor_permissions = actor.permissions,
        .schema_name = schema_name,
        .schema_version = schema_version,
        .definition_id = definition_id,
        .definition_version = definition_version,
        .scenario_payload_json = body,
    }) catch |err| {
        return mapValidationError(allocator, err);
    };
    defer report.deinit(allocator);

    if (!report.valid) {
        return validationFailureResult(allocator, report.issues);
    }

    const ok_body = std.fmt.allocPrint(
        allocator,
        "{{\"valid\":true,\"errors\":[]}}",
        .{},
    ) catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    return response.ok(ok_body);
}

pub fn handleRunScenario(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
    user_id: ?[]const u8,
    tenant_id: ?[]const u8,
    permissions_header: ?[]const u8,
    body: []const u8,
) HandlerResult {
    const actor = authenticate(allocator, authorization, user_id, tenant_id, permissions_header, "simulation:run") catch |err| {
        return switch (err) {
            error.Unauthorized => response.problemResponse(allocator, errors.problemUnauthorized("Bearer token required")),
            error.Forbidden => response.problemResponse(allocator, errors.problemForbidden("missing permission: simulation:run")),
            error.OutOfMemory => response.problemResponse(allocator, errors.problemInternalError("out of memory")),
        };
    };
    defer actor.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return response.problemResponse(allocator, errors.problemBadRequest("malformed_json"));
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return response.problemResponse(allocator, errors.problemUnprocessable("request body must be an object"));
    }

    const schema_name, const schema_version = extractSchemaRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("schema.name and schema.version are required"));
    };
    const definition_id, const definition_version = extractDefinitionRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("definitionRef.definitionId and definitionRef.version are required"));
    };

    const result = scenario_runner.runScenario(allocator, .{
        .actor_user_id = actor.user_id,
        .actor_tenant_id = actor.tenant_id,
        .actor_permissions = actor.permissions,
        .schema_name = schema_name,
        .schema_version = schema_version,
        .definition_id = definition_id,
        .definition_version = definition_version,
        .scenario_payload_json = body,
    }) catch |err| {
        if (err == scenario_runner.ScenarioSchemaError.ScenarioValidationFailed) {
            var report = scenario_runner.validateScenarioSubmissionDetailed(allocator, .{
                .actor_user_id = actor.user_id,
                .actor_tenant_id = actor.tenant_id,
                .actor_permissions = actor.permissions,
                .schema_name = schema_name,
                .schema_version = schema_version,
                .definition_id = definition_id,
                .definition_version = definition_version,
                .scenario_payload_json = body,
            }) catch return mapValidationError(allocator, err);
            defer report.deinit(allocator);
            return validationFailureResult(allocator, report.issues);
        }
        return mapRunError(allocator, err);
    };
    defer result.deinit(allocator);

    const json = serializeScenarioRunResult(allocator, result) catch {
        return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    };
    return response.ok(json);
}

pub fn handleRunBatch(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
    user_id: ?[]const u8,
    tenant_id: ?[]const u8,
    permissions_header: ?[]const u8,
    body: []const u8,
) HandlerResult {
    const actor = authenticate(allocator, authorization, user_id, tenant_id, permissions_header, "simulation:run_batch") catch |err| {
        return switch (err) {
            error.Unauthorized => response.problemResponse(allocator, errors.problemUnauthorized("Bearer token required")),
            error.Forbidden => response.problemResponse(allocator, errors.problemForbidden("missing permission: simulation:run_batch")),
            error.OutOfMemory => response.problemResponse(allocator, errors.problemInternalError("out of memory")),
        };
    };
    defer actor.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return response.problemResponse(allocator, errors.problemBadRequest("malformed_json"));
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return response.problemResponse(allocator, errors.problemUnprocessable("request body must be an object"));
    }

    const schema_name, const schema_version = extractSchemaRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("schema.name and schema.version are required"));
    };
    const definition_id, const definition_version = extractDefinitionRef(parsed.value.object) catch {
        return response.problemResponse(allocator, errors.problemUnprocessable("definitionRef.definitionId and definitionRef.version are required"));
    };

    const scenarios_value = parsed.value.object.get("scenarios") orelse {
        return response.problemResponse(allocator, errors.problemUnprocessable("scenarios is required"));
    };
    if (scenarios_value != .array) {
        return response.problemResponse(allocator, errors.problemUnprocessable("scenarios must be an array"));
    }

    const parallelism = blk: {
        const parallelism_obj = parsed.value.object.get("parallelism") orelse break :blk @as(u16, 1);
        if (parallelism_obj != .object) {
            return response.problemResponse(allocator, errors.problemUnprocessable("parallelism must be an object"));
        }
        const per_tenant = parallelism_obj.object.get("perTenant") orelse break :blk @as(u16, 1);
        if (per_tenant == .integer) {
            if (per_tenant.integer <= 0 or per_tenant.integer > std.math.maxInt(u16)) {
                return response.problemResponse(allocator, errors.problemUnprocessable("parallelism.perTenant out of range"));
            }
            break :blk @as(u16, @intCast(per_tenant.integer));
        }
        return response.problemResponse(allocator, errors.problemUnprocessable("parallelism.perTenant must be an integer"));
    };

    const scenarios_json = jsonStringifyAlloc(allocator, scenarios_value) catch {
        return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    };
    defer allocator.free(scenarios_json);

    const batch_result = scenario_runner.runScenarioBatch(allocator, .{
        .actor_user_id = actor.user_id,
        .actor_tenant_id = actor.tenant_id,
        .actor_permissions = actor.permissions,
        .schema_name = schema_name,
        .schema_version = schema_version,
        .definition_id = definition_id,
        .definition_version = definition_version,
        .scenarios_json = scenarios_json,
        .tenant_parallelism = parallelism,
    }) catch |err| {
        return mapRunError(allocator, err);
    };
    defer batch_result.deinit(allocator);

    const json = serializeBatchRunResult(allocator, batch_result) catch {
        return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    };
    return response.ok(json);
}

pub fn handleGetSchema(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
    user_id: ?[]const u8,
    tenant_id: ?[]const u8,
    permissions_header: ?[]const u8,
    name: []const u8,
    version: []const u8,
) HandlerResult {
    const actor = authenticate(allocator, authorization, user_id, tenant_id, permissions_header, "simulation:schema_read") catch |err| {
        return switch (err) {
            error.Unauthorized => response.problemResponse(allocator, errors.problemUnauthorized("Bearer token required")),
            error.Forbidden => response.problemResponse(allocator, errors.problemForbidden("missing permission: simulation:schema_read")),
            error.OutOfMemory => response.problemResponse(allocator, errors.problemInternalError("out of memory")),
        };
    };
    defer actor.deinit(allocator);

    const schema = scenario_runner.schemaDocument(name, version) orelse {
        return response.problemResponse(allocator, errors.problemNotFound("schema not found"));
    };

    const body = allocator.dupe(u8, schema) catch {
        return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    };
    return response.ok(body);
}

const RequestActor = struct {
    user_id: []const u8,
    tenant_id: []const u8,
    permissions: []const []const u8,

    pub fn deinit(self: RequestActor, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.tenant_id);
        for (self.permissions) |permission| allocator.free(permission);
        allocator.free(self.permissions);
    }
};

fn authenticate(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
    user_id: ?[]const u8,
    tenant_id: ?[]const u8,
    permissions_header: ?[]const u8,
    required_permission: []const u8,
) error{ Unauthorized, Forbidden, OutOfMemory }!RequestActor {
    const auth_header = authorization orelse return error.Unauthorized;
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) return error.Unauthorized;
    if (auth_header.len <= "Bearer ".len) return error.Unauthorized;

    const actor_user_id = user_id orelse return error.Unauthorized;
    const actor_tenant_id = tenant_id orelse return error.Unauthorized;

    const permissions = try parsePermissions(allocator, permissions_header);
    errdefer {
        for (permissions) |permission| allocator.free(permission);
        allocator.free(permissions);
    }

    var has_required = false;
    for (permissions) |permission| {
        if (std.mem.eql(u8, permission, required_permission)) {
            has_required = true;
            break;
        }
    }
    if (!has_required) return error.Forbidden;

    return .{
        .user_id = try allocator.dupe(u8, actor_user_id),
        .tenant_id = try allocator.dupe(u8, actor_tenant_id),
        .permissions = permissions,
    };
}

fn parsePermissions(allocator: std.mem.Allocator, header: ?[]const u8) ![]const []const u8 {
    const raw = header orelse return allocator.alloc([]const u8, 0);

    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(allocator);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        try items.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return items.toOwnedSlice(allocator);
}

fn extractSchemaRef(root: std.json.ObjectMap) error{InvalidInput}!struct { []const u8, []const u8 } {
    const schema = root.get("schema") orelse return error.InvalidInput;
    if (schema != .object) return error.InvalidInput;

    const name = schema.object.get("name") orelse return error.InvalidInput;
    const version = schema.object.get("version") orelse return error.InvalidInput;
    if (name != .string or version != .string) return error.InvalidInput;

    return .{ name.string, version.string };
}

fn extractDefinitionRef(root: std.json.ObjectMap) error{InvalidInput}!struct { []const u8, []const u8 } {
    const definition = root.get("definitionRef") orelse return error.InvalidInput;
    if (definition != .object) return error.InvalidInput;

    const id = definition.object.get("definitionId") orelse return error.InvalidInput;
    const version = definition.object.get("version") orelse return error.InvalidInput;
    if (id != .string or version != .string) return error.InvalidInput;

    return .{ id.string, version.string };
}

fn validationFailureResult(allocator: std.mem.Allocator, issues: []const scenario_runner.ValidationIssue) HandlerResult {
    var issues_json: std.ArrayList(u8) = .empty;
    defer issues_json.deinit(allocator);

    issues_json.appendSlice(allocator, "[") catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    for (issues, 0..) |issue, idx| {
        if (idx > 0) {
            issues_json.appendSlice(allocator, ",") catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
        }
        const item = std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"message\":\"{s}\"}}",
            .{ issue.path, issue.message },
        ) catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
        defer allocator.free(item);
        issues_json.appendSlice(allocator, item) catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));
    }
    issues_json.appendSlice(allocator, "]") catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"https://bpm.example.com/problems/unprocessable-entity\",\"title\":\"Unprocessable Entity\",\"status\":422,\"detail\":\"scenario validation failed\",\"errors\":{s}}}",
        .{issues_json.items},
    ) catch return response.problemResponse(allocator, errors.problemInternalError("serialization_failed"));

    return .{ .status_code = 422, .body = body };
}

fn mapValidationError(allocator: std.mem.Allocator, err: anyerror) HandlerResult {
    return switch (err) {
        scenario_runner.ScenarioSchemaError.SchemaNotFound => response.problemResponse(allocator, errors.problemNotFound("schema not found")),
        scenario_runner.ScenarioSchemaError.UnsupportedSchemaVersion => response.problemResponse(allocator, errors.problemUnprocessable("unsupported schema version")),
        scenario_runner.ScenarioSchemaError.InvalidScenarioPayload => response.problemResponse(allocator, errors.problemBadRequest("invalid scenario payload")),
        scenario_runner.ScenarioSchemaError.ScenarioValidationFailed => response.problemResponse(allocator, errors.problemUnprocessable("scenario validation failed")),
        else => response.problemResponse(allocator, errors.problemInternalError("internal_error")),
    };
}

fn mapRunError(allocator: std.mem.Allocator, err: anyerror) HandlerResult {
    return switch (err) {
        scenario_runner.RunnerError.Unauthorized => response.problemResponse(allocator, errors.problemUnauthorized("unauthorized")),
        scenario_runner.RunnerError.Forbidden => response.problemResponse(allocator, errors.problemForbidden("forbidden")),
        scenario_runner.RunnerError.TenantAccessDenied => response.problemResponse(allocator, errors.problemNotFound("resource not found")),
        scenario_runner.RunnerError.DefinitionNotFound => response.problemResponse(allocator, errors.problemNotFound("definition not found")),
        scenario_runner.RunnerError.DefinitionVersionNotFound => response.problemResponse(allocator, errors.problemNotFound("definition version not found")),
        scenario_runner.RunnerError.InvalidParallelism => response.problemResponse(allocator, errors.problemUnprocessable("invalid parallelism")),
        scenario_runner.ScenarioSchemaError.SchemaNotFound => response.problemResponse(allocator, errors.problemNotFound("schema not found")),
        scenario_runner.ScenarioSchemaError.UnsupportedSchemaVersion => response.problemResponse(allocator, errors.problemUnprocessable("unsupported schema version")),
        scenario_runner.ScenarioSchemaError.ScenarioValidationFailed => response.problemResponse(allocator, errors.problemUnprocessable("scenario validation failed")),
        scenario_runner.ScenarioSchemaError.InvalidScenarioPayload => response.problemResponse(allocator, errors.problemBadRequest("invalid scenario payload")),
        scenario_runner.AssertionError.UnknownAssertionType => response.problemResponse(allocator, errors.problemUnprocessable("unknown assertion type")),
        scenario_runner.AssertionError.AssertionEvaluationFailed => response.problemResponse(allocator, errors.problemUnprocessable("assertion evaluation failed")),
        else => response.problemResponse(allocator, errors.problemInternalError("internal_error")),
    };
}

fn serializeScenarioRunResult(allocator: std.mem.Allocator, result: scenario_runner.ScenarioRunResult) ![]const u8 {
    var assertion_json: std.ArrayList(u8) = .empty;
    defer assertion_json.deinit(allocator);
    try assertion_json.appendSlice(allocator, "[");
    for (result.assertion_results, 0..) |assertion, idx| {
        if (idx > 0) try assertion_json.appendSlice(allocator, ",");
        const item = try std.fmt.allocPrint(
            allocator,
            "{{\"assertionId\":\"{s}\",\"assertionType\":\"{s}\",\"passed\":{s},\"expected\":{s},\"actual\":{s}}}",
            .{ assertion.assertion_id, assertion.assertion_type, if (assertion.passed) "true" else "false", assertion.expected_json, assertion.actual_json },
        );
        defer allocator.free(item);
        try assertion_json.appendSlice(allocator, item);
    }
    try assertion_json.appendSlice(allocator, "]");

    var trace_json: std.ArrayList(u8) = .empty;
    defer trace_json.deinit(allocator);
    try trace_json.appendSlice(allocator, "[");
    for (result.event_trace, 0..) |entry, idx| {
        if (idx > 0) try trace_json.appendSlice(allocator, ",");
        const item = try std.fmt.allocPrint(
            allocator,
            "{{\"eventType\":\"{s}\",\"payload\":{s}}}",
            .{ entry.event_type, entry.payload_json },
        );
        defer allocator.free(item);
        try trace_json.appendSlice(allocator, item);
    }
    try trace_json.appendSlice(allocator, "]");

    return std.fmt.allocPrint(
        allocator,
        "{{\"runId\":\"{s}\",\"passed\":{s},\"elapsedMs\":{d},\"assertionResults\":{s},\"eventTrace\":{s}}}",
        .{ result.run_id, if (result.passed) "true" else "false", result.elapsed_ms, assertion_json.items, trace_json.items },
    );
}

fn serializeBatchRunResult(allocator: std.mem.Allocator, result: scenario_runner.BatchRunResult) ![]const u8 {
    var scenarios: std.ArrayList(u8) = .empty;
    defer scenarios.deinit(allocator);

    try scenarios.appendSlice(allocator, "[");
    for (result.scenario_results, 0..) |run, idx| {
        if (idx > 0) try scenarios.appendSlice(allocator, ",");
        const run_json = try serializeScenarioRunResult(allocator, run);
        defer allocator.free(run_json);
        try scenarios.appendSlice(allocator, run_json);
    }
    try scenarios.appendSlice(allocator, "]");

    return std.fmt.allocPrint(
        allocator,
        "{{\"batchRunId\":\"{s}\",\"total\":{d},\"passed\":{d},\"failed\":{d},\"elapsedMs\":{d},\"scenarioResults\":{s}}}",
        .{ result.batch_run_id, result.total, result.passed, result.failed, result.elapsed_ms, scenarios.items },
    );
}

test "handleGetSchema returns schema for supported version" {
    const result = handleGetSchema(
        std.testing.allocator,
        "Bearer test-token",
        "user-1",
        "tenant-1",
        "simulation:schema_read",
        "simulation-scenario",
        "1.0",
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
}

test "handleValidateScenario rejects missing bearer token" {
    const result = handleValidateScenario(
        std.testing.allocator,
        null,
        "user-1",
        "tenant-1",
        "simulation:validate",
        "{}",
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(@as(u16, 401), result.status_code);
}

fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}
