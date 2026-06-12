# Test Spec: ISS-303 — Timer DLQ Routing on Retry Exhaustion

**Requirement ID:** ISS-303  
**Module:** `src/scheduler/scheduler.zig`  
**Migration:** `migrations/092_iss303_timer_fire_error_count.sql`  
**Design artifact:** `src/design/scheduler-concurrency-epic3.md`  
**Status:** TEST-DESIGNED

---

## Requirement summary

When a timer's fire transaction rolls back (e.g. target instance does not exist, event append
fails), ISS-303 introduces a retry counter. Each fire failure increments `fire_error_count` on
the timer row (Transaction 2, new connection). After `max_timer_fire_retries` failures the
timer is moved to `status = 'failed'` and a `dead_letter_queue` entry is inserted atomically
in a third transaction (`markTimerFailedInTx`).

**Key design facts:**
- `SchedulerConfig.max_timer_fire_retries` defaults to `3`.
- Migration `092_iss303_timer_fire_error_count.sql` adds `fire_error_count INTEGER NOT NULL DEFAULT 0` and `failed_at TIMESTAMPTZ NULL` to `timers`.
- `markTimerFailedInTx` does NOT call `moveToDlq`; it performs the INSERT directly on the
  caller's connection to stay within the same transaction.
- DLQ row: `item_type = 'TIMER'`, `source_ref = timer_id`, `reason = 'TIMER_EXHAUSTED'`.

---

## Acceptance criteria

| ID | Criterion |
|----|-----------|
| AC-303-1 | `SchedulerConfig.max_timer_fire_retries` defaults to `3` |
| AC-303-2 | Migration `092_iss303_timer_fire_error_count.sql` exists and adds `fire_error_count` and `failed_at` columns to the `timers` table |
| AC-303-3 | After exactly `max_timer_fire_retries` fire failures, timer `status = 'failed'` and `failed_at IS NOT NULL` |
| AC-303-4 | A `dead_letter_queue` row exists with `item_type = 'TIMER'` and `source_ref = <timer_id>` after exhaustion |
| AC-303-5 | Before exhaustion (`fire_error_count < max_timer_fire_retries`), timer remains `status = 'pending'` with no DLQ entry |
| AC-303-6 | `processNextDueTimer` returns `.none` (not `.fired`) on the error path so the poll loop back-off is respected |

---

## Test cases

### TC-SCH-303-01 — `SchedulerConfig.max_timer_fire_retries` default is 3 (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-303-01 |
| **Type** | Unit |
| **File** | `tests/unit/sch05_missed_timer_recovery_test.zig` (already present as TC-SCH-05-13) |
| **Requirement** | AC-303-1 |
| **Description** | `SchedulerConfig{}` → `max_timer_fire_retries == 3`. Already implemented; spec entry provides ISS-303 traceability. |
| **Expected outcome** | `expectEqual(3, config.max_timer_fire_retries)` passes |
| **MUST coverage** | YES (covered by existing TC-SCH-05-13) |

### TC-SCH-303-02 — Migration 092 file exists and contains expected column definitions (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-303-02 |
| **Type** | Unit (file presence check) |
| **File** | `tests/unit/sch303_timer_dlq_unit_test.zig` |
| **Requirement** | AC-303-2 |
| **Description** | Assert that `migrations/092_iss303_timer_fire_error_count.sql` exists and its content contains both `fire_error_count` and `failed_at` column names. |
| **Expected outcome** | File exists; content contains both column names |
| **MUST coverage** | YES |

### TC-SCH-303-03 — Timer moves to FAILED + DLQ after retry exhaustion (integration)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-303-03 |
| **Type** | Integration (requires BPM_TEST_DB_URL) |
| **File** | `tests/integration/sch303_timer_dlq_test.zig` |
| **Requirement** | AC-303-3, AC-303-4 |
| **Description** | Insert a timer for a non-existent `instance_id` (forces `appendTimerFiredEventInTx` to fail). Call `pollDueTimers` `max_timer_fire_retries + 1` times (4 times with default = 3). After final call assert: timer `status = 'failed'`, `failed_at IS NOT NULL`. Assert `dead_letter_queue` has a row with `item_type = 'TIMER'` and `source_ref = timer_id`. |
| **Expected outcome** | `timers.status = 'failed'`; `timers.failed_at IS NOT NULL`; DLQ row present |
| **MUST coverage** | YES |

### TC-SCH-303-04 — Timer stays PENDING before exhaustion (integration)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-303-04 |
| **Type** | Integration (requires BPM_TEST_DB_URL) |
| **File** | `tests/integration/sch303_timer_dlq_test.zig` |
| **Requirement** | AC-303-5 |
| **Description** | Insert a timer for a non-existent instance. Call `pollDueTimers` exactly `max_timer_fire_retries - 1` times (2 times with default = 3). Assert: timer `status = 'pending'`; `fire_error_count = 2`; no DLQ row for this timer. |
| **Expected outcome** | `timers.status = 'pending'`; `fire_error_count = 2`; no DLQ entry |
| **MUST coverage** | YES |

### TC-SCH-303-05 — Concurrent SKIP LOCKED: two polls on one timer fire it exactly once (integration)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-303-05 |
| **Type** | Integration (requires BPM_TEST_DB_URL) |
| **File** | `tests/integration/sch303_timer_dlq_test.zig` |
| **Requirement** | ISS-301 AC-301-4 |
| **Description** | Insert one due timer for a real instance. Call `pollDueTimers` twice sequentially on two separate `Scheduler` instances backed by the same pool. Assert total `fired` count = 1 and timer `status = 'fired'`. Verifies SKIP LOCKED exclusion after ISS-301 advisory lock removal. |
| **Expected outcome** | `fired` sum = 1; timer `status = 'fired'` |
| **MUST coverage** | YES |

---

## Migration verification

The integration tests also transitively verify AC-303-2 because they will fail at the
`SELECT fire_error_count FROM timers` query if the column does not exist.

Direct file-presence verification is handled by TC-SCH-303-02 in the unit test file.

---

## Notes

- Integration tests use `error.SkipZigTest` when `BPM_TEST_DB_URL` is absent — this is
  acceptable for integration tests per project rules (only forbidden on unit MUST tests).
- Each test uses per-test UUID prefixes to prevent fixture collision with parallel test runs.
- Cleanup (`DELETE FROM timers WHERE ...` and `DELETE FROM dead_letter_queue WHERE ...`) runs
  in `defer` blocks so it executes even when the test fails.
