> An internal emit runs inside a step transaction and has no response to write, so it SHALL NOT be refused with a status code. When outbox depth is at or above the cap, `outbox.emit()` SHALL return the typed error `error.OutboxOverflow`, no outbox row SHALL be inserted, the step transaction SHALL roll back, and the node's configured retry policy and the existing dead letter path SHALL handle it. `OutboxOverflow` SHALL appear in the declared error set of `outbox.emit()` and of every caller.

**Acceptance Criteria:**
- GIVEN depth is at the cap, WHEN a SERVICE_TASK step calls `outbox.emit()`, THEN it returns `error.OutboxOverflow`, no row is inserted into `plat_outbox`, and every other write of that step is discarded by the rollback.
- GIVEN a caller of `outbox.emit()` omits `OutboxOverflow` from its declared error set, WHEN the build runs, THEN it fails with an error-set diagnostic; the variant is never absorbed by `catch unreachable` and never mapped to a generic failure.
- GIVEN a step fails with `OutboxOverflow`, WHEN retries are scheduled, THEN the node's existing retry policy and backoff apply unchanged; no separate retry mechanism and no separate rate limiter is introduced for this path.
- GIVEN a runaway producer, WHEN its steps fail and back off, THEN its own emit rate falls, so the producer throttles itself while the drainer catches up.
- GIVEN retry attempts are exhausted while depth stays at the cap, WHEN the step is dead-lettered, THEN the instance transitions to `failed` and the dead letter entry carries `OutboxOverflow`, the attempt count, and the depth observed at each attempt.
- GIVEN a dead-lettered instance is retried after the gate reopens, WHEN it resumes, THEN it runs against the definition version pinned at instance start (PD-08).

**See:** OBP-01, OBP-02 (the external counterpart), OBP-04, OBS-05 (dead letter queue), PD-08 (the pinned version used on retry)
