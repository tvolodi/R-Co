# Test Spec: SCH-05 — Missed timer recovery

**Requirement:** SCH-05 — If the scheduler was offline when a timer was due, it SHALL fire all overdue timers immediately on restart, with a flag indicating the timer fired late.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-SCH-05-01: Startup sweep fires all due timers with `fired_late=true`
**Given:** A scheduler that has just been initialized (`is_startup_sweep = true`) and one or more timers with `status = PENDING` and `fires_at <= NOW()`.
**When:** `pollDueTimers` is called for the first time.
**Then:** All due timers are fired, each TIMER_FIRED event payload includes `fired_late: true`, `scheduled_fire_at`, and `actual_fire_at`.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the platform was offline when one or more timers became due, WHEN the platform restarts and SCH-02 begins polling, THEN it fires all timers with `status = PENDING` and `fire_at ≤ NOW()` as overdue.

### TC-SCH-05-02: Normal poll does not mark sub-interval lateness
**Given:** A scheduler in normal polling mode (`is_startup_sweep = false`) and a timer whose `fires_at` is within one `poll_interval` of the current time.
**When:** `pollDueTimers` fires the timer.
**Then:** The TIMER_FIRED event has `fired_late: false`.
**Layer:** integration
**Acceptance criterion mapped:** Overdue timer events MUST include a flag `fired_late: true` and the actual firing timestamp vs the scheduled `fire_at`.

### TC-SCH-05-03: Normal poll marks timers overdue by more than one poll interval
**Given:** A scheduler in normal polling mode (`is_startup_sweep = false`) and a timer whose `fires_at` is more than one `poll_interval` in the past.
**When:** `pollDueTimers` fires the timer.
**Then:** The TIMER_FIRED event has `fired_late: true`.
**Layer:** integration
**Acceptance criterion mapped:** Overdue timer events MUST include a flag `fired_late: true`.

### TC-SCH-05-04: Extended TIMER_FIRED payload contains all metadata fields
**Given:** A timer is fired by the scheduler.
**When:** The TIMER_FIRED event is persisted.
**Then:** The event payload is a JSON object containing `timer_id` (string), `fired_late` (boolean), `scheduled_fire_at` (integer, epoch microseconds), and `actual_fire_at` (integer, epoch microseconds).
**Layer:** unit, integration
**Acceptance criterion mapped:** Overdue timer events MUST include a flag `fired_late: true` and the actual firing timestamp vs the scheduled `fire_at`.

### TC-SCH-05-05: `is_startup_sweep` transitions from `true` to `false` after first poll
**Given:** A scheduler initialized with `is_startup_sweep = true`.
**When:** `pollDueTimers` completes.
**Then:** `scheduler.is_startup_sweep` is `false`.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the platform was offline, WHEN the platform restarts and SCH-02 begins polling, THEN the first poll cycle fires all overdue timers in sequence.

### TC-SCH-05-06: All due timers are processed — none skipped
**Given:** Multiple timers with `status = PENDING` and `fires_at <= NOW()`.
**When:** `pollDueTimers` is called.
**Then:** Every due timer is fired exactly once (PollSummary.fired == count of due timers).
**Layer:** integration
**Acceptance criterion mapped:** No overdue timer MUST be skipped; all are fired exactly once.

### TC-SCH-05-07: Cancelled timers are skipped even if `fires_at <= NOW()`
**Given:** A timer with `status = CANCELLED` and `fires_at <= NOW()`.
**When:** `pollDueTimers` is called.
**Then:** The cancelled timer is not fired; `PollSummary.fired` does not count it.
**Layer:** integration
**Acceptance criterion mapped:** Overdue timer for a CANCELLED instance: timer has `status = CANCELLED`; skipped.

### TC-SCH-05-08: `isFiredLate` returns `true` on startup sweep for any past timer
**Given:** `is_startup_sweep = true`, `scheduled_fire_at = 1000`, `actual_fire_at = 2000`.
**When:** `isFiredLate(1000, 2000, 5000000, true)` is evaluated.
**Then:** Returns `true` because `scheduled < actual`.
**Layer:** unit
**Acceptance criterion mapped:** GIVEN the platform was offline when timers became due, WHEN the platform restarts, THEN overdue timers are flagged with `fired_late: true`.

### TC-SCH-05-09: `isFiredLate` returns `false` on normal poll for sub-threshold lateness
**Given:** `is_startup_sweep = false`, `scheduled_fire_at = 1000`, `actual_fire_at = 1500`, `poll_interval_us = 5000000`.
**When:** `isFiredLate(1000, 1500, 5000000, false)` is evaluated.
**Then:** Returns `false` because `1000 >= 1500 - 5000000`.
**Layer:** unit
**Acceptance criterion mapped:** Only timers overdue by more than one poll interval are flagged as late during normal polls.

### TC-SCH-05-10: `isFiredLate` returns `true` on normal poll when timer is materially late
**Given:** `is_startup_sweep = false`, `scheduled_fire_at = 1000`, `actual_fire_at = 6000000`, `poll_interval_us = 5000000`.
**When:** `isFiredLate(1000, 6000000, 5000000, false)` is evaluated.
**Then:** Returns `true` because `1000 < 6000000 - 5000000`.
**Layer:** unit
**Acceptance criterion mapped:** Only timers overdue by more than one poll interval are flagged as late during normal polls.

### TC-SCH-05-11: `buildTimerFiredPayload` produces valid JSON with all fields
**Given:** A timer ID, scheduled/actual fire timestamps, and a fired_late flag.
**When:** `buildTimerFiredPayload` is called.
**Then:** The returned JSON string contains `timer_id`, `fired_late`, `scheduled_fire_at`, and `actual_fire_at`.
**Layer:** unit
**Acceptance criterion mapped:** Overdue timer events MUST include a flag `fired_late: true` and the actual firing timestamp vs the scheduled `fire_at`.

### TC-SCH-05-12: Crash/restart simulation — timer inserted with past `fires_at` is fired with `fired_late=true`
**Given:** A newly initialized scheduler and a timer manually inserted with `fires_at` in the past simulating a crash/restart scenario.
**When:** `pollDueTimers` is called.
**Then:** The timer is fired with `fired_late: true` in the TIMER_FIRED payload.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the platform was offline when timers became due, WHEN the platform restarts and SCH-02 begins polling, THEN it fires all timers with `status = PENDING` and `fire_at ≤ NOW()` as overdue.

## Traceability Notes

- `TC-SCH-05-01` through `TC-SCH-05-07` and `TC-SCH-05-12` are implemented as integration tests in `tests/integration/sch02_timer_polling_test.zig` alongside the existing SCH-02/SCH-03/SCH-04 test suite.
- `TC-SCH-05-08` through `TC-SCH-05-11` are pure function unit tests implemented in `tests/unit/sch05_missed_timer_recovery_test.zig`.
