//! Unit tests for validateEdgeConditions() — PD-06.
//!
//! Pure function tests: no I/O, no DB, no mocks required.
//!
//! Run with: zig build test
//!
//! Requirement traceability:
//!   PD-06 → TC-PD-06-01 through TC-PD-06-19
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

fn freeResult(result: gm.ValidationResult) void {
    for (result.violations) |v| alloc.free(v.message);
    alloc.free(result.violations);
}

// ---------------------------------------------------------------------------
// TC-PD-06-01 — valid EXCLUSIVE_GATEWAY with condition on all outgoing edges
// ---------------------------------------------------------------------------

test "TC-PD-06-01: EXCLUSIVE_GATEWAY with valid CEL conditions on all outgoing edges -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end1", .node_type = .END, .label = null },
        .{ .id = "end2", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end1", .condition = "x > 0" },
        .{ .id = "e3", .source = "gw", .target = "end2", .condition = "x <= 0" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ---------------------------------------------------------------------------
// TC-PD-06-02 — valid: one default edge + conditioned edge from EXCLUSIVE_GATEWAY
// ---------------------------------------------------------------------------

test "TC-PD-06-02: EXCLUSIVE_GATEWAY with one default and one conditioned edge -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end1", .node_type = .END, .label = null },
        .{ .id = "end2", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end1", .condition = "score >= 90" },
        .{ .id = "e3", .source = "gw", .target = "end2", .condition = null, .is_default = true },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ---------------------------------------------------------------------------
// TC-PD-06-03 — CHK-EC-01: edge from START with non-null condition
// ---------------------------------------------------------------------------

test "TC-PD-06-03: edge from START with condition -> EDGE_CONDITION_NOT_ALLOWED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = "x > 0" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_CONDITION_NOT_ALLOWED"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-04 — CHK-EC-01: edge from HUMAN_TASK with non-null condition
// ---------------------------------------------------------------------------

test "TC-PD-06-04: edge from HUMAN_TASK with condition -> EDGE_CONDITION_NOT_ALLOWED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task", .condition = null },
        .{ .id = "e2", .source = "task", .target = "end", .condition = "approved == true" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_CONDITION_NOT_ALLOWED"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-05 — CHK-EC-02: edge from START with is_default=true
// ---------------------------------------------------------------------------

test "TC-PD-06-05: edge from START with is_default=true -> EDGE_DEFAULT_NOT_ALLOWED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = null, .is_default = true },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_DEFAULT_NOT_ALLOWED"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-06 — CHK-EC-02: edge from SERVICE_TASK with is_default=true
// ---------------------------------------------------------------------------

test "TC-PD-06-06: edge from SERVICE_TASK with is_default=true -> EDGE_DEFAULT_NOT_ALLOWED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "svc", .node_type = .SERVICE_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "svc", .condition = null },
        .{ .id = "e2", .source = "svc", .target = "end", .condition = null, .is_default = true },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_DEFAULT_NOT_ALLOWED"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-07 — CHK-EC-03: non-default edge from EXCLUSIVE_GATEWAY without condition
// ---------------------------------------------------------------------------

test "TC-PD-06-07: non-default edge from EXCLUSIVE_GATEWAY with null condition -> EDGE_MISSING_CONDITION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_MISSING_CONDITION"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-08 — CHK-EC-03: non-default edge from EXCLUSIVE_GATEWAY with empty condition
// ---------------------------------------------------------------------------

test "TC-PD-06-08: non-default edge from EXCLUSIVE_GATEWAY with empty string condition -> EDGE_MISSING_CONDITION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_MISSING_CONDITION"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-09 — CHK-EC-04: default edge from EXCLUSIVE_GATEWAY also carries condition
// ---------------------------------------------------------------------------

test "TC-PD-06-09: default edge with non-empty condition -> EDGE_DEFAULT_HAS_CONDITION" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "x > 0", .is_default = true },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_DEFAULT_HAS_CONDITION"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-10 — CHK-EC-05: two default edges from the same EXCLUSIVE_GATEWAY
// ---------------------------------------------------------------------------

test "TC-PD-06-10: two default edges from same EXCLUSIVE_GATEWAY -> EDGE_MULTIPLE_DEFAULTS" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end1", .node_type = .END, .label = null },
        .{ .id = "end2", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end1", .condition = null, .is_default = true },
        .{ .id = "e3", .source = "gw", .target = "end2", .condition = null, .is_default = true },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_MULTIPLE_DEFAULTS"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-11 — CHK-EC-06: unbalanced parentheses in CEL expression
// ---------------------------------------------------------------------------

test "TC-PD-06-11: CEL expression with unbalanced parens -> EDGE_INVALID_CEL" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "foo(bar" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_CEL"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-12 — CHK-EC-06: unbalanced brackets in CEL expression
// ---------------------------------------------------------------------------

test "TC-PD-06-12: CEL expression with unbalanced brackets -> EDGE_INVALID_CEL" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "items[0" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_CEL"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-13 — CHK-EC-06: unmatched double-quote string delimiter
// ---------------------------------------------------------------------------

test "TC-PD-06-13: CEL expression with unmatched double-quote -> EDGE_INVALID_CEL" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "name == \"open" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_CEL"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-14 — CHK-EC-06: unmatched single-quote string delimiter
// ---------------------------------------------------------------------------

test "TC-PD-06-14: CEL expression with unmatched single-quote -> EDGE_INVALID_CEL" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "status == 'open" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_CEL"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-15 — CHK-EC-06: valid CEL with balanced parentheses and strings
// ---------------------------------------------------------------------------

test "TC-PD-06-15: CEL with balanced parens and quoted strings -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "status == \"approved\" && size(items) > 0" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// TC-PD-06-16 — multiple violations collected in a single graph
// ---------------------------------------------------------------------------

test "TC-PD-06-16: graph with multiple PD-06 violations -> all violations collected" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        // CHK-EC-01: HUMAN_TASK edge with condition
        .{ .id = "e1", .source = "task", .target = "end", .condition = "x > 0" },
        // CHK-EC-03: EG non-default edge without condition
        .{ .id = "e2", .source = "gw", .target = "end", .condition = null },
        .{ .id = "e3", .source = "start", .target = "gw", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_CONDITION_NOT_ALLOWED"));
    try std.testing.expect(hasCode(result.violations, "EDGE_MISSING_CONDITION"));
    try std.testing.expect(result.violations.len >= 2);
}

// ---------------------------------------------------------------------------
// TC-PD-06-17 — dangling edge source: treated as non-EXCLUSIVE_GATEWAY
// ---------------------------------------------------------------------------

test "TC-PD-06-17: edge with dangling source and condition -> EDGE_CONDITION_NOT_ALLOWED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = null },
        // Source 'ghost' does not exist in the node list.
        .{ .id = "e2", .source = "ghost", .target = "end", .condition = "x > 0" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_CONDITION_NOT_ALLOWED"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-18 — whitespace-only condition treated as empty (CHK-EC-03)
// ---------------------------------------------------------------------------

test "TC-PD-06-18: EG non-default edge with whitespace-only condition -> not caught by CEL (len > 0), but CHK-EC-06 catches it" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null },
        // Whitespace-only: len > 0 so CHK-EC-03 doesn't trigger, but isValidCelSyntax returns false.
        .{ .id = "e2", .source = "gw", .target = "end", .condition = "   " },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_CEL"));
}

// ---------------------------------------------------------------------------
// TC-PD-06-19 — valid graph with no EXCLUSIVE_GATEWAY nodes
// ---------------------------------------------------------------------------

test "TC-PD-06-19: graph with no EXCLUSIVE_GATEWAY and no conditions -> valid" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task", .condition = null },
        .{ .id = "e2", .source = "task", .target = "end", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeConditions(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ---------------------------------------------------------------------------
// EXT-04-UT-01 — transform validation: valid no-op and simple expression
// ---------------------------------------------------------------------------

test "EXT-04-UT-01: null and whitespace transform expressions are valid no-ops" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task", .condition = null, .transform = null },
        .{ .id = "e2", .source = "task", .target = "end", .condition = null, .transform = "   \t  " },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeTransforms(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ---------------------------------------------------------------------------
// EXT-04-UT-02 — transform validation: malformed expression rejected
// ---------------------------------------------------------------------------

test "EXT-04-UT-02: malformed transform expression is rejected" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task", .condition = null },
        .{ .id = "e2", .source = "task", .target = "end", .condition = null, .transform = "variables.(" },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const result = try gm.validateEdgeTransforms(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_INVALID_TRANSFORM_CEL"));
}
