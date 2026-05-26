//! Unit tests for EE-07 — Parallel Gateway (join).
//!
//! TC-EE-07-01 through TC-EE-07-04 are embedded directly in
//! `src/engine/transition.zig` because they call `processNodeEntry`, which is
//! a private (non-pub) function. Those tests are compiled and run as part of
//! `zig build test` via the `unit_tests` step (root: `src/main.zig`).
//!
//! This file adds TC-EE-07-05 using the public `transition()` API, exercising
//! the 3-branch join scenario that the embedded tests do not cover.
//!
//! Requirement traceability:
//!   EE-07 AC1 → TC-EE-07-05 (N=3 join)
//!   EE-07 AC1+AC5 → TC-EE-07-04 (in transition.zig)
//!   EE-07 AC2+AC3 → TC-EE-07-01 (in transition.zig)
//!   EE-07 AC4 → TC-EE-07-03 (in transition.zig)
//!   (see tests/specs/EE-07.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const transition_mod = bpm.engine_transition;
const graph_mod = bpm.definition_graph;

const InstanceState = transition_mod.InstanceState;
const Token = transition_mod.Token;
const PendingEvent = transition_mod.PendingEvent;
const TransitionEvent = transition_mod.TransitionEvent;

// ---------------------------------------------------------------------------
// TC-EE-07-05: 3-branch join — all 3 active branches arrive via sequential
//              task_completed events → join fires exactly once, 1 outgoing token
//
// Given:
//   Graph: t1 → join_gw, t2 → join_gw, t3 → join_gw, join_gw → t4
//   (join_gw has incoming_count=3, so it is treated as a join node)
//   InstanceState with 3 tokens: {t1/branch_0}, {t2/branch_1}, {t3/branch_2}
//   cancelled_branch_ids = []
//
// When:
//   transition(state0, task_completed("t1")) → state1 (1/3 arrived — wait)
//   transition(state1, task_completed("t2")) → state2 (2/3 arrived — wait)
//   transition(state2, task_completed("t3")) → state3 (3/3 arrived — fire)
//
// Then:
//   state3.tokens.len == 1
//   state3.tokens[0].node_id == "t4"
//   state3.tokens[0].branch_id == branch_0 (edge_index "0" is the merged id)
//   state3.pending_events.len == 1
//   state3.pending_events[0].parallel_join.join_node_id == "join_gw"
//   state3.pending_events[0].parallel_join.branch_ids_arrived.len == 3
//   state3.pending_events[0].parallel_join.branch_ids_cancelled.len == 0
// ---------------------------------------------------------------------------
test "TC-EE-07-05: 3-branch join — all 3 active branches arrive via task_completed → join fires, 1 outgoing token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Graph: 5 nodes, 4 edges. join_gw has 3 incoming edges (→ join behaviour).
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "join_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t4", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "t1", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "t2", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "t3", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e4", .source = "join_gw", .target = "t4", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    // branch_id format: "<instance_id_hex>/<split_gateway_node_id>/<edge_index>"
    // Using a recognisable fixed hex prefix; the join algorithm only needs the
    // second ('/'-delimited) segment to identify the split gateway and the third
    // segment to select the deterministic merged_branch_id (edge_index "0").
    const branch_0 = "abababababababababababababababababab/split_gw/0";
    const branch_1 = "abababababababababababababababababab/split_gw/1";
    const branch_2 = "abababababababababababababababababab/split_gw/2";

    // Initial state: 3 tokens, one per branch, parked at the task nodes.
    const init_tokens = try alloc.dupe(Token, &[_]Token{
        .{ .node_id = "t1", .branch_id = branch_0 },
        .{ .node_id = "t2", .branch_id = branch_1 },
        .{ .node_id = "t3", .branch_id = branch_2 },
    });
    const state0 = InstanceState{
        .instance_id = [16]u8{0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB,0xAB},
        .status = .ACTIVE,
        .tokens = init_tokens,
        .variables = std.json.ObjectMap.empty,
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .pending_events = &[_]PendingEvent{},
        .cancelled_branch_ids = &[_][]const u8{},
    };

    const empty_vars = std.json.ObjectMap.empty;

    // --- Step 1: complete t1 → branch_0 token advances to join_gw (wait: 1/3) ---
    const state1 = try transition_mod.transition(alloc, snap, state0, TransitionEvent{
        .task_completed = .{ .task_node_id = "t1", .output_variables = empty_vars },
    });
    // join_gw waits: arrived=1, expected=3 — no PARALLEL_JOIN event yet.
    try testing.expectEqual(@as(usize, 0), state1.pending_events.len);
    // 3 tokens still active: branch_0 on join_gw, branch_1 on t2, branch_2 on t3.
    try testing.expectEqual(@as(usize, 3), state1.tokens.len);
    // The advanced token is now on join_gw.
    var branch0_on_join = false;
    for (state1.tokens) |t| {
        if (std.mem.eql(u8, t.node_id, "join_gw") and
            std.mem.eql(u8, t.branch_id, branch_0))
        {
            branch0_on_join = true;
        }
    }
    try testing.expect(branch0_on_join);

    // --- Step 2: complete t2 → branch_1 token advances to join_gw (wait: 2/3) ---
    const state2 = try transition_mod.transition(alloc, snap, state1, TransitionEvent{
        .task_completed = .{ .task_node_id = "t2", .output_variables = empty_vars },
    });
    // join_gw still waits: arrived=2, expected=3.
    try testing.expectEqual(@as(usize, 0), state2.pending_events.len);
    // 3 tokens still active: branch_0 and branch_1 on join_gw, branch_2 on t3.
    try testing.expectEqual(@as(usize, 3), state2.tokens.len);
    var join_count_after_t2: usize = 0;
    for (state2.tokens) |t| {
        if (std.mem.eql(u8, t.node_id, "join_gw")) join_count_after_t2 += 1;
    }
    try testing.expectEqual(@as(usize, 2), join_count_after_t2);

    // --- Step 3: complete t3 → branch_2 token advances to join_gw (fire: 3/3) ---
    const state3 = try transition_mod.transition(alloc, snap, state2, TransitionEvent{
        .task_completed = .{ .task_node_id = "t3", .output_variables = empty_vars },
    });

    // Join fired: exactly 1 merged token on the outgoing node t4.
    try testing.expectEqual(@as(usize, 1), state3.tokens.len);
    try testing.expectEqualStrings("t4", state3.tokens[0].node_id);

    // Merged branch_id MUST be the one with edge_index "0" (deterministic selection).
    try testing.expectEqualStrings(branch_0, state3.tokens[0].branch_id);

    // Exactly 1 PARALLEL_JOIN event — join fired exactly once.
    try testing.expectEqual(@as(usize, 1), state3.pending_events.len);
    const join_payload = state3.pending_events[0].parallel_join;
    try testing.expectEqualStrings("join_gw", join_payload.join_node_id);

    // All 3 branches recorded in branch_ids_arrived.
    try testing.expectEqual(@as(usize, 3), join_payload.branch_ids_arrived.len);

    // No cancelled branches.
    try testing.expectEqual(@as(usize, 0), join_payload.branch_ids_cancelled.len);

    // outgoing_token_id matches the merged token's branch_id.
    try testing.expectEqualStrings(branch_0, join_payload.outgoing_token_id);

    // Instance remains ACTIVE (t4 is a HUMAN_TASK, not END).
    try testing.expectEqual(transition_mod.InstanceStatus.ACTIVE, state3.status);
}
