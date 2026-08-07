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

    // ISS-0158 / GH #479: EVERY field above is allocator-owned and must be
    // freed by freePendingEventPayload. `kind` used to be the one exception —
    // the emit site stored parseEffectKind's return value directly, which is a
    // static string literal ("http_call" / "email") living in read-only .rdata.
    // Any caller that freed the payload uniformly (as tests/integration/
    // effects_subsystem_test.zig's freeTransitionResult does, and as any
    // reasonable reading of the struct implies) segfaulted inside
    // Allocator.free's @memset when it tried to scribble over that literal.
    // Do not reintroduce a borrowed field here: a payload whose fields have
    // mixed ownership cannot be freed by a single loop, and this struct
    // crosses a module boundary where the borrowed/owned distinction is
    // invisible to the caller.
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

/// Free every heap allocation transition() makes when producing a fresh
/// InstanceState (tokens, variables, join_counters, pending_task_nodes,
/// error_detail). ISS-0601: `transition()` always returns a state whose
/// tokens/pending_task_nodes/variables/join_counters/error_detail were
/// freshly duped/deep-cloned from the input — so once a caller has moved
/// on to a newer state, the old one is entirely owned garbage and must be
/// fully freed, not just its variables/join_counters maps.
///
/// `cancelled_branch_ids`' outer slice is duped per call, but the
/// individual branch_id strings are shared across every generation
/// (transition() dupes only the array of slice headers, not their
/// contents) — so only the outer array is freed here, never the strings.
pub fn freeInstanceState(allocator: std.mem.Allocator, state: InstanceState) void {
    for (state.tokens) |t| {
        allocator.free(t.node_id);
        allocator.free(t.branch_id);
        if (t.token_id) |tid| allocator.free(tid);
        if (t.waiting_child_instance_id) |w| allocator.free(w);
    }
    allocator.free(state.tokens);

    var vars = state.variables;
    freeJsonValueSafe(allocator, std.json.Value{ .object = vars });
    _ = &vars;

    var jc = state.join_counters;
    freeJsonValueSafe(allocator, std.json.Value{ .object = jc });
    _ = &jc;

    for (state.pending_task_nodes) |n| allocator.free(n);
    allocator.free(state.pending_task_nodes);

    if (state.error_detail) |ed| allocator.free(ed);

    if (state.cancelled_branch_ids.len > 0) allocator.free(state.cancelled_branch_ids);
}

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
    // ISS-0601: keys must be heap-duped (not string literals) — this
    // object is freed via freeJsonValueSafe on overwrite/state cleanup,
    // which calls allocator.free() on every object key.
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer obj.deinit(allocator);
    const rc_key = try allocator.dupe(u8, "received_count");
    errdefer allocator.free(rc_key);
    try obj.put(allocator, rc_key, std.json.Value{ .integer = @as(i64, new_received) });
    const eb_key = try allocator.dupe(u8, "expected_from_branches");
    errdefer allocator.free(eb_key);
    try obj.put(allocator, eb_key, std.json.Value{ .integer = @as(i64, new_expected) });

    // ISS-0601: getOrPut + free-on-overwrite — a plain put() with a fresh
    // key_dup would leak both the previous key and the previous nested
    // {received_count, expected_from_branches} object every time this
    // join node's counter is updated again.
    const gop = try state.join_counters.getOrPut(allocator, node_id);
    if (gop.found_existing) {
        freeJsonValueSafe(allocator, gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, node_id);
    }
    gop.value_ptr.* = std.json.Value{ .object = obj };

    return JoinCounter{
        .received_count = new_received,
        .expected_from_branches = new_expected,
    };
}

/// Reset a join counter entry after the join fires.
/// Sets received_count to 0 so subsequent getJoinCounter sees a fresh counter.
/// Cannot remove from ArrayHashMap (Zig 0.16 no remove method), so we overwrite.
fn clearJoinCounter(allocator: std.mem.Allocator, state: *InstanceState, node_id: []const u8) !void {
    // Overwrite with sentinel zero values — getJoinCounter treats 0/0 as fresh.
    // ISS-0601: keys must be heap-duped — see updateJoinCounter.
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer obj.deinit(allocator);
    const rc_key = try allocator.dupe(u8, "received_count");
    errdefer allocator.free(rc_key);
    try obj.put(allocator, rc_key, std.json.Value{ .integer = 0 });
    const eb_key = try allocator.dupe(u8, "expected_from_branches");
    errdefer allocator.free(eb_key);
    try obj.put(allocator, eb_key, std.json.Value{ .integer = 0 });

    // ISS-0601: getOrPut + free-on-overwrite — see updateJoinCounter.
    const gop = try state.join_counters.getOrPut(allocator, node_id);
    if (gop.found_existing) {
        freeJsonValueSafe(allocator, gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, node_id);
    }
    gop.value_ptr.* = std.json.Value{ .object = obj };
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
// Helper function for safe ObjectMap updates
// ---------------------------------------------------------------------------

/// Safely put a key-value pair into a JsonValue ObjectMap, freeing the old value if the key already exists.
/// ISS-0601: Prevents memory leaks when updating variables in cloned ObjectMaps.
fn putVariableSafe(
    allocator: std.mem.Allocator,
    map: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const gop = try map.getOrPut(allocator, key);
    if (gop.found_existing) {
        // Free the old value before replacing.
        freeJsonValueSafe(allocator, gop.value_ptr.*);
        // ISS-0158 / GH #479: on the found_existing path getOrPut KEEPS the
        // key already in the map and leaves `key` (which callers allocate
        // fresh, e.g. `allocator.dupe(u8, "effect_result")` in the
        // .effect_completed arm) unreferenced. Nothing freed it, so every
        // overwrite of an existing variable leaked its key. Callers hand
        // ownership of `key` to this function unconditionally, so free the
        // redundant copy here rather than making each call site branch.
        allocator.free(key);
    }
    gop.value_ptr.* = value;
}

/// Helper to free a JsonValue - mirrors reconstruction.zig's freeJsonValue
fn freeJsonValueSafe(allocator: std.mem.Allocator, value: std.json.Value) void {
    var mutable_value = value;
    switch (mutable_value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| freeJsonValueSafe(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValueSafe(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
        else => {},
    }
}

/// Deep-clone a JsonValue: duplicates strings and recursively clones
/// arrays/objects (including their keys) so the result shares no memory
/// with the source. Mirrors reconstruction.zig's cloneJsonValue.
///
/// ISS-0601: `std.json.ObjectMap.clone()` is a SHALLOW clone — it copies
/// the hash-table bucket storage but keys/values remain aliased with the
/// source map. Using putVariableSafe's free-on-overwrite against a
/// shallow-cloned map frees memory the source state still points to,
/// causing a use-after-free that (at high event volumes) corrupts the
/// allocator's internal structures.
fn cloneJsonValueSafe(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.init(allocator);
            errdefer {
                for (new_arr.items) |item| freeJsonValueSafe(allocator, item);
                new_arr.deinit();
            }
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                const cloned = try cloneJsonValueSafe(allocator, item);
                new_arr.appendAssumeCapacity(cloned);
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = try cloneObjectMapSafe(allocator, obj);
            errdefer freeJsonValueSafe(allocator, std.json.Value{ .object = new_obj });
            _ = &new_obj;
            break :blk .{ .object = new_obj };
        },
        else => value,
    };
}

/// Deep-clone a JsonValue ObjectMap: duplicates every key and deep-clones
/// every value so the result shares no memory with the source map.
/// ISS-0601: required so `new_state.variables`/`join_counters` fully own
/// their memory and can be safely mutated (freed-on-overwrite) without
/// affecting the state they were cloned from.
fn cloneObjectMapSafe(allocator: std.mem.Allocator, source: std.json.ObjectMap) error{OutOfMemory}!std.json.ObjectMap {
    var result = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeJsonValueSafe(allocator, entry.value_ptr.*);
        }
        result.deinit(allocator);
    }
    var it = source.iterator();
    while (it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);
        const cloned_value = try cloneJsonValueSafe(allocator, entry.value_ptr.*);
        errdefer freeJsonValueSafe(allocator, cloned_value);
        try result.put(allocator, key_copy, cloned_value);
    }
    return result;
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
        // ISS-0601: deep-clone (not .clone(), which shallow-copies and
        // aliases keys/values with `state`) so new_state fully owns its
        // variable/join-counter memory — see cloneObjectMapSafe above.
        .variables = try cloneObjectMapSafe(allocator, state.variables),
        .join_counters = try cloneObjectMapSafe(allocator, state.join_counters),
        .pending_task_nodes = try allocator.alloc([]const u8, state.pending_task_nodes.len),
        .error_detail = null,
        .cancelled_branch_ids = try allocator.dupe([]const u8, state.cancelled_branch_ids),
    };
    for (state.tokens, 0..) |t, i| {
        var token_id_copy: ?[]const u8 = null;
        if (t.token_id) |tid| {
            token_id_copy = try allocator.dupe(u8, tid);
        }
        // GH #428: waiting_child_instance_id was previously dropped here,
        // silently discarding a token's "parked waiting on child sub-process"
        // state on every transition() call (not just sub_process_completed) —
        // any token waiting on a SUB_PROCESS child could never be matched by
        // the sub_process_completed handler below (token_idx would always be
        // null) because the field was reset to its default (null) instead of
        // being carried over. See freeInstanceState (line ~161), which frees
        // it, and the sub_process_completed handler (line ~866), which reads
        // it — both assume it survives the clone.
        var waiting_child_copy: ?[]const u8 = null;
        if (t.waiting_child_instance_id) |w| {
            waiting_child_copy = try allocator.dupe(u8, w);
        }
        new_state.tokens[i] = Token{
            .node_id = try allocator.dupe(u8, t.node_id),
            .branch_id = try allocator.dupe(u8, t.branch_id),
            .token_id = token_id_copy,
            .waiting_child_instance_id = waiting_child_copy,
        };
    }
    for (state.pending_task_nodes, 0..) |n, i| {
        new_state.pending_task_nodes[i] = try allocator.dupe(u8, n);
    }

    var emitted_events = std.ArrayList(PendingEvent).empty;
    defer emitted_events.deinit(allocator);

    const result_state = switch (event) {
        .instance_started => |payload| blk: {
            // Seed variables from initial_variables.
            // ISS-0601: deep-clone — payload.initial_variables may be
            // parsed from a temporary/arena allocator (see
            // reconstruction.zig's mapToTransitionEvent), so a shallow
            // .clone() would alias keys/values that get freed once the
            // arena is torn down. Free the placeholder clone made above
            // (from state.variables) first, to avoid leaking it.
            freeJsonValueSafe(allocator, std.json.Value{ .object = new_state.variables });
            new_state.variables = try cloneObjectMapSafe(allocator, payload.initial_variables);
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
                    try putVariableSafe(allocator, &new_state.variables, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            // Remove from pending_task_nodes
            var new_pending = std.ArrayList([]const u8).empty;
            defer new_pending.deinit(allocator);
            var dropped_pending: ?[]const u8 = null;
            for (new_state.pending_task_nodes) |n| {
                if (!std.mem.eql(u8, n, payload.task_node_id)) {
                    try new_pending.append(allocator, n);
                } else {
                    dropped_pending = n;
                }
            }
            {
                const old_pending_array = new_state.pending_task_nodes;
                new_state.pending_task_nodes = try new_pending.toOwnedSlice(allocator);
                // ISS-0601: surviving entries were moved by value into the
                // new array; free the stale outer array once nothing
                // references it. The one dropped entry's string is freed
                // last, after the array holding it is gone.
                allocator.free(old_pending_array);
                if (dropped_pending) |dp| allocator.free(dp);
            }
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

                    var transform_obj_mut = transform_obj;
                    var transform_it = transform_obj_mut.iterator();
                    while (transform_it.next()) |entry| {
                        try putVariableSafe(allocator, &new_state.variables, entry.key_ptr.*, entry.value_ptr.*);
                    }
                    // Keys/values were moved into new_state.variables above
                    // (putVariableSafe stores them directly); only the map's
                    // own bucket storage needs freeing here.
                    transform_obj_mut.deinit(allocator);
                }
            }

            {
                const old_tok_node_id = new_state.tokens[token_idx.?].node_id;
                new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
                allocator.free(old_tok_node_id);
            }
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
                try putVariableSafe(allocator, &new_state.variables, entry.key_ptr.*, entry.value_ptr.*);
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

                    var transform_obj_mut = transform_obj;
                    var transform_it = transform_obj_mut.iterator();
                    while (transform_it.next()) |entry| {
                        try putVariableSafe(allocator, &new_state.variables, entry.key_ptr.*, entry.value_ptr.*);
                    }
                    // Keys/values were moved into new_state.variables above
                    // (putVariableSafe stores them directly); only the map's
                    // own bucket storage needs freeing here.
                    transform_obj_mut.deinit(allocator);
                }
            }

            {
                const old_tok_node_id = new_state.tokens[token_idx.?].node_id;
                new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
                allocator.free(old_tok_node_id);
            }
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

            if (new_state.tokens[token_idx.?].waiting_child_instance_id) |old_w| allocator.free(old_w);
            new_state.tokens[token_idx.?].waiting_child_instance_id = null;
            {
                const old_tok_node_id = new_state.tokens[token_idx.?].node_id;
                new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
                allocator.free(old_tok_node_id);
            }
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
                // ISS-0158 / GH #479: dupe the body too. `payload` is borrowed
                // from the caller's event, but every value in `variables` is
                // freed by freeJsonValueSafe/freeInstanceState — storing the
                // borrowed slice would hand the state's teardown a pointer it
                // does not own (double-free / free-of-borrowed-memory).
                const body_dup = try allocator.dupe(u8, body);
                errdefer allocator.free(body_dup);
                try putVariableSafe(allocator, &new_state.variables, key_dup, std.json.Value{ .string = body_dup });
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
            {
                const old_tok_node_id = new_state.tokens[token_idx.?].node_id;
                new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, next_node_id);
                allocator.free(old_tok_node_id);
            }
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
                if (!std.mem.eql(u8, t.node_id, node_id_from_key)) {
                    // Surviving tokens are moved by value — their fields keep
                    // the same owner, so do not free them here.
                    try surviving.append(allocator, t);
                } else {
                    // ISS-0158 / GH #479: the token parked on the failed
                    // SERVICE_TASK is dropped here. Its fields are
                    // allocator-owned per the ISS-0601 ownership contract and
                    // nothing else references them, so dropping it without
                    // freeing leaked node_id/branch_id/token_id on EVERY
                    // effect failure. TC-EXP-302-04 and TC-EXP-302-08 catch it.
                    allocator.free(t.node_id);
                    allocator.free(t.branch_id);
                    if (t.token_id) |tid| allocator.free(tid);
                    if (t.waiting_child_instance_id) |w| allocator.free(w);
                }
            }
            // ISS-0158 / GH #479: free the stale outer array too — its
            // elements have either been moved into `surviving` or freed above.
            allocator.free(new_s.tokens);
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
            // ISS-0601: deep-clone — `value` lives inside the caller's
            // `variables` map (new_state.variables). A shallow .clone()
            // would alias keys/values with it; callers drain the result
            // into new_state.variables via putVariableSafe, which frees
            // on overwrite and would then free memory new_state.variables
            // itself still owns.
            .object => |obj| cloneObjectMapSafe(allocator, obj) catch error.OutOfMemory,
            else => error.TransformResultNonObject,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, expression, .{}) catch
        return error.TransformEvaluationFailed;
    defer parsed.deinit();

    return switch (parsed.value) {
        // parsed.value's memory belongs to `parsed` (freed by defer above),
        // so this must also be a deep clone, not a shallow one.
        .object => |obj| cloneObjectMapSafe(allocator, obj) catch error.OutOfMemory,
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
            if (!active) {
                // GH #428: every token here is being discarded — the one
                // that just arrived at this END node was filtered out of
                // new_tokens above, and everything still in new_tokens.items
                // is (per the `active` check) itself parked on some END node
                // too and about to be replaced with an empty slice. Free the
                // full original state.tokens set (which per the ISS-0601
                // ownership contract is always allocator-owned) before
                // discarding, or every field on every token leaks whenever
                // an instance completes with more than zero tokens present.
                for (state.tokens) |t| {
                    allocator.free(t.node_id);
                    allocator.free(t.branch_id);
                    if (t.token_id) |tid| allocator.free(tid);
                    if (t.waiting_child_instance_id) |w| allocator.free(w);
                }
                allocator.free(state.tokens);
                new_state.status = .COMPLETED;
                new_state.tokens = &[_]Token{};
            } else {
                // ISS-0158 / GH #479: some OTHER branch is still active, so the
                // instance does not complete — but the token that just arrived
                // at this END node was still filtered out of `new_tokens`
                // above and is being discarded. Only the `!active` arm freed
                // discarded tokens, so on this path its allocator-owned fields
                // leaked on every END arrival that did not finish the
                // instance. TC-EXP-302-08 (parallel branches, left completes
                // while right is still running) catches exactly this.
                for (state.tokens) |t| {
                    if (std.mem.eql(u8, t.node_id, node_id)) {
                        allocator.free(t.node_id);
                        allocator.free(t.branch_id);
                        if (t.token_id) |tid| allocator.free(tid);
                        if (t.waiting_child_instance_id) |w| allocator.free(w);
                    }
                }
                // Surviving tokens were copied by value into new_tokens (same
                // field pointers), so only the stale outer array is freed.
                allocator.free(state.tokens);
                new_state.tokens = try new_tokens.toOwnedSlice(allocator);
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
                // ISS-0601: every entry was moved by value into the new
                // array; only the stale outer array needs freeing.
                allocator.free(state.pending_task_nodes);
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
            {
                const old_tok_node_id = new_state.tokens[token_idx.?].node_id;
                new_state.tokens[token_idx.?].node_id = try allocator.dupe(u8, chosen.?.target);
                allocator.free(old_tok_node_id);
            }
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

                // ISS-0149 / GitHub #465: the token that ARRIVED at this gateway was
                // filtered out of `new_tokens` at the top of this branch and is
                // replaced by the freshly-allocated per-edge tokens above — nothing
                // downstream ever sees it again. Its fields are allocator-owned per
                // the ISS-0601 ownership contract, and `state.tokens`' outer array is
                // likewise owned and about to be superseded by `toOwnedSlice`, so both
                // must be released here or every parallel split leaks the arriving
                // token's node_id + branch_id + token_id plus the old array.
                //
                // Surviving tokens were appended into `new_tokens` BY VALUE (same
                // field pointers), so only the dropped token's fields may be freed —
                // never the survivors'. This mirrors what the JOIN branch below
                // already does for the same reason.
                for (state.tokens) |t| {
                    if (!std.mem.eql(u8, t.node_id, node_id)) continue;
                    allocator.free(t.node_id);
                    allocator.free(t.branch_id);
                    if (t.token_id) |tid| allocator.free(tid);
                    if (t.waiting_child_instance_id) |w| allocator.free(w);
                }
                allocator.free(state.tokens);

                new_state.tokens = try new_tokens.toOwnedSlice(allocator);

                // GH #428: snapshot the target node_ids to visit BEFORE
                // recursing, and iterate that snapshot — not new_state.tokens
                // directly. `for (new_state.tokens) |t|` captures the slice
                // header once at loop entry; each processNodeEntry call below
                // can return a brand-new InstanceState (different .tokens
                // backing array) and, since the GH #428 END/join-fire fixes,
                // may now genuinely free the previous one. Continuing to read
                // `t` from the original (now-freed) slice on the next
                // iteration was a real use-after-free — TC-EE-03-05 (a
                // 2-branch split where both branches terminate at END)
                // caught it: processing the first branch could complete the
                // instance and free the whole original token array,
                // including the second branch's still-unvisited node_id.
                // These strings must be dupe'd, not just referenced, because
                // the very InstanceState that owns the original t.node_id
                // memory (`new_state` before the first processNodeEntry call)
                // is exactly what gets superseded/freed by that call.
                var visit_targets = std.ArrayList([]const u8).empty;
                defer {
                    for (visit_targets.items) |vt| allocator.free(vt);
                    visit_targets.deinit(allocator);
                }
                for (new_state.tokens) |t| {
                    if (std.mem.eql(u8, t.node_id, node_id)) continue;
                    try visit_targets.append(allocator, try allocator.dupe(u8, t.node_id));
                }
                for (visit_targets.items) |target_node_id| {
                    new_state = try processNodeEntry(allocator, snapshot, new_state, target_node_id, events);
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

                    // GH #428: the stray/arrived tokens on the join node are
                    // being discarded here (replaced with an empty slice) —
                    // free them first, or every token parked on a join that
                    // cascades to ALL_BRANCHES_CANCELLED leaks in production.
                    // join_state.tokens is state.tokens at this point (never
                    // reassigned above), and state.tokens is always allocator-
                    // owned per the ISS-0601 ownership contract (transition()
                    // deep-clones every token before calling processNodeEntry).
                    for (join_state.tokens) |t| {
                        allocator.free(t.node_id);
                        allocator.free(t.branch_id);
                        if (t.token_id) |tid| allocator.free(tid);
                        if (t.waiting_child_instance_id) |w| allocator.free(w);
                    }
                    allocator.free(join_state.tokens);

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

                // GH #428: every token that WAS on join_state.tokens has now
                // either been merged away or (tokens not on this join node)
                // copied by value into new_tokens. join_state.tokens itself
                // — the original outer slice — is fully superseded here and
                // must be freed, or every token that arrives at a firing
                // PARALLEL_GATEWAY join leaks (fields + outer array).
                //
                // branch_id is the one exception: arrived_ids captured each
                // consumed token's branch_id BY REFERENCE (not a dupe — see
                // `try arrived_ids.append(allocator, t.branch_id)` above),
                // and that array is now owned by join_event.parallel_join.
                // branch_ids_arrived, which outlives this function. Freeing
                // t.branch_id here would leave branch_ids_arrived pointing
                // at freed memory — ownership of that specific string
                // transfers to the event instead of being freed with the
                // token. node_id/token_id/waiting_child_instance_id were
                // never captured anywhere else, so those are safe to free.
                for (join_state.tokens) |t| {
                    if (std.mem.eql(u8, t.node_id, node_id)) {
                        allocator.free(t.node_id);
                        if (t.token_id) |tid| allocator.free(tid);
                        if (t.waiting_child_instance_id) |w| allocator.free(w);
                    }
                    // Tokens NOT on this join node were copied by value into
                    // new_tokens (same pointers) — do not free their fields,
                    // only the stale outer array below.
                }
                allocator.free(join_state.tokens);

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
            // ISS-0158 / GH #479: parseEffectKind returns a static string
            // literal; dupe it so `kind` is allocator-owned like every other
            // field of EffectEmittedPayload. Freeing a .rdata literal
            // segfaults — see the ownership note on EffectEmittedPayload.
            const kstr = try allocator.dupe(u8, parseEffectKind(node_attrs));
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

    // GH #428: must not collapse OutOfMemory into InvalidTimerConfig — a
    // caller (e.g. std.testing.checkAllAllocationFailures) that specifically
    // needs to see OutOfMemory propagate would otherwise get a misleading
    // "invalid config" error on an allocation failure that had nothing to do
    // with the JSON being malformed.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTimerConfig,
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
    // GH #428: if repeat_expression was duped above and the duration_iso8601
    // dupe below then fails (OutOfMemory), repeat_expression was leaked —
    // TC-ISS-0132-01 catches exactly this via checkAllAllocationFailures.
    errdefer if (repeat_expression) |r| allocator.free(r);

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

    // GH #428: same OutOfMemory-preservation fix as parseTimerConfig above —
    // do not collapse an allocation failure into a "config is invalid" error.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSubProcessConfig,
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
// GH #428 test-fixture helper
//
// processNodeEntry()/transition() free or reallocate token/state fields they
// don't need to keep unchanged (see freeInstanceState above and the
// ISS-0601 doc comment on it) — production callers always pass allocator-
// owned InstanceState because it always originates from a prior transition()
// call or a DB row deserialization. Test fixtures that build tokens from
// string literals instead (`.node_id = "gw"`) violate that assumption: a
// literal is never safe to pass to allocator.free, so any code path that
// replaces-and-frees a token field (e.g. EXCLUSIVE_GATEWAY advancing
// `tokens[i].node_id`) segfaults on a literal-backed fixture.
//
// It is not enough to heap-dupe each Token's *fields* — the outer `[]Token`
// slice itself must also come from the allocator. A fixture written as
// `var __toks = [_]Token{...}; state.tokens = &__toks;` puts a pointer to a
// *stack* array in state.tokens: several processNodeEntry paths return that
// same pointer unchanged (EXCLUSIVE_GATEWAY mutates it in place; the join
// "park" path returns it untouched), and freeInstanceState unconditionally
// calls `allocator.free(state.tokens)`. Freeing a stack address panics with
// "Invalid free" (DebugAllocator canary check) because the allocator never
// handed that address out. dupeTokenSlice() below allocates the outer slice
// with the allocator so that free is always valid — use it instead of a
// `var __toks = [_]Token{...}` array wherever the result will be passed to
// freeInstanceState.
//
// The identical trap applies to `pending_task_nodes` (and, when non-empty,
// `cancelled_branch_ids`): freeInstanceState/processNodeEntry free those
// outer slices unconditionally or pass them through unchanged too. A
// fixture built as `var __x = [_][]const u8{};` is a stack-local array —
// syntactically it looks like the struct's own zero-length default
// (`&[_][]const u8{}`), but only the latter is a compile-time-constant that
// Zig's allocator special-cases as safe to "free" as a no-op (see
// Allocator.allocBytesWithAlignment: byte_count == 0 returns a sentinel
// pointer that free() recognizes and skips). emptyOwnedStrSlice() below
// allocates a genuine (if zero-length) heap slice so the free is always
// valid regardless of which special case applies.
//
// dupeTokenSlice/emptyOwnedStrSlice give tests a one-line way to build
// heap-owned fixtures so `defer freeInstanceState(allocator, result)` is
// always safe to call on whatever processNodeEntry/transition returns. This
// is a test-fixture-only convenience — it changes nothing about
// processNodeEntry's or transition's own ownership contract.
// ---------------------------------------------------------------------------
const TokenSpec = struct { node_id: []const u8, branch_id: []const u8 };

/// Allocate a heap-owned []Token (both the outer slice and every token's
/// node_id/branch_id) from a comptime-known list of (node_id, branch_id)
/// pairs. Free with freeOwnedTokenSlice, or implicitly via freeInstanceState
/// once the slice has been installed as an InstanceState.tokens field and
/// passed through processNodeEntry/transition.
fn dupeTokenSlice(allocator: std.mem.Allocator, specs: []const TokenSpec) ![]Token {
    const toks = try allocator.alloc(Token, specs.len);
    errdefer allocator.free(toks);
    for (specs, 0..) |spec, i| {
        toks[i] = Token{
            .node_id = try allocator.dupe(u8, spec.node_id),
            .branch_id = try allocator.dupe(u8, spec.branch_id),
        };
    }
    return toks;
}

/// A genuinely heap-allocated (if zero-length) []const u8 slice-of-slices,
/// safe to hand to a field that freeInstanceState frees unconditionally
/// (pending_task_nodes) — see the doc comment above for why a plain `var
/// __x = [_][]const u8{}` stack array is NOT safe there.
fn emptyOwnedStrSlice(allocator: std.mem.Allocator) ![][]const u8 {
    return allocator.alloc([]const u8, 0);
}

/// Free every heap allocation inside a single PendingEvent payload. Mirrors
/// (and is the missing counterpart to) freeInstanceState, scoped to the
/// PendingEvent union.
///
/// ISS-0149 / GitHub #465: this used to be documented as "test-only", with a note
/// that `src/engine/instance.zig`'s `freeOwnedTransitionState` "currently frees only
/// the outer EmittedEvent.idempotency_key and does not walk into payload internals."
/// That gap WAS the production leak — it is now closed: `freeOwnedTransitionState`
/// delegates to `freeTransitionResult`, which reaches this function for every
/// emitted event. So this is production teardown, not a test helper.
fn freePendingEventPayload(allocator: std.mem.Allocator, payload: PendingEvent) void {
    switch (payload) {
        .parallel_split => |p| {
            allocator.free(p.source_node_id);
            // GH #428: token_ids[i] and target_node_ids[i] are the SAME
            // pointers as the split-created result.tokens[i].branch_id/
            // node_id (processNodeEntry appends the identical branch_id/
            // target allocation to both the new Token and this event's
            // tracking arrays — see the PARALLEL_GATEWAY split case around
            // line 1454). freeInstanceState(result) already frees those
            // strings via the token fields; freeing them again here via the
            // outer arrays' elements would double-free. Only the two outer
            // slices (the arrays of pointers) belong to this payload alone.
            allocator.free(p.token_ids);
            allocator.free(p.target_node_ids);
            var vars = p.variables_snapshot;
            freeJsonValueSafe(allocator, std.json.Value{ .object = vars });
            _ = &vars;
        },
        .parallel_join => |p| {
            allocator.free(p.join_node_id);
            // GH #428: unlike parallel_split's token_ids/target_node_ids
            // (which alias the *merged* token's fields, freed via
            // freeInstanceState), branch_ids_arrived[i] alias the *consumed*
            // tokens' branch_id — tokens that no longer exist in any
            // InstanceState after the join fires (processNodeEntry's
            // PARALLEL_GATEWAY join STEP e frees their node_id but
            // deliberately leaves branch_id owned by this event — see that
            // fix's comment). So here, unlike the split case, the elements
            // DO need freeing individually, not just the outer array.
            for (p.branch_ids_arrived) |b| allocator.free(b);
            allocator.free(p.branch_ids_arrived);
            allocator.free(p.branch_ids_cancelled);
            allocator.free(p.outgoing_token_id);
        },
        .instance_cancelled => |p| {
            if (p.join_node_id) |j| allocator.free(j);
            allocator.free(p.branch_ids_cancelled);
        },
        .timer_created => |p| {
            allocator.free(p.timer_node_id);
            // GH #428: duration_iso8601/repeat_expression are moved directly
            // from parseTimerConfig's return value into this payload (not
            // re-duped, not aliased with anything else in state) — the
            // payload is their sole owner. Missing this was the specific
            // leak TC-SCH-01-01 caught.
            allocator.free(p.duration_iso8601);
            if (p.repeat_expression) |r| allocator.free(r);
            allocator.free(p.token_branch_id);
            allocator.free(p.payload_json);
        },
        .sub_process_start => |p| {
            allocator.free(p.parent_node_id);
            allocator.free(p.parent_branch_id);
            // GH #428: child_definition_id is moved directly from
            // parseSubProcessConfig's return value — this payload is its
            // sole owner. Missing this was the leak TC-EXT-05-UT-01 caught.
            allocator.free(p.child_definition_id);
        },
        .effect_emitted => |p| {
            allocator.free(p.node_id);
            allocator.free(p.token_id);
            allocator.free(p.correlation_key);
            // ISS-0158 / GH #479: `kind` is now duped at the emit site (it used
            // to alias a static literal, so freeing it here would have
            // segfaulted). It is allocator-owned like its siblings — freeing it
            // is required, or every SERVICE_TASK activation leaks it.
            allocator.free(p.kind);
            allocator.free(p.spec_json);
        },
    }
}

/// Free every PendingEvent in a raw events list collected directly from
/// processNodeEntry (as opposed to the EmittedEvent-wrapped list transition()
/// returns — see freeEmittedEvents below for that case).
fn freePendingEvents(allocator: std.mem.Allocator, events: []const PendingEvent) void {
    for (events) |ev| freePendingEventPayload(allocator, ev);
}

/// Free a transition()-returned TransitionResult in full: state (via
/// freeInstanceState) plus every EmittedEvent's idempotency_key and payload,
/// plus the emitted_events slice itself.
///
/// ISS-0149 / GitHub #465: made `pub` so `src/engine/instance.zig` can call the
/// canonical teardown instead of maintaining its own partial copy. Its private
/// version freed only `idempotency_key`, never `payload`, so every allocation
/// `freePendingEventPayload` handles above (a TIMER node's `duration_iso8601`,
/// a SERVICE_TASK's `spec_json`, a sub-process's `child_definition_id`, …) was
/// leaked on the production `create()`/`advance()` path.
pub fn freeTransitionResult(allocator: std.mem.Allocator, result: TransitionResult) void {
    for (result.emitted_events) |ev| {
        allocator.free(ev.idempotency_key);
        freePendingEventPayload(allocator, ev.payload);
    }
    allocator.free(result.emitted_events);
    freeInstanceState(allocator, result.state);
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
    var __tokens_1 = [_]Token{};
    var __pending_task_nodes_2 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_1,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_2,
        .error_detail = null,
    };
    var initial_vars = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer initial_vars.deinit(allocator);
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };
    const result = transition(allocator, graph, state, event, 1) catch unreachable;
    defer freeTransitionResult(allocator, result);
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
    var __tokens_3 = [_]Token{.{ .node_id = "task1", .branch_id = "b" }};
    var __pending_task_nodes_4 = [_][]const u8{"task1"};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_3,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_4,
        .error_detail = null,
    };
    var output_vars = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer output_vars.deinit(allocator);
    const event = TransitionEvent{ .task_completed = .{
        .task_node_id = "task1",
        .output_variables = output_vars,
    } };
    const result = transition(allocator, graph, state, event, 1) catch unreachable;
    defer freeTransitionResult(allocator, result);
    // GH #428: this assertion was stale — it predates (or never actually ran
    // against) the END-node completion behavior that TC-EE-02-03 verifies
    // directly: when a token reaches END and no other active (non-END) token
    // remains, processNodeEntry clears tokens to empty and sets status to
    // COMPLETED rather than leaving a token parked on "end". The task_completed
    // event here is the only token in the instance, its edge leads straight to
    // END, so the instance completes: 0 tokens, status COMPLETED.
    try std.testing.expect(result.state.tokens.len == 0);
    try std.testing.expect(result.state.status == .COMPLETED);
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
    // GH #428: allocator-owned — the END-node "all tokens discarded, status
    // -> COMPLETED" path now frees state.tokens (fields + outer slice)
    // before replacing it with &[_]Token{}, matching the ISS-0601 ownership
    // contract (state.tokens is always allocator-owned in production, since
    // it always originates from transition()'s deep-clone). See the fix's
    // comment in processNodeEntry's .END case for the leak this closes.
    const __tokens_5 = try dupeTokenSlice(allocator, &.{.{ .node_id = "end", .branch_id = "b" }});
    const __pending_task_nodes_6 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_5,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_6,
        .error_detail = null,
    };
    // event is unused in this test
    // Directly test processNodeEntry for END
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result = processNodeEntry(allocator, graph, state, "end", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    var initial_vars = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer initial_vars.deinit(allocator);

    var __tokens_7 = [_]Token{};
    var __pending_task_nodes_8 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_7,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_8,
        .error_detail = null,
    };
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };

    const tr = try transition(allocator, graph, state, event, 1);
    defer freeTransitionResult(allocator, tr);
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
    // GH #428: must be allocator-owned (both the outer slice AND each
    // token's fields), not a string literal or a stack array — the
    // EXCLUSIVE_GATEWAY path below replaces tokens[idx].node_id in place and
    // frees the previous value (allocator.free(old_tok_node_id)); freeing a
    // literal segfaults (see dupeTokenSlice doc comment above). Note:
    // EXCLUSIVE_GATEWAY mutates state.tokens in place and returns the same
    // backing slice (new_state = state is a shallow copy), so `result.tokens`
    // here *is* `__tokens_9` — freeing via freeInstanceState(result) below is
    // the only free needed; a second free of __tokens_9 would double-free.
    const __tokens_9 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    // GH #428: heap-allocated (even though zero-length) — freeInstanceState
    // unconditionally frees pending_task_nodes with no length guard, and a
    // stack-local `var [_][]const u8{}` is not the same safe-to-free address
    // as the struct's own zero-length default. See emptyOwnedStrSlice's doc
    // comment above for the full explanation.
    const __pending_task_nodes_10 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_9,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_10,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    var __tokens_11 = [_]Token{.{ .node_id = "gw", .branch_id = "b" }};
    var __pending_task_nodes_12 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_11,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_12,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
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
    // GH #428: allocator-owned — see TC-EE-02-04's comment for why (this is
    // the other EXCLUSIVE_GATEWAY test that segfaulted on a literal node_id).
    const __tokens_13 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    const __pending_task_nodes_14 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_13,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_14,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // PARALLEL_GATEWAY split filters the arriving token out of the new token
    // array by value (doesn't free/reuse its fields), so a literal here is
    // safe from a crash standpoint — but the *new* split tokens are freshly
    // allocator.dupe'd and must be freed via freeInstanceState below.
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_15 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    const __pending_task_nodes_16 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_15,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_16,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
    defer freePendingEvents(allocator, events.items);
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
    // GH #428: allocator-owned tokens — the "park and wait" path returns
    // join_state with state.tokens unchanged (aliased, not reallocated), so
    // freeInstanceState(result1) below would try to free literal strings if
    // these weren't heap-owned.
    const __tokens_17 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b1" }});
    const __pending_task_nodes_18 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_17,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_18,
        .error_detail = null,
    };
    // Not all arrived, should park
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result1 = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result1);
    try std.testing.expect(result1.tokens.len == 1);
    // Now both tokens arrive
    const __tokens_19 = try dupeTokenSlice(allocator, &.{
        .{ .node_id = "gw", .branch_id = "b1" },
        .{ .node_id = "gw", .branch_id = "b2" },
    });
    const __pending_task_nodes_20 = try emptyOwnedStrSlice(allocator);
    const state2 = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_19,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_20,
        .error_detail = null,
    };
    var events2 = std.ArrayList(PendingEvent).empty;
    // defer executes LIFO: register deinit first so freePendingEvents (which
    // needs events2.items still populated) runs before the backing buffer
    // is freed.
    defer events2.deinit(allocator);
    defer freePendingEvents(allocator, events2.items);
    const result2 = processNodeEntry(allocator, graph, state2, "gw", &events2) catch unreachable;
    defer freeInstanceState(allocator, result2);
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
    var __tokens_21 = [_]Token{};
    var __pending_task_nodes_22 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_21,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_22,
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
    var __tokens_23 = [_]Token{.{ .node_id = "missing", .branch_id = "b" }};
    var __pending_task_nodes_24 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_23,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_24,
        .error_detail = null,
    };
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
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
    var __tokens_25 = [_]Token{};
    var __pending_task_nodes_26 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_25,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_26,
        .error_detail = null,
    };
    var initial_vars = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer initial_vars.deinit(allocator);
    const event = TransitionEvent{ .instance_started = .{
        .initial_variables = initial_vars,
        .start_node_id = "start",
    } };
    const result1 = transition(allocator, graph, state, event, 1) catch unreachable;
    defer freeTransitionResult(allocator, result1);
    const result2 = transition(allocator, graph, state, event, 1) catch unreachable;
    defer freeTransitionResult(allocator, result2);
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
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_27 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    const __pending_task_nodes_28 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_27,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_28,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_29 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    const __pending_task_nodes_30 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_29,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_30,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_31 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "arriving" }});
    const __pending_task_nodes_32 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_31,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_32,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_33 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw", .branch_id = "b" }});
    const __pending_task_nodes_34 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_33,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_34,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = processNodeEntry(allocator, graph, state, "gw", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // ISS-0149 / GH #465: processNodeEntry now frees the arriving token that the
    // PARALLEL_GATEWAY split drops, per the ISS-0601 "tokens are always
    // allocator-owned" contract. A stack array of string literals cannot be freed,
    // so this fixture must be heap-owned like its siblings above.
    const __tokens_35 = try dupeTokenSlice(allocator, &.{.{ .node_id = "gw2", .branch_id = "b" }});
    const __pending_task_nodes_36 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_35,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_36,
        .error_detail = null,
    };
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = processNodeEntry(allocator, graph, state, "gw2", &events) catch unreachable;
    defer freeInstanceState(allocator, result);
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
    // GH #428: processNodeEntry (unlike transition()) never reallocates
    // cancelled_branch_ids — it passes the outer slice through unchanged.
    // freeInstanceState always frees that outer slice (never the strings
    // inside it — see its doc comment), so the outer slice itself must be
    // heap-owned here, not a stack-local array, or freeInstanceState(result)
    // below would free stack memory. The join-fire path also now frees
    // every token consumed by the merge (see the fix in processNodeEntry's
    // PARALLEL_GATEWAY join STEP e), so __tokens_37's fields must be
    // heap-owned too, not literal-backed.
    const __tokens_37 = try dupeTokenSlice(allocator, &.{.{ .node_id = "join_gw", .branch_id = branch_1 }});
    const __pending_task_nodes_38 = try emptyOwnedStrSlice(allocator);
    const __cbi_1 = try allocator.dupe([]const u8, &[_][]const u8{branch_0});
    const state = InstanceState{
        .instance_id = instance_id,
        .status = .ACTIVE,
        .tokens = __tokens_37,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_38,
        .error_detail = null,
        .cancelled_branch_ids = __cbi_1,
    };

    // processNodeEntry: expected_count = 2 - 1 = 1, arrived = 1 → FIRE.
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);
    defer freeInstanceState(allocator, result);

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
    // GH #428: allocator-owned — the "park" path returns state.tokens
    // unchanged (aliased), so freeInstanceState(result) below needs these
    // heap-owned, not literal.
    const __tokens_39 = try dupeTokenSlice(allocator, &.{.{ .node_id = "join_gw", .branch_id = branch_0 }});
    const __pending_task_nodes_40 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_39,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_40,
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{}, // no cancellations
    };

    // expected_count = 2, arrived = 1 → wait (park).
    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);
    defer freeInstanceState(allocator, result);
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
    // GH #428: tokens must be allocator-owned — the ALL_BRANCHES_CANCELLED
    // cascade path (STEP f in processNodeEntry) now frees join_state.tokens
    // (the stray token(s) being discarded) internally before replacing them
    // with &[_]Token{}, matching the ISS-0601 ownership contract that
    // state.tokens is always allocator-owned. cancelled_branch_ids must also
    // be a heap-owned outer slice — see TC-EE-07-01's comment for why.
    const __tokens_41 = try dupeTokenSlice(allocator, &.{.{ .node_id = "join_gw", .branch_id = branch_0 }});
    const __pending_task_nodes_42 = try emptyOwnedStrSlice(allocator);
    const __cbi_2 = try allocator.dupe([]const u8, &[_][]const u8{ branch_0, branch_1 });
    const state_with_stray = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_41,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_42,
        .error_detail = null,
        .cancelled_branch_ids = __cbi_2,
    };

    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = try processNodeEntry(allocator, graph, state_with_stray, "join_gw", &events);
    defer freeInstanceState(allocator, result);

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

    const __pending_task_nodes_43 = try emptyOwnedStrSlice(allocator);
    // GH #428: heap-owned — the join-fire path frees every token consumed by
    // the merge (see the fix in processNodeEntry's PARALLEL_GATEWAY join
    // STEP e), so literal-backed tokens would crash on free.
    const __tokens_join_pair = try dupeTokenSlice(allocator, &.{
        .{ .node_id = "join_gw", .branch_id = branch_1 }, // arrived first (stored first)
        .{ .node_id = "join_gw", .branch_id = branch_0 }, // arrived second
    });
    // GH #428: both branches have arrived tokens on join_gw above, so neither
    // can also be cancelled — listing both here (as a prior version of this
    // fixture did) is self-contradictory and makes expected_count collapse to
    // 0, driving processNodeEntry into the ALL_BRANCHES_CANCELLED path
    // instead of the merge/fire path this test actually exercises. No branch
    // is cancelled in this scenario.
    const __cbi_3 = try emptyOwnedStrSlice(allocator);
    const state = InstanceState{
        .instance_id = [_]u8{0xAB} ** 16,
        .status = .ACTIVE,
        .tokens = __tokens_join_pair,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = __pending_task_nodes_43,
        .error_detail = null,
        .cancelled_branch_ids = __cbi_3,
    };

    var events = std.ArrayList(PendingEvent).empty;
    defer events.deinit(allocator);
    defer freePendingEvents(allocator, events.items);
    const result = try processNodeEntry(allocator, graph, state, "join_gw", &events);
    defer freeInstanceState(allocator, result);

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

    var __tokens_44 = [_]Token{};
    var __pending_task_nodes_45 = [_][]const u8{};
    var __cbi_4 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0x11} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_44,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_45,
        .error_detail = null,
        .cancelled_branch_ids = &__cbi_4,
    };

    var init_vars = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer init_vars.deinit(allocator);

    const tr = try transition(allocator, graph, state, .{
        .instance_started = .{
            .initial_variables = init_vars,
            .start_node_id = "start",
        },
    }, 1);
    defer freeTransitionResult(allocator, tr);

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

    var __pending_task_nodes_46 = [_][]const u8{};
    var __tokens_sp1 = [_]Token{.{
        .node_id = "sp1",
        .branch_id = "b1",
        .waiting_child_instance_id = "123e4567-e89b-12d3-a456-426614174001",
    }};
    var __cbi_5 = [_][]const u8{};
    const state = InstanceState{
        .instance_id = [_]u8{0x22} ** 16,
        .status = .ACTIVE,
        .tokens = &__tokens_sp1,
        .variables = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .join_counters = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
        .pending_task_nodes = &__pending_task_nodes_46,
        .error_detail = null,
        .cancelled_branch_ids = &__cbi_5,
    };

    const tr = try transition(allocator, graph, state, .{
        .sub_process_completed = .{
            .sub_process_node_id = "sp1",
            .child_instance_id = "123e4567-e89b-12d3-a456-426614174001",
        },
    }, 1);
    defer freeTransitionResult(allocator, tr);

    try std.testing.expect(tr.state.status == .COMPLETED);
    try std.testing.expect(tr.state.tokens.len == 0);
}

// ---------------------------------------------------------------------------
// EXP-102: evaluateGatewayCondition unit tests
// ---------------------------------------------------------------------------

test "TC-EXP-102-01: evaluateGatewayCondition returns true for matching condition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    defer vars.deinit(alloc);
    try vars.put(alloc, "order_total", .{ .integer = 1500 });

    const result = evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars);
    try testing.expect(result == true);
}

test "TC-EXP-102-02: evaluateGatewayCondition returns false for non-matching condition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    defer vars.deinit(alloc);
    try vars.put(alloc, "order_total", .{ .integer = 500 });

    const result = evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars);
    try testing.expect(result == false);
}

test "TC-EXP-102-03: evaluateGatewayCondition returns false on syntax error (no panic)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vars = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    defer vars.deinit(alloc);

    const result = evaluateGatewayCondition(alloc, "variables.INVALID !!! syntax", vars);
    try testing.expect(result == false);
}

// ---------------------------------------------------------------------------
// ISS-0132 — allocation-failure coverage
//
// The memory-leak signature recurred across 18 pipeline runs (2026-05-28 ->
// 2026-08-05) because the leaks live on *allocation-failure* paths that the
// ordinary tests never reach: `zig build test-engine` exercises happy paths,
// passes clean, and the leak only surfaces when a full integration run happens
// to trip an error path. Each run patched the one site it hit; none added the
// coverage that finds the class.
//
// `std.testing.checkAllAllocationFailures` re-invokes the function once per
// allocation index, failing that allocation and asserting the call both
// propagates error.OutOfMemory and leaks nothing. That turns a
// non-deterministic leak into a deterministic test failure.
//
// When adding a function that allocates more than once before returning, add
// it here too.
// ---------------------------------------------------------------------------

fn allocFailureParseTimerConfig(allocator: std.mem.Allocator, raw: []const u8) !void {
    const cfg = try parseTimerConfig(allocator, raw);
    allocator.free(cfg.duration_iso8601);
    if (cfg.repeat_expression) |r| allocator.free(r);
}

test "TC-ISS-0132-01: parseTimerConfig leaks nothing on any allocation failure" {
    // Both fields present: duration_iso8601 and repeat_expression are duped
    // separately, so a failure on the second must still free the first.
    const raw = "{\"duration_iso8601\":\"PT30M\",\"repeat_expression\":\"R3/PT10M\"}";
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureParseTimerConfig,
        .{raw},
    );
}

test "TC-ISS-0132-02: parseTimerConfig leaks nothing when only duration is present" {
    const raw = "{\"duration_iso8601\":\"PT30M\"}";
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureParseTimerConfig,
        .{raw},
    );
}

fn allocFailureCloneJsonValue(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const cloned = try cloneJsonValueSafe(allocator, parsed.value);
    freeJsonValueSafe(allocator, cloned);
}

test "TC-ISS-0132-03: cloneJsonValueSafe leaks nothing on any allocation failure" {
    // Nested object + array + multiple string values, so the clone performs
    // many allocations and a failure can land mid-structure.
    const raw = "{\"a\":\"alpha\",\"b\":[\"x\",\"y\",\"z\"],\"c\":{\"d\":\"delta\",\"e\":\"epsilon\"},\"f\":42}";
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocFailureCloneJsonValue,
        .{raw},
    );
}
