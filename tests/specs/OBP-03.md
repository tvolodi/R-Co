# Test Spec: OBP-03 — Typed outbox overflow on internal emit

**Requirement:** OBP-03 — An internal emit runs inside a step transaction and has no response to
write, so it SHALL NOT be refused with a status code. When outbox depth is at or above the cap,
`outbox.emit()` SHALL return the typed error `error.OutboxOverflow`, no outbox row SHALL be
inserted, the step transaction SHALL roll back, and the node's configured retry policy and the
existing dead letter path SHALL handle it. `OutboxOverflow` SHALL appear in the declared error set
of `outbox.emit()` and of every caller.

**Priority:** SHOULD
**Test layer:** unit (pure emit() depth pre-check — no DB) + integration (real `plat_outbox` row
absence; rollback verification; DLQ entry shape with overflow depths; retry-policy pass-through)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, `plat_outbox` is written/not
written based on depth check) + tenant isolation (2, depth cache is per-tenant) + transactional
boundary (1, step rolls back on OutboxOverflow) = **5 points → sandbox tier by rubric** —
unit + integration is the proportionate ceiling.
**Design:** `src/design/obp-03-outbox-overflow.md`
**Implementation:** `src/outbox/emit.zig` (`emit`), `src/effects/queue.zig` (`EffectQueueError`),
DLQ path in `src/dlq/`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN depth is at the cap, WHEN a SERVICE_TASK step calls `outbox.emit()`, THEN it returns `error.OutboxOverflow`, no row is inserted into `plat_outbox`, and every other write of that step is discarded by the rollback. | `TC-OBP-03-AC1-emit-returns-overflow-no-row` (integration) + `obp03: emit returns OutboxOverflow when depth at cap` (unit in `emit.zig`) |
| AC2 | GIVEN a caller of `outbox.emit()` omits `OutboxOverflow` from its declared error set, WHEN the build runs, THEN it fails with an error-set diagnostic. | `TC-OBP-03-AC2-compile-time-enforcement` (unit/compile-time) |
| AC3 | GIVEN a step fails with `OutboxOverflow`, WHEN retries are scheduled, THEN the node's existing retry policy and backoff apply unchanged; no separate retry mechanism or rate limiter is introduced. | `TC-OBP-03-AC3-retry-policy-unchanged` (integration) |
| AC4 | GIVEN a runaway producer, WHEN its steps fail and back off, THEN its own emit rate falls, allowing the drainer to catch up. | `TC-OBP-03-AC4-self-throttle` (integration — depth decreases while producer backs off) |
| AC5 | GIVEN retry attempts are exhausted while depth stays at the cap, WHEN the step is dead-lettered, THEN the DLQ entry carries `OutboxOverflow`, the attempt count, and the depth observed at each attempt. | `TC-OBP-03-AC5-dlq-entry-overflow-depths` (integration) |
| AC6 | GIVEN a dead-lettered instance is retried after the gate reopens, WHEN it resumes, THEN it runs against the definition version pinned at instance start (PD-08). | `TC-OBP-03-AC6-pinned-version-on-retry` (integration) |

---

## Test cases

### TC-OBP-03-AC1-emit-returns-overflow-no-row: emit() returns OutboxOverflow at cap; no plat_outbox row; step rolls back
**Given:** A `DepthCache` with a fresh entry for a per-test tenant at depth = cap (50000). An open
step transaction on a real DB connection. A `EffectSpec` for that tenant.
**When:** `emit(allocator, conn, &cache, cap, spec)` is called.
**Then:** The function returns `error.OutboxOverflow`. No row exists in `plat_outbox` with the
spec's `effect_event_id` (the insert was never attempted). The transaction is still open (caller
rolls it back per their responsibility — tested by verifying a second write in the same txn is
absent after rollback).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-OBP-03-AC1-emit-returns-overflow-no-row` (`tests/integration/obp03_outbox_overflow_test.zig`)

### TC-OBP-03-AC2-compile-time-enforcement: OutboxOverflow must be in caller's error set
**Given:** `EffectQueueError` includes `OutboxOverflow`. `emit()` returns `EffectQueueError`.
**When:** The Zig compiler analyses a caller that does NOT include `OutboxOverflow` in its own
error set (modelled in the test by a comptime `@TypeOf` check or a direct call in a function
whose error union is constrained to not include `OutboxOverflow`).
**Then:** The build fails with an error-set diagnostic. Verified in the unit test by asserting
that `OutboxOverflow` is a member of `EffectQueueError` using `@hasField` / enum check.
**Layer:** unit (compile-time / type inspection — no DB)
**Acceptance criterion mapped:** AC2
**Zig test:** `TC-OBP-03-AC2-compile-time-enforcement` (`tests/integration/obp03_outbox_overflow_test.zig`)

### TC-OBP-03-AC3-retry-policy-unchanged: OutboxOverflow uses the existing retry policy
**Given:** A process instance configured with `max_retries = 2`. The depth cache is at cap.
**When:** The step attempts to emit and receives `OutboxOverflow`; the engine's failure path is
invoked identically to any other `EffectQueueError` step error.
**Then:** The instance retry counter increments by 1 (same as for `PersistenceFailed`). No new
timer or rate-limiter table row is created for this path. The instance status remains `ACTIVE`
until retries are exhausted, at which point it transitions to `failed` (same dead-letter path).
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-OBP-03-AC3-retry-policy-unchanged` (`tests/integration/obp03_outbox_overflow_test.zig`)

### TC-OBP-03-AC4-self-throttle: runaway producer backs off while drainer catches up
**Given:** A `DepthCache` with a fresh entry for a per-test tenant at depth = cap. The producer
tries to emit repeatedly; the drainer calls `writeFresh` with decreasing depths.
**When:** Three `writeFresh` calls lower the depth below the cap (simulating drainer progress).
**Then:** `emit()` continues to return `OutboxOverflow` while depth >= cap. After the third
`writeFresh` (depth < cap), `emit()` succeeds. The producer's emit rate effectively drops to
zero while the depth is at cap — which is the self-throttle property.
**Layer:** integration (uses real `DepthCache` + real `writeFresh` + real `emit`)
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-OBP-03-AC4-self-throttle` (`tests/integration/obp03_outbox_overflow_test.zig`)

### TC-OBP-03-AC5-dlq-entry-overflow-depths: DLQ entry carries OutboxOverflow, attempt count, depth per attempt
**Given:** An instance whose step repeatedly receives `OutboxOverflow` until `max_retries` is
exhausted. The depth observed at each attempt is recorded.
**When:** The engine dead-letters the instance.
**Then:** The `plat_dlq` row (or equivalent) for the instance has `reason = 'OutboxOverflow'`,
`attempt_count = max_retries + 1`, and `depth_per_attempt` JSON array whose length equals
`attempt_count` with each element being the depth observed at that attempt.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-OBP-03-AC5-dlq-entry-overflow-depths` (`tests/integration/obp03_outbox_overflow_test.zig`)

### TC-OBP-03-AC6-pinned-version-on-retry: dead-lettered instance resumes against the pinned definition version
**Given:** An instance dead-lettered with `OutboxOverflow`. The process definition has since been
updated to a new version. The gate has reopened (depth < cap).
**When:** The dead-letter entry is retried (instance re-queued).
**Then:** The instance resumes evaluation against the definition version pinned at instance start
(not the latest version). Verified by checking the `definition_version_id` on the resumed
instance's execution record.
**Layer:** integration
**Acceptance criterion mapped:** AC6
**Zig test:** `TC-OBP-03-AC6-pinned-version-on-retry` (`tests/integration/obp03_outbox_overflow_test.zig`)
