# Test Spec: ISS-302 — Startup Sweep Advisory Lock

**Requirement ID:** ISS-302  
**Module:** `src/scheduler/scheduler.zig`  
**Design artifact:** `src/design/scheduler-concurrency-epic3.md`  
**Status:** TEST-DESIGNED

---

## Requirement summary

When multiple HA scheduler nodes start simultaneously, each has `is_startup_sweep = true`
and would each sweep all past-due timers. While SKIP LOCKED prevents double-firing, the
duplicate sweep work generates confusing log noise. ISS-302 ensures exactly one node runs
the startup sweep by gating the sweep loop behind a PostgreSQL session-level advisory lock
(`SCHEDULER_STARTUP_LOCK_ID = 5863412975429063421`).

**Protocol:**
1. When `is_startup_sweep = true`, acquire the session-level lock via `pg_try_advisory_lock`.
2. If lock NOT acquired: log WARN, set `is_startup_sweep = false`, fall through to normal polling.
3. If lock acquired: run existing sweep while loop; release lock after loop completes.
4. `is_startup_sweep` is set to `false` at end of `pollDueTimers` regardless.

---

## Acceptance criteria

| ID | Criterion |
|----|-----------|
| AC-302-1 | `SCHEDULER_STARTUP_LOCK_ID` compile-time constant equals `5863412975429063421` |
| AC-302-2 | When `is_startup_sweep = true` and lock is acquired, `pollDueTimers` runs the timer sweep loop normally and `is_startup_sweep` is `false` afterward |
| AC-302-3 | When `is_startup_sweep = true` and lock is NOT acquired, sweep is skipped, `is_startup_sweep` is set to `false`, and normal polling continues |
| AC-302-4 | When `is_startup_sweep = false`, the advisory lock path is bypassed entirely |
| AC-302-5 | `acquireStartupSweepLock` uses `pg_try_advisory_lock` (session-level), not `pg_try_advisory_xact_lock` |

---

## Test cases

### TC-SCH-302-01 — `SCHEDULER_STARTUP_LOCK_ID` constant value (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-302-01 |
| **Type** | Unit |
| **File** | `tests/unit/sch302_startup_sweep_lock_test.zig` |
| **Requirement** | AC-302-1 |
| **Description** | Verify that `SCHEDULER_STARTUP_LOCK_ID` exported via `bpm.scheduler_poller` equals `5863412975429063421`. |
| **Expected outcome** | Value matches exactly; test passes |
| **MUST coverage** | YES |

### TC-SCH-302-02 — `is_startup_sweep` true on fresh init (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-302-02 |
| **Type** | Unit |
| **File** | `tests/unit/sch302_startup_sweep_lock_test.zig` |
| **Requirement** | AC-302-2 |
| **Description** | Create a `Scheduler` with `Scheduler.init(undefined, config)`. Assert `is_startup_sweep` is `true`. This is covered by TC-SCH-05-05a already; this spec entry documents the traceability. |
| **Expected outcome** | `scheduler.is_startup_sweep == true` |
| **MUST coverage** | YES |

### TC-SCH-302-03 — Sweep skipped when lock not acquired: `is_startup_sweep` cleared (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-302-03 |
| **Type** | Unit |
| **File** | `tests/unit/sch302_startup_sweep_lock_test.zig` |
| **Requirement** | AC-302-3 |
| **Description** | Verify that when `is_startup_sweep = true` but the lock is not acquired (another node holds it), `is_startup_sweep` is set to `false` and the fired count in `PollSummary` reflects that no timers were fired via the sweep path. This is tested by inspecting state after a `pollDueTimers` call on an integration DB where the lock is already held. |
| **Expected outcome** | `is_startup_sweep == false`; `summary.fired` counts only normal-poll results |
| **MUST coverage** | YES |

### TC-SCH-302-04 — `acquireStartupSweepLock` uses `pg_try_advisory_lock` not `pg_try_advisory_xact_lock` (unit/source inspection)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-302-04 |
| **Type** | Unit (source inspection) |
| **File** | `tests/unit/sch302_startup_sweep_lock_test.zig` |
| **Requirement** | AC-302-5 |
| **Description** | Assert that the scheduler source contains `pg_try_advisory_lock` and does NOT contain `pg_try_advisory_xact_lock` for the startup lock (ISS-301 already removed the per-timer advisory xact lock). |
| **Expected outcome** | Source contains `pg_try_advisory_lock`; does not contain `pg_try_advisory_xact_lock` |
| **MUST coverage** | YES |

### TC-SCH-302-05 — Normal poll (non-sweep): startup lock path not taken (unit)

| Field | Value |
|-------|-------|
| **Test ID** | TC-SCH-302-05 |
| **Type** | Unit |
| **File** | `tests/unit/sch302_startup_sweep_lock_test.zig` |
| **Requirement** | AC-302-4 |
| **Description** | Create a `Scheduler` and manually set `is_startup_sweep = false`. Call `pollDueTimers` against a real empty DB. Assert no advisory lock query for the startup ID is executed (verified by observing the DB does not hold the lock after the call, or via source inspection that the `if (self.is_startup_sweep)` branch is skipped). Unit-level: just verify `is_startup_sweep` remains `false` after a no-op poll. |
| **Expected outcome** | `is_startup_sweep` stays `false`; no lock acquired |
| **MUST coverage** | YES |

---

## Notes

- `acquireStartupSweepLock` / `releaseStartupSweepLock` are private (`fn`, not `pub fn`).
  Integration verification happens indirectly through `pollDueTimers` behaviour.
- The unit tests in `sch302_startup_sweep_lock_test.zig` that require DB state
  (`is_startup_sweep` cleared after skipped sweep) are in the integration test file
  `sch303_timer_dlq_test.zig` (shared test file for EPIC-3 integration tests).
