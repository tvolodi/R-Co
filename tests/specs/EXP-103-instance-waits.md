# Test Spec: EXP-103 — `instance_waits` Persistence Layer

**Requirement:** EXP-103  
**Run ID:** WF02-exp103-instance-waits-20260612  
**Status:** TEST-DESIGNED

---

## Overview

Verifies that the `instance_waits` table is written and resolved atomically alongside
the corresponding wait-row tables (`timers`, `tasks`). Five integration tests covering
the two arm paths (timer, human task) and the three resolve paths (timer fire, task
complete, transaction rollback).

All tests connect to a real PostgreSQL via `BPM_TEST_DB_URL`. No mocks.

---

## Test Cases

### TC-EXP-103-01 — Timer arm creates `instance_waits` row

| Field | Value |
|---|---|
| **Priority** | MUST |
| **Layer** | Integration (real PostgreSQL) |
| **Requirement** | EXP-103 §4.1 — Timer arm atomicity |

**Preconditions:**
- `BPM_TEST_DB_URL` is set and reachable.
- Migration 093 (`instance_waits` table) is applied.

**Steps:**
1. Insert a minimal `instance_projections` row.
2. INSERT a timer row (`status='pending'`, `fires_at` in the past).
3. INSERT an `instance_waits` row (`kind='timer'`, `ref_id=timer_id`, `node_id='TC01_NODE'`) in the same logical operation.
4. Commit the transaction.
5. Query `instance_waits WHERE ref_id = timer_id`.

**Expected outcome:**
- Exactly 1 row returned.
- `kind = 'timer'`.
- `ref_id = timer_id`.
- `resolved_at IS NULL`.

**Cleanup:** DELETE timers, instance_waits, instance_projections for the test UUIDs.

---

### TC-EXP-103-02 — Task creation creates `instance_waits` row

| Field | Value |
|---|---|
| **Priority** | MUST |
| **Layer** | Integration (real PostgreSQL) |
| **Requirement** | EXP-103 §4.3 — Human task arm atomicity |

**Preconditions:**
- `BPM_TEST_DB_URL` is set and reachable.
- Migration 093 applied.

**Steps:**
1. Insert `instance_projections` and `tokens` rows.
2. Call `TaskStore.createInTx(conn, instance_id, token_id, "TC02_NODE", "TC-02 Task", null, null, null)`.
3. Query `instance_waits WHERE ref_id = task_id`.

**Expected outcome:**
- Exactly 1 row returned.
- `kind = 'human_task'`.
- `ref_id = task.task_id`.
- `resolved_at IS NULL`.
- A `tasks` row also exists with `status='PENDING'` and the same `id`.

**Cleanup:** DELETE tasks, instance_waits, tokens, instance_projections.

---

### TC-EXP-103-03 — Timer fire sets `resolved_at` in `instance_waits`

| Field | Value |
|---|---|
| **Priority** | MUST |
| **Layer** | Integration (real PostgreSQL + Scheduler) |
| **Requirement** | EXP-103 §4.4 — Timer resolve atomicity |

**Preconditions:**
- `BPM_TEST_DB_URL` is set and reachable.
- Migration 093 applied.
- Timer row and `instance_waits` row are present (`resolved_at IS NULL`).

**Steps:**
1. Insert `instance_projections`, timer (`fires_at = NOW() - 1s`), and `instance_waits` (kind='timer').
2. Construct `Scheduler` and call `scheduler.pollDueTimers(allocator)`.
3. Query `instance_waits WHERE ref_id = timer_id`.

**Expected outcome:**
- `resolved_at IS NOT NULL`.
- `timers` row `status = 'fired'`.

**Cleanup:** DELETE timers, events, instance_waits, instance_projections.

---

### TC-EXP-103-04 — Task completion sets `resolved_at` in `instance_waits`

| Field | Value |
|---|---|
| **Priority** | MUST |
| **Layer** | Integration (real PostgreSQL) |
| **Requirement** | EXP-103 §4.5 — Task complete resolve atomicity |

**Preconditions:**
- `BPM_TEST_DB_URL` is set and reachable.
- Migration 093 applied.
- Task row and `instance_waits` row are present (`resolved_at IS NULL`).

**Steps:**
1. Insert `instance_projections`, `tokens`, task (`status='PENDING'`), and `instance_waits` (kind='human_task', ref_id=task_id).
2. Call `TaskStore.completeInTx(conn, task_id, '{}')`.
3. Query `instance_waits WHERE ref_id = task_id`.

**Expected outcome:**
- `resolved_at IS NOT NULL`.
- `tasks` row `status = 'COMPLETED'`.

**Cleanup:** DELETE tasks, instance_waits, tokens, instance_projections.

---

### TC-EXP-103-05 — Rollback leaves no orphaned `instance_waits` row

| Field | Value |
|---|---|
| **Priority** | MUST |
| **Layer** | Integration (real PostgreSQL) |
| **Requirement** | EXP-103 §1 — Crash-safety / atomic co-write |

**Preconditions:**
- `BPM_TEST_DB_URL` is set and reachable.
- Migration 093 applied.

**Steps:**
1. Insert `instance_projections`.
2. BEGIN a transaction.
3. INSERT a timer row.
4. INSERT an `instance_waits` row for that timer.
5. ROLLBACK the transaction.
6. Query `timers WHERE id = timer_id`.
7. Query `instance_waits WHERE ref_id = timer_id`.

**Expected outcome:**
- `timers` row: 0 rows (rolled back).
- `instance_waits` row: 0 rows (rolled back — no orphan).

**Cleanup:** DELETE instance_projections (timer/wait were rolled back).
