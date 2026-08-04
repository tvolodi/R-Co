# Scheduler Concurrency — EPIC-3 Design

**Issues:** ISS-301, ISS-302, ISS-303  
**Module:** `src/scheduler/scheduler.zig`  
**Migration:** `migrations/089_iss303_timer_fire_error_count.sql`  
**Classification:** Type E (novel / cross-cutting; touches transaction protocol, config, DLQ)

---

## Module purpose

`src/scheduler/scheduler.zig` is the background timer-firing engine. It polls PostgreSQL for
due timers, claims them atomically with `FOR UPDATE SKIP LOCKED`, fires them inside a
transaction (appending the appropriate event), and handles recurrence re-arming.

These three issues correct two concurrency flaws and add exhaustion-handling to the fire path:

- **ISS-301**: Remove the `pg_try_advisory_xact_lock` call that is redundant with SKIP LOCKED.
- **ISS-302**: Gate the startup missed-timer sweep so only one HA node runs it.
- **ISS-303**: Track per-timer fire failures; after `max_timer_fire_retries` failures move the
  timer to `FAILED` and insert a DLQ entry atomically.

---

## ISS-301 — Remove redundant advisory lock

### Rationale: why SKIP LOCKED alone is sufficient

`FOR UPDATE SKIP LOCKED` is a PostgreSQL row-level lock acquired **inside the same
transaction** that claims the timer. The first connection to reach a pending timer row locks
it; every other concurrent connection sees the row as locked and skips it. This guarantee is
atomic at the storage layer and holds identically in single-node and HA deployments.

The `pg_try_advisory_xact_lock` call that follows is redundant:

1. By the time the advisory lock is attempted, the row is **already exclusively locked** by the
   current transaction. No other session can claim that timer row.
2. The advisory lock key was derived from the timer UUID (`advisoryLockKey(uuid)`), giving it
   the same per-timer granularity as SKIP LOCKED — no broader protection.
3. Advisory transaction locks are released at transaction end, the same lifetime as the
   SKIP LOCKED row lock, providing no additional durability.
4. The advisory lock path returns `.skipped_locked` on failure, implying a contention scenario
   that SKIP LOCKED already eliminates.

### Block to remove from `processNextDueTimer`

The following contiguous block at **lines 207–242** must be deleted entirely:

```
        const lock_key = advisoryLockKeyText(timer_id_text) catch return SchedulerError.TransactionFailed;
        const lock_key_text = std.fmt.allocPrint(a, "{}", .{lock_key}) catch return SchedulerError.OutOfMemory;

        const lock_rows = conn.query(
            a,
            \\SELECT pg_try_advisory_xact_lock($1::bigint)
        ,
            &.{lock_key_text},
        ) catch return SchedulerError.TransactionFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0 or lock_rows.rows[0].len == 0) {
            const lock_fields = [_]logger.LogField{
                .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                .{ .key = "outcome", .value = .{ .string = "skipped_locked" } },
            };
            logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace,
                "timer advisory lock row missing", &lock_fields) catch {};
            conn.rollback() catch {};
            return .skipped_locked;
        }

        const locked = colGet(lock_rows.rows[0], 0);
        if (!std.mem.eql(u8, locked, "t") and !std.mem.eql(u8, locked, "true")) {
            const lock_fields = [_]logger.LogField{
                .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                .{ .key = "outcome", .value = .{ .string = "skipped_locked" } },
            };
            logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace,
                "timer advisory lock not acquired", &lock_fields) catch {};
            conn.rollback() catch {};
            return .skipped_locked;
        }
```

Nothing replaces this block. Execution falls through directly to the `if (std.mem.eql(u8,
timer_type, "human_task_escalation"))` branch.

### Helper function removal

`pub fn advisoryLockKey` (line 470) and `fn advisoryLockKeyText` (line 478) derive per-timer
advisory lock integers from UUIDs. After ISS-301 removes the only call site
(`advisoryLockKeyText` in `processNextDueTimer`) and ISS-302 uses a fixed compile-time
constant instead, **both helpers must be deleted**.

Verify no other callers before deleting:
```
grep -r "advisoryLockKey" src/
```
Expected: zero matches after removal of the call site.

### Post-removal semantics of `PollOutcome.skipped_locked`

Before ISS-301: `.skipped_locked` was returned both by advisory lock failure (the removed
block) and by `fireEscalationTimerInTx` when `FOR UPDATE SKIP LOCKED` on the tasks row
returned 0 rows.

After ISS-301: `.skipped_locked` is returned **only** from `fireEscalationTimerInTx`
(task row contention). The `PollSummary.skipped_locked` counter retains its meaning for
escalation timers but no longer conflates advisory lock failures into the count.

`.none` continues to mean: no due timer was available (SKIP LOCKED SELECT returned 0 rows).

---

## ISS-302 — Startup sweep advisory lock

### Overview

When multiple HA nodes start simultaneously, all have `is_startup_sweep = true` and would
each sweep all past-due timers. While SKIP LOCKED prevents double-firing, the duplicate sweep
work is wasteful and generates confusing log noise. This design ensures exactly one node runs
the startup sweep.

### Compile-time constant

Add to `scheduler.zig` (module-level, outside the `Scheduler` struct):

```zig
/// Session-level advisory lock ID for the startup missed-timer sweep.
/// Derived from FNV-1a hash of "bpm_scheduler_startup_sweep", truncated to i64.
/// This value is distinct from any per-timer advisory lock key (which were
/// UUID-derived and are removed by ISS-301).
const SCHEDULER_STARTUP_LOCK_ID: i64 = 5863412975429063421;
```

This is a fixed compile-time constant; it must not be derived at runtime.

### Session-level lock vs transaction-level lock

The startup lock uses `pg_try_advisory_lock` (session-level), **not**
`pg_try_advisory_xact_lock` (transaction-level). The distinction is critical:

- `pg_try_advisory_xact_lock`: released automatically when the transaction ends.
- `pg_try_advisory_lock`: held until `pg_advisory_unlock` is called or the **connection**
  is closed.

The sweep may span many individual timer transactions (each timer fires in its own
connection from the pool). A transaction-level lock on a sweep-management connection would
release after the first query, losing the exclusion for the remainder of the sweep.
The session-level lock on a dedicated connection is held for the full sweep duration.

### Sweep connection

The lock must be acquired and released on the **same dedicated connection**, separate from
per-timer connections (each timer fires via `processNextDueTimer` which does its own
`pool.acquire()`). This dedicated connection is held only for the sweep, not for the full
scheduler lifetime.

### Protocol: `pollDueTimers` modification

Current structure:
```
pollDueTimers:
    while (processed < max_per_cycle):
        outcome = processNextDueTimer(...)
        ...
    self.is_startup_sweep = false
```

After ISS-302, the structure becomes:

```
pollDueTimers:
    if (self.is_startup_sweep):
        sweep_conn = pool.acquire()        // dedicated connection for advisory lock
        lock_acquired = pg_try_advisory_lock(sweep_conn, SCHEDULER_STARTUP_LOCK_ID)

        if (!lock_acquired):
            log WARN "startup sweep skipped — lock held by another node"
            pool.release(sweep_conn)
            self.is_startup_sweep = false
            // fall through to normal polling below

        else:
            defer:
                pg_advisory_unlock(sweep_conn, SCHEDULER_STARTUP_LOCK_ID)
                pool.release(sweep_conn)
            // run existing sweep while loop (no changes to loop body)
            while (processed < max_per_cycle):
                outcome = processNextDueTimer(...)    // each uses own pool.acquire()
                ...

    else:  // normal polling (also entered if sweep was skipped)
        while (processed < max_per_cycle):
            outcome = processNextDueTimer(...)
            ...

    self.is_startup_sweep = false
```

### Public interface additions

```zig
/// Acquire the startup sweep session-level advisory lock.
/// Returns true if lock acquired, false if another node holds it.
/// `conn` must remain open until `releaseStartupSweepLock` is called.
fn acquireStartupSweepLock(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
) SchedulerError!bool

/// Release the startup sweep session-level advisory lock.
fn releaseStartupSweepLock(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
) SchedulerError!void
```

### SQL executed by `acquireStartupSweepLock`

```sql
SELECT pg_try_advisory_lock($1::bigint)
```

Parameter `$1` = `SCHEDULER_STARTUP_LOCK_ID` formatted as a decimal string.

Returns `"t"` if acquired, `"f"` if not.

### SQL executed by `releaseStartupSweepLock`

```sql
SELECT pg_advisory_unlock($1::bigint)
```

Parameter `$1` = `SCHEDULER_STARTUP_LOCK_ID` formatted as a decimal string.

### Log entry on skipped sweep

```
WARN  scheduler.poller  "startup sweep skipped — lock held by another node"
  fields: { "lock_id": "5863412975429063421" }
```

### Interaction with defence-in-depth

The sweep loop calls `processNextDueTimer` which still uses `FOR UPDATE SKIP LOCKED`. If
two nodes simultaneously pass the advisory lock check (a theoretical race on lock acquisition
itself), SKIP LOCKED ensures no timer fires twice. The advisory lock is a performance and
log-hygiene optimisation, not a safety gate.

---

## ISS-303 — Exhausted-retry timers → FAILED + DLQ

### Dependency

ISS-303 depends on ISS-101 (migration 081) having added `'failed'` to the `timers.status`
CHECK constraint. This is confirmed done: `migrations/081_iss101_timers_failed_status.sql`
is present in the repository.

### Migration 089 — `fire_error_count` and `failed_at` columns

**File:** `migrations/089_iss303_timer_fire_error_count.sql`

Pattern: identical `to_regclass()` guard from migration 081 — no-op when timers table
absent (public schema), additive when present.

```sql
-- 089_iss303_timer_fire_error_count.sql
-- Requirements: ISS-303
--
-- Add fire_error_count and failed_at to timers table.
-- Idempotent: uses information_schema column existence check inside the
-- to_regclass() guard, same pattern as migration 081.

DO $$
DECLARE
    v_timers_oid OID;
BEGIN
    v_timers_oid := to_regclass('timers');
    IF v_timers_oid IS NULL THEN
        RETURN;  -- timers does not exist in this schema (e.g. public); no-op
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name   = 'timers'
          AND column_name  = 'fire_error_count'
    ) THEN
        EXECUTE 'ALTER TABLE timers ADD COLUMN fire_error_count INTEGER NOT NULL DEFAULT 0';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name   = 'timers'
          AND column_name  = 'failed_at'
    ) THEN
        EXECUTE 'ALTER TABLE timers ADD COLUMN failed_at TIMESTAMPTZ NULL';
    END IF;
END
$$;
```

Column semantics:

| Column | Type | Nullable | Default | Meaning |
|---|---|---|---|---|
| `fire_error_count` | `INTEGER` | NO | `0` | Number of failed fire attempts; incremented on each rollback |
| `failed_at` | `TIMESTAMPTZ` | YES | `NULL` | Timestamp when the timer was moved to `FAILED` status |

### `SchedulerConfig` addition

```zig
pub const SchedulerConfig = struct {
    poll_interval_ms: u64 = 5000,
    jitter_ms: u64 = 0,
    max_timers_per_cycle: u32 = 64,
    max_timer_fire_retries: u32 = 3,  // ← add this field
};
```

After `max_timer_fire_retries` failed fire attempts, the timer is moved to `FAILED` and a
DLQ entry is inserted. The default of 3 matches the DLQ retry convention used elsewhere.

### `markTimerFailedInTx` — function design

This function runs **within the caller's existing transaction** (on `conn`). It must NOT
call `moveToDlq` because `moveToDlq` acquires its own pool connection, which is illegal
inside an open transaction on a different connection.

```zig
/// Mark a timer as FAILED and insert a dead_letter_queue entry within the
/// caller's existing transaction.
///
/// Precondition: `conn` must have an active transaction (BEGIN issued).
/// The caller is responsible for COMMIT or ROLLBACK.
///
/// Does NOT call dlq.moveToDlq — that function acquires its own connection,
/// which cannot participate in the caller's transaction.
fn markTimerFailedInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    timer_id_text: []const u8,
    instance_id_text: []const u8,
    payload_json: []const u8,
    max_retries: u32,
) SchedulerError!void
```

**Step 1 — Update timers row:**

```sql
UPDATE timers
SET
    status           = 'failed',
    failed_at        = NOW(),
    fire_error_count = fire_error_count + 1
WHERE id = $1::uuid
  AND status = 'pending'
```

Parameter `$1` = `timer_id_text`.

**Step 2 — Insert DLQ entry:**

Mirrors the INSERT inside `moveToDlq` exactly (same column list, same parameter ordering,
same conflict clause), but executed on `conn` rather than a new connection.

Column mapping for timer failure:

| DLQ column | Value |
|---|---|
| `entry_type` | `'timer_failed'` (literal string — matches `entryTypeForItemType(.TIMER)`) |
| `instance_id` | `NULLIF($2, '')::uuid` where `$2` = `instance_id_text` |
| `reason` | `'TIMER_EXHAUSTED'` |
| `error_detail` | `jsonb_build_object('chain', '[]'::jsonb)` |
| `retry_count` | `$3::int` where `$3` = `max_retries` formatted as decimal string |
| `max_retries` | same as `retry_count` |
| `status` | `'pending'` |
| `item_type` | `'TIMER'` (literal string — matches `itemTypeToString(.TIMER)`) |
| `retry_limit` | same as `retry_count` |
| `original_payload` | `$4::jsonb` where `$4` = `payload_json` |
| `error_chain` | `'[]'::jsonb` |
| `processor_metadata` | `'{}'::jsonb` |
| `first_failed_at` | `NOW()` |
| `last_failed_at` | `NOW()` |
| `source_ref` | `$5` where `$5` = `timer_id_text` |
| `updated_at` | `NOW()` |

Full INSERT SQL:

```sql
INSERT INTO dead_letter_queue (
    entry_type,
    instance_id,
    reason,
    error_detail,
    retry_count,
    max_retries,
    status,
    item_type,
    retry_limit,
    original_payload,
    error_chain,
    processor_metadata,
    first_failed_at,
    last_failed_at,
    source_ref,
    updated_at
)
VALUES (
    'timer_failed',
    NULLIF($1, '')::uuid,
    'TIMER_EXHAUSTED',
    jsonb_build_object('chain', '[]'::jsonb),
    $2::int,
    $2::int,
    'pending',
    'TIMER',
    $2::int,
    $3::jsonb,
    '[]'::jsonb,
    '{}'::jsonb,
    NOW(),
    NOW(),
    $4,
    NOW()
)
ON CONFLICT (item_type, source_ref, last_failed_at)
DO NOTHING
RETURNING id::text
```

Parameters:
- `$1` = `instance_id_text`
- `$2` = `max_retries` formatted as decimal string
- `$3` = `payload_json`
- `$4` = `timer_id_text`

### Two-transaction approach in `processNextDueTimer`

The fire path (`appendTimerFiredEventInTx` → `markTimerFiredInTx` →
`insertRecurringPendingTimerInTx`) runs inside a single transaction on `conn`. If any step
fails, the `errdefer conn.rollback()` at the top of `processNextDueTimer` rolls back the
entire fire transaction. At that point `conn` is invalid for further writes (transaction
aborted), so the error-count increment and exhaustion check must use new connections.

**Transaction 1 — fire transaction (existing, on `conn`):**

```
BEGIN
  FOR UPDATE SKIP LOCKED → claim timer row
  [advisory lock removed by ISS-301]
  appendTimerFiredEventInTx(conn, ...)   ← can fail
  markTimerFiredInTx(conn, ...)          ← can fail
  insertRecurringPendingTimerInTx(conn, ...) ← can fail (recurrence only)
COMMIT  ← success path
  [or]
ROLLBACK  ← errdefer on any error
```

**After rollback — Transaction 2 — increment fire_error_count (new connection):**

Acquire a new connection from the pool (Transaction 1's `conn` is released by the existing
`defer self.pool.release(conn)`). On this new connection:

```sql
BEGIN;
UPDATE timers
SET fire_error_count = fire_error_count + 1
WHERE id = $1::uuid
  AND status = 'pending';  -- guard: only pending timers accumulate errors
COMMIT;
```

Then read back the current count:

```sql
SELECT fire_error_count FROM timers WHERE id = $1::uuid;
```

**Exhaustion check and Transaction 3 — fail transaction (new connection):**

If `fire_error_count >= max_timer_fire_retries`:

```
BEGIN
  markTimerFailedInTx(conn2, timer_id_text, instance_id_text, payload_json, max_retries)
    [step 1] UPDATE timers SET status='failed', failed_at=NOW(), fire_error_count=fire_error_count+1 WHERE id=$1::uuid
    [step 2] INSERT INTO dead_letter_queue ...
COMMIT
```

If `fire_error_count < max_timer_fire_retries`: log WARN with current count and next attempt
number; return `.fired` is wrong — return `.none` to avoid inflating the fired counter.
(The timer remains PENDING and will be picked up in a future poll cycle.)

### Data flow diagram

```
processNextDueTimer(conn):
│
├── BEGIN (Tx1 on conn)
├── SELECT ... FOR UPDATE SKIP LOCKED → timer row
│     ├── 0 rows → ROLLBACK → return .none
│     └── 1 row  → continue
│
├── appendTimerFiredEventInTx(conn)  ┐
├── markTimerFiredInTx(conn)         ├── Tx1 fire path
├── insertRecurringPendingTimerInTx  ┘
│
├── COMMIT → return .fired
│
└── [on error] errdefer ROLLBACK
      │
      └── [ISS-303 error path]
            conn2 = pool.acquire()
            BEGIN (Tx2 on conn2)
            UPDATE timers SET fire_error_count = fire_error_count + 1 WHERE id=$1 AND status='pending'
            COMMIT Tx2
            SELECT fire_error_count FROM timers WHERE id=$1 (on conn2)
            pool.release(conn2)
            │
            ├── fire_error_count < max_retries → log WARN, return .none
            │
            └── fire_error_count >= max_retries
                  conn3 = pool.acquire()
                  BEGIN (Tx3 on conn3)
                  markTimerFailedInTx(conn3, ...) → UPDATE timers + INSERT dead_letter_queue
                  COMMIT Tx3
                  pool.release(conn3)
                  return .none
```

### `processNextDueTimer` return value after fire failure

On the error path (Tx1 rollback), `processNextDueTimer` must return `.none`, not
`.skipped_locked` or `.fired`. The timer is not gone; it will be re-polled. The polling
loop in `pollDueTimers` treats `.none` as "no more work this cycle" and breaks — this is
correct because the same timer would be reclaimed immediately in the next iteration,
creating a busy-loop until exhaustion. Returning `.none` allows the poll interval jitter
to provide natural back-off between retry attempts.

---

## Dependencies

| Module | Used by | Access pattern |
|---|---|---|
| `pool` (db) | All three issues | Per-timer and per-sweep pool connections |
| `src/obs/logger.zig` | ISS-302 (WARN log) | `logWithTrace` |
| `src/dlq/store.zig` | ISS-303 | `DlqItemType` enum only; `moveToDlq` NOT called |
| `migrations/081_*` | ISS-303 precondition | `FAILED` status must be in CHECK before 089 runs |

`src/engine/transition.zig` is **not touched**. The I/O-free property is inviolable.

---

## Error taxonomy

| Error | Source | Meaning |
|---|---|---|
| `SchedulerError.PoolExhausted` | All | `pool.acquire()` failed; propagated to poll loop |
| `SchedulerError.TransactionFailed` | All | Any DB query/exec failure; Tx rolled back |
| `SchedulerError.OutOfMemory` | All | Arena allocation failure |

ISS-303 adds no new error variants. The error-count increment and fail-transaction paths
return `SchedulerError.TransactionFailed` on DB failure; the poll loop logs and continues to
the next cycle.

---

## Open questions

None. All design decisions are fully specified. The lock constant is provided explicitly;
the DLQ SQL is derived directly from `moveToDlq`'s INSERT. No ambiguity requiring
REQ-ANALYST input.

---

## Test strategy

### ISS-301

**Unit test (code inspection):**  
After removal, assert that `processNextDueTimer` contains no reference to
`pg_try_advisory_xact_lock` and no reference to `advisoryLockKeyText` or `advisoryLockKey`.
Implement as a compile-time check or a simple grep in the test runner.

**Integration test:**  
Spawn 2 concurrent scheduler instances against a single test database. Insert 1 due timer.
Both instances call `pollDueTimers` simultaneously. Assert:
- Exactly 1 `TIMER_FIRED` event in the events table.
- Exactly 1 row in `timers` with `status = 'fired'`.
- `PollSummary.fired` sums to 1 across both instances.

### ISS-302

**Unit test — lock not acquired:**  
Inject a `pg_try_advisory_lock` stub that returns `"f"`. Call `pollDueTimers` with
`is_startup_sweep = true`. Assert:
- `is_startup_sweep` is `false` after the call.
- The while loop did not execute (no `processNextDueTimer` calls).
- A WARN log was emitted with message "startup sweep skipped — lock held by another node".

**Unit test — lock acquired:**  
Inject a `pg_try_advisory_lock` stub returning `"t"` and a `pg_advisory_unlock` stub.
Assert:
- The sweep while loop executes.
- `pg_advisory_unlock(SCHEDULER_STARTUP_LOCK_ID)` is called exactly once after the loop.
- `pg_advisory_unlock` is called even if the sweep loop returns an error (defer pattern).

**Integration test:**  
Insert N past-due timers. Start 2 scheduler nodes simultaneously with `is_startup_sweep =
true`. After both complete, assert:
- Each timer has exactly 1 `TIMER_FIRED` event.
- Exactly 1 node logged "startup sweep" begin/end; the other logged the skipped message.

### ISS-303

**Integration test (primary):**  
Insert a timer whose `instance_id` references a non-existent instance (so
`appendTimerFiredEventInTx` will fail with a FK violation on every attempt).

For `i` in `[1 .. max_timer_fire_retries]`:
- Call `processNextDueTimer` once.
- After each call: assert `timers.fire_error_count = i` and `timers.status = 'pending'`.

After `max_timer_fire_retries` calls:
- Assert `timers.status = 'failed'`.
- Assert `timers.failed_at IS NOT NULL`.
- Assert exactly 1 row in `dead_letter_queue` where `source_ref = timer_id` AND
  `item_type = 'TIMER'` AND `reason = 'TIMER_EXHAUSTED'`.

**Migration idempotency test:**  
Apply migration 089 twice to a tenant schema. Assert no error and columns exist with
correct types and defaults.

**Null instance integration test:**  
Insert a timer with no `instance_id`. Fire to exhaustion. Assert DLQ row has
`instance_id IS NULL` (the `NULLIF($1, '')::uuid` guard handles the empty string case).
