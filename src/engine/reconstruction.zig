//! EE-11: State Reconstruction
//!
//! Replays the full ordered event log for a process instance through the pure
//! transition function (src/engine/transition.zig) to produce a fresh
//! InstanceState that is equivalent to the persisted instance_projections row.
//!
//! XC-04 Kernel Determinism: This module is part of the platform kernel.
//! State reconstruction is deterministic (ES-06). See reconstructInstancePointInTime()
//! for XC-05 (Deterministic Replay) point-in-time reconstruction support.
//!
//! Design artefact: src/design/engine.md §EE-11
const std = @import("std");
const db = @import("pool");
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

pub const RestoreReconciliationResult = struct {
    restored_instances: u32,
    rearmed_waits: u32,
    orphaned_instances: u32,
};

pub const ReplayDefinitionSource = enum {
    artifact_repository,
    snapshot_fallback,
};

pub fn determineReplaySourceForSnapshot(
    allocator: std.mem.Allocator,
    snapshot: snapshot_mod.DefinitionGraph,
    definition_artifact_hash: ?[]const u8,
) error{OutOfMemory}!ReplayDefinitionSource {
    return replaySourceFromSnapshotHash(allocator, snapshot, definition_artifact_hash);
}

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
    defer snapshot_mod.freeSnapshot(allocator, snapshot_obj);
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

    const ref_row = conn.queryRow(
        ra,
        \\SELECT definition_artifact_hash
        \\FROM instance_projections
        \\WHERE instance_id = $1::uuid
    ,
        &.{inst_id_hex},
    ) catch return ReconstructionError.QueryFailed;
    if (ref_row == null) return ReconstructionError.InstanceNotFound;

    const definition_artifact_hash: ?[]const u8 = blk: {
        const raw = ref_row.?[0];
        if (raw) |hash| {
            if (hash.len == 0) break :blk null;
            break :blk hash;
        }
        break :blk null;
    };

    const replay_source = replaySourceFromSnapshotHash(
        ra,
        snapshot,
        definition_artifact_hash,
    ) catch return ReconstructionError.OutOfMemory;
    _ = replay_source;

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
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    // ── Step 4: Replay events through transition() ───────────────────────────
    for (rows.rows) |row| {
        const event_type = colGet(row, 0);
        const payload_json = colGet(row, 1);
        // ISS-203: read sequence_number (col 2) to pass as triggering_event_seq.
        const seq_str = colGet(row, 2);
        const triggering_seq: i64 = std.fmt.parseInt(i64, seq_str, 10) catch 1;

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
        const te = mapToTransitionEvent(ra, event_type, payload_json) catch |err| switch (err) {
            error.UnknownEventType => continue,
            error.OutOfMemory => return ReconstructionError.OutOfMemory,
            error.ParseFailed => return ReconstructionError.ReplayFailed,
        };

        // Apply the pure transition function (zero I/O — anti-pattern check).
        // Discard emitted_events during replay — they were already persisted as event rows.
        const old_state = state;
        state = (transition_mod.transition(allocator, snapshot, state, te, triggering_seq) catch
            return ReconstructionError.ReplayFailed).state;

        // ISS-0601: transition() always returns a state with freshly
        // duped/deep-cloned tokens, variables, join_counters,
        // pending_task_nodes, and error_detail — old_state is now fully
        // owned garbage and must be freed in its entirety, not just its
        // variables/join_counters maps.
        transition_mod.freeInstanceState(allocator, old_state);
    }

    // ── Step 5: Optional write-back ──────────────────────────────────────────
    if (write_back) {
        try performWriteBack(allocator, pool, instance_id, state);
    }

    return state;
}

/// Re-arm unresolved waits from the durable instance_waits table.
pub fn rearmWaitsFromDescriptorsInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
) ReconstructionError!u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inst_id_hex = uuidToHex(a, instance_id) catch return ReconstructionError.OutOfMemory;

    var rows = conn.query(
        a,
        \\SELECT kind, ref_id::text
        \\FROM instance_waits
        \\WHERE instance_id = $1::uuid
        \\  AND resolved_at IS NULL
        \\ORDER BY created_at ASC
    ,
        &.{inst_id_hex},
    ) catch return ReconstructionError.QueryFailed;
    defer rows.deinit();

    var rearmed: u32 = 0;
    for (rows.rows) |row| {
        const kind = colGet(row, 0);
        const ref_id = colGet(row, 1);

        if (std.mem.eql(u8, kind, "timer")) {
            const live = conn.queryRow(
                a,
                \\SELECT 1
                \\FROM timers
                \\WHERE id = $1::uuid
                \\  AND status = 'pending'
                \\LIMIT 1
            ,
                &.{ref_id},
            ) catch return ReconstructionError.QueryFailed;
            if (live != null) rearmed += 1;
            continue;
        }

        if (std.mem.eql(u8, kind, "human_task")) {
            const live = conn.queryRow(
                a,
                \\SELECT 1
                \\FROM tasks
                \\WHERE id = $1::uuid
                \\  AND status = 'PENDING'
                \\LIMIT 1
            ,
                &.{ref_id},
            ) catch return ReconstructionError.QueryFailed;
            if (live != null) rearmed += 1;
            continue;
        }
    }

    return rearmed;
}

/// Mark an instance as an orphan when its waits cannot all be safely re-armed.
pub fn markRestoredOrphanInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
    reason: []const u8,
) ReconstructionError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inst_id_hex = uuidToHex(a, instance_id) catch return ReconstructionError.OutOfMemory;

    conn.exec(
        \\UPDATE instance_projections
        \\SET status = 'RESTORED_ORPHAN',
        \\    error_detail = jsonb_build_object('restored_orphan_reason', $2::text),
        \\    updated_at = NOW()
        \\WHERE instance_id = $1::uuid
    ,
        &.{ inst_id_hex, reason },
    ) catch return ReconstructionError.QueryFailed;
}

/// Reconcile all waits for a restored tenant.
pub fn restoreTenantWithWaitReconciliation(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: Uuid,
) ReconstructionError!RestoreReconciliationResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tenant_hex = uuidToHex(a, tenant_id) catch return ReconstructionError.OutOfMemory;

    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer pool.release(conn);

    var rows = conn.query(
        a,
        \\SELECT instance_id::text
        \\FROM instance_projections
        \\WHERE tenant_id = $1::uuid
        \\ORDER BY instance_id ASC
    ,
        &.{tenant_hex},
    ) catch return ReconstructionError.QueryFailed;
    defer rows.deinit();

    var result = RestoreReconciliationResult{
        .restored_instances = 0,
        .rearmed_waits = 0,
        .orphaned_instances = 0,
    };

    for (rows.rows) |row| {
        const instance_hex = colGet(row, 0);
        const instance_uuid = parseUuid(instance_hex) catch return ReconstructionError.QueryFailed;
        const total_waits_row = conn.queryRow(
            a,
            \\SELECT COUNT(*)::text
            \\FROM instance_waits
            \\WHERE instance_id = $1::uuid
            \\  AND resolved_at IS NULL
        ,
            &.{instance_hex},
        ) catch return ReconstructionError.QueryFailed;
        const total_waits: u32 = if (total_waits_row) |r| blk: {
            defer {
                for (r) |col| if (col) |v| a.free(v);
                a.free(r);
            }
            break :blk std.fmt.parseInt(u32, r[0] orelse "0", 10) catch 0;
        } else 0;

        const rearmed = rearmWaitsFromDescriptorsInTx(allocator, conn, instance_uuid) catch return ReconstructionError.QueryFailed;
        result.restored_instances += 1;
        result.rearmed_waits += rearmed;

        if (rearmed < total_waits) {
            try markRestoredOrphanInTx(allocator, conn, instance_uuid, "unrearmable instance_waits descriptors");
            result.orphaned_instances += 1;
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// XC-05: Deterministic Replay — Point-in-Time Reconstruction
// ---------------------------------------------------------------------------

/// Reconstruct instance state as of a specific sequence number.
///
/// Used for XC-05 (Deterministic Replay) to validate that replaying an instance
/// up to a given sequence number produces identical state to what it had at that point.
///
/// Parameters:
///   up_to_sequence — Stop replay at this event sequence number (inclusive).
///                    If null, replay to the latest event (same as reconstructInstance).
///
/// Returns the reconstructed InstanceState as of that sequence number.
pub fn reconstructInstancePointInTime(
    allocator: std.mem.Allocator,
    pool: *Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,
    instance_id: Uuid,
    up_to_sequence: ?i64,
) ReconstructionError!InstanceState {
    // Reuse the same logic as reconstructInstance, but filter events by sequence number.
    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();
    const ra = row_arena.allocator();

    const snapshot_obj = snapshot_store.getByInstanceId(allocator, instance_id) catch |err| switch (err) {
        error.DefinitionNotFound => return ReconstructionError.InstanceNotFound,
        error.PoolExhausted => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer snapshot_mod.freeSnapshot(allocator, snapshot_obj);
    const snapshot = snapshot_obj.graph;

    const inst_id_hex = uuidToHex(ra, instance_id) catch return ReconstructionError.OutOfMemory;

    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer pool.release(conn);

    // Query with optional sequence cutoff.
    // ISS-0601: ORDER BY is required — without it Postgres may return rows
    // out of physical/scan order, which breaks event replay (transition()
    // must see instance_started before any other event).
    const base_sql =
        \\SELECT event_type, payload, sequence_number
        \\FROM events
        \\WHERE instance_id = $1::uuid
        \\ORDER BY sequence_number ASC
    ;
    const with_cutoff_sql =
        \\SELECT event_type, payload, sequence_number
        \\FROM events
        \\WHERE instance_id = $1::uuid AND sequence_number <= $2
        \\ORDER BY sequence_number ASC
    ;

    var rows: db.QueryResult = undefined;
    if (up_to_sequence) |seq| {
        const seq_str = std.fmt.allocPrint(ra, "{d}", .{seq}) catch return ReconstructionError.OutOfMemory;
        rows = conn.query(ra, with_cutoff_sql, &.{ inst_id_hex, seq_str }) catch
            return ReconstructionError.QueryFailed;
    } else {
        rows = conn.query(ra, base_sql, &.{inst_id_hex}) catch
            return ReconstructionError.QueryFailed;
    }
    defer rows.deinit();

    if (rows.rows.len == 0) return ReconstructionError.InstanceNotFound;

    // Replay events exactly as in reconstructInstance
    var state = InstanceState{
        .instance_id = instance_id,
        .status = .ACTIVE,
        .tokens = &[_]Token{},
        .variables = std.json.ObjectMap{},
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = &[_][]const u8{},
        .error_detail = null,
        .cancelled_branch_ids = &[_][]const u8{},
    };

    for (rows.rows) |row| {
        const event_type = colGet(row, 0);
        const payload_json = colGet(row, 1);
        // ISS-203: read sequence_number (col 2) to pass as triggering_event_seq.
        const seq_str2 = colGet(row, 2);
        const triggering_seq2: i64 = std.fmt.parseInt(i64, seq_str2, 10) catch 1;

        if (std.mem.eql(u8, event_type, "EXECUTION_ERROR")) {
            state.status = .ERROR;
            state.error_detail = allocator.dupe(u8, payload_json) catch
                return ReconstructionError.OutOfMemory;
            break;
        }

        const te = mapToTransitionEvent(ra, event_type, payload_json) catch |err| switch (err) {
            error.UnknownEventType => continue,
            error.OutOfMemory => return ReconstructionError.OutOfMemory,
            error.ParseFailed => return ReconstructionError.ReplayFailed,
        };

        const old_state = state;
        state = (transition_mod.transition(allocator, snapshot, state, te, triggering_seq2) catch
            return ReconstructionError.ReplayFailed).state;

        // ISS-0601: see freeInstanceState doc comment — old_state is fully
        // owned garbage once transition() returns a freshly-built state.
        transition_mod.freeInstanceState(allocator, old_state);
    }

    return state;
}

// ---------------------------------------------------------------------------
// ISS-601: Snapshot-Assisted Reconstruction
// ---------------------------------------------------------------------------

/// Reconstruct instance state using snapshot-assisted replay.
///
/// Algorithm:
///   1. Query the latest snapshot for this instance (max snapshot_seq).
///   2. If a snapshot exists:
///      a. Deserialise state_blob → InstanceState.
///      b. Query events WHERE instance_id = $1 AND sequence_number > snapshot_seq
///         ORDER BY sequence_number ASC.
///      c. Replay those events through transition().
///   3. If no snapshot exists:
///      a. Fall back to full replay (existing reconstructInstance path).
///
/// The snapshot path joins event_payloads_overflow to reconstruct full event
/// payloads, exactly as full replay does.
///
/// Security: all SQL parameters bound as $N — no SQL string interpolation.
pub fn reconstructInstanceWithSnapshot(
    allocator: std.mem.Allocator,
    pool: *Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,
    instance_id: Uuid,
    write_back: bool,
) ReconstructionError!InstanceState {
    // ── Step 1: Fetch the definition snapshot ────────────────────────────────
    const snapshot_obj = snapshot_store.getByInstanceId(allocator, instance_id) catch |err| switch (err) {
        error.DefinitionNotFound => return ReconstructionError.InstanceNotFound,
        error.PoolExhausted => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer snapshot_mod.freeSnapshot(allocator, snapshot_obj);
    const snapshot = snapshot_obj.graph;

    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();
    const ra = row_arena.allocator();

    const inst_id_hex = uuidToHex(ra, instance_id) catch return ReconstructionError.OutOfMemory;

    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return ReconstructionError.PoolExhausted,
        else => return ReconstructionError.QueryFailed,
    };
    defer pool.release(conn);

    // ── Step 2: Query latest snapshot ─────────────────────────────────────────
    // Security: $1 = instance_id — bound as $N.
    const snap_row_opt = conn.queryRow(
        ra,
        \\SELECT snapshot_seq, state_blob
        \\FROM instance_state_snapshots
        \\WHERE instance_id = $1::uuid
        \\ORDER BY snapshot_seq DESC
        \\LIMIT 1
    ,
        &.{inst_id_hex},
    ) catch null; // Table may not exist yet — fall through to full replay.

    var snapshot_seq: i64 = 0;
    var state: InstanceState = undefined;
    var use_snapshot: bool = false;

    if (snap_row_opt) |snap_row| {
        if (snap_row.len >= 2 and snap_row[0] != null and snap_row[1] != null) {
            const seq_str = snap_row[0].?;
            const blob_str = snap_row[1].?;
            snapshot_seq = std.fmt.parseInt(i64, seq_str, 10) catch 0;
            if (snapshot_seq > 0 and blob_str.len > 0) {
                // Deserialise state_blob → InstanceState.
                state = deserializeInstanceState(allocator, instance_id, blob_str) catch
                    InstanceState{
                        .instance_id = instance_id,
                        .status = .ACTIVE,
                        .tokens = &[_]Token{},
                        .variables = std.json.ObjectMap{},
                        .join_counters = std.json.ObjectMap{},
                        .pending_task_nodes = &[_][]const u8{},
                        .error_detail = null,
                        .cancelled_branch_ids = &[_][]const u8{},
                    };
                use_snapshot = true;
            }
        }
    }

    if (!use_snapshot) {
        // Fall back to full replay.
        return reconstructInstance(allocator, pool, snapshot_store, instance_id, write_back);
    }

    // ── Step 3: Query delta events (seq > snapshot_seq) ──────────────────────
    // Join event_payloads_overflow with fallback.
    // Security: $1=instance_id, $2=snapshot_seq — bound as $N.
    const snapshot_seq_str = std.fmt.allocPrint(ra, "{d}", .{snapshot_seq}) catch
        return ReconstructionError.OutOfMemory;

    const delta_sql_overflow =
        \\SELECT e.event_type,
        \\       COALESCE(epo.payload, e.payload) AS full_payload,
        \\       e.sequence_number
        \\FROM events e
        \\LEFT JOIN event_payloads_overflow epo ON e.event_id = epo.event_id
        \\WHERE e.instance_id = $1::uuid AND e.sequence_number > $2
        \\ORDER BY e.sequence_number ASC
    ;
    const delta_sql_simple =
        \\SELECT event_type, payload, sequence_number
        \\FROM events
        \\WHERE instance_id = $1::uuid AND sequence_number > $2
        \\ORDER BY sequence_number ASC
    ;

    var rows = conn.query(ra, delta_sql_overflow, &.{ inst_id_hex, snapshot_seq_str }) catch
        conn.query(ra, delta_sql_simple, &.{ inst_id_hex, snapshot_seq_str }) catch
        return ReconstructionError.QueryFailed;
    defer rows.deinit();

    // ── Step 4: Replay events through transition() ───────────────────────────
    for (rows.rows) |row| {
        const event_type = colGet(row, 0);
        const payload_json = colGet(row, 1);
        const seq_str2 = colGet(row, 2);
        const triggering_seq: i64 = std.fmt.parseInt(i64, seq_str2, 10) catch 1;

        if (std.mem.eql(u8, event_type, "EXECUTION_ERROR")) {
            state.status = .ERROR;
            state.error_detail = allocator.dupe(u8, payload_json) catch
                return ReconstructionError.OutOfMemory;
            break;
        }

        const te = mapToTransitionEvent(ra, event_type, payload_json) catch |err| switch (err) {
            error.UnknownEventType => continue,
            error.OutOfMemory => return ReconstructionError.OutOfMemory,
            error.ParseFailed => return ReconstructionError.ReplayFailed,
        };

        const old_state = state;
        state = (transition_mod.transition(allocator, snapshot, state, te, triggering_seq) catch
            return ReconstructionError.ReplayFailed).state;

        // ISS-0601: see freeInstanceState doc comment — old_state is fully
        // owned garbage once transition() returns a freshly-built state.
        transition_mod.freeInstanceState(allocator, old_state);
    }

    // ── Step 5: Optional write-back ──────────────────────────────────────────
    if (write_back) {
        try performWriteBack(allocator, pool, instance_id, state);
    }

    return state;
}

// ---------------------------------------------------------------------------
// ISS-601: Snapshot deserialization helper
// ---------------------------------------------------------------------------

/// Deserialise a state_blob JSON string into an InstanceState.
///
/// Schema matches the state_blob spec from
/// src/design/iss601_state_snapshots.md §3.2.
///
/// On any parse failure: returns OutOfMemory (corrupt snapshot → caller falls
/// back to full replay).
fn deserializeInstanceState(
    allocator: std.mem.Allocator,
    instance_id: Uuid,
    state_blob: []const u8,
) error{OutOfMemory}!InstanceState {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        a,
        state_blob,
        .{ .allocate = .alloc_always },
    ) catch return error.OutOfMemory;

    if (parsed.value != .object) return error.OutOfMemory;
    const obj = parsed.value.object;

    // Parse status
    const status_str = if (obj.get("status")) |s|
        switch (s) {
            .string => |str| str,
            else => return error.OutOfMemory,
        }
    else
        return error.OutOfMemory;

    const status: InstanceStatus = if (std.mem.eql(u8, status_str, "ACTIVE"))
        .ACTIVE
    else if (std.mem.eql(u8, status_str, "COMPLETED"))
        .COMPLETED
    else if (std.mem.eql(u8, status_str, "CANCELLED"))
        .CANCELLED
    else if (std.mem.eql(u8, status_str, "ERROR"))
        .ERROR
    else
        return error.OutOfMemory;

    // Parse tokens array
    var tokens = std.ArrayList(Token).empty;
    if (obj.get("tokens")) |tokens_val| {
        if (tokens_val == .array) {
            for (tokens_val.array.items) |tok_val| {
                if (tok_val != .object) continue;
                const tok_obj = tok_val.object;

                const node_id_val = tok_obj.get("node_id") orelse continue;
                const branch_id_val = tok_obj.get("branch_id") orelse continue;
                if (node_id_val != .string or branch_id_val != .string) continue;

                const node_id = allocator.dupe(u8, node_id_val.string) catch
                    return error.OutOfMemory;
                const branch_id = allocator.dupe(u8, branch_id_val.string) catch {
                    allocator.free(node_id);
                    return error.OutOfMemory;
                };

                var token_id: ?[]const u8 = null;
                if (tok_obj.get("token_id")) |tid_val| {
                    if (tid_val == .string) {
                        token_id = allocator.dupe(u8, tid_val.string) catch {
                            allocator.free(node_id);
                            allocator.free(branch_id);
                            return error.OutOfMemory;
                        };
                    }
                }

                var waiting_child: ?[]const u8 = null;
                if (tok_obj.get("waiting_child_instance_id")) |w_val| {
                    if (w_val == .string and w_val.string.len > 0) {
                        waiting_child = allocator.dupe(u8, w_val.string) catch {
                            if (token_id) |t| allocator.free(t);
                            allocator.free(node_id);
                            allocator.free(branch_id);
                            return error.OutOfMemory;
                        };
                    }
                }

                tokens.append(allocator, Token{
                    .node_id = node_id,
                    .branch_id = branch_id,
                    .token_id = token_id,
                    .waiting_child_instance_id = waiting_child,
                }) catch {
                    if (token_id) |t| allocator.free(t);
                    if (waiting_child) |w| allocator.free(w);
                    allocator.free(node_id);
                    allocator.free(branch_id);
                    return error.OutOfMemory;
                };
            }
        }
    }
    const tokens_slice = tokens.toOwnedSlice(allocator) catch return error.OutOfMemory;

    // Parse variables
    var variables = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
        return error.OutOfMemory;
    errdefer variables.deinit(allocator);
    if (obj.get("variables")) |vars_val| {
        if (vars_val == .object) {
            variables = parseObjectMapFromJson(allocator, vars_val.object) catch
                return error.OutOfMemory;
        }
    }

    // Parse join_counters
    var join_counters = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
        return error.OutOfMemory;
    errdefer join_counters.deinit(allocator);
    if (obj.get("join_counters")) |jc_val| {
        if (jc_val == .object) {
            join_counters = parseObjectMapFromJson(allocator, jc_val.object) catch
                return error.OutOfMemory;
        }
    }

    // Parse pending_task_nodes
    var pending_task_nodes = std.ArrayList([]const u8).empty;
    if (obj.get("pending_task_nodes")) |ptn_val| {
        if (ptn_val == .array) {
            for (ptn_val.array.items) |ptn_item| {
                if (ptn_item == .string) {
                    const duped = allocator.dupe(u8, ptn_item.string) catch
                        return error.OutOfMemory;
                    pending_task_nodes.append(allocator, duped) catch {
                        allocator.free(duped);
                        return error.OutOfMemory;
                    };
                }
            }
        }
    }
    const pending_slice = pending_task_nodes.toOwnedSlice(allocator) catch
        return error.OutOfMemory;

    // Parse error_detail
    var error_detail: ?[]const u8 = null;
    if (obj.get("error_detail")) |ed_val| {
        if (ed_val == .string and ed_val.string.len > 0) {
            error_detail = allocator.dupe(u8, ed_val.string) catch
                return error.OutOfMemory;
        }
    }

    // Parse cancelled_branch_ids
    var cancelled_branch_ids = std.ArrayList([]const u8).empty;
    if (obj.get("cancelled_branch_ids")) |cbi_val| {
        if (cbi_val == .array) {
            for (cbi_val.array.items) |cbi_item| {
                if (cbi_item == .string) {
                    const duped = allocator.dupe(u8, cbi_item.string) catch
                        return error.OutOfMemory;
                    cancelled_branch_ids.append(allocator, duped) catch {
                        allocator.free(duped);
                        return error.OutOfMemory;
                    };
                }
            }
        }
    }
    const cancelled_slice = cancelled_branch_ids.toOwnedSlice(allocator) catch
        return error.OutOfMemory;

    return InstanceState{
        .instance_id = instance_id,
        .status = status,
        .tokens = tokens_slice,
        .variables = variables,
        .join_counters = join_counters,
        .pending_task_nodes = pending_slice,
        .error_detail = error_detail,
        .cancelled_branch_ids = cancelled_slice,
    };
}

/// Clone a std.json.ObjectMap using allocator for all keys and values.
fn parseObjectMapFromJson(
    allocator: std.mem.Allocator,
    source: std.json.ObjectMap,
) error{OutOfMemory}!std.json.ObjectMap {
    var result = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
        return error.OutOfMemory;
    errdefer result.deinit(allocator);

    var it = source.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        // ISS-0601: Duplicate the key string so it's owned by allocator, not borrowed from source
        const key_copy = allocator.dupe(u8, key) catch return error.OutOfMemory;
        // Clone the value into allocator.
        const cloned_value = cloneJsonValue(allocator, value) catch {
            allocator.free(key_copy);
            return error.OutOfMemory;
        };
        result.put(allocator, key_copy, cloned_value) catch {
            // Free the cloned key and value on put failure.
            allocator.free(key_copy);
            freeJsonValue(allocator, cloned_value);
            return error.OutOfMemory;
        };
    }
    return result;
}

/// Shallow-clone a std.json.Value into allocator.
fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (value) {
        .null => std.json.Value{ .null = {} },
        .bool => |b| std.json.Value{ .bool = b },
        .integer => |n| std.json.Value{ .integer = n },
        .float => |f| std.json.Value{ .float = f },
        .string => |s| {
            const duped = allocator.dupe(u8, s) catch return error.OutOfMemory;
            return std.json.Value{ .string = duped };
        },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            for (arr.items) |item| {
                const cloned = cloneJsonValue(allocator, item) catch {
                    for (new_arr.items) |prev| freeJsonValue(allocator, prev);
                    new_arr.deinit();
                    return error.OutOfMemory;
                };
                new_arr.append(cloned) catch {
                    freeJsonValue(allocator, cloned);
                    for (new_arr.items) |prev| freeJsonValue(allocator, prev);
                    new_arr.deinit();
                    return error.OutOfMemory;
                };
            }
            return std.json.Value{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
                return error.OutOfMemory;
            errdefer {
                var it2 = new_obj.iterator();
                while (it2.next()) |e| freeJsonValue(allocator, e.value_ptr.*);
                new_obj.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                // ISS-0601: Duplicate the key string so it's owned by allocator
                const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch
                    return error.OutOfMemory;
                const cloned = cloneJsonValue(allocator, entry.value_ptr.*) catch {
                    allocator.free(key_copy);
                    return error.OutOfMemory;
                };
                new_obj.put(allocator, key_copy, cloned) catch {
                    allocator.free(key_copy);
                    freeJsonValue(allocator, cloned);
                    return error.OutOfMemory;
                };
            }
            return std.json.Value{ .object = new_obj };
        },
        .number_string => |s| {
            const duped = allocator.dupe(u8, s) catch return error.OutOfMemory;
            return std.json.Value{ .number_string = duped };
        },
    };
}

/// Free all keys and values in a JsonValue ObjectMap, then deinit the map.
/// This is the REQUIRED cleanup pattern for ObjectMaps populated by
/// parseObjectMapFromJson or cloneJsonValue.
///
/// Usage in application code:
///   defer freeObjectMap(allocator, &reconst_state.variables);
///
/// Usage in test code:
///   freeObjectMap(alloc, &reconst_state.variables);
///   freeObjectMap(alloc, &reconst_state.join_counters);
pub fn freeObjectMap(
    allocator: std.mem.Allocator,
    map: *std.json.ObjectMap,
) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeJsonValue(allocator, entry.value_ptr.*);
    }
    map.deinit(allocator);
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    var mutable_value = value;
    switch (mutable_value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                // ISS-0601: Free both keys and values
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
        else => {},
    }
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

/// Parse a canonical UUID string into raw bytes.
fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidUuid}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
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
        .RESTORED_ORPHAN => "RESTORED_ORPHAN",
    };
}

fn replaySourceFromSnapshotHash(
    allocator: std.mem.Allocator,
    snapshot: snapshot_mod.DefinitionGraph,
    definition_artifact_hash: ?[]const u8,
) error{OutOfMemory}!ReplayDefinitionSource {
    const hash = definition_artifact_hash orelse return .snapshot_fallback;
    if (!isValidDefinitionArtifactHash(hash)) return .snapshot_fallback;

    const canonical_json = std.json.Stringify.valueAlloc(allocator, snapshot, .{}) catch
        return error.OutOfMemory;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_json, &digest, .{});
    const computed = std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)}) catch
        return error.OutOfMemory;

    if (std.ascii.eqlIgnoreCase(computed, hash)) {
        return .artifact_repository;
    }
    return .snapshot_fallback;
}

fn isValidDefinitionArtifactHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
