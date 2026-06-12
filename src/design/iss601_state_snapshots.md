# Module: ISS-601 — State Snapshots for Large-Instance Reconstruction

**Stage:** Epic 6 — Performance and cutover quality
**Requirement:** ISS-601
**Priority:** P2 · **Estimate:** M
**Labels:** performance, engine
**Depends on:** EE-11 (State Reconstruction in `src/engine/reconstruction.zig`)
**Files to produce:** `src/engine/snapshot_writer.zig`, `migrations/NNN_instance_state_snapshots.sql`, `src/engine/reconstruction.zig` (modified)

---

## 1. Purpose

Large process instances accumulate thousands of events over their lifetime. Full replay from event zero meets NFR-04 (5 seconds for 10,000 events) but degrades linearly for instances with hundreds of thousands of events. This module introduces **periodic per-instance state snapshots** so that reconstruction replays only events since the most recent snapshot rather than the entire event log. A snapshot captures the full `InstanceState` (tokens, variables, join_counters, status, pending_task_nodes, error_detail, cancelled_branch_ids) at a known sequence number. Reconstruction loads the latest snapshot, sets the state to the snapshot's captured state, then replays only events with `sequence_number > snapshot.snapshot_seq` through the pure `transition()` function.

---

## 2. Module Layout

```
src/engine/
├── snapshot_writer.zig         — NEW: snapshot creation logic (takeSnapshot, maybeTakeSnapshot)
├── reconstruction.zig          — MODIFIED: snapshot-aware reconstruction path
migrations/
└── NNN_instance_state_snapshots.sql  — NEW: snapshot table DDL
```

`snapshot_writer.zig` is a new module with no dependency on the HTTP layer or API routes. It depends on `src/engine/transition.zig` (pure, zero I/O) for the `InstanceState` type, `src/engine/reconstruction.zig` for the existing reconstruction path (used as fallback when no snapshot exists), and `src/db/pool.zig` for database access.

---

## 3. Data Model

### 3.1 Snapshot Table

```sql
CREATE TABLE IF NOT EXISTS instance_state_snapshots (
    instance_id   UUID        NOT NULL,
    snapshot_seq  BIGINT      NOT NULL,
    state_blob    JSONB       NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (instance_id, snapshot_seq)
);

CREATE INDEX IF NOT EXISTS idx_instance_state_snapshots_latest
    ON instance_state_snapshots (instance_id, snapshot_seq DESC);
```

**Column rationale:**

| Column | Type | Purpose |
|---|---|---|
| `instance_id` | UUID | FK to `instance_projections.instance_id`. Identifies the owning instance. |
| `snapshot_seq` | BIGINT | The event sequence number at which this snapshot was taken. The snapshot represents instance state AFTER applying the event with this sequence number. Monotonically increasing per instance. |
| `state_blob` | JSONB NOT NULL | Full serialisation of `InstanceState` at `snapshot_seq`. Contains `tokens`, `variables`, `join_counters`, `status`, `pending_task_nodes`, `error_detail`, `cancelled_branch_ids`. Must never be null — a snapshot with null state is a data integrity defect. |
| `created_at` | TIMESTAMPTZ | Server timestamp of snapshot creation. Informational; not used in reconstruction logic. |

**Primary key:** `(instance_id, snapshot_seq)` ensures at most one snapshot per instance per sequence number. The descending index `idx_instance_state_snapshots_latest` enables O(log n) lookup of the most recent snapshot for an instance.

### 3.2 state_blob JSON Schema

The `state_blob` column stores a JSON object with the following structure:

```json
{
  "status": "ACTIVE",
  "tokens": [
    {
      "node_id": "task_approve",
      "branch_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890/start/0",
      "token_id": "f1e2d3c4-b5a6-7890-1234-567890abcdef",
      "waiting_child_instance_id": null
    }
  ],
  "variables": {
    "order_total": 1500,
    "customer_name": "Alice"
  },
  "join_counters": {
    "parallel_split_1": {
      "received_count": 2,
      "expected_from_branches": 3
    }
  },
  "pending_task_nodes": ["task_approve"],
  "error_detail": null,
  "cancelled_branch_ids": []
}
```

All fields are mandatory in the JSON blob. Missing fields indicate a corrupt snapshot and must be treated as a reconstruction fallback (full replay).

---

## 4. Public Interface

### 4.1 snapshot_writer.zig

```zig
pub const SnapshotWriterError = error{
    /// pool.acquire() returned ExhaustedPool. HTTP 503.
    PoolExhausted,
    /// INSERT into instance_state_snapshots failed. HTTP 500.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
    /// The instance is in a terminal status that should not receive snapshots
    /// (COMPLETED snapshots are taken by the completion path, not by the interval
    /// trigger — this error means an invalid call on a non-ACTIVE instance).
    InstanceTerminal,
};

pub const SnapshotInterval = struct {
    /// Take a snapshot every N events. Default: 1000.
    events_per_snapshot: u32,
};

/// Default interval: 1000 events between snapshots.
pub const DEFAULT_SNAPSHOT_INTERVAL: u32 = 1000;

pub const SnapshotWriter = struct {
    pool: *Pool,

    pub fn init(pool: *Pool) SnapshotWriter;

    pub fn deinit(self: *SnapshotWriter) void;

    /// Take a snapshot of the given InstanceState at the given sequence number.
    /// Stores a JSONB blob of the full state into instance_state_snapshots.
    ///
    /// Called from two paths:
    ///   1. Interval path: after every N events (N = DEFAULT_SNAPSHOT_INTERVAL).
    ///   2. Completion path: when an instance reaches COMPLETED, CANCELLED, or ERROR.
    ///
    /// The caller must have already committed the event that produced `state`
    /// before calling this function — the snapshot is a secondary write and must
    /// not be in the same transaction as the event append (snapshot writes can
    /// be async / fire-and-forget; a failed snapshot write does not roll back
    /// the event).
    ///
    /// Idempotency: INSERT ... ON CONFLICT (instance_id, snapshot_seq) DO NOTHING.
    /// If a snapshot already exists at this seq (e.g. from a retry), this is a no-op.
    pub fn takeSnapshot(
        self: *SnapshotWriter,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        state: *const InstanceState,
        snapshot_seq: i64,
    ) SnapshotWriterError!void;

    /// Conditionally take a snapshot if the sequence number crosses the interval
    /// boundary. Compares `current_seq` against the most recent snapshot_seq for
    /// this instance; if (current_seq - latest_snapshot_seq) >= interval, takes a snapshot.
    ///
    /// If no prior snapshot exists, takes a snapshot (first snapshot = baseline).
    /// Also takes a snapshot on terminal status (COMPLETED, CANCELLED, ERROR)
    /// regardless of interval — this is the "instance completion" path.
    ///
    /// Returns true if a snapshot was taken, false if skipped.
    pub fn maybeTakeSnapshot(
        self: *SnapshotWriter,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        state: *const InstanceState,
        current_seq: i64,
        status: InstanceStatus,
        interval: u32,
    ) SnapshotWriterError!bool;
};
```

### 4.2 reconstruction.zig (modified — new public function)

```zig
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
///   4. Optional write-back (same as existing reconstructInstance).
///
/// The snapshot path joins event_payloads_overflow to reconstruct full event
/// payloads, exactly as full replay does. The event query for the snapshot
/// delta path uses the same transparent payload splicing as the full path.
///
/// Security: all SQL parameters bound as $N — no SQL string interpolation.
pub fn reconstructInstanceWithSnapshot(
    allocator: std.mem.Allocator,
    pool: *Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,
    instance_id: Uuid,
    write_back: bool,
) ReconstructionError!InstanceState;
```

The existing `reconstructInstance` and `reconstructInstancePointInTime` functions are preserved unchanged as fallback paths. `reconstructInstanceWithSnapshot` is the new primary entry point for callers that want the performance benefit of snapshots.

---

## 5. Algorithm: Snapshot-Assisted Reconstruction

### 5.1 Snapshot Creation

Snapshot creation is triggered at two points:

**Interval trigger (non-blocking, async-best-effort):**
- After an event is committed and the `instance_projections` row is updated, the caller (e.g. `completeTask` in `instance.zig`) calls `snapshot_writer.maybeTakeSnapshot(state, current_seq, status, interval)`.
- `maybeTakeSnapshot` queries `SELECT MAX(snapshot_seq) FROM instance_state_snapshots WHERE instance_id = $1`.
- If `(current_seq - latest_snapshot_seq) >= interval`, or if no prior snapshot exists, `takeSnapshot` is called.
- A failed snapshot write is logged but does not cause the operation to fail — the next interval boundary will retry.

**Completion trigger (synchronous):**
- When an instance reaches COMPLETED, CANCELLED, or ERROR status, the completion path calls `takeSnapshot` unconditionally.
- A failed completion snapshot is also logged but non-fatal; the instance's final state can always be reconstructed from the full event log.

### 5.2 Reconstruction Algorithm

```
reconstructInstanceWithSnapshot(instance_id):
  1. Load definition snapshot (unchanged — needed for transition()).
  2. Query latest snapshot:
       SELECT snapshot_seq, state_blob
       FROM instance_state_snapshots
       WHERE instance_id = $1
       ORDER BY snapshot_seq DESC
       LIMIT 1
  3. If snapshot exists:
     a. Parse state_blob → InstanceState (initialise tokens, variables,
        join_counters, pending_task_nodes, error_detail, cancelled_branch_ids
        from the JSON blob).
     b. Query delta events:
          SELECT e.event_type, e.payload, e.sequence_number,
                 COALESCE(epo.payload, e.payload) AS full_payload
          FROM events e
          LEFT JOIN event_payloads_overflow epo ON e.event_id = epo.event_id
          WHERE e.instance_id = $1 AND e.sequence_number > $2
          -- Also UNION ALL with events_archive (same join pattern)
          ORDER BY sequence_number ASC
     c. For each delta event:
        - Map to TransitionEvent.
        - Call transition(snapshot, current_state, te, triggering_seq).
        - Set current_state = result.state.
     d. Return current_state.
  4. If no snapshot exists:
     a. Fall back to full replay (existing reconstructInstance logic).
     b. Return reconstructed state.
```

### 5.3 Performance Analysis

**Full replay (baseline):**
- 10,000 events: NFR-04 target (5s).

**Snapshot-assisted replay:**
- Instance with 100,000 events, snapshots every 1,000 events:
  - Latest snapshot at seq 100,000 (or 99,000).
  - Delta: 0–999 events to replay.
  - Replay time: 1,000 events processed in well under 1s.
  - Snapshot lookup: O(log n) via descending index — sub-millisecond.
- Snapshot-assisted replay is O(delta) instead of O(total_events), bounded by the snapshot interval.

**Worst case (no snapshot exists):**
- Falls back to full replay — identical performance to the current path.

**NFR-04 verification:**
- Benchmark: create instance with 100,000 events, verify snapshot-assisted replay < 1s.
- Full replay benchmark (10,000 events, no snapshot) unchanged — still < 5s.
- The benchmark lives in the existing `zig build bench` infrastructure.

---

## 6. Error Taxonomy

### SnapshotWriterError

| Error | Condition | HTTP Mapping |
|---|---|---|
| `PoolExhausted` | `pool.acquire()` failed — pool exhausted or shutdown. | 503 |
| `PersistenceFailed` | INSERT into `instance_state_snapshots` failed, or SELECT latest snapshot failed. | 500 |
| `OutOfMemory` | Allocator exhausted during JSON serialisation or query. | 500 |
| `InstanceTerminal` | `takeSnapshot` called on a non-ACTIVE instance outside the completion path. | programming error (assert in debug, no-op in release) |

### Reconstruction error extensions

The existing `ReconstructionError` set from `reconstruction.zig` applies unchanged. No new error variants are needed — a corrupt snapshot blob is handled by falling back to full replay (the snapshot lookup is best-effort; reconstruction always succeeds via the full replay path if snapshot-assisted replay fails).

Specific failure recovery:
- **Corrupt `state_blob`:** If JSON parsing of a snapshot's `state_blob` fails, the snapshot is treated as absent and full replay is used. The corrupt snapshot row is logged but not deleted (manual investigation may be needed).
- **Snapshot newer than latest event:** If `snapshot_seq > MAX(sequence_number)`, the snapshot is ignored (data inconsistency) and full replay is used.

---

## 7. Integration Points

### 7.1 Callers of snapshot creation

Snapshot creation is triggered from `InstanceStore` methods that commit events:

- `InstanceStore.create()` — after initial event (seq 1). First snapshot at seq 1 (baseline).
- `InstanceStore.completeTask()` — after `task_completed` event is committed, calls `maybeTakeSnapshot`.
- `InstanceStore.cancelInstance()` — after `INSTANCE_CANCELLED` event, calls `takeSnapshot` (completion path).
- `InstanceStore.setInstanceError()` — after `EXECUTION_ERROR` event, calls `takeSnapshot` (completion path).

### 7.2 Callers of snapshot-assisted reconstruction

- API endpoint `GET /instances/:id` — currently calls `InstanceStore.getById()` which reads from `instance_projections` directly; snapshot-assisted reconstruction is used when the projection is stale or suspected corrupt (e.g. `write_back = true` in `reconstructInstance`).
- `reconstructInstance` with `write_back = true` — internal consistency repair path.
- `reconstructInstancePointInTime` — point-in-time reconstruction for audit/XC-05 determinism checks; snapshots can accelerate this if the requested point-in-time is after a snapshot.
- Background integrity checker (future) — periodically reconstructs instances and compares against projections; snapshots make this viable at scale.

### 7.3 Event payload reconstruction

The snapshot-assisted path must join `event_payloads_overflow` exactly as full replay does. The `events` table stores inline payloads up to 4096 bytes; larger payloads are stored in `event_payloads_overflow` and referenced via `{"$ref": "overflow"}` in the `events.payload` column. The reconstruction query must LEFT JOIN `event_payloads_overflow` and use `COALESCE(epo.payload, e.payload)` to reconstruct the full payload before passing it to `mapToTransitionEvent`.

The existing `reconstruction.zig` currently queries only `events.payload` without the overflow join. ISS-601 adds this join to **both** the full replay path and the snapshot delta path. This is an acceptance criterion: "Replay joins `event_payloads_overflow` to reconstruct full payloads."

---

## 8. Dependencies

| Dependency | Direction | Why |
|---|---|---|
| `src/db/pool.zig` | snapshot_writer → Pool | All database access for snapshot CRUD. |
| `src/engine/transition.zig` | snapshot_writer + reconstruction → transition | `InstanceState` type, `InstanceStatus` enum, `Token` struct — types only, no function call. |
| `src/engine/reconstruction.zig` | self (modified) | Existing full replay path is the fallback when no snapshot exists. |
| `src/definition/snapshot.zig` | reconstruction → snapshot_store | DefinitionGraph for transition() during replay. |
| `std.json` | snapshot_writer + reconstruction → stdlib | JSON serialisation/deserialisation of `state_blob`. |

**Must NOT depend on:**
- `src/api/` — direction is API → engine only.
- `src/tasks/` — lateral dependency; must not cross-import.
- `src/engine/transition.zig` logic — `snapshot_writer.zig` only imports types from transition, never calls `transition()`.

---

## 9. Key Invariants

1. **Snapshot idempotency.** Taking a snapshot at the same `(instance_id, snapshot_seq)` twice is a no-op (ON CONFLICT DO NOTHING). This protects against retry storms.

2. **Snapshot is always after the event.** A snapshot at `snapshot_seq = N` represents state AFTER applying event N. The delta query uses `sequence_number > snapshot_seq` (strict greater-than).

3. **Snapshot failure is non-fatal.** A failed snapshot write does not cause the triggering operation (event append, task completion) to fail. The next interval boundary or completion will retry. Worst case: no snapshot exists and full replay is used — functionally correct, just slower.

4. **Snapshot-assisted replay is deterministic.** Same as full replay: replaying the same events through the same `transition()` function with the same starting state produces identical final state.

5. **Snapshot state matches transition output.** The `state_blob` stored in a snapshot is exactly the `InstanceState` returned by `transition()` at that sequence number. No transformation or projection — the raw state.

6. **No snapshot for initial state.** The initial `InstanceState` (empty tokens, empty variables, status ACTIVE) is trivial to construct and does not need a snapshot. The first snapshot is at seq 1 (after `instance_started`).

7. **Overflow payload join is applied uniformly.** Both the full replay path and the snapshot delta path join `event_payloads_overflow`. The existing `reconstruction.zig` is updated to add this join to the full replay path as part of ISS-601.

8. **Snapshot intervals are configurable.** The default 1000-event interval is stored as a constant in `snapshot_writer.zig`. It can be made configurable via `BPM_SNAPSHOT_INTERVAL` environment variable in a future enhancement, but the initial implementation uses a fixed constant.

---

## 10. Migration

One new migration file, numbered to follow existing migrations:

```sql
-- NNN_instance_state_snapshots.sql

CREATE TABLE IF NOT EXISTS instance_state_snapshots (
    instance_id   UUID        NOT NULL,
    snapshot_seq  BIGINT      NOT NULL,
    state_blob    JSONB       NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (instance_id, snapshot_seq)
);

CREATE INDEX IF NOT EXISTS idx_instance_state_snapshots_latest
    ON instance_state_snapshots (instance_id, snapshot_seq DESC);
```

No changes to existing tables. No data migration needed.

---

## 11. Test Strategy

### Unit tests (no DB)

- Serialise/deserialise `InstanceState` to/from `state_blob` JSON — round-trip fidelity.
- `maybeTakeSnapshot` interval arithmetic: test boundary conditions (seq exactly at interval, seq one short, seq one past).
- `SnapshotWriterError` error set compilation.

### Integration tests (real PostgreSQL)

- Create instance with 50 events, take snapshot at seq 25, reconstruct with `reconstructInstanceWithSnapshot`: assert reconstructed state matches projection.
- Create instance with 50 events, no snapshot, reconstruct: assert falls back to full replay and produces correct state.
- Create instance with 2,500 events (crosses 2 snapshot boundaries), verify snapshots exist at seq 1000 and seq 2000, reconstruct and assert correctness.
- Create instance, take snapshot, then add event with overflow payload (>4KB), reconstruct: assert overflow payload is correctly joined and replayed.
- Idempotency: take snapshot at seq N twice, assert second call is a no-op.
- Corrupt snapshot: manually insert a snapshot with invalid JSON in `state_blob`, reconstruct: assert full replay fallback and correct state.

### Benchmark

- `zig build bench` extended with ISS-601 benchmark:
  - Instance with 100,000 events, snapshot every 1,000.
  - Measure `reconstructInstanceWithSnapshot` wall-clock time.
  - Assert < 1s (well under NFR-04 5s target).
  - Compare against full replay of 10,000 events (still < 5s).

### Pipeline tests

- Create instance via API, complete tasks to generate events past the snapshot interval, verify instance state via `GET /instances/:id`.
- Cancel instance, verify final snapshot exists and contains CANCELLED status.

---

## 12. Open Questions

1. **Async snapshot writes.** Should snapshot writes be fire-and-forget (spawned in a separate DB connection outside the event transaction)? The current design writes snapshots synchronously but outside the event transaction. If snapshot write latency becomes an issue, a background worker thread could consume a snapshot queue. Not needed for the initial implementation — snapshots are fast INSERT operations on a table with no foreign keys or triggers.

2. **Snapshot retention.** Should old snapshots be pruned? The table grows linearly with events (1 row per 1,000 events per instance). For an instance with 1M events, that is 1,000 snapshot rows — negligible. Explicit retention is not needed for the initial implementation but can be added later: keep the latest N snapshots per instance, or keep snapshots older than 30 days only at every 10,000th event.

3. **Per-instance interval override.** Should the snapshot interval be configurable per definition or per instance? The initial implementation uses a global constant. Per-definition configuration could be useful for instances expected to accumulate very large event counts (e.g. long-running compliance processes). Defer to a future enhancement.

4. **Snapshot compression.** Should `state_blob` be compressed for very large variable maps? JSONB in PostgreSQL already applies compression. No additional compression layer is needed unless profiling shows snapshot INSERT/read as a bottleneck.

---

## 13. Acceptance Criteria Checklist

- [ ] Periodic per-instance state snapshot; reconstruction folds events since the latest snapshot instead of full replay.
- [ ] Replay joins `event_payloads_overflow` to reconstruct full payloads (both full replay path and snapshot delta path).
- [ ] NFR-04 (5s for 10k events) verified by benchmark; large-instance path documented and benchmarked at < 1s for snapshot-assisted replay of 100k-event instances.
- [ ] Snapshot table created: `instance_id` (UUID), `snapshot_seq` (BIGINT), `state_blob` (JSONB NOT NULL), `created_at` (TIMESTAMPTZ), with primary key on `(instance_id, snapshot_seq)`.
- [ ] Snapshot interval: every 1000 events, and on instance completion (COMPLETED, CANCELLED, ERROR).
- [ ] Existing `reconstructInstance` and `reconstructInstancePointInTime` preserved unchanged as fallback paths.
