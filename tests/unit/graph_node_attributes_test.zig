//! Unit tests for validateNodeAttributes() — PD-05.
//!
//! Pure function tests: no I/O, no DB, no mocks required.
//! The graph module has no external dependencies — only std is needed.
//!
//! Run with: zig build test
//!
//! Requirement traceability:
//!   PD-05 → TC-PD-05-01 through TC-PD-05-19
const std = @import("std");
const gm = @import("graph");

const alloc = std.testing.allocator;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hasCode(violations: []const gm.Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

/// Free the ValidationResult returned by validateNodeAttributes.
/// Always call this via defer immediately after receiving the result.
fn freeResult(result: gm.ValidationResult) void {
    for (result.violations) |v| alloc.free(v.message);
    alloc.free(result.violations);
}

// ---------------------------------------------------------------------------
// HUMAN_TASK attribute tests
// ---------------------------------------------------------------------------

test "TC-PD-05-01: HUMAN_TASK with role present and non-empty -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"approver\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-02: HUMAN_TASK with role attribute absent -> HUMAN_TASK_MISSING_ROLE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "HUMAN_TASK_MISSING_ROLE"));
}

test "TC-PD-05-03: HUMAN_TASK with role = empty string -> HUMAN_TASK_MISSING_ROLE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "HUMAN_TASK_MISSING_ROLE"));
}

// ---------------------------------------------------------------------------
// SERVICE_TASK attribute tests
// ---------------------------------------------------------------------------

test "TC-PD-05-04: SERVICE_TASK with valid endpoint and timeout_ms -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\",\"timeout_ms\":60000}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-05: SERVICE_TASK with endpoint absent -> SERVICE_TASK_MISSING_ENDPOINT" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"timeout_ms\":60000}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_MISSING_ENDPOINT"));
}

test "TC-PD-05-06: SERVICE_TASK with timeout_ms absent -> valid (runtime default applies)" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-07: SERVICE_TASK with timeout_ms = 0 -> SERVICE_TASK_INVALID_TIMEOUT" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\",\"timeout_ms\":0}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_TIMEOUT"));
}

test "TC-PD-05-08: SERVICE_TASK with timeout_ms = 300001 -> SERVICE_TASK_INVALID_TIMEOUT" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\",\"timeout_ms\":300001}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_TIMEOUT"));
}

test "TC-PD-05-09: SERVICE_TASK with timeout_ms = 300000 -> valid (boundary: max permitted)" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\",\"timeout_ms\":300000}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-09b: SERVICE_TASK with url (without endpoint) -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"https://api.example.com\",\"method\":\"POST\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-ADP-08-01: SERVICE_TASK with service_id and capability -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc.orders\",\"capabilities\":[\"service:call:svc.orders\"]}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-ADP-08-01b: SERVICE_TASK with service_id and wildcard capability -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc.orders\",\"capabilities\":[\"service:call:*\"]}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-ADP-08-02: SERVICE_TASK with service_id missing capability -> violation" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc.orders\",\"capabilities\":[\"definitions:write\"]}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_MISSING_SERVICE_CAPABILITY"));
}

test "TC-PD-05-09c: SERVICE_TASK with invalid method -> SERVICE_TASK_INVALID_METHOD" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"https://api.example.com\",\"method\":\"TRACE\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_METHOD"));
}

test "TC-PD-05-09d: SERVICE_TASK with invalid retry_limit -> SERVICE_TASK_INVALID_RETRY_LIMIT" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"https://api.example.com\",\"retry_limit\":256}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_RETRY_LIMIT"));
}

test "TC-PD-05-09e: SERVICE_TASK with invalid headers type -> SERVICE_TASK_INVALID_HEADERS" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"https://api.example.com\",\"headers\":\"bad\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_HEADERS"));
}

test "TC-PD-05-09f: SERVICE_TASK with empty header name/value -> SERVICE_TASK_INVALID_HEADERS" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"https://api.example.com\",\"headers\":{\"\":\"value\",\"X-Trace\":\"\"}}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_INVALID_HEADERS"));
}

// ---------------------------------------------------------------------------
// TIMER attribute tests
// ---------------------------------------------------------------------------

test "TC-PD-05-10: TIMER with valid duration_iso8601 = PT5M -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT5M\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-20: SUB_PROCESS with child_definition_id -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "sp1", .node_type = .SUB_PROCESS, .label = null, .attributes = "{\"child_definition_id\":\"123e4567-e89b-12d3-a456-426614174000\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "sp1", .condition = null },
        .{ .id = "e2", .source = "sp1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-21: SUB_PROCESS without child_definition_id -> violation" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "sp1", .node_type = .SUB_PROCESS, .label = null, .attributes = "{}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "sp1", .condition = null },
        .{ .id = "e2", .source = "sp1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "SUB_PROCESS_MISSING_CHILD_DEFINITION_ID"));
}

test "TC-PD-05-11: TIMER with duration_iso8601 = P0D -> valid (zero duration permitted)" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"P0D\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-12: TIMER with duration_iso8601 absent -> TIMER_MISSING_DURATION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .TIMER, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "TIMER_MISSING_DURATION"));
}

test "TC-PD-05-13: TIMER with duration_iso8601 = 'invalid' (no P prefix) -> TIMER_INVALID_DURATION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"invalid\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "TIMER_INVALID_DURATION"));
}

test "TC-PD-05-14: TIMER with duration_iso8601 = 'P' (P but no designator) -> TIMER_INVALID_DURATION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"P\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "TIMER_INVALID_DURATION"));
}

// ---------------------------------------------------------------------------
// Gateway and terminal node tests (no mandatory attributes)
// ---------------------------------------------------------------------------

test "TC-PD-05-15: EXCLUSIVE_GATEWAY with no attributes -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-16: PARALLEL_GATEWAY with no attributes -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "n1", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "n1", .condition = null },
        .{ .id = "e2", .source = "n1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-17: START node with no attributes -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "TC-PD-05-18: END node with no attributes -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ---------------------------------------------------------------------------
// Multiple violations — no early exit
// ---------------------------------------------------------------------------

test "TC-PD-05-19: HUMAN_TASK missing role AND SERVICE_TASK missing endpoint -> both violations collected" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "ht1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "st1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"timeout_ms\":60000}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "ht1", .condition = null },
        .{ .id = "e2", .source = "ht1", .target = "st1", .condition = null },
        .{ .id = "e3", .source = "st1", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateNodeAttributes(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
    try std.testing.expect(hasCode(result.violations, "HUMAN_TASK_MISSING_ROLE"));
    try std.testing.expect(hasCode(result.violations, "SERVICE_TASK_MISSING_ENDPOINT"));
}
