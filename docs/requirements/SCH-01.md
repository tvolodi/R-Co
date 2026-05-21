---
id: SCH-01
title: Durable timer creation
stage: 5
priority: MUST
status: VALIDATED
---

# SCH-01 — Durable timer creation `[MUST]`

> The platform SHALL allow a process definition to declare timer events on nodes. When execution reaches such a node, a durable timer is persisted with a `fire_at` timestamp. Timers MUST survive process restarts.

**Acceptance Criteria:**
- GIVEN execution reaches a timer node, WHEN the transition function processes the arrival, THEN a durable timer record is persisted in the same transaction as the state transition event (DB-03), with: `timer_id` (UUID), `instance_id`, `fire_at` (absolute UTC timestamp), `status = PENDING`, and associated event payload.
- `fire_at` MUST be an absolute UTC timestamp derived from the node's duration/schedule at the moment of token arrival.
- GIVEN the platform is restarted, WHEN it comes back up, THEN all PENDING timers are intact and will be evaluated by the scheduler (SCH-02).
- GIVEN `fire_at ≤ NOW()` at creation time, THEN the timer is treated as due immediately on the next SCH-02 poll.

**See:** EE-02 (timer nodes processed by the transition function), SCH-02 (polling fires created timers), SCH-03 (cancellation), DB-03 (atomic persistence)

**Edge cases:**
- Timer creation for an already-CANCELLED instance: rejected; instance is in terminal state.
