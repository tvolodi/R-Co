//! Unit tests for EE-03 — Task activation (pure transition function layer).
//!
//! These tests exercise `engine_transition.transition()` directly (no DB).
//! They verify that only HUMAN_TASK node entry produces a `pending_task_nodes`
//! entry; all other node types (START, END, EXCLUSIVE_GATEWAY,
//! PARALLEL_GATEWAY) must NOT produce one.
//!
//! TC-EE-03-06 through TC-EE-03-08 require a real PostgreSQL database and
//! are stubbed here with error.SkipZigTest; they are implemented in the
//! integration test suite.
//!
//! Requirement traceability:
//!   EE-03 → TC-EE-03-01 … TC-EE-03-08
//!   (see tests/specs/EE-03.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig (module root
// = src/).  engine_transition and definition_graph are re-exported from
// main.zig so that types are deduplicated across the module tree.
const bpm = @import("bpm");
const transition_mod = bpm.engine_transition;
const graph_mod = bpm.definition_graph;

const InstanceState = transition_mod.InstanceState;
const Token = transition_mod.Token;
const TransitionEvent = transition_mod.TransitionEvent;

// ---------------------------------------------------------------------------
// Shared test helper — build an empty InstanceState with a zero instance_id.
// Uses the caller-supplied allocator (typically an ArenaAllocator backing).
// ---------------------------------------------------------------------------
fn emptyState() InstanceState {
    return InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };
}

// ---------------------------------------------------------------------------
// TC-EE-03-01: HUMAN_TASK node activation creates Task with status=PENDING
//
// Verifies that when `instance_started` causes a token to enter a HUMAN_TASK
// node, `pending_task_nodes` contains that node's ID.
// ---------------------------------------------------------------------------
test "TC-EE-03-01: HUMAN_TASK node entry populates pending_task_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: START → HUMAN_TASK("task1")
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = "Review" },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);

    // Token parked on HUMAN_TASK node
    try testing.expectEqual(@as(usize, 1), new_state.tokens.len);
    try testing.expectEqualStrings("task1", new_state.tokens[0].node_id);

    // pending_task_nodes has the HUMAN_TASK node ID
    try testing.expectEqual(@as(usize, 1), new_state.pending_task_nodes.len);
    try testing.expectEqualStrings("task1", new_state.pending_task_nodes[0]);
}

// ---------------------------------------------------------------------------
// TC-EE-03-02: START node activation does NOT create Task record
//
// Verifies that the START node itself never appears in pending_task_nodes.
// Graph START → END: the START node is traversed, END node is entered,
// instance reaches COMPLETED with no pending tasks.
// ---------------------------------------------------------------------------
test "TC-EE-03-02: START node activation does NOT add to pending_task_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: START → END (no HUMAN_TASK)
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "end", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);

    // START traversal must not produce pending_task_nodes entries
    try testing.expectEqual(@as(usize, 0), new_state.pending_task_nodes.len);
    // Reached END immediately — instance COMPLETED
    try testing.expectEqual(transition_mod.InstanceStatus.COMPLETED, new_state.status);
}

// ---------------------------------------------------------------------------
// TC-EE-03-03: END node activation does NOT create Task record
//
// Verifies that completing a HUMAN_TASK that routes to an END node does NOT
// append END to pending_task_nodes, and the instance transitions to COMPLETED.
// ---------------------------------------------------------------------------
test "TC-EE-03-03: END node activation does NOT add to pending_task_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: START → HUMAN_TASK("task1") → END
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = "Review" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "task1", .target = "end", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    // Build a state with token parked on task1 (as after TC-EE-03-01)
    const token = Token{
        .node_id = try alloc.dupe(u8, "task1"),
        .branch_id = try alloc.dupe(u8, "root"),
    };
    const pending_nodes = try alloc.dupe([]const u8, &[_][]const u8{
        try alloc.dupe(u8, "task1"),
    });
    const parked_state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = try alloc.dupe(Token, &[_]Token{token}),
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = pending_nodes,
        .error_detail = null,
        .pending_events = &[_]transition_mod.PendingEvent{},
    };

    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task1",
        .output_variables = std.json.ObjectMap.empty,
    } };

    const new_state = try transition_mod.transition(alloc, snap, parked_state, event);

    // END node must NOT produce a pending_task_nodes entry
    try testing.expectEqual(@as(usize, 0), new_state.pending_task_nodes.len);
    // Instance must be COMPLETED
    try testing.expectEqual(transition_mod.InstanceStatus.COMPLETED, new_state.status);
}

// ---------------------------------------------------------------------------
// TC-EE-03-04: EXCLUSIVE_GATEWAY activation does NOT create Task record
//
// Verifies that traversing an EXCLUSIVE_GATEWAY (with a default edge to END)
// produces no pending_task_nodes entry.
// ---------------------------------------------------------------------------
test "TC-EE-03-04: EXCLUSIVE_GATEWAY activation does NOT add to pending_task_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: START → EXCLUSIVE_GATEWAY("gw") → END (default edge)
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null, .is_default = false },
        // Default edge from EXCLUSIVE_GATEWAY to END (no condition)
        .{ .id = "e2", .source = "gw", .target = "end", .condition = null, .is_default = true },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);

    // EXCLUSIVE_GATEWAY traversal must not produce pending_task_nodes entries
    try testing.expectEqual(@as(usize, 0), new_state.pending_task_nodes.len);
    // Reached END — instance COMPLETED
    try testing.expectEqual(transition_mod.InstanceStatus.COMPLETED, new_state.status);
}

// ---------------------------------------------------------------------------
// TC-EE-03-05: PARALLEL_GATEWAY activation does NOT create Task record
//
// Verifies that a PARALLEL_GATEWAY split creates branch tokens but no
// pending_task_nodes entries. Graph: START → PAR_SPLIT → {END_A, END_B}.
// ---------------------------------------------------------------------------
test "TC-EE-03-05: PARALLEL_GATEWAY activation does NOT add to pending_task_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: START → PARALLEL_GATEWAY("par") → END_A and END_B
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "par", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "end_a", .node_type = .END, .label = null },
        .{ .id = "end_b", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "par", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "par", .target = "end_a", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "par", .target = "end_b", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.empty,
        .start_node_id = "start",
    } };

    const new_state = try transition_mod.transition(alloc, snap, emptyState(), event);

    // PARALLEL_GATEWAY split must not produce pending_task_nodes entries
    try testing.expectEqual(@as(usize, 0), new_state.pending_task_nodes.len);
    // Both branches reach END immediately — instance COMPLETED
    try testing.expectEqual(transition_mod.InstanceStatus.COMPLETED, new_state.status);
}

// ---------------------------------------------------------------------------
// Integration stubs (require real PostgreSQL — TC-EE-03-06 … TC-EE-03-08)
// ---------------------------------------------------------------------------

// TC-EE-03-06: Task created by applyTransition() is visible via GET /tasks
// immediately after the transaction commits.
// Implemented in the integration test suite (tests/integration/).
test "TC-EE-03-06: Task visible via GET /tasks immediately after commit" {
    return error.SkipZigTest;
}

// TC-EE-03-07: Task record returned by createInTx contains all required
// fields: task_id, instance_id, node_id, assignee_type, assignee_ref, created_at.
// Implemented in the integration test suite (tests/integration/).
test "TC-EE-03-07: Task record contains required fields" {
    return error.SkipZigTest;
}

// TC-EE-03-08: Calling applyTransition on a HUMAN_TASK node whose definition
// has no assignee_ref produces a Task with status=PENDING and null assignee_ref.
// Implemented in the integration test suite (tests/integration/).
test "TC-EE-03-08: HUMAN_TASK with no assignee_ref creates Task in PENDING" {
    return error.SkipZigTest;
}
