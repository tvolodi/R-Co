# Module: exp-03-async-effects

**Covers:** EXP-301 (effects subsystem + worker + result re-entry), EXP-302 (service task migration), EXP-303 (sandbox stub executor)
**Epic:** EPIC-3 — Async outbound effects (Wave 1)
**Related:** EXP-501 (secrets by reference), EXP-401 (compensation via effects), ISS-205/EXT-02 (webhook outbox pattern reused), OBS-05 (DLQ)
**Primary design targets:**
- `src/effects/mod.zig` — public types and executor interface
- `src/effects/queue.zig` — transactional outbox insert/sweep
- `src/effects/worker.zig` — background polling loop
- `src/effects/adapters/http.zig` — HTTP connector adapter
- `src/effects/adapters/email.zig` — email channel adapter (placeholder)
- `src/effects/stub.zig` — sandbox stub executor
- `src/engine/service_task.zig` — migration from inline I/O to emit
- `src/engine/transition.zig` — new `effect_emitted` variant in `PendingEvent`
- `migrations/094_exp301_effects_outbox.sql`
- `migrations/095_exp301_effects_results.sql`
- `migrations/096_exp302_service_task_effect_ref.sql`

---

## Module purpose

The async effects subsystem decouples all outbound I/O from the execution engine step. Currently, `src/engine/service_task.zig` performs network calls inline during task completion, binding external latency to the holding transaction. This violates the core architectural commitment that the transition function has zero I/O and that no engine-path module performs network calls.

The effects subsystem moves every outbound action into a transactional outbox. The execution engine emits an `EFFECT_EMITTED` event (pure data) during a task-completion transaction; a background worker then delivers it, retrying with backoff; the result re-enters the engine as an `EFFECT_COMPLETED` or `EFFECT_FAILED` event, which drives a catch event node in the process graph. At no point does the engine thread perform network I/O.

EXP-302 migrates `service_task.zig` to use this subsystem. EXP-303 provides a stub executor for sandbox/simulation contexts that records calls without performing them.

**Inviolable invariants preserved:**
1. `src/engine/transition.zig` has zero I/O — no network, no clock, no DB.
2. The audit log stays in-transaction with every state change.
3. The event log is the system of record; effect delivery rows are projections rebuildable from events.

---

## Public interface

### Effect kinds

```
pub const EffectKind = enum {
    http_call,    // HTTP/HTTPS outbound call
    email,        // SMTP / mail service call (placeholder; secrets by reference via EXP-501)
};
```

### Effect specification (embedded in EFFECT_EMITTED event payload)

```
pub const EffectSpec = struct {
    // Stable identity — used as the idempotency key sent to the remote.
    // Set to the UUID of the EFFECT_EMITTED event by the event-store writer.
    // Format: effect-event-id as hyphenated UUID string.
    effect_event_id: []const u8,          // UUID, assigned at commit time

    // Back-reference to the instance/node that produced this effect.
    instance_id:     []const u8,          // UUID string
    node_id:         []const u8,          // graph node id
    token_id:        []const u8,          // token that activated this node

    // Correlation back to the catch-event node waiting for this result.
    // Stored in the wait descriptor (instance_waits) at emit time.
    correlation_key: []const u8,          // e.g. "<instance_id>:<node_id>:<token_id>"

    kind: EffectKind,

    // Kind-specific payload — stored as JSONB blob in effects_outbox.spec_json.
    spec_json: []const u8,
};

pub const HttpEffectSpec = struct {
    url:              []const u8,         // fully rendered at emit time
    method:           []const u8,         // "POST" | "GET" | "PUT" | "PATCH" | "DELETE"
    headers_json:     ?[]const u8,        // JSON object; Idempotency-Key header injected by worker
    body_json:        ?[]const u8,        // fully rendered body
    timeout_ms:       u32,                // default 30_000
    retry_limit:      u8,                 // default 5
    secret_ref:       ?[]const u8,        // secret reference resolved via EXP-501 at delivery time
};

pub const EmailEffectSpec = struct {
    to:         []const u8,
    subject:    []const u8,
    body:       []const u8,
    secret_ref: ?[]const u8,              // SMTP credentials reference
};
```

### Executor interface

```
pub const EffectExecutorVTable = struct {
    /// Attempt one delivery. Returns the HTTP status code (for HTTP kind) or
    /// a synthetic status code (200 = success, 0 = undeliverable) for other kinds.
    /// Must be non-blocking with respect to the effects worker main loop.
    execute: *const fn (
        allocator:   std.mem.Allocator,
        spec:        EffectSpec,
        attempt:     u8,
    ) EffectDeliveryError!EffectDeliveryResult,
};

pub const EffectDeliveryResult = struct {
    status_code:   u16,
    response_body: ?[]u8,   // caller owns memory
    idempotency_key_sent: []const u8,
};

pub const EffectDeliveryError = error{
    TransportError,
    Timeout,
    SecretResolutionFailed,
    OutOfMemory,
    InvalidSpec,
};
```

### Queue functions (called from event-store writer, inside the transaction)

```
// Insert one effects_outbox row per EFFECT_EMITTED event.
// Must be called inside an already-open transaction.
// Returns the assigned effect_delivery_id.
pub fn insertEffectInTx(
    allocator: std.mem.Allocator,
    conn:      anytype,  // open *db.Conn
    spec:      EffectSpec,
) EffectQueueError![]const u8;  // effect_delivery_id UUID

pub const EffectQueueError = error{
    PersistenceFailed,
    OutOfMemory,
};
```

### Result re-entry (called from effects worker after delivery)

```
// Appends EFFECT_COMPLETED or EFFECT_FAILED to the event log and drives
// the catch-event transition, all in one atomic transaction.
// This is the only path that may create new engine events after initial emit.
pub fn reenterEffectResult(
    allocator:      std.mem.Allocator,
    pool:           *db.Pool,
    correlation_key: []const u8,
    succeeded:      bool,
    response_body:  ?[]const u8,
    http_status:    u16,
) EffectReentryError!void;

pub const EffectReentryError = error{
    InstanceNotFound,
    CorrelationKeyNotFound,
    TransitionFailed,
    PersistenceFailed,
    OutOfMemory,
};
```

### Transition engine additions

New variants are added to `PendingEvent` in `transition.zig`:

```
// New variant emitted when the engine activates a SERVICE_TASK node (after migration)
// or any EFFECT node in the graph.
pub const EffectEmittedPayload = struct {
    node_id:         []const u8,
    token_id:        []const u8,
    correlation_key: []const u8,
    kind:            []const u8,    // "http_call" | "email"
    spec_json:       []const u8,    // serialised HttpEffectSpec or EmailEffectSpec
};

// Added to PendingEvent union:
//   effect_emitted: EffectEmittedPayload,
```

New variant added to `TransitionEvent` (the input side):

```
// Drives a catch-event node when an effect result re-enters.
//   effect_completed: struct { correlation_key, response_body_json }
//   effect_failed:    struct { correlation_key, error_detail }
```

### Stub executor (EXP-303)

```
pub const StubEffectsExecutor = struct {
    // Per-kind counter: incremented on every execute() call.
    http_call_count: u32,
    email_count:     u32,

    // Per-correlation_key recorded calls (for test assertions).
    // Key: correlation_key. Value: most recent EffectSpec serialised as JSON.
    recorded: std.StringHashMap([]const u8),

    // Injected stub response (status_code + body). Defaults to 200 / "{}".
    stub_response: EffectDeliveryResult,

    pub fn execute(
        allocator: std.mem.Allocator,
        spec:      EffectSpec,
        attempt:   u8,
    ) EffectDeliveryError!EffectDeliveryResult;

    pub fn reset(self: *StubEffectsExecutor) void;
};
```

---

## Data flow diagram

### EXP-301 — request path (task completion → outbox emit)

```
  POST /tasks/:id/complete
        │
        ▼
  Auth / RBAC middleware
        │
        ▼
  Execution Engine (pure)
  │  load InstanceState
  │  evaluate outgoing conditions
  │  compute NewInstanceState
  │  if next node is SERVICE_TASK (migrated) or EFFECT node →
  │      emit PendingEvent.effect_emitted { correlation_key, spec_json }
        │
        ▼
  Event Store — ATOMIC TRANSACTION
  │  INSERT TASK_COMPLETED event
  │  INSERT EFFECT_EMITTED event (event_id becomes idempotency key)
  │  INSERT effects_outbox row via insertEffectInTx()
  │      (status=pending, next_attempt_at=NOW()+5s, max_attempts=5)
  │  INSERT instance_waits descriptor (kind=catch_event, correlation_key)
  │  UPDATE projection tables, task rows, token model
        │
        ▼
  Client ← 200 { instance state — token now at catch-event node }
```

### EXP-301 — worker path (poll + successful delivery)

```
  Background: Effects Worker (polling loop, every ~5 s)
        │
        ▼
  SELECT effects_outbox WHERE status='pending'
    AND next_attempt_at <= now()
    FOR UPDATE SKIP LOCKED
        │
        ▼
  For each due row:
    EffectExecutorVTable.execute(spec, attempt)
        │
        └── success (2xx) ──────────────────────────────────────────┐
                                                                      ▼
                                                         reenterEffectResult(
                                                           correlation_key, succeeded=true)
                                                               │
                                               ATOMIC TRANSACTION
                                               │  INSERT EFFECT_COMPLETED event
                                               │  drive transition() with effect_completed input
                                               │  INSERT next TASK_ACTIVATED / INSTANCE_COMPLETED
                                               │  UPDATE projection, instance_waits (delete row)
                                               │  mark effects_outbox row delivered
```

### EXP-301 — worker path (retry and DLQ)

```
  For each due row (failure branches):
        │
        ├── retriable failure (network, timeout, 429, 5xx) ─────────┐
        │                                                             ▼
        │                                                  UPDATE effects_outbox
        │                                                    attempt_count += 1
        │                                                    next_attempt_at = NOW() + backoff
        │
        └── terminal failure (max_attempts exhausted) ──────────────┐
                                                                      ▼
                                                           reenterEffectResult(
                                                             correlation_key, succeeded=false)
                                                               │
                                                   ATOMIC TRANSACTION
                                                   │  INSERT EFFECT_FAILED event
                                                   │  drive transition() with effect_failed input
                                                   │  INSERT next TASK_ACTIVATED (error branch) / DLQ
                                                   │  UPDATE projection, instance_waits (delete row)
                                                   │  mark effects_outbox row dead_lettered
                                                   │  INSERT dlq_items row
```

### EXP-302 — service task migration path

```
  Current (before migration):
    transition() → SERVICE_TASK activated
    event-store writer calls service_task.executeHttp() inline  ← I/O IN ENGINE PATH

  After migration:
    transition() → SERVICE_TASK activated
    emits PendingEvent.effect_emitted { ... http_call spec ... }
    event-store writer inserts EFFECT_EMITTED + effects_outbox row
    HTTP call happens in effects worker (out of engine path)
    result re-enters via reenterEffectResult()
```

---

## Database schema (migration targets)

### Migration 094 — effects outbox

```sql
-- effects_outbox: transactional outbox for effect delivery
-- One row per EFFECT_EMITTED event. Rebuildable from events.
CREATE TABLE effects_outbox (
    effect_delivery_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    effect_event_id      UUID NOT NULL,          -- FK to events.event_id
    instance_id          UUID NOT NULL,
    node_id              TEXT NOT NULL,
    correlation_key      TEXT NOT NULL,
    kind                 TEXT NOT NULL CHECK (kind IN ('http_call','email')),
    spec_json            JSONB NOT NULL,
    status               TEXT NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','delivered','dead_lettered')),
    attempt_count        SMALLINT NOT NULL DEFAULT 0,
    max_attempts         SMALLINT NOT NULL DEFAULT 5,
    next_attempt_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '5 seconds',
    last_http_status     SMALLINT,
    last_error           TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_effects_outbox_due
    ON effects_outbox (next_attempt_at)
    WHERE status = 'pending';
CREATE INDEX idx_effects_outbox_instance
    ON effects_outbox (instance_id);
```

### Migration 095 — effect event types in the registry

Registers `EFFECT_EMITTED`, `EFFECT_COMPLETED`, `EFFECT_FAILED` in
`event_type_registry` with JSON schema.

### Migration 096 — service task effect reference column

```sql
-- Adds an optional column linking a legacy service task attempt row
-- to the effects_outbox row that replaced inline execution.
-- NULL for tasks processed before migration; non-null after.
ALTER TABLE tasks
    ADD COLUMN effect_delivery_id UUID REFERENCES effects_outbox(effect_delivery_id);
```

---

## Idempotency strategy

The idempotency key sent to the remote system in the `Idempotency-Key` HTTP header is derived from `effect_event_id` — the UUID of the `EFFECT_EMITTED` event that was committed to the event log. This key is stable across retries because it is written to `effects_outbox.spec_json` at insert time (inside the transaction that created the event). The worker reads it from the row; it never recomputes it.

**Why this is safe:** The `EFFECT_EMITTED` event is inserted with the standard `events` idempotency key (`engine:<hash>` format from ISS-203). If the transaction is retried by the caller, the second attempt hits the unique constraint on `events.idempotency_key` and aborts — so the outbox row is also absent. There is never a duplicate outbox row for the same logical emit.

---

## Backoff schedule

Reuses the existing webhook dispatcher constants (ISS-205):

| Attempt | Delay before next attempt |
|---------|--------------------------|
| 1       | 5 s                      |
| 2       | 30 s                     |
| 3       | 2 min                    |
| 4       | 10 min                   |
| 5 (max) | 30 min → dead-lettered   |

The constants are defined in `src/effects/worker.zig` mirroring `dispatcher.zig`:
`EFFECT_BACKOFF_MS = [_]u32{ 5_000, 30_000, 120_000, 600_000, 1_800_000 }`.

---

## Error taxonomy

```
pub const EffectQueueError = error{
    PersistenceFailed,
    OutOfMemory,
};

pub const EffectDeliveryError = error{
    TransportError,         // TCP/TLS failure
    Timeout,                // per-call deadline exceeded
    SecretResolutionFailed, // EXP-501 secret ref not found or decryption failed
    OutOfMemory,
    InvalidSpec,            // spec_json failed to deserialise (DLQ immediately)
};

pub const EffectReentryError = error{
    InstanceNotFound,           // instance was deleted before re-entry
    CorrelationKeyNotFound,     // catch-event node not waiting (idempotent skip)
    TransitionFailed,           // engine transition returned an error state
    PersistenceFailed,
    OutOfMemory,
};
```

**Error handling rules:**

- `EffectDeliveryError.InvalidSpec` → immediate DLQ without consuming a retry slot.
- `EffectDeliveryError.TransportError | Timeout` → retry.
- HTTP 429 → retry (respects the backoff schedule; no special honour of Retry-After for now).
- HTTP 3xx → no auto-follow; classified as permanent failure; DLQ.
- HTTP 5xx → retry.
- HTTP 4xx (except 429) → permanent failure; DLQ.
- `EffectReentryError.CorrelationKeyNotFound` → log and discard (idempotent; catch-event already fired).

---

## State transitions for a SERVICE_TASK node (after EXP-302 migration)

```
  NODE STATES (from the engine perspective):

  TASK_ACTIVATED (service task)
       │
       │  transition() evaluates → emits effect_emitted
       ▼
  TOKEN PARKED at catch-event node
  EFFECT_EMITTED event appended
  effects_outbox row: pending
       │
       │  effects worker delivers successfully
       ▼
  EFFECT_COMPLETED event appended
  transition() with effect_completed input
  TOKEN advances past catch-event
       │
       ▼  (happy path)
  Next node activated / INSTANCE_COMPLETED

       │  (failure after max_attempts)
       ▼
  EFFECT_FAILED event appended
  transition() with effect_failed input
  TOKEN follows error-boundary edge (if defined) or → EXECUTION_ERROR
```

---

## EXP-302 — Decision gate: synchronous service task exceptions

The requirement states that the owner must decide whether any **low-risk synchronous** service tasks remain after migration. This design defines the two paths:

**Path A — Full async (default):** All SERVICE_TASK nodes use the async effects path. The token parks at a catch-event node. The process graph must define at least one outgoing edge from that catch-event node.

**Path B — Sync exception (explicit opt-in):** A SERVICE_TASK node marked `sync_inline: true` in its node attributes retains inline execution via the existing `service_task.zig` executor. This is a deliberate escape hatch for tasks where round-trip latency would exceed acceptable process SLA (e.g. a fast intra-datacenter call). The opt-in must be documented in the process definition and requires a validator warning.

**Default for EXP-302 WF-02 implementation:** All non-marked SERVICE_TASK nodes are migrated to Path A. Path B support is a stub validator warning only; no runtime changes required for Path B at this stage.

**Invariant:** Whether Path A or Path B, `transition.zig` emits no I/O. Path B moves the inline call to the event-store writer layer (outside transition), not into the transition function itself.

---

## EXP-303 — Stub executor behavior

The `StubEffectsExecutor` is the executor used when `instance.is_sandbox = true` or when the effects worker is started with `executor = .stub`. Its contract:

- `execute()` returns `stub_response` (default: HTTP 200, body `{}`).
- Increments `http_call_count` or `email_count` per call.
- Records the full `EffectSpec` serialised as JSON under `correlation_key` in `recorded`.
- Performs no network I/O, no file I/O, no clock reads.
- `reset()` zeroes all counters and clears `recorded`.

The stub is **not** registered in the `effects_outbox` worker loop. In sandbox mode, the event-store writer still inserts the `EFFECT_EMITTED` event and the outbox row (maintaining audit correctness), but the worker calls the stub executor instead of the HTTP adapter.

Test assertions access `stub.http_call_count` and `stub.recorded.get(correlation_key)` directly.

---

## Dependencies

| This module calls | For |
|---|---|
| `src/db/pool.zig` | Connection pool for outbox insert and sweep |
| `src/engine/transition.zig` | Re-entry calls `transition()` with `effect_completed`/`effect_failed` inputs |
| `src/event_store/writer.zig` | Appends `EFFECT_EMITTED`, `EFFECT_COMPLETED`, `EFFECT_FAILED` events |
| `src/tasks/store.zig` | Updates task row `effect_delivery_id` column (EXP-302) |
| `src/dlq/store.zig` | Inserts DLQ item on terminal failure |
| `src/obs/alerts.zig` | Emits alert on DLQ admission |
| `src/scheduler/` | NOT called — effects worker is an independent background loop |
| `src/webhook/dispatcher.zig` | NOT called — effects outbox is separate from webhook outbox |

**Must NOT depend on:**
- Any HTTP client library inside `transition.zig`
- Any database call inside `transition.zig`
- `src/effects/*` from within `transition.zig` (the transition function is pure)

---

## Test strategy

### Unit tests (no database, no network)

Located at `tests/unit/effects/`:

1. **Backoff schedule** — `computeEffectBackoffMs` across all attempt indices; assert matches defined table; cap enforced.
2. **Idempotency key derivation** — given an `effect_event_id` UUID, verify the key sent in the `Idempotency-Key` header matches exactly.
3. **Stub executor** — `StubEffectsExecutor.execute()` increments counters, records spec, returns stub response; `reset()` clears state.
4. **EffectSpec serialisation** — round-trip: `HttpEffectSpec` → JSON → deserialise; assert all fields preserved.
5. **Failure classification** — `classifyHttpOutcome(status_code)` returns correct `retry | permanent | success` for 200, 400, 429, 500, 301.

### Integration tests (real PostgreSQL via `BPM_TEST_DB_URL`)

Located at `tests/integration/effects/`:

1. **Happy path** — insert EFFECT_EMITTED event + outbox row in a test transaction; call worker sweep once with stub executor returning 200; assert outbox row marked `delivered`, `EFFECT_COMPLETED` event appended, catch-event token advanced.
2. **Retry backoff** — stub returns 503 twice, then 200; assert `attempt_count` increments, `next_attempt_at` advances per schedule, final delivery marks `delivered`.
3. **DLQ admission** — stub returns 503 for all 5 attempts; assert row marked `dead_lettered`, `EFFECT_FAILED` event appended, `dlq_items` row created.
4. **Idempotent re-entry** — call `reenterEffectResult()` twice with same correlation_key; second call hits `CorrelationKeyNotFound`; assert only one `EFFECT_COMPLETED` event exists.
5. **In-transaction atomicity** — simulate crash between outbox insert and event insert (by aborting the transaction mid-write); assert no orphan outbox rows; verify outbox + event counts remain consistent.
6. **Sandbox stub isolation** — start a sandbox instance; complete a service task node; assert `EFFECT_EMITTED` event written, stub executor called (counter = 1), no network calls, `EFFECT_COMPLETED` auto-driven.

### E2E test (Playwright, against running backend)

Located at `web/tests/e2e/pipelines/effects.pipeline.e2e.spec.ts`:

1. Create a process definition with a SERVICE_TASK node → catch-event → two branches (success/failure).
2. Start an instance, complete the user task that precedes the service task.
3. Assert the instance token is parked at the catch-event node.
4. (Stub executor is active in test tenant) Trigger worker sweep via `POST /api/v1/admin/effects/sweep` (test-only endpoint).
5. Assert instance advances to success branch; assert audit log contains `EFFECT_EMITTED` and `EFFECT_COMPLETED`.

---

## Incremental rollout plan

**Phase 1 — Subsystem scaffolding (EXP-301 core)**
- Migrations 094, 095 applied (effects_outbox table, event types).
- `src/effects/mod.zig`, `src/effects/queue.zig` added.
- `src/effects/worker.zig` added with HTTP adapter; stub adapter also added.
- `src/engine/transition.zig` gains `effect_emitted` variant in `PendingEvent` and `effect_completed`/`effect_failed` in `TransitionEvent`.
- `src/event_store/writer.zig` gains logic to call `insertEffectInTx` when `effect_emitted` events are in the result.
- Existing SERVICE_TASK nodes **not yet migrated** — inline path still active.
- Effects worker started as a second background thread alongside the scheduler.
- All unit and integration tests pass.
- `zig build`, `zig build test`, `zig build migrate` all exit 0.

**Phase 2 — Service task migration (EXP-302)**
- Migration 096 applied (tasks.effect_delivery_id column).
- `src/engine/service_task.zig` emits `effect_emitted` payload instead of returning `HttpExecutionResult`.
- Process graph validator updated: SERVICE_TASK nodes without `sync_inline: true` must have at least one outgoing edge from a catch-event node.
- Validator emits a WARNING (not error) for SERVICE_TASK nodes with `sync_inline: true`.
- All integration tests for the service task module updated.
- All existing service task unit tests updated (mock executor → stub executor assertions).
- `zig build`, `zig build test`, `zig build migrate` exit 0.

**Phase 3 — Sandbox stub (EXP-303)**
- `src/effects/stub.zig` (`StubEffectsExecutor`) is the registered executor for sandbox instances.
- Effects worker checks `instance.is_sandbox` before dispatching; routes to stub if true.
- `notifications_sent` simulation metric is wired to `stub.http_call_count + stub.email_count`.
- Unit and integration tests for stub confirmed passing.
- `zig build`, `zig build test` exit 0.

**Audit invariant across all phases:**
- Every EFFECT_EMITTED, EFFECT_COMPLETED, EFFECT_FAILED event is written inside the same transaction that modifies instance state. No state change is visible without a corresponding event. The event log remains the sole system of record.

---

## Open questions

1. **EXP-501 dependency:** `HttpEffectSpec.secret_ref` fields are designed but the secrets module (EXP-501) is not yet implemented. In Phase 1, if `secret_ref` is non-null the worker must return `EffectDeliveryError.SecretResolutionFailed` immediately (and retry) rather than crashing. Mark with `// TODO(EXP-501):` comments.

2. **Catch-event node wiring:** The process definition graph format does not currently have a first-class `CATCH_EVENT` node type that receives `effect.completed` / `effect.failed` signals. The graph validator and definition format may need an additive extension before EXP-302 phase can be completed. This is a dependency on `src/definition/graph.zig` that BACKEND-DEV must verify and, if needed, define as a companion issue.

3. **Email adapter:** The `email` channel is a placeholder stub in Phase 1. A concrete SMTP or mail-service adapter is not part of this design scope. `EmailEffectSpec` is defined so the schema is stable; the adapter can be filled in independently.

4. **`POST /api/v1/admin/effects/sweep` test-only endpoint:** A test-only HTTP endpoint to trigger one worker sweep cycle is needed for deterministic E2E tests (Phase 3). This should be gated behind `is_test_mode` at startup. Requires a small addition to `src/api/routes/admin.zig`.
