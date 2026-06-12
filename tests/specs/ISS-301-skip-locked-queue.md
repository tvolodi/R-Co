# Test Spec: ISS-301 — Remove Redundant Advisory Lock

**Requirement ID:** ISS-301  
**Module:** `src/scheduler/scheduler.zig`  
**Design artifact:** `src/design/scheduler-concurrency-epic3.md`  
**Status:** TEST-DESIGNED

---

## Requirement summary

`processNextDueTimer` previously called `pg_try_advisory_xact_lock` after claiming a timer
row with `FOR UPDATE SKIP LOCKED`. This advisory lock was redundant because SKIP LOCKED
already provides exclusive row-level claiming at the storage layer. ISS-301 removes the
redundant advisory lock block and the two helpers (`advisoryLockKey`, `advisoryLockKeyText`)
that derived its key.

---

## Acceptance criteria

| ID | Criterion |
|----|-----------|
| AC-301-1 | `processNextDueTimer` does not call `pg_try_advisory_xact_lock` |
| AC-301-2 | `advisoryLockKey` and `advisoryLockKeyText` helpers are removed from `scheduler.zig` |
| AC-301-3 | `.skipped_locked` is returned only from `fireEscalationTimerInTx` (task row contention), not from any advisory lock path |
| AC-301-4 | Two concurrent scheduler instances polling the same due timer fire it exactly once combined |

---

## Test cases

### TC-SCH-301-01 — No `pg_try_advisory_xact_lock` call in scheduler.zig

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-301-01 |
| **Type** | Unit (compile/source inspection) |
| **File** | `tests/unit/sch301_skip_locked_test.zig` |
| **Requirement** | AC-301-1, AC-301-2 |
| **Description** | Assert that the scheduler source file contains no reference to `pg_try_advisory_xact_lock`, `advisoryLockKey`, or `advisoryLockKeyText`. Implemented as a runtime string-search over the embedded source bytes (compile-time constant). |
| **Expected outcome** | Test passes (no forbidden symbols present) |
| **MUST coverage** | YES |

### TC-SCH-301-02 — No `advisoryLockKey` helper in scheduler.zig

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-301-02 |
| **Type** | Unit (compile/source inspection) |
| **File** | `tests/unit/sch301_skip_locked_test.zig` |
| **Requirement** | AC-301-2 |
| **Description** | Assert neither `advisoryLockKey` nor `advisoryLockKeyText` function name appears in the scheduler module source. |
| **Expected outcome** | Test passes (symbols absent) |
| **MUST coverage** | YES |

### TC-SCH-301-03 — Concurrent polling fires each timer exactly once (integration)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-301-03 |
| **Type** | Integration (requires BPM_TEST_DB_URL) |
| **File** | `tests/integration/sch303_timer_dlq_test.zig` |
| **Requirement** | AC-301-3, AC-301-4 |
| **Description** | Insert one due timer. Call `pollDueTimers` twice sequentially in the same test process (simulating two workers competing). Assert the combined `fired` count across both calls equals exactly 1. Assert the timer row ends with `status = 'fired'`. |
| **Expected outcome** | `fired` total = 1; timer status = 'fired'; no double-fire |
| **MUST coverage** | YES |

---

## Non-test verification

After ISS-301 removal:
```
grep -r "advisoryLockKey" src/
```
Expected: zero matches.

---

## Notes

The removal of the advisory lock does not change the observable behaviour of the `PollSummary`
counters for normal timer types. The `.skipped_locked` counter continues to count escalation
timer task-row contention from `fireEscalationTimerInTx`.
