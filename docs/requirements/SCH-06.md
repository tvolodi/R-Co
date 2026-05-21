---
id: SCH-06
title: Timer jitter
stage: 5
priority: SHOULD
status: VALIDATED
---

# SCH-06 — Timer jitter `[SHOULD]`

> The scheduler SHALL apply a configurable random jitter (±N ms) to polling intervals to prevent thundering-herd effects in clustered deployments.

**Acceptance Criteria:**
- GIVEN jitter is configured (e.g. `BPM_SCHEDULER_JITTER_MS=500`), WHEN the scheduler schedules its next poll, THEN the actual delay is `base_interval ± random(0, jitter_ms)`.
- Jitter MUST be randomised independently on each node in a cluster (no shared seed).
- Default jitter is 0 ms (disabled); enabling requires explicit configuration.
- Jitter MUST NOT be applied to the timer's `fire_at` value; only to the polling interval.

**See:** SCH-02 (polling interval where jitter is applied)

**Edge cases:**
- Jitter larger than base interval: minimum effective interval is 0; the platform does not validate this.
