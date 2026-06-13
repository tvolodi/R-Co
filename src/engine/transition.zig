//! Pure transition function — EE-02
//!
//! Implements the deterministic, zero-I/O process state transition logic.
//! All state is passed in; all output is returned. No DB, no network, no clock.
//!
//! XC-04 Kernel Determinism: This module is part of the platform kernel.
//! It contains NO LLM API calls, HTTP requests, or external service dependencies.
//! This guarantee is verified by static analysis: grep for "llm|openai|anthropic|model_inference"
//! returns zero matches (outside comments). Determinism is critical for XC-05 replay.
//!
//! Design artefact: src/design/engine.md §EE-02
const std = @import("std");
const graph_mod = @import("../definition/graph.zig");
const expr = @import("expr");
const Uuid = graph_mod.Uuid;

// ---------------------------------------------------------------------------
// JoinCounter struct — ISS-105
// ---------------------------------------------------------------------------
pub const JoinCounter = struct {
    received_count: u32,
    expected_from_branches: u32,
};

// ---------------------------------------------------------------------------
// Token struct — ISS-105: Added token_id for stable identity
// ---------------------------------------------------------------------------
pub const Token = struct {
    node_id: []const u8,
    branch_id: []const u8,
    token_id: ?[]const u8 = null, // UUID string — stable identity (optional for compatibility)
    waiting_child_instance_id: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// PendingEvent tagged union (EE-06, EE-07)
// ---------------------------------------------------------------------------
pub const ParallelSplitPayload = struct {
    source_node_id: []const u8,
    token_ids: [][]const u8,
    target_node_ids: [][]const u8,
    edge_count: usize,
    variables_snapshot: std.json.ObjectMap,
};

/// EE-07: emitted when a parallel join gateway fires.
pub const ParallelJoinPayload = struct {
    join_node_id: []const u8,
    branch_ids_arrived: [][]const u8,
    branch_ids_cancelled: [][]const u8,
    outgoing_token_id: []const u8,
};

/// EE-07: emitted when all parallel branches are cancelled before any token
/// reaches the join, cascading the instance to CANCELLED status.
pub const InstanceCancelledPayload = struct {
    reason: []const u8, // "ALL_BRANCHES_CANCELLED" or "OPERATOR"
    join_node_id: ?[]const u8, // set when reason == "ALL_BRANCHES_CANCELLED"
    branch_ids_cancelled: [][]const u8,
};

/// SCH-01: emitted when execution enters a TIMER node.
pub const TimerCreatedPayload = struct {
    timer_node_id: []const u8,
    duration_iso8601: []const u8,
    repeat_expression: ?[]const u8 = null,
    token_branch_id: []const u8,
    payload_json: []const u8,
};

pub const SubProcessStartPayload = struct {
    parent_node_id: []const u8,
    parent_branch_id: []const u8,
    child_definition_id: []const u8,
};

pub const PendingEvent = union(enum) {
    parallel_split: ParallelSplitPayload,
    parallel_join: ParallelJoinPayload, // EE-07
    instance_cancelled: InstanceCancelledPayload, // EE-07
    timer_created: TimerCreatedPayload, // SCH-01
    sub_process_start: SubProcessStartPayload,
    effect_emitted: EffectEmittedPayload, // EXP-301: async effect activated
};

// ---------------------------------------------------------------------------
// EXP-301: EffectEmittedPayload — emitted when engine activates an effect node
// ---------------------------------------------------------------------------

/// Emitted when transition() activates a SERVICE_TASK node (EXP-302 path)
/// or any EFFECT node in the graph. Pure data — no I/O.
/// The event-store writer uses this to insert the EFFECT_EMITTED event and
/// the effects_outbox row in the same transaction.
pub const EffectEmittedPayload = struct {
    node_id: []const u8,
    token_id: []const u8, // empty string if token has no stable ID
    correlation_key: []const u8, // "<node_id>:<token_id_or_branch_id>"
    kind: []const u8, // "http_call" | "email"
    spec_json: []const u8, // raw node attributes JSON (rendered at emit time)
};

// ---------------------------------------------------------------------------
// EmittedEvent wrapper struct — ISS-203: deterministic idempotency keys
// ---------------------------------------------------------------------------

/// A cascade event produced by transition(), carrying a deterministic
/// idempotency key derived solely from the transition inputs.
/// Format of idempotency_key: "engine:<16-hex-digits>" (always 23 chars).
pub const EmittedEvent = struct {
    /// Engine-computed deterministic key.
    /// Never null for events produced by transition().
    idempotency_key: []const u8,
    /// The payload of the emitted effect.
    payload: PendingEvent,
};

// ---------------------------------------------------------------------------
// TransitionResult struct — ISS-201: first-class return from transition()
// ---------------------------------------------------------------------------
pub const TransitionResult = struct {
    state: InstanceState,
    /// ISS-203: each emitted event now carries a deterministic idempotency key.
    emitted_events: []EmittedEvent,
};

// ---------------------------------------------------------------------------
// InstanceState struct — ISS-105: Added join_counters for parallel gateway state
// ---------------------------------------------------------------------------
pub const InstanceState = struct {
    instance_id: Uuid,
    status: InstanceStatus,
    tokens: []Token,
    variables: std.json.ObjectMap,
    join_counters: std.json.ObjectMap, // ISS-105: {NodeId: {received_count, expected_from_branches}}
    pending_task_nodes: [][]const u8,
    error_detail: ?[]const u8,
    /// EE-07/EE-08: flat slice of branch_id strings for cancelled parallel branches.
    /// Format: "<instance_id_hex>/<split_gateway_node_id>/<edge_index>".
    /// Initialised to empty at instance creation; grows as branches are cancelled.
    /// Never shrinks. Default allows existing literals to omit the field.
    cancelled_branch_ids: [][]const u8 = &[_][]const u8{},
};

pub const InstanceStatus = enum {
    ACTIVE,
    COMPLETED,
    CANCELLED,
    ERROR,
    RESTORED_ORPHAN,
};

// ---------------------------------------------------------------------------
// TransitionEvent tagged union
// ---------------------------------------------------------------------------
pub const TransitionEvent = union(enum) {
    instance_started: struct {
        initial_variables: std.json.ObjectMap,
        start_node_id: []const u8,
    },
    task_completed: struct {
        task_node_id: []const u8,
        output_variables: std.json.ObjectMap,
    },
    service_task_completed: struct {
        service_task_node_id: []const u8,
        output_variables: std.json.ObjectMap,
    },
    sub_process_completed: struct {
        sub_process_node_id: []const u8,
        child_instance_id: []const u8,
    },
    unknown: struct {
        event_type: []const u8,
    },
    /// EXP-301: effect delivery succeeded. Advances the token past the
    /// parked SERVICE_TASK node, merging response_body_json into variables.
    effect_completed: struct {
        correlation_key: []const u8,
        response_body_json: ?[]const u8,
    },
    /// EXP-301: effect delivery failed (max attempts exhausted or permanent).
    /// Drives the error boundary edge or sets instance to ERROR.
    effect_failed: struct {
        correlation_key: []const u8,
        error_detail: []const u8,
    },
};

const ParsedSubProcessConfig = struct {
    child_definition_id: []const u8,
};

// ---------------------------------------------------------------------------
// TransitionError error set
// ---------------------------------------------------------------------------
pub const TransitionError = error{
    UnknownEventType,
    TokenOnMissingNode,
    NoMatchingEdge,
    CelEvaluationError,
    TransformResultNonObject,
    InvalidState,
    OutOfMemory,
    /// ISS-203: triggering_event_seq must be > 0.
    /// Callers must supply the actual sequence number assigned by the event store.
    InvalidTriggeringSeq,
};

// ---------------------------------------------------------------------------
// FNV-1a (64-bit) hash helper — ISS-203
// ---------------------------------------------------------------------------

/// Feed bytes into a running FNV-1a 64-bit hash accumulator.
/// Call with initial value FNV1A_64_OFFSET_BASIS for the first chunk,
/// then chain subsequent calls with the returned value.
const FNV1A_64_OFFSET_BASIS: u64 = 14695981039346656037;
const FNV1A_64_PRIME: u64 = 1099511628211;

fn fnv1a64Feed(hash: u64, data: []const u8) u64 {
    var h = hash;
    for (data) |byte| {
        h ^= @as(u64, byte);
        h = h *% FNV1A_64_PRIME;
    }
    return h;
}

/// Compute a deterministic idempotency key for a single engine-emitted event.
///
/// Formula: FNV-1a-64(
///   instance_id_bytes || 0x00 ||
///   triggering_event_seq_big_endian_u64 || 0x00 ||
///   node_id_utf8 || 0x00 ||
///   event_type_tag_utf8 || 0x00 ||
///   ordinal_big_endian_u64
/// )
/// Result string: "engine:<16-hex-lowercase-digits>"  (always exactly 23 chars)
fn computeEmittedEventKey(
    allocator: std.mem.Allocator,
    instance_id: Uuid,
    triggering_event_seq: i64,
    node_id: []const u8,
    event_type_tag: []const u8,
    ordinal: usize,
) error{OutOfMemory}![]u8 {
    var h = FNV1A_64_OFFSET_BASIS;
    // field 1: instance_id raw bytes
    h = fnv1a64Feed(h, &instance_id);
    // separator
    h = fnv1a64Feed(h, &[_]u8{0x00});
    // field 2: triggering_event_seq as big-endian u64
    const seq_u64: u64 = @bitCast(triggering_event_seq);
    const seq_be = [8]u8{
        @intCast((seq_u64 >> 56) & 0xFF),
        @intCast((seq_u64 >> 48) & 0xFF),
        @intCast((seq_u64 >> 40) & 0xFF),
        @intCast((seq_u64 >> 32) & 0xFF),
        @intCast((seq_u64 >> 24) & 0xFF),
        @intCast((seq_u64 >> 16) & 0xFF),
        @intCast((seq_u64 >> 8) & 0xFF),
        @intCast(seq_u64 & 0xFF),
    };
    h = fnv1a64Feed(h, &seq_be);
    // separator
    h = fnv1a64Feed(h, &[_]u8{0x00});
    // field 3: node_id UTF-8
    h = fnv1a64Feed(h, node_id);
    // separator
    h = fnv1a64Feed(h, &[_]u8{0x00});
    // field 4: event_type_tag UTF-8
    h = fnv1a64Feed(h, event_type_tag);
    // separator
    h = fnv1a64Feed(h, &[_]u8{0x00});
    // field 5: ordinal as big-endian u64
    const ord_u64: u64 = @intCast(ordinal);
    const ord_be = [8]u8{
        @intCast((ord_u64 >> 56) & 0xFF),
        @intCast((ord_u64 >> 48) & 0xFF),
        @intCast((ord_u64 >> 40) & 0xFF),
        @intCast((ord_u64 >> 32) & 0xFF),
        @intCast((ord_u64 >> 24) & 0xFF),
        @intCast((ord_u64 >> 16) & 0xFF),
        @intCast((ord_u64 >> 8) & 0xFF),
        @intCast(ord_u64 & 0xFF),
    };
    h = fnv1a64Feed(h, &ord_be);

    return std.fmt.allocPrint(allocator, "engine:{x:0>16}", .{h});
}

// ---------------------------------------------------------------------------
// ISS-206: Deterministic token_id computation via FNV-1a
// ---------------------------------------------------------------------------

/// Compute a deterministic token_id for a branch token created at a PARALLEL split.
///
/// Formula: FNV-1a-64(
///   instance_id_raw_bytes || 0x00 ||
///   gateway_node_id_utf8 || 0x00 ||
///   edge_index_decimal_utf8 || 0x00 ||
///   arriving_branch_id_utf8
/// )
/// Result string: 16 lowercase hex digits (always exactly 16 chars).
///
/// Determinism guarantee: all inputs are replay-stable (instance_id, node_id from
/// definition graph, edge_index from graph edge ordering, arriving_branch_id from
/// the deterministic branch_id scheme). Re-running the same split produces identical
/// token_id values, satisfying the replay invariant.
fn computeTokenId(
    allocator: std.mem.Allocator,
    instance_id: Uuid,
    gateway_node_id: []const u8,
    edge_index: usize,
    arriving_branch_id: []const u8,
) error{OutOfMemory}![]const u8 {
    var h = FNV1A_64_OFFSET_BASIS;
    h = fnv1a64Feed(h, &instance_id);
    h = fnv1a64Feed(h, &[_]u8{0x00});
    h = fnv1a64Feed(h, gateway_node_id);
    h = fnv1a64Feed(h, &[_]u8{0x00});
    // edge_index as decimal string (variable-length; adequate for small N < 1000)
    var edge_buf: [20]u8 = undefined;
    const edge_str = std.fmt.bufPrint(&edge_buf, "{d}", .{edge_index}) catch unreachable;
    h = fnv1a64Feed(h, edge_str);
    h = fnv1a64Feed(h, &[_]u8{0x00});
    h = fnv1a64Feed(h, arriving_branch_id);

    return std.fmt.allocPrint(allocator, "{x:0>16}", .{h});
}

// ---------------------------------------------------------------------------
// ISS-206: Join counter helpers (operate on InstanceState.join_counters ObjectMap)
// ---------------------------------------------------------------------------

/// Read the join counter for a node_id from state.join_counters.
/// Returns default {received_count: 0, expected_from_branches: 0} if absent.
fn getJoinCounter(state: InstanceState, node_id: []const u8) JoinCounter {
    const val = state.join_counters.get(node_id) orelse return JoinCounter{
        .received_count = 0,
        .expected_from_branches = 0,
    };
    if (val != .object) return JoinCounter{
        .received_count = 0,
        .expected_from_branches = 0,
    };
    const rc = val.object.get("received_count");
    const eb = val.object.get("expected_from_branches");
    const received: u32 = if (rc != null and rc.? == .integer)
        @intCast(rc.?.integer)
    else
        0;
    const expected: u32 = if (eb != null and eb.? == .integer)
        @intCast(eb.?.integer)
    else
        0;
    return JoinCounter{
        .received_count = received,
        .expected_from_branches = expected,
    };
}

/// Update the join counter for a node in state.join_counters to reflect
/// the cumulative number of tokens that have arrived at this join node.
/// Uses max(arrived_count, current.received_count) to avoid double-counting
/// tokens that are still parked from previous transitions.
/// Creates the entry with expected_from_branches if absent.
/// Returns the updated counter.
fn updateJoinCounter(
    allocator: std.mem.Allocator,
    state: *InstanceState,
    node_id: []const u8,
    arrived_count: u32,
    expected_branches: u32,
) error{OutOfMemory}!JoinCounter {
    const current = getJoinCounter(state.*, node_id);
    // Use max to handle tokens parked across multiple transition() calls:
    // tokens stay parked on the join node until it fires, so arrived_count
    // already includes previously-arrived tokens. We track the peak, not the sum.
    const new_received = if (arrived_count > current.received_count) arrived_count else current.received_count;
    const new_expected = if (current.expected_from_branches == 0)
        expected_branches
    else
        current.expected_from_branches;

    // Build JSON object: {"received_count": N, "expected_from_branches": M}
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "received_count", std.json.Value{ .integer = @as(i64, new_received) });
    try obj.put(allocator, "expected_from_branches", std.json.Value{ .integer = @as(i64, new_expected) });

    const key_dup = try allocator.dupe(u8, node_id);
    errdefer allocator.free(key_dup);
    try state.join_counters.put(allocator, key_dup, std.json.Value{ .object = obj });

    return JoinCounter{
        .received_count = new_received,
        .expected_from_branches = new_expected,
    };
}

/// Reset a join counter entry after the join fires.
/// Sets received_count to 0 so subsequent getJoinCounter sees a fresh counter.
/// Cannot remove from ArrayHashMap (Zig 0.16 no remove method), so we overwrite.
fn clearJoinCounter(allocator: std.mem.Allocator, state: *InstanceState, node_id: []const u8) !void {
    const key_dup = try allocator.dupe(u8, node_id);
    errdefer allocator.free(key_dup);
    // Overwrite with sentinel zero values — getJoinCounter treats 0/0 as fresh.
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "received_count", std.json.Value{ .integer = 0 });
    try obj.put(allocator, "expected_from_branches", std.json.Value{ .integer = 0 });
    try state.join_counters.put(allocator, key_dup, std.json.Value{ .object = obj });
}

/// Return the canonical event-type tag string for a PendingEvent variant.
/// Used as the event_type_tag field in the idempotency key computation.
fn pendingEventTag(ev: PendingEvent) []const u8 {
    return switch (ev) {
        .parallel_split => "parallel_split",
        .parallel_join => "parallel_join",
        .instance_cancelled => "instance_cancelled",
        .timer_created => "timer_created",
        .sub_process_start => "sub_process_start",
        .effect_emitted => "effect_emitted",
    };
}

/// Return the node_id that the event is associated with, for key computation.
fn pendingEventNodeId(ev: PendingEvent) []const u8 {
    return switch (ev) {
        .parallel_split => |p| p.source_node_id,
        .parallel_join => |p| p.join_node_id,
        .instance_cancelled => |p| p.join_node_id orelse "",
        .timer_created => |p| p.timer_node_id,
        .sub_process_start => |p| p.parent_node_id,
        .effect_emitted => |p| p.node_id,
    };
}


// ---------------------------------------------------------------------------
// transition() function
// ---------------------------------------------------------------------------
pub fn transition(
    allocator: std.mem.Allocator,
    snapshot: graph_mod.DefinitionGraph,
    state: InstanceState,
    event: TransitionEvent,
    triggering_event_seq: i64,
) TransitionError!TransitionResult {
    // ISS-203: reject degenerate sequence numbers immediately.
    if (triggering_event_seq <= 0) return TransitionError.InvalidTriggeringSeq;

    // Precondition checks
    // 1. All tokens must reference valid node_ids
    for (state.tokens) |token| {
        var found = false;
        for (snapshot.nodes) |node| {
            if (std.mem.eql(u8, node.id, token.node_id)) {
                found = true;
                break;
            }
        }
        if (!found) return TransitionError.TokenOnMissingNode;
    }
    // 2. If status is COMPLETED or CANCELLED, tokens must be empty
    if ((state.status == .COMPLETED or state.status == .CANCELLED) and state.tokens.len > 0)
        return TransitionError.InvalidState;
    // 3. Unknown event
    if (event == .unknown) return TransitionError.UnknownEventType;

    var new_state = InstanceState{
        .instance_id = state.instance_id,
        .status = state.status,
        .tokens = try allocator.alloc(Token, state.tokens.len),
        .variables = try state.variables.clone(allocator),
        .join_counters = try state.join_counters.clone(allocator),
        .pending_task_nodes = try allocator.alloc([]const u8, state.pending_task_nodes.len),
        .error_detail = null,
        .cancelled_branch_ids = try allocator.dupe([]const u8, state.cancelled_branch_ids),
    };
    for (state.tokens, 0..) |t, i| {
        var token_id_copy: ?[]const u8 = null;
        if (t.token_id) |tid| {
            token_id_copy = try allocator.dupe(u8, tid);
        }
        new_state.tokens[i] = Token{
            .node_id = try allocator.dupe(u8, t.node_id),
            .branch_id = try allocator.dupe(u8, t.branch_id),
            .token_id = token_id_copy,
        };
    }
    for (state.pending_task_nodes, 0..) |n, i| {
        new_state.pending_task_nodes[i] = try allocator.dupe(u8, n);
    }

    var emitted_events = std.ArrayList(PendingEvent).empty;
    defer emitted_events.deinit(allocator);

    const result_state = switch (event) {
        .instance_started => |payload| blk: {
            // Seed variables from initial_variables
            new_state.variables = try payload.initial_variables.clone(allocator);
            // Place token on first node after START
            const start_node = for (snapshot.nodes) |node| {
                if (std.mem.eql(u8, node.id, payload.start_node_id)) break node;
            } else return TransitionError.InvalidState;
            // Find outgoing edge from START
            var found = false;
            var next_node_id: []const u8 = undefined;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, start_node.id)) {
                    next_node_id = edge.target;
                    found = true;
                    break;
                }
            }
            if (!found) return TransitionError.InvalidState;
            // Root branch_id is instance_id as hex string
            const branch_id = try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                state.instance_id[0],  state.instance_id[1],  state.instance_id[2],  state.instance_id[3],
                state.instance_id[4],  state.instance_id[5],  state.instance_id[6],  state.instance_id[7],
                state.instance_id[8],  state.instance_id[9],  state.instance_id[10], state.instance_id[11],
                state.instance_id[12], state.instance_id[13], state.instance_id[14], state.instance_id[15],
            });
            // Place token
            new_state.tokens = try allocator.alloc(Token, 1);
            new_state.tokens[0] = Token{
                .node_id = try allocator.dupe(u8, next_node_id),
                .branch_id = branch_id,
                // ISS-206: deterministic token_id for root token
                .token_id = try computeTokenId(allocator, state.instance_id, "ROOT", 0, branch_id),
            };
            // Process node entry
            break :blk try processNodeEntry(allocator, snapshot, new_state, next_node_id, &emitted_events);
        },
        .task_completed => |payload| blk: {
            // Find token on task_node_id
            var token_idx: ?usize = null;
            for (new_state.tokens, 0..) |t, i| {
                if (std.mem.eql(u8, t.node_id, payload.task_node_id)) {
                    token_idx = i;
                    break;
                }
            }
            if (token_idx == null) return TransitionError.InvalidState;
            // Merge output_variables into variables
            {
                var it = payload.output_variables.iterator();
                while (it.next()) |entry| {
                    try new_state.variables.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            // Remove from pending_task_nodes
            var new_pending = std.ArrayList([]const u8).empty;
            defer new_pending.deinit(allocator);
            for (new_state.pending_task_nodes) |n| {
                if (!std.mem.eql(u8, n, payload.task_node_id))
                    try new_pending.append(allocator, n);
            }
            new_state.pending_task_nodes = try new_pending.toOwnedSlice(allocator);
            // Advance token
            var outgoing_found = false;
            var chosen_edge: graph_mod.GraphEdge = undefined;
            var next_node_id: []const u8 = undefined;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, payload.task_node_id)) {
                    chosen_edge = edge;
                    next_node_id = edge.target;
                    outgoing_found = true;
                    break;
                }
            }
            if (!outgoing_found) return TransitionError.InvalidState;

            if (chosen_edge.transform) |raw_expr| {
                const transform_expr = std.mem.trim(u8, raw_expr, " \t\r\n");
                if (transform_expr.len > 0) {
                    const transform_obj = evaluateEdgeTransform(
                        allocator,
                        transform_expr,
                        new_state.variables,
                    ) catch |err| switch (err) {
                        error.TransformEvaluationFailed => return TransitionError.CelEvaluationError,
                        error.TransformResultNonObject => return TransitionError.TransformResultNonObject,
                        error.OutOfMemory => return TransitionError.OutOfMemory,
                    };

                    var transform_it = transform_obj.iterator();
                    while (transform_it.next()) |entry| {
                        try new_state.variables.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }

            new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
            // Process node entry
            break :blk try processNodeEntry(allocator, snapshot, new_state, next_node_id, &emitted_events);
        },
        .service_task_completed => |payload| blk: {
            // Find token on service_task_node_id
            var token_idx: ?usize = null;
            for (new_state.tokens, 0..) |t, i| {
                if (std.mem.eql(u8, t.node_id, payload.service_task_node_id)) {
                    token_idx = i;
                    break;
                }
            }
            if (token_idx == null) return TransitionError.InvalidState;

            // Merge output variables from successful SERVICE_TASK response.
            var it = payload.output_variables.iterator();
            while (it.next()) |entry| {
                try new_state.variables.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }

            // Advance token along the single outgoing edge.
            var outgoing_found = false;
            var chosen_edge: graph_mod.GraphEdge = undefined;
            var next_node_id: []const u8 = undefined;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, payload.service_task_node_id)) {
                    chosen_edge = edge;
                    next_node_id = edge.target;
                    outgoing_found = true;
                    break;
                }
            }
            if (!outgoing_found) return TransitionError.InvalidState;

            if (chosen_edge.transform) |raw_expr| {
                const transform_expr = std.mem.trim(u8, raw_expr, " \t\r\n");
                if (transform_expr.len > 0) {
                    const transform_obj = evaluateEdgeTransform(
                        allocator,
                        transform_expr,
                        new_state.variables,
                    ) catch |err| switch (err) {
                        error.TransformEvaluationFailed => return TransitionError.CelEvaluationError,
                        error.TransformResultNonObject => return TransitionError.TransformResultNonObject,
                        error.OutOfMemory => return TransitionError.OutOfMemory,
                    };

                    var transform_it = transform_obj.iterator();
                    while (transform_it.next()) |entry| {
                        try new_state.variables.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }

            new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
            break :blk try processNodeEntry(allocator, snapshot, new_state, next_node_id, &emitted_events);
        },
        .sub_process_completed => |payload| blk: {
            var token_idx: ?usize = null;
            for (new_state.tokens, 0..) |t, i| {
                if (!std.mem.eql(u8, t.node_id, payload.sub_process_node_id)) continue;
                const waiting_child = t.waiting_child_instance_id orelse continue;
                if (std.mem.eql(u8, waiting_child, payload.child_instance_id)) {
                    token_idx = i;
                    break;
                }
            }
            if (token_idx == null) return TransitionError.InvalidState;

            var outgoing_found = false;
            var next_node_id: []const u8 = undefined;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, payload.sub_process_node_id)) {
                    next_node_id = edge.target;
                    outgoing_found = true;
                    break;
                }
            }
            if (!outgoing_found) return TransitionError.InvalidState;

            new_state.tokens[token_idx.?].waiting_child_instance_id = null;
            new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
            break :blk try processNodeEntry(allocator, snapshot, new_state, next_node_id, &emitted_events);
        },
        // EXP-301: effect delivery succeeded — advance token past SERVICE_TASK.
        .effect_completed => |payload| blk: {
            const node_id_from_key = extractNodeIdFromCorrelationKey(payload.correlation_key);
            var token_idx: ?usize = null;
            for (new_state.tokens, 0..) |t, i| {
                if (std.mem.eql(u8, t.node_id, node_id_from_key)) {
                    token_idx = i;
                    break;
                }
            }
            if (token_idx == null) return TransitionError.InvalidState;
            if (payload.response_body_json) |body| {
                const key_dup = try allocator.dupe(u8, "effect_result");
                errdefer allocator.free(key_dup);
                try new_state.variables.put(allocator, key_dup, std.json.Value{ .string = body });
            }
            var outgoing_found = false;
            var next_node_id: []const u8 = undefined;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, node_id_from_key)) {
                    next_node_id = edge.target;
                    outgoing_found = true;
                    break;
                }
            }
            if (!outgoing_found) return TransitionError.InvalidState;
            new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
            break :blk try processNodeEntry(allocator, snapshot, new_state, next_node_id, &emitted_events);
        },
        // EXP-301: effect delivery failed — set instance to ERROR.
        .effect_failed => |payload| blk: {
            const node_id_from_key = extractNodeIdFromCorrelationKey(payload.correlation_key);
            var new_s = new_state;
            new_s.status = .ERROR;
            new_s.error_detail = try allocator.dupe(u8, payload.error_detail);
            var surviving = std.ArrayList(Token).empty;
            defer surviving.deinit(allocator);
            for (new_s.tokens) |t| {
                if (!std.mem.eql(u8, t.node_id, node_id_from_key))
                    try surviving.append(allocator, t);
            }
            new_s.tokens = try surviving.toOwnedSlice(allocator);
            break :blk new_s;
        },
        else => return TransitionError.UnknownEventType,
    };

    // ISS-203: wrap each PendingEvent in an EmittedEvent with a deterministic key.
    // Key is computed after the full list is assembled so ordinals are stable.
    const raw_events = emitted_events.items;
    const wrapped = try allocator.alloc(EmittedEvent, raw_events.len);
    for (raw_events, 0..) |ev, i| {
        const key = computeEmittedEventKey(
            allocator,
            state.instance_id,
            triggering_event_seq,
            pendingEventNodeId(ev),
            pendingEventTag(ev),
            i,
        ) catch return TransitionError.OutOfMemory;
        wrapped[i] = EmittedEvent{
            .idempotency_key = key,
            .payload = ev,
        };
    }

    return TransitionResult{ .state = result_state, .emitted_events = wrapped };
}

const EdgeTransformError = error{
    TransformEvaluationFailed,
    TransformResultNonObject,
    OutOfMemory,
};

fn evaluateEdgeTransform(
    allocator: std.mem.Allocator,
    expression: []const u8,
    variables: std.json.ObjectMap,
) EdgeTransformError!std.json.ObjectMap {
    if (std.mem.startsWith(u8, expression, "variables.")) {
        const var_name = expression["variables.".len..];
        if (!isSimpleIdentifier(var_name)) return error.TransformEvaluationFailed;

        const value = variables.get(var_name) orelse return error.TransformEvaluationFailed;
        return switch (value) {
            .object => |obj| obj.clone(allocator) catch error.OutOfMemory,
            else => error.TransformResultNonObject,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, expression, .{}) catch
        return error.TransformEvaluationFailed;
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => |obj| obj.clone(allocator) catch error.OutOfMemory,
        else => error.TransformResultNonObject,
    };
}

fn isSimpleIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, idx| {
        if (idx == 0 and !(std.ascii.isAlphabetic(c) or c == '_')) return false;
        if (idx > 0 and !(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// EXP-301: Correlation key helpers
// ---------------------------------------------------------------------------

/// Extract the node_id from a correlation_key formatted as "<node_id>:<token_id>".
/// Returns the portion before the first ':'. If no ':' is found, returns the
/// full key (safe fallback for legacy or malformed keys).
fn extractNodeIdFromCorrelationKey(correlation_key: []const u8) []const u8 {
    const colon_pos = std.mem.indexOfScalar(u8, correlation_key, ':') orelse return correlation_key;
    return correlation_key[0..colon_pos];
}

/// Return true when node attributes contain "sync_inline": true.
/// Used by EXP-302 Path B: SERVICE_TASK nodes that retain inline execution.
fn parseSyncInline(node_attrs: ?[]const u8) bool {
    const raw = node_attrs orelse return false;
    if (raw.len == 0) return false;
    // Simple substring check — avoids allocator dependency in a helper.
    return std.mem.indexOf(u8, raw, "\"sync_inline\":true") != null or
        std.mem.indexOf(u8, raw, "\"sync_inline\": true") != null;
}

/// Infer effect kind from node attributes JSON.
/// Returns "http_call" by default if not specified or if kind is unrecognised.
fn parseEffectKind(node_attrs: ?[]const u8) []const u8 {
    const raw = node_attrs orelse return "http_call";
    if (std.mem.indexOf(u8, raw, "\"kind\":\"email\"") != null or
        std.mem.indexOf(u8, raw, "\"kind\": \"email\"") != null)
        return "email";
    return "http_call";
}

// ---------------------------------------------------------------------------
// evaluateGatewayCondition — EXP-102 adapter: CEL syntax → src/expr
// ---------------------------------------------------------------------------
//
// Translates a CEL-syntax gateway condition string (as stored in definition
// graphs) to expr syntax, then parses and evaluates it via src/expr.
// Returns false on any translation, parse, or evaluation error — preserving
// the same `catch false` semantics as the previous cel.evaluate call.
//
// I/O-free guarantee: expr.parse() and expr.evaluate() are pure computations.
// All intermediate allocations are freed before return.
fn evaluateGatewayCondition(
    allocator: std.mem.Allocator,
    cel_expression: []const u8,
    variables: std.json.ObjectMap,
) bool {
    // Step 1: Translate CEL syntax → expr syntax.
    const expr_text = translateCelToExpr(allocator, cel_expression) orelse return false;
    defer allocator.free(expr_text);

    // Step 2: Parse the translated expression.
    const parse_result = expr.parse(allocator, expr_text) catch return false;
    switch (parse_result) {
        .fail => |errors| {
            allocator.free(errors);
            return false;
        },
        .ok => {},
    }
    var ast = parse_result.ok;
    defer ast.deinit();

    // Step 3: Build expr.Context from the JSON ObjectMap.
    var ctx = expr.Context.init(allocator);
    defer ctx.deinit();
    var it = variables.iterator();
    while (it.next()) |kv| {
        const val = celJsonValueToExprValue(kv.value_ptr.*);
        ctx.put(kv.key_ptr.*, val) catch return false;
    }

    // Step 4: Evaluate and extract bool result.
    const eval_result = expr.evaluate(&ast, &ctx, allocator);
    return switch (eval_result) {
        .ok => |v| switch (v) {
            .bool_val => |b| b,
            else => false,
        },
        .err => false,
    };
}

/// Translate CEL gateway condition syntax to expr syntax.
/// Strips `variables.` prefix; replaces `&&`→`and`, `||`→`or`, `!`→`not`.
/// Returns null if the expression uses unsupported CEL features (macros,
/// type-conversion functions, collection functions, or ternary operator).
/// Caller must free the returned slice with the same allocator.
fn translateCelToExpr(allocator: std.mem.Allocator, cel_expression: []const u8) ?[]const u8 {
    if (hasCelUnsupportedFeatures(cel_expression)) return null;

    var result = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < cel_expression.len) {
        // Strip "variables." prefix
        if (i + 10 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..10], "variables.")) {
            i += 10;
            continue;
        }
        // "&&" → " and "
        if (i + 2 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..2], "&&")) {
            result.appendSlice(allocator, " and ") catch return null;
            i += 2;
            continue;
        }
        // "||" → " or "
        if (i + 2 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..2], "||")) {
            result.appendSlice(allocator, " or ") catch return null;
            i += 2;
            continue;
        }
        // "!" → "not " (only logical NOT; "!=" passes through unchanged)
        if (cel_expression[i] == '!') {
            if (i + 1 < cel_expression.len and cel_expression[i + 1] == '=') {
                result.appendSlice(allocator, "!=") catch return null;
                i += 2;
                continue;
            }
            result.appendSlice(allocator, "not ") catch return null;
            i += 1;
            continue;
        }
        result.append(allocator, cel_expression[i]) catch return null;
        i += 1;
    }
    return result.toOwnedSlice(allocator) catch {
        result.deinit(allocator);
        return null;
    };
}

/// Returns true if the CEL expression contains features outside the CEL/expr
/// grammar intersection (macros, type-conversion functions, collection
/// functions, map literals, or ternary operator).
fn hasCelUnsupportedFeatures(expression: []const u8) bool {
    const method_features = [_][]const u8{ ".all(", ".exists(", ".size(", ".map(" };
    for (method_features) |feat| {
        if (std.mem.indexOf(u8, expression, feat) != null) return true;
    }
    const standalone_features = [_][]const u8{ "has(", "matches(", "int(", "string(", "double(" };
    for (standalone_features) |feat| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, expression, pos, feat)) |idx| {
            if (idx == 0 or !isCelIdentChar(expression[idx - 1])) return true;
            pos = idx + feat.len;
        }
    }
    if (std.mem.indexOf(u8, expression, "map{") != null) return true;
    {
        var in_double = false;
        var in_single = false;
        for (expression) |c| {
            if (c == '"' and !in_single) in_double = !in_double;
            if (c == '\'' and !in_double) in_single = !in_single;
            if (!in_double and !in_single and c == '?') return true;
        }
    }
    return false;
}

fn isCelIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

/// Convert a std.json.Value to an expr Value.
/// All JSON variants map to the closest expr equivalent; unsupported variants
/// map to null (preserves graceful-degradation semantics).
///
/// CEL compatibility note: CEL stores all numeric values as f64, so
/// `1500.0` and `1500` are the same in CEL. src/expr has distinct int64 and
/// float64 types. To preserve CEL comparison semantics, whole-number JSON
/// floats (e.g. 1500.0) are converted to int_val so they compare correctly
/// against integer literals in expressions (e.g. `> 1000`).
fn celJsonValueToExprValue(jv: std.json.Value) expr.Value {
    return switch (jv) {
        .null => expr.valueNull(),
        .bool => |b| expr.valueBool(b),
        .integer => |n| expr.valueInt(n),
        .float => |f| blk: {
            // Convert whole-number JSON floats to int_val to avoid type
            // mismatches when compared against integer literals in expressions.
            // CEL treats all numbers as f64; src/expr has distinct int64/float64.
            if (!std.math.isNan(f) and !std.math.isInf(f) and f == @trunc(f)) {
                const as_int: i64 = @intFromFloat(f);
                if (@as(f64, @floatFromInt(as_int)) == f) {
                    break :blk expr.valueInt(as_int);
                }
            }
            break :blk expr.valueFloat(f);
        },
        .string => |s| expr.valueStr(s),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch 0.0;
            return expr.valueFloat(f);
        },
        else => expr.valueNull(),
    };
}

// ---------------------------------------------------------------------------
// processNodeEntry() internal helper
// ---------------------------------------------------------------------------
fn processNodeEntry(
    allocator: std.mem.Allocator,
    snapshot: graph_mod.DefinitionGraph,
    state: InstanceState,
    node_id: []const u8,
    events: *std.ArrayList(PendingEvent),
) TransitionError!InstanceState {
    // Find node type
    var node_type: ?graph_mod.NodeType = null;
    var node_attrs: ?[]const u8 = null;
    for (snapshot.nodes) |node| {
        if (std.mem.eql(u8, node.id, node_id)) {
            node_type = node.node_type;
            node_attrs = node.attributes;
            break;
        }
    }
    if (node_type == null) return TransitionError.InvalidState;

    switch (node_type.?) {
        .END => {
            // Remove arriving token
            var new_tokens = std.ArrayList(Token).empty;
            defer new_tokens.deinit(allocator);
            for (state.tokens) |t| {
                if (!std.mem.eql(u8, t.node_id, node_id))
                    try new_tokens.append(allocator, t);
            }
            // If no remaining non-END tokens, status = COMPLETED
            var active = false;
            for (new_tokens.items) |t| {
                for (snapshot.nodes) |n| {
                    if (std.mem.eql(u8, n.id, t.node_id) and n.node_type != .END) {
                        active = true;
                        break;
                    }
                }
            }
            var new_state = state;
            new_state.tokens = try new_tokens.toOwnedSlice(allocator);
            if (!active) {
                new_state.status = .COMPLETED;
                new_state.tokens = &[_]Token{};
            }
            return new_state;
        },
        .HUMAN_TASK => {
            // Token stays, append to pending_task_nodes if not present
            var already = false;
            for (state.pending_task_nodes) |n| {
                if (std.mem.eql(u8, n, node_id)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                var new_pending = std.ArrayList([]const u8).empty;
                defer new_pending.deinit(allocator);
                for (state.pending_task_nodes) |n| try new_pending.append(allocator, n);
                try new_pending.append(allocator, try allocator.dupe(u8, node_id));
                var new_state = state;
                new_state.pending_task_nodes = try new_pending.toOwnedSlice(allocator);
                return new_state;
            }
            return state;
        },
        .TIMER => {
            // Emit a scheduler intent and keep the token parked on the TIMER node.
            // The durable timer row is persisted by the caller in the DB transaction.
            const timer_config = parseTimerConfig(allocator, node_attrs) catch |err| switch (err) {
                error.InvalidTimerConfig => return TransitionError.InvalidState,
                error.OutOfMemory => return TransitionError.OutOfMemory,
            };

            var token_branch_id: ?[]const u8 = null;
            for (state.tokens) |tok| {
                if (std.mem.eql(u8, tok.node_id, node_id)) {
                    token_branch_id = tok.branch_id;
                    break;
                }
            }
            if (token_branch_id == null) return TransitionError.InvalidState;

            const payload_json = try buildTimerPayloadJson(
                allocator,
                node_id,
                timer_config.duration_iso8601,
                timer_config.repeat_expression,
                token_branch_id.?,
            );

            try events.append(allocator, PendingEvent{
                .timer_created = .{
                    .timer_node_id = try allocator.dupe(u8, node_id),
                    .duration_iso8601 = timer_config.duration_iso8601,
                    .repeat_expression = timer_config.repeat_expression,
                    .token_branch_id = try allocator.dupe(u8, token_branch_id.?),
                    .payload_json = payload_json,
                },
            });

            return state;
        },
        .SUB_PROCESS => {
            const sub_cfg = parseSubProcessConfig(allocator, node_attrs) catch |err| switch (err) {
                error.InvalidSubProcessConfig => return TransitionError.InvalidState,
                error.OutOfMemory => return TransitionError.OutOfMemory,
            };

            var token_branch_id: ?[]const u8 = null;
            var token_waiting_child: ?[]const u8 = null;
            for (state.tokens) |tok| {
                if (!std.mem.eql(u8, tok.node_id, node_id)) continue;
                token_branch_id = tok.branch_id;
                token_waiting_child = tok.waiting_child_instance_id;
                break;
            }
            if (token_branch_id == null) return TransitionError.InvalidState;

            if (token_waiting_child != null) {
                // Parent already waiting on child completion for this token.
                return state;
            }

            try events.append(allocator, PendingEvent{
                .sub_process_start = .{
                    .parent_node_id = try allocator.dupe(u8, node_id),
                    .parent_branch_id = try allocator.dupe(u8, token_branch_id.?),
                    .child_definition_id = sub_cfg.child_definition_id,
                },
            });

            return state;
        },
        .EXCLUSIVE_GATEWAY => {
            // Partition outgoing edges
            var non_default = std.ArrayList(graph_mod.GraphEdge).empty;
            var defaults = std.ArrayList(graph_mod.GraphEdge).empty;
            defer non_default.deinit(allocator);
            defer defaults.deinit(allocator);
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, node_id)) {
                    if (edge.is_default) try defaults.append(allocator, edge) else try non_default.append(allocator, edge);
                }
            }
            var chosen: ?graph_mod.GraphEdge = null;
            for (non_default.items) |edge| {
                if (edge.condition) |cond| {
                    const match = evaluateGatewayCondition(allocator, cond, state.variables);
                    if (match) {
                        chosen = edge;
                        break;
                    }
                }
            }
            if (chosen == null and defaults.items.len > 0) chosen = defaults.items[0];
            if (chosen == null) return TransitionError.NoMatchingEdge;
            // Advance token
            var token_idx: ?usize = null;
            for (state.tokens, 0..) |t, i| {
                if (std.mem.eql(u8, t.node_id, node_id)) {
                    token_idx = i;
                    break;
                }
            }
            if (token_idx == null) return TransitionError.InvalidState;
            var new_state = state;
            new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, chosen.?.target);
            return try processNodeEntry(allocator, snapshot, new_state, chosen.?.target, events);
        },
        .PARALLEL_GATEWAY => {
            // Determine split or join
            var outgoing_count: usize = 0;
            var incoming_count: usize = 0;
            for (snapshot.edges) |edge| {
                if (std.mem.eql(u8, edge.source, node_id)) outgoing_count += 1;
                if (std.mem.eql(u8, edge.target, node_id)) incoming_count += 1;
            }
            if (outgoing_count > 1 and incoming_count <= 1) {
                // Split: remove arriving token, create N tokens
                var new_tokens = std.ArrayList(Token).empty;
                defer new_tokens.deinit(allocator);
                for (state.tokens) |t| {
                    if (!std.mem.eql(u8, t.node_id, node_id))
                        try new_tokens.append(allocator, t);
                }
                // Track branch_ids and target node_ids for the PARALLEL_SPLIT event
                var split_token_ids = std.ArrayList([]const u8).empty;
                defer split_token_ids.deinit(allocator);
                var split_target_ids = std.ArrayList([]const u8).empty;
                defer split_target_ids.deinit(allocator);
                var i: usize = 0;
                for (snapshot.edges) |edge| {
                    if (std.mem.eql(u8, edge.source, node_id)) {
                        // branch_id = "<instance_id_hex>/<gateway_node_id>/<edge_index>"
                        // This deterministic scheme matches the design (OQ-1) and is
                        // stable across replays.
                        const id = &state.instance_id;
                        const branch_id = try std.fmt.allocPrint(
                            allocator,
                            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}" ++
                                "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}/{s}/{d}",
                            .{
                                id[0],   id[1],  id[2],  id[3],
                                id[4],   id[5],  id[6],  id[7],
                                id[8],   id[9],  id[10], id[11],
                                id[12],  id[13], id[14], id[15],
                                node_id, i,
                            },
                        );
                        const target = try allocator.dupe(u8, edge.target);
                        try new_tokens.append(allocator, Token{
                            .node_id = target,
                            .branch_id = branch_id,
                        });
                        try split_token_ids.append(allocator, branch_id);
                        try split_target_ids.append(allocator, target);
                        i += 1;
                    }
                }
                // Build PARALLEL_SPLIT event and accumulate with existing pending_events
                const split_event = PendingEvent{
                    .parallel_split = ParallelSplitPayload{
                        .source_node_id = try allocator.dupe(u8, node_id),
                        .token_ids = try split_token_ids.toOwnedSlice(allocator),
                        .target_node_ids = try split_target_ids.toOwnedSlice(allocator),
                        .edge_count = i,
                        .variables_snapshot = try state.variables.clone(allocator),
                    },
                };
                try events.append(allocator, split_event);
                var new_state = state;
                new_state.tokens = try new_tokens.toOwnedSlice(allocator);
                // Recursively process each new token
                for (new_state.tokens) |t| {
                    if (std.mem.eql(u8, t.node_id, node_id)) continue;
                    new_state = try processNodeEntry(allocator, snapshot, new_state, t.node_id, events);
                }
                return new_state;
            } else if (incoming_count > 1) {
                // EE-07 Join path: wait for all active (non-cancelled) branches.
                // ISS-206: track arrivals via persisted join_counters.
                // Create a mutable copy of state for join_counter updates.
                var join_state = state;

                // Collect all tokens parked on this join node.
                var tokens_on_join = std.ArrayList(Token).empty;
                defer tokens_on_join.deinit(allocator);
                for (state.tokens) |t| {
                    if (std.mem.eql(u8, t.node_id, node_id))
                        try tokens_on_join.append(allocator, t);
                }
                const arrived_now = tokens_on_join.items.len;

                // Extract split_gateway_node_id from the arriving token's branch_id
                // (second '/'-delimited segment). Falls back to "" for old-style tokens.
                const split_gw_id: []const u8 = if (tokens_on_join.items.len > 0)
                    extractBranchSegment(tokens_on_join.items[0].branch_id, 1)
                else
                    "";

                // Count cancelled branches belonging to this split.
                var cancelled_count: usize = 0;
                for (state.cancelled_branch_ids) |bid| {
                    if (split_gw_id.len > 0 and
                        std.mem.eql(u8, extractBranchSegment(bid, 1), split_gw_id))
                        cancelled_count += 1;
                }

                const total_branches = incoming_count;
                const expected_count = total_branches - cancelled_count;

                // ISS-206: update join counters in mutable state copy.
                // received_count accumulates across transitions; when threshold
                // is reached, the join fires and the counter is cleared.
                const counter = try updateJoinCounter(
                    allocator,
                    &join_state,
                    node_id,
                    @intCast(arrived_now),
                    @intCast(expected_count),
                );

                if (counter.received_count < counter.expected_from_branches) {
                    // Not all branches have arrived — park and wait.
                    // join_counter has been updated in join_state.
                    return join_state;
                }

                if (counter.expected_from_branches == 0) {
                    // STEP f: all branches cancelled — cascade INSTANCE_CANCELLED.
                    try clearJoinCounter(allocator, &join_state, node_id);

                    var new_tokens_f = std.ArrayList(Token).empty;
                    defer new_tokens_f.deinit(allocator);
                    for (join_state.tokens) |t| {
                        if (!std.mem.eql(u8, t.node_id, node_id))
                            try new_tokens_f.append(allocator, t);
                    }

                    var cancelled_for_split_f = std.ArrayList([]const u8).empty;
                    defer cancelled_for_split_f.deinit(allocator);
                    for (join_state.cancelled_branch_ids) |bid| {
                        if (split_gw_id.len > 0 and
                            std.mem.eql(u8, extractBranchSegment(bid, 1), split_gw_id))
                            try cancelled_for_split_f.append(allocator, bid);
                    }

                    const cancel_event = PendingEvent{
                        .instance_cancelled = InstanceCancelledPayload{
                            .reason = "ALL_BRANCHES_CANCELLED",
                            .join_node_id = try allocator.dupe(u8, node_id),
                            .branch_ids_cancelled = try cancelled_for_split_f.toOwnedSlice(allocator),
                        },
                    };
                    try events.append(allocator, cancel_event);

                    var new_state_f = join_state;
                    new_state_f.status = .CANCELLED;
                    new_state_f.tokens = &[_]Token{};
                    return new_state_f;
                }

                // STEP e: fire — received_count >= expected > 0.
                // ISS-206: clear the join counter after firing.
                try clearJoinCounter(allocator, &join_state, node_id);

                // Remove all tokens on the join node.
                var new_tokens = std.ArrayList(Token).empty;
                defer new_tokens.deinit(allocator);
                for (join_state.tokens) |t| {
                    if (!std.mem.eql(u8, t.node_id, node_id))
                        try new_tokens.append(allocator, t);
                }

                // Select merged_branch_id: prefer branch with edge_index segment "0".
                var merged_branch_id: []const u8 = "";
                for (tokens_on_join.items) |t| {
                    if (std.mem.eql(u8, extractBranchSegment(t.branch_id, 2), "0")) {
                        merged_branch_id = t.branch_id;
                        break;
                    }
                }
                // Fallback: lexicographically smallest (handles old-style branch_ids).
                if (merged_branch_id.len == 0) {
                    merged_branch_id = tokens_on_join.items[0].branch_id;
                    for (tokens_on_join.items[1..]) |t| {
                        if (std.mem.order(u8, t.branch_id, merged_branch_id) == .lt)
                            merged_branch_id = t.branch_id;
                    }
                }

                // Find single outgoing edge (PD-02 guarantees exactly one).
                var next_node_id: []const u8 = "";
                for (snapshot.edges) |edge| {
                    if (std.mem.eql(u8, edge.source, node_id)) {
                        next_node_id = edge.target;
                        break;
                    }
                }
                if (next_node_id.len == 0) return TransitionError.InvalidState;

                // Create merged token on the outgoing edge.
                const merged_token = Token{
                    .node_id = try allocator.dupe(u8, next_node_id),
                    .branch_id = try allocator.dupe(u8, merged_branch_id),
                };
                try new_tokens.append(allocator, merged_token);

                // Collect arrived branch_ids for the PARALLEL_JOIN event.
                var arrived_ids = std.ArrayList([]const u8).empty;
                defer arrived_ids.deinit(allocator);
                for (tokens_on_join.items) |t| try arrived_ids.append(allocator, t.branch_id);

                // Collect cancelled branch_ids for this split for the event.
                var cancelled_for_split = std.ArrayList([]const u8).empty;
                defer cancelled_for_split.deinit(allocator);
                for (join_state.cancelled_branch_ids) |bid| {
                    if (split_gw_id.len > 0 and
                        std.mem.eql(u8, extractBranchSegment(bid, 1), split_gw_id))
                        try cancelled_for_split.append(allocator, bid);
                }

                const join_event = PendingEvent{
                    .parallel_join = ParallelJoinPayload{
                        .join_node_id = try allocator.dupe(u8, node_id),
                        .branch_ids_arrived = try arrived_ids.toOwnedSlice(allocator),
                        .branch_ids_cancelled = try cancelled_for_split.toOwnedSlice(allocator),
                        .outgoing_token_id = try allocator.dupe(u8, merged_branch_id),
                    },
                };
                try events.append(allocator, join_event);

                var new_state = join_state;
                new_state.tokens = try new_tokens.toOwnedSlice(allocator);
                return try processNodeEntry(allocator, snapshot, new_state, next_node_id, events);
            } else {
                return state;
            }
        },
        // EXP-302: SERVICE_TASK — async effect (Path A) or sync_inline pass (Path B).
        .SERVICE_TASK => {
            if (parseSyncInline(node_attrs)) return state;
            var tok_id: []const u8 = "";
            var br_id: []const u8 = "";
            for (state.tokens) |tok| {
                if (std.mem.eql(u8, tok.node_id, node_id)) {
                    if (tok.token_id) |tid| tok_id = tid;
                    br_id = tok.branch_id;
                    break;
                }
            }
            const stable = if (tok_id.len > 0) tok_id else br_id;
            const ckey = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ node_id, stable });
            const kstr = parseEffectKind(node_attrs);
            const sraw = node_attrs orelse "{}";
            try events.append(allocator, PendingEvent{ .effect_emitted = .{
                .node_id = try allocator.dupe(u8, node_id),
                .token_id = try allocator.dupe(u8, stable),
                .correlation_key = ckey,
                .kind = kstr,
                .spec_json = try allocator.dupe(u8, sraw),
            } });
            return state;
        },
        else => return state,
    }
}

const ParsedTimerConfig = struct {
    duration_iso8601: []const u8,
    repeat_expression: ?[]const u8,
};

fn parseTimerConfig(
    allocator: std.mem.Allocator,
    node_attrs: ?[]const u8,
) error{ InvalidTimerConfig, OutOfMemory }!ParsedTimerConfig {
    const raw = node_attrs orelse return error.InvalidTimerConfig;
    if (raw.len == 0) return error.InvalidTimerConfig;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch {
        return error.InvalidTimerConfig;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidTimerConfig;
    const duration_val = parsed.value.object.get("duration_iso8601") orelse return error.InvalidTimerConfig;
    if (duration_val != .string) return error.InvalidTimerConfig;
    if (duration_val.string.len == 0) return error.InvalidTimerConfig;

    var repeat_expression: ?[]const u8 = null;
    if (parsed.value.object.get("repeat_expression")) |repeat_val| {
        if (repeat_val != .string or repeat_val.string.len == 0) return error.InvalidTimerConfig;
        repeat_expression = try allocator.dupe(u8, repeat_val.string);
    }

    return .{
        .duration_iso8601 = try allocator.dupe(u8, duration_val.string),
        .repeat_expression = repeat_expression,
    };
}

fn parseSubProcessConfig(
    allocator: std.mem.Allocator,
    node_attrs: ?[]const u8,
) error{ InvalidSubProcessConfig, OutOfMemory }!ParsedSubProcessConfig {
    const raw = node_attrs orelse return error.InvalidSubProcessConfig;
    if (raw.len == 0) return error.InvalidSubProcessConfig;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch {
        return error.InvalidSubProcessConfig;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSubProcessConfig;
    const child_def = parsed.value.object.get("child_definition_id") orelse return error.InvalidSubProcessConfig;
    if (child_def != .string or child_def.string.len == 0) return error.InvalidSubProcessConfig;

    return .{ .child_definition_id = try allocator.dupe(u8, child_def.string) };
}

fn buildTimerPayloadJson(
    allocator: std.mem.Allocator,
    timer_node_id: []const u8,
    duration_iso8601: []const u8,
    repeat_expression: ?[]const u8,
    token_branch_id: []const u8,
) TransitionError![]const u8 {
    const node_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = timer_node_id },
        .{},
    ) catch return TransitionError.OutOfMemory;
    defer allocator.free(node_json);

    const duration_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = duration_iso8601 },
        .{},
    ) catch return TransitionError.OutOfMemory;
    defer allocator.free(duration_json);

    const branch_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = token_branch_id },
        .{},
    ) catch return TransitionError.OutOfMemory;
    defer allocator.free(branch_json);

    if (repeat_expression) |repeat_expr| {
        const repeat_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = repeat_expr },
            .{},
        ) catch return TransitionError.OutOfMemory;
        defer allocator.free(repeat_json);

        return std.fmt.allocPrint(
            allocator,
            "{{\"node_id\":{s},\"timer_kind\":\"duration\",\"duration_iso8601\":{s},\"token_branch_id\":{s},\"recurrence\":{{\"expression\":{s}}}}}",
            .{ node_json, duration_json, branch_json, repeat_json },
        ) catch TransitionError.OutOfMemory;
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":{s},\"timer_kind\":\"duration\",\"duration_iso8601\":{s},\"token_branch_id\":{s}}}",
        .{ node_json, duration_json, branch_json },
    ) catch TransitionError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Helper: extract the Nth '/'-delimited segment from a branch_id string.
//
// branch_id format: "<instance_id_hex>/<split_gateway_node_id>/<edge_index>"
//   seg_idx 0 → instance_id_hex
//   seg_idx 1 → split_gateway_node_id
//   seg_idx 2 → edge_index
//
// Returns empty string if the segment index does not exist (safe fallback for
// old-style branch_ids that do not follow the structured format).
// ---------------------------------------------------------------------------
fn extractBranchSegment(branch_id: []const u8, seg_idx: usize) []const u8 {
    var idx: usize = 0;
    var start: usize = 0;
    for (branch_id, 0..) |c, i| {
        if (c == '/') {
            if (idx == seg_idx) return branch_id[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    if (idx == seg_idx) return branch_id[start..];
    return "";
}

// ---------------------------------------------------------------------------
// Unit tests (TC-EE-02-01 through TC-EE-02-11)
// ---------------------------------------------------------------------------
test "TC-EE-02-01: instance_started event places token on first non-START node" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Minimal graph: START -> HUMAN_TASK
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var initial_vars = std.json.ObjectMap.init(allocator);
    defer initial_vars.deinit();
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };
    const result = transition(allocator, graph, state, event, 1) catch unreachable;
    // Should have one token on HUMAN_TASK
    try std.testing.expect(result.state.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.state.tokens[0].node_id, "task1"));
}

test "TC-EE-02-02: task_completed on HUMAN_TASK advances to next node" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: START -> HUMAN_TASK -> END
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "task1", .target = "end", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "task1", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{"task1"},
        .error_detail = null,
    };
    var output_vars = std.json.ObjectMap.init(allocator);
    defer output_vars.deinit();
    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task1",
        .output_variables = output_vars,
    } };
    const result = transition(allocator, graph, state, event, 1) catch unreachable;
    // Should have token on END
    try std.testing.expect(result.state.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.state.tokens[0].node_id, "end"));
}

test "TC-EE-02-03: token reaches END → status becomes COMPLETED" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: START -> HUMAN_TASK -> END
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "task1", .target = "end", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "end", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    // event is unused in this test
    // Directly test processNodeEntry for END
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "end", &events) catch unreachable;
    try std.testing.expect(result.status == .COMPLETED);
}

test "TC-SCH-01-01: entering TIMER emits timer_created pending effect" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{
            .id = "timer1",
            .node_type = .TIMER,
            .label = null,
            .attributes = "{\"duration_iso8601\":\"PT0S\"}",
        },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "timer1", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    var initial_vars = std.json.ObjectMap.init(allocator);
    defer initial_vars.deinit();

    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };

    const tr = try transition(allocator, graph, state, event, 1);
    try std.testing.expect(tr.state.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, tr.state.tokens[0].node_id, "timer1"));
    try std.testing.expect(tr.emitted_events.len == 1);
    const timer_event = tr.emitted_events[0].payload.timer_created;
    try std.testing.expect(std.mem.eql(u8, timer_event.timer_node_id, "timer1"));
    try std.testing.expect(std.mem.eql(u8, timer_event.duration_iso8601, "PT0S"));
}

test "TC-EE-02-04: EXCLUSIVE_GATEWAY follows first true CEL condition" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: START -> GW -> T1, T2; GW is EXCLUSIVE_GATEWAY
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t1", .condition = "true", .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t2", .condition = "false", .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    // Should follow first true (t1)
    try std.testing.expect(result.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].node_id, "t1"));
}

test "TC-EE-02-05: EXCLUSIVE_GATEWAY with no true condition and no default → NoMatchingEdge error" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: GW with two false conditions, no default
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e2", .source = "gw", .target = "t1", .condition = "false", .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t2", .condition = "false", .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events);
    try std.testing.expectError(TransitionError.NoMatchingEdge, result);
}

test "TC-EE-02-06: EXCLUSIVE_GATEWAY default edge fallback" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: GW with two false, one default
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e2", .source = "gw", .target = "t1", .condition = "false", .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t2", .condition = "false", .is_default = false },
        .{ .id = "e4", .source = "gw", .target = "t3", .condition = null, .is_default = true },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    try std.testing.expect(result.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].node_id, "t3"));
}

test "TC-EE-02-07: PARALLEL_GATEWAY split creates N tokens" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: GW (split) -> t1, t2
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    // Should have two tokens, one on t1, one on t2
    try std.testing.expect(result.tokens.len == 2);
    var found1 = false;
    var found2 = false;
    for (result.tokens) |t| {
        if (std.mem.eql(u8, t.node_id, "t1")) found1 = true;
        if (std.mem.eql(u8, t.node_id, "t2")) found2 = true;
    }
    try std.testing.expect(found1 and found2);
}

test "TC-EE-02-08: PARALLEL_GATEWAY join waits until all tokens arrive, then merges" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: t1, t2 -> GW (join) -> t3
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "t1", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "t2", .target = "gw", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    // Only one token has arrived
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b1" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    // Not all arrived, should park
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result1 = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    try std.testing.expect(result1.tokens.len == 1);
    // Now both tokens arrive
    const state2 = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{ .{ .node_id = "gw", .branch_id = "b1" }, .{ .node_id = "gw", .branch_id = "b2" } },
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
        var events2 = std.ArrayList(PendingEvent).init(allocator);
    defer events2.deinit();
    const result2 = processNodeEntry(allocator, graph, state2, "gw", &events2) catch unreachable;
    // Should merge to one token on t3
    try std.testing.expect(result2.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result2.tokens[0].node_id, "t3"));
}

test "TC-EE-02-09: unknown event type → UnknownEventType error" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{};
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    const event = TransitionEvent{ .unknown = .{ .event_type = "foo" } };
    const result = transition(allocator, graph, state, event, 1);
    try std.testing.expectError(TransitionError.UnknownEventType, result);
}

test "TC-EE-02-10: token on missing node → TokenOnMissingNode error" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Graph: only node is "start"
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{};
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "missing", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = std.json.ObjectMap.init(allocator),
        .start_node_id = "start",
    } };
    const result = transition(allocator, graph, state, event, 1);
    try std.testing.expectError(TransitionError.TokenOnMissingNode, result);
}

test "TC-EE-02-11: same inputs called twice → identical output (determinism)" {
    // ...existing code...
    // ...existing code...
    const allocator = std.testing.allocator;
    // Minimal graph: START -> HUMAN_TASK
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "task1", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var initial_vars = std.json.ObjectMap.init(allocator);
    defer initial_vars.deinit();
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };
    const result1 = transition(allocator, graph, state, event, 1) catch unreachable;
    const result2 = transition(allocator, graph, state, event, 1) catch unreachable;
    // Should be identical
    try std.testing.expect(result1.state.tokens.len == result2.state.tokens.len);
    try std.testing.expect(std.mem.eql(u8, result1.state.tokens[0].node_id, result2.state.tokens[0].node_id));
    // ISS-203: idempotency keys must match across identical calls
    try std.testing.expect(result1.emitted_events.len == result2.emitted_events.len);
}

// ---------------------------------------------------------------------------
// Unit tests (TC-EE-06-01 through TC-EE-06-05) — Parallel Gateway Split
// ---------------------------------------------------------------------------

test "TC-EE-06-01: PARALLEL_GATEWAY split with 2 edges creates 2 tokens and 1 PARALLEL_SPLIT event" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    try std.testing.expect(result.tokens.len == 2);
    try std.testing.expect(events.items.len == 1);
    _ = events.items[0].parallel_split; // asserts active tag is .parallel_split
}

test "TC-EE-06-02: PARALLEL_GATEWAY split with 3 edges creates 3 tokens with unique branch_ids" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    try std.testing.expect(result.tokens.len == 3);
    try std.testing.expect(!std.mem.eql(u8, result.tokens[0].branch_id, result.tokens[1].branch_id));
    try std.testing.expect(!std.mem.eql(u8, result.tokens[0].branch_id, result.tokens[2].branch_id));
    try std.testing.expect(!std.mem.eql(u8, result.tokens[1].branch_id, result.tokens[2].branch_id));
}

test "TC-EE-06-03: original arriving token removed after parallel split" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw", .target = "t1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "t2", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "arriving" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    // 1 arriving token → 2 split tokens (not 3)
    try std.testing.expect(result.tokens.len == 2);
    // No token should remain on gateway node
    for (result.tokens) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.node_id, "gw"));
    }
}

test "TC-EE-06-04: each new token targets correct next node per definition edges" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "ta", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "tb", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw", .target = "ta", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw", .target = "tb", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    try std.testing.expect(result.tokens.len == 2);
    var found_ta = false;
    var found_tb = false;
    for (result.tokens) |t| {
        if (std.mem.eql(u8, t.node_id, "ta")) found_ta = true;
        if (std.mem.eql(u8, t.node_id, "tb")) found_tb = true;
    }
    try std.testing.expect(found_ta and found_tb);
}

test "TC-EE-06-05: PARALLEL_SPLIT event records correct source_node_id and edge_count" {
    const allocator = std.testing.allocator;
    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "gw2", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "n1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "n2", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "gw2", .target = "n1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "gw2", .target = "n2", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "gw2", .branch_id = "b" }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = processNodeEntry(allocator, graph, state, "gw2", &events) catch unreachable;
    try std.testing.expect(events.items.len == 1);
    const payload = events.items[0].parallel_split;
    try std.testing.expect(std.mem.eql(u8, payload.source_node_id, "gw2"));
    try std.testing.expect(payload.edge_count == 2);
    try std.testing.expect(payload.token_ids.len == 2);
    try std.testing.expect(payload.target_node_ids.len == 2);
    // Each result token's branch_id must appear in payload.token_ids
    for (result.tokens) |t| {
        var found = false;
        for (payload.token_ids) |tid| {
            if (std.mem.eql(u8, tid, t.branch_id)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// ---------------------------------------------------------------------------
// Unit tests (TC-EE-07-01 through TC-EE-07-04) — Parallel Gateway Join (EE-07)
// ---------------------------------------------------------------------------

test "TC-EE-07-01: join waits when one branch cancelled, fires when remaining active branch arrives" {
    // Graph: split_gw(split) -> t1, t2 -> join_gw(join) -> t3
    // Branch 0 (to t1) has been cancelled. Only branch 1 (to t2) is active.
    // When branch 1 arrives at join_gw, join fires immediately (expected=1, arrived=1).
    const allocator = std.testing.allocator;
    const instance_id = [_]u8{0xAB} ** 16;
    const instance_hex = "abababababababababababababababababab";
    _ = instance_hex;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "split_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "join_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "split_gw", .target = "t1", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "split_gw", .target = "t2", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "t1", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e4", .source = "t2", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e5", .source = "join_gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    // branch_id format: "<instance_hex>/<split_gw_node_id>/<edge_index>"
    const branch_0 = "abababababababababababababababababab/split_gw/0"; // cancelled
    const branch_1 = "abababababababababababababababababab/split_gw/1"; // active, arrived

    // State: branch_0 is cancelled, branch_1's token is on join_gw.
    const state = InstanceState{
        .instance_id = instance_id,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "join_gw", .branch_id = branch_1 }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{branch_0},
    };

    // processNodeEntry: expected_count = 2 - 1 = 1, arrived = 1 → FIRE.
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);

    // After firing: one merged token on t3.
    try std.testing.expect(result.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].node_id, "t3"));

    // Exactly one PARALLEL_JOIN event must be emitted.
    try std.testing.expect(events.items.len == 1);
    const join_payload = events.items[0].parallel_join;
    try std.testing.expect(std.mem.eql(u8, join_payload.join_node_id, "join_gw"));
    try std.testing.expect(join_payload.branch_ids_arrived.len == 1);
    try std.testing.expect(std.mem.eql(u8, join_payload.branch_ids_arrived[0], branch_1));
    try std.testing.expect(join_payload.branch_ids_cancelled.len == 1);
    try std.testing.expect(std.mem.eql(u8, join_payload.branch_ids_cancelled[0], branch_0));
    try std.testing.expect(std.mem.eql(u8, join_payload.outgoing_token_id, result.tokens[0].branch_id));
}

test "TC-EE-07-02: join still waits when only 1 of 2 active branches has arrived" {
    // Both branches are active (no cancellations). Only one has arrived.
    const allocator = std.testing.allocator;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "join_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "t1", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "t2", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "join_gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const branch_0 = "abababababababababababababababababab/split_gw/0";
    const state = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "join_gw", .branch_id = branch_0 }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{}, // no cancellations
    };

    // expected_count = 2, arrived = 1 → wait (park).
    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);
    try std.testing.expect(result.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].node_id, "join_gw"));
    try std.testing.expect(events.items.len == 0);
}

test "TC-EE-07-03: all-branches-cancelled path → INSTANCE_CANCELLED event, status CANCELLED" {
    // Both branches cancelled, no token arrives at join. EE-08 will invoke
    // processNodeEntry on join_gw with arrived_count=0, expected_count=0 → step f.
    const allocator = std.testing.allocator;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "join_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "t1", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "t2", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "join_gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const branch_0 = "abababababababababababababababababab/split_gw/0";
    const branch_1 = "abababababababababababababababababab/split_gw/1";

    // Both branches cancelled, EE-08 places a stray token on join_gw to trigger
    // re-evaluation. Step f detects expected_count == 0 and cascades to CANCELLED.
    const state_with_stray = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{ .node_id = "join_gw", .branch_id = branch_0 }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{ branch_0, branch_1 },
    };

        var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = try processNodeEntry(allocator, graph, state_with_stray, "join_gw", &events);

    // Status must be CANCELLED, tokens must be empty.
    try std.testing.expect(result.status == .CANCELLED);
    try std.testing.expect(result.tokens.len == 0);

    // Exactly one INSTANCE_CANCELLED event.
    try std.testing.expect(events.items.len == 1);
    const cancel_payload = events.items[0].instance_cancelled;
    try std.testing.expect(std.mem.eql(u8, cancel_payload.reason, "ALL_BRANCHES_CANCELLED"));
    try std.testing.expect(cancel_payload.join_node_id != null);
    try std.testing.expect(std.mem.eql(u8, cancel_payload.join_node_id.?, "join_gw"));
    try std.testing.expect(cancel_payload.branch_ids_cancelled.len == 2);
}

test "TC-EE-07-04: PARALLEL_JOIN event records branch_id with edge_index 0 as outgoing_token_id" {
    // Verifies deterministic merged_branch_id selection: the branch with
    // edge_index segment "0" is chosen as the outgoing token id.
    const allocator = std.testing.allocator;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "t1", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "t2", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "join_gw", .node_type = .PARALLEL_GATEWAY, .label = null },
        .{ .id = "t3", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "t1", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "t2", .target = "join_gw", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "join_gw", .target = "t3", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    // branch_1 arrives first (stored first in tokens), branch_0 arrives second.
    // The merged_branch_id should be the one with edge_index "0" (branch_0).
    const branch_0 = "abababababababababababababababababab/split_gw/0";
    const branch_1 = "abababababababababababababababababab/split_gw/1";

    const state = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{
            .{ .node_id = "join_gw", .branch_id = branch_1 }, // arrived first (stored first)
            .{ .node_id = "join_gw", .branch_id = branch_0 }, // arrived second
        },
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    var events = std.ArrayList(PendingEvent).init(allocator);
    defer events.deinit();
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);

    // One merged token on t3.
    try std.testing.expect(result.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].node_id, "t3"));

    // Outgoing token must use branch_0 (edge_index "0").
    try std.testing.expect(std.mem.eql(u8, result.tokens[0].branch_id, branch_0));

    // PARALLEL_JOIN event.
    try std.testing.expect(events.items.len == 1);
    const join_payload = events.items[0].parallel_join;
    try std.testing.expect(std.mem.eql(u8, join_payload.outgoing_token_id, branch_0));
    try std.testing.expect(join_payload.branch_ids_arrived.len == 2);
    try std.testing.expect(join_payload.branch_ids_cancelled.len == 0);
}

test "TC-EXT-05-UT-01: entering SUB_PROCESS emits sub_process_start pending event" {
    const allocator = std.testing.allocator;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null },
        .{ .id = "sp1", .node_type = .SUB_PROCESS, .label = null, .attributes = "{\"child_definition_id\":\"123e4567-e89b-12d3-a456-426614174000\"}" },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "sp1", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const state = InstanceState{
        .instance_id = [_]u8{0x11} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    var init_vars = std.json.ObjectMap.init(allocator);
    defer init_vars.deinit();

    const tr = try transition(allocator, graph, state, .{
        .instance_started = .{
            .initial_variables = init_vars,
            .start_node_id = "start",
        },
    }, 1);

    try std.testing.expect(tr.state.tokens.len == 1);
    try std.testing.expect(std.mem.eql(u8, tr.state.tokens[0].node_id, "sp1"));
    try std.testing.expect(tr.emitted_events.len == 1);
    _ = tr.emitted_events[0].payload.sub_process_start;
}

test "TC-EXT-05-UT-02: sub_process_completed advances waiting token" {
    const allocator = std.testing.allocator;

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "sp1", .node_type = .SUB_PROCESS, .label = null, .attributes = "{\"child_definition_id\":\"123e4567-e89b-12d3-a456-426614174000\"}" },
        .{ .id = "end", .node_type = .END, .label = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "sp1", .target = "end", .condition = null, .is_default = false },
    };
    const graph = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const state = InstanceState{
        .instance_id = [_]u8{0x22} ** 16,
        .status = .ACTIVE,
        .tokens = &[_]Token{.{
            .node_id = "sp1",
            .branch_id = "b1",
            .waiting_child_instance_id = "123e4567-e89b-12d3-a456-426614174001",
        }},
        .variables = std.json.ObjectMap.init(allocator),
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    const tr = try transition(allocator, graph, state, .{
        .sub_process_completed = .{
            .sub_process_node_id = "sp1",
            .child_instance_id = "123e4567-e89b-12d3-a456-426614174001",
        },
    }, 1);

    try std.testing.expect(tr.state.status == .COMPLETED);
    try std.testing.expect(tr.state.tokens.len == 0);
}

// ---------------------------------------------------------------------------
// EXP-102: evaluateGatewayCondition unit tests
// ---------------------------------------------------------------------------

test "TC-EXP-102-01: evaluateGatewayCondition returns true for matching condition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = std.json.ObjectMap.init(alloc);
    defer vars.deinit();
    try vars.put("order_total", .{ .integer = 1500 });

    const result = evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars);
    try testing.expect(result == true);
}

test "TC-EXP-102-02: evaluateGatewayCondition returns false for non-matching condition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = std.json.ObjectMap.init(alloc);
    defer vars.deinit();
    try vars.put("order_total", .{ .integer = 500 });

    const result = evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars);
    try testing.expect(result == false);
}

test "TC-EXP-102-03: evaluateGatewayCondition returns false on syntax error (no panic)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = std.json.ObjectMap.init(alloc);
    defer vars.deinit();

    const result = evaluateGatewayCondition(alloc, "variables.INVALID !!! syntax", vars);
    try testing.expect(result == false);
}
