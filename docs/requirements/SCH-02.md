---
id: SCH-02
title: Timer polling
stage: 5
priority: MUST
status: VALIDATED
---

# SCH-02 — Timer polling `[MUST]`

> A background scheduler thread SHALL poll for due timers at a configurable interval (default 5 seconds). Due timers SHALL be fired atomically — the timer is marked FIRED and the associated instance event is appended in a single transaction. In clustered deployments, the platform SHALL use a PostgreSQL advisory lock to ensure only one node fires a given timer.

**Acceptance Criteria:**
- GIVEN the scheduler thread runs, WHEN it polls, THEN it selects all timers with `status = PENDING` and `fire_at ≤ NOW()`.
- For each due timer, in a single transaction: mark timer as `FIRED` and append the associated event to the instance's event log.
- In a clustered deployment, BEFORE processing a due timer, the scheduler MUST acquire a PostgreSQL advisory lock on the timer's ID. If the lock is unavailable, that timer is skipped (another node is processing it). The lock is released when the transaction commits.
- Default polling interval is 5 seconds; configurable via environment variable.

**See:** SCH-01 (timers created here), SCH-03 (cancellation sets status = CANCELLED before polling picks it up), SCH-05 (overdue timers on restart), SCH-06 (jitter on interval)

**Edge cases:**
- Database unavailable during firing: the transaction rolls back; timer remains PENDING and is retried on next poll.
- A timer due during the interval between polls: fires on the next poll (maximum latency = poll interval + jitter).
