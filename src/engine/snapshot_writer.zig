//! ISS-601 — Periodic per-instance state snapshot writer
//!
//! Creates periodic snapshots of InstanceState as JSONB blobs in the
//! instance_state_snapshots table. Called after event appends and on instance
//! completion. Snapshots are used by reconstruction.zig to replay only events
//! since the latest snapshot rather than the full event log.
//!
//! No dependency on HTTP layer or API routes.
//! Depends on transition.zig for InstanceState/InstanceStatus types (types only).
//! Depends on pool.zig for database access.
//!
//! Design artefact: src/design/iss601_state_snapshots.md
const std = @import("std");
const db = @import("pool");
const Pool = db.Pool;
const PoolError = db.PoolError;
const transition_mod = @import("transition.zig");
const InstanceState = transition_mod.InstanceState;
const InstanceStatus = transition_mod.InstanceStatus;

/// Re-export Uuid type for callers.
pub const Uuid = [16]u8;

// ---------------------------------------------------------------------------
// SnapshotWriterError
// ---------------------------------------------------------------------------

pub const SnapshotWriterError = error{
    /// pool.acquire() returned ExhaustedPool. HTTP 503.
    PoolExhausted,
    /// INSERT into instance_state_snapshots or SELECT latest snapshot failed. HTTP 500.
    PersistenceFailed,
    /// Allocator exhausted during JSON serialisation or query.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Default snapshot interval
// ---------------------------------------------------------------------------

/// Take a snapshot every N events. Default: 1000.
pub const DEFAULT_SNAPSHOT_INTERVAL: u32 = 1000;

// ---------------------------------------------------------------------------
// SnapshotWriter
// ---------------------------------------------------------------------------

pub const SnapshotWriter = struct {
    pool: *Pool,

    pub fn init(pool: *Pool) SnapshotWriter {
        return SnapshotWriter{ .pool = pool };
    }

    pub fn deinit(self: *SnapshotWriter) void {
        _ = self;
    }

    /// Take a snapshot of the given InstanceState at the given sequence number.
    ///
    /// Stores a JSONB blob of the full state into instance_state_snapshots.
    ///
    /// Called from two paths:
    ///   1. Interval path: after every N events (N = DEFAULT_SNAPSHOT_INTERVAL).
    ///   2. Completion path: when an instance reaches COMPLETED, CANCELLED, or ERROR.
    ///
    /// The caller must have already committed the event that produced `state`
    /// before calling this function — the snapshot is a secondary write and must
    /// not be in the same transaction as the event append.
    ///
    /// Idempotency: INSERT ... ON CONFLICT (instance_id, snapshot_seq) DO NOTHING.
    /// If a snapshot already exists at this seq (e.g. from a retry), this is a no-op.
    ///
    /// Security: all SQL values bound as $N parameters — no SQL string interpolation.
    pub fn takeSnapshot(
        self: *SnapshotWriter,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        state: *const InstanceState,
        snapshot_seq: i64,
    ) SnapshotWriterError!void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch
            return SnapshotWriterError.OutOfMemory;

        // Serialize InstanceState → JSONB blob.
        const state_blob = serializeInstanceState(a, state) catch
            return SnapshotWriterError.OutOfMemory;

        const snapshot_seq_str = std.fmt.allocPrint(a, "{d}", .{snapshot_seq}) catch
            return SnapshotWriterError.OutOfMemory;

        // Security: $1=instance_id, $2=snapshot_seq, $3=state_blob — all bound as $N.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return SnapshotWriterError.PoolExhausted,
            else => return SnapshotWriterError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.exec(
            \\INSERT INTO instance_state_snapshots
            \\    (instance_id, snapshot_seq, state_blob)
            \\VALUES ($1::uuid, $2::bigint, $3::jsonb)
            \\ON CONFLICT (instance_id, snapshot_seq) DO NOTHING
        ,
            &.{ inst_id_hex, snapshot_seq_str, state_blob },
        ) catch return SnapshotWriterError.PersistenceFailed;
    }

    /// Conditionally take a snapshot if the sequence number crosses the interval
    /// boundary. Compares `current_seq` against the most recent snapshot_seq for
    /// this instance.
    ///
    /// If no prior snapshot exists, takes a snapshot (first snapshot = baseline).
    /// Also takes a snapshot on terminal status (COMPLETED, CANCELLED, ERROR)
    /// regardless of interval — this is the "instance completion" path.
    ///
    /// Returns true if a snapshot was taken, false if skipped.
    ///
    /// Security: all SQL values bound as $N parameters — no SQL string interpolation.
    pub fn maybeTakeSnapshot(
        self: *SnapshotWriter,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        state: *const InstanceState,
        current_seq: i64,
        status: InstanceStatus,
        interval: u32,
    ) SnapshotWriterError!bool {
        // Terminal status — always snapshot (completion path).
        const is_terminal = status == .COMPLETED or status == .CANCELLED or status == .ERROR;

        if (!is_terminal) {
            // Query the latest snapshot_seq for this instance.
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const inst_id_hex = uuidToHex(a, instance_id) catch
                return SnapshotWriterError.OutOfMemory;

            const conn = self.pool.acquire() catch |err| switch (err) {
                PoolError.ExhaustedPool => return SnapshotWriterError.PoolExhausted,
                else => return SnapshotWriterError.PersistenceFailed,
            };
            defer self.pool.release(conn);

            // Security: $1 = instance_id — bound as $N.
            const row_opt = conn.queryRow(
                a,
                \\SELECT snapshot_seq FROM instance_state_snapshots
                \\WHERE instance_id = $1::uuid
                \\ORDER BY snapshot_seq DESC
                \\LIMIT 1
            ,
                &.{inst_id_hex},
            ) catch return SnapshotWriterError.PersistenceFailed;

            if (row_opt) |row| {
                if (row.len > 0 and row[0] != null) {
                    const latest_str = row[0].?;
                    const latest_seq = std.fmt.parseInt(i64, latest_str, 10) catch
                        return SnapshotWriterError.PersistenceFailed;
                    // Only snapshot if interval boundary crossed.
                    const delta = current_seq - latest_seq;
                    if (delta < interval) return false;
                }
            }
            // If no prior snapshot exists, take one (baseline).
        }

        try self.takeSnapshot(allocator, instance_id, state, current_seq);
        return true;
    }
};

// ---------------------------------------------------------------------------
// JSON serialization helpers (private)
// ---------------------------------------------------------------------------

/// Serialize InstanceState to a JSONB-compatible string.
/// Schema matches the state_blob spec from src/design/iss601_state_snapshots.md §3.2.
fn serializeInstanceState(allocator: std.mem.Allocator, state: *const InstanceState) error{OutOfMemory}![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"status\":");
    const status_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = instanceStatusToString(state.status) },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(status_json);
    try buf.appendSlice(allocator, status_json);

    // tokens array
    try buf.appendSlice(allocator, ",\"tokens\":[");
    for (state.tokens, 0..) |tok, i| {
        if (i > 0) try buf.append(allocator, ',');
        try serializeToken(allocator, &buf, tok);
    }
    try buf.append(allocator, ']');

    // variables object
    try buf.appendSlice(allocator, ",\"variables\":");
    const vars_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = state.variables },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(vars_json);
    try buf.appendSlice(allocator, vars_json);

    // join_counters object
    try buf.appendSlice(allocator, ",\"join_counters\":");
    const jc_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = state.join_counters },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(jc_json);
    try buf.appendSlice(allocator, jc_json);

    // pending_task_nodes array
    try buf.appendSlice(allocator, ",\"pending_task_nodes\":[");
    for (state.pending_task_nodes, 0..) |node_id, i| {
        if (i > 0) try buf.append(allocator, ',');
        const nid_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = node_id },
            .{},
        ) catch return error.OutOfMemory;
        defer allocator.free(nid_json);
        try buf.appendSlice(allocator, nid_json);
    }
    try buf.append(allocator, ']');

    // error_detail
    try buf.appendSlice(allocator, ",\"error_detail\":");
    if (state.error_detail) |detail| {
        const ed_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = detail },
            .{},
        ) catch return error.OutOfMemory;
        defer allocator.free(ed_json);
        try buf.appendSlice(allocator, ed_json);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    // cancelled_branch_ids array
    try buf.appendSlice(allocator, ",\"cancelled_branch_ids\":[");
    for (state.cancelled_branch_ids, 0..) |bid, i| {
        if (i > 0) try buf.append(allocator, ',');
        const bid_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = bid },
            .{},
        ) catch return error.OutOfMemory;
        defer allocator.free(bid_json);
        try buf.appendSlice(allocator, bid_json);
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn serializeToken(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    tok: transition_mod.Token,
) error{OutOfMemory}!void {
    try buf.appendSlice(allocator, "{\"node_id\":");
    const nid_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = tok.node_id },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(nid_json);
    try buf.appendSlice(allocator, nid_json);

    try buf.appendSlice(allocator, ",\"branch_id\":");
    const bid_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = tok.branch_id },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(bid_json);
    try buf.appendSlice(allocator, bid_json);

    if (tok.token_id) |tid| {
        try buf.appendSlice(allocator, ",\"token_id\":");
        const tid_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = tid },
            .{},
        ) catch return error.OutOfMemory;
        defer allocator.free(tid_json);
        try buf.appendSlice(allocator, tid_json);
    }

    if (tok.waiting_child_instance_id) |child_id| {
        try buf.appendSlice(allocator, ",\"waiting_child_instance_id\":");
        const child_json = std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .string = child_id },
            .{},
        ) catch return error.OutOfMemory;
        defer allocator.free(child_json);
        try buf.appendSlice(allocator, child_json);
    }

    try buf.append(allocator, '}');
}

// ---------------------------------------------------------------------------
// Private helpers
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

fn instanceStatusToString(status: InstanceStatus) []const u8 {
    return switch (status) {
        .ACTIVE => "ACTIVE",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
        .ERROR => "ERROR",
    };
}
