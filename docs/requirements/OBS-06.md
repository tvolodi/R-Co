---
id: OBS-06
title: Alerting hooks
stage: 6
priority: SHOULD
status: VALIDATED
---

# OBS-06 — Alerting hooks `[SHOULD]`

> The platform SHALL support configurable webhook calls on defined system events: instance stuck in ERROR for > N minutes, DLQ depth exceeds threshold, scheduler lag exceeds threshold.

**Acceptance Criteria:**
- GIVEN an alerting webhook is configured for "instance stuck in ERROR > N minutes", WHEN an instance has been in ERROR status for > N consecutive minutes, THEN the platform delivers a POST to the configured URL with a JSON body identifying the instance, error reason, and duration.
- GIVEN a DLQ depth threshold is configured, WHEN the DLQ item count crosses the threshold, THEN the alerting hook fires ONCE. It does not re-fire on every poll while depth remains above threshold.
- GIVEN a scheduler lag threshold is configured, WHEN the scheduler detects its actual poll interval exceeds the threshold (e.g. due to lock contention), THEN the alerting hook fires.
- Failed alert deliveries are retried 3 times with exponential backoff; after 3 failures, the failure is logged (OBS-01) but no further action is taken.

**See:** OBS-05 (DLQ depth monitored here), SCH-02 (scheduler lag source), EXT-02 (subscription pause notified via this mechanism)

**Edge cases:**
- Multiple instances simultaneously entering ERROR state: one alert per instance (not one aggregate alert).
- DLQ depth drops below threshold then rises again: hook fires again on the second crossing.
