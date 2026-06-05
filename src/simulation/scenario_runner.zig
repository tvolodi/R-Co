const std = @import("std");

pub const ScenarioSchemaError = error{
    SchemaNotFound,
    UnsupportedSchemaVersion,
    ScenarioValidationFailed,
    InvalidScenarioPayload,
};

pub const AssertionError = error{
    UnknownAssertionType,
    AssertionEvaluationFailed,
    EventSequenceMismatch,
    FinalStateMismatch,
    ForbiddenEventObserved,
    TaskAssignmentMismatch,
};

pub const RunnerError = error{
    DefinitionNotFound,
    DefinitionVersionNotFound,
    Unauthorized,
    Forbidden,
    TenantAccessDenied,
    InvalidParallelism,
    SimulationExecutionFailed,
    Timeout,
};

pub const ValidationIssue = struct {
    path: []const u8,
    message: []const u8,
};

pub const ValidationReport = struct {
    valid: bool,
    issues: []ValidationIssue,

    pub fn deinit(self: ValidationReport, allocator: std.mem.Allocator) void {
        for (self.issues) |issue| {
            allocator.free(issue.path);
            allocator.free(issue.message);
        }
        allocator.free(self.issues);
    }
};

pub const ScenarioEventTraceEntry = struct {
    event_type: []const u8,
    payload_json: []const u8,

    pub fn deinit(self: ScenarioEventTraceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.payload_json);
    }
};

pub const AssertionResult = struct {
    assertion_id: []const u8,
    assertion_type: []const u8,
    passed: bool,
    expected_json: []const u8,
    actual_json: []const u8,

    pub fn deinit(self: AssertionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.assertion_id);
        allocator.free(self.assertion_type);
        allocator.free(self.expected_json);
        allocator.free(self.actual_json);
    }
};

pub const ScenarioRunResult = struct {
    run_id: []const u8,
    passed: bool,
    elapsed_ms: u64,
    assertion_results: []AssertionResult,
    event_trace: []ScenarioEventTraceEntry,

    pub fn deinit(self: ScenarioRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        for (self.assertion_results) |result| result.deinit(allocator);
        allocator.free(self.assertion_results);
        for (self.event_trace) |entry| entry.deinit(allocator);
        allocator.free(self.event_trace);
    }
};

pub const BatchRunResult = struct {
    batch_run_id: []const u8,
    total: u32,
    passed: u32,
    failed: u32,
    elapsed_ms: u64,
    scenario_results: []ScenarioRunResult,

    pub fn deinit(self: BatchRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.batch_run_id);
        for (self.scenario_results) |result| result.deinit(allocator);
        allocator.free(self.scenario_results);
    }
};

pub const ScenarioRunInput = struct {
    actor_user_id: []const u8,
    actor_realm_id: []const u8,
    actor_permissions: []const []const u8,
    schema_name: []const u8,
    schema_version: []const u8,
    definition_id: []const u8,
    definition_version: []const u8,
    scenario_payload_json: []const u8,
};

pub const BatchRunInput = struct {
    actor_user_id: []const u8,
    actor_realm_id: []const u8,
    actor_permissions: []const []const u8,
    schema_name: []const u8,
    schema_version: []const u8,
    definition_id: []const u8,
    definition_version: []const u8,
    scenarios_json: []const u8,
    tenant_parallelism: u16,
};

const SCHEMA_NAME = "simulation-scenario";
const SCHEMA_VERSION = "1.0";

pub const SCENARIO_SCHEMA_JSON =
    \\{
    \\  "$id": "simulation-scenario/1.0",
    \\  "type": "object",
    \\  "required": ["schema", "definitionRef", "initialVariables", "actions", "mocks", "assertions"],
    \\  "properties": {
    \\    "schema": {
    \\      "type": "object",
    \\      "required": ["name", "version"],
    \\      "properties": {
    \\        "name": { "type": "string" },
    \\        "version": { "type": "string" }
    \\      }
    \\    },
    \\    "definitionRef": {
    \\      "type": "object",
    \\      "required": ["definitionId", "version"],
    \\      "properties": {
    \\        "definitionId": { "type": "string" },
    \\        "version": { "type": "string" },
    \\        "tenantId": { "type": "string" }
    \\      }
    \\    },
    \\    "initialVariables": { "type": "object" },
    \\    "actions": { "type": "array" },
    \\    "mocks": { "type": "array" },
    \\    "assertions": { "type": "array" }
    \\  }
    \\}
;

pub fn schemaSupported(name: []const u8, version: []const u8) bool {
    return std.mem.eql(u8, name, SCHEMA_NAME) and std.mem.eql(u8, version, SCHEMA_VERSION);
}

pub fn schemaDocument(name: []const u8, version: []const u8) ?[]const u8 {
    if (!schemaSupported(name, version)) return null;
    return SCENARIO_SCHEMA_JSON;
}

pub fn validateScenarioSubmission(
    allocator: std.mem.Allocator,
    submission: ScenarioRunInput,
) (ScenarioSchemaError || error{OutOfMemory})!void {
    var report = try validateScenarioSubmissionDetailed(allocator, submission);
    defer report.deinit(allocator);
    if (!report.valid) return error.ScenarioValidationFailed;
}

pub fn validateScenarioSubmissionDetailed(
    allocator: std.mem.Allocator,
    submission: ScenarioRunInput,
) (ScenarioSchemaError || error{OutOfMemory})!ValidationReport {
    var issues: std.ArrayList(ValidationIssue) = .empty;
    errdefer {
        for (issues.items) |issue| {
            allocator.free(issue.path);
            allocator.free(issue.message);
        }
        issues.deinit(allocator);
    }

    if (!schemaSupported(submission.schema_name, submission.schema_version)) {
        if (!std.mem.eql(u8, submission.schema_name, SCHEMA_NAME)) return error.SchemaNotFound;
        return error.UnsupportedSchemaVersion;
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        submission.scenario_payload_json,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidScenarioPayload;
    defer parsed.deinit();

    if (parsed.value != .object) {
        try appendIssue(&issues, allocator, "$/", "scenario payload must be a JSON object");
        return ValidationReport{ .valid = false, .issues = try issues.toOwnedSlice(allocator) };
    }

    const root = parsed.value.object;
    const schema_value = root.get("schema") orelse {
        try appendIssue(&issues, allocator, "$.schema", "missing required field");
        return ValidationReport{ .valid = false, .issues = try issues.toOwnedSlice(allocator) };
    };

    if (schema_value != .object) {
        try appendIssue(&issues, allocator, "$.schema", "schema must be an object");
    } else {
        const schema_name_value = schema_value.object.get("name");
        const schema_version_value = schema_value.object.get("version");

        if (schema_name_value == null) {
            try appendIssue(&issues, allocator, "$.schema.name", "missing required field");
        }
        if (schema_version_value == null) {
            try appendIssue(&issues, allocator, "$.schema.version", "missing required field");
        }

        if (schema_name_value) |value| {
            if (value != .string) {
                try appendIssue(&issues, allocator, "$.schema.name", "schema name must be a string");
            } else if (!std.mem.eql(u8, value.string, submission.schema_name)) {
                try appendIssue(&issues, allocator, "$.schema.name", "schema name mismatch with request");
            }
        }

        if (schema_version_value) |value| {
            if (value != .string) {
                try appendIssue(&issues, allocator, "$.schema.version", "schema version must be a string");
            } else if (!std.mem.eql(u8, value.string, submission.schema_version)) {
                try appendIssue(&issues, allocator, "$.schema.version", "schema version mismatch with request");
            }
        }
    }

    const definition_ref = root.get("definitionRef");
    if (definition_ref == null) {
        try appendIssue(&issues, allocator, "$.definitionRef", "missing required field");
    }
    if (definition_ref) |def_ref| {
        if (def_ref != .object) {
            try appendIssue(&issues, allocator, "$.definitionRef", "definitionRef must be an object");
        } else {
            const definition_id = def_ref.object.get("definitionId");
            const definition_version = def_ref.object.get("version");
            if (definition_id == null) {
                try appendIssue(&issues, allocator, "$.definitionRef.definitionId", "missing required field");
            }
            if (definition_version == null) {
                try appendIssue(&issues, allocator, "$.definitionRef.version", "missing required field");
            }
            if (definition_id) |value| {
                if (value != .string or value.string.len == 0) {
                    try appendIssue(&issues, allocator, "$.definitionRef.definitionId", "definitionId must be a non-empty string");
                }
            }
            if (definition_version) |value| {
                if (value != .string or value.string.len == 0) {
                    try appendIssue(&issues, allocator, "$.definitionRef.version", "version must be a non-empty string");
                }
            }
        }
    }

    const initial_variables = root.get("initialVariables");
    if (initial_variables == null) {
        try appendIssue(&issues, allocator, "$.initialVariables", "missing required field");
    }
    if (initial_variables) |value| {
        if (value != .object) {
            try appendIssue(&issues, allocator, "$.initialVariables", "initialVariables must be an object");
        }
    }

    try validateArrayField(&issues, allocator, root, "actions", "$.actions");
    try validateArrayField(&issues, allocator, root, "mocks", "$.mocks");

    const assertions = root.get("assertions");
    if (assertions == null) {
        try appendIssue(&issues, allocator, "$.assertions", "missing required field");
    }
    if (assertions) |value| {
        if (value != .array) {
            try appendIssue(&issues, allocator, "$.assertions", "assertions must be an array");
        } else if (value.array.items.len == 0) {
            try appendIssue(&issues, allocator, "$.assertions", "at least one assertion is required");
        } else {
            for (value.array.items, 0..) |assertion, idx| {
                if (assertion != .object) {
                    const path = try std.fmt.allocPrint(allocator, "$.assertions[{d}]", .{idx});
                    defer allocator.free(path);
                    try appendIssue(&issues, allocator, path, "assertion must be an object");
                    continue;
                }
                const id_value = assertion.object.get("id") orelse null;
                const type_value = assertion.object.get("type") orelse null;
                if (id_value == null or id_value.? != .string or id_value.?.string.len == 0) {
                    const path = try std.fmt.allocPrint(allocator, "$.assertions[{d}].id", .{idx});
                    defer allocator.free(path);
                    try appendIssue(&issues, allocator, path, "assertion id must be a non-empty string");
                }
                if (type_value == null or type_value.? != .string or type_value.?.string.len == 0) {
                    const path = try std.fmt.allocPrint(allocator, "$.assertions[{d}].type", .{idx});
                    defer allocator.free(path);
                    try appendIssue(&issues, allocator, path, "assertion type must be a non-empty string");
                }
            }
        }
    }

    return ValidationReport{
        .valid = issues.items.len == 0,
        .issues = try issues.toOwnedSlice(allocator),
    };
}

pub fn runScenario(
    allocator: std.mem.Allocator,
    input: ScenarioRunInput,
) (ScenarioSchemaError || AssertionError || RunnerError || error{OutOfMemory})!ScenarioRunResult {
    if (!hasPermission(input.actor_permissions, "simulation:run")) return error.Forbidden;
    if (input.actor_user_id.len == 0 or input.actor_realm_id.len == 0) return error.Unauthorized;
    if (input.definition_id.len == 0) return error.DefinitionNotFound;
    if (input.definition_version.len == 0) return error.DefinitionVersionNotFound;

    try validateScenarioSubmission(allocator, input);

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        input.scenario_payload_json,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidScenarioPayload;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidScenarioPayload;

    const tenant_guard = extractDefinitionTenant(parsed.value) orelse null;
    if (tenant_guard) |tenant_id| {
        if (!std.mem.eql(u8, tenant_id, input.actor_realm_id)) return error.TenantAccessDenied;
    }

    const started_ms = currentMillisecondTimestamp();

    const event_trace = try buildEventTrace(allocator, parsed.value);
    errdefer {
        for (event_trace) |entry| entry.deinit(allocator);
        allocator.free(event_trace);
    }

    const actual_final_variables = parsed.value.object.get("actualFinalVariables") orelse
        (parsed.value.object.get("initialVariables") orelse std.json.Value{ .null = {} });
    const actual_final_status = blk: {
        const maybe_status = parsed.value.object.get("actualFinalStatus");
        if (maybe_status) |value| {
            if (value == .string) break :blk value.string;
        }
        break :blk "COMPLETED";
    };
    const actual_task_assignments = parsed.value.object.get("actualTaskAssignments") orelse std.json.Value{ .array = std.json.Array.init(allocator) };

    const assertions_value = parsed.value.object.get("assertions") orelse return error.InvalidScenarioPayload;
    if (assertions_value != .array) return error.InvalidScenarioPayload;

    var assertion_results: std.ArrayList(AssertionResult) = .empty;
    errdefer {
        for (assertion_results.items) |result| result.deinit(allocator);
        assertion_results.deinit(allocator);
    }

    var all_passed = true;

    for (assertions_value.array.items) |assertion| {
        if (assertion != .object) return error.AssertionEvaluationFailed;

        const assertion_id_value = assertion.object.get("id") orelse return error.AssertionEvaluationFailed;
        const assertion_type_value = assertion.object.get("type") orelse return error.AssertionEvaluationFailed;
        if (assertion_id_value != .string or assertion_type_value != .string) return error.AssertionEvaluationFailed;

        const assertion_id = assertion_id_value.string;
        const assertion_type = assertion_type_value.string;

        var passed = false;
        var expected_json: []const u8 = try allocator.dupe(u8, "null");
        errdefer allocator.free(expected_json);
        var actual_json: []const u8 = try allocator.dupe(u8, "null");
        errdefer allocator.free(actual_json);

        if (std.mem.eql(u8, assertion_type, "event_sequence")) {
            const expected = assertion.object.get("expected") orelse return error.AssertionEvaluationFailed;
            if (expected != .array) return error.AssertionEvaluationFailed;
            allocator.free(expected_json);
            allocator.free(actual_json);
            expected_json = try jsonStringifyAlloc(allocator, expected);
            actual_json = try serializeEventTypes(allocator, event_trace);
            passed = matchEventSequence(expected.array.items, event_trace);
            if (!passed) all_passed = false;
        } else if (std.mem.eql(u8, assertion_type, "final_variables")) {
            const expected = assertion.object.get("expected") orelse return error.AssertionEvaluationFailed;
            allocator.free(expected_json);
            allocator.free(actual_json);
            expected_json = try jsonStringifyAlloc(allocator, expected);
            actual_json = try jsonStringifyAlloc(allocator, actual_final_variables);
            passed = jsonValuesEqual(expected, actual_final_variables);
            if (!passed) all_passed = false;
        } else if (std.mem.eql(u8, assertion_type, "final_status")) {
            const expected = assertion.object.get("expected") orelse return error.AssertionEvaluationFailed;
            if (expected != .string) return error.AssertionEvaluationFailed;
            allocator.free(expected_json);
            allocator.free(actual_json);
            expected_json = try jsonStringifyAlloc(allocator, expected);
            actual_json = try jsonStringifyAlloc(allocator, std.json.Value{ .string = actual_final_status });
            passed = std.mem.eql(u8, expected.string, actual_final_status);
            if (!passed) all_passed = false;
        } else if (std.mem.eql(u8, assertion_type, "task_assignments")) {
            const expected = assertion.object.get("expected") orelse return error.AssertionEvaluationFailed;
            if (expected != .array or actual_task_assignments != .array) return error.AssertionEvaluationFailed;
            allocator.free(expected_json);
            allocator.free(actual_json);
            expected_json = try jsonStringifyAlloc(allocator, expected);
            actual_json = try jsonStringifyAlloc(allocator, actual_task_assignments);
            passed = jsonValuesEqual(expected, actual_task_assignments);
            if (!passed) all_passed = false;
        } else if (std.mem.eql(u8, assertion_type, "forbidden_events")) {
            const forbidden = assertion.object.get("forbidden") orelse return error.AssertionEvaluationFailed;
            if (forbidden != .array) return error.AssertionEvaluationFailed;
            allocator.free(expected_json);
            allocator.free(actual_json);
            expected_json = try jsonStringifyAlloc(allocator, forbidden);
            actual_json = try serializeEventTypes(allocator, event_trace);
            passed = !anyPatternMatches(forbidden.array.items, event_trace);
            if (!passed) all_passed = false;
        } else {
            return error.UnknownAssertionType;
        }

        try assertion_results.append(allocator, .{
            .assertion_id = try allocator.dupe(u8, assertion_id),
            .assertion_type = try allocator.dupe(u8, assertion_type),
            .passed = passed,
            .expected_json = expected_json,
            .actual_json = actual_json,
        });
    }

    const ended_ms = currentMillisecondTimestamp();
    const elapsed_ms_i64: i64 = if (ended_ms >= started_ms) ended_ms - started_ms else 0;

    const run_id = try std.fmt.allocPrint(
        allocator,
        "run-{s}-{s}-{d}",
        .{ input.definition_id, input.definition_version, started_ms },
    );

    return .{
        .run_id = run_id,
        .passed = all_passed,
        .elapsed_ms = @intCast(elapsed_ms_i64),
        .assertion_results = try assertion_results.toOwnedSlice(allocator),
        .event_trace = event_trace,
    };
}

pub fn runScenarioBatch(
    allocator: std.mem.Allocator,
    input: BatchRunInput,
) (ScenarioSchemaError || AssertionError || RunnerError || error{OutOfMemory})!BatchRunResult {
    if (!hasPermission(input.actor_permissions, "simulation:run_batch")) return error.Forbidden;
    if (input.tenant_parallelism == 0) return error.InvalidParallelism;

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        input.scenarios_json,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidScenarioPayload;
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidScenarioPayload;

    var runs: std.ArrayList(ScenarioRunResult) = .empty;
    errdefer {
        for (runs.items) |run| run.deinit(allocator);
        runs.deinit(allocator);
    }

    var passed_count: u32 = 0;
    var failed_count: u32 = 0;
    var sum_elapsed: u64 = 0;

    for (parsed.value.array.items) |scenario| {
        const scenario_json = try jsonStringifyAlloc(allocator, scenario);
        defer allocator.free(scenario_json);

        const run = try runScenario(allocator, .{
            .actor_user_id = input.actor_user_id,
            .actor_realm_id = input.actor_realm_id,
            .actor_permissions = input.actor_permissions,
            .schema_name = input.schema_name,
            .schema_version = input.schema_version,
            .definition_id = input.definition_id,
            .definition_version = input.definition_version,
            .scenario_payload_json = scenario_json,
        });

        sum_elapsed += run.elapsed_ms;
        if (run.passed) {
            passed_count += 1;
        } else {
            failed_count += 1;
        }

        try runs.append(allocator, run);
    }

    const total_u32: u32 = @intCast(parsed.value.array.items.len);
    const effective_parallelism: u64 = @max(@as(u64, 1), @min(@as(u64, input.tenant_parallelism), @as(u64, @max(total_u32, 1))));
    const elapsed_ms = if (sum_elapsed == 0) 0 else (sum_elapsed + effective_parallelism - 1) / effective_parallelism;

    const batch_run_id = try std.fmt.allocPrint(
        allocator,
        "batch-{s}-{s}-{d}",
        .{ input.definition_id, input.definition_version, currentMillisecondTimestamp() },
    );

    return .{
        .batch_run_id = batch_run_id,
        .total = total_u32,
        .passed = passed_count,
        .failed = failed_count,
        .elapsed_ms = elapsed_ms,
        .scenario_results = try runs.toOwnedSlice(allocator),
    };
}

fn appendIssue(
    issues: *std.ArrayList(ValidationIssue),
    allocator: std.mem.Allocator,
    path: []const u8,
    message: []const u8,
) !void {
    try issues.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    });
}

fn validateArrayField(
    issues: *std.ArrayList(ValidationIssue),
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    key: []const u8,
    path: []const u8,
) !void {
    const value = root.get(key) orelse {
        try appendIssue(issues, allocator, path, "missing required field");
        return;
    };
    if (value != .array) {
        try appendIssue(issues, allocator, path, "value must be an array");
    }
}

fn hasPermission(permissions: []const []const u8, required: []const u8) bool {
    for (permissions) |permission| {
        if (std.mem.eql(u8, permission, required)) return true;
    }
    return false;
}

fn extractDefinitionTenant(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const definition_ref = root.object.get("definitionRef") orelse return null;
    if (definition_ref != .object) return null;
    const tenant_id = definition_ref.object.get("tenantId") orelse return null;
    if (tenant_id != .string) return null;
    return tenant_id.string;
}

fn buildEventTrace(allocator: std.mem.Allocator, root: std.json.Value) ![]ScenarioEventTraceEntry {
    if (root != .object) return error.InvalidScenarioPayload;

    if (root.object.get("actualEventTrace")) |actual_trace| {
        if (actual_trace != .array) return error.InvalidScenarioPayload;
        var entries: std.ArrayList(ScenarioEventTraceEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        for (actual_trace.array.items, 0..) |item, idx| {
            if (item != .object) {
                _ = idx;
                return error.InvalidScenarioPayload;
            }
            const event_type = item.object.get("eventType") orelse item.object.get("event_type") orelse return error.InvalidScenarioPayload;
            if (event_type != .string) return error.InvalidScenarioPayload;
            const payload = item.object.get("payload") orelse std.json.Value{ .null = {} };
            try entries.append(allocator, .{
                .event_type = try allocator.dupe(u8, event_type.string),
                .payload_json = try jsonStringifyAlloc(allocator, payload),
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    const actions = root.object.get("actions") orelse return error.InvalidScenarioPayload;
    if (actions != .array) return error.InvalidScenarioPayload;

    var entries: std.ArrayList(ScenarioEventTraceEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    for (actions.array.items, 0..) |action, idx| {
        const event_type = if (action == .object)
            blk: {
                const action_type = action.object.get("type");
                if (action_type) |value| {
                    if (value == .string and value.string.len > 0) {
                        break :blk try std.fmt.allocPrint(allocator, "action:{s}", .{value.string});
                    }
                }
                break :blk try std.fmt.allocPrint(allocator, "action:{d}", .{idx});
            }
        else
            try std.fmt.allocPrint(allocator, "action:{d}", .{idx});
        errdefer allocator.free(event_type);

        try entries.append(allocator, .{
            .event_type = event_type,
            .payload_json = try jsonStringifyAlloc(allocator, action),
        });
    }

    return entries.toOwnedSlice(allocator);
}

fn serializeEventTypes(allocator: std.mem.Allocator, event_trace: []const ScenarioEventTraceEntry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (event_trace, 0..) |entry, idx| {
        if (idx > 0) try out.append(allocator, ',');
        const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.event_type }, .{});
        defer allocator.free(encoded);
        try out.appendSlice(allocator, encoded);
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn currentMillisecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10_000);
    }

    const posix = std.posix;
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divTrunc(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

fn eventMatchesPattern(pattern: std.json.Value, event_type: []const u8) bool {
    return switch (pattern) {
        .string => std.mem.eql(u8, pattern.string, "*") or std.mem.eql(u8, pattern.string, event_type),
        .object => blk: {
            if (pattern.object.get("wildcard")) |wildcard| {
                if (wildcard == .bool and wildcard.bool) break :blk true;
            }
            if (pattern.object.get("eventType")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, event_type)) break :blk true;
            }
            if (pattern.object.get("event_type")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, event_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn isWildcardPattern(pattern: std.json.Value) bool {
    return switch (pattern) {
        .string => std.mem.eql(u8, pattern.string, "*"),
        .object => blk: {
            const wildcard = pattern.object.get("wildcard") orelse break :blk false;
            break :blk wildcard == .bool and wildcard.bool;
        },
        else => false,
    };
}

fn matchEventSequence(expected_patterns: []const std.json.Value, event_trace: []const ScenarioEventTraceEntry) bool {
    var expected_idx: usize = 0;
    var event_idx: usize = 0;

    while (expected_idx < expected_patterns.len) {
        const pattern = expected_patterns[expected_idx];
        if (isWildcardPattern(pattern)) {
            expected_idx += 1;
            if (expected_idx >= expected_patterns.len) return true;
            const next_pattern = expected_patterns[expected_idx];
            while (event_idx < event_trace.len and !eventMatchesPattern(next_pattern, event_trace[event_idx].event_type)) {
                event_idx += 1;
            }
            if (event_idx >= event_trace.len) return false;
            event_idx += 1;
            expected_idx += 1;
            continue;
        }

        if (event_idx >= event_trace.len) return false;
        if (!eventMatchesPattern(pattern, event_trace[event_idx].event_type)) return false;
        expected_idx += 1;
        event_idx += 1;
    }

    return true;
}

fn anyPatternMatches(patterns: []const std.json.Value, event_trace: []const ScenarioEventTraceEntry) bool {
    for (patterns) |pattern| {
        for (event_trace) |entry| {
            if (eventMatchesPattern(pattern, entry.event_type)) return true;
        }
    }
    return false;
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |ai, bi| {
                if (!jsonValuesEqual(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var iterator = a.object.iterator();
            while (iterator.next()) |entry| {
                const right = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, right)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "validateScenarioSubmissionDetailed rejects malformed schema metadata" {
    const payload =
        \\{
        \\  "schema": { "name": "wrong", "version": "1.0" },
        \\  "definitionRef": { "definitionId": "def-1", "version": "v1" },
        \\  "initialVariables": {},
        \\  "actions": [],
        \\  "mocks": [],
        \\  "assertions": [
        \\    { "id": "a-1", "type": "final_status", "expected": "COMPLETED" }
        \\  ]
        \\}
    ;

    var report = try validateScenarioSubmissionDetailed(std.testing.allocator, .{
        .actor_user_id = "u1",
        .actor_realm_id = "t1",
        .actor_permissions = &. {"simulation:run"},
        .schema_name = SCHEMA_NAME,
        .schema_version = SCHEMA_VERSION,
        .definition_id = "def-1",
        .definition_version = "v1",
        .scenario_payload_json = payload,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.valid);
    try std.testing.expect(report.issues.len > 0);
}

test "runScenario evaluates final_status and forbidden_events assertions" {
    const payload =
        \\{
        \\  "schema": { "name": "simulation-scenario", "version": "1.0" },
        \\  "definitionRef": { "definitionId": "def-1", "version": "v1", "tenantId": "tenant-a" },
        \\  "initialVariables": { "x": 1 },
        \\  "actions": [{ "type": "start" }, { "type": "approve" }],
        \\  "mocks": [],
        \\  "actualFinalStatus": "COMPLETED",
        \\  "assertions": [
        \\    { "id": "s1", "type": "final_status", "expected": "COMPLETED" },
        \\    { "id": "f1", "type": "forbidden_events", "forbidden": ["event:forbidden"] }
        \\  ]
        \\}
    ;

    const result = try runScenario(std.testing.allocator, .{
        .actor_user_id = "user-a",
        .actor_realm_id = "tenant-a",
        .actor_permissions = &. {"simulation:run"},
        .schema_name = SCHEMA_NAME,
        .schema_version = SCHEMA_VERSION,
        .definition_id = "def-1",
        .definition_version = "v1",
        .scenario_payload_json = payload,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 2), result.assertion_results.len);
}
