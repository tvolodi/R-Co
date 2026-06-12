# Design: `instance_waits` Persistence Layer

**Requirement:** EXP-103  
**Run ID:** WF02-exp103-instance-waits-20260612  
**Status:** DESIGN — no implementation code

---

## 1. Module Purpose

`instance_waits` is a durable descriptor table that records every in-flight wait
a process instance is currently blocked on. One row exists for each live wait
(timer, human task, or catch-event subscription) from the moment the wait is armed
until the moment it is resolved. The invariant is **atomic co-write**: the row is
inserted in the same database transaction that arms the wait, so a crash between
arm and commit leaves neither the wait nor its descriptor. On restore/reconciliation
(EXP-402), the unresolved rows in this table are the authoritative source for
re-arming in-flight waits without querying the wait-specific tables (timers, tasks).

---

## 2. Schema: Migration 093

**File:** `migrations/093_exp103_instance_waits.sql`

Migration follows the `to_regclass()` idempotency pattern from migrations 081 and 083.
Full DDL with `DO $$ ... $$` idempotency wrapper belongs in the migration file.

```sql
-- 093_exp103_instance_waits.sql  (per-tenant, DO $$ ... idempotent)
-- to_regclass() guard: entire block is no-op if instance_projections absent.
CREATE TABLE instance_waits (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id      UUID        NOT NULL REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
    kind             TEXT        NOT NULL CHECK (kind IN ('timer','catch_event','human_task')),
    ref_id           UUID        NOT NULL,
    node_id          TEXT        NOT NULL,
    fire_at          TIMESTAMPTZ NULL,
    catch_event_key  TEXT        NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at      TIMESTAMPTZ NULL,
    UNIQUE (instance_id, ref_id)
);
CREATE INDEX idx_instance_waits_instance_resolved
    ON instance_waits (instance_id, resolved_at);
```

### Column annotations

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | `gen_random_uuid()` default; not exposed externally |
| `instance_id` | UUID NOT NULL | FK → `instance_projections(instance_id)` ON DELETE CASCADE |
| `kind` | TEXT NOT NULL | `'timer'` \| `'catch_event'` \| `'human_task'` |
| `ref_id` | UUID NOT NULL | The ID of the wait object: `timer_id`, `task_id`, or event correlation UUID |
| `node_id` | TEXT NOT NULL | The process graph node that armed the wait (`step_name` / `node_id`) |
| `fire_at` | TIMESTAMPTZ NULL | Populated for `kind='timer'`; NULL for `catch_event` and `human_task` |
| `catch_event_key` | TEXT NULL | Populated for `kind='catch_event'`; NULL for `timer` and `human_task` |
| `created_at` | TIMESTAMPTZ NOT NULL | Default `NOW()` at INSERT time |
| `resolved_at` | TIMESTAMPTZ NULL | Set to `NOW()` when the wait is consumed; NULL while in-flight |

**UNIQUE (instance_id, ref_id):** Each wait object (timer, task, event) produces
exactly one descriptor row. Duplicate arm attempts violate this constraint and cause
the transaction to roll back — which is the correct behaviour (the wait would also
fail to arm on its own constraint).

**ON DELETE CASCADE:** When an instance row is deleted from `instance_projections`,
all its wait descriptors are deleted automatically without a separate cleanup step.

---

## 3. Data Flow

**Arm path — writing `instance_waits` alongside the wait:**

```
Engine transition (instance.zig)
  │
  ├─► timer_created emitted event
  │       │
  │       └─► persistTimersFromPendingEventsInTx()
  │                │
  │                ├─ insertPendingTimerInTx()       [timers table]
  │                └─ insertTimerWaitDescriptorInTx() [instance_waits]  ← NEW
  │
  ├─► HUMAN_TASK node activated
  │       │
  │       └─► TaskStore.createInTx()
  │                │
  │                ├─ INSERT INTO tasks             [tasks table]
  │                └─ INSERT INTO instance_waits    [instance_waits]  ← NEW
  │
  └─► catch_event arming (NOT YET IMPLEMENTED — see §6)
```

**Resolve path — marking `instance_waits` resolved alongside the wait state change:**

```
Scheduler poll cycle (scheduler.zig)
  │
  └─► markTimerFiredInTx()
           │
           ├─ UPDATE timers SET status='fired' WHERE id=$timer_id  [timers]
           └─ UPDATE instance_waits SET resolved_at=NOW()          ← NEW
              WHERE ref_id=$timer_id AND resolved_at IS NULL

Task complete/cancel (instance.zig → tasks/store.zig)
  │
  ├─► TaskStore.completeInTx()
  │        │
  │        ├─ UPDATE tasks SET status='COMPLETED'                  [tasks]
  │        └─ UPDATE instance_waits SET resolved_at=NOW()          ← NEW
  │           WHERE ref_id=$task_id AND resolved_at IS NULL
  │
  └─► TaskStore.cancelInTx()
           │
           ├─ UPDATE tasks SET status='CANCELLED'                   [tasks]
           └─ UPDATE instance_waits SET resolved_at=NOW()           ← NEW
              WHERE ref_id IN (SELECT id FROM tasks
                               WHERE instance_id=$instance_id
                               AND status='PENDING')
              AND resolved_at IS NULL
```

---

## 4. Precise Integration Points

### 4.1 Timer arming — `src/engine/instance.zig::persistTimersFromPendingEventsInTx()`

**Location:** `src/engine/instance.zig`, function `persistTimersFromPendingEventsInTx`.

This function is called inside an already-open transaction (the caller holds `conn`
and will commit after all pending events are processed). The function iterates
`pending_events`, and for each `.timer_created` event it:

1. Generates `timer_id` (random UUID v4).
2. Calls `scheduler_store_mod.insertPendingTimerInTx(...)` — inserts into `timers`.

**New step to add (same `conn`, same transaction, immediately after step 2):**

```
INSERT INTO instance_waits
    (instance_id, kind, ref_id, node_id, fire_at)
VALUES
    ($instance_id::uuid, 'timer', $timer_id::uuid, $step_name,
     NOW() + $duration_iso8601::interval)
ON CONFLICT (instance_id, ref_id) DO NOTHING
```

The `ON CONFLICT DO NOTHING` matches the `ON CONFLICT (id) DO NOTHING` on the
`timers` INSERT — idempotent re-runs do not double-insert descriptors.

**New helper function (scheduler/store.zig):**

```
pub fn insertTimerWaitDescriptorInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
    timer_id: Uuid,
    step_name: []const u8,
    duration_iso8601: []const u8,
) TimerStoreError!void
```

Placed in `src/scheduler/store.zig` alongside `insertPendingTimerInTx` for
locality. Called from `persistTimersFromPendingEventsInTx` after the `timers`
INSERT succeeds.

### 4.2 Escalation timer arming — `src/engine/instance.zig::maybeInsertEscalationTimerInTx()`

**Location:** `src/engine/instance.zig`, function `maybeInsertEscalationTimerInTx`.

Calls `scheduler_store_mod.insertEscalationTimerInTx(...)`. The escalation timer
`kind` is still `'timer'`; `node_id` = `task_node_id`; `fire_at` is derived from
`task_created_at_utc + escalation_duration_iso8601`.

**New step to add** immediately after `insertEscalationTimerInTx` succeeds:
call the same `insertTimerWaitDescriptorInTx` helper with the escalation timer's
`timer_id`, `task_node_id`, and `escalation_duration_iso8601`.

### 4.3 Human task activation — `src/tasks/store.zig::TaskStore.createInTx()`

**Location:** `src/tasks/store.zig`, `TaskStore.createInTx`.

`createInTx` already receives a `conn` in an open transaction. After the `INSERT
INTO tasks ... RETURNING` succeeds, an additional INSERT must be issued on the
same `conn`:

```
INSERT INTO instance_waits
    (instance_id, kind, ref_id, node_id)
VALUES
    ($instance_id::uuid, 'human_task', $task_id::uuid, $node_id)
ON CONFLICT (instance_id, ref_id) DO NOTHING
```

`task_id` is obtained from the RETURNING row (currently returned as part of `Task`).
`fire_at` and `catch_event_key` are NULL for `human_task` rows.

**New helper function (tasks/store.zig):**

```
pub fn insertTaskWaitDescriptorInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
    task_id: Uuid,
    node_id: []const u8,
) TaskError!void
```

Called at the end of `createInTx`, after `task_id` is available from RETURNING.

### 4.4 Timer resolved — `src/scheduler/scheduler.zig::markTimerFiredInTx()`

**Location:** `src/scheduler/scheduler.zig`, private function `markTimerFiredInTx`.

Currently executes one `UPDATE timers SET status='fired'...`. Extend to also execute:

```
UPDATE instance_waits
SET resolved_at = NOW()
WHERE ref_id = $1::uuid
  AND resolved_at IS NULL
```

Same `conn`, immediately after the `timers` UPDATE. If the descriptor row does not
exist (e.g. migrated system with old timers), the UPDATE affects 0 rows — that is
silent and correct.

### 4.5 Task completed — `src/tasks/store.zig::TaskStore.completeInTx()`

**Location:** `src/tasks/store.zig`, `TaskStore.completeInTx`.

Extend to execute after the `UPDATE tasks SET status='COMPLETED'` RETURNING:

```
UPDATE instance_waits
SET resolved_at = NOW()
WHERE ref_id = $1::uuid
  AND resolved_at IS NULL
```

`$1` is `task_id`. Same `conn`, same transaction.

### 4.6 Task cancelled — `src/tasks/store.zig::TaskStore.cancelInTx()`

**Location:** `src/tasks/store.zig`, `TaskStore.cancelInTx`.

`cancelInTx` cancels all PENDING tasks for a given `instance_id` in bulk. Extend
to bulk-resolve descriptors in the same transaction:

```
UPDATE instance_waits
SET resolved_at = NOW()
WHERE instance_id = $1::uuid
  AND kind = 'human_task'
  AND resolved_at IS NULL
```

`$1` is `instance_id`. This is safe even if some tasks were already resolved — the
`resolved_at IS NULL` predicate restricts to still-open descriptors.

---

## Public Interface

The two new helper functions introduced by this module (Zig pseudocode signatures;
implementation belongs in the listed source files):

**`insertTimerWaitDescriptorInTx`** — `src/scheduler/store.zig`

- `allocator: std.mem.Allocator`
- `conn: *db.Conn` (open transaction)
- `instance_id: Uuid`
- `timer_id: Uuid` → stored as `ref_id`
- `step_name: []const u8` → stored as `node_id`
- `duration_iso8601: []const u8` → used to derive `fire_at`
- Returns: `TimerStoreError!void`

**`insertTaskWaitDescriptorInTx`** — `src/tasks/store.zig`

- `allocator: std.mem.Allocator`
- `conn: *db.Conn` (open transaction)
- `instance_id: Uuid`
- `task_id: Uuid` → stored as `ref_id`
- `node_id: []const u8`
- Returns: `TaskError!void`

---

## 5. Error Taxonomy

`instance_waits` INSERT/UPDATE failures follow the **fail-fast** rule because
the caller always holds an open transaction and uses `errdefer conn.rollback()`:

- If `insertTimerWaitDescriptorInTx` returns an error, the caller propagates it.
  The transaction is not committed. The `timers` INSERT is rolled back.
- If `insertTaskWaitDescriptorInTx` returns an error, `createInTx` propagates
  `TaskError.InvalidInput`. The `tasks` INSERT is rolled back.
- If the `resolved_at` UPDATE in `markTimerFiredInTx` returns an error,
  `SchedulerError.TransactionFailed` is propagated and the scheduler retries
  the timer on the next poll cycle.
- All SQL is via `$N` positional parameters — no interpolation of user data.

**No partial state is possible:** because every descriptor write shares the same
transaction as the wait-row write, a crash at any point before COMMIT leaves
neither the wait row nor the descriptor.

---

## 6. Catch-Event Arming (Deferred — EXP-103 Phase 2)

A search of the codebase found **no existing catch-event arming mechanism** in
`src/engine/instance.zig` or any other source file. The `instance_waits` schema
includes `kind='catch_event'` and `catch_event_key` in preparation, but no
arming call-site exists yet.

**Phase 2 design note (for the future CODE-DESIGNER):**

When catch-event arming is implemented, it must:
1. Accept `conn` (open transaction), `instance_id`, a correlation UUID (`ref_id`),
   `node_id`, and `catch_event_key`.
2. Call a new `insertCatchEventWaitDescriptorInTx` that inserts into `instance_waits`
   with `kind='catch_event'`, `fire_at=NULL`, `catch_event_key=<key>`.
3. Resolution: when the matching event is received and consumed, UPDATE
   `instance_waits SET resolved_at=NOW() WHERE ref_id=$event_ref_id`.

**Current migration:** The `CHECK (kind IN ('timer', 'catch_event', 'human_task'))`
constraint already allows `catch_event` rows so the schema needs no change in Phase 2.

---

## 7. Restore Reconciliation Query (EXP-402 Reference)

When a tenant restore is performed, the following query retrieves all waits that
must be re-armed (i.e. rows that were armed before the backup point and not yet
resolved):

```sql
SELECT
    iw.kind,
    iw.ref_id,
    iw.node_id,
    iw.fire_at,
    iw.catch_event_key,
    iw.instance_id
FROM instance_waits iw
WHERE iw.resolved_at IS NULL
ORDER BY iw.instance_id, iw.created_at;
```

This query is covered by `idx_instance_waits_instance_resolved` which has
`(instance_id, resolved_at)` — the `resolved_at IS NULL` predicate uses the index
for the common case of few unresolved rows per instance.

---

## 8. Test Strategy

Five integration tests, each verifying atomicity for one arm/resolve path. All
tests run against a real PostgreSQL schema via `BPM_TEST_DB_URL`. All fixtures
use per-test UUID v4 values.

### Test 1 — Timer arm atomicity

**Scenario:** Inject a fault after `timers` INSERT but before `instance_waits`
INSERT (simulate by rolling back the transaction manually after the first INSERT).

**Expected:** `timers` row absent AND `instance_waits` row absent — no partial state.

**Positive path:** Run both INSERTs and COMMIT. Assert:
- `SELECT COUNT(*) FROM timers WHERE id=$timer_id` = 1
- `SELECT kind, ref_id FROM instance_waits WHERE ref_id=$timer_id` returns one row
  with `kind='timer'`, `resolved_at IS NULL`.

### Test 2 — Human task arm atomicity

**Scenario:** Call `TaskStore.createInTx` inside a real transaction; commit and
verify both `tasks` and `instance_waits` rows exist.

**Expected:**
- `tasks` row with `id=$task_id`, `status='PENDING'`
- `instance_waits` row with `ref_id=$task_id`, `kind='human_task'`, `resolved_at IS NULL`

**Rollback path:** Begin transaction, call `createInTx`, ROLLBACK. Assert neither
row exists.

### Test 3 — Timer resolve atomicity (`markTimerFiredInTx`)

**Prerequisite:** Test 1 positive path (timer row + descriptor exist).

**Action:** Call `markTimerFiredInTx` (the extended version) inside a transaction
and commit.

**Expected:**
- `timers` row: `status='fired'`, `fired_at IS NOT NULL`
- `instance_waits` row: `resolved_at IS NOT NULL`

**Rollback path:** Call inside a transaction, ROLLBACK. Assert both remain unchanged.

### Test 4 — Task complete resolve atomicity (`completeInTx`)

**Prerequisite:** Test 2 positive path (task row + descriptor exist).

**Action:** Call `TaskStore.completeInTx` inside a transaction and commit.

**Expected:**
- `tasks` row: `status='COMPLETED'`
- `instance_waits` row: `resolved_at IS NOT NULL`

### Test 5 — Task bulk-cancel resolve atomicity (`cancelInTx`)

**Prerequisite:** Two PENDING tasks on the same `instance_id`, both with
`instance_waits` descriptor rows.

**Action:** Call `TaskStore.cancelInTx` for the `instance_id` and commit.

**Expected:**
- Both `tasks` rows: `status='CANCELLED'`
- Both `instance_waits` rows: `resolved_at IS NOT NULL`

**Partial-cancel guard:** A pre-existing completed task for the same instance
must retain its original `resolved_at` value (not double-set).

---

## 9. Dependencies

| Depends on | Why |
|---|---|
| `src/scheduler/store.zig` | New `insertTimerWaitDescriptorInTx` lives here |
| `src/tasks/store.zig` | New `insertTaskWaitDescriptorInTx` lives here; `cancelInTx` bulk-resolve |
| `src/engine/instance.zig` | Calls the two new helpers at existing arm sites |
| `src/scheduler/scheduler.zig` | `markTimerFiredInTx` extended with resolve UPDATE |
| `migrations/093_exp103_instance_waits.sql` | Schema prerequisite |

**Must NOT depend on:**
- `src/engine/transition.zig` — pure function; no I/O allowed (XC-04 Kernel Determinism)
- Any external HTTP call

---

## 10. Open Questions

None. All ambiguities are resolved by the existing codebase conventions:
- `to_regclass()` idempotency pattern: confirmed from migrations 081 and 083.
- Timer `timer_id` is generated in `instance.zig` before calling `insertPendingTimerInTx`; it is available for the descriptor INSERT.
- `task_id` is available from the RETURNING row of `TaskStore.createInTx`.
- Catch-event arming does not exist in the codebase; deferred to EXP-103 Phase 2.
