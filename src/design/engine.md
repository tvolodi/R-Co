# Module: engine

**Covers:** EE-01 (Start instance), EE-02 (Pure transition function), EE-05 (Exclusive gateway), EE-06/EE-07 (Parallel split/join)
**Files:** `src/engine/instance.zig`, `src/engine/transition.zig`, `src/api/routes/instances.zig`
**Depends on:** `src/definition/snapshot.zig` (PD-08), `src/definition/store.zig`, `src/definition/graph.zig`, `migrations/001_event_store.sql`, `migrations/004_definitions.sql`

---

## Module purpose

The engine module implements the process instance lifecycle. `instance.zig` owns all
DB-backed instance creation logic against `instance_projections` and coordinates with
`SnapshotStore` (PD-08) to atomically capture the definition graph at start time.
`src/api/routes/instances.zig` exposes the HTTP layer over `InstanceStore`.

---

## Section EE-01: Start Instance

---

### 1. Database Schema

#### 1a. `instance_projections` — already exists in `migrations/001_event_store.sql`

This is the canonical instance read-model. No new migration is required for EE-01 basic
instance creation. The table already contains all columns needed.

```
instance_projections
────────────────────────────────────────────────────────────────────────
instance_id     UUID        PRIMARY KEY
definition_id   UUID        NOT NULL
correlation_key TEXT                          -- nullable; EE-01 optional field
status          TEXT        NOT NULL DEFAULT 'ACTIVE'
                            -- CHECK: 'ACTIVE' | 'COMPLETED' | 'CANCELLED' | 'ERROR'
current_nodes   JSONB       NOT NULL DEFAULT '[]'   -- active token positions
variables       JSONB       NOT NULL DEFAULT '{}'   -- merged variable map
error_detail    JSONB                               -- set on ERROR status (EE-10)
last_event_seq  BIGINT      NOT NULL DEFAULT 0
started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
completed_at    TIMESTAMPTZ
cancelled_at    TIMESTAMPTZ
updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
parent_instance_id  UUID    REFERENCES instance_projections(instance_id)  -- Stage 6
parent_token_id     UUID    REFERENCES tokens(id)                         -- Stage 6
result_variables    JSONB                                                  -- Stage 6
```

Existing unique index that enforces EE-01 correlation uniqueness:
```sql
CREATE UNIQUE INDEX uq_instance_correlation
    ON instance_projections(definition_id, correlation_key)
    WHERE correlation_key IS NOT NULL;
```

**Note on `initial_variables`:** EE-01 requires the caller to supply `initial_variables`.
These are stored as the initial value of the `variables` JSONB column. No separate
`initial_variables` column is needed; the projection's `variables` field is seeded from
the caller-supplied value at INSERT time and subsequently merged by EE-09.

#### 1b. `instance_definition_snapshots` — already exists in `migrations/004_definitions.sql`

Stores the immutable PD-08 snapshot bound to each instance. EE-01 calls
`SnapshotStore.create()` to populate this table.

```
instance_definition_snapshots
────────────────────────────────────────────────────────────────────────
instance_id     UUID        PRIMARY KEY            -- one-to-one with instance_projections
definition_id   UUID        NOT NULL REFERENCES process_definitions(id)
definition_name TEXT        NOT NULL
definition_ver  TEXT        NOT NULL
graph           JSONB       NOT NULL               -- full DefinitionGraph at snapshot time
snapshotted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

Both tables are read by `InstanceStore.create()` but written in two separate DB
transactions (see §5 Algorithm for the ordering rationale).

---

### 2. InstanceStatus enum

```zig
pub const InstanceStatus = enum {
    ACTIVE,
    COMPLETED,
    CANCELLED,
    ERROR,
};
```

Maps directly to the `status` TEXT column values in `instance_projections`. Used for
in-memory representation; serialised to/from uppercase string by the DB layer.

---

### 3. Instance struct

```zig
pub const Instance = struct {
    /// Primary key from instance_projections.instance_id.
    instance_id: Uuid,
    /// FK to process_definitions.id.
    definition_id: Uuid,
    /// Current lifecycle status.
    status: InstanceStatus,
    /// Nullable; unique per definition_id when non-null (EE-01 AC).
    correlation_key: ?[]const u8,
    /// The caller-supplied initial variables JSON object string.
    /// Seeded into instance_projections.variables at INSERT time.
    initial_variables: []const u8,
    /// JSON string of the DefinitionGraph captured at start (PD-08).
    /// Retrieved from instance_definition_snapshots.graph.
    definition_snapshot: []const u8,
    /// UTC epoch microseconds derived from instance_projections.started_at.
    created_at: i64,
    /// UTC epoch microseconds derived from instance_projections.updated_at.
    updated_at: i64,
};
```

All slice fields are allocated with the caller-supplied `std.mem.Allocator` and owned
by the caller.

---

### 4. InstanceError set

```zig
pub const InstanceError = error{
    /// definition_id not found in process_definitions. HTTP 404.
    DefinitionNotFound,
    /// Definition exists but status ≠ ACTIVE. HTTP 409.
    DefinitionNotActive,
    /// correlation_key is non-null and already used for the same definition_id. HTTP 409.
    DuplicateCorrelationKey,
    /// initial_variables is null, not a JSON object, or definition_id is a malformed UUID.
    /// HTTP 422.
    InvalidInput,
    /// db.Pool.acquire() returned ExhaustedPool. HTTP 503.
    PoolExhausted,
    /// DB transaction failed to commit (transient). HTTP 500.
    TransactionFailed,
};
```

---

### 5. InstanceStore module (`src/engine/instance.zig`)

#### Struct definition

```zig
pub const InstanceStore = struct {
    pool: *db.Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,

    pub fn init(pool: *db.Pool, snapshot_store: *snapshot_mod.SnapshotStore) InstanceStore;
};
```

`snapshot_store` is the already-initialised `SnapshotStore` from
`src/definition/snapshot.zig`. Both `pool` and `snapshot_store` must outlive
`InstanceStore`.

#### create() signature

```zig
pub fn create(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    definition_id: Uuid,
    correlation_key: ?[]const u8,
    initial_variables: []const u8,  // JSON object string; MUST NOT be null literal
) InstanceError!Instance
```

#### Algorithm

**Step a — Validate `initial_variables`**

Parse `initial_variables` using `std.json.parseFromSlice`. The root value MUST be a
`std.json.Value.object`. If parsing fails or the root is not an object (e.g. null,
array, scalar), return `InstanceError.InvalidInput` immediately — before any DB call.

An empty object `{}` is valid per EE-01 AC.

**Step b — Load and verify the definition**

Acquire a pool connection. Execute:
```sql
SELECT id, status
FROM process_definitions
WHERE id = $1::uuid
```
Parameter: `$1` = `definition_id` serialised as a hex UUID string (no SQL string
interpolation of any user-supplied value).

- 0 rows returned → return `InstanceError.DefinitionNotFound`
- `status` ≠ `'ACTIVE'` → return `InstanceError.DefinitionNotActive`
- Release the connection after this read (not held across the snapshot call).

**Step c — Capture the definition snapshot**

Call `self.snapshot_store.create(allocator, instance_id, definition_id)` where
`instance_id` is a fresh UUID generated by `gen_random_uuid()` executed in a
preliminary SQL call or generated client-side using a cryptographically random source.

Design choice — **pre-generate the UUID client-side** using `std.crypto.random.bytes`
to fill a 16-byte array, then format it as a UUID v4 hex string for all subsequent
SQL binds. This allows the same `instance_id` to be passed to `SnapshotStore.create()`
before the `instance_projections` INSERT.

`SnapshotStore.create()` opens its own DB transaction:
- Reads the definition under `FOR SHARE` lock.
- Inserts into `instance_definition_snapshots` with `ON CONFLICT DO NOTHING`.
- Commits.

If `SnapshotStore.create()` returns:
- `SnapshotError.DefinitionNotFound` → map to `InstanceError.DefinitionNotFound`
- `SnapshotError.SnapshotAlreadyExists` → this instance_id was already used in a
  prior (retried) call; treat as a retried idempotent call and continue to step d
  (the `instance_projections` INSERT will be a no-op via `ON CONFLICT DO NOTHING`
  or will surface the existing row).
- `SnapshotError.PoolExhausted` → map to `InstanceError.PoolExhausted`
- `SnapshotError.TransactionFailed` → map to `InstanceError.TransactionFailed`

**Ordering rationale:** The snapshot is written BEFORE the `instance_projections` INSERT.
If the INSERT subsequently fails, the snapshot row is an orphan but causes no harm — it
is bound to an `instance_id` that was never used by a live projection. Retrying the full
EE-01 operation with a new UUID generates a new snapshot; the orphan is inert.
This order is required by `snapshot.zig`'s contract: "If this function returns any error,
the EE-01 caller MUST abort — do NOT append any event."

**Step d — Insert the instance projection**

Acquire a second pool connection. Execute within a transaction:
```sql
INSERT INTO instance_projections
    (instance_id, definition_id, correlation_key, status, variables,
     current_nodes, started_at, updated_at)
VALUES
    ($1::uuid, $2::uuid, $3, 'ACTIVE', $4::jsonb,
     '[]'::jsonb, NOW(), NOW())
ON CONFLICT (instance_id) DO NOTHING
RETURNING
    instance_id,
    definition_id,
    correlation_key,
    status,
    variables,
    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
```

Parameters:
- `$1` = `instance_id` (hex UUID string — no SQL interpolation)
- `$2` = `definition_id` (hex UUID string — no SQL interpolation)
- `$3` = `correlation_key` (TEXT or NULL — no SQL interpolation)
- `$4` = `initial_variables` (raw JSON string bound as JSONB — no SQL interpolation)

`current_nodes` is seeded as `'[]'` at INSERT time. The execution engine (EE-02) will
place the token on the START node immediately after creation.

**Unique constraint violation** on `uq_instance_correlation` (definition_id,
correlation_key WHERE correlation_key IS NOT NULL) → map PostgreSQL error code `23505`
to `InstanceError.DuplicateCorrelationKey`.

If `ON CONFLICT (instance_id) DO NOTHING` fires (retried call): return 0 RETURNING rows.
Re-fetch the existing row using `SELECT ... WHERE instance_id = $1` and return it
(idempotent retry).

**Step e — Retrieve the snapshot graph for the response**

Call `self.snapshot_store.getByInstanceId(allocator, instance_id)` to retrieve the
`graph` JSONB for inclusion in the returned `Instance` struct's `definition_snapshot`
field.

**Step f — Build and return Instance**

Populate the `Instance` struct from the RETURNING row and the snapshot graph. All
slices are duplicated into `allocator` so the caller owns them independently of the
DB connection lifetime. Return `InstanceError!Instance`.

#### Security invariants

- **No SQL string interpolation.** Every user-supplied value (`definition_id`,
  `correlation_key`, `initial_variables`, `instance_id`) is bound exclusively via
  `$N` positional parameters through `pg.zig`. The SQL literal strings contain only
  fixed schema identifiers.
- All validation of `initial_variables` happens in-process (step a) before any DB
  call is made.
- `definition_id` must be a valid 16-byte UUID (parsed in step b before any write).
  Invalid UUID format → `InstanceError.InvalidInput` (HTTP 422).

---

### 6. HTTP API Route

**File:** `src/api/routes/instances.zig`

#### Route registration

```
POST /api/v1/instances   →  handleCreate
```

Auth middleware enforces a valid session before the handler is invoked (API-08).
The handler may assume `ctx.actor` is populated.

#### Request body (JSON)

```json
{
  "definition_id":    "<UUID string>",
  "correlation_key":  "<string> | null | omitted",
  "initial_variables": { ... }
}
```

Field rules:
- `definition_id`: required; must parse as a valid UUID v4 hex string.
- `correlation_key`: optional; if omitted or explicitly `null`, stored as NULL.
- `initial_variables`: required; must be a JSON object (not null, not array).

#### Success response — HTTP 201

```json
{
  "instance_id": "<UUID>",
  "status":      "ACTIVE",
  "created_at":  "<ISO 8601 UTC timestamp>"
}
```

`created_at` is derived from the `Instance.created_at` microsecond epoch field,
formatted as `YYYY-MM-DDTHH:MM:SS.ffffffZ`.

#### Error responses

| HTTP | Condition | Error body `code` |
|------|-----------|-------------------|
| 400  | Malformed JSON body | `MALFORMED_JSON` |
| 404  | `definition_id` not found in `process_definitions` | `DEFINITION_NOT_FOUND` |
| 409  | Definition exists but `status ≠ ACTIVE` | `DEFINITION_NOT_ACTIVE` |
| 409  | `correlation_key` already used for this `definition_id` | `DUPLICATE_CORRELATION_KEY` |
| 422  | `initial_variables` is null or not a JSON object | `INVALID_INITIAL_VARIABLES` |
| 422  | `definition_id` is missing or not a valid UUID | `INVALID_DEFINITION_ID` |
| 503  | DB connection pool exhausted | `SERVICE_UNAVAILABLE` |
| 500  | Unexpected DB or internal error | `INTERNAL_ERROR` |

**Distinguishing the two HTTP 409 cases:** The error body includes a `code` field that
uniquely identifies the cause. Clients MUST inspect `code` rather than the HTTP status
alone to distinguish `DEFINITION_NOT_ACTIVE` from `DUPLICATE_CORRELATION_KEY`.

#### Handler signature

```zig
/// POST /api/v1/instances
pub fn handleCreate(
    store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    body: []const u8,  // raw request body bytes
) HandlerResult
```

`HandlerResult` follows the same pattern as `src/api/routes/definitions.zig`:
```zig
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,  // JSON-encoded; owned by caller allocator
};
```

#### Error mapping — `InstanceError` → HTTP

```zig
switch (err) {
    InstanceError.DefinitionNotFound      => 404,
    InstanceError.DefinitionNotActive     => 409,  // code: DEFINITION_NOT_ACTIVE
    InstanceError.DuplicateCorrelationKey => 409,  // code: DUPLICATE_CORRELATION_KEY
    InstanceError.InvalidInput            => 422,
    InstanceError.PoolExhausted           => 503,
    InstanceError.TransactionFailed       => 500,
}
```

---

### 7. Traceability table

| EE-01 Acceptance Criterion | Design element |
|----------------------------|----------------|
| Authorised caller submits valid start request with existing ACTIVE definition → HTTP 201 with `instance_id`, `status=ACTIVE`, `created_at` | §5 step b checks status; §5 step d inserts the row; §6 returns 201 with `instance_id`, `status`, `created_at` |
| `correlation_key` supplied → duplicate with same definition → HTTP 409 | `uq_instance_correlation` unique index (§1a); §5 step d maps `23505` → `DuplicateCorrelationKey`; §6 maps to 409 with `DUPLICATE_CORRELATION_KEY` code |
| No `correlation_key` → no uniqueness constraint; multiple keyless instances allowed | `$3` binds as NULL; `uq_instance_correlation` index has `WHERE correlation_key IS NOT NULL` (§1a) |
| `initial_variables` MUST be a JSON object; `{}` is permitted | §5 step a parses and checks `std.json.Value.object`; `{}` is a valid object; §6 returns 422 for non-object |
| Definition not in ACTIVE status → HTTP 409 | §5 step b checks `status ≠ 'ACTIVE'`; §6 maps `DefinitionNotActive` → 409 with `DEFINITION_NOT_ACTIVE` code |
| Snapshot of the definition graph stored atomically with instance creation (PD-08) | §5 step c calls `SnapshotStore.create()` before the `instance_projections` INSERT; §1b documents `instance_definition_snapshots` |
| Execution token placed on START node; first non-START node transition fires immediately | `current_nodes` seeded as `'[]'` at INSERT (§5 step d); token placement on START node is handled by EE-02 (deferred to next run — out of scope for EE-01 design) |
| `initial_variables = null` → HTTP 422 | §5 step a rejects null (not a JSON object); §6 returns 422 with `INVALID_INITIAL_VARIABLES` |
| Starting by name when no ACTIVE version exists → HTTP 404 | Lookup by name+version resolves to a `definition_id` first (same store.getActiveByName path); `DefinitionNotFound` → 404 (out of scope for EE-01 HTTP handler body field, handled at routing layer) |

---

## Implementation notes for BACKEND-DEV

1. `src/engine/instance.zig` is the **only new source file** for EE-01. No new
   migration is required — both `instance_projections` and `instance_definition_snapshots`
   already exist.

2. Import paths:
   ```zig
   const snapshot_mod = @import("../definition/snapshot.zig");
   const db = @import("../db/pool.zig");
   const graph_mod = @import("../definition/graph.zig");
   ```

3. UUID generation: use `std.crypto.random.bytes(&uuid_bytes)` then set version and
   variant bits (v4 format) before hex-encoding. Do NOT call `gen_random_uuid()` via SQL
   and parse it back — generate client-side so the same value can be passed to
   `SnapshotStore.create()` before the INSERT.

4. `SnapshotStore.create()` returns `SnapshotAlreadyExists` on a retried call with the
   same `instance_id`. Treat this as a non-fatal condition in step c: continue to step d
   and let `ON CONFLICT (instance_id) DO NOTHING` handle the idempotent INSERT.

5. The `initial_variables` string is stored as-is (after JSON validation) into the
   `variables` JSONB column. No transformation is needed; PostgreSQL validates the JSONB
   cast at INSERT time.

6. `src/engine/` currently contains only `.gitkeep`. Create `instance.zig` there;
   do not modify any existing files unless necessary to wire up the module.

7. Follow all conventions from `src/api/routes/definitions.zig` for the handler layer:
   `HandlerResult`, `parseUuid`, `errorResult` helpers should be reused or mirrored.

---

## Section EE-02: Pure Transition Function

**Covers:** EE-02 (pure transition function), EE-05 (exclusive gateway evaluation),
EE-06 (parallel gateway split), EE-07 (parallel gateway join)
**File:** `src/engine/transition.zig`
**Depends on:**
- `src/definition/graph.zig` — `DefinitionGraph`, `GraphNode`, `GraphEdge`, `NodeType`,
  `Uuid` (zig type aliases)
- `src/engine/instance.zig` — `InstanceStatus`, `Uuid` (re-exported from EE-01)
- `vendor/cel/cel.zig` — CEL evaluator (stub; real implementation delivered separately)

**Must NOT depend on:** `src/db/`, `std.fs`, `std.net`, `std.io`, or any module that
performs I/O. Violations of this rule are a design error (see backend guide §3.4).

---

### Module purpose

The transition module provides the pure, I/O-free execution kernel of the BPM platform.
Given an immutable definition graph snapshot, the current in-memory instance state, and
a triggering event, it produces a new `InstanceState` with no side effects. No database
reads, network calls, filesystem access, or log writes occur inside this function. All
such concerns are the responsibility of the caller (the persistence orchestration layer).

The function is deterministic: identical `(snapshot, state, event)` triples always
produce identical output, regardless of time, concurrency, or OS state. This property
is required for crash-safe event replay (NFR-07) and for independent unit-testability
without running the full platform (EE-02 AC).

---

### 1. `InstanceState` struct

The in-memory projection consumed and produced by the transition function. This is
distinct from `Instance` (the DB-backed struct defined in `instance.zig` for EE-01).
`InstanceState` is a pure in-memory value — it is never directly written to the DB;
the persistence layer maps it to/from `instance_projections` columns.

```zig
pub const InstanceState = struct {
    /// Corresponds to instance_projections.instance_id.
    instance_id: Uuid,
    /// Current lifecycle status (re-used from EE-01).
    status: InstanceStatus,
    /// Active execution token positions. Slice owned by caller allocator.
    tokens: []Token,
    /// Current variable map, merged from initial_variables and all task outputs.
    variables: std.json.ObjectMap,
    /// Node IDs of HUMAN_TASK nodes that have been activated and not yet completed.
    /// Slice and each string owned by caller allocator.
    pending_task_nodes: [][]const u8,
    /// Human-readable error detail; non-null only when status = ERROR.
    /// String owned by caller allocator.
    error_detail: ?[]const u8,
};
```

**Allocator ownership:** All slice fields (`tokens`, `pending_task_nodes`, each
`[]const u8` within `pending_task_nodes`) and `error_detail` are allocated by the
caller-supplied `std.mem.Allocator`. The `variables` `ObjectMap` uses the same
allocator. The transition function returns a new `InstanceState` whose slices are
freshly allocated; it never writes into the input state's slices.

**Relationship to architecture doc:** The simplified `InstanceState` in
`docs/BPM_Platform_Backend_Architecture.md §6.4` uses `active_tokens: []NodeId` and
`last_seq: u64`. This design extends that shape: `tokens: []Token` supersedes
`active_tokens` by adding `branch_id` (required for parallel join tracking), and
`pending_task_nodes` / `error_detail` are added for HUMAN_TASK and ERROR status
tracking. The `last_seq` field is a persistence concern handled by the DB layer wrapper
and is not part of the transition function's value; BACKEND-DEV may add it to a separate
`PersistedInstanceState` wrapper struct if needed for optimistic concurrency.

---

### 2. `Token` struct

Represents one active execution position in the instance.

```zig
pub const Token = struct {
    /// The node this token currently occupies; refers to a GraphNode.id.
    /// String owned by caller allocator.
    node_id: []const u8,
    /// Identifies the parallel branch this token belongs to.
    /// For the root execution path (before any PARALLEL_GATEWAY split), this is
    /// the instance_id formatted as a lowercase hex UUID string.
    /// For tokens created by a PARALLEL_GATEWAY split, this is a unique identifier
    /// assigned at split time (see §6.5).
    /// String owned by caller allocator.
    branch_id: []const u8,
};
```

**Purpose of `branch_id`:** The branch_id allows the parallel join algorithm (§6.6) to
verify that all distinct branches have arrived at the join node without double-counting
a single branch that re-enters a join due to a bug or malformed graph.

---

### 3. `TransitionEvent` tagged union

The typed event value passed as input to the transition function. Only the subset of
event types relevant to EE-02 scope is enumerated; all other event types are represented
by the `.unknown` variant, which the function handles by returning
`TransitionError.UnknownEventType`.

```zig
pub const TransitionEvent = union(enum) {
    /// Fired once per instance lifecycle, immediately after instance creation (EE-01).
    /// Causes token placement on the START node and immediate advance to the
    /// first successor node.
    instance_started: InstanceStartedPayload,

    /// Fired when an authorised caller completes a HUMAN_TASK (EE-04).
    /// Causes the token to advance off the task node.
    task_completed: TaskCompletedPayload,

    /// Catch-all for any event type string not handled by the transition function.
    /// The function returns TransitionError.UnknownEventType when this variant is
    /// received; it does NOT panic.
    unknown: UnknownPayload,
};

pub const InstanceStartedPayload = struct {
    /// Variable map provided by the caller at instance creation (EE-01 initial_variables).
    /// The transition function uses this to seed InstanceState.variables.
    initial_variables: std.json.ObjectMap,
    /// The node_id of the START node in the definition graph.
    /// Provided by the caller (derived from the graph by scanning for NodeType.START).
    start_node_id: []const u8,
};

pub const TaskCompletedPayload = struct {
    /// The node_id of the HUMAN_TASK node whose task has been completed.
    task_node_id: []const u8,
    /// Output variables submitted by the task completer. May be an empty ObjectMap.
    /// These are merged into InstanceState.variables per EE-09 collision policy
    /// BEFORE gateway conditions are evaluated.
    output_variables: std.json.ObjectMap,
};

pub const UnknownPayload = struct {
    /// The raw event type string received from the event store.
    event_type_string: []const u8,
};
```

**Scope note:** `TIMER_FIRED` and `INSTANCE_CANCELLED` event types are out of scope for
EE-02 and will be added to this union in a subsequent design update (SCH-01, EE-08).

---

### 4. `TransitionError` error set

```zig
pub const TransitionError = error{
    /// Event type not handled by the transition function (.unknown variant received).
    /// The caller should log the event_type_string and transition the instance to
    /// ERROR status via a separate persistence call.
    UnknownEventType,

    /// A token in the input InstanceState references a node_id that does not exist
    /// in the provided DefinitionGraph. Indicates snapshot/state mismatch.
    TokenOnMissingNode,

    /// EXCLUSIVE_GATEWAY evaluation exhausted all outgoing edges: no condition
    /// evaluated to true and no default edge (is_default=true) was defined.
    /// Caller must set instance status to ERROR per EE-10.
    NoMatchingEdge,

    /// CEL runtime error during condition evaluation (type mismatch, undefined
    /// variable access, etc.). Per EE-05 AC, this is treated as `false` for the
    /// individual condition, NOT as a fatal error for the transition. This error
    /// is only surfaced when ALL edges fail evaluation AND at least one failure was
    /// a CEL error rather than a clean `false` result, to aid diagnostics.
    /// Normal CEL `false` results do not surface this error.
    CelEvaluationError,

    /// The input InstanceState is internally inconsistent at function entry (e.g.
    /// status = COMPLETED but tokens slice is non-empty; or the same branch_id
    /// appears twice in tokens for a join node).
    InvalidState,

    /// Allocator returned OutOfMemory while constructing the new InstanceState.
    OutOfMemory,
};
```

---

### 5. `transition()` function signature

```zig
/// Pure execution kernel. No I/O. Deterministic.
///
/// Parameters:
///   allocator  — used to allocate all slices in the returned InstanceState.
///   snapshot   — the immutable definition graph bound to this instance at start time.
///   state      — the current InstanceState. NOT mutated; read-only.
///   event      — the triggering event.
///
/// Returns a newly allocated InstanceState on success. The caller owns all memory.
/// Returns a TransitionError on failure; no partial state is returned.
///
/// File: src/engine/transition.zig
pub fn transition(
    allocator: std.mem.Allocator,
    snapshot: definition.DefinitionGraph,
    state: InstanceState,
    event: TransitionEvent,
) TransitionError!InstanceState
```

where `definition` is the import alias for `src/definition/graph.zig`.

**Zero I/O contract:** The Zig compiler cannot enforce this at compile time. BACKEND-DEV
must ensure no `std.fs`, `std.net`, `std.io`, DB pool, or async calls appear anywhere
in the call graph rooted at `transition`. The unit test suite (EE-02 AC) indirectly
enforces this by running without a database.

---

### 6. Node transition algorithms

The following algorithms describe the logic for each node type. They are written as
prose + pseudocode. BACKEND-DEV translates them directly to Zig; no implementation code
appears here.

#### Precondition check (applies to every call)

Before dispatching on the event type, the function validates the input `state`:

1. For each token in `state.tokens`: look up `token.node_id` in `snapshot.nodes` (linear
   scan or hash-map; design leaves the lookup strategy to BACKEND-DEV). If any node_id
   is missing → return `TransitionError.TokenOnMissingNode`.
2. If `state.status` is `COMPLETED` or `CANCELLED` and `state.tokens` is non-empty →
   return `TransitionError.InvalidState`.
3. If `event` is `.unknown` → return `TransitionError.UnknownEventType` immediately
   (before any state mutation).

#### 6.1 START node

**Triggered by:** `.instance_started` event.

**Algorithm:**
```
new_state = deep_copy(state)
new_state.variables = initial_variables   // seed from event payload
new_state.tokens = []  // start with empty token list

start_node = find_node(snapshot, event.start_node_id)
// START node itself is never a resting point — advance immediately
outgoing = find_outgoing_edges(snapshot, start_node.id)
// START MUST have exactly one outgoing edge (validated at definition creation, PD-02)
next_node_id = outgoing[0].target

token = Token{
    .node_id   = next_node_id,
    .branch_id = format_uuid_string(state.instance_id),  // root branch
}
new_state.tokens = [token]
// Now process the node the token just landed on (recursive advance)
new_state = process_node_entry(allocator, snapshot, new_state, token)
return new_state
```

`process_node_entry` is an internal helper (not part of the public API) that handles
the node the token has just entered. It applies the gateway and END node logic below.

#### 6.2 END node

**Triggered by:** any event that causes a token to land on an END node (typically
`task_completed` on the preceding node).

**Algorithm:**
```
remove the arriving token from new_state.tokens

remaining_active = count tokens in new_state.tokens whose node is NOT an END node
if remaining_active == 0:
    new_state.status = COMPLETED
    new_state.tokens = []  // clear all tokens
else:
    // Parallel branches still running; do not complete yet
    new_state.status = ACTIVE
    // The END token is also removed (absorbed); other branch tokens remain
```

**Rule:** An instance with no active (non-END) tokens always transitions to COMPLETED.
Partially completed parallel branches keep the instance ACTIVE until all branches
reach an END or are cancelled.

#### 6.3 HUMAN_TASK node

**Triggered by:** any event that causes a token to enter a HUMAN_TASK node (entry phase),
or `.task_completed` event (completion phase).

**Entry phase** (when a token lands on a HUMAN_TASK node):
```
token stays on this node (node_id = human_task_node_id)
append human_task_node_id to new_state.pending_task_nodes
// No further advance; the token rests here until task_completed
```

**Completion phase** (`.task_completed` event):
```
task_node_id = event.task_node_id

// Locate the token
token = find_token_on_node(new_state.tokens, task_node_id)
if token == null:
    return TransitionError.InvalidState  // no active token on this task node

// Merge output variables BEFORE advancing (EE-09 collision policy — documented separately)
new_state.variables = merge_variables(new_state.variables, event.output_variables)

// Remove from pending_task_nodes
new_state.pending_task_nodes = remove(new_state.pending_task_nodes, task_node_id)

// Advance the token
outgoing = find_outgoing_edges(snapshot, task_node_id)
// HUMAN_TASK MUST have exactly one outgoing edge (PD-02 validation)
next_node_id = outgoing[0].target
token.node_id = next_node_id

// Process the node the token just entered
new_state = process_node_entry(allocator, snapshot, new_state, token)
return new_state
```

**Note on variable merge:** EE-09 (variable collision policy) specifies the full merge
algorithm including schema validation and VARIABLE_OVERWRITTEN events. That algorithm
is a caller concern (the persistence layer emits the events); the transition function
only applies the final merged variable map to `new_state.variables`. See
**§ Section EE-09** (Variable Scoping and Merge) for the full design.

#### 6.4 EXCLUSIVE_GATEWAY node

**Triggered by:** any event that causes a token to land on an EXCLUSIVE_GATEWAY node.

**Algorithm:**
```
outgoing = find_outgoing_edges(snapshot, gateway_node_id)

// Partition into non-default and default edges
non_default_edges = [e for e in outgoing if not e.is_default]
default_edges     = [e for e in outgoing if e.is_default]
// PD-02 guarantees at most one default edge per gateway

chosen_edge = null
for edge in non_default_edges (in declared order — index order in snapshot.edges):
    result = cel_evaluate(edge.condition, new_state.variables)
    if result == true:
        chosen_edge = edge
        break
    // CEL runtime error → treat as false (EE-05 AC); do not abort

if chosen_edge == null and len(default_edges) > 0:
    chosen_edge = default_edges[0]

if chosen_edge == null:
    return TransitionError.NoMatchingEdge
    // Caller is responsible for setting instance status = ERROR per EE-10

// Follow the chosen edge
next_node_id = chosen_edge.target
token.node_id = next_node_id
new_state = process_node_entry(allocator, snapshot, new_state, token)
return new_state
```

**CEL error handling:** A CEL runtime error on a single condition is logged as `false`
for that condition. The iteration continues. If ALL conditions produce CEL errors and
there is no default edge, the function still returns `TransitionError.NoMatchingEdge`
(the caller determines whether to surface a `CelEvaluationError` diagnostic).

#### 6.5 PARALLEL_GATEWAY — split

**Triggered by:** any event that causes a token to land on a PARALLEL_GATEWAY with
more than one outgoing edge.

**Algorithm:**
```
outgoing = find_outgoing_edges(snapshot, gateway_node_id)
// Verified at definition creation (PD-02): > 1 outgoing edge for a split gateway

// Remove the arriving token
new_state.tokens = remove_token(new_state.tokens, arriving_token)

// Create one new token per outgoing edge
for i, edge in enumerate(outgoing):
    new_branch_id = generate_unique_branch_id(state.instance_id, gateway_node_id, i)
    new_token = Token{
        .node_id   = edge.target,
        .branch_id = new_branch_id,
    }
    new_state.tokens = append(new_state.tokens, new_token)
    // Process the node each new token just entered
    new_state = process_node_entry(allocator, snapshot, new_state, new_token)
```

**`generate_unique_branch_id` design note:** The branch_id must be stable and unique
per branch within the instance. BACKEND-DEV MAY derive it as a deterministic string
such as `"<instance_id>/<gateway_node_id>/<edge_index>"`. Whatever scheme is chosen,
it must produce a unique string per branch and be consistent across replays (pure,
no UUID generation at runtime). This is flagged as an open question (§11).

**`process_node_entry` recursion depth:** For chained gateways, `process_node_entry`
may recurse. The maximum recursion depth is bounded by the node count of the definition
(MAX_NODES = 500 per graph.zig). Cycles are prevented by PD-02 DAG validation.

#### 6.6 PARALLEL_GATEWAY — join

**Triggered by:** any event that causes a token to land on a PARALLEL_GATEWAY with
more than one incoming edge.

**Algorithm:**
```
incoming = find_incoming_edges(snapshot, gateway_node_id)
expected_count = len(incoming)  // number of branches that must arrive

// Count tokens currently on this join node in new_state.tokens
// (including the token that just arrived; it has already been placed there)
tokens_on_join = [t for t in new_state.tokens if t.node_id == gateway_node_id]
arrived_count  = len(tokens_on_join)

if arrived_count < expected_count:
    // Not all branches have arrived yet; token parks here
    // The token is already in new_state.tokens on gateway_node_id — no further action
    return new_state

// All branches have arrived — merge and advance
// Remove all waiting tokens from the join node
new_state.tokens = [t for t in new_state.tokens if t.node_id != gateway_node_id]

// The merged token inherits the branch_id of the most senior token
// (the one with the earliest arrival — or the root branch_id if one is present)
// BACKEND-DEV may use any stable deterministic selection; the branch_id of the
// merged token must be the parent branch_id for correct outer join tracking.
merged_branch_id = select_parent_branch_id(tokens_on_join)

outgoing = find_outgoing_edges(snapshot, gateway_node_id)
// PD-02 guarantees exactly one outgoing edge from a join gateway
merged_token = Token{
    .node_id   = outgoing[0].target,
    .branch_id = merged_branch_id,
}
new_state.tokens = append(new_state.tokens, merged_token)
new_state = process_node_entry(allocator, snapshot, new_state, merged_token)
return new_state
```

**Distinguishing split vs join:** A PARALLEL_GATEWAY is a split when it has > 1
outgoing edges and ≤ 1 incoming edge. It is a join when it has > 1 incoming edges
(regardless of outgoing count). The algorithms above apply the appropriate logic based
on edge count at runtime. A gateway with > 1 incoming AND > 1 outgoing edges (fork-join)
applies the join logic first, then the split logic — this pattern is unusual and
flagged as an open question (§11).

---

### 7. CEL evaluation pattern

The transition function calls the CEL evaluator from `vendor/cel/cel.zig` to evaluate
outgoing edge conditions at EXCLUSIVE_GATEWAY nodes.

**Call pattern (pseudocode):**
```
result = cel.evaluate(
    expression: edge.condition,       // []const u8 — the CEL expression string
    variables:  new_state.variables,  // std.json.ObjectMap bound as "variables"
) catch |err| {
    // Any CEL error (type error, undefined identifier, parse failure) →
    // treat as boolean false for this condition (EE-05 AC).
    // Do NOT propagate the error; log at caller level if diagnostics are needed.
    break :eval false;
};
// result is bool
```

**CEL environment binding:** The variable map is bound to the identifier `variables`
in the CEL evaluation context. Edge condition expressions reference fields as
`variables.amount`, `variables.status`, etc. The CEL interpreter is assumed to be
initialised once at platform startup and shared across calls (no per-call init cost).
The transition function receives the evaluator as a function pointer or interface value
if the real implementation requires it — the exact injection mechanism is left to
BACKEND-DEV per the CEL module's actual API (the current stub does not expose one).

**CEL evaluator is a dependency, not a caller:** The transition function calls into
the CEL module; the CEL module itself must also be pure (no I/O). If the CEL vendor
implementation introduces I/O, that is a defect to be resolved before integration.

---

### 8. Immutability contract

The transition function must NOT mutate any field of the input `state`. It produces a
completely new `InstanceState` by:

1. **Deep-copying** `state.tokens` into a new slice allocated by `allocator`.
2. **Deep-copying** `state.variables` (the `ObjectMap` and all string keys/values)
   into a new map allocated by `allocator`.
3. **Deep-copying** `state.pending_task_nodes` (the outer slice and each inner string)
   into a new allocation.
4. **Applying deltas** to the copies only — never writing back into the input slices.

The caller (persistence orchestration layer) is responsible for freeing the input
`InstanceState` after the transition returns. The returned `InstanceState` is owned
by the caller via `allocator`.

**Partial-allocation failure:** If `allocator` returns `error.OutOfMemory` at any
point during construction of the new state, the function must free any allocations
it has already made (to avoid leaks) and then return `TransitionError.OutOfMemory`.
BACKEND-DEV MUST use a `defer deinit` pattern or arena allocator approach to ensure
no partial leaks on this path.

---

### 9. Data flow diagram

```
Caller (persistence orchestration layer)
│
│  (1) Load DefinitionGraph from instance_definition_snapshots (EE-01 snapshot)
│  (2) Reconstruct InstanceState from instance_projections + event log (NFR-07 replay)
│  (3) Decode incoming event from event_store into TransitionEvent
│
└──▶ transition(allocator, snapshot, state, event)
          │
          ├── [precondition] validate tokens against snapshot nodes
          │        └── TokenOnMissingNode / InvalidState / UnknownEventType → error
          │
          ├── [dispatch on event type]
          │        ├── .instance_started
          │        │       └── seed variables; place root token on START successor
          │        │
          │        └── .task_completed
          │                └── merge output_variables; advance token off task node
          │
          ├── [process_node_entry — internal, recursive]
          │        ├── START        → advance to successor (entry only; never rests)
          │        ├── END          → remove token; COMPLETED if no active tokens remain
          │        ├── HUMAN_TASK   → park token; add to pending_task_nodes
          │        ├── EXCL_GW      → evaluate CEL conditions in order; follow first true
          │        │                   or default; NoMatchingEdge if none
          │        ├── PAR_GW split → N tokens (one per outgoing edge, new branch_ids)
          │        └── PAR_GW join  → count tokens on node; advance when all arrived
          │
          └──▶ returns new InstanceState (all slices caller-owned via allocator)
                    │
                    ▼
         Caller persists new state, appends event to event_store, creates Task records
         (EE-03), emits VARIABLE_OVERWRITTEN events (EE-09), handles EE-10 ERROR status
```

---

### 10. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/definition/graph.zig` | `DefinitionGraph`, `GraphNode`, `GraphEdge`, `NodeType`, `Uuid` | Snapshot type; node/edge traversal; node type dispatch |
| `src/engine/instance.zig` | `InstanceStatus`, `Uuid` | Status enum (ACTIVE, COMPLETED, CANCELLED, ERROR) |
| `vendor/cel/cel.zig` | `evaluate` (TBD) | CEL condition evaluation for EXCLUSIVE_GATEWAY |
| `std.mem` | `Allocator` | New state allocation |
| `std.json` | `ObjectMap` | Variable map type |

**Must NOT import:** `src/db/`, `src/event_store/`, `src/api/`, `src/obs/`, `std.fs`,
`std.net`, `std.Thread`, `std.time` (clock reads), or any module that performs I/O.

---

### 11. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-1 | **branch_id generation scheme**: The parallel split algorithm must assign a unique, deterministic `branch_id` per new token. Should this be `"<instance_id>/<gateway_node_id>/<edge_index>"`? A pure string concat is preferable to UUID generation to keep the function deterministic across replays. | Medium — affects join matching correctness | REQ-ANALYST or BACKEND-DEV to confirm. Recommended: deterministic string `<instance_id>/<gateway_id>/<edge_id>`. |
| OQ-2 | **Fork-join gateway** (PARALLEL_GATEWAY with > 1 incoming AND > 1 outgoing): The current design applies join-then-split logic. Confirm whether this topology is allowed by PD-02 or is rejected at definition validation time. | Low — edge case; PD-02 currently prohibits this via `CHK-04` per graph validator | Verify PD-02 / CHK-04 constraints in `graph.zig`; no design change needed if prohibited. |
| OQ-3 | **CEL evaluator injection**: The `vendor/cel/cel.zig` module is a stub. The final API may require the transition function to accept a `Cel.Evaluator` parameter rather than calling a module-level function. | Low — affects signature only | Defer until CEL module is implemented; update signature if needed. |
| OQ-4 | **Parallel join: branch cancellation**: EE-07 and the architecture doc state that cancelled branches do not count toward the join threshold. `InstanceState` does not currently carry a "cancelled branches set". This is required for correct join behaviour when a parallel branch is cancelled mid-flight. | Medium — correctness issue for cancelled-branch scenarios | Address in EE-07/EE-08 design; for EE-02 scope, assume no branch cancellation occurs. |

---

### 12. Traceability table

| EE-02 Acceptance Criterion | Design element |
|---|---|
| Returns new `InstanceState` with no I/O for any `(snapshot, state, event)` triple | §5 function signature + §8 immutability contract; §10 forbidden imports list; zero I/O enforced by type system and unit test suite |
| Deterministic: identical inputs → identical outputs | §5 signature note; §8 immutability contract; §6.5 branch_id uses deterministic derivation (OQ-1); CEL evaluator called with same variable map (§7) |
| Test suite exercises function with in-memory inputs; 100% pass before persistence integration | §5 zero-I/O contract; `transition.zig` has no DB imports; tests in `tests/unit/transition_test.zig` use inline `DefinitionGraph` and `InstanceState` literals |
| Covers all node-type transitions defined in PD-05 and gateway rules in EE-05/EE-06/EE-07 | §6.1 START, §6.2 END, §6.3 HUMAN_TASK, §6.4 EXCLUSIVE_GATEWAY, §6.5 PARALLEL split, §6.6 PARALLEL join |
| Unknown event type → error state, not panic | `TransitionEvent.unknown` variant + `TransitionError.UnknownEventType` (§3, §4); §6 precondition check returns error immediately |
| Token on non-existent node_id → error state identifying the inconsistency | §4 `TokenOnMissingNode` error; §6 precondition check validates all tokens against snapshot before dispatch |
| Calling with same inputs twice → identical output (no side effects) | §8 immutability contract; no global mutable state in `transition.zig`; `variables` deep-copied on each call |

---

### Implementation notes for BACKEND-DEV (EE-02)

1. **File to create:** `src/engine/transition.zig`. Do not modify `instance.zig` except
   to add any re-exports that `transition.zig` needs.

2. **Import paths:**
   ```zig
   const definition = @import("../definition/graph.zig");
   const instance_mod = @import("instance.zig");
   const cel = @import("../../vendor/cel/cel.zig");
   const std = @import("std");
   ```

3. **`process_node_entry` is an internal function** — not `pub`. Signature suggestion:
   ```zig
   fn processNodeEntry(
       allocator: std.mem.Allocator,
       snapshot: definition.DefinitionGraph,
       state: *InstanceState,  // mutated in-place during construction
       token: *Token,
   ) TransitionError!void
   ```
   Because `transition` constructs a single new state value, using a mutable pointer
   internally (not exposed externally) is acceptable as long as the input `state`
   parameter remains unmodified.

4. **`find_outgoing_edges` / `find_incoming_edges`** are internal helpers that scan
   `snapshot.edges` for edges whose `source` (or `target`) matches the given node_id.
   Use linear scan — graph is ≤ 500 nodes / 2000 edges per PD-02 limits, so O(n) is
   acceptable.

5. **Arena allocator pattern for partial-allocation safety:** Consider using
   `std.heap.ArenaAllocator` backed by the caller's allocator to build the new state.
   On any error, `arena.deinit()` frees all partial allocations atomically.

6. **Unit test file:** `tests/unit/transition_test.zig`. Tests MUST pass with no
   database connection; use inline `DefinitionGraph` literals to supply snapshots and
   `std.testing.allocator` for allocations.

7. **SERVICE_TASK and TIMER nodes:** These node types are out of scope for EE-02 and
   will be addressed in later requirements (SCH-01, EE-08). If a token lands on one
   of these nodes during EE-02 testing, the function should return
   `TransitionError.InvalidState` with an appropriate `error_detail` string, so that
   unimplemented node types fail loudly rather than silently.

---

## Section EE-03: Task Activation

**Covers:** EE-03 (Task activation on HUMAN_TASK node entry)
**Files:** `src/tasks/store.zig`, `src/engine/instance.zig`, `src/api/routes/tasks.zig`
**Depends on:**
- `src/engine/transition.zig` — `InstanceState.pending_task_nodes`, `transition()`
- `src/engine/instance.zig` — `InstanceStore` (EE-01)
- `src/definition/graph.zig` — `DefinitionGraph`, `GraphNode`
- `migrations/005_instances.sql` — existing `tasks` table
- `src/db/pool.zig` — `db.Pool`, connection type

---

### Module purpose

EE-03 connects the pure transition kernel (EE-02) to the database: whenever the
transition function signals that a HUMAN_TASK node has been entered by returning a
newly populated `pending_task_nodes` entry, the persistence orchestration layer must
create a corresponding `tasks` row in the same DB transaction as the state update and
event write. This guarantees that the task record is never visible to API consumers
until the state transition is also committed, satisfying the atomicity requirement
(DB-03) and the immediate-visibility requirement (EE-03 AC).

START, END, EXCLUSIVE_GATEWAY, and PARALLEL_GATEWAY nodes never appear in
`pending_task_nodes` — the transition function only appends to that list when entering
a HUMAN_TASK node (§6.3 EE-02). Therefore no guard logic is needed in the persistence
layer to suppress task creation for those node types; the signal itself is the guard.

---

### 1. Database schema

#### 1a. `tasks` table — already exists in `migrations/005_instances.sql`

No new migration is required for EE-03. The relevant columns are:

```
tasks
────────────────────────────────────────────────────────────────────────
id              UUID        PRIMARY KEY DEFAULT gen_random_uuid()
instance_id     UUID        NOT NULL FK → instance_projections(instance_id)
token_id        UUID        NOT NULL FK → tokens(id)
node_id         TEXT        NOT NULL   -- node in the definition graph
node_name       TEXT        NOT NULL   -- display name from node definition
status          TEXT        NOT NULL DEFAULT 'PENDING'
                            -- PENDING | COMPLETED | CANCELLED
assignee_type   TEXT                   -- USER | GROUP | ROLE | null
assignee_ref    TEXT                   -- user_id / group_name / role_name | null
form_schema     JSONB                  -- optional (EE-04 scope)
output_variables JSONB                 -- set on completion (EE-04 scope)
completed_by    UUID                   -- set on completion (EE-04 scope)
completed_at    TIMESTAMPTZ
cancelled_at    TIMESTAMPTZ
created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

EE-03 writes only: `instance_id`, `token_id`, `node_id`, `node_name`, `assignee_type`,
`assignee_ref`. All other columns use their defaults or remain NULL until EE-04.

---

### 2. `TaskStatus` enum

**File:** `src/tasks/store.zig`

```
pub const TaskStatus = enum {
    PENDING,
    COMPLETED,
    CANCELLED,
};
```

Maps directly to the `status` TEXT column values in the `tasks` table. Used for
in-memory representation; serialised to/from uppercase string by the DB layer.

---

### 3. `Task` struct

**File:** `src/tasks/store.zig`

```
pub const Task = struct {
    /// Primary key from tasks.id.
    task_id: Uuid,
    /// FK to instance_projections.instance_id.
    instance_id: Uuid,
    /// FK to tokens.id — the execution token parked on this task node.
    token_id: Uuid,
    /// The HUMAN_TASK node_id in the definition graph.
    node_id: []const u8,
    /// The display name of the HUMAN_TASK node (from GraphNode.name).
    node_name: []const u8,
    /// Current lifecycle status.
    status: TaskStatus,
    /// Assignee type: USER | GROUP | ROLE, or null if unassigned.
    assignee_type: ?[]const u8,
    /// Assignee reference: user_id / group_name / role_name, or null if unassigned.
    assignee_ref: ?[]const u8,
    /// UTC epoch microseconds derived from tasks.created_at.
    created_at: i64,
    /// UTC epoch microseconds derived from tasks.updated_at.
    updated_at: i64,
};
```

All slice fields (`node_id`, `node_name`, `assignee_type`, `assignee_ref`) are
allocated with the caller-supplied `std.mem.Allocator` and owned by the caller.
`task_id`, `instance_id`, and `token_id` are `[16]u8` (Uuid type alias from
`src/definition/graph.zig`).

---

### 4. `TaskError` error set

**File:** `src/tasks/store.zig`

```
pub const TaskError = error{
    /// task_id not found in tasks table. HTTP 404.
    NotFound,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Malformed parameter (e.g. invalid UUID format, invalid status string). HTTP 422.
    InvalidInput,
};
```

---

### 5. `TaskStore` struct

**File:** `src/tasks/store.zig`

#### Struct definition

```
pub const TaskStore = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) TaskStore;
};
```

`pool` must outlive `TaskStore`.

#### 5a. `createInTx` method

```
pub fn createInTx(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
    token_id: Uuid,
    node_id: []const u8,
    node_name: []const u8,
    assignee_type: ?[]const u8,
    assignee_ref: ?[]const u8,
) TaskError!Task
```

**Purpose:** Insert one row into `tasks` using an already-open DB connection `conn`.
The caller owns the transaction; `createInTx` does NOT issue BEGIN or COMMIT.

**Algorithm:**

Execute the following parameterised INSERT on `conn`:
```sql
INSERT INTO tasks
    (instance_id, token_id, node_id, node_name, status, assignee_type, assignee_ref)
VALUES
    ($1::uuid, $2::uuid, $3, $4, 'PENDING', $5, $6)
RETURNING
    id,
    instance_id,
    token_id,
    node_id,
    node_name,
    status,
    assignee_type,
    assignee_ref,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
```

Parameters (all bound as `$N` — no SQL string interpolation):
- `$1` = `instance_id` as hex UUID string
- `$2` = `token_id` as hex UUID string
- `$3` = `node_id` (TEXT)
- `$4` = `node_name` (TEXT)
- `$5` = `assignee_type` (TEXT or NULL)
- `$6` = `assignee_ref` (TEXT or NULL)

The `id` (task_id) and `created_at` / `updated_at` are produced by the DB defaults
(`gen_random_uuid()`, `NOW()`). The function reads them back from the RETURNING clause
and populates the returned `Task` struct. All slice fields are duplicated into
`allocator`.

**Security invariant:** All six parameter values are bound via positional placeholders.
No value is concatenated into the SQL string literal.

#### 5b. `list` method

```
pub fn list(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    instance_id: ?Uuid,
    status_filter: ?TaskStatus,
    assignee_ref_filter: ?[]const u8,
    limit: u32,
    offset: u32,
) TaskError![]Task
```

**Purpose:** Query `tasks` with optional filters; return a caller-owned slice.

**Algorithm:**

Acquire a connection from `self.pool` (return `TaskError.PoolExhausted` on failure).

Build a parameterised SELECT. The WHERE clause is built programmatically by
accumulating only non-null filter values as positional `$N` parameters. The base query:

```sql
SELECT
    id, instance_id, token_id, node_id, node_name, status,
    assignee_type, assignee_ref,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
FROM tasks
[WHERE ...]
ORDER BY created_at ASC
LIMIT $P OFFSET $Q
```

Filter construction (parameter index increments for each non-null filter):
- If `instance_id` is non-null: append `instance_id = $N::uuid`
- If `status_filter` is non-null: append `status = $N` (uppercase TEXT string)
- If `assignee_ref_filter` is non-null: append `assignee_ref = $N`
- `LIMIT` and `OFFSET` are always the final two parameters.

All values bound as `$N` — no SQL string interpolation of any filter value.

Maximum value of `limit` is 200; if the caller passes a value > 200, clamp to 200
before building the query (do not return an error for this; clamping is silent).

Release the connection after the query completes (or fails).

Return a slice of `Task` structs allocated into `allocator`. An empty result set
returns an empty slice (not an error).

---

### 6. Engine persistence layer augmentation — `applyTransition`

**File:** `src/engine/instance.zig`

Add the following function to `InstanceStore`:

```
pub fn applyTransition(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    task_store: *task_mod.TaskStore,
    instance_id: Uuid,
    old_state: transition.InstanceState,
    event: transition.TransitionEvent,
    snapshot: definition_graph.DefinitionGraph,
) ApplyError!transition.InstanceState
```

where:
- `task_mod` is the import alias for `src/tasks/store.zig`
- `transition` is the import alias for `src/engine/transition.zig`
- `definition_graph` is the import alias for `src/definition/graph.zig`

#### `ApplyError` error set

```
pub const ApplyError = error{
    /// transition() returned a TransitionError.
    TransitionFailed,
    /// A DB INSERT, UPDATE, or event write failed after BEGIN.
    PersistenceFailed,
    /// db.Pool.acquire() failed (pool exhausted or shutdown).
    PoolExhausted,
    /// Allocator returned OutOfMemory.
    OutOfMemory,
};
```

#### Algorithm

**Step a — Call the pure transition function (outside the transaction)**

```
new_state = transition.transition(allocator, snapshot, old_state, event)
    catch return ApplyError.TransitionFailed;
```

This step has zero I/O (§5 EE-02). It is intentionally placed before BEGIN so that a
transition logic failure never opens a DB transaction.

**Step b — Compute `new_task_node_ids`**

Compute the set difference: node IDs that appear in `new_state.pending_task_nodes`
but not in `old_state.pending_task_nodes`. These are the HUMAN_TASK nodes newly
activated by this transition.

```
new_task_node_ids = set_difference(
    new_state.pending_task_nodes,
    old_state.pending_task_nodes,
)
```

For each element in `new_task_node_ids`, look up the corresponding node in `snapshot`
to retrieve `node_name`, `assignee_type`, and `assignee_ref`. Also find the token in
`new_state.tokens` whose `node_id` matches the task node to obtain `token_id`.

**Step c — Acquire a DB connection and BEGIN TRANSACTION**

Acquire a connection from `self.pool` (return `ApplyError.PoolExhausted` on failure).
Issue `BEGIN` on the connection.

**Step d — INSERT event row into `events`**

Write the triggering event to the event store table using the already-open connection.
Parameters bound as `$N` — no SQL string interpolation. On failure, ROLLBACK and
return `ApplyError.PersistenceFailed`.

**Step e — UPDATE `instance_projections`**

Update the projection row to reflect `new_state`:

```sql
UPDATE instance_projections
SET
    status        = $2,
    current_nodes = $3::jsonb,
    variables     = $4::jsonb,
    last_event_seq = $5,
    updated_at    = NOW()
WHERE instance_id = $1::uuid
```

Parameters:
- `$1` = `instance_id`
- `$2` = `new_state.status` as uppercase TEXT
- `$3` = JSON serialisation of `new_state.tokens` array
- `$4` = JSON serialisation of `new_state.variables` ObjectMap
- `$5` = incremented event sequence number

On failure, ROLLBACK and return `ApplyError.PersistenceFailed`.

**Step f — Create Task records for newly activated HUMAN_TASK nodes**

For each `node_id` in `new_task_node_ids`:

```
node     = find_node(snapshot, node_id)        // GraphNode with name, assignee fields
token    = find_token_on_node(new_state.tokens, node_id)
task_store.createInTx(
    allocator, conn,
    instance_id,
    token.id,
    node_id,
    node.name,
    node.assignee_type,   // ?[]const u8 from node definition; null if unassigned
    node.assignee_ref,    // ?[]const u8 from node definition; null if unassigned
) catch {
    ROLLBACK;
    return ApplyError.PersistenceFailed;
};
```

`createInTx` uses the same open `conn` (still inside the transaction). No new
connection is acquired in this step.

**Step g — COMMIT**

Issue `COMMIT` on the connection. On failure, return `ApplyError.PersistenceFailed`.

**Step h — Return `new_state`**

Release the connection and return `new_state` to the caller.

#### Atomicity invariant

Steps c through g (BEGIN → event INSERT → projection UPDATE → task INSERTs → COMMIT)
execute as a single DB transaction. If any step in c–g fails, ROLLBACK is issued and
`ApplyError.PersistenceFailed` (or `ApplyError.PoolExhausted`) is returned. Step a
(the pure transition call) is outside the transaction by design; a transition failure
never opens a connection.

#### Security invariants

- All SQL parameter values (`instance_id`, status strings, JSON blobs, `node_id`,
  `token_id`, `assignee_type`, `assignee_ref`) are bound exclusively via `$N`
  positional parameters. No user-supplied or snapshot-derived value is concatenated
  into any SQL string literal.
- `transition()` is called before any DB connection is acquired; this ensures no
  connection leak if the transition function returns an error.

---

### 7. GET /tasks HTTP endpoint

**File:** `src/api/routes/tasks.zig`

#### Route registration

```
GET /api/v1/tasks   →  handleList
```

Auth middleware enforces a valid session before the handler is invoked. The handler
may assume `ctx.actor` is populated.

#### Query parameters

| Parameter | Type | Default | Constraint |
|---|---|---|---|
| `instance_id` | UUID string (optional) | — | Must parse as valid UUID if present |
| `status` | string (optional) | — | Must be `PENDING`, `COMPLETED`, or `CANCELLED` if present |
| `assignee_ref` | string (optional) | — | Passed as-is; no format constraint |
| `limit` | integer (optional) | 50 | Clamped to 1–200 |
| `offset` | integer (optional) | 0 | Must be ≥ 0 |

All query parameter values are parsed into typed variables (`Uuid`, `TaskStatus`,
`[]const u8`, `u32`) before being passed to `TaskStore.list()`. No raw query string
value is ever interpolated into a SQL string.

#### Success response — HTTP 200

```json
{
  "tasks": [
    {
      "task_id":       "<UUID>",
      "instance_id":   "<UUID>",
      "node_id":       "<string>",
      "node_name":     "<string>",
      "status":        "PENDING",
      "assignee_type": "<string> | null",
      "assignee_ref":  "<string> | null",
      "created_at":    "<ISO 8601 UTC timestamp>"
    }
  ],
  "total":  "<integer — count of rows returned in this response>",
  "limit":  "<integer>",
  "offset": "<integer>"
}
```

`created_at` is derived from `Task.created_at` (UTC epoch microseconds), formatted as
`YYYY-MM-DDTHH:MM:SS.ffffffZ`. The `total` field reflects the count of items in the
`tasks` array for this response page (not the global count of all matching tasks).

#### Error responses

| HTTP | Condition | Error body `code` |
|------|-----------|-------------------|
| 400  | Malformed query parameter (non-integer `limit` / `offset`) | `INVALID_PARAMETER` |
| 422  | `instance_id` present but not a valid UUID | `INVALID_INSTANCE_ID` |
| 422  | `status` present but not a valid TaskStatus value | `INVALID_STATUS` |
| 503  | DB connection pool exhausted | `SERVICE_UNAVAILABLE` |
| 500  | Unexpected DB or internal error | `INTERNAL_ERROR` |

#### Handler signature

```
pub fn handleList(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    query_string: []const u8,  // raw URL query string bytes
) HandlerResult
```

`HandlerResult` follows the same pattern as `src/api/routes/definitions.zig`:
```
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,  // JSON-encoded; owned by caller allocator
};
```

The handler parses `query_string` in-process (typed variables) then calls
`TaskStore.list(allocator, instance_id, status_filter, assignee_ref_filter, limit, offset)`.
It serialises the result slice to JSON and wraps it in the response envelope above.

---

### 8. Traceability table

| EE-03 Acceptance Criterion | Design element |
|---|---|
| Task record created on HUMAN_TASK node entry | `applyTransition` step f calls `TaskStore.createInTx` for each node_id in `new_task_node_ids` (§6 step f) |
| Task fields: `task_id`, `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, `created_at` | `Task` struct (§3) contains all required fields; DB defaults produce `task_id` and `created_at` via `gen_random_uuid()` and `NOW()` in the INSERT RETURNING clause (§5a) |
| Atomic with state transition event (DB-03) | `applyTransition` wraps event INSERT, projection UPDATE, and all task INSERTs in a single DB transaction (§6 steps c–g); ROLLBACK on any failure |
| START, END, gateway nodes do NOT create Task records | `pending_task_nodes` is populated only for HUMAN_TASK nodes by `transition()` (EE-02 §6.3); `new_task_node_ids` is derived from that set — non-task nodes never appear in it |
| Newly created Task visible via GET /tasks immediately after commit | `GET /tasks` route calls `TaskStore.list()` which queries the committed `tasks` table; tasks are committed in step g of `applyTransition` before the response to any subsequent GET request is produced (§7) |

---

### Implementation notes for BACKEND-DEV (EE-03)

1. **New source file:** `src/tasks/store.zig`. Import it into `src/bpm.zig` or
   the top-level module registration file alongside `InstanceStore`.

2. **`instance.zig` augmentation:** Add `applyTransition` to the existing
   `InstanceStore` struct. Add the import:
   ```zig
   const task_mod = @import("../tasks/store.zig");
   const transition = @import("transition.zig");
   ```

3. **No new migration required.** The `tasks` table and its indexes already exist in
   `migrations/005_instances.sql`.

4. **`token_id` lookup:** In `applyTransition` step f, locate the token in
   `new_state.tokens` whose `node_id` equals the task node's `node_id`. If no such
   token exists, return `ApplyError.PersistenceFailed` — this indicates a bug in the
   transition function that placed a node in `pending_task_nodes` without placing the
   corresponding token.

5. **Set-difference implementation:** The `pending_task_nodes` slices are `[][]const u8`.
   For each entry in `new_state.pending_task_nodes`, check whether a string-equal entry
   exists in `old_state.pending_task_nodes`. The expected count is small (≤ parallel
   branches × HUMAN_TASK density), so O(n²) linear scan is acceptable.

6. **Connection release:** Always release the acquired connection in a `defer` block
   after acquiring it in step c, regardless of whether COMMIT or ROLLBACK is issued.
   Do not hold the connection across the step a pure function call.

7. **Security reminder:** `assignee_type` and `assignee_ref` originate from the
   definition graph snapshot (not directly from HTTP input), but they are still
   treated as untrusted text for SQL purposes — bound as `$5` and `$6` in the INSERT,
   never interpolated.

---

## Section EE-04: Complete Task

**Covers:** EE-04 (Complete a HUMAN_TASK by submitting output variables)
**Files:** `src/tasks/store.zig`, `src/engine/instance.zig`, `src/api/routes/tasks.zig`
**Depends on:**
- `src/engine/transition.zig` — `TransitionEvent.task_completed`, `InstanceState`, `transition()`
- `src/engine/instance.zig` — `InstanceStore` (EE-01, EE-03)
- `src/tasks/store.zig` — `TaskStore`, `Task`, `TaskError` (EE-03)
- `src/definition/snapshot.zig` — `SnapshotStore`, `DefinitionGraph`
- `migrations/005_instances.sql` — existing `tasks`, `instance_projections` tables
- `src/db/pool.zig` — `db.Pool`, connection type

---

### Module purpose

EE-04 implements the complete-task lifecycle step. An authorised caller submits a
`POST /tasks/:id/complete` request carrying an `output_variables` JSON object. The
platform verifies the task exists and is PENDING, merges the output variables into the
instance variable map, advances the execution token off the task node using the pure
transition function, persists the task status change, the new instance state, and the
`TASK_COMPLETED` event — all within a single atomic DB transaction. If the advancing
token reaches one or more HUMAN_TASK nodes, the corresponding `tasks` rows are
created inside the same transaction.

The `output_variables` payload may be an empty object `{}`; this is valid and
equivalent to supplying no outputs. The task must be in `PENDING` status; attempting
to complete an already-`COMPLETED` or `CANCELLED` task returns HTTP 409.

---

### 1. Database schema

No new migration is required. The relevant columns in `tasks`
(`migrations/005_instances.sql`) already include:

```
output_variables  JSONB                  -- set on completion (EE-04)
completed_by      UUID                   -- set on completion (EE-04); reserved for IDN-03
completed_at      TIMESTAMPTZ
updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

The `completeInTx` UPDATE (§5b below) writes to `status`, `output_variables`,
`updated_at`, and `completed_at`. The `completed_by` column is left NULL until
IDN-03 (identity) is released.

---

### 2. Updated `TaskError` error set

**File:** `src/tasks/store.zig`

Add `AlreadyTerminated` to the existing `TaskError` set:

```zig
pub const TaskError = error{
    /// task_id not found in tasks table. HTTP 404.
    NotFound,
    /// Task status ≠ PENDING (already COMPLETED or CANCELLED). HTTP 409.
    AlreadyTerminated,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Malformed parameter (e.g. invalid UUID format, invalid status string). HTTP 422.
    InvalidInput,
};
```

`AlreadyTerminated` is distinct from `NotFound` so the HTTP layer can map them to 409
vs 404 respectively without inspecting any string message.

---

### 3. New `TaskStore` methods

**File:** `src/tasks/store.zig`

#### 3a. `getById`

```zig
pub fn getById(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    task_id: Uuid,
) TaskError!Task
```

**Purpose:** Fetch a single `Task` by primary key. Acquires its own connection from
`self.pool`; the caller does not supply a connection.

**Algorithm:**

Acquire a connection from `self.pool` (return `TaskError.PoolExhausted` on failure).
Release the connection on return (success or error).

Execute the following parameterised SELECT:

```sql
SELECT
    id,
    instance_id,
    token_id,
    node_id,
    node_name,
    status,
    assignee_type,
    assignee_ref,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
FROM tasks
WHERE id = $1::uuid
```

Parameter: `$1` = `task_id` formatted as a hex UUID string (no SQL string
interpolation).

- 0 rows returned → return `TaskError.NotFound`.
- 1 row returned → parse into a `Task` struct (all slice fields duplicated into
  `allocator`); return the struct.

**Security invariant:** `task_id` is bound exclusively as `$1::uuid`. No UUID value
is concatenated into the SQL string literal.

#### 3b. `completeInTx`

```zig
pub fn completeInTx(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    task_id: Uuid,
    output_variables_json: []const u8,
) TaskError!Task
```

**Purpose:** Update a task row to `COMPLETED` status using an already-open DB
connection. The caller owns the transaction; `completeInTx` does NOT issue BEGIN,
COMMIT, or ROLLBACK.

**Algorithm:**

Execute the following parameterised UPDATE on `conn`:

```sql
UPDATE tasks
SET
    status           = 'COMPLETED',
    output_variables = $2::jsonb,
    completed_at     = NOW(),
    updated_at       = NOW()
WHERE id = $1::uuid
  AND status = 'PENDING'
RETURNING
    id,
    instance_id,
    token_id,
    node_id,
    node_name,
    status,
    assignee_type,
    assignee_ref,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
```

Parameters (all bound as `$N` — no SQL string interpolation):
- `$1` = `task_id` as hex UUID string
- `$2` = `output_variables_json` (raw JSON string bound as JSONB)

Result interpretation:
- 0 RETURNING rows: the WHERE predicate matched no row. This means either the task
  does not exist or its status ≠ `'PENDING'`. Because `getById` has already confirmed
  existence before `completeInTx` is called (see `InstanceStore.completeTask` §4
  steps a–b), 0 rows here indicates the task was concurrently completed or cancelled
  between the two calls. Return `TaskError.AlreadyTerminated` (HTTP 409).
- 1 RETURNING row → parse into a `Task` struct (slice fields duplicated into
  `allocator`); return the struct.

**Security invariant:** Both parameter values (`task_id`, `output_variables_json`) are
bound as `$N` positional parameters. The SQL string contains only fixed schema
identifiers and `$N` placeholders; no user-supplied value is concatenated.

---

### 4. `InstanceStore.completeTask` method

**File:** `src/engine/instance.zig`

```zig
pub fn completeTask(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    task_store: *task_mod.TaskStore,
    task_id: task_mod.Uuid,
    output_variables_json: []const u8,
) CompleteTaskError!transition_mod.InstanceState
```

#### `CompleteTaskError` error set

```zig
pub const CompleteTaskError = error{
    /// task_id not found in tasks table. HTTP 404.
    TaskNotFound,
    /// Task status ≠ PENDING (already COMPLETED or CANCELLED). HTTP 409.
    TaskAlreadyTerminated,
    /// output_variables is null or not a JSON object. HTTP 422.
    InvalidInput,
    /// Pure transition function returned a TransitionError. HTTP 500.
    TransitionFailed,
    /// A DB INSERT, UPDATE, or event write failed after BEGIN. HTTP 500.
    PersistenceFailed,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Allocator returned OutOfMemory.
    OutOfMemory,
};
```

#### Algorithm

All steps within a single DB transaction (steps h–m are inside BEGIN…COMMIT):

**Step a — Fetch the task (outside the transaction)**

```
task = task_store.getById(allocator, task_id)
    catch |err| switch (err) {
        TaskError.NotFound      => return CompleteTaskError.TaskNotFound,
        TaskError.PoolExhausted => return CompleteTaskError.PoolExhausted,
        TaskError.InvalidInput  => return CompleteTaskError.InvalidInput,
        TaskError.AlreadyTerminated => unreachable,  // getById never returns this
    };
```

**Step b — Verify task is PENDING (outside the transaction)**

```
if (task.status != .PENDING) return CompleteTaskError.TaskAlreadyTerminated;
```

**Step c — Load the instance's current state from `instance_projections`**

Acquire a separate pool connection. Execute:
```sql
SELECT
    instance_id,
    status,
    current_nodes,
    variables,
    last_event_seq
FROM instance_projections
WHERE instance_id = $1::uuid
```
Parameter: `$1` = `task.instance_id` as hex UUID string.
Deserialise the row into an `InstanceState` in-memory value (`tokens` from
`current_nodes` JSONB, `variables` from `variables` JSONB, etc.).
Release this read connection after the SELECT.

**Step d — Load the definition snapshot**

Call `self.snapshot_store.getByInstanceId(allocator, task.instance_id)` to retrieve
the `DefinitionGraph` for this instance.

**Step e — Validate and parse `output_variables_json`**

Parse `output_variables_json` using `std.json.parseFromSlice`. The root value MUST be
a `std.json.Value.object`. If parsing fails or the root is not an object (e.g. null,
array, scalar), return `CompleteTaskError.InvalidInput` immediately — before any
further DB call. An empty object `{}` is valid.

**Step f — Build the `TransitionEvent`**

```zig
const event = transition_mod.TransitionEvent{
    .task_completed = .{
        .task_node_id    = task.node_id,
        .output_variables = parsed_output_variables,  // std.json.ObjectMap from step e
    },
};
```

**Step g — Call `transition()` (outside the transaction, zero I/O)**

```
const new_state = transition_mod.transition(allocator, snapshot, current_state, event)
    catch return CompleteTaskError.TransitionFailed;
```

This step has zero I/O and is intentionally placed before BEGIN so that a transition
logic failure never opens a DB transaction.

**Step h — BEGIN TRANSACTION**

Acquire a connection from `self.pool` (return `CompleteTaskError.PoolExhausted` on
failure). Issue `BEGIN` on the connection. Set up `errdefer conn.rollback()` to ensure
ROLLBACK on any subsequent error return.

**Step i — Call `task_store.completeInTx`**

```
_ = task_store.completeInTx(allocator, conn, task_id, output_variables_json)
    catch return CompleteTaskError.PersistenceFailed;
    // ROLLBACK issued via errdefer
```

This sets the task row's `status` to `'COMPLETED'` and writes `output_variables`.

**Step j — INSERT event row into `events`**

Insert a `TASK_COMPLETED` event into the `events` / `instance_sequence` tables using
the same open `conn`. Follows the same CTE-based sequence-bump pattern used in
`applyTransition` (§6 EE-03 step d). Parameters bound as `$N` — no SQL string
interpolation. On failure, ROLLBACK (via errdefer) and return
`CompleteTaskError.PersistenceFailed`.

**Step k — UPDATE `instance_projections`**

```sql
UPDATE instance_projections
SET
    status         = $2,
    current_nodes  = $3::jsonb,
    variables      = $4::jsonb,
    last_event_seq = $5,
    updated_at     = NOW()
WHERE instance_id  = $1::uuid
```

Parameters: `$1`=`task.instance_id`, `$2`=`new_state.status` (TEXT),
`$3`=serialised `new_state.tokens`, `$4`=serialised `new_state.variables`,
`$5`=incremented sequence number. On failure, ROLLBACK and return
`CompleteTaskError.PersistenceFailed`.

**Step l — Create Task records for newly activated HUMAN_TASK nodes**

Compute `new_task_node_ids` = set difference of `new_state.pending_task_nodes` minus
`current_state.pending_task_nodes`. For each newly activated node:

```
task_store.createInTx(allocator, conn, task.instance_id, token.token_id,
    node_id, node_name, node.assignee_type, node.assignee_ref)
    catch return CompleteTaskError.PersistenceFailed;
    // ROLLBACK issued via errdefer
```

Locate the correct token by matching `new_state.tokens[i].node_id == node_id`. If no
token is found, return `CompleteTaskError.PersistenceFailed` (indicates a transition
function bug, analogous to EE-03 implementation note 4).

**Step m — COMMIT**

Issue `COMMIT` on the connection. On failure, return `CompleteTaskError.PersistenceFailed`.
Release the connection. Return `new_state`.

#### Atomicity invariant

Steps h–m (BEGIN → `completeInTx` → event INSERT → projection UPDATE → new task
INSERTs → COMMIT) execute as a single DB transaction. Steps a–g are outside the
transaction. If any step in h–m fails, ROLLBACK is issued via `errdefer` and
`CompleteTaskError.PersistenceFailed` is returned. The caller observes either the
complete committed state or no change at all (NFR-07 crash safety).

#### Security invariants

- All SQL parameter values are bound exclusively via `$N` positional parameters.
  No user-supplied value (`output_variables_json`, `task_id`) is concatenated into
  any SQL string literal at any point in the call chain.
- `output_variables_json` is validated as a JSON object in-process (step e) before
  any DB connection is acquired for the transaction.

---

### 5. `POST /tasks/:id/complete` HTTP handler

**File:** `src/api/routes/tasks.zig`

#### Route registration

```
POST /api/v1/tasks/:id/complete   →  handleComplete
```

Auth middleware enforces a valid session before the handler is invoked. The handler
may assume `ctx.actor` is populated.

#### Handler signature

```zig
pub fn handleComplete(
    store: *task_mod.TaskStore,
    instance_store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    task_id_str: []const u8,  // raw ":id" path segment
    body: []const u8,         // raw request body bytes
) HandlerResult
```

`HandlerResult` follows the same pattern as `handleList`:
```zig
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,  // JSON-encoded; owned by caller allocator
};
```

#### Algorithm

**Parse `task_id_str` as UUID:**
```
task_id = parseUuid(task_id_str)
    catch return errorResult(allocator, 422, "INVALID_INPUT", "task_id is not a valid UUID");
```

**Parse request body:**
Parse `body` as a JSON object. Locate the `output_variables` key. Validate that
`output_variables` is present, is a JSON object (not null, not array, not scalar), and
re-serialise it to a compact JSON string for `output_variables_json`. Return HTTP 422
if `output_variables` is null or not a JSON object.

```
// TODO IDN-03: verify caller has rights to complete task.assignee_ref before
// calling completeTask. The 403 Forbidden path is blocked on IDN-03 release.
```

**Call `instance_store.completeTask`:**
```
const new_state = instance_store.completeTask(
    allocator, store, task_id, output_variables_json,
) catch |err| switch (err) {
    CompleteTaskError.TaskNotFound         => return errorResult(allocator, 404, "TASK_NOT_FOUND", ...),
    CompleteTaskError.TaskAlreadyTerminated => return errorResult(allocator, 409, "TASK_ALREADY_TERMINATED", ...),
    CompleteTaskError.InvalidInput         => return errorResult(allocator, 422, "INVALID_INPUT", ...),
    CompleteTaskError.TransitionFailed     => return errorResult(allocator, 500, "TRANSITION_FAILED", ...),
    CompleteTaskError.PersistenceFailed    => return errorResult(allocator, 500, "PERSISTENCE_FAILED", ...),
    CompleteTaskError.PoolExhausted        => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", ...),
    CompleteTaskError.OutOfMemory          => return errorResult(allocator, 500, "INTERNAL_ERROR", ...),
};
_ = new_state;  // caller discards the returned state; HTTP response does not echo it
```

**Success response — HTTP 200:**
```json
{ "status": "ok", "task_id": "<UUID>" }
```

#### Error response table

| Error | HTTP status | JSON body `error` field |
|---|---|---|
| Malformed `:id` UUID | 422 | `INVALID_INPUT` |
| `output_variables` null or not an object | 422 | `INVALID_INPUT` |
| `TaskNotFound` | 404 | `TASK_NOT_FOUND` |
| `TaskAlreadyTerminated` | 409 | `TASK_ALREADY_TERMINATED` |
| `TransitionFailed` | 500 | `TRANSITION_FAILED` |
| `PersistenceFailed` | 500 | `PERSISTENCE_FAILED` |
| `PoolExhausted` | 503 | `SERVICE_UNAVAILABLE` |

**Authorization stub note:** The 403 Forbidden path (TASK_WORKER completing a task
assigned to a different user) is intentionally not implemented in this handler.
See TODO comment above. It is blocked on IDN-03.

---

### 6. Data flow diagram

```
HTTP POST /api/v1/tasks/:id/complete
│
│  body: { "output_variables": { ... } }
│
└──▶ handleComplete(store, instance_store, allocator, task_id_str, body)
          │
          ├── [1] Parse task_id_str → Uuid (422 if malformed)
          ├── [2] Parse body → extract output_variables JSON object (422 if invalid)
          │
          └──▶ instance_store.completeTask(allocator, task_store, task_id, output_vars_json)
                    │
                    ├── [a] task_store.getById(task_id)
                    │        └── TaskError.NotFound → CompleteTaskError.TaskNotFound → 404
                    │
                    ├── [b] Verify task.status == PENDING
                    │        └── status ≠ PENDING → CompleteTaskError.TaskAlreadyTerminated → 409
                    │
                    ├── [c] SELECT instance_projections → InstanceState (read-only conn)
                    │
                    ├── [d] snapshot_store.getByInstanceId → DefinitionGraph
                    │
                    ├── [e] Parse output_variables_json → ObjectMap (422 if invalid)
                    │
                    ├── [f] Build TransitionEvent.task_completed
                    │
                    ├── [g] transition(allocator, snapshot, state, event) → new_state
                    │        └── Zero I/O; deterministic; outside any transaction
                    │        └── TransitionError → CompleteTaskError.TransitionFailed → 500
                    │
                    ├── [h] pool.acquire() → conn; conn.begin()
                    │
                    ├── [i] task_store.completeInTx(conn, task_id, output_vars_json)
                    │        └── UPDATE tasks SET status='COMPLETED' WHERE id=$1 AND status='PENDING'
                    │
                    ├── [j] INSERT event row (TASK_COMPLETED) into events table
                    │
                    ├── [k] UPDATE instance_projections (status, current_nodes, variables, last_event_seq)
                    │
                    ├── [l] For each newly activated HUMAN_TASK node:
                    │        └── task_store.createInTx(conn, ...) — new PENDING task rows
                    │
                    ├── [m] conn.commit()
                    │        └── Any failure in [i]–[m] → errdefer conn.rollback()
                    │
                    └──▶ returns new_state
                              │
                              ▼
                    handleComplete returns HTTP 200 { "status": "ok", "task_id": "<UUID>" }
```

---

### 7. Error taxonomy

| Error identifier | Source | HTTP status | Description |
|---|---|---|---|
| `TaskError.NotFound` | `TaskStore.getById` | 404 | No task row matches `task_id` |
| `TaskError.AlreadyTerminated` | `TaskStore.completeInTx` (0 RETURNING rows) | 409 | Task completed/cancelled between pre-check and UPDATE |
| `CompleteTaskError.TaskNotFound` | `InstanceStore.completeTask` step a | 404 | Maps from `TaskError.NotFound` |
| `CompleteTaskError.TaskAlreadyTerminated` | `InstanceStore.completeTask` step b or i | 409 | Task not in PENDING status |
| `CompleteTaskError.InvalidInput` | step e; `handleComplete` body parse | 422 | `output_variables` null or not a JSON object |
| `CompleteTaskError.TransitionFailed` | step g | 500 | Pure transition returned error |
| `CompleteTaskError.PersistenceFailed` | steps i–m | 500 | Any DB write failed after BEGIN |
| `CompleteTaskError.PoolExhausted` | step h; step a | 503 | Pool exhausted |
| `CompleteTaskError.OutOfMemory` | any allocation step | 500 | Allocator exhausted |

---

### 8. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/tasks/store.zig` | `TaskStore`, `Task`, `TaskError`, `Uuid` | Task fetch, completion, new task creation |
| `src/engine/transition.zig` | `transition()`, `TransitionEvent`, `InstanceState` | Pure state advance |
| `src/definition/snapshot.zig` | `SnapshotStore`, `DefinitionGraph` | Load graph for transition function |
| `src/engine/instance.zig` | `InstanceStore`, `CompleteTaskError` | Persistence orchestration |
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Transaction management |
| `std.json` | `parseFromSlice`, `ObjectMap` | Parse and validate `output_variables` |

**Must NOT depend on:** `std.fs`, `std.net`, `std.Thread.sleep`, or anything that
introduces I/O within `transition()` itself.

---

### 9. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE04-1 | **Authorization (403 path):** The handler stub includes a TODO for IDN-03. Until identity is available, any caller can complete any task. Should the handler reject if `ctx.actor` is absent (e.g. anonymous)? | Medium — security gap for unauthenticated callers | Defer to IDN-03; auth middleware already enforces session existence (see EE-01 §6 note). No design change needed here. |
| OQ-EE04-2 | **`completed_by` column:** `tasks.completed_by UUID` exists in `migrations/005_instances.sql`. `completeInTx` does not populate it (IDN-03 not released). Should the UPDATE include `completed_by = NULL` explicitly, or leave it absent? | Low — column defaults to NULL; omitting is equivalent | Omit from the UPDATE; include `completed_by` in a follow-up design update when IDN-03 is delivered. |
| OQ-EE04-3 | **Concurrency / lost-update:** Between `getById` (step a) and `completeInTx` (step i), another request could complete the same task. The `WHERE status='PENDING'` predicate in the UPDATE handles this by returning 0 rows, which `completeInTx` maps to `AlreadyTerminated`. No additional locking is required. Confirm this is acceptable. | Low — handled correctly by the WHERE predicate | No design change needed; document as design choice. |

---

### 10. Traceability table

| EE-04 Acceptance Criterion | Design element |
|---|---|
| `POST /tasks/:id/complete` with `output_variables` accepted | `handleComplete` handler (§5); parses body for `output_variables` key; re-serialises to `output_variables_json` |
| Task status PENDING check → HTTP 409 if not | `InstanceStore.completeTask` step b checks `task.status == .PENDING`; `completeInTx` WHERE clause enforces atomically; both map to `CompleteTaskError.TaskAlreadyTerminated` → HTTP 409 |
| Task not found → HTTP 404 | `TaskStore.getById` returns `TaskError.NotFound`; `completeTask` step a maps to `CompleteTaskError.TaskNotFound`; handler maps to HTTP 404 with `TASK_NOT_FOUND` |
| `output_variables` null or not a JSON object → HTTP 422 | `completeTask` step e parses and validates; `handleComplete` validates before call; both return `CompleteTaskError.InvalidInput` → HTTP 422 with `INVALID_INPUT` |
| Variable merge, state transition, TASK_COMPLETED event, task status change — one transaction | `completeTask` steps h–m: `completeInTx` (i), event INSERT (j), projection UPDATE (k), optional new task INSERTs (l), all within a single `BEGIN`…`COMMIT`; `errdefer rollback` on any failure (§4 atomicity invariant) |

---

### Implementation notes for BACKEND-DEV (EE-04)

1. **Modified source files:**
   - `src/tasks/store.zig` — add `TaskError.AlreadyTerminated`, `getById`, `completeInTx`
   - `src/engine/instance.zig` — add `CompleteTaskError`, `completeTask`
   - `src/api/routes/tasks.zig` — add `handleComplete`

2. **No new migration required.** All columns used by EE-04 (`output_variables`,
   `completed_at`, `updated_at`) already exist in `migrations/005_instances.sql`.

3. **Import additions for `instance.zig`:** No new imports needed; `task_mod`,
   `transition_mod`, and `snapshot_mod` are already imported for EE-03.

4. **Import additions for `tasks.zig` route:** Add:
   ```zig
   const instance_mod = @import("../../engine/instance.zig");
   ```

5. **`parseUuid` helper:** Reuse or mirror the helper already used in `handleList`
   (imported from `task_mod` or defined locally in `tasks.zig`).

6. **`output_variables_json` serialisation:** In `handleComplete`, after validating
   that `output_variables` is a JSON object, use `std.json.Stringify.valueAlloc` or
   equivalent to produce a compact JSON string for the `output_variables_json`
   parameter to `completeTask`. This avoids passing the raw body slice (which may
   contain keys beyond `output_variables`).

7. **Security reminder:** Both `task_id` (from URL path) and `output_variables_json`
   (from request body) are user-supplied. Both must be bound as `$N` parameters in all
   SQL calls; neither may be concatenated into any SQL string literal.

---

## Section EE-05: Exclusive Gateway — CEL Integration

**Covers:** EE-05 (CEL condition evaluation for EXCLUSIVE_GATEWAY routing)
**Files:** `vendor/cel/cel.zig`, `src/engine/transition.zig`
**Depends on:**
- `src/definition/graph.zig` — `GraphEdge` (`.condition`, `.is_default`)
- `src/engine/transition.zig` — `processNodeEntry`, `InstanceState`, `TransitionError`
- `std.json` — `ObjectMap` (variable map type)
- `std.mem` — `Allocator`

---

### Module purpose

EE-05 replaces the stub condition evaluator in `transition.zig`'s `EXCLUSIVE_GATEWAY`
handler with a real, embedded CEL (Common Expression Language) evaluator implemented
in `vendor/cel/cel.zig`. When the execution token reaches an EXCLUSIVE_GATEWAY node,
the platform evaluates each non-default outgoing edge's condition expression against
the current instance variable map in declared order, and follows the first edge whose
condition evaluates to `true`. CEL runtime errors are treated as `false` per EE-05 AC;
they never abort the transition. If no non-default edge matches, the default edge
(if present) is taken. If no edge matches and no default exists, the function returns
`TransitionError.NoMatchingEdge`, which the caller maps to ERROR status per EE-10.

---

### 1. `cel.evaluate` function API

**File:** `vendor/cel/cel.zig`

#### Error type

```zig
pub const CelError = error{
    /// The expression string cannot be parsed (syntax error).
    ParseError,
    /// Evaluation produced a non-boolean result or a runtime type error
    /// (e.g. type mismatch in comparison, accessing an undefined variable).
    EvalError,
    /// The allocator failed during expression evaluation.
    OutOfMemory,
};
```

#### Function signature

```zig
/// Evaluate a CEL expression string against a variable map.
///
/// Parameters:
///   allocator  — used for any intermediate allocations during parsing/evaluation.
///   expression — a CEL expression string (e.g. "variables.amount > 1000").
///   variables  — the instance variable map; bound as the identifier `variables`
///                in the CEL environment. Only top-level keys are accessible as
///                `variables.<key>`. Nested access (e.g. `variables.a.b`) is NOT
///                required for this milestone.
///
/// Returns:
///   true   — expression evaluated to boolean true.
///   false  — expression evaluated to boolean false.
///   CelError.ParseError  — expression cannot be parsed (syntax error).
///   CelError.EvalError   — evaluation produced a non-boolean result or a runtime
///                          type error (e.g. undefined variable, type mismatch).
///   CelError.OutOfMemory — allocator failed during evaluation.
///
/// IMPORTANT: Per EE-05 AC, all callers of this function MUST use the
/// `catch false` pattern — any CelError is treated as boolean false for that
/// condition without aborting the transition.
pub fn evaluate(
    allocator: std.mem.Allocator,
    expression: []const u8,
    variables: std.json.ObjectMap,
) CelError!bool
```

#### CEL subset for this milestone

BACKEND-DEV SHALL implement a minimal evaluator supporting the following construct
definitions only. Any expression outside this subset returns `CelError.ParseError`
or `CelError.EvalError`.

**Supported value types (bound from `std.json.ObjectMap` values):**

| JSON value type | CEL type | Notes |
|---|---|---|
| `bool` | boolean | Direct mapping |
| `f64` (number) | numeric | Treated as numeric for comparison operators |
| `string` | string | Double-quoted string comparison |
| All other types | — | Accessing such a key returns `CelError.EvalError` |

**Supported literals:**
- Boolean literals: `true`, `false`
- Integer literals: decimal integer strings (e.g. `42`, `-7`)
- String literals: double-quoted strings (e.g. `"pending"`)

**Supported variable access:**
- Form: `variables.<key>` where `<key>` is a top-level key in the `ObjectMap`.
- If `<key>` is not present in `variables` → return `CelError.EvalError`.
- If the corresponding `std.json.Value` is not bool, f64, or string → return `CelError.EvalError`.

**Supported operators:**

| Operator | Applies to | Notes |
|---|---|---|
| `==` | any compatible pair | Type mismatch → `CelError.EvalError` |
| `!=` | any compatible pair | Type mismatch → `CelError.EvalError` |
| `<` | numeric only | String operand → `CelError.EvalError` |
| `>` | numeric only | String operand → `CelError.EvalError` |
| `<=` | numeric only | String operand → `CelError.EvalError` |
| `>=` | numeric only | String operand → `CelError.EvalError` |
| `&&` | boolean | Both operands must evaluate to boolean |
| `\|\|` | boolean | Both operands must evaluate to boolean |
| `!` (unary) | boolean | Operand must evaluate to boolean |
| `( )` | grouping | Any sub-expression |

**String comparison for `==` and `!=`:** Supported. String comparison for `<`, `>`,
`<=`, `>=` is NOT supported; attempting it returns `CelError.EvalError`.

#### CEL grammar (EBNF)

```
expr     := or_expr
or_expr  := and_expr ('||' and_expr)*
and_expr := not_expr ('&&' not_expr)*
not_expr := '!' not_expr | cmp_expr
cmp_expr := primary (('==' | '!=' | '<' | '>' | '<=' | '>=') primary)?
primary  := 'true' | 'false' | INTEGER | STRING | 'variables' '.' IDENT | '(' expr ')'

INTEGER  := '-'? [0-9]+
STRING   := '"' [^"]* '"'
IDENT    := [a-zA-Z_][a-zA-Z0-9_]*
```

**Implementation approach:** BACKEND-DEV SHALL implement a hand-written recursive
descent (Pratt) parser following the grammar above. The parser operates on a lexed
token stream; a single-pass tokeniser splits the expression string into typed tokens
(`BOOLEAN`, `INTEGER`, `STRING`, `IDENT`, `OP`, `LPAREN`, `RPAREN`, `DOT`) before
parsing begins. No external parser library is required; the subset is deliberately
small enough for a ≤ 300-line Zig implementation.

**Allocator use:** Intermediate string slices produced during tokenisation may be
allocated via `allocator`. BACKEND-DEV SHOULD use an `ArenaAllocator` backed by the
caller's allocator to ensure no partial leaks on error paths.

**Numeric precision:** JSON numbers are represented as `f64` in `std.json.ObjectMap`.
Integer literals in expressions are parsed and compared as `f64`. This means integers
larger than 2^53 may lose precision; this is acceptable for this milestone (see OQ-EE05-3).

---

### 2. Updated `EXCLUSIVE_GATEWAY` handler in `transition.zig`

**File:** `src/engine/transition.zig`

The current `EXCLUSIVE_GATEWAY` arm of `processNodeEntry` contains a stub that only
handles the literal string `"true"` as a true condition. This stub SHALL be replaced
with a real `cel.evaluate` call per the following specification.

#### Required import

Add the following import to `transition.zig` (at the top-level import block):

```zig
const cel = @import("../../vendor/cel/cel.zig");
```

The relative path `../../vendor/cel/cel.zig` is correct relative to
`src/engine/transition.zig`; adjust only if the file is relocated.

#### Updated `EXCLUSIVE_GATEWAY` handler algorithm

The existing edge-partitioning logic (building `non_default` and `defaults` lists
by iterating `snapshot.edges`) is retained unchanged. Only the condition evaluation
loop changes.

```
[Design pseudocode — not implementation code]

chosen_edge = null

FOR EACH edge IN non_default.items (snapshot index order — preserves declared order):
    IF edge.condition IS null:
        // Non-default edge with no condition string:
        // treat as always-false (defensive guard; PD-02 SHOULD prevent this case)
        CONTINUE

    result = cel.evaluate(allocator, edge.condition.?, new_state.variables) catch false
    // All CelError variants (ParseError, EvalError, OutOfMemory) are caught here
    // and mapped to boolean false per EE-05 AC. Iteration continues to next edge.

    IF result == true:
        chosen_edge = edge
        BREAK

// Default edge fallback (unchanged from existing design §6.4)
IF chosen_edge == null AND defaults.items.len > 0:
    chosen_edge = defaults.items[0]

// No match — caller maps to ERROR status per EE-10
IF chosen_edge == null:
    RETURN TransitionError.NoMatchingEdge

// Advance the token to the chosen edge's target
// (token_idx lookup and processNodeEntry call unchanged from existing stub)
token_idx = find_token_index_on_node(state.tokens, node_id)
new_state.tokens[token_idx.?].node_id = chosen_edge.?.target
RETURN processNodeEntry(allocator, snapshot, new_state, chosen_edge.?.target)
```

#### Key design constraints

**`catch false` pattern (mandatory):**

The `cel.evaluate` call MUST be written as a single expression that catches all
`CelError` variants and returns `false`:

```zig
// Canonical Zig form (design — not implementation):
const result = cel.evaluate(allocator, edge.condition.?, new_state.variables) catch false;
```

This form catches `CelError.ParseError`, `CelError.EvalError`, and
`CelError.OutOfMemory` with a single `catch false`. It is the idiomatic Zig pattern
for "treat all errors as a default value." Using a `catch |err| switch(err) { ... }`
form is permitted but must produce the same `false` result for every branch.

**Declared order guarantee:**

`non_default.items` is built by iterating `snapshot.edges` in array index order
(the order in which edges appear in the `DefinitionGraph.edges` slice, which reflects
the definition's declared order). BACKEND-DEV MUST NOT sort or reorder `non_default.items`
before the evaluation loop. The first edge in declared order whose condition evaluates
to `true` wins.

**`OutOfMemory` during evaluation:**

When `cel.evaluate` returns `CelError.OutOfMemory`, the `catch false` pattern
suppresses it and treats the condition as false. This is intentional: a single OOM
during condition evaluation does not abort the transition; the loop continues to the
next edge. If all evaluations fail (including via OOM), the default edge is tried
before returning `NoMatchingEdge`. This behaviour is consistent with the EE-05 AC
that states "CEL runtime error treated as false."

**Zero I/O invariant:**

`vendor/cel/cel.zig` MUST be a pure module — no `std.fs`, `std.net`, `std.io`,
or any blocking/async call. If the CEL implementation introduces I/O, that is a
defect in the CEL module, not in `transition.zig`, but it violates the zero-I/O
contract of the transition function and must be resolved before integration.

---

### 3. New unit tests for EE-05

**File:** `src/engine/transition.zig` (appended to the existing test block, after TC-EE-02-11)

The following test cases SHALL be added. All use `std.testing.allocator` and
inline `DefinitionGraph` literals (no database, no I/O) consistent with the existing
TC-EE-02-xx suite. These tests require the real `cel.evaluate` implementation to be
present in `vendor/cel/cel.zig`; they will not compile until that implementation
replaces the stub.

---

#### TC-EE-05-01: Numeric comparison condition routes to correct edge

**Graph:** `gw` (EXCLUSIVE_GATEWAY) → `t1`, `t2`
- Edge e1 (non-default): `condition = "variables.amount > 1000"`; `target = "t1"`
- Edge e2 (non-default): `condition = "variables.amount <= 1000"`; `target = "t2"`

**Input state:**
- Token on `gw`
- `variables = { "amount": 1500.0 }` (JSON number — `std.json.Value.float = 1500.0`)

**Expected result:**
- `processNodeEntry` returns without error
- `result.tokens.len == 1`
- `result.tokens[0].node_id` equals `"t1"` (amount=1500 satisfies `> 1000`; e1 is first)

---

#### TC-EE-05-02: String equality condition routes to correct edge

**Graph:** `gw` (EXCLUSIVE_GATEWAY) → `t1`, `t2`
- Edge e1 (non-default): `condition = "variables.status == \"approved\""`; `target = "t1"`
- Edge e2 (non-default): `condition = "variables.status == \"rejected\""`; `target = "t2"`

**Input state:**
- Token on `gw`
- `variables = { "status": "approved" }` (JSON string)

**Expected result:**
- `result.tokens[0].node_id` equals `"t1"`

---

#### TC-EE-05-03: CEL runtime error (undefined variable) → treated as false; default edge followed

**Graph:** `gw` (EXCLUSIVE_GATEWAY) → `t1`, `t2`
- Edge e1 (non-default): `condition = "variables.missing_key == 42"`; `target = "t1"`
- Edge e2 (default, `is_default = true`): no condition; `target = "t2"`

**Input state:**
- Token on `gw`
- `variables = {}` (empty map — `missing_key` is absent)

**Expected result:**
- `cel.evaluate` returns `CelError.EvalError` for e1; `catch false` maps it to false
- Default edge e2 is selected
- `processNodeEntry` returns without error
- `result.tokens[0].node_id` equals `"t2"`

**Verification note:** This test confirms that a CEL error on a non-default edge does
not propagate as a `TransitionError` and does not prevent the default edge from being
evaluated.

---

#### TC-EE-05-04: All conditions false, no default → `NoMatchingEdge`

**Graph:** `gw` (EXCLUSIVE_GATEWAY) → `t1`, `t2`
- Edge e1 (non-default): `condition = "false"`; `target = "t1"`
- Edge e2 (non-default): `condition = "false"`; `target = "t2"`
- No default edge

**Input state:**
- Token on `gw`
- `variables = {}` (empty map)

**Expected result:**
- `processNodeEntry` returns `TransitionError.NoMatchingEdge`
- `std.testing.expectError(TransitionError.NoMatchingEdge, result)`

---

#### TC-EE-05-05: Declared-order evaluation; first true condition wins

**Graph:** `gw` (EXCLUSIVE_GATEWAY) → `t1`, `t2`, `t3`
- Edge e1 (non-default, declared first): `condition = "variables.x > 0"`; `target = "t1"`
- Edge e2 (non-default, declared second): `condition = "variables.x > 0"`; `target = "t2"` (same condition, also true)
- Edge e3 (non-default, declared third): `condition = "true"`; `target = "t3"` (always true)

**Input state:**
- Token on `gw`
- `variables = { "x": 5.0 }` (JSON number; `x > 0` is satisfied)

**Expected result:**
- `result.tokens[0].node_id` equals `"t1"` — the first edge in declared order that evaluates to true
- `t2` and `t3` are NOT followed (break-on-first-true semantics)

---

#### Note on existing tests TC-EE-02-04 through TC-EE-02-06

These tests use `"true"` and `"false"` as condition strings. The CEL grammar includes
`'true'` and `'false'` as boolean literal tokens. The real `cel.evaluate`
implementation will evaluate `"true"` → `true` and `"false"` → `false` correctly.
Therefore TC-EE-02-04, TC-EE-02-05, and TC-EE-02-06 require **no changes** to their
test data — they will pass without modification once the CEL stub is replaced with
the real implementation.

---

### 4. Traceability table

| EE-05 Acceptance Criterion | Design element |
|---|---|
| Token at EXCLUSIVE_GATEWAY: first true CEL condition followed | `cel.evaluate` called per non-default edge in `non_default.items` (snapshot/declared index order); first `true` result sets `chosen_edge` and breaks the loop (§2 handler algorithm; TC-EE-05-01, TC-EE-05-02, TC-EE-05-05) |
| Default edge (`is_default=true`) followed when no non-default condition matches | Default-edge fallback: `IF chosen_edge == null AND defaults.items.len > 0: chosen_edge = defaults.items[0]` (§2 handler algorithm; TC-EE-05-03) |
| No match, no default → ERROR per EE-10 | `RETURN TransitionError.NoMatchingEdge` when `chosen_edge` is still null after default-edge check; the persistence layer maps this error to instance ERROR status per EE-10 (§2 handler algorithm; TC-EE-05-04) |
| CEL runtime error treated as `false` | `catch false` applied to `cel.evaluate` catches all `CelError` variants (`ParseError`, `EvalError`, `OutOfMemory`) and maps them to boolean false; iteration continues to next edge (§1 `CelError` definition; §2 `catch false` pattern; TC-EE-05-03) |
| Exactly one edge followed | Break-on-first-true in the non-default evaluation loop + single `chosen_edge` variable; a single `processNodeEntry` call on `chosen_edge.?.target` is the only advance (§2 handler algorithm; TC-EE-05-05) |

---

### 5. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `vendor/cel/cel.zig` | `evaluate`, `CelError` | CEL condition evaluation at EXCLUSIVE_GATEWAY |
| `src/definition/graph.zig` | `GraphEdge` (`.condition`, `.is_default`) | Edge condition string and default-edge flag |
| `std.json` | `ObjectMap` | Variable map passed to `cel.evaluate` |
| `std.mem` | `Allocator` | Passed through to `cel.evaluate` for intermediate allocations |

**Must NOT introduce any new I/O dependency.** `vendor/cel/cel.zig` itself must be
pure (no `std.fs`, `std.net`, `std.io`). If the CEL implementation introduces I/O,
that is a defect to be resolved before integration.

---

### 6. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE05-1 | **Non-default edge with null condition:** The updated handler treats a non-default edge that has no condition string as always-false (CONTINUE). PD-02 SHOULD reject null-condition non-default edges at definition creation time, making this guard defensive only. Confirm whether `graph.zig`'s validator currently enforces this. | Low — guard is defensive; PD-02 constraint prevents this in practice | Verify PD-02 `graph.zig` validator; no design change needed if constraint exists. |
| OQ-EE05-2 | **String ordering operators (`<`, `>`, `<=`, `>=`):** The grammar explicitly excludes string comparison for these operators. If process definitions require string ordering (e.g. comparing date strings lexicographically), a future milestone would need to add coercion or a `compare()` built-in. | Low — out of scope for this milestone | Document as known limitation; no action required now. |
| OQ-EE05-3 | **Floating-point precision for large integers:** JSON numbers are `f64`; integers > 2^53 may lose precision in numeric comparisons. Typical BPM variable values (amounts, counts, IDs) are well within `f64` precision range. | Low — process variable integers rarely exceed 2^53 in BPM use cases | Accept `f64` semantics for this milestone; document for future fix if precision issues arise. |

---

## Section EE-06: Parallel Gateway — Split

**Covers:** EE-06 (PARALLEL_GATEWAY split — creates N concurrent execution tokens)
**Files:** `src/engine/transition.zig`
**Depends on:**
- `src/definition/graph.zig` — `DefinitionGraph`, `GraphEdge`, `NodeType`
- `src/engine/transition.zig` — `processNodeEntry`, `InstanceState`, `Token`, `TransitionError`
- `migrations/001_event_store.sql` — `event_store` table for PARALLEL_SPLIT event persistence
- `std.mem` — `Allocator`

---

### Module purpose

EE-06 extends the `PARALLEL_GATEWAY` split path in `transition.zig`'s `processNodeEntry`
to: (1) remove the arriving token, (2) create N independent tokens — one per outgoing
edge — and (3) record a `PARALLEL_SPLIT` event in `InstanceState.pending_events` for
persistence by the DB-layer caller. Each new token's `branch_id` is deterministically
derived from the instance ID, the gateway node ID, and an edge index, making it globally
unique and stable for replay. The split records the token branch IDs in the event payload
so the EE-07 join can reconcile arrivals. The entire operation is pure (zero I/O); the
caller holds the DB transaction (DB-03).

---

### 1. Updated `InstanceState` struct — additions for EE-06

EE-06 requires a mechanism for `transition.zig` to return pending events (i.e. the
`PARALLEL_SPLIT` event) to the caller for persistence. This is achieved by adding a
`pending_events` field to `InstanceState`.

#### `PendingEvent` tagged union

```
[Design — not implementation code]

ParallelSplitPayload = struct {
    source_node_id:     []const u8,            // PARALLEL_GATEWAY node ID
    token_ids:          [][]const u8,          // branch_ids of the N new tokens (see §3)
    target_node_ids:    [][]const u8,          // target node IDs, one per new token
    edge_count:         usize,                 // N — number of outgoing edges
    variables_snapshot: std.json.ObjectMap,    // variable map at split time (for audit)
}

PendingEvent = union(enum) {
    parallel_split: ParallelSplitPayload,
    // Reserve space for future event types (PARALLEL_JOIN, TASK_ACTIVATED, etc.)
}
```

#### Updated `InstanceState` struct

Add one field to the existing struct definition:

```
[Design — not implementation code]

InstanceState = struct {
    instance_id:        Uuid,
    status:             InstanceStatus,
    tokens:             []Token,
    variables:          std.json.ObjectMap,
    pending_task_nodes: [][]const u8,
    error_detail:       ?[]const u8,
    pending_events:     []PendingEvent,    // NEW — appended by split/join handlers
}
```

**Migration impact for existing code:** All existing places in `transition.zig` and
`instance.zig` that construct `InstanceState` literals MUST be updated to initialise
`pending_events` to an empty slice (`&[_]PendingEvent{}`). BACKEND-DEV SHALL audit
all struct literal constructions before committing.

**Caller drain contract:** The DB-layer caller MUST drain `pending_events` and persist
each event to the `event_store` table within the same DB transaction as the token
updates (DB-03 compliance). After draining, the field is not reset by the caller —
it is simply discarded alongside the ephemeral `InstanceState` value.

---

### 2. Parallel split algorithm in `processNodeEntry`

**File:** `src/engine/transition.zig`, `PARALLEL_GATEWAY` arm, split path
(triggered when `outgoing_count > 1 and incoming_count <= 1`)

```
[Design pseudocode — not implementation code]

STEP a: Collect all outgoing edges of the PARALLEL_GATEWAY
    outgoing_edges = [edge for edge in snapshot.edges where edge.source == node_id]

STEP b: Remove the arriving token from state.tokens
    new_tokens = [t for t in state.tokens where t.node_id != node_id]

STEP c: For each outgoing edge, create a new Token with a unique branch_id
    //   branch_id format: "<instance_id_32_hex_chars>/<gateway_node_id>/<edge_index>"
    //   This deterministic scheme is globally unique and stable for replay.
    //   It encodes the gateway_node_id so EE-07 can group tokens by their split.
    new_split_tokens = []
    for i, edge in enumerate(outgoing_edges):
        branch_id = format("{instance_id_hex}/{node_id}/{i}")
        tok = Token{ .node_id = edge.target, .branch_id = branch_id }
        new_split_tokens.append(tok)

STEP d: Append all N new tokens to new_tokens
    new_tokens = new_tokens + new_split_tokens

STEP e: Append PARALLEL_SPLIT event to pending_events
    split_event = PendingEvent {
        .parallel_split = ParallelSplitPayload {
            .source_node_id     = node_id,
            .token_ids          = [tok.branch_id for tok in new_split_tokens],
            .target_node_ids    = [edge.target for edge in outgoing_edges],
            .edge_count         = outgoing_edges.len,
            .variables_snapshot = state.variables,   // snapshot at split time
        }
    }
    new_pending_events = state.pending_events + [split_event]

STEP f: Recursively activate each new token's target node
    new_state = InstanceState{
        ...state,
        tokens         = new_tokens,
        pending_events = new_pending_events,
    }
    for tok in new_split_tokens:
        // Recursive call activates HUMAN_TASK (TASK_ACTIVATED), END (completes branch),
        // or further gateways as needed. Each recursive call may append more
        // pending_events (e.g. from nested splits). The accumulated pending_events
        // in new_state carry all intermediate events back to the top-level caller.
        new_state = processNodeEntry(allocator, snapshot, new_state, tok.node_id)

STEP g: Return updated state
    return new_state
    // Caller holds the DB transaction (DB-03 compliance is caller's responsibility).
    // transition.zig performs zero I/O.
```

**DB-03 compliance note:** `transition.zig` is a pure function. All N tokens and the
`PARALLEL_SPLIT` event are created in memory only. Atomicity is the caller's
responsibility: the caller opens one DB transaction, invokes `transition()`, persists
`new_state.tokens` and drains `new_state.pending_events` into the event store, then
commits — all within a single transaction.

---

### 3. Token uniqueness guarantee

Each new token's `branch_id` is its globally unique identifier. The format is:

```
branch_id = "<instance_id_32_hex_chars>/<gateway_node_id>/<edge_index>"
```

**Uniqueness proof:**
- `instance_id` is a UUIDv4 (globally unique across all instances — see EE-01).
- `gateway_node_id` is unique within a definition graph (enforced by PD-02 structural
  validation, which rejects duplicate node IDs).
- `edge_index` (0, 1, 2, …N-1) distinguishes tokens from the same gateway in the
  same instance.

Therefore `branch_id` is globally unique across all tokens in all instances. A gateway
can only fire once per token arrival; re-entrant gateways are not in scope for this
milestone (see OQ-EE06-2).

**Determinism advantage:** Unlike random UUIDv4 generation, this scheme produces the
same `branch_id` values for the same inputs (`instance_id`, `gateway_node_id`,
`edge_index`). This is valuable for event-sourcing replay: replaying the same
`PARALLEL_SPLIT` event against the same initial state yields identical token
identifiers, enabling idempotent reprocessing without token identity drift.

**EE-07 join correlation:** The join handler identifies which tokens belong to a
given split by extracting the second segment (gateway_node_id) from each token's
`branch_id`. Tokens whose `branch_id` second segment equals the join gateway's
node ID are the expected arrivals. Counting distinct such tokens gives the join's
required arrival count.

**Existing `Token` struct — no additions required:** The current `Token` fields
(`node_id: []const u8`, `branch_id: []const u8`) are sufficient for EE-06. No
`parent_split_node_id` field is needed; the gateway node ID is already encoded in
`branch_id` as the second `/`-delimited segment. BACKEND-DEV SHALL NOT add new
fields to `Token` for this requirement.

---

### 4. `PARALLEL_SPLIT` event schema in the event store

When the caller persists the `PendingEvent.parallel_split` payload, it MUST insert
one row into the `event_store` table (`migrations/001_event_store.sql`) with the
following payload JSON:

```json
{
  "type":            "PARALLEL_SPLIT",
  "source_node_id":  "<gateway-node-id>",
  "token_ids":       ["<branch_id_1>", "<branch_id_2>", ...],
  "target_node_ids": ["<target_node_id_1>", "<target_node_id_2>", ...],
  "edge_count":      N,
  "variables":       { ... }
}
```

Field definitions:

| Field | Type | Description |
|---|---|---|
| `type` | string literal `"PARALLEL_SPLIT"` | Discriminator for event consumers |
| `source_node_id` | string | The PARALLEL_GATEWAY node ID that fired the split |
| `token_ids` | string array | The `branch_id` of each new token, in outgoing-edge order |
| `target_node_ids` | string array | The `node_id` of each new token's target, in edge order |
| `edge_count` | integer | N — count of outgoing edges; equals `len(token_ids)` |
| `variables` | JSON object | Snapshot of `InstanceState.variables` at the moment of split (for audit and replay) |

**Insertion contract:**
- The insert MUST execute within the same DB transaction as the token projection
  updates (DB-03).
- The `instance_id` and `sequence` columns are populated by the caller using the
  same conventions as other event types (see EE-01 event-store conventions).
- `token_ids` entries are `branch_id` strings (not RFC 4122 hyphenated UUIDs); they
  are opaque identifiers to event consumers and MUST be treated as such.

---

### 5. Traceability table

| EE-06 Acceptance Criterion | Design Element |
|---|---|
| N tokens created for N outgoing edges | Step c–d: for-loop over `outgoing_edges` creates one `Token` per edge and appends all to `new_tokens` |
| Each token progresses independently | Step d–f: separate `Token` entries in `new_tokens`; recursive `processNodeEntry` call per token; no shared mutable state across token activations |
| Split event recorded in event log | Step e: `PARALLEL_SPLIT` event appended to `new_pending_events`; caller persists to `event_store` within DB transaction (DB-03) |
| All N tokens created in single transaction | `transition.zig` is pure (zero I/O); caller opens one DB transaction, receives `new_state`, persists all tokens and events atomically before committing (DB-03 — caller's responsibility) |

---

### 6. Dependencies and constraints

| Module | Role | Constraint |
|---|---|---|
| `src/definition/graph.zig` | Provides `DefinitionGraph`, `GraphEdge`, `NodeType.PARALLEL_GATEWAY` | Read-only; not modified |
| `src/engine/transition.zig` | Contains `processNodeEntry`, `InstanceState`, `Token`, `PendingEvent` | Zero I/O; pure function invariant must be preserved |
| `migrations/001_event_store.sql` | `event_store` table for PARALLEL_SPLIT event rows | Written by caller, never by `transition.zig` |
| `std.mem.Allocator` | All heap allocations for new tokens, `branch_id` strings, and event payloads | Passed through from caller |

**Zero I/O invariant (absolute rule):** No file system, network, clock, or blocking
call is permitted inside `processNodeEntry` or anywhere in `transition.zig`. The split
handler MUST NOT access `std.fs`, `std.net`, `std.io`, or `std.time`. Any violation
is a critical defect (see `docs/anti-patterns.md`).

---

### 7. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE06-1 | **`pending_events` accumulation across recursive calls:** If a token activated in Step f itself triggers an event (e.g. an EE-07 join fires immediately on the same call stack), that event must also accumulate in `pending_events` via the `new_state` passed recursively. Confirm that the recursive accumulation pattern correctly preserves all intermediate events in the final returned `InstanceState`. | Medium — affects EE-07 integration correctness | Verify via unit test: a split immediately followed by a join on the same call stack MUST yield both `PARALLEL_SPLIT` and `PARALLEL_JOIN` events in the returned `pending_events`. |
| OQ-EE06-2 | **PARALLEL_GATEWAY with exactly 1 outgoing edge (degenerate case):** The split condition `outgoing_count > 1` skips gateways with a single outgoing edge (treated as neither split nor join). Confirm whether PD-02 structural validation rejects single-edge PARALLEL_GATEWAYs at definition creation time or whether the runtime should handle it as a pass-through. | Low — degenerate case unlikely in practice | Verify PD-02 validator; if not rejected, add explicit pass-through (advance token to the single outgoing edge, no PARALLEL_SPLIT event) in the handler. |
| OQ-EE06-3 | **`variables_snapshot` size in PARALLEL_SPLIT event:** Including the full variable map in the event payload may be large for instances with many variables. Evaluate whether the snapshot should be omitted (the event has enough information for EE-07 join correlation without it). | Low — performance and storage concern | Accept full snapshot for this milestone; evaluate storage impact during NFR benchmarks (see WF-04). |

---

## Section EE-07: Parallel Gateway — Join

**Covers:** EE-07 (PARALLEL_GATEWAY join — waits for all active incoming tokens before activating outgoing edge; handles branch cancellation from EE-08)
**File:** `src/engine/transition.zig`
**Depends on:**
- `src/definition/graph.zig` — `DefinitionGraph`, `GraphEdge`, `NodeType`
- `src/engine/transition.zig` — `processNodeEntry`, `InstanceState`, `Token`, `PendingEvent`, `TransitionError`
- `migrations/001_event_store.sql` — `event_store` table for `PARALLEL_JOIN` / `INSTANCE_CANCELLED` event persistence
- `std.mem` — `Allocator`

---

### Module purpose

EE-07 extends the `PARALLEL_GATEWAY` join path in `transition.zig`'s `processNodeEntry`
to handle branch cancellation (EE-08) and guarantee exactly-once join firing. When a
token arrives at a join gateway, the handler determines how many active (non-cancelled)
branches remain outstanding and fires only when all of them have arrived. If all branches
are cancelled before any token reaches the join, the handler cascades the cancellation to
the instance (`status = CANCELLED`). The join fires exactly once, enforced by DB-03
row-level locking on `instance_projections`. The transition function itself remains
pure (zero I/O); the caller holds the DB transaction.

---

### 1. InstanceState additions for join tracking

The join algorithm needs three categories of information at decision time.

#### a. Expected branch set (total branches from the split)

The expected branch count is **not** stored as a new `InstanceState` field. It is
derived at runtime from the definition graph: the join gateway's `incoming_count`
(number of incoming edges in `snapshot.edges` whose `target == gateway_node_id`) equals
the number of branches produced by the corresponding split, because PD-02 validates
that each incoming edge of a join gateway traces back to a distinct branch of its split.

The join handler identifies which split created the arriving tokens by extracting the
`split_gateway_node_id` from the arriving token's `branch_id`. The deterministic
format `"<instance_id_hex>/<split_gateway_node_id>/<edge_index>"` (established in
EE-06 §3) makes the split gateway identity the second `/`-delimited segment of every
branch_id. No additional state field is required.

#### b. Cancelled branch set — new `cancelled_branch_ids` field

Cancelled branches MUST be tracked explicitly. One new field is added to `InstanceState`:

```
[Design — not implementation code]

InstanceState = struct {
    instance_id:          Uuid,
    status:               InstanceStatus,
    tokens:               []Token,
    variables:            std.json.ObjectMap,
    pending_task_nodes:   [][]const u8,
    error_detail:         ?[]const u8,
    pending_events:       []PendingEvent,
    cancelled_branch_ids: [][]const u8,   // NEW — EE-07/EE-08
}
```

`cancelled_branch_ids` is a flat slice of branch_id strings (same
`"<instance_id>/<split_gateway_node_id>/<edge_index>"` format as `Token.branch_id`).
It is populated by:
- The EE-08 cancellation path — when the operator cancels an instance, EE-08 records
  each cancelled branch's `branch_id` here before calling the transition function for
  the join re-evaluation.
- The all-cancelled cascade in §2 step f — when the join handler determines
  `expected_count == 0`, it sets `status = CANCELLED` and clears tokens without
  needing to add more entries to `cancelled_branch_ids` (EE-08 has already added them).

At instance creation, `cancelled_branch_ids` is initialised to an empty slice
(`&[_][]const u8{}`). It only grows; entries are never removed.

**Migration impact for existing code:** All places in `transition.zig` and
`instance.zig` that construct `InstanceState` literals MUST be updated to include
`cancelled_branch_ids = &[_][]const u8{}`. BACKEND-DEV SHALL audit all struct literal
constructions before committing. The `instance_projections.current_nodes` JSONB
serialisation MUST also persist `cancelled_branch_ids` alongside `tokens` so that it
survives process restarts and event replay (NFR-07 crash safety).

#### c. Arrived branch set and "fired" flag

The arrived branch set is **implicit**: it is the set of tokens in `state.tokens`
whose `node_id` equals the join gateway's `node_id`. Each waiting branch parks its
token on the join node; no additional field is required.

An explicit `fired` boolean is **not required**. Exactly-once is enforced by DB-03
row-level locking (§3). Once the join fires, all tokens on the join node are consumed
and a merged token is placed downstream; no tokens remain on the join node. Any
subsequent arrival at the join (which cannot occur in a well-formed process under
correct EE-08 interaction) would find `arrived_count < expected_count` and park,
not double-fire.

---

### 2. Join algorithm in `processNodeEntry`

**File:** `src/engine/transition.zig`, `PARALLEL_GATEWAY` arm, join path  
(triggered when `incoming_count > 1`)

```
[Design pseudocode — not implementation code]

STEP a: Determine split vs join
    incoming_count = count(e in snapshot.edges where e.target == node_id)
    // A PARALLEL_GATEWAY is a join when incoming_count > 1.
    // The split path (outgoing_count > 1 && incoming_count <= 1) is handled separately.

STEP b: Record the arriving token in the arrived-set
    // The arriving token has already been placed on the join node (node_id set to
    // gateway_node_id) before processNodeEntry is called. Enumerate all tokens on
    // the join node — these represent all branches that have arrived so far.
    tokens_on_join    = [t for t in state.tokens where t.node_id == node_id]
    arrived_branch_ids = [t.branch_id for t in tokens_on_join]
    arrived_count     = len(arrived_branch_ids)

    // Identify the split gateway from the arriving token's branch_id.
    // branch_id format: "<instance_id_hex>/<split_gateway_node_id>/<edge_index>"
    // The second '/'-delimited segment is split_gateway_node_id.
    split_gateway_node_id = arriving_token.branch_id.split('/')[1]

STEP c: Compute expected_count
    total_branches = incoming_count   // from definition graph — total split branches

    // Filter cancelled_branch_ids to those belonging to this split
    cancelled_for_split = [b for b in state.cancelled_branch_ids
                            where b.split('/')[1] == split_gateway_node_id]
    cancelled_count = len(cancelled_for_split)

    expected_count = total_branches - cancelled_count

STEP d: Wait path — arrived_count < expected_count
    if arrived_count < expected_count:
        // Not all active branches have arrived yet.
        // The arriving token is already parked on the join node in state.tokens.
        // No event is emitted; no status or variable change occurs.
        return state   // token already placed; no further action

STEP e: Fire path — arrived_count == expected_count  (and expected_count > 0)
    // All active (non-cancelled) branches have arrived. Fire the join.

    // Remove all tokens on the join node from the token list.
    new_tokens = [t for t in state.tokens where t.node_id != node_id]

    // Select merged_branch_id deterministically:
    //   Use the branch_id whose edge_index segment (third '/'-delimited segment)
    //   is "0" — i.e., the first branch created by the split. If no branch 0
    //   is present (because it was cancelled — this should not occur in step e,
    //   only in step f), fall back to the lexicographically smallest branch_id.
    //   This selection is stable across replays (pure, no arrival-order dependency).
    merged_branch_id = branch_id_with_index_0(tokens_on_join)

    // Find the single outgoing edge of the join gateway.
    // PD-02 guarantees exactly one outgoing edge from a join gateway.
    outgoing_edges = [e for e in snapshot.edges where e.source == node_id]
    next_node_id   = outgoing_edges[0].target

    // Create merged token on the outgoing edge.
    merged_token = Token{
        .node_id   = next_node_id,
        .branch_id = merged_branch_id,
    }
    new_tokens = append(new_tokens, merged_token)

    // Build PARALLEL_JOIN event and accumulate with existing pending_events.
    join_event = PendingEvent{
        .parallel_join = ParallelJoinPayload{
            .join_node_id         = node_id,
            .branch_ids_arrived   = arrived_branch_ids,
            .branch_ids_cancelled = cancelled_for_split,
            .outgoing_token_id    = merged_token.branch_id,
        }
    }
    new_pending_events = state.pending_events + [join_event]

    // Construct new state with merged token.
    new_state = InstanceState{
        ...state,
        tokens         = new_tokens,
        pending_events = new_pending_events,
    }

    // Recursively advance the merged token into the next node.
    return processNodeEntry(allocator, snapshot, new_state, next_node_id)

STEP f: All-cancelled path — expected_count == 0
    // All branches of the split were cancelled before any token reached the join.
    // The join cannot fire. The instance transitions to CANCELLED status.
    // This path is triggered when EE-08 adds the final branch_id to
    // cancelled_branch_ids and calls the transition function, and no arrived tokens
    // are present on the join node (arrived_count == 0 == expected_count).

    // Remove any stray tokens on the join node (defensive guard).
    new_tokens = [t for t in state.tokens where t.node_id != node_id]

    // Build INSTANCE_CANCELLED event.
    cancel_event = PendingEvent{
        .instance_cancelled = InstanceCancelledPayload{
            .reason              = "ALL_BRANCHES_CANCELLED",
            .join_node_id        = node_id,
            .branch_ids_cancelled = cancelled_for_split,
        }
    }
    new_pending_events = state.pending_events + [cancel_event]

    new_state = InstanceState{
        ...state,
        status         = CANCELLED,
        tokens         = [],   // terminal state — all tokens cleared
        pending_events = new_pending_events,
    }
    return new_state
    // No PARALLEL_JOIN event is emitted on this path; the join did not fire.
    // The caller persists INSTANCE_CANCELLED and updates instance_projections.status.
```

**Integration with EE-08:** Step f is reached when EE-08 adds the last outstanding
branch_id to `cancelled_branch_ids` and the transition function is re-invoked. EE-08
is responsible for adding all branch_ids of the cancelled parallel split to
`cancelled_branch_ids` before calling the join re-evaluation. EE-08 handles the
full-instance cancellation path (operator-initiated); step f here handles the automatic
cascade triggered by all branches cancelling. Both paths end with
`status = CANCELLED` and an `INSTANCE_CANCELLED` event.

**Note on variable merging:** Variables brought by arriving tokens are merged by the
caller (EE-09 collision policy) before `processNodeEntry` is called, consistent with
the EE-03/EE-04 pattern. The `PARALLEL_JOIN` event records which branches arrived,
enabling audit and replay.

**Zero I/O invariant:** The join handler performs no I/O. Setting
`status = CANCELLED` and returning a new `InstanceState` is a pure value operation.
The caller persists the resulting state within its DB transaction.

---

### 3. Exactly-once guarantee

The join fires at most once regardless of concurrent token arrivals via the following
mechanism.

**DB-03 row-level locking:** The persistence orchestration layer acquires a
`SELECT FOR UPDATE` lock on the `instance_projections` row for `instance_id` at the
start of every `applyTransition` call. This exclusive lock is held until the
transaction commits. No two `applyTransition` calls for the same instance can execute
concurrently; they are fully serialised by the DB.

**Serialised arrival example (2 branches):**

```
T1: applyTransition for branch B1
    └── SELECT FOR UPDATE on instance row (acquires lock)
    └── Read state S0 — 0 tokens on join (arrived=0 < expected=2)
    └── Add B1's token to join node → state S1
    └── transition() returns S1 (wait path — step d)
    └── UPDATE instance_projections with S1
    └── COMMIT  →  lock released

T2: applyTransition for branch B2  (was blocked until T1 committed)
    └── SELECT FOR UPDATE on instance row (acquires lock after T1 releases)
    └── Read state S1 — 1 token on join (B1 already there)
    └── Add B2's token to join node → arrived=2 == expected=2
    └── transition() fires the join (step e) → produces S2 with merged token
    └── UPDATE instance_projections with S2
    └── COMMIT  →  lock released
```

T2 always reads the committed state from T1 (which includes B1's token), so the
join fires exactly once in T2.

**Post-fire safety:** After the join fires in T2, the state contains a merged token
downstream and zero tokens on the join node. Any subsequent `applyTransition` call
that somehow places a token on the same join node would enter the wait path (step d)
with `arrived_count = 1 < expected_count`. This cannot happen in a well-formed
instance because the N branches are consumed by the join fire; EE-06 and EE-08
together guarantee that each branch produces at most one token at the join.

**No explicit `fired` flag needed:** The DB-03 lock makes the state transition
atomic. Once the join fires, the absence of tokens on the join node — persisted
atomically in the same commit — is itself proof that the join has fired. No in-memory
or persisted `fired` sentinel is required.

---

### 4. `PARALLEL_JOIN` event schema

Add `ParallelJoinPayload` and `InstanceCancelledPayload` to the `PendingEvent` tagged
union in `transition.zig`:

```
[Design — not implementation code]

ParallelJoinPayload = struct {
    join_node_id:         []const u8,     // PARALLEL_GATEWAY node ID (join role)
    branch_ids_arrived:   [][]const u8,   // branch_ids of all tokens that arrived
    branch_ids_cancelled: [][]const u8,   // branch_ids excluded from count (empty if none)
    outgoing_token_id:    []const u8,     // branch_id of the merged outgoing token
}

InstanceCancelledPayload = struct {
    reason:               []const u8,     // "ALL_BRANCHES_CANCELLED" or "OPERATOR"
    join_node_id:         ?[]const u8,    // set when reason == "ALL_BRANCHES_CANCELLED"
    branch_ids_cancelled: [][]const u8,   // all cancelled branch_ids for this split
}

PendingEvent = union(enum) {
    parallel_split:     ParallelSplitPayload,      // EE-06
    parallel_join:      ParallelJoinPayload,        // EE-07 NEW
    instance_cancelled: InstanceCancelledPayload,   // EE-07 NEW (all-cancelled path)
}
```

When the caller persists `PendingEvent.parallel_join`, it MUST insert one row into
the `event_store` table with the following payload JSON:

```json
{
  "type":                 "PARALLEL_JOIN",
  "join_node_id":         "<gateway-node-id>",
  "branch_ids_arrived":   ["<b1>", "<b2>", ...],
  "branch_ids_cancelled": ["<bc1>", ...],
  "outgoing_token_id":    "<new-tok-id>"
}
```

**Field definitions:**

| Field | Type | Description |
|---|---|---|
| `type` | string literal `"PARALLEL_JOIN"` | Discriminator for event consumers |
| `join_node_id` | string | The PARALLEL_GATEWAY node ID that fired the join |
| `branch_ids_arrived` | string array | `branch_id` values of all tokens consumed by the join; at least 1 entry |
| `branch_ids_cancelled` | string array | `branch_id` values excluded from threshold (may be empty) |
| `outgoing_token_id` | string | `branch_id` of the merged token placed on the outgoing edge |

For the all-cancelled path (step f), no `PARALLEL_JOIN` event is emitted. Instead
the `INSTANCE_CANCELLED` event is persisted with payload:

```json
{
  "type":                 "INSTANCE_CANCELLED",
  "reason":               "ALL_BRANCHES_CANCELLED",
  "join_node_id":         "<gateway-node-id>",
  "branch_ids_cancelled": ["<bc1>", "<bc2>", ...]
}
```

**Insertion contract:**
- The insert MUST execute within the same DB transaction as the token and
  projection updates (DB-03).
- The `instance_id` and `sequence` columns are populated by the caller using the
  same conventions as other event types.
- `branch_id` strings are opaque identifiers; event consumers MUST treat them as
  such and not attempt to parse them as RFC 4122 UUIDs.

---

### 5. Traceability table

| EE-07 AC | Design element |
|---|---|
| N active tokens arrive at join → join fires, 1 outgoing token created | §2 steps b–e: tokens on join node accumulate as each branch arrives; when `arrived_count == expected_count > 0`, all join tokens are removed, a single merged token is created on the outgoing edge, and `processNodeEntry` recurses on `next_node_id` |
| "Active" excludes tokens on cancelled branches | §2 step c: `cancelled_for_split` is subtracted from `total_branches` to produce `expected_count`; cancelled branches never place a token on the join node (EE-08 removes their tokens before they reach the join) |
| One branch cancelled, remaining active branches arrive → join fires normally | §2 step c: `expected_count = total_branches - 1`; when `N-1` tokens park on the join and `arrived_count == expected_count`, step e fires the join, producing 1 merged token; `branch_ids_cancelled` in the event records the excluded branch |
| All branches cancelled → join cancelled, CANCELLED status | §2 step f: when `expected_count == 0`, no join fire occurs; `status` is set to `CANCELLED`, `tokens` is cleared to `[]`, `INSTANCE_CANCELLED` event is appended to `pending_events` for persistence by the caller |
| Join fires exactly once regardless of arrival order | §3: DB-03 `SELECT FOR UPDATE` on `instance_projections` serialises all `applyTransition` calls; T2 always reads T1's committed state (including B1's parked token) before deciding to fire; no race condition is possible |

---

### 6. Resolution of OQ-4

**OQ-4 (from §11 of this document):** "EE-07 and the architecture doc state that
cancelled branches do not count toward the join threshold. `InstanceState` does not
currently carry a 'cancelled branches set'. This is required for correct join behaviour
when a parallel branch is cancelled mid-flight."

**Resolution:** OQ-4 is fully resolved by the `cancelled_branch_ids: [][]const u8`
field added to `InstanceState` in §1b above.

- **Initialisation:** empty slice at instance creation; never nil.
- **Population:** EE-08 appends each cancelled branch's `branch_id` to this field
  when a branch is cancelled. Because `applyTransition` is serialised by DB-03 locking,
  the field is always up-to-date when the join handler reads it.
- **Join threshold correction:** §2 step c filters `cancelled_branch_ids` by
  `split_gateway_node_id` (second segment of each entry) and subtracts the count from
  `incoming_count` to produce `expected_count`. This is O(k) in the number of
  cancelled branches — typically very small.
- **Persistence:** `cancelled_branch_ids` is serialised alongside `tokens` in the
  `instance_projections.current_nodes` JSONB column and restored on each
  `applyTransition` call. It survives process restarts and event replay (NFR-07).
- **No per-join map required:** The flat slice design works correctly for instances
  with multiple concurrent parallel splits because the second segment of each
  `branch_id` uniquely identifies its split gateway. The join handler filters
  in-line by `split_gateway_node_id`.

OQ-4 is closed. No future design update is required for EE-07 or EE-08 to address
cancelled-branch tracking; it is fully specified here.

---

## Section EE-08: Instance Cancellation

**Covers:** EE-08 (Cancel a running process instance — all open tasks, pending timers,
in-flight SERVICE_TASK calls, and the `INSTANCE_CANCELLED` event, all in one atomic
DB transaction)
**Files:** `src/engine/instance.zig`, `src/api/routes/instances.zig`
**Depends on:**
- `src/engine/transition.zig` — `InstanceState`, `PendingEvent`, `InstanceCancelledPayload`,
  `cancelled_branch_ids`
- `src/tasks/store.zig` — `TaskStore`, `TaskStatus`
- `src/definition/snapshot.zig` — `SnapshotStore`
- `src/db/pool.zig` — `db.Pool`, `db.Conn`
- `migrations/001_event_store.sql` — `event_store` table (INSTANCE_CANCELLED event row)
- `migrations/005_instances.sql` — `tasks`, `instance_projections` tables
- `migrations/007_timers.sql` — `timers` table (SCH-03 timer cancellation)

**Must NOT depend on:** `src/engine/transition.zig` for any I/O — the transition
function is pure and must not be called with I/O side effects. The cancellation logic
lives entirely in `instance.zig` (the persistence orchestration layer).

---

### Module purpose

EE-08 implements operator-initiated instance cancellation. When an authorised caller
submits `POST /instances/:id/cancel`, the platform performs a single atomic DB
transaction that:

1. Acquires a row-level lock on `instance_projections` (first-writer-wins concurrency).
2. Verifies the instance is in `ACTIVE` (or `ERROR`) status — terminal instances return
   HTTP 409.
3. Sets all `PENDING` tasks for the instance to `CANCELLED`.
4. Sets all `PENDING` timers for the instance to `CANCELLED` (SCH-03 contract).
5. Appends an `INSTANCE_CANCELLED` event to the event store.
6. Sets `instance_projections.status = 'CANCELLED'`, clears `current_nodes`, and
   records `cancelled_at = NOW()`.
7. Commits. HTTP 200 is returned.

In-flight SERVICE_TASK HTTP calls are abandoned on a best-effort basis: the platform
marks the instance CANCELLED in the DB but does not block waiting for any outbound
HTTP call to complete or time out. The SERVICE_TASK executor (Stage 6) is expected to
check instance status before applying any response it receives after the cancellation
commit; it discards the response silently.

The cancellation transaction does not invoke `transition()`. The state change is
applied directly by the persistence layer, because cancellation is an operator action
that overrides process logic rather than a process-logic-driven state change.

---

### 1. Database schema

No new migration is required. All tables used by EE-08 already exist:

#### 1a. `instance_projections` — columns written by EE-08

```
instance_projections
────────────────────────────────────────────────────────────────────────
status          TEXT        set to 'CANCELLED'
current_nodes   JSONB       set to '{"tokens":[],"cancelled_branch_ids":[]}'
cancelled_at    TIMESTAMPTZ set to NOW()
updated_at      TIMESTAMPTZ set to NOW()
```

The `SELECT FOR UPDATE` lock is on the `instance_projections` row for `instance_id`.
This serialises concurrent cancellation and task-completion attempts (EE-12 AC).

#### 1b. `tasks` — bulk update by EE-08

```
tasks
────────────────────────────────────────────────────────────────────────
status          TEXT        set to 'CANCELLED' for all PENDING rows
cancelled_at    TIMESTAMPTZ set to NOW() for all PENDING rows
updated_at      TIMESTAMPTZ set to NOW() for all PENDING rows
```

The UPDATE uses `WHERE instance_id = $1 AND status = 'PENDING'`. Rows already in
`COMPLETED` or `CANCELLED` status are not affected.

#### 1c. `timers` — bulk update by EE-08 (SCH-03)

```
timers
────────────────────────────────────────────────────────────────────────
status          TEXT        set to 'CANCELLED' for all PENDING rows
updated_at      TIMESTAMPTZ set to NOW() for all PENDING rows
```

The UPDATE uses `WHERE instance_id = $1 AND status = 'PENDING'`. `FIRED` timers are
not affected.

#### 1d. `event_store` — INSTANCE_CANCELLED event row

One row is inserted per cancellation call with `event_type = 'INSTANCE_CANCELLED'`
and the payload defined in §5 below.

---

### 2. `CancelInstanceError` error set

**File:** `src/engine/instance.zig`

```zig
pub const CancelInstanceError = error{
    /// instance_id not found in instance_projections. HTTP 404.
    InstanceNotFound,
    /// Instance is already in a terminal status (CANCELLED or COMPLETED). HTTP 409.
    AlreadyTerminal,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Any DB INSERT, UPDATE, or COMMIT failed inside the transaction. HTTP 500.
    PersistenceFailed,
    /// Allocator returned OutOfMemory. HTTP 500.
    OutOfMemory,
};
```

`AlreadyTerminal` covers both `CANCELLED` and `COMPLETED` statuses. The HTTP handler
maps it to 409 with a `code` field that disambiguates the cause (see §6).

---

### 3. `InstanceStore.cancelInstance` method

**File:** `src/engine/instance.zig`

#### Function signature

```zig
pub fn cancelInstance(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    instance_id: Uuid,
) CancelInstanceError!void
```

The function returns `void` on success — no state is returned to the HTTP handler
beyond the absence of an error.

#### Algorithm

**Step a — Acquire a DB connection and BEGIN TRANSACTION**

Acquire a connection from `self.pool` (return `CancelInstanceError.PoolExhausted` on
failure). Issue `BEGIN` on the connection. Set up `errdefer conn.rollback() catch {}`
to guarantee ROLLBACK on any subsequent error return.

**Step b — Lock and read the instance row**

Execute within the open transaction:

```sql
SELECT status, current_nodes
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE
```

Parameter: `$1` = `instance_id` as hex UUID string (no SQL string interpolation).

The `FOR UPDATE` clause acquires an exclusive row-level lock. This lock is held until
COMMIT (step h), serialising concurrent cancellation and task-completion requests for
the same instance (EE-12 first-writer-wins).

Result interpretation:
- 0 rows → ROLLBACK, return `CancelInstanceError.InstanceNotFound`.
- 1 row with `status IN ('CANCELLED', 'COMPLETED')` → ROLLBACK, return
  `CancelInstanceError.AlreadyTerminal`.
- 1 row with `status = 'ACTIVE'` or `status = 'ERROR'` → proceed to step c.

**Design note — ERROR status:** The requirement text (EE-08 AC) covers `ACTIVE`
instances explicitly. Instances in `ERROR` status are also cancellable by an operator
(the dead letter API OBS-05 also provides retry/discard, but cancellation is a valid
operator action). This is flagged as OQ-EE08-1 in §10.

**Step c — Cancel all PENDING tasks**

Execute on the same open connection:

```sql
UPDATE tasks
SET
    status       = 'CANCELLED',
    cancelled_at = NOW(),
    updated_at   = NOW()
WHERE instance_id = $1::uuid
  AND status      = 'PENDING'
```

Parameter: `$1` = `instance_id` (no SQL string interpolation). On DB failure:
ROLLBACK (via errdefer), return `CancelInstanceError.PersistenceFailed`.

This UPDATE is a no-op if there are no PENDING tasks — which is valid per the EE-08
edge case "cancelling an instance with no open tasks or timers."

**Step d — Cancel all PENDING timers (SCH-03)**

Execute on the same open connection:

```sql
UPDATE timers
SET
    status     = 'CANCELLED',
    updated_at = NOW()
WHERE instance_id = $1::uuid
  AND status      = 'PENDING'
```

Parameter: `$1` = `instance_id` (no SQL string interpolation). On DB failure:
ROLLBACK (via errdefer), return `CancelInstanceError.PersistenceFailed`.

This UPDATE is a no-op if there are no PENDING timers for the instance.

**SCH-03 race note:** If SCH-02 has already acquired an advisory lock on a timer and
is mid-fire when EE-08 runs, the two transactions contend on the timer row. Only one
can win; the other is blocked until the winner commits. If SCH-02 commits first (timer
FIRED), the EE-08 UPDATE's `WHERE status = 'PENDING'` predicate skips that row — the
timer was already processed, which is acceptable. If EE-08 commits first (timer
CANCELLED), SCH-02's transaction sees status != 'PENDING' and performs no action.
Both outcomes are valid per SCH-03 AC.

**Step e — Read instance state for branch tracking**

Parse `current_nodes` JSONB from the row read in step b to extract `cancelled_branch_ids`
and `tokens`. This is needed to build a complete list of cancelled branch_ids for the
`INSTANCE_CANCELLED` event payload and to handle the `InstanceCancelledPayload` struct.

Specifically, extract the `branch_id` from every token in the `tokens` array that
belongs to a parallel split (i.e. tokens whose `branch_id` contains at least one `/`).
These, combined with any already-recorded `cancelled_branch_ids`, form the full
cancellation record.

**Step f — Insert INSTANCE_CANCELLED event**

Execute on the same open connection:

```sql
INSERT INTO event_store
    (instance_id, event_type, sequence, payload, actor_id, created_at)
VALUES
    ($1::uuid, 'INSTANCE_CANCELLED', (
        SELECT COALESCE(MAX(sequence), 0) + 1
        FROM event_store
        WHERE instance_id = $1::uuid
    ), $2::jsonb, $3, NOW())
```

Parameters (all bound as `$N` — no SQL string interpolation):
- `$1` = `instance_id` as hex UUID string
- `$2` = JSON event payload (see §5 for schema)
- `$3` = actor_id string (from the HTTP handler's `ctx.actor.user_id`; passed into
  `cancelInstance` as a `[]const u8` parameter — see revised signature in §3.1)

On DB failure: ROLLBACK (via errdefer), return `CancelInstanceError.PersistenceFailed`.

**Step g — Update instance_projections**

Execute on the same open connection:

```sql
UPDATE instance_projections
SET
    status        = 'CANCELLED',
    current_nodes = '{"tokens":[],"cancelled_branch_ids":[]}'::jsonb,
    cancelled_at  = NOW(),
    updated_at    = NOW()
WHERE instance_id = $1::uuid
```

Parameter: `$1` = `instance_id` (no SQL string interpolation). On DB failure:
ROLLBACK (via errdefer), return `CancelInstanceError.PersistenceFailed`.

**Step h — COMMIT**

Issue `COMMIT` on the connection. On failure: return `CancelInstanceError.PersistenceFailed`.
Release the connection. Return `void` (success).

#### 3.1 Revised function signature (with actor_id)

The event INSERT in step f requires `actor_id`. The canonical signature is:

```zig
pub fn cancelInstance(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    instance_id: Uuid,
    actor_id: []const u8,
) CancelInstanceError!void
```

`actor_id` is a non-empty string (the authenticated caller's user_id from
`ctx.actor`). The HTTP handler validates that it is non-empty before calling this
function.

#### Atomicity invariant

Steps a through h (BEGIN → SELECT FOR UPDATE → task UPDATE → timer UPDATE → event
INSERT → projection UPDATE → COMMIT) execute as a single DB transaction. If any step
in a–h fails after BEGIN, ROLLBACK is issued via `errdefer` and the appropriate
`CancelInstanceError` is returned. No partial state (tasks cancelled but instance
still ACTIVE, or event appended but tasks not cancelled) is ever observable.

This satisfies EE-08 AC: "task cancellations, timer cancellations, status change, and
INSTANCE_CANCELLED event MUST all commit in a single transaction."

#### Security invariants

- All SQL parameter values (`instance_id`, `actor_id`, event payload JSON) are bound
  exclusively via `$N` positional parameters.
- No user-supplied or runtime-derived value is concatenated into any SQL string literal
  at any point in the call chain.
- `actor_id` is not validated for format (UUID vs string); it is stored verbatim as
  TEXT. The auth middleware guarantees it is a non-empty, authenticated identity.

---

### 4. Data flow diagram

```
HTTP POST /api/v1/instances/:id/cancel
│
│  (no request body required)
│
└──▶ handleCancel(instance_store, allocator, instance_id_str, actor_id)
          │
          ├── [1] Parse instance_id_str → Uuid (422 if malformed)
          │
          └──▶ instance_store.cancelInstance(allocator, instance_id, actor_id)
                    │
                    ├── [a] pool.acquire() → conn; conn.begin()
                    │        └── PoolExhausted → CancelInstanceError.PoolExhausted → 503
                    │
                    ├── [b] SELECT status, current_nodes FROM instance_projections
                    │        WHERE instance_id = $1 FOR UPDATE
                    │        ├── 0 rows → InstanceNotFound → 404
                    │        └── status IN ('CANCELLED','COMPLETED') → AlreadyTerminal → 409
                    │
                    ├── [c] UPDATE tasks SET status='CANCELLED'
                    │        WHERE instance_id=$1 AND status='PENDING'
                    │        (no-op if no pending tasks — valid)
                    │
                    ├── [d] UPDATE timers SET status='CANCELLED'
                    │        WHERE instance_id=$1 AND status='PENDING'    [SCH-03]
                    │        (no-op if no pending timers — valid)
                    │
                    ├── [e] Parse current_nodes → extract token branch_ids
                    │        (for INSTANCE_CANCELLED event payload)
                    │
                    ├── [f] INSERT INTO event_store
                    │        (instance_id, 'INSTANCE_CANCELLED', seq+1, payload, actor_id)
                    │
                    ├── [g] UPDATE instance_projections
                    │        SET status='CANCELLED', current_nodes='...', cancelled_at=NOW()
                    │        WHERE instance_id=$1
                    │
                    ├── [h] conn.commit()
                    │        └── Any failure in [a]–[h] → errdefer conn.rollback()
                    │                                     → PersistenceFailed → 500
                    │
                    └──▶ returns void (success)
                              │
                              ▼
                    handleCancel returns HTTP 200 { "status": "ok", "instance_id": "<UUID>" }
```

**Best-effort SERVICE_TASK abandonment:** In-flight HTTP calls from SERVICE_TASK nodes
(Stage 6) are not tracked in the DB. The cancellation transaction commits without
waiting for them. The SERVICE_TASK executor checks `instance_projections.status` when
it receives an HTTP response; if the status is `CANCELLED`, the response is discarded
silently. No additional mechanism is needed within EE-08 scope.

---

### 5. `INSTANCE_CANCELLED` event payload schema

The event inserted in step f carries the following `payload` JSONB:

```json
{
  "type":                "INSTANCE_CANCELLED",
  "reason":              "OPERATOR",
  "cancelled_task_ids":  ["<task_uuid_1>", "<task_uuid_2>", ...],
  "cancelled_timer_ids": ["<timer_uuid_1>", ...],
  "active_token_branch_ids": ["<branch_id_1>", ...],
  "actor_id":            "<user_id_or_token_id>"
}
```

**Field definitions:**

| Field | Type | Description |
|---|---|---|
| `type` | string literal `"INSTANCE_CANCELLED"` | Discriminator for event consumers and replay |
| `reason` | string `"OPERATOR"` | Distinguishes operator cancellation from auto-cancellation (ALL_BRANCHES_CANCELLED from EE-07) |
| `cancelled_task_ids` | string array | UUIDs of all tasks set to CANCELLED in step c; may be empty |
| `cancelled_timer_ids` | string array | UUIDs of all timers set to CANCELLED in step d; may be empty |
| `active_token_branch_ids` | string array | `branch_id` values of all tokens that were active at cancellation time (extracted from `current_nodes` in step e); may be empty if no parallel branches were in flight |
| `actor_id` | string | The authenticated caller's identity |

**Populating `cancelled_task_ids` and `cancelled_timer_ids`:** The step c and step d
UPDATEs must use `RETURNING id` to collect the affected row IDs before the COMMIT.
The IDs are serialised into the payload JSON for step f.

**Revised step c SQL (with RETURNING):**

```sql
UPDATE tasks
SET
    status       = 'CANCELLED',
    cancelled_at = NOW(),
    updated_at   = NOW()
WHERE instance_id = $1::uuid
  AND status      = 'PENDING'
RETURNING id
```

**Revised step d SQL (with RETURNING):**

```sql
UPDATE timers
SET
    status     = 'CANCELLED',
    updated_at = NOW()
WHERE instance_id = $1::uuid
  AND status      = 'PENDING'
RETURNING id
```

The returned ID slices are collected into temporary `[]Uuid` slices (allocator-owned)
for serialisation into the event payload JSON.

---

### 6. `POST /instances/:id/cancel` HTTP handler

**File:** `src/api/routes/instances.zig`

#### Route registration

```
POST /api/v1/instances/:id/cancel   →  handleCancel
```

Auth middleware enforces a valid session before the handler is invoked. The handler
may assume `ctx.actor` is populated.

#### Handler signature

```zig
/// POST /api/v1/instances/:id/cancel
pub fn handleCancel(
    store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,  // raw ":id" path segment
    actor_id: []const u8,          // from ctx.actor.user_id
) HandlerResult
```

`HandlerResult` follows the same pattern as the existing `handleCreate`:
```zig
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,  // JSON-encoded; owned by caller allocator
};
```

#### Algorithm

**Parse `instance_id_str` as UUID:**
```
instance_id = parseUuid(instance_id_str)
    catch return errorResult(allocator, 422, "INVALID_INPUT",
        "instance_id is not a valid UUID");
```

**Validate `actor_id` is non-empty:**
```
if (actor_id.len == 0)
    return errorResult(allocator, 401, "UNAUTHORIZED", "missing actor identity");
```

**Call `instance_store.cancelInstance`:**
```
instance_store.cancelInstance(allocator, instance_id, actor_id) catch |err|
    switch (err) {
        CancelInstanceError.InstanceNotFound  => return errorResult(allocator, 404, ...),
        CancelInstanceError.AlreadyTerminal   => return errorResult(allocator, 409, ...),
        CancelInstanceError.PoolExhausted     => return errorResult(allocator, 503, ...),
        CancelInstanceError.PersistenceFailed => return errorResult(allocator, 500, ...),
        CancelInstanceError.OutOfMemory       => return errorResult(allocator, 500, ...),
    };
```

**Success response — HTTP 200:**
```json
{ "status": "ok", "instance_id": "<UUID>" }
```

#### Error response table

| Condition | HTTP | `code` field |
|---|---|---|
| `:id` not a valid UUID | 422 | `INVALID_INPUT` |
| Instance not found | 404 | `INSTANCE_NOT_FOUND` |
| Instance already CANCELLED or COMPLETED | 409 | `ALREADY_TERMINAL` |
| DB pool exhausted | 503 | `SERVICE_UNAVAILABLE` |
| DB write failed | 500 | `PERSISTENCE_FAILED` |
| OOM | 500 | `INTERNAL_ERROR` |

**Authorization note:** The PROCESS_OPERATOR or PLATFORM_ADMIN role is required per
IDN-03. Auth middleware enforces role presence before the handler is invoked. The
handler does not perform role checks itself; it trusts `ctx.actor` is authorised.

---

### 7. Concurrency handling

#### First-writer-wins for concurrent cancel + task-complete

The `SELECT FOR UPDATE` in step b locks the `instance_projections` row for the
duration of the transaction. Any concurrent `completeTask` call (EE-04) or second
`cancelInstance` call for the same instance is blocked until the first transaction
commits.

After the cancellation transaction commits:
- A blocked `completeTask` reads `status = 'CANCELLED'` and returns
  `CompleteTaskError.TaskAlreadyTerminated` → HTTP 409 (task is now CANCELLED).
- A blocked second `cancelInstance` reads `status = 'CANCELLED'` and returns
  `CancelInstanceError.AlreadyTerminal` → HTTP 409.

This satisfies EE-08 AC: "Concurrent cancellation while a task is being completed:
the first operation to acquire the row-level lock wins; the other receives HTTP 409."

#### Interaction with EE-07 parallel join

If the instance being cancelled has parallel branches, the cancellation transaction
sets all PENDING tasks to CANCELLED (step c) but does NOT invoke the transition
function or re-evaluate the join logic. The join re-evaluation is not needed because
the entire instance is being cancelled — no further process execution occurs. The
`current_nodes` column is overwritten to `{"tokens":[],"cancelled_branch_ids":[]}`
(step g), permanently clearing all token and branch state.

The EE-07 all-branches-cancelled cascade (where EE-08 adds branch_ids to
`cancelled_branch_ids` and re-evaluates the join) applies only to partial branch
cancellations in future scopes (e.g. boundary event handling). For the full-instance
cancellation case covered here, direct DB writes are used instead.

---

### 8. Error taxonomy

| Error identifier | Source | HTTP | Description |
|---|---|---|---|
| `CancelInstanceError.InstanceNotFound` | step b (0 rows) | 404 | No row in `instance_projections` for `instance_id` |
| `CancelInstanceError.AlreadyTerminal` | step b (status check) | 409 | Instance already CANCELLED or COMPLETED |
| `CancelInstanceError.PoolExhausted` | step a | 503 | Pool exhausted; cannot acquire connection |
| `CancelInstanceError.PersistenceFailed` | steps c, d, f, g, or h | 500 | Any DB write failed inside the transaction |
| `CancelInstanceError.OutOfMemory` | payload JSON serialisation | 500 | Allocator exhausted |

---

### 9. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Connection and transaction management |
| `src/tasks/store.zig` | (no function calls; SQL written directly in `cancelInstance`) | Task cancellation is performed via direct SQL in the same connection, not through `TaskStore` methods, to avoid acquiring a second connection |
| `migrations/005_instances.sql` | `tasks` table | Bulk task cancellation (step c) |
| `migrations/007_timers.sql` | `timers` table | Bulk timer cancellation (step d, SCH-03) |
| `migrations/001_event_store.sql` | `event_store` table | INSTANCE_CANCELLED event row (step f) |
| `std.json` | `stringify` | Serialise event payload for step f |
| `std.mem` | `Allocator` | Temporary slices for RETURNING IDs and payload JSON |

**Must NOT import:** `src/engine/transition.zig` for any mutable call —
`cancelInstance` is a direct-DB operation; it does not go through the pure transition
function.

---

### 10. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE08-1 | **Cancellation of ERROR-status instances:** EE-08 requirement text covers `ACTIVE` instances. Should `ERROR`-status instances also be cancellable via `POST /instances/:id/cancel`? OBS-05 (dead letter API) provides retry/discard. If cancel is not supported for ERROR, the handler must return HTTP 409 for ERROR status the same as for COMPLETED/CANCELLED. | Low-Medium — affects operator UX; ERROR instances may be stuck indefinitely without a cancel option | Recommended: allow cancellation of ERROR-status instances (include `ERROR` in the `status IN ('ACTIVE', 'ERROR')` check in step b). Flag for REQ-ANALYST confirmation. |
| OQ-EE08-2 | **`actor_id` source:** The design assumes `ctx.actor.user_id` is a non-empty string available from auth middleware. Before IDN-04 (token issuance) is released, only the bootstrap token is available. Should `actor_id` default to `"SYSTEM"` or the literal bootstrap token string when IDN-04 is not available? | Low — affects event payload only; does not affect correctness | Use the raw token string or `"BOOTSTRAP"` sentinel; update when IDN-04 delivers real user IDs. No design change needed; document as a known placeholder. |
| OQ-EE08-3 | **SERVICE_TASK abandonment mechanism:** EE-08 specifies best-effort abandonment. The current design relies on the SERVICE_TASK executor (Stage 6) checking instance status. This check is passive — if the executor crashes before checking, a completed HTTP response may be partially applied. Should there be a `service_task_in_flight` tracking table to make abandonment more reliable? | Low — best-effort is an explicit requirement AC; a tracking table is a Stage 6 concern | Defer to Stage 6 SERVICE_TASK design; note here as a known limitation for audit trail purposes. |

---

### 11. Traceability table

| EE-08 Acceptance Criterion | Design element |
|---|---|
| `POST /instances/:id/cancel` on ACTIVE instance → all open tasks set to CANCELLED | §3 step c: `UPDATE tasks SET status='CANCELLED' WHERE instance_id=$1 AND status='PENDING'`; within the same transaction as all other writes |
| `POST /instances/:id/cancel` on ACTIVE instance → all pending timers set to CANCELLED (SCH-03) | §3 step d: `UPDATE timers SET status='CANCELLED' WHERE instance_id=$1 AND status='PENDING'`; same transaction |
| In-flight SERVICE_TASK HTTP calls abandoned (best-effort) | §4 data flow note: cancellation transaction commits without waiting; Stage 6 SERVICE_TASK executor checks instance status on response receipt (OQ-EE08-3) |
| `INSTANCE_CANCELLED` event appended | §3 step f: INSERT into event_store with `event_type='INSTANCE_CANCELLED'` and structured payload (§5); same transaction |
| Instance status set to CANCELLED; HTTP 200 returned | §3 step g: `UPDATE instance_projections SET status='CANCELLED'`; §6 handler returns HTTP 200 `{"status":"ok","instance_id":"..."}` |
| Already CANCELLED or COMPLETED → HTTP 409 | §3 step b: `status IN ('CANCELLED','COMPLETED')` check after `FOR UPDATE`; maps to `CancelInstanceError.AlreadyTerminal`; §6 handler returns 409 with `ALREADY_TERMINAL` |
| Task cancellations, timer cancellations, status change, event — one transaction | §3 steps a–h: entire algorithm runs inside a single `BEGIN`…`COMMIT`; `errdefer conn.rollback()` on any failure |
| Cancelling instance with no open tasks or timers — still appends INSTANCE_CANCELLED event | §3 steps c and d: UPDATEs are no-ops for zero matching rows; step f INSERT always runs (no guard on row count) |
| Concurrent cancellation: first-writer-wins, other gets HTTP 409 | §7: `FOR UPDATE` lock in step b serialises concurrent requests; second caller sees `status='CANCELLED'` and returns `AlreadyTerminal` → 409 |

---

### Implementation notes for BACKEND-DEV (EE-08)

1. **Modified source files:**
   - `src/engine/instance.zig` — add `CancelInstanceError`, `cancelInstance`
   - `src/api/routes/instances.zig` — add `handleCancel` and route registration

2. **No new migration required.** The `tasks`, `timers`, `instance_projections`, and
   `event_store` tables already exist in their respective migration files.

3. **RETURNING clause handling:** Steps c and d use `RETURNING id`. The pg.zig API
   returns rows from UPDATEs with RETURNING the same way as SELECTs. Collect the
   returned UUIDs into a `std.ArrayList(Uuid)` and serialise them to the event payload.
   If `pg.zig` does not support RETURNING on UPDATE, use a pre-UPDATE SELECT with
   `FOR UPDATE SKIP LOCKED` to collect IDs, then perform the UPDATE. Do NOT use a
   subquery with `IN (SELECT ...)` as this may introduce SQL injection risk via
   plan shape; use the RETURNING approach.

4. **Event sequence number:** The sub-SELECT `COALESCE(MAX(sequence), 0) + 1` in step
   f's INSERT is a simple sequence bump. If the event store uses a separate
   `instance_sequence` table (as referenced in EE-03/EE-04 designs), use the same
   CTE-based sequence-bump pattern for consistency. Adjust to match the actual event
   store schema in `migrations/001_event_store.sql`.

5. **`errdefer` pattern:**
   ```zig
   const conn = self.pool.acquire() catch return CancelInstanceError.PoolExhausted;
   defer self.pool.release(conn);
   conn.begin() catch return CancelInstanceError.PersistenceFailed;
   errdefer conn.rollback() catch {};
   // ... steps c through g ...
   conn.commit() catch return CancelInstanceError.PersistenceFailed;
   ```
   The `errdefer` ensures ROLLBACK on any error return after BEGIN. The outer `defer`
   returns the connection to the pool regardless of commit/rollback outcome.

6. **parseUuid helper:** Reuse the existing `parseUuid` helper from
   `src/api/routes/instances.zig` (already used by `handleCreate`).

7. **`timers` table availability:** The `timers` table is defined in
   `migrations/007_timers.sql`. If this migration has not been applied in the test
   environment, the UPDATE in step d will fail. BACKEND-DEV must ensure all migrations
   are applied before running EE-08 integration tests. Use `zig build migrate` before
   running `zig build test-integration`.

8. **Security reminder:** `instance_id` (from URL path) and `actor_id` (from auth
   context) are both bound as `$N` parameters in all SQL calls. The event payload JSON
   is serialised in-process (not constructed via string concatenation) and bound as a
   JSONB parameter.

---

## Section EE-09: Variable Scoping and Merge

**Covers:** EE-09 (Variable scoping and merge — collision policy, schema validation, VARIABLE_OVERWRITTEN events)
**Files:** `src/engine/instance.zig`
**Depends on:**
- `src/engine/transition.zig` — `InstanceState`, `Token`, `transition()` (simple in-memory merge inside transition; full policy here)
- `src/event_store/store.zig` — `appendInTx` (VARIABLE_OVERWRITTEN, EXECUTION_ERROR events)
- `src/db/pool.zig` — `db.Conn` (transaction management)
- `migrations/012_event_retention.sql` — `variable_schemas` table
- `migrations/005_instances.sql` — `instance_projections.variables` JSONB column

**Must NOT appear in:** `src/engine/transition.zig`. The merge function accesses the
DB (schema lookup) and emits events; both actions violate the zero-I/O rule.

---

### Module purpose

EE-09 implements the variable collision policy applied every time a caller submits
`output_variables` via task completion (EE-04), a parallel join convergence (EE-07),
a SERVICE_TASK response (Stage 6), or an edge transformer expression (Stage 6). The
policy runs entirely inside `instance.zig` before the pure transition function
(`transition.zig`) is invoked, so the merged variable map is already in `InstanceState`
when CEL condition evaluation (EE-05) runs inside that same transition call.

The merge algorithm has three paths:

1. **New key** — key not present in the instance variable map → insert unconditionally;
   no event emitted.
2. **Overwrite** — key present, new value passes schema validation (or no schema
   registered for this key) → overwrite and record a `VARIABLE_OVERWRITTEN` event.
3. **Schema violation** — key present, registered schema rejects the new value → do
   NOT apply the merge, transition the instance to `ERROR` status, append an
   `EXECUTION_ERROR` event with `error_type = "SCHEMA_VIOLATION"`.

Paths 1 and 2 do not mutate `instance_projections.variables` directly; that column is
updated by the standard projection UPDATE at the end of the existing transaction.
`VARIABLE_OVERWRITTEN` and `EXECUTION_ERROR` events are appended inside that same
transaction, satisfying DB-03 atomicity.

---

### 1. Database schema

#### 1a. `variable_schemas` — already exists in `migrations/012_event_retention.sql`

```
variable_schemas
────────────────────────────────────────────────────────────────────────
id              UUID        PRIMARY KEY DEFAULT gen_random_uuid()
definition_id   UUID        NOT NULL REFERENCES process_definitions(id) ON DELETE CASCADE
variable_key    TEXT        NOT NULL
json_schema     JSONB       NOT NULL
description     TEXT
created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
UNIQUE (definition_id, variable_key)
```

Schemas are registered per definition, per variable key. If no row exists for
`(definition_id, variable_key)`, the variable carries no schema constraint and any
JSON value is accepted (Paths 1 and 2 proceed unconditionally).

#### 1b. `instance_projections.variables` — already exists in `migrations/001_event_store.sql`

```
instance_projections.variables   JSONB   NOT NULL DEFAULT '{}'
```

This is the live merged variable map. It is written by the standard
`UPDATE instance_projections SET variables = $1 ...` that already exists in the
`completeTask` transaction. No new column or migration is required.

#### 1c. `event_store` — no new schema

`VARIABLE_OVERWRITTEN` and `EXECUTION_ERROR` events are stored as JSON objects in
`event_store.payload`. The payload schemas are defined in §7 and §8 below.

---

### 2. New error set

**File:** `src/engine/instance.zig`

```zig
pub const MergeVariablesError = error{
    /// A registered schema rejects the new value for an existing variable key.
    /// Caller must NOT apply the merge; invoke the ERROR path instead.
    SchemaViolation,
    /// Failed to load variable_schemas rows from the DB.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};
```

---

### 3. New types

**File:** `src/engine/instance.zig`

#### 3a. `VariableOverwrittenPayload`

```zig
pub const VariableOverwrittenPayload = struct {
    /// Always "VARIABLE_OVERWRITTEN".
    event_type:  []const u8,
    instance_id: Uuid,
    /// The task_id that produced the output_variables.
    /// Null for parallel-join-triggered merges.
    task_id:     ?Uuid,
    key:         []const u8,
    /// JSON-encoded string of the value before overwrite.
    old_value:   []const u8,
    /// JSON-encoded string of the new value.
    new_value:   []const u8,
    // merged_at is NOT in this struct; set by SQL INSERT using NOW()
    // to match the DB server clock used for all other *_at columns.
};
```

#### 3b. `SchemaViolationDetail`

```zig
pub const SchemaViolationDetail = struct {
    /// The variable key whose new value failed schema validation.
    affected_field: []const u8,
    /// Human-readable description, e.g. "expected integer, got string".
    reason:         []const u8,
    /// JSON-encoded snapshot of instance variables BEFORE any merge was applied.
    variable_state: []const u8,
};
```

#### 3c. `MergeVariablesResult`

```zig
pub const MergeVariablesResult = struct {
    /// Final merged variable map (caller-owned; allocated from caller's `allocator`).
    merged: std.json.ObjectMap,
    /// Events to INSERT into event_store inside the same transaction.
    /// May be a zero-length slice when no key was overwritten (all new keys or no-op).
    overwritten_events: []VariableOverwrittenPayload,
};
```

---

### 4. `mergeVariables` function signature

**File:** `src/engine/instance.zig`

```zig
/// Validate and compute the merged variable map per EE-09 collision policy.
///
/// Does NOT write to the DB and does NOT call BEGIN/COMMIT.
/// The caller holds an open transaction; this function issues only one SELECT
/// (the variable_schemas fetch) against `conn` inside that transaction.
///
/// Returns the merged map and the list of VARIABLE_OVERWRITTEN event payloads
/// the caller must INSERT inside the same open transaction.
///
/// On schema violation: returns error.SchemaViolation; `violation_out.*` is
/// populated with detail for the EXECUTION_ERROR event payload.
///
/// Security: definition_id is bound as $1::uuid; variable_key as $2 TEXT.
/// No user-supplied key or value is concatenated into any SQL string.
pub fn mergeVariables(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    conn: db.Conn,                          // caller-owned; already inside a transaction
    definition_id: Uuid,
    instance_id: Uuid,
    task_id: ?Uuid,                         // null for parallel-join merge calls
    current_vars: std.json.ObjectMap,       // snapshot of instance vars before merge
    output_variables: std.json.ObjectMap,   // caller-parsed; duplicates already resolved
    violation_out: *?SchemaViolationDetail, // populated when error.SchemaViolation returned
) MergeVariablesError!MergeVariablesResult
```

---

### 5. `mergeVariables` algorithm

**Preconditions:**
- `conn` is open and inside a `BEGIN` transaction (caller owns BEGIN/COMMIT).
- `output_variables` is a valid JSON object; caller validated before this call.
- `violation_out.*` is `null` on entry; this function sets it only on
  `error.SchemaViolation`.

**Pseudocode:**

```
// EE-09 edge case: empty output_variables is a no-op.
if output_variables.count() == 0:
    return MergeVariablesResult{
        .merged            = deep_copy(current_vars, allocator),
        .overwritten_events = &.{},   // empty slice
    }

// Fetch all variable schemas for this definition in one query.
// SELECT variable_key, json_schema FROM variable_schemas WHERE definition_id = $1::uuid
// If query fails → return error.PersistenceFailed
schemas: map[string]json_schema = load_variable_schemas(conn, definition_id)

// Duplicate-key note: output_variables is already a parsed std.json.ObjectMap.
// Standard JSON parsing semantics (last-value-wins on duplicate keys) were applied
// by std.json.parseFromSlice at body-parse time. No extra deduplication here.

merged = deep_copy(current_vars, allocator)
overwritten_events: ArrayList(VariableOverwrittenPayload) = .init(allocator)

for each (key, new_value) in output_variables (in insertion order):
    schema = schemas.get(key)  // null if no schema registered for this key

    if schema != null:
        if not json_schema_validate(new_value, schema):
            violation_out.* = SchemaViolationDetail{
                .affected_field = key,
                .reason         = validation_error_message(new_value, schema),
                .variable_state = json_encode(current_vars, allocator),
            }
            return error.SchemaViolation
            // Entire merge is aborted — no partial application.

    if current_vars.contains(key):
        // Path 2: existing key + compatible value → overwrite + event
        old_val = current_vars.get(key)
        overwritten_events.append(VariableOverwrittenPayload{
            .event_type  = "VARIABLE_OVERWRITTEN",
            .instance_id = instance_id,
            .task_id     = task_id,
            .key         = key,
            .old_value   = json_encode(old_val, allocator),
            .new_value   = json_encode(new_value, allocator),
        })
    // else: Path 1 — new key; insert silently, no event.

    merged.put(key, new_value)   // insert or overwrite

return MergeVariablesResult{
    .merged            = merged,
    .overwritten_events = overwritten_events.toOwnedSlice(),
}
```

**Validation order:** Schema validation is checked for each key in insertion order of
`output_variables`. If any key fails, the ENTIRE merge is aborted — no partial merge
is applied. This satisfies the EE-09 AC: "the merge is NOT applied."

**No-op guarantee:** An empty `output_variables = {}` returns immediately with a
copy of `current_vars` and a zero-length events slice. The caller skips all
`VARIABLE_OVERWRITTEN` INSERTs (zero iterations). No event is emitted.

---

### 6. Integration with `completeTask` (EE-04)

`mergeVariables` is called inside the `completeTask` step sequence in `instance.zig`,
BEFORE the pure transition function is invoked. This ensures the merged variable map
is in `InstanceState.variables` when CEL gateway conditions evaluate (EE-05 AC).

**Updated `completeTask` step sequence:**

```
a. Fetch task (TaskStore.getById) — validate exists and is PENDING.
b. Load instance projection (instance_id, definition_id, current variables, status).
   If status ≠ ACTIVE → return CompleteTaskError.TaskAlreadyTerminated (HTTP 409).
c. Load definition snapshot (SnapshotStore.load).
d. Parse output_variables from request body.
   If absent or not a JSON object → return CompleteTaskError.InvalidInput (HTTP 422).
e. Acquire connection; BEGIN; SELECT FOR UPDATE on instance_projections row for instance_id.
f. [EE-09] Call mergeVariables(conn, definition_id, instance_id, task_id,
           current_vars = state.variables,
           output_variables = parsed_output_vars,
           &violation_out):
   ┌── Schema violation path:
   │      INSERT EXECUTION_ERROR event (§7 payload) into event_store.
   │      UPDATE instance_projections SET status='ERROR',
   │             error_detail=json_encode(violation_out.*), updated_at=NOW().
   │      COMMIT.
   │      Return CompleteTaskError.SchemaViolationError (HTTP 422).
   └── Success path: merge_result = MergeVariablesResult{ .merged, .overwritten_events }
g. Build updated InstanceState: state.variables = merge_result.merged.
h. Call transition(allocator, snapshot, state_with_merged_vars, task_completed_event).
   On TransitionError → ROLLBACK; return CompleteTaskError.TransitionFailed (HTTP 500).
i. Persist inside the open transaction:
   i.   TaskStore.completeInTx(conn, task_id, output_variables_json).
   ii.  event_store.appendInTx(conn, TASK_COMPLETED event).
   iii. For each e in merge_result.overwritten_events:
            event_store.appendInTx(conn, VARIABLE_OVERWRITTEN event using §8 payload).
   iv.  UPDATE instance_projections SET variables = merge_result.merged,
            current_nodes = new_state.tokens, last_event_seq = ..., updated_at = NOW().
j. COMMIT.
k. Return HTTP 200.
```

**Ordering invariant (critical):** Step f MUST precede step h. The transition function
must receive `state.variables = merge_result.merged` so that:
- CEL conditions (EE-05) evaluate the post-merge variable map.
- A schema violation prevents any token advancement.
- The ERROR transition is atomic with the EXECUTION_ERROR event.

**`CompleteTaskError` addition:**

```zig
/// Variable schema rejected a value in output_variables.
/// Instance has been transitioned to ERROR status. HTTP 422.
SchemaViolationError,
```

---

### 7. EXECUTION_ERROR event payload (SCHEMA_VIOLATION)

Satisfies EE-10 AC: "error type, affected node or field, human-readable reason, and
instance variable state at time of the error."

```json
{
    "event_type":     "EXECUTION_ERROR",
    "instance_id":    "<uuid>",
    "task_id":        "<uuid>",
    "error_type":     "SCHEMA_VIOLATION",
    "affected_field": "<variable_key>",
    "reason":         "<human-readable validation failure message>",
    "variable_state": { ... }
}
```

`variable_state` is the snapshot of `instance_projections.variables` taken BEFORE any
merge was attempted (i.e., `current_vars` at the time `mergeVariables` was called).

---

### 8. VARIABLE_OVERWRITTEN event payload

```json
{
    "event_type":  "VARIABLE_OVERWRITTEN",
    "instance_id": "<uuid>",
    "task_id":     "<uuid or null>",
    "key":         "<variable_key>",
    "old_value":   <any JSON value>,
    "new_value":   <any JSON value>,
    "merged_at":   "<ISO8601 UTC timestamp>"
}
```

`merged_at` is set by the SQL `INSERT` using `NOW()` (consistent with all other `*_at`
columns). It is NOT supplied by the application layer.

---

### 9. Integration with parallel join (EE-07)

When tokens from two or more parallel branches converge at a `PARALLEL_GATEWAY` join
node and the join threshold is met (§EE-07 step e), the EE-09 collision policy is
applied once per arriving branch, in deterministic order, before the merged token
advances.

**Join merge procedure** (persistence handler in `instance.zig`):

```
accumulated_vars = state.variables    // instance variables before any branch contributes

// Branches sorted in lexicographic order of branch_id for deterministic replay (EE-11).
for each token in arriving_tokens sorted by branch_id (lexicographic ASC):
    if token.output_variables.count() == 0:
        continue   // no contribution from this branch

    merge_result = mergeVariables(conn, definition_id, instance_id,
                       task_id = null,
                       current_vars = accumulated_vars,
                       output_variables = token.output_variables,
                       &violation_out)

    if error.SchemaViolation:
        → EXECUTION_ERROR path (same as §6 violation handling)
        → ROLLBACK; return error to caller

    accumulated_vars = merge_result.merged
    // Accumulate VARIABLE_OVERWRITTEN events for batch INSERT after all branches merge.
    all_overwritten_events.extend(merge_result.overwritten_events)

final_merged_vars = accumulated_vars
// Proceed with transition() using state.variables = final_merged_vars.
```

**Deterministic ordering:** Using lexicographic `branch_id` order ensures that event
log reconstruction (EE-11) produces identical variable state on every replay, regardless
of the wall-clock order in which branches arrived.

---

### 10. `Token` addition for parallel branch output variables

**File:** `src/engine/transition.zig` (type definition only — no I/O added)

The parallel join merge path requires each `Token` to carry the output variables produced
by the task that completed on that branch. This is a pure data field; no I/O is
introduced.

```zig
pub const Token = struct {
    id:               Uuid,
    node_id:          []const u8,
    branch_id:        []const u8,
    /// Output variables produced by the task (or SERVICE_TASK, Stage 6) that
    /// completed on this branch. Empty ObjectMap until a task on this branch completes.
    /// Used by the EE-09 merge procedure during PARALLEL_JOIN (§9 above).
    output_variables: std.json.ObjectMap,
};
```

`output_variables` is set by `instance.zig` when persisting a `task_completed` event
for a task on a parallel branch. The transition function does not modify
`token.output_variables` directly; it copies the field to new tokens on parallel splits.

---

### 11. DB transaction atomicity

Per DB-03, all writes for a single task completion MUST occur within one
`BEGIN`…`COMMIT`. There are two transaction layouts depending on the merge outcome:

**Layout A — Schema violation (ERROR path):**

```sql
BEGIN;
SELECT id FROM instance_projections WHERE instance_id = $1 FOR UPDATE;

INSERT INTO event_store (event_type, instance_id, payload, sequence, created_at)
    VALUES ('EXECUTION_ERROR', $1, $2::jsonb,
            (SELECT COALESCE(MAX(sequence),0)+1 FROM event_store WHERE instance_id=$1),
            NOW());

UPDATE instance_projections
    SET status = 'ERROR', error_detail = $3::jsonb, updated_at = NOW()
    WHERE instance_id = $1;

COMMIT;
```

**Layout B — Happy path (overwrite ≥ 0 keys):**

```sql
BEGIN;
SELECT id FROM instance_projections WHERE instance_id = $1 FOR UPDATE;

-- Complete the task row
UPDATE tasks
    SET status = 'COMPLETED', output_variables = $2::jsonb,
        completed_at = NOW(), updated_at = NOW()
    WHERE id = $3 AND status = 'PENDING';

-- TASK_COMPLETED event
INSERT INTO event_store (event_type, instance_id, payload, sequence, created_at)
    VALUES ('TASK_COMPLETED', $1, $4::jsonb,
            (SELECT COALESCE(MAX(sequence),0)+1 FROM event_store WHERE instance_id=$1),
            NOW());

-- VARIABLE_OVERWRITTEN events (zero or more INSERTs; one per overwritten key)
-- Repeated for each entry in merge_result.overwritten_events:
INSERT INTO event_store (event_type, instance_id, payload, sequence, created_at)
    VALUES ('VARIABLE_OVERWRITTEN', $1, $N::jsonb,
            (SELECT COALESCE(MAX(sequence),0)+1 FROM event_store WHERE instance_id=$1),
            NOW());

-- Projection update (variables, tokens, sequence, timestamp)
UPDATE instance_projections
    SET variables = $M::jsonb, current_nodes = $K::jsonb,
        last_event_seq = ..., updated_at = NOW()
    WHERE instance_id = $1;

COMMIT;
```

Any failure at any step triggers `ROLLBACK`; the instance remains in its pre-call state
and the caller returns HTTP 500 (`PersistenceFailed`).

---

### 12. Data flow diagram

```
POST /tasks/:id/complete
      │  output_variables: { "k": v, ... }
      ▼
handleComplete (api/routes/tasks.zig)
  │  parse body → output_vars: ObjectMap
  │  call InstanceStore.completeTask(...)
  ▼
completeTask (engine/instance.zig)
  │  a–e. fetch task, load state/snapshot, BEGIN, SELECT FOR UPDATE
  │
  ├──▶ mergeVariables(conn, def_id, inst_id, task_id,
  │          current_vars, output_vars, &violation_out)
  │       │
  │       ├── load variable_schemas (one SELECT, $1=def_id)
  │       │
  │       ├── [schema violation?] ──▶ violation_out populated
  │       │                           return error.SchemaViolation
  │       │                                │
  │       │                                ▼
  │       │                         INSERT EXECUTION_ERROR event
  │       │                         UPDATE projection status=ERROR
  │       │                         COMMIT → HTTP 422
  │       │
  │       └── [success] → MergeVariablesResult{ merged_vars, overwritten_events[] }
  │
  ├──▶ state.variables = merged_vars
  │
  ├──▶ transition(snapshot, state_with_merged_vars, task_completed_event)
  │       └── pure function; CEL evaluates against merged_vars (EE-05)
  │
  └──▶ persist (single transaction):
           UPDATE tasks → COMPLETED
           INSERT TASK_COMPLETED event
           INSERT VARIABLE_OVERWRITTEN event × len(overwritten_events)
           UPDATE instance_projections (variables=merged, tokens=new_tokens)
       COMMIT → HTTP 200
```

---

### 13. Error taxonomy

| Error identifier | Source | HTTP status | Description |
|---|---|---|---|
| `MergeVariablesError.SchemaViolation` | `mergeVariables` | (internal) | New value for existing key fails registered JSON Schema |
| `MergeVariablesError.PersistenceFailed` | `mergeVariables` | 500 | DB SELECT on `variable_schemas` failed |
| `MergeVariablesError.OutOfMemory` | `mergeVariables` | 500 | Allocator exhausted |
| `CompleteTaskError.SchemaViolationError` | `completeTask` step f | 422 | Schema violation; instance transitioned to ERROR |

---

### 14. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/db/pool.zig` | `db.Conn` | Issued SELECT on `variable_schemas` inside caller's transaction |
| `src/event_store/store.zig` | `appendInTx` | Emit VARIABLE_OVERWRITTEN and EXECUTION_ERROR events |
| `src/engine/transition.zig` | `InstanceState`, `Token` | Read `current_vars`; pass `merged_vars` as new `state.variables` |
| `migrations/012_event_retention.sql` | `variable_schemas` table | Per-variable JSON Schema storage |
| `std.json` | `ObjectMap`, `Value`, `parseFromSlice` | Variable map types; schema-value comparison |

**Must NOT be imported by:** `src/engine/transition.zig`. The merge function issues a
DB query; placing it in `transition.zig` would violate the zero-I/O contract.

---

### 15. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE09-1 | **JSON Schema validation library:** `mergeVariables` calls a `json_schema_validate` helper. No JSON Schema validator currently exists in `vendor/` or `src/tools/`. | High — blocks EE-09 implementation | BACKEND-DEV to implement a minimal inline validator covering `type`, `minimum`, `maximum`, `maxLength`, and `enum` constraints at `src/tools/json_schema.zig`. Full draft-07 compliance is not required. |
| OQ-EE09-2 | **`Token.output_variables` in replay (EE-11):** During event log replay, `token.output_variables` must be restored. The `task_completed` event payload already carries `output_variables`; the transition function must assign them to the token when replaying. Confirm this is acceptable (pure data assignment, no I/O added to `transition.zig`). | Medium — affects EE-11 correctness | Acceptable. Update `transition.zig`'s `task_completed` handler to set `token.output_variables = event.output_variables` when implementing EE-09. |
| OQ-EE09-3 | **SERVICE_TASK response merge (Stage 6):** SERVICE_TASK HTTP responses are merged per EE-09. The `task_id` parameter to `mergeVariables` will be the SERVICE_TASK node_id (not a user-visible task UUID). Confirm this naming is acceptable in the `VARIABLE_OVERWRITTEN` payload. | Low — cosmetic consistency | Defer to Stage 6 design; no change needed for EE-09. |

---

### 16. Traceability table

| EE-09 Acceptance Criterion | Design element |
|---|---|
| New key in output_variables → inserted into instance map | §5 pseudocode "Path 1": `merged.put(key, new_value)` with no event emitted |
| Existing key + schema-compatible value → overwrite + `VARIABLE_OVERWRITTEN` event | §5 pseudocode "Path 2": event appended to `overwritten_events`; §8 event payload schema |
| Existing key + schema-rejected value → merge NOT applied, instance to ERROR, `EXECUTION_ERROR` event | §5 pseudocode: `return error.SchemaViolation`; §6 violation handling; §7 EXECUTION_ERROR payload; §11 Layout A transaction |
| Merged variables immediately accessible to CEL evaluations (EE-05) | §6 ordering invariant: step f (merge) before step h (transition call); transition receives `state.variables = merge_result.merged` |
| Empty `output_variables = {}` is a no-op | §5: early return on `count() == 0`; no events emitted; no DB writes |
| Duplicate key in single task's JSON → last-value-wins | §5 note: `std.json.parseFromSlice` applies last-value-wins before `mergeVariables` is called |
| Parallel join collision uses same policy | §9: per-branch merge loop calls `mergeVariables` with same API; lexicographic ordering for determinism |
| Merge + event INSERTs + projection UPDATE are atomic (DB-03) | §11 transaction layout; `errdefer conn.rollback()` on any failure |

---

### Implementation notes for BACKEND-DEV (EE-09)

1. **Modified source files:**
   - `src/engine/instance.zig` — add `MergeVariablesError`, `MergeVariablesResult`,
     `VariableOverwrittenPayload`, `SchemaViolationDetail`; implement `mergeVariables`;
     update `completeTask` step sequence (steps f–i); add
     `CompleteTaskError.SchemaViolationError`.
   - `src/engine/transition.zig` — add `output_variables: std.json.ObjectMap` field to
     `Token` struct. **No I/O added.** Pure type change only.
   - `src/tools/json_schema.zig` — new file; minimal JSON Schema validator (OQ-EE09-1).

2. **No new migration required.** `variable_schemas` already exists in
   `migrations/012_event_retention.sql`.

3. **JSON Schema validator (OQ-EE09-1):** Before implementing `mergeVariables`,
   implement `src/tools/json_schema.zig` with a `validate(value: std.json.Value, schema: std.json.ObjectMap) ValidationResult` function. `ValidationResult` carries `ok: bool` and `reason: []const u8`. Cover at minimum: `type`, `minimum`, `maximum`, `maxLength`, `enum`.

4. **`mergeVariables` does not manage transactions.** It is called while an open
   transaction is in progress (step e of `completeTask`). Never call `BEGIN` or
   `COMMIT` inside `mergeVariables`.

5. **Security reminder:** `variable_key` values from `variable_schemas` rows are
   trusted (defined at process definition creation time). However, the `output_variables`
   keys from user requests are untrusted. All SQL parameters — `definition_id`,
   `variable_key`, and the JSON payloads for events — MUST be bound as `$N` parameters.
   No user-supplied key or value may be concatenated into a SQL string literal.

6. **Unit test file:** `tests/unit/merge_variables_test.zig`. Tests must cover:
   - All three collision paths (new key, overwrite, schema violation).
   - Empty `output_variables` no-op.
   - Duplicate key in a single `output_variables` JSON object.
   - Schema violation aborts entire merge (no partial application).
   - Parallel join deterministic ordering test (two tokens, same key, verify
     lexicographic-first branch value wins).

---

## Section EE-10: Execution Error Handling

**Covers:** EE-10 (Unified execution error handling — ERROR status, EXECUTION_ERROR event, HTTP 409 guard, concurrent race)
**Files:** `src/engine/instance.zig`, `src/api/routes/instances.zig`, `src/api/routes/tasks.zig`
**Depends on:**
- `src/engine/transition.zig` — `TransitionError.NoMatchingEdge`, `InstanceState` (read-only; no I/O added)
- `src/event_store/store.zig` — (event appended inside caller's transaction via direct SQL; not through `appendInTx` wrapper)
- `src/db/pool.zig` — `db.Pool`, `db.Conn` (transaction management)
- `migrations/001_event_store.sql` — `event_store` table
- `migrations/005_instances.sql` — `instance_projections` table (`status`, `error_detail` columns)

**Must NOT depend on:** `src/engine/transition.zig` for any I/O. `setInstanceError` lives
in `instance.zig`, not in `transition.zig`.

---

### Module purpose

EE-10 defines the platform's unified error handling path for unresolvable engine
conditions. When the execution engine encounters a condition it cannot resolve — no
matching gateway edge, a schema violation on variable merge, or any future trigger —
the platform atomically sets the process instance to `ERROR` status and appends a
structured `EXECUTION_ERROR` event. All callers (gateway no-match from EE-05,
schema-violation from EE-09, and any future trigger) use a single shared persistence
function `setInstanceError` as the sole entry-point for this transition. Once an
instance is in `ERROR` status, any subsequent state-transition attempt (task
completion, gateway evaluation) is rejected with HTTP 409 before any DB write occurs.
The instance remains in `ERROR` status until an operator retries or discards it via the
dead letter API (OBS-05, Stage 4).

---

### 1. Database schema

No new migration is required. All columns used by EE-10 already exist.

#### 1a. `instance_projections` — columns written by EE-10

```
instance_projections
────────────────────────────────────────────────────────────────────────
status          TEXT        set to 'ERROR'
error_detail    JSONB       set to the EXECUTION_ERROR payload (see §4)
updated_at      TIMESTAMPTZ set to NOW()
```

The `error_detail` column was already specified at engine.md line 39. It is `NULL`
when the instance is in `ACTIVE`, `COMPLETED`, or `CANCELLED` status; populated only
on the `ERROR` transition.

#### 1b. `event_store` — EXECUTION_ERROR event row

One row is inserted per `setInstanceError` call with `event_type = 'EXECUTION_ERROR'`
and the payload defined in §4.

---

### 2. `SetInstanceErrorError` error set

**File:** `src/engine/instance.zig`

```zig
pub const SetInstanceErrorError = error{
    /// instance_id not found in instance_projections. Caller should treat as 404.
    InstanceNotFound,
    /// Instance is already in a terminal status (ERROR, CANCELLED, or COMPLETED).
    /// Caller should treat as 409.
    AlreadyTerminal,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Any DB INSERT or UPDATE inside the transaction failed. HTTP 500.
    PersistenceFailed,
    /// Allocator returned OutOfMemory. HTTP 500.
    OutOfMemory,
};
```

`AlreadyTerminal` is returned when the row lock reveals `status` is already `ERROR`,
`CANCELLED`, or `COMPLETED`. The concurrent race design (§7) relies on this error to
suppress the second `EXECUTION_ERROR` event.

---

### 3. `ErrorType` enum

**File:** `src/engine/instance.zig`

```zig
pub const ErrorType = enum {
    /// EXCLUSIVE_GATEWAY exhausted all outgoing edges with no match and no default edge.
    /// Populated by the EE-05 gateway handler.
    NO_MATCHING_EDGE,
    /// A task output variable failed registered JSON Schema validation (EE-09).
    SCHEMA_VIOLATION,
};
```

This enum is serialised to its string name (`"NO_MATCHING_EDGE"`, `"SCHEMA_VIOLATION"`)
in the `EXECUTION_ERROR` event payload.

---

### 4. `EXECUTION_ERROR` event payload schema

The `payload` JSONB field of the `EXECUTION_ERROR` event row in `event_store`:

```json
{
  "event_type":            "EXECUTION_ERROR",
  "instance_id":           "<UUID string>",
  "error_type":            "NO_MATCHING_EDGE | SCHEMA_VIOLATION",
  "affected_node":         "<node_id string — present when error_type = NO_MATCHING_EDGE>",
  "affected_field":        "<variable key string — present when error_type = SCHEMA_VIOLATION>",
  "reason":                "<human-readable string describing the root cause>",
  "variable_state":        { "<key>": <value>, ... },
  "evaluated_conditions":  [
    { "edge_id": "<id>", "condition": "<CEL expression>", "result": false },
    ...
  ]
}
```

**Field definitions:**

| Field | Type | Presence | Description |
|---|---|---|---|
| `event_type` | string literal `"EXECUTION_ERROR"` | Always | Discriminator for event consumers and replay |
| `instance_id` | UUID string | Always | The instance that transitioned to ERROR |
| `error_type` | `"NO_MATCHING_EDGE"` or `"SCHEMA_VIOLATION"` | Always | Identifies which trigger fired |
| `affected_node` | string | When `error_type = NO_MATCHING_EDGE` | The gateway node_id where no edge matched |
| `affected_field` | string | When `error_type = SCHEMA_VIOLATION` | The variable key whose new value failed schema |
| `reason` | string | Always | Human-readable English string; never empty |
| `variable_state` | JSON object | Always | Snapshot of `instance_projections.variables` at the moment of error |
| `evaluated_conditions` | JSON array | When `error_type = NO_MATCHING_EDGE` | List of `{edge_id, condition, result}` objects for all edges evaluated; `result` is always `false` for all entries (none matched) |

**Mutual exclusivity rule:** Exactly one of `affected_node` or `affected_field` is
present in any given payload. When `error_type = NO_MATCHING_EDGE`, `affected_node` is
set and `affected_field` is absent. When `error_type = SCHEMA_VIOLATION`, `affected_field`
is set and `affected_node` is absent. The `evaluated_conditions` array is present only
for `NO_MATCHING_EDGE`.

**`error_detail` column:** `instance_projections.error_detail` is set to the same JSON
object as the event payload. This provides a direct read path for the operator without
replaying the event log.

---

### 5. `SetInstanceErrorArgs` struct

**File:** `src/engine/instance.zig`

```zig
pub const EvaluatedCondition = struct {
    edge_id:   []const u8,
    condition: []const u8,
    result:    bool,
};

pub const SetInstanceErrorArgs = struct {
    instance_id:          Uuid,
    error_type:           ErrorType,
    /// Set when error_type = NO_MATCHING_EDGE. Null otherwise.
    affected_node:        ?[]const u8,
    /// Set when error_type = SCHEMA_VIOLATION. Null otherwise.
    affected_field:       ?[]const u8,
    /// Human-readable description of the root cause.
    reason:               []const u8,
    /// Current instance variable map (snapshot at error time).
    /// Must be a valid JSON object string.
    variable_state:       []const u8,
    /// Non-null only when error_type = NO_MATCHING_EDGE.
    /// Slice may be empty if no conditions were evaluated (degenerate gateway).
    evaluated_conditions: ?[]const EvaluatedCondition,
    /// The actor_id of the caller initiating the operation that triggered the error.
    actor_id:             []const u8,
};
```

All slice fields are borrowed from the caller's scope. `setInstanceError` does not take
ownership; all serialisation to JSON is performed within the call before returning.

---

### 6. `InstanceStore.setInstanceError` method

**File:** `src/engine/instance.zig`

#### Function signature

```zig
pub fn setInstanceError(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    args: SetInstanceErrorArgs,
) SetInstanceErrorError!void
```

Returns `void` on success. On any error, the transaction is rolled back and the
corresponding `SetInstanceErrorError` variant is returned.

#### Algorithm

**Step a — Acquire a DB connection and BEGIN TRANSACTION**

Acquire a connection from `self.pool` (`SetInstanceErrorError.PoolExhausted` on
failure). Issue `BEGIN` on the connection. Set up `errdefer conn.rollback() catch {}`
to guarantee ROLLBACK on any subsequent error return.

**Step b — Lock and read the instance row**

```sql
SELECT status, variables
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE
```

Parameter: `$1` = `args.instance_id` as hex UUID string (no SQL string interpolation).

The `FOR UPDATE` clause acquires an exclusive row-level lock held until COMMIT. This
serialises concurrent ERROR-triggering operations on the same instance (§7 concurrent
race).

Result interpretation:
- 0 rows → ROLLBACK, return `SetInstanceErrorError.InstanceNotFound`.
- 1 row with `status IN ('ERROR', 'CANCELLED', 'COMPLETED')` → ROLLBACK, return
  `SetInstanceErrorError.AlreadyTerminal`.
- 1 row with `status = 'ACTIVE'` → proceed to step c.

**Note on `variables` column:** The `variables` JSONB column is read here to produce
the `variable_state` snapshot in the event payload. If `args.variable_state` is
supplied by the caller from an in-memory state (always the case for EE-05 and EE-09
callers who hold the current `InstanceState`), this read is used only for the lock;
the in-memory `args.variable_state` is preferred for the payload and is always
consistent with the pre-error state. Do NOT re-read variables from the DB row to build
the payload; use `args.variable_state` as provided by the caller.

**Step c — Serialise event payload**

Build the `EXECUTION_ERROR` event payload JSON in memory (see §4) using
`std.json.stringify` or a manual builder. The payload is allocated with `allocator` as
a `[]const u8`. On `error.OutOfMemory`, ROLLBACK (via errdefer), return
`SetInstanceErrorError.OutOfMemory`.

**Step d — Insert EXECUTION_ERROR event**

```sql
INSERT INTO event_store
    (instance_id, event_type, sequence, payload, actor_id, created_at)
VALUES
    ($1::uuid, 'EXECUTION_ERROR', (
        SELECT COALESCE(MAX(sequence), 0) + 1
        FROM event_store
        WHERE instance_id = $1::uuid
    ), $2::jsonb, $3, NOW())
```

Parameters (all bound as `$N`):
- `$1` = `args.instance_id` as hex UUID string
- `$2` = serialised event payload JSON from step c
- `$3` = `args.actor_id` string

On DB failure: ROLLBACK (via errdefer), return `SetInstanceErrorError.PersistenceFailed`.

**Step e — Update instance_projections**

```sql
UPDATE instance_projections
SET
    status       = 'ERROR',
    error_detail = $2::jsonb,
    updated_at   = NOW()
WHERE instance_id = $1::uuid
```

Parameters:
- `$1` = `args.instance_id` as hex UUID string
- `$2` = same serialised event payload JSON from step c (reuse the same `[]const u8`)

On DB failure: ROLLBACK (via errdefer), return `SetInstanceErrorError.PersistenceFailed`.

**Step f — COMMIT**

Issue `COMMIT` on the connection. On failure: return `SetInstanceErrorError.PersistenceFailed`.
Release the connection to the pool. Return `void` (success).

#### Atomicity invariant

Steps a through f (BEGIN → SELECT FOR UPDATE → JSON build → event INSERT → projection
UPDATE → COMMIT) execute as a single DB transaction. If any step fails after BEGIN,
ROLLBACK is issued via `errdefer`. No partial state is observable: the instance either
fully transitions to ERROR (both event row and projection updated) or remains unchanged.

---

### 7. Concurrent ERROR race

**Scenario:** Two concurrent operations (e.g. two gateway evaluations on the same
instance, both seeing no matching edge) both call `setInstanceError` simultaneously.

**Resolution via SELECT FOR UPDATE:**

```
T1: BEGIN → SELECT status='ACTIVE' FOR UPDATE → locks row
T2: BEGIN → SELECT ... FOR UPDATE → BLOCKED (waiting for T1's lock)

T1: INSERT EXECUTION_ERROR event, UPDATE status='ERROR' → COMMIT → releases lock
T2: SELECT returns → status='ERROR' → AlreadyTerminal → ROLLBACK
    → setInstanceError returns SetInstanceErrorError.AlreadyTerminal
    → caller returns HTTP 409 (no second EXECUTION_ERROR event inserted)
```

The first caller to commit wins. The second caller sees `status = 'ERROR'` after
acquiring the lock, returns `SetInstanceErrorError.AlreadyTerminal`, and the HTTP
handler maps this to HTTP 409.

**Invariant:** At most one `EXECUTION_ERROR` event is ever inserted per instance
per error-triggering event. The event log is never corrupted with duplicate ERROR
transitions.

---

### 8. HTTP 409 guard for subsequent state-transition attempts

**Purpose:** When any state-transition handler (task completion, gateway evaluation,
or future trigger) is invoked on an instance already in `ERROR` status, it MUST
detect this before any DB write and return HTTP 409 immediately.

**Where the check is placed:**

#### In `completeTask` (`src/engine/instance.zig`)

The `SELECT FOR UPDATE` already performed at the start of `completeTask` (step b of
EE-04/EE-09 algorithm) reads `instance_projections.status`. The guard is an additional
status check immediately after reading the row:

```
Step b of completeTask:
    SELECT status, current_nodes, variables
    FROM instance_projections
    WHERE instance_id = $1 FOR UPDATE

    if status = 'ERROR'   → ROLLBACK; return CompleteTaskError.InstanceInError → HTTP 409
    if status = 'CANCELLED' → ROLLBACK; return CompleteTaskError.TaskAlreadyTerminated → HTTP 409
    if status = 'COMPLETED' → ROLLBACK; return CompleteTaskError.TaskAlreadyTerminated → HTTP 409
```

The new `InstanceInError` variant is added to `CompleteTaskError`:

```zig
pub const CompleteTaskError = error{
    // ... existing variants ...
    /// Instance is in ERROR status; no further state transitions allowed. HTTP 409.
    InstanceInError,
};
```

#### In gateway evaluation handler (`src/engine/instance.zig`)

The gateway evaluation path (called from `completeTask` or a dedicated handler) must
also apply the guard before calling `transition()`. The guard is already implicitly
covered by the `completeTask` `SELECT FOR UPDATE` check above, since gateway evaluation
occurs within the same transaction as task completion. No additional check point is
required in the transition function itself (it is pure).

**HTTP mapping:**

`CompleteTaskError.InstanceInError` is mapped to HTTP 409 in `src/api/errors.zig`:

```zig
CompleteTaskError.InstanceInError => .{
    .status = 409,
    .code   = "INSTANCE_IN_ERROR",
    .detail = "Instance is in ERROR status. Use the dead letter API to retry or discard.",
},
```

---

### 9. Caller integration

#### EE-05 gateway no-match caller (in `completeTask`, `src/engine/instance.zig`)

When `transition()` returns `TransitionError.NoMatchingEdge`:

```
transition(snapshot, state, event) catch |err| switch (err) {
    TransitionError.NoMatchingEdge => {
        self.setInstanceError(allocator, .{
            .instance_id          = instance_id,
            .error_type           = .NO_MATCHING_EDGE,
            .affected_node        = gateway_node_id,   // the gateway node token was on
            .affected_field       = null,
            .reason               = "No outgoing edge condition matched and no default edge defined",
            .variable_state       = state_vars_json,   // serialised from state.variables
            .evaluated_conditions = &evaluated_conds,  // built during CEL eval loop (§9a)
            .actor_id             = actor_id,
        }) catch |set_err| return mapSetErrorToCompleteError(set_err);
        return CompleteTaskError.InstanceInError;
    },
    // ... other errors ...
};
```

`evaluated_conds` is a `[]EvaluatedCondition` built by the gateway evaluation loop in
`instance.zig` (not in `transition.zig`). Each entry records the `edge_id`, the CEL
expression string, and whether it evaluated to `true` or `false`. The `transition()`
pure function returns an error tag only — the caller reconstructs the condition list
from the snapshot.

**Important:** `setInstanceError` is called **outside** the main `completeTask`
transaction. The ERROR path diverges at `transition()` failure: the `completeTask`
transaction is rolled back (via `errdefer`), then `setInstanceError` opens its own
transaction. This keeps the ERROR commit isolated from any partial task-completion
state.

#### EE-09 schema-violation caller (in `completeTask`, `src/engine/instance.zig`)

When `mergeVariables` returns `MergeVariablesError.SchemaViolation`:

```
mergeVariables(...) catch |err| switch (err) {
    MergeVariablesError.SchemaViolation => {
        self.setInstanceError(allocator, .{
            .instance_id          = instance_id,
            .error_type           = .SCHEMA_VIOLATION,
            .affected_node        = null,
            .affected_field       = violation.variable_key,
            .reason               = violation.reason,
            .variable_state       = state_vars_json,
            .evaluated_conditions = null,
            .actor_id             = actor_id,
        }) catch |set_err| return mapSetErrorToCompleteError(set_err);
        return CompleteTaskError.InstanceInError;
    },
    // ... other errors ...
};
```

Same isolation principle: `mergeVariables` is called within an open `completeTask`
transaction; on `SchemaViolation`, that transaction is rolled back first, then
`setInstanceError` opens its own transaction.

---

### 10. Data flow diagram

```
POST /tasks/:id/complete  (or gateway evaluation triggered by task completion)
      │
      ▼
handleCompleteTask (api/routes/tasks.zig)
  │  parse body → output_vars
  │
  └──▶ instance_store.completeTask(allocator, task_id, output_vars, actor_id)
            │
            ├── [b] SELECT status, vars FROM instance_projections WHERE id=$1 FOR UPDATE
            │       ├── status = 'ERROR'     → CompleteTaskError.InstanceInError → HTTP 409
            │       ├── status = 'CANCELLED' → CompleteTaskError.TaskAlreadyTerminated → 409
            │       └── status = 'ACTIVE'    → continue
            │
            ├── [f] mergeVariables(...)
            │       └── SchemaViolation ──▶ ROLLBACK completeTask tx
            │                              setInstanceError(.SCHEMA_VIOLATION, ...)
            │                              ├─ [b] SELECT FOR UPDATE → status='ACTIVE' → lock
            │                              ├─ [c] build EXECUTION_ERROR payload JSON
            │                              ├─ [d] INSERT INTO event_store
            │                              ├─ [e] UPDATE instance_projections status='ERROR'
            │                              └─ [f] COMMIT
            │                              return CompleteTaskError.InstanceInError → HTTP 409
            │                              (EE-09 schema violation: HTTP 422 in prior design
            │                               is updated to HTTP 409 to match EE-10 spec)
            │
            ├── [h] transition(snapshot, state, event)
            │       └── NoMatchingEdge ──▶ ROLLBACK completeTask tx
            │                             setInstanceError(.NO_MATCHING_EDGE, ...)
            │                             ├─ [b] SELECT FOR UPDATE → status='ACTIVE' → lock
            │                             ├─ [c] build EXECUTION_ERROR payload JSON
            │                             │       (includes evaluated_conditions list)
            │                             ├─ [d] INSERT INTO event_store
            │                             ├─ [e] UPDATE instance_projections status='ERROR'
            │                             └─ [f] COMMIT
            │                             return CompleteTaskError.InstanceInError → HTTP 409
            │
            └── [happy path] persist TASK_COMPLETED + variable + projection → HTTP 200

Concurrent race (two parallel NoMatchingEdge triggers on same instance):
  T1: setInstanceError → SELECT status='ACTIVE' FOR UPDATE → lock acquired
  T2: setInstanceError → SELECT FOR UPDATE → BLOCKED
  T1: INSERT event + UPDATE status='ERROR' → COMMIT
  T2: SELECT returns status='ERROR' → AlreadyTerminal → ROLLBACK → HTTP 409
```

---

### 11. Atomic transaction layout

**Single setInstanceError call (normal case):**

```sql
BEGIN;

SELECT status, variables
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE;

-- If status != 'ACTIVE': ROLLBACK; return AlreadyTerminal.

INSERT INTO event_store
    (instance_id, event_type, sequence, payload, actor_id, created_at)
VALUES
    ($1::uuid, 'EXECUTION_ERROR',
     (SELECT COALESCE(MAX(sequence), 0) + 1 FROM event_store WHERE instance_id = $1::uuid),
     $2::jsonb, $3, NOW());

UPDATE instance_projections
SET
    status       = 'ERROR',
    error_detail = $2::jsonb,
    updated_at   = NOW()
WHERE instance_id = $1::uuid;

COMMIT;
```

Parameters:
- `$1` = instance_id (hex UUID, no string interpolation)
- `$2` = EXECUTION_ERROR JSON payload (bound as JSONB)
- `$3` = actor_id string

**Concurrent second caller (race loser):**

```sql
BEGIN;

SELECT status, variables
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE;
-- Returns status = 'ERROR' (T1 already committed)

ROLLBACK;
-- Returns SetInstanceErrorError.AlreadyTerminal → HTTP 409
```

---

### 12. Operator retry/discard hooks

EE-10 only **sets** the `ERROR` status and records the `EXECUTION_ERROR` event. It
does not implement the retry or discard paths. Those paths are defined in **OBS-05**
(dead letter API), which is a Stage 4 requirement. The design note for BACKEND-DEV is:

- `setInstanceError` must not clear `error_detail` or change status back to `ACTIVE`.
  It is a one-way transition.
- OBS-05 implementation will read `instance_projections.error_detail` and
  `instance_projections.status = 'ERROR'` to identify instances eligible for
  retry/discard.
- No EE-10 code references OBS-05 — dependency flows from OBS-05 to EE-10, not the
  reverse.

---

### 13. Error taxonomy

| Error identifier | Source | HTTP status | Description |
|---|---|---|---|
| `SetInstanceErrorError.InstanceNotFound` | step b (0 rows) | 404 (caller maps) | No row in `instance_projections` for `instance_id` |
| `SetInstanceErrorError.AlreadyTerminal` | step b (status check) | 409 | Instance already in ERROR, CANCELLED, or COMPLETED; no second event inserted |
| `SetInstanceErrorError.PoolExhausted` | step a | 503 | Pool exhausted; cannot acquire connection |
| `SetInstanceErrorError.PersistenceFailed` | steps d, e, or f | 500 | Any DB write failed inside the transaction |
| `SetInstanceErrorError.OutOfMemory` | step c | 500 | Allocator exhausted during payload serialisation |
| `CompleteTaskError.InstanceInError` | `completeTask` step b | 409 | Instance already in ERROR; detected before any DB write |

---

### 14. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Connection acquisition and transaction management |
| `migrations/001_event_store.sql` | `event_store` table | EXECUTION_ERROR event INSERT (step d) |
| `migrations/005_instances.sql` | `instance_projections` table | `SELECT FOR UPDATE` (step b) and `UPDATE status='ERROR'` (step e) |
| `std.json` | `stringify`, `Value`, `ObjectMap` | Serialise EXECUTION_ERROR payload in step c |
| `std.mem` | `Allocator` | Temporary payload JSON buffer |

**Must NOT be imported by:** `src/engine/transition.zig`. The `setInstanceError`
function issues DB queries and must not be placed in or called from the pure transition
function.

---

### 15. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE10-1 | **HTTP status for schema-violation ERROR path:** EE-09 §13 maps `CompleteTaskError.SchemaViolationError` to HTTP 422. EE-10 specifies the error path yields HTTP 409. These are now the same code path (both set ERROR and call `setInstanceError`). The unified return code should be 409 (instance entered ERROR state). Confirm that the EE-09 422 mapping is superseded by EE-10 409. | Medium — affects API contract; clients must handle 409 not 422 for schema violations | Confirm with REQ-ANALYST. Recommended: use HTTP 409 for both triggers, as the EE-10 requirement text specifies 409 for any operation on an ERROR instance, and the error transition is the defining result. Update `src/api/errors.zig` accordingly. |
| OQ-EE10-2 | **`evaluated_conditions` reconstruction:** `transition()` returns only `TransitionError.NoMatchingEdge` — it does not return the list of evaluated conditions. The caller in `instance.zig` must reconstruct this list from the definition snapshot and the CEL evaluation loop it ran. Confirm that `instance.zig` is the correct owner of the CEL evaluation loop for the gateway (not `transition.zig`). | Medium — affects where CEL eval loop lives; if in `transition.zig`, the loop result cannot be accessed by the caller | Confirmed by the pure-function contract: CEL eval producing structured output for the error payload must happen in `instance.zig`. `transition.zig` remains I/O-free and returns only an error tag. The gateway CEL evaluation loop is duplicated in `instance.zig` for the error-payload construction path. |
| OQ-EE10-3 | **`setInstanceError` called outside or inside `completeTask` transaction:** The design specifies that the `completeTask` main transaction is rolled back before `setInstanceError` opens its own transaction. This means no DB state from the partial task-completion is visible at the time `setInstanceError` runs. Confirm this is the intended isolation model vs. keeping the ERROR write inside the `completeTask` transaction. | Low — both models are safe; the isolated model is simpler | Recommended: isolated model (rollback first, then separate `setInstanceError` transaction). Simplifies the EE-09 Layout A pattern (§11 of EE-09 section) which already showed a separate ERROR transaction. |

---

### 16. Traceability table

| EE-10 Acceptance Criterion | Design element |
|---|---|
| Unresolvable condition → `status = ERROR` and `EXECUTION_ERROR` event appended | §6 `setInstanceError` step e: `UPDATE instance_projections SET status='ERROR'`; step d: `INSERT INTO event_store` with `event_type='EXECUTION_ERROR'`; both within one `BEGIN`…`COMMIT` |
| `EXECUTION_ERROR` event contains: error type, affected node or field, human-readable reason, variable state at time of error | §4 payload schema: `error_type`, `affected_node`/`affected_field`, `reason`, `variable_state` fields |
| `EXECUTION_ERROR` carries sufficient context for operator to diagnose without replay | §4 payload: `evaluated_conditions` for gateway errors; `affected_field` + `reason` for schema violations; `variable_state` snapshot always included |
| Operation on ERROR-status instance → HTTP 409 | §8 HTTP 409 guard: `completeTask` step b reads `status` after `FOR UPDATE`; `InstanceInError` error → HTTP 409 via `src/api/errors.zig` |
| Concurrent dual-trigger: first commits, second sees ERROR → HTTP 409, no second EXECUTION_ERROR event | §7 concurrent race: `SELECT FOR UPDATE` serialises; second caller reads `status='ERROR'` → `AlreadyTerminal` → ROLLBACK → HTTP 409; no event INSERT |
| Instance remains in ERROR until operator action (OBS-05) | §12 operator hooks: `setInstanceError` is a one-way transition; no automatic recovery in EE-10 scope; OBS-05 (Stage 4) provides retry/discard |

---

### Implementation notes for BACKEND-DEV (EE-10)

1. **Modified source files:**
   - `src/engine/instance.zig` — add `ErrorType` enum, `EvaluatedCondition` struct,
     `SetInstanceErrorArgs` struct, `SetInstanceErrorError` error set, `setInstanceError`
     function; add `CompleteTaskError.InstanceInError` variant; update `completeTask` to
     add status guard (step b) and call `setInstanceError` on `SchemaViolation` and
     `NoMatchingEdge` error paths (§9 caller integration).
   - `src/api/routes/tasks.zig` — add HTTP mapping for `CompleteTaskError.InstanceInError`
     → HTTP 409 with code `"INSTANCE_IN_ERROR"`.
   - `src/api/errors.zig` — add `INSTANCE_IN_ERROR` error code and 409 mapping entry.

2. **No new migration required.** The `error_detail` JSONB column already exists on
   `instance_projections` (engine.md line 39; `migrations/001_event_store.sql`).

3. **Transaction isolation for the ERROR path:** Roll back the `completeTask` open
   transaction first (via `errdefer conn.rollback()`), release the connection, then call
   `setInstanceError` with a fresh connection acquisition. This prevents any partial
   task-completion state from appearing in the DB before the ERROR transition commits.

4. **CEL evaluation loop ownership (OQ-EE10-2):** The gateway CEL evaluation loop that
   builds `evaluated_conditions` must live in `instance.zig`, not `transition.zig`. The
   transition function returns only `TransitionError.NoMatchingEdge`. The caller in
   `instance.zig` reconstructs the evaluated-condition list by re-running the CEL
   expressions from the snapshot before calling `setInstanceError`. This is a deliberate
   duplication to preserve the zero-I/O contract of `transition.zig`.

5. **HTTP 409 guard placement:** The guard check on `status = 'ERROR'` in `completeTask`
   step b must occur immediately after the `SELECT FOR UPDATE` reads the row, before any
   variable merge, before calling `transition()`, and before any DB write. This is a
   pre-condition check, not an error recovery step.

6. **Security reminder:** `instance_id` (from URL), `actor_id` (from auth context), and
   the event `payload` JSON are all bound as `$N` parameters. The `evaluated_conditions`
   array and all string fields from `SetInstanceErrorArgs` are serialised in-process via
   `std.json.stringify` before being bound as JSONB parameters. No user-supplied value
   is concatenated into any SQL string literal.

7. **Integration test file:** `tests/integration/instance_error_test.zig`. Tests must
   cover:
   - Gateway no-match → ERROR status, EXECUTION_ERROR event, evaluated_conditions in
     payload, HTTP 409 on subsequent completeTask.
   - Schema violation → ERROR status, EXECUTION_ERROR event, affected_field in payload,
     HTTP 409 on subsequent completeTask.
   - Concurrent race: two goroutines triggering ERROR simultaneously on the same instance;
     assert exactly one EXECUTION_ERROR event in event_store.
   - Operation on already-ERROR instance → HTTP 409 without inserting a second event.

---

## Section EE-11: State Reconstruction

**Covers:** EE-11 (State reconstruction — full event-log replay, cross-table merge, optional write-back, POST /instances/{id}/reconstruct)
**Files:** `src/engine/reconstruction.zig` (new), `src/api/routes/instances.zig`
**Depends on:**
- `src/engine/transition.zig` — `transition()` (the EE-02 pure transition function, referred to as "applyEvent" in the requirement), `InstanceState`, `InstanceStatus`, `Token`, `TransitionEvent`
- `src/event_store/store.zig` — `Store.read()` for active events; `EventRecord`, `Uuid`
- `src/db/pool.zig` — `db.Pool`, `db.Conn` (direct query for `events_archive` rows)
- `migrations/001_event_store.sql` — `events` table
- `migrations/003_event_archive.sql` — `events_archive` table (already exists; no new migration required)
- `migrations/005_instances.sql` — `instance_projections` table (write-back path only)

**Must NOT depend on:** any I/O in `src/engine/transition.zig`. The `transition()` function MUST remain I/O-free. All DB queries for event retrieval and write-back are performed in `reconstruction.zig`, not in `transition.zig`.

---

### Module purpose

EE-11 defines the platform's state reconstruction capability. At any point in time,
the full current state of any process instance can be derived deterministically by
fetching every event the instance has ever emitted — from both the live `events` table
and the archive `events_archive` table — and replaying them in strict `sequence_number`
order through the pure transition function (`transition()` in `src/engine/transition.zig`).
The result is guaranteed to be identical to the persisted projection in
`instance_projections`, field-for-field.

Reconstruction serves two purposes:
1. **Read-model repair:** if `instance_projections` is corrupt or absent, the platform
   can rebuild it without any data loss because the event log is the ground truth.
2. **Auditability:** an operator can reconstruct the state at any point in history by
   replaying only events up to a given `sequence_number` (ES-06 point-in-time path,
   out of scope for EE-11 itself but using the same mechanism).

---

### 1. Database schema

No new migration is required. All tables used by EE-11 already exist.

| Table | Migration | Role |
|---|---|---|
| `events` | `001_event_store.sql` | Primary event log; queried first |
| `events_archive` | `003_event_archive.sql` | Archive of older events; queried second |
| `instance_projections` | `001_event_store.sql` | Read-model; updated on optional write-back |

The `events` and `events_archive` tables share an identical column schema (excluding
`events_archive.archived_at`). This ensures a UNION ALL query returns a homogeneous
result set that can be decoded with the same `EventRecord` parser used for live events.

---

### 2. `ReconstructionError` error set

**File:** `src/engine/reconstruction.zig`

```zig
pub const ReconstructionError = error{
    /// No events found for this instance_id in either events or events_archive.
    /// Caller maps to HTTP 404.
    InstanceNotFound,
    /// A SELECT FOR UPDATE on instance_projections was blocked (lock contention).
    /// Only raised when write_back = true. Caller maps to HTTP 409.
    LockContention,
    /// db.Pool.acquire() returned ExhaustedPool. HTTP 503.
    PoolExhausted,
    /// Any DB query failed (transient). HTTP 500.
    QueryFailed,
    /// transition() returned an error while replaying an event.
    /// This indicates a corrupt or inconsistent event log. HTTP 500.
    ReplayFailed,
    /// Allocator exhausted. HTTP 500.
    OutOfMemory,
};
```

---

### 3. `reconstructInstance` function signature

**File:** `src/engine/reconstruction.zig`

```zig
const std = @import("std");
const pg = @import("pg");
const transition_mod = @import("transition.zig");
const InstanceState   = transition_mod.InstanceState;
const InstanceStatus  = transition_mod.InstanceStatus;
const Token           = transition_mod.Token;
const TransitionEvent = transition_mod.TransitionEvent;
const store_mod       = @import("../event_store/store.zig");
const Uuid            = store_mod.Uuid;

/// Reconstruct the full current state of an instance by replaying its event log.
///
/// Parameters:
///   allocator   — Arena or child allocator; caller owns all returned memory.
///   pool        — Shared pg.Pool; function acquires one connection internally.
///   instance_id — The UUID of the instance to reconstruct.
///   write_back  — If true, persist the reconstructed InstanceState back to
///                 instance_projections using the same atomic UPDATE as normal
///                 projection updates (see §7). Requires a second connection
///                 acquisition after the read phase.
///
/// Returns the final InstanceState after all events have been replayed.
/// Returns ReconstructionError.InstanceNotFound if no events exist for the instance.
///
/// The pure transition function (transition.transition, EE-02) is called once per
/// event. No DB writes occur during the replay loop itself (NFR-04 compliance, §9).
pub fn reconstructInstance(
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    instance_id: Uuid,
    write_back: bool,
) ReconstructionError!InstanceState {
    // ... implementation in src/engine/reconstruction.zig ...
}
```

The function is the sole public entry point for EE-11 reconstruction. It is called by:
- The `POST /instances/{id}/reconstruct` HTTP handler (§8) with `write_back = true`.
- Any future internal caller that needs a verified current state (e.g. OBS-05 retry
  path) with `write_back = false`.

---

### 4. Initial state for replay

Before the first event is applied, the reconstruction function initialises an
`InstanceState` representing the "pre-birth" condition of the instance. This matches
the logical state of an instance before its `INSTANCE_STARTED` event is applied:

```zig
const initial_state = InstanceState{
    .instance_id          = instance_id,
    .status               = .ACTIVE,
    .tokens               = &[_]Token{},
    .variables            = std.json.ObjectMap{},
    .pending_task_nodes   = &[_][]const u8{},
    .error_detail         = null,
    .pending_events       = &[_]transition_mod.PendingEvent{},
    .cancelled_branch_ids = &[_][]const u8{},
};
```

This initial state is identical to the value passed to `transition()` for the first
`INSTANCE_STARTED` event during EE-01 instance creation. Replaying `INSTANCE_STARTED`
against this state places the token on the first node after the START gateway, seeding
variables and producing the first live `InstanceState`. All subsequent events advance
that state.

---

### 5. Event retrieval query design

#### 5a. Merged query (UNION ALL)

The preferred approach for complete reconstruction uses a single parameterised query
that merges both tables in ascending `sequence_number` order:

```sql
SELECT event_id, instance_id, event_type, payload, actor_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
       sequence_number, idempotency_key, metadata, global_seq
FROM events
WHERE instance_id = $1::uuid

UNION ALL

SELECT event_id, instance_id, event_type, payload, actor_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
       sequence_number, idempotency_key, metadata, global_seq
FROM events_archive
WHERE instance_id = $1::uuid

ORDER BY sequence_number ASC
```

Parameters:
- `$1` = `instance_id` as a hex UUID string (bound via pg.zig prepared statement; no
  string interpolation).

The `ORDER BY sequence_number ASC` applies across the full UNION result set, ensuring
events from `events_archive` (which by design have lower `sequence_number` values than
live events) appear first in the replay stream.

#### 5b. Graceful fallback for missing or empty `events_archive`

Because `events_archive` was created in migration `003_event_archive.sql` with
`CREATE TABLE IF NOT EXISTS`, it always exists in a correctly migrated database.
However, the reconstruction function must handle two edge cases gracefully:

1. **Empty archive** — the UNION ALL returns only the rows from `events`; this is
   normal operation and requires no special handling.

2. **Archive table does not exist** (e.g. a test environment running only migration 001) —
   the UNION ALL query will fail with a PostgreSQL relation-not-found error. The
   implementation MUST catch this specific error and fall back to querying only the
   `events` table:

```sql
-- Fallback query (no UNION ALL):
SELECT event_id, instance_id, event_type, payload, actor_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
       sequence_number, idempotency_key, metadata, global_seq
FROM events
WHERE instance_id = $1::uuid
ORDER BY sequence_number ASC
```

The fallback is triggered only when the primary query returns a PostgreSQL error with
`SQLSTATE 42P01` (relation does not exist). Any other error propagates as
`ReconstructionError.QueryFailed`.

#### 5c. Row decoding

Each result row is decoded into an `EventRecord` struct (defined in
`src/event_store/store.zig`) using the same column-order mapping already used by
`Store.read()`. The `archived_at` column present in `events_archive` rows is excluded
from the SELECT list so the decoder is table-agnostic.

---

### 6. Event replay loop

After the event list is fetched and decoded into `[]EventRecord`, the reconstruction
function iterates through every record in ascending `sequence_number` order:

```
state = initial_state   // see §4

for each EventRecord r in events_ordered_by_sequence_number:
    if r.event_type == "EXECUTION_ERROR":
        // EE-10: this event records a terminal error transition.
        // Directly set status = ERROR and stop replay.
        state.status       = .ERROR
        state.error_detail = r.payload  // JSON bytes from the event record
        BREAK

    te = mapToTransitionEvent(r)  // see §6a below
    state = transition(allocator, snapshot, state, te)
        catch |err| => return ReconstructionError.ReplayFailed

return state
```

Replay halts immediately on `EXECUTION_ERROR` because no valid state transition exists
after an instance has entered `ERROR` status (EE-10 §8). Any events with a higher
`sequence_number` than the `EXECUTION_ERROR` event are unreachable under normal
operation (the platform rejects appends to ERROR instances), but if such events exist
(data inconsistency), they are silently ignored by the early-exit logic above.

#### 6a. Event-type to TransitionEvent mapping

The `mapToTransitionEvent` helper converts a raw `EventRecord` into a `TransitionEvent`
union value for consumption by `transition()`:

| DB `event_type` | `TransitionEvent` variant | Payload mapping |
|---|---|---|
| `INSTANCE_STARTED` | `.instance_started` | `initial_variables` from `payload.initial_variables`; `start_node_id` from `payload.start_node_id` |
| `TASK_COMPLETED` | `.task_completed` | `task_node_id` from `payload.task_node_id`; `output_variables` from `payload.output_variables` |
| `EXECUTION_ERROR` | (handled before `transition()` — see §6) | N/A |
| Any other type | `.unknown{ .event_type = r.event_type }` | `transition()` returns `TransitionError.UnknownEventType` → caller returns `ReconstructionError.ReplayFailed` |

The `snapshot` argument passed to `transition()` is the definition graph stored in
`instance_projections.definition_snapshot` at the time of the query, fetched alongside
the event list in the same DB round-trip.

#### 6b. `pending_events` during replay

`transition()` may produce `InstanceState.pending_events` (e.g. `parallel_split` or
`parallel_join` payloads) as part of a transition. During reconstruction, these pending
events represent side-effects that were already persisted to the DB as subsequent event
records. The replay loop does NOT re-process `pending_events`; it only consumes the
already-persisted `EventRecord` stream. After all events are replayed, the final
`InstanceState.pending_events` field is reset to empty before returning, since all
pending side-effects are already reflected in the event log.

---

### 7. Optional write-back path

If `write_back = true`, after the replay loop completes successfully, the function
persists the reconstructed `InstanceState` back to `instance_projections`:

```sql
BEGIN;

SELECT instance_id
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE NOWAIT;
-- If NOWAIT raises lock_not_available (SQLSTATE 55P03):
--   ROLLBACK; return ReconstructionError.LockContention -> HTTP 409

UPDATE instance_projections
SET
    status        = $2,
    current_nodes = $3::jsonb,
    variables     = $4::jsonb,
    error_detail  = $5::jsonb,
    updated_at    = NOW()
WHERE instance_id = $1::uuid;

COMMIT;
```

Parameters:
- `$1` = `instance_id` (hex UUID, bound as parameter)
- `$2` = reconstructed `status` as TEXT (`ACTIVE`, `COMPLETED`, `CANCELLED`, `ERROR`)
- `$3` = reconstructed token positions as JSONB (serialised from `InstanceState.tokens`)
- `$4` = reconstructed variables as JSONB (serialised from `InstanceState.variables`)
- `$5` = `error_detail` as JSONB, or SQL NULL if `error_detail` is null

The `FOR UPDATE NOWAIT` clause ensures the write-back does not block indefinitely if
another transaction is currently modifying the instance. A lock contention raises
`ReconstructionError.LockContention`, which the HTTP handler maps to HTTP 409.

The UPDATE uses the exact same column set as the normal projection update performed
by `completeTask()` in `src/engine/instance.zig`, satisfying the requirement that
write-back uses the same atomic UPDATE as normal projection updates.

---

### 8. API endpoint: POST /instances/{id}/reconstruct

**File:** `src/api/routes/instances.zig`

#### 8a. Request

```
POST /instances/{id}/reconstruct
Authorization: Bearer <operator-token>
Content-Type: application/json
Body: {} (empty JSON object; no request parameters required)
```

The `{id}` path parameter is the instance UUID (validated as a 36-character UUID string
before any DB query). Authorization requires the `operator` role (the same role guard
used by all administrative endpoints).

#### 8b. Response matrix

| Condition | HTTP status | Body |
|---|---|---|
| Reconstruction successful | 200 OK | `InstanceState` as JSON |
| No events found for `{id}` | 404 Not Found | `{"error": "INSTANCE_NOT_FOUND"}` |
| Write-back lock contention | 409 Conflict | `{"error": "LOCK_CONTENTION"}` |
| Pool exhausted | 503 Service Unavailable | `{"error": "POOL_EXHAUSTED"}` |
| Replay failed (corrupt log) | 500 Internal Server Error | `{"error": "REPLAY_FAILED"}` |

#### 8c. Handler algorithm

```
1. Extract and validate {id} from URL path.
2. Verify operator role from JWT claims; return 403 if missing.
3. Call reconstructInstance(allocator, pool, instance_id, write_back=true).
4. On ReconstructionError.InstanceNotFound -> return HTTP 404.
5. On ReconstructionError.LockContention   -> return HTTP 409.
6. On ReconstructionError.PoolExhausted    -> return HTTP 503.
7. On any other ReconstructionError        -> return HTTP 500.
8. Serialise the returned InstanceState as JSON.
9. Return HTTP 200 with the JSON body.
```

#### 8d. Security constraints

- `instance_id` from the URL path is validated as a UUID (hex or hyphenated form) before
  any DB query. Invalid UUID format returns HTTP 400 without a DB call.
- The `instance_id` value is bound as a `$1` parameter in all SQL queries; it is NEVER
  concatenated into a SQL string literal.
- The operator role check is performed before `reconstructInstance` is called; no DB
  query executes for unauthenticated or unauthorised requests.

---

### 9. NFR-04 compliance path

NFR-04 requires reconstruction to complete within <= 5 seconds for up to 10,000 events.

The replay loop achieves this because:

1. **Single DB round-trip for event retrieval.** The UNION ALL query (§5a) fetches all
   events for the instance in a single `SELECT` statement. At 10,000 events, this is
   one network round-trip to PostgreSQL.

2. **O(1) per event in the transition function.** `transition()` (EE-02) performs no
   I/O, no allocation beyond the new `InstanceState` value, and no unbounded loops.
   For 10,000 events the replay loop is O(N) with a small constant factor.

3. **No DB writes during replay.** The replay loop itself issues zero DB queries.
   The only write that may occur is the single optional write-back UPDATE at the end
   (§7), outside the replay loop.

4. **In-process JSON decoding.** Each `EventRecord.payload` is decoded in-process using
   `std.json`. No additional network calls are made per event.

At typical event sizes (< 4 KB per payload), 10,000 events occupy < 40 MB of memory.
With an arena allocator, the allocation pattern is a series of small forward-only
allocations — ideal for cache locality.

Benchmark target: `tests/bench/reconstruction_bench.zig` — replay 10,000 events;
assert wall-clock time <= 5,000 ms (NFR-04). Run with `zig build bench`.

---

### 10. Edge cases

#### 10a. Instance with 0 events

If the UNION ALL query returns 0 rows, `reconstructInstance` returns
`ReconstructionError.InstanceNotFound`. The HTTP handler maps this to HTTP 404.

Rationale: an instance with no events has never been started. There is no meaningful
initial state to return, and returning the bare `initial_state` struct would mislead
callers into thinking a live instance exists. The 404 response correctly signals that
the `{id}` does not correspond to any persisted instance.

#### 10b. Event log contains EXECUTION_ERROR

The replay loop halts immediately when it encounters an `EXECUTION_ERROR` event (§6).
The reconstructed `InstanceState.status` is set to `.ERROR` and
`InstanceState.error_detail` is populated from the event's payload. The reconstructed
state is identical to what `instance_projections` holds after EE-10 processing.

#### 10c. Reconstruction spanning both tables

When events have been archived (ES-07), older events reside in `events_archive` with
lower `sequence_number` values and newer events remain in `events`. The UNION ALL
query returns the complete ordered stream regardless of which table each event is in.
Because `transition()` is deterministic and the ordering is strictly by
`sequence_number`, the reconstructed state is identical to the state that would have
been produced if no archival had occurred. This satisfies the EE-11 acceptance
criterion: "Reconstruction that spans both tables produces identical results to
pre-archival reconstruction."

#### 10d. Corrupt or absent read model

The reconstruction function does not read from `instance_projections` during the replay
phase (only the event log tables are queried — see OQ-EE11-1 for the exception when
the definition snapshot is needed). If `instance_projections` has a corrupt row,
reconstruction still succeeds and with `write_back = true`, the corrupt row is
overwritten atomically. The event log remains the ground truth at all times.

---

### 11. Traceability table

| EE-11 Acceptance Criterion | Design element |
|---|---|
| Platform replays all N events through the pure transition function (EE-02) and produces an `InstanceState` equal to the persisted projection, field-for-field | §6 replay loop calls `transition()` for each event; §7 write-back uses the same UPDATE as normal projection writes; §4 initial state matches EE-01 instance creation |
| Reconstruction MUST complete within NFR-04 (<= 5 seconds for up to 10,000 events) | §9: single DB round-trip; O(1) per event; no writes during replay loop; benchmark in `tests/bench/reconstruction_bench.zig` |
| Reconstruction MUST be possible even if the read-model is corrupt or absent | §10d: only `events` and `events_archive` are read during replay; `instance_projections` is only written on write-back |
| After successful reconstruction, the platform MAY write the result back to the projection table | §7: optional `write_back` parameter; atomic UPDATE with `FOR UPDATE NOWAIT` |
| Reconstruction spanning both `events` and `events_archive` (ES-07) produces identical results to pre-archival reconstruction | §5a UNION ALL query; §10c determinism argument |
| Instance with 0 events: reconstructed state = initial state | §10a: returns `ReconstructionError.InstanceNotFound` -> HTTP 404 (no events = instance does not exist) |
| Event log contains an `EXECUTION_ERROR` event: reconstructed status = ERROR | §6: replay loop halts on `EXECUTION_ERROR`; status set to `.ERROR` |

---

### 12. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/engine/transition.zig` | `transition()`, `InstanceState`, `InstanceStatus`, `Token`, `TransitionEvent`, `PendingEvent` | Replay loop calls `transition()` for each event; data types for state and events |
| `src/event_store/store.zig` | `EventRecord`, `Uuid` | Row struct for decoded event records |
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Connection acquisition, UNION ALL query, write-back transaction |
| `migrations/001_event_store.sql` | `events` table | Primary event log queried in UNION ALL |
| `migrations/003_event_archive.sql` | `events_archive` table | Archive queried in UNION ALL; graceful fallback on SQLSTATE 42P01 |
| `migrations/005_instances.sql` | `instance_projections` table | Write-back UPDATE only; not read during replay |
| `std.json` | `ObjectMap`, `Value`, `parseFromSlice` | Decode event payloads; serialise InstanceState for write-back |
| `std.mem` | `Allocator` | Arena allocation for replay state |

**Must NOT be imported by:** `src/engine/transition.zig`. The reconstruction function
issues DB queries and must not be placed in or called from the pure transition function.

---

### 13. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-EE11-1 | **Definition snapshot source during replay:** `transition()` requires a `DefinitionGraph` snapshot for each call. During reconstruction, the snapshot should be the one stored in `instance_projections.definition_snapshot` at the time of the query (pinned at instance creation per PD-08). If `instance_projections` is absent, the snapshot cannot be fetched — reconstruction would fail. Confirm whether reconstruction without a valid `instance_projections` row should attempt to fetch the latest definition snapshot from `process_definitions` as a fallback. | Medium — affects recovery scope; a corrupt projection with a deleted definition version would block reconstruction | Recommended: always use the snapshot from `instance_projections.definition_snapshot`. If the row is absent, return `ReconstructionError.InstanceNotFound` (the projection table row is required to identify which definition version to replay against). Document this as a design constraint in the implementation notes. |
| OQ-EE11-2 | **`FOR UPDATE NOWAIT` vs. advisory lock for write-back:** The write-back path uses `SELECT FOR UPDATE NOWAIT` to detect lock contention. If the caller needs non-blocking reconstruction without write-back, no lock is needed. Confirm that HTTP 409 (LockContention) is the correct response for NOWAIT contention vs. retrying internally. | Low — both are correct; 409 lets the client decide retry strategy | Recommended: HTTP 409 without internal retry. The operator endpoint is low-frequency; a simple retry from the client is appropriate. |

---

### Implementation notes for BACKEND-DEV (EE-11)

1. **New source file:** `src/engine/reconstruction.zig` — contains `ReconstructionError`
   error set, `reconstructInstance()` function, `mapToTransitionEvent()` helper, and
   the write-back transaction logic.

2. **Modified source files:**
   - `src/api/routes/instances.zig` — add `POST /instances/{id}/reconstruct` handler
     (§8), calling `reconstruction.reconstructInstance()` with `write_back = true`.
   - `src/api/errors.zig` — add `INSTANCE_NOT_FOUND` (if not already present),
     `LOCK_CONTENTION`, `REPLAY_FAILED`, `POOL_EXHAUSTED` error code entries.

3. **No new migration required.** `events_archive` already exists in
   `migrations/003_event_archive.sql`.

4. **Existing functions called:**
   - `transition.transition()` — called once per event in the replay loop. Must remain
     I/O-free; do NOT add any DB calls to `transition.zig`.
   - `store.uuidToHex()` (or the equivalent in `instance.zig`) — for binding the
     `instance_id` UUID as a hex string in SQL parameters.
   - `std.json.parseFromSlice()` — for decoding `EventRecord.payload` JSONB bytes into
     the `TransitionEvent` payload structs.

5. **New error types added** (all in `src/engine/reconstruction.zig`):
   - `ReconstructionError` (complete set defined in §2)

6. **Security reminder:** `instance_id` (from URL path) is bound as `$1` in all SQL
   queries. The `event_type` string from decoded `EventRecord` rows is used only for
   a string comparison (`std.mem.eql`), never interpolated into SQL. JSONB payloads
   from the DB are parsed in-process by `std.json`; they are treated as untrusted input
   and no fields from them are interpolated into SQL strings.

7. **Integration test file:** `tests/integration/reconstruction_test.zig`. Tests MUST
   cover:
   - Instance with events only in `events` table: reconstructed state == persisted projection.
   - Instance with events split across `events` and `events_archive`: reconstructed state
     == state produced from pre-archival reconstruction.
   - Instance with EXECUTION_ERROR event: reconstructed status == ERROR.
   - Write-back with `write_back = true`: `instance_projections` row updated to match
     reconstructed state.
   - Concurrent reconstruction with write-back: `FOR UPDATE NOWAIT` contention returns
     HTTP 409.
   - Non-existent instance (0 events): HTTP 404.
   - Fallback to events-only query when `events_archive` relation is absent (SQLSTATE
     42P01 handled gracefully).

---

## Section EE-12: Concurrent Instance Safety

**Covers:** EE-12 (Concurrent instance safety — row-level locking, cross-instance
isolation, same-instance contention, load test for 100 concurrent instances)
**Files:** `src/engine/instance.zig` (modified), `src/api/routes/instances.zig` (modified)
**Depends on:**
- `migrations/005_instances.sql` — `instance_projections` table (row being locked)
- `migrations/006_tasks.sql` — `tasks` table (isolation by `instance_id` FK)
- `src/engine/instance.zig` — `completeTask()` (primary site of locking change)
- `src/engine/transition.zig` — `transition()` (I/O-free; unaffected by EE-12)
- `src/tasks/store.zig` — `TaskStore` (task lookup and mutation; unaffected by EE-12)

**Must NOT depend on:** any global mutex, application-level semaphore, or advisory lock
that spans instance boundaries. Row-level locking is the ONLY concurrency mechanism used.

---

### Module purpose

EE-12 formalises the concurrency safety model for process instance operations. The
central guarantee is **per-instance serialisation with zero cross-instance contention**:
all mutating operations on a single instance are serialised by a PostgreSQL row-level
lock on that instance's row in `instance_projections`, while operations on different
instances are fully independent and may proceed in parallel without any shared lock.

This is not a new mechanism — `completeTask()` already acquires `SELECT ... FOR UPDATE`.
EE-12 upgrades that lock from **blocking** (`FOR UPDATE`) to **non-blocking**
(`FOR UPDATE NOWAIT`) so that the second of two concurrent requests on the same instance
receives an immediate HTTP 409 rather than blocking until the first finishes.

---

### 1. Concurrency model

Each process instance is a single row in `instance_projections` identified by its
`instance_id` UUID primary key. All state-mutating operations (`completeTask`,
reconstruction write-back) acquire a PostgreSQL **row-level lock** on that specific row
before performing any writes. The lock is held for the entire duration of the database
transaction (BEGIN → COMMIT / ROLLBACK) and released automatically on commit or
rollback.

**Isolation guarantee:**
- All concurrent operations on a given instance are **totally ordered** by the sequence
  in which they acquire the row lock. Only one operation may hold the lock at a time.
- Operations on **different** instances target **different** rows. PostgreSQL row-level
  locks do not block across row boundaries, so 100 concurrent operations on 100 distinct
  instances acquire 100 independent locks with zero contention.

**No global lock.** There is no application-level mutex, advisory lock, or table-level
lock anywhere in the EE-12 implementation. The only locking primitive is PostgreSQL's
native row-level lock (`FOR UPDATE NOWAIT`).

---

### 2. Row-level locking strategy

#### 2a. Lock acquisition SQL pattern

The exact SQL statement used to acquire the row-level lock inside the `completeTask`
transaction:

```sql
SELECT id, status
FROM instance_projections
WHERE instance_id = $1::uuid
FOR UPDATE NOWAIT
```

Parameters:
- `$1` = `instance_id` as a hex UUID string (bound via pg.zig prepared statement;
  **never** concatenated into the SQL string literal).

`FOR UPDATE` takes a row-level exclusive lock on the matched tuple. `NOWAIT` instructs
PostgreSQL to raise an error immediately (SQLSTATE `55P03` — `lock_not_available`)
if the row is already locked by another transaction, rather than blocking until the
competing lock is released.

**Why `id` in the SELECT list?** Selecting any column forces PostgreSQL to locate the
tuple and acquire the lock before returning. Selecting `id` is a minimal projection with
no risk of confusion with later reads. `status` is also fetched in the same statement to
allow the EE-10 terminal-status guard (already present in `completeTask`) without a
second round-trip.

#### 2b. Integration with DB-03 (transactional writes)

DB-03 requires all state-mutating writes to occur within a single atomic database
transaction. The `FOR UPDATE NOWAIT` lock is always the **first statement** executed
after `BEGIN` in `completeTask`:

```
BEGIN
  SELECT id, status FROM instance_projections WHERE instance_id = $1 FOR UPDATE NOWAIT
  -- (lock held from here until COMMIT or ROLLBACK)
  UPDATE tasks    SET status = 'COMPLETED' …        -- §completeTask step i
  INSERT INTO events …                              -- §completeTask step j
  UPDATE instance_projections SET status, current_nodes, variables … -- step k
  INSERT INTO tasks (new HUMAN_TASK activations) …  -- step l
COMMIT
```

The lock is acquired before any write, so every write in steps i–l is protected.
No write can be observed by another transaction until the lock is released at COMMIT.

#### 2c. Functions that acquire the row-level lock

| Function | File | Lock variant | When |
|---|---|---|---|
| `completeTask()` (EE-04 task completion) | `src/engine/instance.zig` | `FOR UPDATE NOWAIT` | First statement after `BEGIN`; currently uses blocking `FOR UPDATE` — EE-12 upgrades to NOWAIT |
| `reconstructInstance()` write-back (EE-11 §7) | `src/engine/reconstruction.zig` | `FOR UPDATE NOWAIT` | Already implemented per EE-11 design; no change |

`applyTransition()` (EE-03) issues its own `BEGIN … COMMIT` but does **not** acquire an
explicit `FOR UPDATE` lock on `instance_projections`. This is safe because
`applyTransition` is called only from the EE-01 post-creation flow (one call per new
instance, no concurrency concern) and from internal engine paths where the caller is
expected to serialise access. If `applyTransition` is ever exposed to a concurrent HTTP
path, a `FOR UPDATE NOWAIT` lock must be added before its first write.

---

### 3. Same-instance concurrent task completion — HTTP 409

#### 3a. Design choice: NOWAIT

**Selected approach: `FOR UPDATE NOWAIT` (option b).**

Rationale:
1. **Immediate response.** The second concurrent request receives HTTP 409 as soon as
   PostgreSQL detects the lock contention — no waiting for the first request to commit.
   Under load, a blocking request can queue behind many others if the system is under
   sustained pressure; NOWAIT eliminates this class of latency spike.
2. **Predictable client behaviour.** The client receives a deterministic HTTP 409 with
   `CONCURRENT_MODIFICATION` code. It can retry immediately, apply backoff, or surface
   the conflict to the user. A blocked request gives the client no signal until it times
   out or the lock is finally released.
3. **Consistency with EE-11.** The write-back path in `reconstruction.zig` already uses
   `FOR UPDATE NOWAIT` (EE-11 §7). Using the same pattern in `completeTask` makes the
   locking strategy uniform across all state-mutating operations.
4. **Correct 409 semantics.** HTTP 409 Conflict is the correct status for "the request
   could not be completed due to a conflict with the current state of the resource" (RFC
   9110 §15.5.10). A concurrent lock contention is exactly such a conflict.

#### 3b. Contention flow

```
Time →   Request A                        Request B
         BEGIN
         SELECT … FOR UPDATE NOWAIT       BEGIN
         (lock acquired)                  SELECT … FOR UPDATE NOWAIT
         UPDATE tasks …                   → SQLSTATE 55P03 raised by PostgreSQL
         INSERT events …                  → Zig catch: return CompleteTaskError.ConcurrentModification
         UPDATE instance_projections …    → HTTP handler: return HTTP 409 CONCURRENT_MODIFICATION
         COMMIT                           (Request B connection released; no rollback needed —
         (lock released)                   the transaction never wrote anything)
```

Request B's error is detected at the `SELECT … FOR UPDATE NOWAIT` statement, before any
write. No partial state is written by Request B. The `conn.begin()` errdefer
(already present in `completeTask`) issues a ROLLBACK to cleanly close B's transaction.

#### 3c. New error variant

```zig
pub const CompleteTaskError = error{
    // … existing variants (TaskNotFound, TaskAlreadyTerminated, etc.) …
    /// Another transaction currently holds the row-level lock on this instance.
    /// The caller should return HTTP 409 with code CONCURRENT_MODIFICATION.
    ConcurrentModification,
};
```

#### 3d. Lock-acquisition error detection

PostgreSQL raises SQLSTATE `55P03` (`lock_not_available`) when a `FOR UPDATE NOWAIT`
lock cannot be immediately acquired. The `pg.zig` driver surfaces this as an error
return from `conn.query()`. The implementation must catch this specific error code:

```zig
const lock_rows = conn.query(
    a,
    \\SELECT id, status FROM instance_projections
    \\WHERE instance_id = $1::uuid
    \\FOR UPDATE NOWAIT
,
    &.{inst_id_hex},
) catch |err| {
    // Check if this is a lock_not_available (SQLSTATE 55P03) error.
    if (isPgError(err, "55P03")) return CompleteTaskError.ConcurrentModification;
    return CompleteTaskError.PersistenceFailed;
};
```

`isPgError(err, sqlstate)` is a helper that inspects the PostgreSQL error fields
returned by `pg.zig`. If `pg.zig` does not expose the SQLSTATE string directly,
the implementation may instead check the PostgreSQL error message string for the
`lock_not_available` keyword as a fallback.

---

### 4. Cross-instance independence

#### 4a. Why schema isolation is sufficient

The database schema provides complete data isolation between instances at the row and FK level:

| Table | Isolation mechanism |
|---|---|
| `instance_projections` | Primary key `instance_id UUID`. Each instance is exactly one row. A lock on row A is an independent PostgreSQL lock tuple from row B. |
| `events` | `instance_id UUID NOT NULL` with index `idx_events_instance`. All events for one instance are in separate rows from events for another. |
| `events_archive` | Same as `events`. |
| `tokens` | `instance_id UUID NOT NULL REFERENCES instance_projections(instance_id) ON DELETE CASCADE`. Token rows are per-instance; no token belongs to two instances. |
| `tasks` | `instance_id UUID NOT NULL REFERENCES instance_projections(instance_id) ON DELETE CASCADE`. Task rows are per-instance. |
| `instance_sequence` | `PRIMARY KEY (instance_id)`. Sequence counter is per-instance; incrementing one does not affect another. |

No column in any table creates a cross-instance dependency that would require a shared
lock. The `definition_id` FK in `instance_projections` is a **read** dependency on
`process_definitions`, not a write dependency — it is set once at creation and never
updated.

#### 4b. Lock independence proof

Given instances A and B (distinct UUIDs):
- Request on instance A executes `SELECT … FROM instance_projections WHERE instance_id = $A FOR UPDATE NOWAIT`. PostgreSQL acquires a lock on the tuple for `instance_id = A`.
- Request on instance B executes the same statement with `$B`. PostgreSQL acquires a lock on the tuple for `instance_id = B`.
- These are **two different tuples**. PostgreSQL row-level locks are per-tuple. Neither request blocks on the other. Both proceed in full parallelism.

No table-level lock is taken anywhere in `completeTask` or `reconstructInstance`. The only
broader lock implied is the implicit `AccessShareLock` on the `instance_projections`
table itself, which is shared (read-compatible) and does not block other concurrent DML.

---

### 5. Load test design — 100 concurrent distinct instances

**File:** `tests/integration/concurrent_instances_test.zig`
**Test function:** `test "EE-12: 100 concurrent task completions on distinct instances succeed"`

#### 5a. Setup phase (sequential)

1. Start from a clean test database (fixtures applied by the integration harness).
2. Create one process definition with a single `USER_TASK` node after the start event.
3. For each `i` in `[0, 99]`:
   a. Call `POST /api/v1/instances` to create instance `i` with `initial_variables = {}`.
   b. Retrieve the `instance_id` from the 201 response.
   c. Trigger `applyTransition` (or advance via the start event) to place the token on
      the `USER_TASK` node.
   d. Query `tasks` WHERE `instance_id = $i AND status = 'PENDING'`; record `task_id[i]`.

Result: 100 instances each with exactly one PENDING task. All `task_id[i]` are distinct.

#### 5b. Concurrent execution phase

Launch 100 HTTP client goroutines simultaneously. Each goroutine `i` sends:
```
POST /api/v1/tasks/{task_id[i]}/complete
Content-Type: application/json
Body: {"output_variables": {}}
```

Synchronisation: all 100 goroutines are created and paused at a barrier before any
request is dispatched. The barrier is released atomically so all 100 requests are
in-flight concurrently (OS scheduling may still stagger actual connection establishment
by a few microseconds, which is acceptable).

#### 5c. Assertions

After all 100 goroutines complete:

| Assertion | Expected value |
|---|---|
| Count of HTTP 200 responses | 100 |
| Count of HTTP 4xx/5xx responses | 0 |
| No deadlock detected (PostgreSQL log) | 0 deadlock events |
| `SELECT COUNT(*) FROM tasks WHERE status='COMPLETED'` | 100 |
| `SELECT COUNT(*) FROM instance_projections WHERE status='COMPLETED'` | 100 (assuming the definition has no further nodes after the task) |
| For each instance: query `current_nodes` from `instance_projections` | Expected token position (END node or empty if process completed) |

**Deadlock detection:** The test reads the PostgreSQL `pg_stat_activity` and
`pg_locks` views at assertion time to verify no lock wait chains remain. If the
platform uses a test PG instance, the log level can be set to `LOG` with `deadlock_timeout = 1ms`
to surface any deadlock attempt in the server log; the test asserts the log is clean.

---

### 6. Load test design — same-instance concurrent task completion

**File:** `tests/integration/concurrent_instances_test.zig`
**Test function:** `test "EE-12: concurrent completions on same instance: one 200, one 409"`

#### 6a. Setup phase

1. Create one process instance; advance to a `USER_TASK` node.
2. Record `task_id` for the single PENDING task.

#### 6b. Concurrent execution phase

Launch exactly 2 HTTP client goroutines simultaneously:
- Goroutine 1: `POST /api/v1/tasks/{task_id}/complete` with `output_variables = {}`
- Goroutine 2: `POST /api/v1/tasks/{task_id}/complete` with `output_variables = {}`

**Reliability mechanism:** Both goroutines connect to the server and send their request
bytes before either's response can be processed. Use a pre-connected HTTP/1.1 persistent
connection (keep-alive) for each goroutine so connection setup does not add latency that
could prevent true concurrency. Both requests are written to their respective sockets
before reading either response. The OS kernel queues both at the server socket; the
server processes them on separate worker threads.

This is inherently probabilistic when running sequentially. For deterministic test
results in CI, use the integration test harness to pause execution of the server worker
after it calls `conn.begin()` but before `conn.query(… FOR UPDATE NOWAIT …)`. Insert a
synchronisation point (test-only hook or a mock that holds the lock for a configurable
duration) so the second goroutine definitely reaches the `FOR UPDATE NOWAIT` while the
first holds the lock. This avoids a race in the test itself.

#### 6c. Assertions

| Assertion | Expected value |
|---|---|
| Count of HTTP 200 responses | 1 |
| Count of HTTP 409 responses with `"code": "CONCURRENT_MODIFICATION"` | 1 |
| `SELECT COUNT(*) FROM tasks WHERE id = $task_id AND status = 'COMPLETED'` | 1 |
| `SELECT COUNT(*) FROM tasks WHERE id = $task_id AND status = 'PENDING'` | 0 |

Order of 200 vs 409 between the two goroutines is non-deterministic and MUST NOT be
asserted; only the counts matter.

---

### 7. Error handling

| Failure mode | HTTP status | Response body `code` | Trigger |
|---|---|---|---|
| `instance_id` not found in `instance_projections` | 404 | `INSTANCE_NOT_FOUND` | `SELECT … FOR UPDATE NOWAIT` returns 0 rows |
| Instance status = `ERROR` | 409 | `INSTANCE_IN_ERROR` | Status check after lock acquired |
| Instance status = `COMPLETED` or `CANCELLED` | 409 | `INSTANCE_ALREADY_TERMINATED` | Status check after lock acquired |
| Task not found (task_id unknown) | 404 | `TASK_NOT_FOUND` | `TaskStore.getById()` pre-lock |
| Task already `COMPLETED` or `CANCELLED` | 409 | `TASK_ALREADY_TERMINATED` | Status check of task row pre-lock |
| Row-level lock not available (NOWAIT conflict) | 409 | `CONCURRENT_MODIFICATION` | SQLSTATE `55P03` from `FOR UPDATE NOWAIT` |
| Pool exhausted | 503 | `SERVICE_UNAVAILABLE` | `pool.acquire()` returns `ExhaustedPool` |
| DB transaction error (transient) | 500 | `INTERNAL_ERROR` | Any other DB error in BEGIN…COMMIT |

The `CONCURRENT_MODIFICATION` 409 is distinct from `TASK_ALREADY_TERMINATED`: the former
means "another request is modifying this instance right now"; the latter means "the task
was already completed by a prior request." Clients MUST inspect the `code` field to
distinguish them.

---

### 8. Migration assessment

**No migration is required for EE-12.**

The `instance_projections` table already has the correct structure for row-level locking:

```sql
-- From migrations/005_instances.sql (via migrations/001_event_store.sql)
-- Already present:
instance_projections (
    instance_id  UUID  PRIMARY KEY  -- row identifier; PostgreSQL lock target
    ...
)
```

PostgreSQL's `SELECT … FOR UPDATE` / `FOR UPDATE NOWAIT` locks a row identified by its
primary key tuple. No additional column, index, or constraint is needed. The lock
mechanism is built into PostgreSQL's MVCC engine and operates on any table with a tuple
identifier — which all tables possess by definition.

The `tasks` table (migrations/006_tasks.sql) and `tokens` table (migrations/005_instances.sql)
are isolated by the `instance_id` FK: all task and token rows for a given instance are
already co-located by `instance_id`, so the single row-level lock on `instance_projections`
protects the complete instance state.

---

### 9. Edge cases

#### 9a. 100 concurrent completions on the same instance

If 100 concurrent requests all try to complete the same task on the same instance:
- **One** request acquires the lock, completes the task, and commits. HTTP 200.
- **The other 99** requests hit `FOR UPDATE NOWAIT` while the first holds the lock.
  Each returns SQLSTATE `55P03` → `CompleteTaskError.ConcurrentModification` → HTTP 409
  `CONCURRENT_MODIFICATION`.
- After the first commits, the task is `COMPLETED`. Any subsequent (non-concurrent)
  retry of any of the 99 failed requests would hit the pre-lock task status check
  (`TaskAlreadyTerminated`) and return HTTP 409 `TASK_ALREADY_TERMINATED`.

No state corruption occurs. All 99 losing requests return an error before performing
any write.

#### 9b. Deadlock impossibility

A deadlock between two transactions T1 and T2 requires T1 to hold a lock that T2 wants,
AND T2 to hold a lock that T1 wants — a circular wait.

In the EE-12 model, each `completeTask` transaction locks **exactly one** row (the
instance's row in `instance_projections`) and no other row-level lock is taken in the
transaction. Therefore:
- T1 can be waiting for a row that T2 holds only if T2 has locked that **same** row.
- But T2 cannot hold another row that T1 wants, because T1 has already acquired its
  single lock (or returned `ConcurrentModification` if it could not).
- **One-lock-per-transaction eliminates circular waits.**

Moreover, `FOR UPDATE NOWAIT` means T1 never waits — it either gets the lock instantly
or returns an error. A waiting transaction is a prerequisite for deadlock participation;
with NOWAIT, no transaction waits, so deadlock is structurally impossible in the
`completeTask` path.

PostgreSQL's deadlock detector would still fire if other code paths (e.g. a future
migration script running concurrent updates) introduce multi-row lock sequences, but
that is outside the EE-12 scope.

#### 9c. Instance in COMPLETED or ERROR status

The `FOR UPDATE NOWAIT` lock is acquired before the status is re-checked inside the
transaction. After acquiring the lock:
- If `status = ERROR` → return `CompleteTaskError.InstanceInError` (HTTP 409
  `INSTANCE_IN_ERROR`). The ROLLBACK (via errdefer) releases the lock immediately.
- If `status = COMPLETED` or `CANCELLED` → return `CompleteTaskError.TaskAlreadyTerminated`
  (HTTP 409 `INSTANCE_ALREADY_TERMINATED`). Lock released immediately.

In both cases, no write occurs. The lock is held only for the duration of the status
read (one query) before the ROLLBACK.

---

### 10. Traceability table

| EE-12 Acceptance Criterion | Design element |
|---|---|
| 100 instances of the same definition run simultaneously without corrupting each other's state (variables, task set, event log, token positions) | §4: cross-instance independence — each instance is a separate row/FK chain; row-level locks are per-row, independent across instances |
| Row-level locking serialises concurrent operations on the same instance; cross-instance contention = zero | §2: `SELECT … FOR UPDATE NOWAIT` on `instance_projections.instance_id`; §4b: lock independence proof |
| Two concurrent task completions on same instance: one succeeds (HTTP 200), other gets HTTP 409 | §3: NOWAIT approach; new `ConcurrentModification` error → HTTP 409 `CONCURRENT_MODIFICATION`; §6: load test design |
| Load test: 100 concurrent task completions across 100 distinct instances all succeed | §5: load test design — 100 goroutines, barrier launch, 100 HTTP 200 assertion |

---

### 11. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `migrations/005_instances.sql` | `instance_projections` | Table whose row is locked |
| `migrations/006_tasks.sql` | `tasks` | Task status check and update (inside lock) |
| `src/engine/instance.zig` | `completeTask()`, `CompleteTaskError` | Primary site of NOWAIT lock acquisition |
| `src/engine/reconstruction.zig` | `reconstructInstance()` write-back | Already uses NOWAIT; no change (EE-11) |
| `src/tasks/store.zig` | `TaskStore.getById()`, `completeInTx()` | Task fetch pre-lock; task update inside lock |
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Connection acquisition and query execution |

**Must NOT be imported by:** `src/engine/transition.zig`. EE-12 is entirely a
persistence-layer concern; the pure transition function is not involved.

---

### 12. Implementation notes for BACKEND-DEV (EE-12)

1. **Modified source file: `src/engine/instance.zig`**
   - In `completeTask()`, change the existing lock query from:
     ```sql
     SELECT status FROM instance_projections WHERE instance_id = $1::uuid FOR UPDATE
     ```
     to:
     ```sql
     SELECT id, status FROM instance_projections WHERE instance_id = $1::uuid FOR UPDATE NOWAIT
     ```
   - Catch the SQLSTATE `55P03` error from `conn.query()` and return
     `CompleteTaskError.ConcurrentModification`.
   - Add `ConcurrentModification` to the `CompleteTaskError` error set (§3c).

2. **Modified source file: `src/api/routes/instances.zig`** (or the task completion
   handler file)
   - Add mapping: `CompleteTaskError.ConcurrentModification → HTTP 409` with
     response body `{"error": "CONCURRENT_MODIFICATION"}`.

3. **No new migration is required** (§8). The `instance_projections` table already has
   the correct schema.

4. **No change to `src/engine/transition.zig`.** The pure transition function is
   I/O-free and must remain so.

5. **No change to `src/tasks/store.zig`.** Task creation (`createInTx`) and status
   update (`completeInTx`) execute inside the `completeTask` transaction and are already
   protected by the instance-level lock.

6. **New integration test file: `tests/integration/concurrent_instances_test.zig`**
   Two test functions (§5, §6):
   - `test "EE-12: 100 concurrent task completions on distinct instances succeed"` —
     setup 100 instances, barrier-launch 100 HTTP requests, assert 100 HTTP 200.
   - `test "EE-12: concurrent completions on same instance: one 200, one 409"` —
     setup 1 instance, launch 2 concurrent requests, assert exactly one 200 and one 409
     with `CONCURRENT_MODIFICATION` code.

7. **Security reminder:** `instance_id` is bound as `$1` in the `FOR UPDATE NOWAIT`
   query. The SQLSTATE string (`55P03`) used for error detection is a constant
   defined in the PostgreSQL specification — it is never derived from user input and
   never concatenated into a SQL string.
