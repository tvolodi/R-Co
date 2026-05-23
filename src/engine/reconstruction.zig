//! EE-11: State Reconstruction
//!
//! Replays the full ordered event log for a process instance through the pure
//! transition function (src/engine/transition.zig) to produce a fresh
//! InstanceState that is equivalent to the persisted instance_projections row.
//!
//! Design artefact: src/design/engine.md §EE-11
const std = @import("std");
const db = @import("../db/pool.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const transition_mod = @import("transition.zig");
const InstanceState = transition_mod.InstanceState;
const InstanceStatus = transition_mod.InstanceStatus;
const Token = transition_mod.Token;
const TransitionEvent = transition_mod.TransitionEvent;
const PendingEvent = transition_mod.PendingEvent;
const snapshot_mod = @import("../definition/snapshot.zig");

/// Uuid is [16]u8 — same concrete type as snapshot_mod.Uuid and instance_mod.Uuid.
pub const Uuid = snapshot_mod.Uuid;

// ---------------------------------------------------------------------------
// ReconstructionError
// ---------------------------------------------------------------------------

pub const ReconstructionError = error{
    /// No events found for this instance_id.  HTTP 404.
    InstanceNotFound,
    /// SELECT FOR UPDATE NOWAIT on instance_projections was blocked by another
    /// transaction.  Only raised when write_back = true.  HTTP 409.
    LockContention,
    /// db.Pool.acquire() returned ExhaustedPool.  HTTP 503.
    PoolExhausted,
    /// A DB query failed (transient error or relation not found).  HTTP 500.
    QueryFailed,
    /// transition() returned an error during event replay.  Indicates a corrupt
    /// or inconsistent event log.  HTTP 500.
    ReplayFailed,
    /// Allocator exhausted.  HTTP 500.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// reconstructInstance
// ---------------------------------------------------------------------------

/// Reconstruct the full current state of a process instance by replaying its
/// ordered event log through the pure transition function.
///
/// Parameters:
///   allocator       — Arena or child allocator; all returned memory is owned
///                     by the caller and allocated here.
///   pool            — Shared connection pool; connections are acquired/released
///                     internally — no connection must be held by the caller.
///   snapshot_store  — Used to fetch the pinned DefinitionGraph for transition().
///   instance_id     — UUID of the instance to reconstruct.
///   write_back      — When true, the reconstructed state is persisted back to
///                     instance_projections via a locked transaction.
///
/// Returns the reconstructed InstanceState.
///
/// Security: all SQL parameters are bound as $N — no SQL string interpolation.
pub fn reconstructInstance(
    allocator: std.mem.Allocator,
    pool: *Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,
    instance_id: Uuid,
    write_back: bool,
) ReconstructionError!InstanceState {
    // ── Step 1: Fetch the definition snapshot ────────────────────────────────
    // The DefinitionGraph pinned at instance-start time is stored in
    // instance_definition_snapshots.  Its absence means the instance was never
    // started (or the DB is corrupt) — return InstanceNotFound.
    const snapshot_obj = snapshot_store.getByInstanceId(allocator, instance_id) catch |err| switch (err) {
        error.DefinitionNotFound => return ReconstructionError.InstanceNotFound,
        error.PoolExhausted => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    const snapshot = snapshot_obj.graph;

    // ── Step 2: Query the ordered event log ─────────────────────────────────
    // Use a private arena for all DB-row memory; the transition loop copies
    // what it needs into `allocator`.
    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();
    const ra = row_arena.allocator();

    const inst_id_hex = uuidToHex(ra, instance_id) catch return ReconstructionError.OutOfMemory;

    // Acquire a connection for the event query.
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer pool.release(conn);

    // Primary query: UNION ALL across events + events_archive ordered by
    // sequence_number ASC.  Falls back to events-only when events_archive is
    // absent (SQLSTATE 42P01 — common in unit-test environments).
    // Security: instance_id bound as $1 — no SQL string interpolation.
    const union_sql =
        \\SELECT event_type, payload, sequence_number
        \\FROM events
        \\WHERE instance_id = $1::uuid
        \\UNION ALL
        \\SELECT event_type, payload, sequence_number
        \\FROM events_archive
        \\WHERE instance_id = $1::uuid
        \\ORDER BY sequence_number ASC
    ;
    const events_only_sql =
        \\SELECT event_type, payload, sequence_number
        \\FROM events
        \\WHERE instance_id = $1::uuid
        \\ORDER BY sequence_number ASC
    ;

    var rows = conn.query(ra, union_sql, &.{inst_id_hex}) catch
        conn.query(ra, events_only_sql, &.{inst_id_hex}) catch
        return ReconstructionError.QueryFailed;
    defer rows.deinit();

    // 0 events → instance has never been started (or does not exist).
    if (rows.rows.len == 0) return ReconstructionError.InstanceNotFound;

    // ── Step 3: Initialise the pre-birth state ───────────────────────────────
    // This is the blank slate before INSTANCE_STARTED is applied.  The very
    // first event in the log must be instance_started, which seeds the first
    // token and the initial variable map via transition().
    var state = InstanceState{
        .instance_id = instance_id,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .pending_events = &[_]PendingEvent{},
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // ── Step 4: Replay events through transition() ───────────────────────────
    for (rows.rows) |row| {
        const event_type = colGet(row, 0);
        const payload_json = colGet(row, 1);

        // EXECUTION_ERROR halts replay immediately; status is set to ERROR and
        // the raw payload JSON is stored as error_detail (design §6).
        if (std.mem.eql(u8, event_type, "EXECUTION_ERROR")) {
            state.status = .ERROR;
            state.error_detail = allocator.dupe(u8, payload_json) catch
                return ReconstructionError.OutOfMemory;
            break;
        }

        // Map the DB event record to a TransitionEvent.
        // Informational events (VARIABLE_OVERWRITTEN, etc.) are skipped —
        // they do not drive state transitions.
        const te = mapToTransitionEvent(allocator, event_type, payload_json) catch |err| switch (err) {
            error.UnknownEventType => continue,
            error.OutOfMemory => return ReconstructionError.OutOfMemory,
            error.ParseFailed => return ReconstructionError.ReplayFailed,
        };

        // Apply the pure transition function (zero I/O — anti-pattern check).
        state = transition_mod.transition(allocator, snapshot, state, te) catch
            return ReconstructionError.ReplayFailed;
    }

    // Reset pending_events: any side-effects from the last transition are
    // already persisted as subsequent event records in the log and must not
    // be re-processed by the caller (design §6b).
    state.pending_events = &[_]PendingEvent{};

    // ── Step 5: Optional write-back ──────────────────────────────────────────
    if (write_back) {
        try performWriteBack(allocator, pool, instance_id, state);
    }

    return state;
}

// ---------------------------------------------------------------------------
// performWriteBack
// ---------------------------------------------------------------------------

/// Persist the reconstructed InstanceState back to instance_projections inside
/// a locked transaction.
///
/// Uses SELECT FOR UPDATE NOWAIT to detect concurrent access.  Any QueryFailed
/// from that specific query is treated as LockContention because SQLSTATE 55P03
/// is not distinguishable at the pool.zig abstraction layer.
///
/// Security: all SQL values bound as $N — no SQL string interpolation.
fn performWriteBack(
    allocator: std.mem.Allocator,
    pool: *Pool,
    instance_id: Uuid,
    state: InstanceState,
) ReconstructionError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inst_id_hex = uuidToHex(a, instance_id) catch return ReconstructionError.OutOfMemory;

    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return ReconstructionError.QueryFailed;
    // Rollback on any error return (double-rollback is harmless: pool ignores the error).
    errdefer conn.rollback() catch {};

    // SELECT FOR UPDATE NOWAIT — locks the row for the duration of the transaction.
    // Any QueryFailed here is treated as LockContention (SQLSTATE 55P03 cannot be
    // distinguished from other errors at the pool.zig layer).
    // Security: $1 = instance_id — bound as $N.
    const lock_opt = conn.queryRow(a,
        \\SELECT instance_id
        \\FROM instance_projections
        \\WHERE instance_id = $1::uuid
        \\FOR UPDATE NOWAIT
    , &.{inst_id_hex}) catch return ReconstructionError.LockContention;
    // Null → no row in instance_projections for this instance_id (data inconsistency).
    if (lock_opt == null) return ReconstructionError.QueryFailed;

    // Serialize state.
    const status_str = instanceStatusToString(state.status);

    // current_nodes: JSON array of {node_id, branch_id} token objects.
    var tokens_buf = std.ArrayList(u8).empty;
    tokens_buf.append(a, '[') catch return ReconstructionError.OutOfMemory;
    for (state.tokens, 0..) |tok, i| {
        if (i > 0) tokens_buf.append(a, ',') catch return ReconstructionError.OutOfMemory;
        const entry = std.fmt.allocPrint(
            a,
            "{{\"node_id\":\"{s}\",\"branch_id\":\"{s}\"}}",
            .{ tok.node_id, tok.branch_id },
        ) catch return ReconstructionError.OutOfMemory;
        tokens_buf.appendSlice(a, entry) catch return ReconstructionError.OutOfMemory;
    }
    tokens_buf.append(a, ']') catch return ReconstructionError.OutOfMemory;
    const tokens_json = tokens_buf.items;

    // variables: JSON object.
    const vars_json = std.json.Stringify.valueAlloc(
        a,
        std.json.Value{ .object = state.variables },
        .{},
    ) catch return ReconstructionError.OutOfMemory;

    // error_detail: empty string sentinel → SQL NULL via CASE expression.
    const error_detail_param = state.error_detail orelse "";

    // UPDATE instance_projections.
    // Security: $1=instance_id, $2=status, $3=current_nodes, $4=variables,
    //           $5=error_detail — all bound as $N; no SQL string interpolation.
    conn.exec(
        \\UPDATE instance_projections
        \\SET
        \\    status        = $2,
        \\    current_nodes = $3::jsonb,
        \\    variables     = $4::jsonb,
        \\    error_detail  = CASE WHEN $5 = '' THEN NULL ELSE $5::jsonb END,
        \\    updated_at    = NOW()
        \\WHERE instance_id = $1::uuid
    , &.{ inst_id_hex, status_str, tokens_json, vars_json, error_detail_param }) catch
        return ReconstructionError.QueryFailed;

    conn.commit() catch return ReconstructionError.QueryFailed;
}

// ---------------------------------------------------------------------------
// mapToTransitionEvent (private)
// ---------------------------------------------------------------------------

const MapError = error{ UnknownEventType, OutOfMemory, ParseFailed };

/// Convert a DB event_type + payload JSON string into a TransitionEvent.
///
/// Returns UnknownEventType for informational events (VARIABLE_OVERWRITTEN,
/// etc.) that do not drive state transitions — the caller skips these.
/// EXECUTION_ERROR must be handled by the caller before calling this function.
fn mapToTransitionEvent(
    allocator: std.mem.Allocator,
    event_type: []const u8,
    payload_json: []const u8,
) MapError!TransitionEvent {
    if (std.mem.eql(u8, event_type, "instance_started")) {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload_json,
            .{ .allocate = .alloc_always },
        ) catch return MapError.ParseFailed;
        // parsed memory lives in `allocator` (arena); caller's arena deinit
        // frees it.  No explicit deinit needed when using an arena allocator.

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return MapError.ParseFailed,
        };

        const iv_val = obj.get("initial_variables") orelse return MapError.ParseFailed;
        const iv: std.json.ObjectMap = switch (iv_val) {
            .object => |o| o,
            else => std.json.ObjectMap{},
        };
        const sn_val = obj.get("start_node_id") orelse return MapError.ParseFailed;
        const sn: []const u8 = switch (sn_val) {
            .string => |s| s,
            else => return MapError.ParseFailed,
        };

        return TransitionEvent{ .instance_started = .{
            .initial_variables = iv,
            .start_node_id = sn,
        } };
    } else if (std.mem.eql(u8, event_type, "task_completed")) {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload_json,
            .{ .allocate = .alloc_always },
        ) catch return MapError.ParseFailed;

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return MapError.ParseFailed,
        };

        const tn_val = obj.get("task_node_id") orelse return MapError.ParseFailed;
        const tn: []const u8 = switch (tn_val) {
            .string => |s| s,
            else => return MapError.ParseFailed,
        };
        const ov_val = obj.get("output_variables") orelse
            std.json.Value{ .object = std.json.ObjectMap{} };
        const ov: std.json.ObjectMap = switch (ov_val) {
            .object => |o| o,
            else => std.json.ObjectMap{},
        };

        return TransitionEvent{ .task_completed = .{
            .task_node_id = tn,
            .output_variables = ov,
        } };
    } else {
        // Informational or unknown event type (VARIABLE_OVERWRITTEN, etc.).
        // These do not drive state transitions; caller skips them.
        return MapError.UnknownEventType;
    }
}

// ---------------------------------------------------------------------------
// Private helpers (mirrors of helpers in instance.zig / instances.zig)
// ---------------------------------------------------------------------------

/// Render a UUID [16]u8 as lowercase hex with hyphens.
fn uuidToHex(allocator: std.mem.Allocator, uuid: Uuid) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Return column `i` of `row` as a non-null slice, or "" if null/absent.
inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

/// Map InstanceStatus to its TEXT representation stored in instance_projections.
fn instanceStatusToString(status: InstanceStatus) []const u8 {
    return switch (status) {
        .ACTIVE => "ACTIVE",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
        .ERROR => "ERROR",
    };
}
