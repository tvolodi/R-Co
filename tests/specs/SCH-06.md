# Test Spec: SCH-06 — Timer jitter

**Requirement:** SCH-06 — The scheduler SHALL apply a configurable random jitter (±N ms) to polling intervals to prevent thundering-herd effects in clustered deployments.
**Priority:** SHOULD
**Test layer:** unit

## Acceptance Criteria

| ID | Criterion | Covered by |
|---|---|---|
| AC-01 | GIVEN jitter is configured (e.g. `BPM_SCHEDULER_JITTER_MS=500`), WHEN the scheduler schedules its next poll, THEN the actual delay is `base_interval ± random(0, jitter_ms)`. | TC-SCH-06-03, TC-SCH-06-13, TC-SCH-06-14, TC-SCH-06-16 |
| AC-02 | Jitter MUST be randomised independently on each node in a cluster (no shared seed). | TC-SCH-06-10, TC-SCH-06-15 |
| AC-03 | Default jitter is 0 ms (disabled); enabling requires explicit configuration. | TC-SCH-06-01, TC-SCH-06-02, TC-SCH-06-08, TC-SCH-06-11 |
| AC-04 | Jitter MUST NOT be applied to the timer's `fire_at` value; only to the polling interval. | Verified by design inspection (scheduler.zig: `computePollDelayMs` operates solely on config fields and RNG; no timer data is accessed) |
| AC-EC-01 | Jitter larger than base interval: minimum effective interval is 0; the platform does not validate this. | TC-SCH-06-04 |

## Test Cases

### TC-SCH-06-01: computePollDelayMs returns base_ms when jitter is 0
**Given:** A Scheduler with `jitter_ms = 0` and `poll_interval_ms = 5000`
**When:** `computePollDelayMs()` is called
**Then:** The result is exactly 5000
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (default/disabled jitter)

### TC-SCH-06-02: computePollDelayMs returns base_ms when jitter_ms is default (implicitly 0)
**Given:** A Scheduler with `poll_interval_ms = 3000` and jitter_ms left at default
**When:** `computePollDelayMs()` is called
**Then:** The result is exactly 3000
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (default jitter is 0)

### TC-SCH-06-03: computePollDelayMs with jitter stays within [base-jitter, base+jitter]
**Given:** A Scheduler with `jitter_ms = 2000`, `poll_interval_ms = 10000`
**When:** `computePollDelayMs()` is called 100 times
**Then:** Every result is in the range [8000, 12000]
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (jitter bounds)

### TC-SCH-06-04: computePollDelayMs never returns negative (clamps to 0 when jitter > base)
**Given:** A Scheduler with `jitter_ms = 10000`, `poll_interval_ms = 100` (jitter > base)
**When:** `computePollDelayMs()` is called 200 times
**Then:** Every result is >= 0 and <= 10100
**Layer:** unit
**Acceptance criterion mapped:** AC-EC-01 (jitter larger than base interval)

### TC-SCH-06-05: computePollDelayMs produces varied results with jitter enabled
**Given:** A Scheduler with `jitter_ms = 5000`, `poll_interval_ms = 10000`
**When:** `computePollDelayMs()` is called 20 times
**Then:** Not all samples are identical (jitter produces variation)
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (jitter randomisation)

### TC-SCH-06-07: computePollDelayMs produces results in valid range across multiple calls
**Given:** A Scheduler with `jitter_ms = 1000`, `poll_interval_ms = 5000`
**When:** `computePollDelayMs()` is called twice
**Then:** Both results are in the range [4000, 6000]
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (jitter bounds)

### TC-SCH-06-08: SchedulerConfig default jitter_ms is 0
**Given:** A default `SchedulerConfig{}`
**When:** The config is inspected
**Then:** `jitter_ms` is 0
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (default jitter is 0)

### TC-SCH-06-09: SchedulerConfig default poll_interval_ms is 5000
**Given:** A default `SchedulerConfig{}`
**When:** The config is inspected
**Then:** `poll_interval_ms` is 5000
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (defaults)

### TC-SCH-06-10: Scheduler struct has prng field after init
**Given:** A Scheduler initialized with `jitter_ms = 1000`
**When:** `computePollDelayMs()` is called
**Then:** The result is in the range [4000, 6000], confirming PRNG was initialized
**Layer:** unit
**Acceptance criterion mapped:** AC-02 (PRNG initialisation)

### TC-SCH-06-11: SchedulerConfig defaults are correct
**Given:** A default `SchedulerConfig{}`
**When:** The config fields are inspected
**Then:** `poll_interval_ms == 5000` and `jitter_ms == 0`
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (defaults)

### TC-SCH-06-12: Scheduler with jitter=0 behaves identically to no jitter
**Given:** Two Schedulers — one with `jitter_ms = 0`, one with default jitter
**When:** `computePollDelayMs()` is called
**Then:** Both return `poll_interval_ms` exactly
**Layer:** unit
**Acceptance criterion mapped:** AC-03 (jitter=0 is equivalent to disabled)

### TC-SCH-06-13: computePollDelayMs mean approximates base_ms over many samples
**Given:** A Scheduler with `jitter_ms = 1000`, `poll_interval_ms = 10000`
**When:** `computePollDelayMs()` is called 1000 times and the mean is computed
**Then:** The mean is within 5% of base_ms (10000)
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (symmetric distribution)

### TC-SCH-06-14: Minimum jitter (jitter_ms=1) covers both extremes of range
**Given:** A Scheduler with `jitter_ms = 1`, `poll_interval_ms = 1000`
**When:** `computePollDelayMs()` is called many times and unique values are collected
**Then:** The range covers both `base - 1` (999) and `base + 1` (1001)
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (jitter bounds at minimum jitter)

### TC-SCH-06-15: Different Scheduler instances have independent PRNG seeds
**Given:** Two Scheduler instances with identical config (`jitter_ms = 5000`, `poll_interval_ms = 10000`)
**When:** `computePollDelayMs()` is called on each
**Then:** The first result from each scheduler differs (probabilistic, verifying seed independence)
**Layer:** unit
**Acceptance criterion mapped:** AC-02 (independent PRNG per node)

### TC-SCH-06-16: computePollDelayMs range covers most of the [base-jitter, base+jitter] interval
**Given:** A Scheduler with `jitter_ms = 1000`, `poll_interval_ms = 5000`
**When:** `computePollDelayMs()` is called 2000 times
**Then:** The observed span (max - min) is at least 70% of the theoretical span (2 * jitter_ms), and all values respect the theoretical bounds [4000, 6000]
**Layer:** unit
**Acceptance criterion mapped:** AC-01 (range coverage)

## Test file locations

| Test ID | File |
|---|---|
| TC-SCH-06-01 through TC-SCH-06-09 | `src/scheduler/scheduler.zig` (inline tests) |
| TC-SCH-06-10 through TC-SCH-06-16 | `tests/unit/sch06_timer_jitter_test.zig` |
