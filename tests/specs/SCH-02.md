# Test Spec: SCH-02 - Timer polling

**Requirement:** SCH-02 - A background scheduler thread SHALL poll for due timers at a configurable interval (default 5 seconds). Due timers SHALL be fired atomically (mark FIRED + append instance event in one transaction). In clustered deployments, scheduler SHALL use a PostgreSQL advisory lock so only one node fires a timer.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SCH-02-01: Due PENDING timer is selected and fired atomically
**Given:** A process instance has a persisted timer with `status = pending` and `fires_at <= NOW()`.
**When:** Scheduler poller runs one polling cycle.
**Then:** The timer is updated to `status = fired` and a `TIMER_FIRED` event is appended for that instance in the same transaction.
**Layer:** integration
**Acceptance criterion mapped:** Poll selects due PENDING timers and atomically performs timer fire + event append.

### TC-SCH-02-02: Advisory lock skip and cancellation compatibility
**Given:** A due timer exists and another transaction already holds the timer advisory lock.
**When:** Scheduler poller attempts to process due timers.
**Then:** That timer is skipped as lock-unavailable.
**And Given:** The instance is then cancelled.
**When:** Scheduler polls again.
**Then:** No timer for the cancelled instance is fired and no new `TIMER_FIRED` event is appended.
**Layer:** integration
**Acceptance criterion mapped:** Per-timer advisory lock behavior (skip when unavailable) and cancellation compatibility with SCH-03.

### TC-SCH-02-03: Rollback keeps timer PENDING when firing transaction fails
**Given:** A due PENDING timer exists and a conflicting idempotency key is pre-inserted so event append fails.
**When:** Scheduler attempts to fire that timer.
**Then:** The scheduler firing transaction fails and rolls back.
**And:** The timer remains `status = pending` (not partially updated to `fired`).
**Layer:** integration
**Acceptance criterion mapped:** Database failure edge case rolls back and retries from PENDING on next poll.
