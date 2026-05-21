---
id: SCH-05
title: Missed timer recovery
stage: 5
priority: MUST
status: VALIDATED
---

# SCH-05 — Missed timer recovery `[MUST]`

> If the scheduler was offline when a timer was due, it SHALL fire all overdue timers immediately on restart, with a flag indicating the timer fired late.

**Acceptance Criteria:**
- GIVEN the platform was offline when one or more timers became due, WHEN the platform restarts and SCH-02 begins polling, THEN it fires all timers with `status = PENDING` and `fire_at ≤ NOW()` as overdue.
- Overdue timer events MUST include a flag `fired_late: true` and the actual firing timestamp vs the scheduled `fire_at`.
- No overdue timer MUST be skipped; all are fired exactly once.
- The first SCH-02 poll after restart fires ALL overdue timers in sequence to avoid thundering-herd behaviour.

**See:** SCH-02 (base polling mechanism), SCH-01 (timers persist across restarts), NFR-07 (crash safety means timers are never lost)

**Edge cases:**
- Overdue timer for a CANCELLED instance: timer has `status = CANCELLED` (SCH-03 ran before shutdown); skipped.
- Platform offline for an extended period with many overdue timers: all are fired in sequence; none dropped.
