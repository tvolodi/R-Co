//! Unit tests for the graph validation module (PD-02).
//!
//! These tests are pure: they import only std and the graph module (which
//! itself has no I/O, DB, or external imports).  No stubs or mocks required.
//!
//! Run with: zig build test
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

/// Free the ValidationResult returned by validateGraph.
fn freeResult(result: gm.ValidationResult) void {
    for (result.violations) |v| alloc.free(v.message);
    alloc.free(result.violations);
}

// ---------------------------------------------------------------------------
// CHK-07 — node limit
// ---------------------------------------------------------------------------

test "CHK-07: graph with 501 nodes returns NODE_LIMIT_EXCEEDED" {
    // Build 501 nodes.
    var nodes: [501]gm.GraphNode = undefined;
    for (0..501) |i| {
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "N{d:0>7}", .{i});
        nodes[i] = gm.GraphNode{ .id = id, .node_type = .HUMAN_TASK, .label = null };
    }
    nodes[0].node_type = .START;
    nodes[500].node_type = .END;

    const g = gm.DefinitionGraph{
        .nodes = &nodes,
        .edges = &.{},
    };

    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "NODE_LIMIT_EXCEEDED"));
}

// ---------------------------------------------------------------------------
// CHK-08 — edge limit
// ---------------------------------------------------------------------------

test "CHK-08: graph with 2001 edges returns EDGE_LIMIT_EXCEEDED" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    var edges: [2001]gm.GraphEdge = undefined;
    for (0..2001) |i| {
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "e{d:0>7}", .{i});
        edges[i] = gm.GraphEdge{
            .id = id,
            .source = "S",
            .target = "E",
            .condition = null,
        };
    }

    const g = gm.DefinitionGraph{
        .nodes = &nodes,
        .edges = &edges,
    };

    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "EDGE_LIMIT_EXCEEDED"));
}

// ---------------------------------------------------------------------------
// CHK-01 — exactly one START node
// ---------------------------------------------------------------------------

test "CHK-01: graph with no START node returns MISSING_START_NODE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "T", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "MISSING_START_NODE"));
}

test "CHK-01: graph with two START nodes returns MULTIPLE_START_NODES" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S1", .node_type = .START, .label = null },
        .{ .id = "S2", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S1", .target = "E", .condition = null },
        .{ .id = "e2", .source = "S2", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "MULTIPLE_START_NODES"));
}

// ---------------------------------------------------------------------------
// CHK-02 — at least one END node
// ---------------------------------------------------------------------------

test "CHK-02: graph with no END node returns MISSING_END_NODE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "MISSING_END_NODE"));
}

// ---------------------------------------------------------------------------
// CHK-03 — no dangling edges
// ---------------------------------------------------------------------------

test "CHK-03: edge referencing unknown source returns DANGLING_EDGE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "E", .condition = null },
        .{ .id = "e2", .source = "MISSING", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "DANGLING_EDGE"));
}

test "CHK-03: edge referencing unknown target returns DANGLING_EDGE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "E", .condition = null },
        .{ .id = "e2", .source = "S", .target = "MISSING", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "DANGLING_EDGE"));
}

// ---------------------------------------------------------------------------
// CHK-04 — no isolated nodes
// ---------------------------------------------------------------------------

test "CHK-04: node with no edges returns ISOLATED_NODE" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
        .{ .id = "X", .node_type = .HUMAN_TASK, .label = null }, // isolated
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "ISOLATED_NODE"));
}

// ---------------------------------------------------------------------------
// CHK-05 — no duplicate node IDs
// ---------------------------------------------------------------------------

test "CHK-05: duplicate node ID returns DUPLICATE_NODE_ID" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null }, // duplicate
        .{ .id = "END", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "END", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "DUPLICATE_NODE_ID"));
}

// ---------------------------------------------------------------------------
// CHK-06 — no cycles without a gateway
// ---------------------------------------------------------------------------

test "CHK-06: simple cycle between two user-task nodes returns CYCLE_WITHOUT_GATEWAY" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "A", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "B", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    // A → B → A cycle; neither is a gateway.
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "A", .condition = null },
        .{ .id = "e2", .source = "A", .target = "B", .condition = null },
        .{ .id = "e3", .source = "B", .target = "A", .condition = null }, // back edge
        .{ .id = "e4", .source = "B", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result.violations, "CYCLE_WITHOUT_GATEWAY"));
}

test "CHK-06: cycle through exclusive-gateway does NOT return CYCLE_WITHOUT_GATEWAY" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    // S → GW → T → GW (cycle via gateway — permitted).
    // GW → E (exit path so E is connected).
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "GW", .condition = null },
        .{ .id = "e2", .source = "GW", .target = "T", .condition = null },
        .{ .id = "e3", .source = "T", .target = "GW", .condition = null }, // back to gateway — allowed
        .{ .id = "e4", .source = "GW", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(!hasCode(result.violations, "CYCLE_WITHOUT_GATEWAY"));
}

// ---------------------------------------------------------------------------
// Valid minimal graph — should produce no violations
// ---------------------------------------------------------------------------

test "valid minimal graph: START → HUMAN_TASK → END returns valid=true" {
    const nodes = [_]gm.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]gm.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };
    const g = gm.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const result = try gm.validateGraph(alloc, g);
    defer freeResult(result);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}
