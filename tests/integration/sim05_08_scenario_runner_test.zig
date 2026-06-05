//! Integration coverage for SIM-05..SIM-08 scenario schema and runner behavior.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const TestHarness = helpers.TestHarness;
const scenario_runner = bpm.simulation_runner;
const simulation_test_routes = bpm.simulation_test_routes;

fn requireIntegrationHarness(allocator: std.mem.Allocator) !void {
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn formatUuid(bytes: [16]u8) [36]u8 {
    var out: [36]u8 = undefined;
    var out_idx: usize = 0;

    for (bytes, 0..) |byte, idx| {
        out[out_idx] = hexDigit(byte >> 4);
        out[out_idx + 1] = hexDigit(byte & 0x0f);
        out_idx += 2;

        if (idx == 3 or idx == 5 or idx == 7 or idx == 9) {
            out[out_idx] = '-';
            out_idx += 1;
        }
    }

    return out;
}

fn fixtureUuid(test_case: []const u8, field: []const u8) [36]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(test_case);
    hasher.update(":");
    hasher.update(field);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var uuid_bytes: [16]u8 = undefined;
    std.mem.copyForwards(u8, uuid_bytes[0..], digest[0..16]);
    // RFC 4122 variant/version bits.
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    return formatUuid(uuid_bytes);
}

fn baseRunInput(
    actor_user_id: []const u8,
    actor_tenant: []const u8,
    definition_id: []const u8,
    definition_version: []const u8,
    payload: []const u8,
) scenario_runner.ScenarioRunInput {
    return .{
        .actor_user_id = actor_user_id,
        .actor_realm_id = actor_tenant,
        .actor_permissions = &.{"simulation:run"},
        .schema_name = "simulation-scenario",
        .schema_version = "1.0",
        .definition_id = definition_id,
        .definition_version = definition_version,
        .scenario_payload_json = payload,
    };
}

fn buildScenarioPayload(
    allocator: std.mem.Allocator,
    actor_tenant: []const u8,
    definition_id: []const u8,
    definition_version: []const u8,
    actual_fields_json: []const u8,
    assertion_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":{{\"name\":\"simulation-scenario\",\"version\":\"1.0\"}},\"definitionRef\":{{\"definitionId\":\"{s}\",\"version\":\"{s}\",\"tenantId\":\"{s}\"}},\"initialVariables\":{{\"amount\":100,\"currency\":\"USD\"}},\"actions\":[{{\"type\":\"start\"}},{{\"type\":\"approve\"}}],\"mocks\":[],{s}\"assertions\":[{s}]}}",
        .{ definition_id, definition_version, actor_tenant, actual_fields_json, assertion_json },
    );
}

fn buildRouteBody(
    allocator: std.mem.Allocator,
    schema_version: []const u8,
    definition_version: []const u8,
    definition_id: []const u8,
    actor_tenant: []const u8,
    initial_variables_field_json: []const u8,
    actions_json: []const u8,
    actual_fields_json: []const u8,
    assertions_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":{{\"name\":\"simulation-scenario\",\"version\":\"{s}\"}},\"definitionRef\":{{\"definitionId\":\"{s}\",\"version\":\"{s}\",\"tenantId\":\"{s}\"}},{s}\"actions\":{s},\"mocks\":[],{s}\"assertions\":[{s}]}}",
        .{ schema_version, definition_id, definition_version, actor_tenant, initial_variables_field_json, actions_json, actual_fields_json, assertions_json },
    );
}

fn buildBatchScenariosJson(
    allocator: std.mem.Allocator,
    count: usize,
    actor_tenant: []const u8,
    definition_id: []const u8,
    definition_version: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (0..count) |idx| {
        if (idx > 0) try out.append(allocator, ',');

        const assertion_json = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"batch-assert-{d}\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}}",
            .{idx},
        );
        defer allocator.free(assertion_json);

        const scenario_json = try buildScenarioPayload(
            allocator,
            actor_tenant,
            definition_id,
            definition_version,
            "\"actualFinalStatus\":\"COMPLETED\",",
            assertion_json,
        );
        defer allocator.free(scenario_json);

        try out.appendSlice(allocator, scenario_json);
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

test "TC-SIM-05-01: schema submission succeeds for valid versioned payload" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-05-01", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-05-01", "actor");
    const definition_id = fixtureUuid("TC-SIM-05-01", "definition_id");

    const body = try buildRouteBody(
        testing.allocator,
        "1.0",
        "v1",
        definition_id[0..],
        actor_tenant[0..],
        "\"initialVariables\":{},",
        "[{\"type\":\"start\"}]",
        "",
        "{\"id\":\"sim05-valid\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}",
    );
    defer testing.allocator.free(body);

    const result = simulation_test_routes.handleValidateScenario(
        testing.allocator,
        "Bearer test-token",
        actor_user_id[0..],
        actor_tenant[0..],
        "simulation:validate",
        body,
    );
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"valid\":true"));
}

test "TC-SIM-05-02: invalid schema payload is rejected with structured errors" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-05-02", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-05-02", "actor");
    const definition_id = fixtureUuid("TC-SIM-05-02", "definition_id");

    const body = try buildRouteBody(
        testing.allocator,
        "1.0",
        "v1",
        definition_id[0..],
        actor_tenant[0..],
        "",
        "[{\"type\":\"start\"}]",
        "",
        "{\"id\":\"sim05-invalid\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}",
    );
    defer testing.allocator.free(body);

    const result = simulation_test_routes.handleValidateScenario(
        testing.allocator,
        "Bearer test-token",
        actor_user_id[0..],
        actor_tenant[0..],
        "simulation:validate",
        body,
    );
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"errors\":"));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "$.initialVariables"));
}

test "TC-SIM-05-03: unsupported schema version is rejected" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-05-03", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-05-03", "actor");
    const definition_id = fixtureUuid("TC-SIM-05-03", "definition_id");

    const body = try buildRouteBody(
        testing.allocator,
        "2.0",
        "v1",
        definition_id[0..],
        actor_tenant[0..],
        "\"initialVariables\":{},",
        "[{\"type\":\"start\"}]",
        "",
        "{\"id\":\"sim05-version\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}",
    );
    defer testing.allocator.free(body);

    const result = simulation_test_routes.handleValidateScenario(
        testing.allocator,
        "Bearer test-token",
        actor_user_id[0..],
        actor_tenant[0..],
        "simulation:validate",
        body,
    );
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "unsupported schema version"));
}

test "TC-SIM-06-01: event_sequence assertion passes with wildcard match" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-01", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-01", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-01", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualEventTrace\":[{\"eventType\":\"action:start\",\"payload\":{}},{\"eventType\":\"action:approve\",\"payload\":{}}],",
        "{\"id\":\"sim06-event-pass\",\"type\":\"event_sequence\",\"expected\":[\"action:start\",\"*\",{\"eventType\":\"action:approve\"}]}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(run.passed);
    try testing.expect(run.assertion_results[0].passed);
}

test "TC-SIM-06-02: event_sequence assertion fails on mismatch" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-02", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-02", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-02", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualEventTrace\":[{\"eventType\":\"action:start\",\"payload\":{}},{\"eventType\":\"action:approve\",\"payload\":{}}],",
        "{\"id\":\"sim06-event-fail\",\"type\":\"event_sequence\",\"expected\":[\"action:approve\",\"action:start\"]}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(!run.passed);
    try testing.expect(!run.assertion_results[0].passed);
}

test "TC-SIM-06-03: final_variables assertion passes on exact match" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-03", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-03", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-03", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualFinalVariables\":{\"amount\":100,\"currency\":\"USD\"},",
        "{\"id\":\"sim06-vars-pass\",\"type\":\"final_variables\",\"expected\":{\"amount\":100,\"currency\":\"USD\"}}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(run.passed);
    try testing.expect(run.assertion_results[0].passed);
}

test "TC-SIM-06-04: final_variables assertion fails on mismatch" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-04", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-04", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-04", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualFinalVariables\":{\"amount\":99,\"currency\":\"USD\"},",
        "{\"id\":\"sim06-vars-fail\",\"type\":\"final_variables\",\"expected\":{\"amount\":100,\"currency\":\"USD\"}}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(!run.passed);
    try testing.expect(!run.assertion_results[0].passed);
}

test "TC-SIM-06-05: final_status assertion passes on exact status" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-05", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-05", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-05", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualFinalStatus\":\"COMPLETED\",",
        "{\"id\":\"sim06-status-pass\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(run.passed);
    try testing.expect(run.assertion_results[0].passed);
}

test "TC-SIM-06-06: final_status assertion fails on status mismatch" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-06", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-06", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-06", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualFinalStatus\":\"FAILED\",",
        "{\"id\":\"sim06-status-fail\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(!run.passed);
    try testing.expect(!run.assertion_results[0].passed);
}

test "TC-SIM-06-07: task_assignments assertion passes on exact assignment set" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-07", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-07", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-07", "definition_id");
    const task_id = fixtureUuid("TC-SIM-06-07", "task_id");

    const actual_fields_json = try std.fmt.allocPrint(
        testing.allocator,
        "\"actualTaskAssignments\":[{{\"taskId\":\"{s}\",\"assignee\":\"alice\"}}],",
        .{task_id[0..]},
    );
    defer testing.allocator.free(actual_fields_json);

    const assertion_json = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"id\":\"sim06-task-pass\",\"type\":\"task_assignments\",\"expected\":[{{\"taskId\":\"{s}\",\"assignee\":\"alice\"}}]}}",
        .{task_id[0..]},
    );
    defer testing.allocator.free(assertion_json);

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        actual_fields_json,
        assertion_json,
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(run.passed);
    try testing.expect(run.assertion_results[0].passed);
}

test "TC-SIM-06-08: task_assignments assertion fails on assignment mismatch" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-08", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-08", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-08", "definition_id");
    const actual_task_id = fixtureUuid("TC-SIM-06-08", "actual_task_id");
    const expected_task_id = fixtureUuid("TC-SIM-06-08", "expected_task_id");

    const actual_fields_json = try std.fmt.allocPrint(
        testing.allocator,
        "\"actualTaskAssignments\":[{{\"taskId\":\"{s}\",\"assignee\":\"bob\"}}],",
        .{actual_task_id[0..]},
    );
    defer testing.allocator.free(actual_fields_json);

    const assertion_json = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"id\":\"sim06-task-fail\",\"type\":\"task_assignments\",\"expected\":[{{\"taskId\":\"{s}\",\"assignee\":\"alice\"}}]}}",
        .{expected_task_id[0..]},
    );
    defer testing.allocator.free(assertion_json);

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        actual_fields_json,
        assertion_json,
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(!run.passed);
    try testing.expect(!run.assertion_results[0].passed);
}

test "TC-SIM-06-09: forbidden_events assertion passes when forbidden events are absent" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-09", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-09", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-09", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualEventTrace\":[{\"eventType\":\"action:start\",\"payload\":{}},{\"eventType\":\"action:approve\",\"payload\":{}}],",
        "{\"id\":\"sim06-forbidden-pass\",\"type\":\"forbidden_events\",\"forbidden\":[\"action:reject\"]}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(run.passed);
    try testing.expect(run.assertion_results[0].passed);
}

test "TC-SIM-06-10: forbidden_events assertion fails when forbidden event is present" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-06-10", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-06-10", "actor");
    const definition_id = fixtureUuid("TC-SIM-06-10", "definition_id");

    const payload = try buildScenarioPayload(
        testing.allocator,
        actor_tenant[0..],
        definition_id[0..],
        "v1",
        "\"actualEventTrace\":[{\"eventType\":\"action:start\",\"payload\":{}},{\"eventType\":\"action:reject\",\"payload\":{}}],",
        "{\"id\":\"sim06-forbidden-fail\",\"type\":\"forbidden_events\",\"forbidden\":[\"action:reject\"]}",
    );
    defer testing.allocator.free(payload);

    const run = try scenario_runner.runScenario(
        testing.allocator,
        baseRunInput(actor_user_id[0..], actor_tenant[0..], definition_id[0..], "v1", payload),
    );
    defer run.deinit(testing.allocator);

    try testing.expect(!run.passed);
    try testing.expect(!run.assertion_results[0].passed);
}

test "TC-SIM-07-01: run API returns structured result fields" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-07-01", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-07-01", "actor");
    const definition_id = fixtureUuid("TC-SIM-07-01", "definition_id");

    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"schema\":{{\"name\":\"simulation-scenario\",\"version\":\"1.0\"}},\"definitionRef\":{{\"definitionId\":\"{s}\",\"version\":\"v3\",\"tenantId\":\"{s}\"}},\"initialVariables\":{{\"amount\":10}},\"actions\":[{{\"type\":\"start\"}},{{\"type\":\"approve\"}}],\"mocks\":[],\"actualFinalStatus\":\"COMPLETED\",\"assertions\":[{{\"id\":\"sim07-run\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}}]}}",
        .{ definition_id[0..], actor_tenant[0..] },
    );
    defer testing.allocator.free(body);

    const result = simulation_test_routes.handleRunScenario(
        testing.allocator,
        "Bearer test-token",
        actor_user_id[0..],
        actor_tenant[0..],
        "simulation:run",
        body,
    );
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("runId") != null);
    try testing.expect(parsed.value.object.get("passed") != null);
    try testing.expect(parsed.value.object.get("elapsedMs") != null);
    const assertion_results = parsed.value.object.get("assertionResults") orelse return error.TestExpectedEqual;
    try testing.expect(assertion_results == .array);
    const event_trace = parsed.value.object.get("eventTrace") orelse return error.TestExpectedEqual;
    try testing.expect(event_trace == .array);
}

test "TC-SIM-07-02: run API includes per-assertion pass/fail rows" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-07-02", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-07-02", "actor");
    const definition_id = fixtureUuid("TC-SIM-07-02", "definition_id");

    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"schema\":{{\"name\":\"simulation-scenario\",\"version\":\"1.0\"}},\"definitionRef\":{{\"definitionId\":\"{s}\",\"version\":\"v3\",\"tenantId\":\"{s}\"}},\"initialVariables\":{{\"amount\":10}},\"actions\":[{{\"type\":\"start\"}}],\"mocks\":[],\"actualFinalStatus\":\"FAILED\",\"assertions\":[{{\"id\":\"sim07-pass\",\"type\":\"event_sequence\",\"expected\":[\"action:start\"]}},{{\"id\":\"sim07-fail\",\"type\":\"final_status\",\"expected\":\"COMPLETED\"}}]}}",
        .{ definition_id[0..], actor_tenant[0..] },
    );
    defer testing.allocator.free(body);

    const result = simulation_test_routes.handleRunScenario(
        testing.allocator,
        "Bearer test-token",
        actor_user_id[0..],
        actor_tenant[0..],
        "simulation:run",
        body,
    );
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const assertion_results = parsed.value.object.get("assertionResults") orelse return error.TestExpectedEqual;
    try testing.expect(assertion_results == .array);
    try testing.expectEqual(@as(usize, 2), assertion_results.array.items.len);

    const first = assertion_results.array.items[0];
    const second = assertion_results.array.items[1];
    try testing.expect(first.object.get("assertionId") != null);
    try testing.expect(first.object.get("assertionType") != null);
    try testing.expect(first.object.get("passed") != null);
    try testing.expect(second.object.get("passed") != null);
}

test "TC-SIM-08-01: batch runner executes 100 scenarios and reports aggregate counts" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-08-01", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-08-01", "actor");
    const definition_id = fixtureUuid("TC-SIM-08-01", "definition_id");

    const scenarios_json = try buildBatchScenariosJson(
        testing.allocator,
        100,
        actor_tenant[0..],
        definition_id[0..],
        "v5",
    );
    defer testing.allocator.free(scenarios_json);

    const batch = try scenario_runner.runScenarioBatch(testing.allocator, .{
        .actor_user_id = actor_user_id[0..],
        .actor_realm_id = actor_tenant[0..],
        .actor_permissions = &.{"simulation:run_batch", "simulation:run"},
        .schema_name = "simulation-scenario",
        .schema_version = "1.0",
        .definition_id = definition_id[0..],
        .definition_version = "v5",
        .scenarios_json = scenarios_json,
        .tenant_parallelism = 10,
    });
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 100), batch.total);
    try testing.expectEqual(@as(u32, 100), batch.passed + batch.failed);
    try testing.expectEqual(@as(usize, 100), batch.scenario_results.len);
}

test "TC-SIM-08-02: batch elapsed time is less than sequential aggregate under parallelism" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-08-02", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-08-02", "actor");
    const definition_id = fixtureUuid("TC-SIM-08-02", "definition_id");

    const scenarios_json = try buildBatchScenariosJson(
        testing.allocator,
        100,
        actor_tenant[0..],
        definition_id[0..],
        "v5",
    );
    defer testing.allocator.free(scenarios_json);

    const batch = try scenario_runner.runScenarioBatch(testing.allocator, .{
        .actor_user_id = actor_user_id[0..],
        .actor_realm_id = actor_tenant[0..],
        .actor_permissions = &.{"simulation:run_batch", "simulation:run"},
        .schema_name = "simulation-scenario",
        .schema_version = "1.0",
        .definition_id = definition_id[0..],
        .definition_version = "v5",
        .scenarios_json = scenarios_json,
        .tenant_parallelism = 8,
    });
    defer batch.deinit(testing.allocator);

    var sequential_elapsed: u64 = 0;
    for (batch.scenario_results) |run| {
        sequential_elapsed += run.elapsed_ms;
    }

    try testing.expect(batch.elapsed_ms <= sequential_elapsed);
    if (sequential_elapsed > 0) {
        try testing.expect(batch.elapsed_ms < sequential_elapsed);
    }
}

test "TC-SIM-08-03: batch runner rejects invalid per-tenant parallelism" {
    try requireIntegrationHarness(testing.allocator);

    const actor_user_id = fixtureUuid("TC-SIM-08-03", "actor_user_id");
    const actor_tenant = fixtureUuid("TC-SIM-08-03", "actor");
    const definition_id = fixtureUuid("TC-SIM-08-03", "definition_id");

    const scenarios_json = try buildBatchScenariosJson(
        testing.allocator,
        1,
        actor_tenant[0..],
        definition_id[0..],
        "v5",
    );
    defer testing.allocator.free(scenarios_json);

    try testing.expectError(
        scenario_runner.RunnerError.InvalidParallelism,
        scenario_runner.runScenarioBatch(testing.allocator, .{
            .actor_user_id = actor_user_id[0..],
            .actor_realm_id = actor_tenant[0..],
            .actor_permissions = &.{"simulation:run_batch", "simulation:run"},
            .schema_name = "simulation-scenario",
            .schema_version = "1.0",
            .definition_id = definition_id[0..],
            .definition_version = "v5",
            .scenarios_json = scenarios_json,
            .tenant_parallelism = 0,
        }),
    );
}
