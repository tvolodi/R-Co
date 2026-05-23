# Test Spec: SCH-01 — Durable timer creation

**Requirement:** SCH-01 — The platform SHALL allow a process definition to declare timer events on nodes. When execution reaches such a node, a durable timer is persisted with a `fire_at` timestamp. Timers MUST survive process restarts.
**Priority:** MUST
**Test layer:** integration

---

## Acceptance Criteria (verbatim from requirement)

1. GIVEN execution reaches a timer node, WHEN the transition function processes the arrival, THEN a durable timer record is persisted in the same transaction as the state transition event (DB-03), with: `timer_id` (UUID), `instance_id`, `fire_at` (absolute UTC timestamp), `status = PENDING`, and associated event payload.
2. `fire_at` MUST be an absolute UTC timestamp derived from the node's duration/schedule at the moment of token arrival.
3. GIVEN the platform is restarted, WHEN it comes back up, THEN all PENDING timers are intact and will be evaluated by the scheduler (SCH-02).
4. GIVEN `fire_at ≤ NOW()` at creation time, THEN the timer is treated as due immediately on the next SCH-02 poll.
5. Edge case: timer creation for an already-CANCELLED instance is rejected.

---

## Test Cases

### TC-SCH-01-01: Timer record persisted on timer-node arrival during instance start

**Given:** An ACTIVE definition with flow `START -> TIMER(duration_iso8601=PT5M) -> END`.
**When:** `InstanceStore.create()` starts a new instance and transition enters the TIMER node.
**Then:**
- Exactly one timer row exists for the instance.
- Persisted fields include non-null timer UUID (`timers.id`), matching `instance_id`, non-null `fires_at`, `status='pending'`, and JSON payload (`action_config`).

**Layer:** integration
**Acceptance criterion mapped:** AC-1, AC-2

---

### TC-SCH-01-02: Atomic persistence with transition/state write semantics

**Given:** An ACTIVE definition with flow `START -> HUMAN_TASK -> TIMER(duration_iso8601=PT5M) -> END` and a started instance parked on the HUMAN_TASK.
**When:** `InstanceStore.completeTask()` transitions token into TIMER.
**Then:**
- The `TASK_COMPLETED` event is persisted.
- Instance projection is updated to include the TIMER node token.
- Exactly one pending timer row is persisted for the same instance.
- Task row is marked `COMPLETED`.

**Layer:** integration
**Acceptance criterion mapped:** AC-1 (same transition persistence semantics / DB-03)

---

### TC-SCH-01-03: Restart durability for pending timers

**Given:** An instance with one pending timer already persisted.
**When:** The process store/pool is torn down and re-initialized (restart simulation).
**Then:** The pending timer row is still present with `status='pending'` for the same instance.

**Layer:** integration
**Acceptance criterion mapped:** AC-3

---

### TC-SCH-01-04: Immediate-due semantics for fire_at <= NOW

**Given:** An ACTIVE definition with flow `START -> TIMER(duration_iso8601=PT0S) -> END`.
**When:** `InstanceStore.create()` reaches the TIMER node.
**Then:** A pending timer row exists where `fires_at <= NOW()`.

**Layer:** integration
**Acceptance criterion mapped:** AC-4

---

### TC-SCH-01-05: Cancelled-instance rejection path

**Given:** An instance already transitioned to `CANCELLED`.
**When:** `scheduler.store.insertPendingTimerInTx()` is called for that instance inside a transaction.
**Then:** The call returns `TimerStoreError.InstanceCancelled` and no timer row is inserted.

**Layer:** integration
**Acceptance criterion mapped:** AC-5 edge case

---

## Notes

- All tests use a real PostgreSQL database via `BPM_TEST_DB_URL` (DIRECTIVE T-1).
- No sleep/wait loops are used; assertions are deterministic and state-based.
- Cleanup is performed per test in FK-safe order.
