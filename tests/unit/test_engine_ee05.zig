//! Unit tests for EE-05 — Exclusive Gateway CEL Integration.
//!
//! These tests exercise the EXCLUSIVE_GATEWAY node in `engine_transition.transition()`
//! using real CEL expressions evaluated against instance variables.
//!
//! Requirement traceability:
//!   EE-05 → TC-EE-05-01 … TC-EE-05-05
//!   (see tests/specs/EE-05.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const transition_mod = bpm.engine_transition;
const graph_mod = bpm.definition_graph;

const InstanceState = transition_mod.InstanceState;
const Token = transition_mod.Token;
const TransitionEvent = transition_mod.TransitionEvent;

// Helper: an empty InstanceState with no tokens and no variables.
fn emptyState() InstanceState {
    return InstanceState{
        .instance_id = std.mem.zeroes([16]u8),
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };
}

// ---------------------------------------------------------------------------
// TC-EE-05-01: Numeric comparison routes to the matching branch
//
// Given a graph: START → EXCLUSIVE_GATEWAY with two non-default edges:
//   edge1 → "variables.amount > 1000" → HUMAN_TASK "t1"
//   edge2 → "variables.amount <= 1000" → HUMAN_TASK "t2"
// And initial_variables = {amount: 1500.0}
// When instance_started fires
// Then token lands on "t1" (first matching condition)
// ---------------------------------------------------------------------------
test "TC-EE-05-01: numeric comparison routes to matching branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e0", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = "variables.amount > 1000", .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = "variables.amount <= 1000", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var vars: std.json.ObjectMap = .{};
    try vars.put(alloc, "amount", .{ .float = 1500.0 });

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = vars,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("t1", new_state.tokens[0].node_id);
}

// ---------------------------------------------------------------------------
// TC-EE-05-02: String equality comparison routes to the matching branch
//
// Given a graph: START → EXCLUSIVE_GATEWAY with two non-default edges:
//   edge1 → "variables.status == \"approved\"" → HUMAN_TASK "t1"
//   edge2 → "variables.status == \"rejected\"" → HUMAN_TASK "t2"
// And initial_variables = {status: "approved"}
// When instance_started fires
// Then token lands on "t1"
// ---------------------------------------------------------------------------
test "TC-EE-05-02: string equality routes to matching branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e0", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = "variables.status == \"approved\"", .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = "variables.status == \"rejected\"", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var vars: std.json.ObjectMap = .{};
    try vars.put(alloc, "status", .{ .string = "approved" });

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = vars,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("t1", new_state.tokens[0].node_id);
}

// ---------------------------------------------------------------------------
// TC-EE-05-03: Missing variable falls through to default edge
//
// Given a graph: START → EXCLUSIVE_GATEWAY with:
//   edge1 (non-default) → "variables.missing_key == 42" → HUMAN_TASK "t1"
//   edge2 (default) → HUMAN_TASK "t2"
// And initial_variables = {} (empty)
// When instance_started fires
// Then CEL eval for edge1 fails (missing key → returns false), and
//      token lands on "t2" via the default edge.
// ---------------------------------------------------------------------------
test "TC-EE-05-03: missing variable causes eval failure, default edge wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e0", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = "variables.missing_key == 42", .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = null, .is_default = true },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("t2", new_state.tokens[0].node_id);
}

// ---------------------------------------------------------------------------
// TC-EE-05-04: All conditions false and no default → NoMatchingEdge
//
// Given a graph: START → EXCLUSIVE_GATEWAY with two non-default edges
//   both having condition "false", and no default edge.
// When instance_started fires
// Then TransitionError.NoMatchingEdge is returned.
// ---------------------------------------------------------------------------
test "TC-EE-05-04: all conditions false with no default returns NoMatchingEdge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e0", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = "false", .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = "false", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    try testing.expectError(
        transition_mod.TransitionError.NoMatchingEdge,
        transition_mod.transition(alloc, snap, emptyState(), event),
    );
}

// ---------------------------------------------------------------------------
// TC-EE-05-05: First matching condition wins (short-circuit evaluation)
//
// Given a graph: START → EXCLUSIVE_GATEWAY with three non-default edges
//   all with condition "true": edge1→t1, edge2→t2, edge3→t3.
// When instance_started fires
// Then the first declared edge wins and token lands on "t1".
// ---------------------------------------------------------------------------
test "TC-EE-05-05: first true condition wins among multiple true conditions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e0", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = "true", .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = "true", .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t3", .condition = "true", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("t1", new_state.tokens[0].node_id);
}

// ---------------------------------------------------------------------------
// EXT-04 transition tests
// ---------------------------------------------------------------------------

test "EXT-04-UT-03: edge transform merges object result into instance variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "next", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "task", .target = "next", .condition = null, .transform = "variables.payload", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var payload_obj: std.json.ObjectMap = .{};
    try payload_obj.put(alloc, "approved", .{ .bool = true });
    try payload_obj.put(alloc, "amount", .{ .integer = 42 });

    var out_vars: std.json.ObjectMap = .{};
    try out_vars.put(alloc, "payload", .{ .object = payload_obj });
    var tokens = [_]Token{.{ .node_id = "task", .branch_id = "b" }};
    var pending = [_][]const u8{"task"};

    const state = InstanceState{
        .instance_id = std.mem.zeroes([16]u8),
        .status = .ACTIVE,
        .tokens = tokens[0..],
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = pending[0..],
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };

    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task",
        .output_variables = out_vars,
    } };

    const new_state = try transition_mod.transition(alloc, snap, state, event);
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("next", new_state.tokens[0].node_id);
    try testing.expect(new_state.variables.get("approved") != null);
    try testing.expect(new_state.variables.get("amount") != null);
}

test "EXT-04-UT-04: missing transform variable returns CelEvaluationError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "next", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "task", .target = "next", .condition = null, .transform = "variables.missing_payload", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    var tokens = [_]Token{.{ .node_id = "task", .branch_id = "b" }};
    var pending = [_][]const u8{"task"};

    const state = InstanceState{
        .instance_id = std.mem.zeroes([16]u8),
        .status = .ACTIVE,
        .tokens = tokens[0..],
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = pending[0..],
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };

    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task",
        .output_variables = std.json.ObjectMap.empty,
    } };

    try testing.expectError(
        transition_mod.TransitionError.CelEvaluationError,
        transition_mod.transition(alloc, snap, state, event),
    );
}

test "EXT-04-UT-05: non-object transform result returns TransformResultNonObject" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "next", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "task", .target = "next", .condition = null, .transform = "variables.amount", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var out_vars: std.json.ObjectMap = .{};
    try out_vars.put(alloc, "amount", .{ .integer = 10 });
    var tokens = [_]Token{.{ .node_id = "task", .branch_id = "b" }};
    var pending = [_][]const u8{"task"};

    const state = InstanceState{
        .instance_id = std.mem.zeroes([16]u8),
        .status = .ACTIVE,
        .tokens = tokens[0..],
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = pending[0..],
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };

    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task",
        .output_variables = out_vars,
    } };

    try testing.expectError(
        transition_mod.TransitionError.TransformResultNonObject,
        transition_mod.transition(alloc, snap, state, event),
    );
}

test "EXT-04-UT-06: whitespace-only transform is treated as no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "task", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "next", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "task", .target = "next", .condition = null, .transform = "   ", .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var out_vars: std.json.ObjectMap = .{};
    try out_vars.put(alloc, "k", .{ .string = "v" });
    var tokens = [_]Token{.{ .node_id = "task", .branch_id = "b" }};
    var pending = [_][]const u8{"task"};

    const state = InstanceState{
        .instance_id = std.mem.zeroes([16]u8),
        .status = .ACTIVE,
        .tokens = tokens[0..],
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = pending[0..],
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };

    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task",
        .output_variables = out_vars,
    } };

    const new_state = try transition_mod.transition(alloc, snap, state, event);
    try testing.expectEqualStrings("next", new_state.tokens[0].node_id);
    try testing.expect(new_state.variables.get("k") != null);
}
