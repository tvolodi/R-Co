# Design: GH-766 — appendEventInTx must write plat_event_idempotency

**Run ID:** WF03-GH766-20260813  
**Handoff:** wf03-gh766-20260813-02-code-designer  
**Type:** E (novel / cross-cutting behaviour change)  
**Status:** COMPLETED

---

## Module purpose

`appendEventInTx` in `src/scheduler/scheduler.zig` appends a domain event to the `events`
table inside an existing database connection (which the caller has already begun a
transaction on). After migration 1147 (`migrations/1147_par01_events_partitioning.sql`)
converted `events` to a partitioned table, the global unique index
`uq_event_idempotency` on `events.idempotency_key` was intentionally removed — a
single UNIQUE index cannot span partitions in PostgreSQL without including all partition
key columns, which would silently narrow the uniqueness guarantee to per-partition scope
(violating PAR-01 AC2). The replacement for that index is the non-partitioned sidecar
table `plat_event_idempotency` (PRIMARY KEY on `idempotency_key`), which is meant to be
written in the same transaction as every event append. `appendEventInTx` currently omits
that write, breaking the deduplication guarantee.

---

## Root cause

`appendEventInTx` performs two SQL statements:

1. CTE INSERT into `instance_sequence` (upsert) + INSERT into `events`
2. UPDATE of `instance_projections`

It never writes to `plat_event_idempotency`. As a result, a duplicate call with the same
`idem_key` succeeds silently instead of producing a PRIMARY KEY violation. TC-SCH-02-03
relied on the old `uq_event_idempotency` index to force a conflict; after migration 1147
that conflict no longer occurs.

---

## Public interface — no signature change

```
fn appendEventInTx(
    conn: *db.Conn,
    instance_id_text: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    idem_key: []const u8,
) SchedulerError!void
```

The function signature, callers (`appendTimerFiredEventInTx`, `appendEscalationEventInTx`),
and the `SchedulerError` error set are all unchanged.

---

## Required change 1 — appendEventInTx (src/scheduler/scheduler.zig)

Insert a third `conn.exec` call immediately **after** the existing events INSERT exec and
**before** the existing `instance_projections` UPDATE exec.

### Exact SQL to add (third exec)

```sql
INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
SELECT $1, event_id, created_at
FROM events
WHERE instance_id = $2::uuid
  AND idempotency_key = $1
ORDER BY created_at DESC
LIMIT 1
```

**Parameter binding:** `&.{ idem_key, instance_id_text }`  
(`$1` = `idem_key`, `$2` = `instance_id_text`)

**Catch clause:** identical to the two existing execs —
`catch return SchedulerError.TransactionFailed`

### Why a SELECT subquery rather than VALUES

The subquery fetches the real `event_id` and `created_at` values that were assigned by
the preceding INSERT INTO `events`. This keeps `plat_event_idempotency.event_id`
accurate so that the sidecar lookup index (`idx_plat_event_idempotency_event`) returns
correct results for downstream archive lookups (PAR-03). The SELECT runs within the
same transaction, so the just-inserted row is immediately visible.

If the `idempotency_key` already exists in `plat_event_idempotency`, PostgreSQL will
raise a PRIMARY KEY violation. The `catch` clause converts that into
`SchedulerError.TransactionFailed`, which is exactly what TC-SCH-02-03 asserts.

### Position in function body

```
conn.exec(  /* 1: instance_sequence upsert + events INSERT */  ) catch return ...;
conn.exec(  /* 2: NEW — plat_event_idempotency INSERT       */  ) catch return ...;  ← INSERT HERE
conn.exec(  /* 3: instance_projections UPDATE               */  ) catch return ...;
```

---

## Required change 2 — TC-SCH-02-03 (tests/integration/sch02_timer_polling_test.zig)

### Current behaviour (broken)

The test pre-seeds a conflicting event by inserting directly into `events`:

```sql
INSERT INTO events (instance_id, event_type, payload, actor_id, sequence_number, idempotency_key)
VALUES ($1::uuid, $2, $3::jsonb, $1::uuid, $4::bigint, $5)
```

After migration 1147 the unique index on `events.idempotency_key` is gone, so this
insert succeeds and `appendEventInTx`'s own events INSERT also succeeds — the
`TransactionFailed` path is never reached.

### Required additional pre-seed (add immediately after the existing events INSERT)

```sql
INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
VALUES ($1, gen_random_uuid(), NOW())
```

**Parameter binding:** `&.{conflicting_idem}`

This row creates the PRIMARY KEY conflict that `appendEventInTx`'s new third exec will
hit, restoring the test to its intended behaviour.

### Placement in test body

The new `conn.exec` call must appear immediately after the existing `conn.exec` that
inserts the conflicting event into `events` and before `scheduler.pollDueTimers` is
called.

### Why `gen_random_uuid()` and `NOW()` are acceptable here

The test only needs to occupy the `idempotency_key` slot; it does not validate the
stored `event_id`. Using `gen_random_uuid()` avoids a second query to look up the
pre-seeded event's UUID and keeps the setup minimal.

---

## Data flow (relevant path only)

```
pollDueTimers()
  └─ fireTimer(conn, ...)                 ← connection inside an open transaction
       └─ appendTimerFiredEventInTx(conn, ...)
            └─ appendEventInTx(conn, ...)
                 ├─ exec 1: instance_sequence upsert + events INSERT
                 ├─ exec 2 [NEW]: plat_event_idempotency INSERT  ← PK violation if duplicate
                 └─ exec 3: instance_projections UPDATE
```

If exec 2 raises a PK violation the function returns `SchedulerError.TransactionFailed`.
The caller (`fireTimer` → `pollDueTimers`) propagates that error; the DB transaction is
rolled back at the pool/connection level so the `events` insert from exec 1 is also
undone — the timer remains `PENDING`.

---

## Error taxonomy

| Error | Source | Propagation |
|---|---|---|
| PRIMARY KEY violation on `plat_event_idempotency.idempotency_key` | duplicate `idem_key` | `catch return SchedulerError.TransactionFailed` |
| Any other exec failure on exec 2 | network, server error | same catch — `SchedulerError.TransactionFailed` |

No new error variants are introduced.

---

## State transitions — no change

The observable state machine for timers (`PENDING` → `fired`) is unchanged. A duplicate
event attempt already produced `TransactionFailed` before migration 1147 (via the old
unique index). This design restores that behaviour post-migration; it does not alter any
timer state or firing semantics.

---

## Dependencies

| Module | Role |
|---|---|
| `src/db/db.zig` (`db.Conn`) | provides `exec` — no change to its interface |
| `migrations/1147_par01_events_partitioning.sql` | creates `plat_event_idempotency` — read-only reference, no change |
| `src/scheduler/scheduler.zig` | file to edit (exec 2 insertion) |
| `tests/integration/sch02_timer_polling_test.zig` | file to edit (pre-seed addition) |

---

## Files NOT to change

| File | Reason |
|---|---|
| `migrations/1147_par01_events_partitioning.sql` | Schema is correct; no DDL change needed |
| Any other migration file | The `plat_event_idempotency` table already exists post-1147 |
| `src/store/event_store.zig` | That module has its own idempotency path; this fix is scoped to the scheduler only |
| `build.zig` / `build.zig.zon` | No new test targets or dependencies |
| Any file not listed in `artifacts_in` | Out of scope for this fix |

---

## Acceptance criteria

1. `src/design/iss-gh766-appendeventintx-idempotency.md` created (this file).
2. Design specifies exact SQL for exec 2 in `appendEventInTx`, including the SELECT
   subquery, parameter binding order, and `catch return SchedulerError.TransactionFailed`.
3. Design specifies exact SQL for TC-SCH-02-03 pre-seed addition, including parameter
   binding and placement.
4. Files NOT to change are enumerated.
5. No Zig function bodies, no SQL migration DDL, no JSX — prose and SQL specimens only.

---

## Open questions

None. Root cause is confirmed (step-01 PASS). Schema is confirmed via migration 1147
full read. Function body is confirmed via source read at lines 913–946.
