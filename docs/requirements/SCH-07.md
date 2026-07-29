---
id: SCH-07
title: Recurring timers
stage: 5
priority: SHOULD
status: RELEASED
---

# SCH-07 — Recurring timers `[SHOULD]`

> The platform SHALL support recurring timers defined by ISO 8601 repeat intervals (e.g. `R/PT1H`). The timer automatically re-arms after firing.

**Acceptance Criteria:**
- GIVEN a recurring timer with an ISO 8601 repeat interval (e.g. `R/PT1H`), WHEN the timer fires (SCH-02), THEN a new timer is created automatically with `fire_at = previous_fire_at + interval` in the same transaction as the firing.
- GIVEN a repeat count N specified (e.g. `R3/PT1H`), WHEN the timer has fired N times, THEN no new timer is created (series complete).
- GIVEN `R/PT1H` (infinite repeats), the timer re-arms indefinitely until the instance terminates.

**See:** SCH-01 (timer creation used for re-arm), SCH-03 (instance cancellation cancels the recurring chain), SCH-02 (fires recurring timers like any other)

**Edge cases:**
- Platform restarts mid-series with missed firings: SCH-05 fires all missed occurrences as overdue.
- Interval shorter than polling period: fires once per poll cycle.
