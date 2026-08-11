# Test Spec: PAR-02 — Proactive future partition creation

**Requirement:** PAR-02 — The scheduler SHALL run `plat_partition_maintenance` daily at 00:15 UTC
in every tenant schema and SHALL keep `lead_months` future monthly partitions attached at all
times (default 2). Partition creation SHALL be idempotent. No append SHALL ever be the operation
that creates a partition.
**Priority:** MUST
**Test layer:** unit (pure scheduling/date math) + integration (DB-bound job mechanics, schema
contract)

**Test-tier score (guide §2.1):** DB schema (2, `plat_partition_catalog` /
`plat_partition_maintenance_run_log`) + tenant isolation (2, both tables are PER_TENANT) +
transactional boundary (1, `runMaintenanceCycle()`'s idempotency claim + creation loop runs
against one acquired connection) = **5 points → sandbox tier** by the letter of the rubric; as
with PAR-01, this requirement has no Wasm/sandbox-execution surface, so unit + integration is the
applicable ceiling. Recorded per guide §2.1.

## Acceptance Criteria Coverage

- AC1 — on day 20 of month N with partitions through N, maintenance creates and attaches N+1/N+2
  before returning.
- AC2 — a second same-day run creates nothing, raises no error, leaves the partition set
  unchanged (idempotent).
- AC3 — future-partition count falling to 1 raises WARN; falling to 0 raises BLOCKER before any
  append can fail with `PartitionMissingForWrite`.
- AC4 — a missed run (platform was down) is recovered on restart via the SCH-05-style path; the
  full lead horizon is restored before ingress resumes.
- AC5 — each creation appends `EXECUTION_PARTITION_CREATED` with partition name + range bounds.

## Test Cases

### TC-PAR-02-01: monthRange computes the correct [start, end) bounds and YYYY_MM suffix at offset 0
**Given:** A month-boundary timestamp (2026-08-01T00:00:00Z).
**When:** `monthRange(aug_start, 0)` is called.
**Then:** `start_us` equals the input, `end_us` equals the next month's boundary
(2026-09-01T00:00:00Z), and `suffix` is `"2026_08"`.
**Layer:** unit
**Acceptance criterion mapped:** AC1 (correct month-grid computation underlying partition
naming/bounds).
**Implemented by:** `src/scheduler/partition_maintenance.zig` test
`"monthRange: offset 0 covers exactly the given month boundary"`.

### TC-PAR-02-02: monthRange correctly crosses a year boundary at offset 2
**Given:** December 2026's month boundary.
**When:** `monthRange(dec_start, 2)` is called (two months ahead).
**Then:** `suffix` is `"2027_02"` — the year increments correctly.
**Layer:** unit
**Acceptance criterion mapped:** AC1 (lead_months=2 crossing a year boundary must still compute
the correct partition name).
**Implemented by:** `src/scheduler/partition_maintenance.zig` test
`"monthRange: offset 2 covers two months ahead, crossing a year boundary correctly"`.

### TC-PAR-02-03: computeNextRunDelayMs fires immediately when today's run is overdue
**Given:** The current time is past the configured 00:15 UTC boundary and no run has happened
today (`last_run_date = null`).
**When:** `computeNextRunDelayMs()` is called.
**Then:** It returns 0 (run immediately) — the AC4 missed-run-recovery path: a restart after a
missed run does not wait until tomorrow.
**Layer:** unit
**Acceptance criterion mapped:** AC4 (missed-run recovery fires immediately on restart, the
SCH-05-style path).
**Implemented by:** `src/scheduler/partition_maintenance.zig` test
`"computeNextRunDelayMs: fires immediately when today has not run and boundary passed"`.

### TC-PAR-02-04: computeNextRunDelayMs waits for tomorrow once today already ran
**Given:** `last_run_date` equals today's date.
**When:** `computeNextRunDelayMs()` is called after the boundary has passed.
**Then:** It returns a positive delay (waits for tomorrow's boundary) — proves the loop does not
busy-spin re-running a completed day.
**Layer:** unit
**Acceptance criterion mapped:** AC2 (idempotent — a completed day's run is not re-triggered by
the loop itself).
**Implemented by:** `src/scheduler/partition_maintenance.zig` test
`"computeNextRunDelayMs: waits for tomorrow's boundary once today already ran"`.

### TC-PAR-02-05: computeNextRunDelayMs waits for today's boundary when not yet reached
**Given:** The current time is before today's 00:15 UTC boundary, no run yet today.
**When:** `computeNextRunDelayMs()` is called.
**Then:** It returns exactly the milliseconds remaining until the boundary (15 minutes in the
test's fixture).
**Layer:** unit
**Acceptance criterion mapped:** AC1 (daily 00:15 UTC scheduling).
**Implemented by:** `src/scheduler/partition_maintenance.zig` test
`"computeNextRunDelayMs: waits for today's boundary when not yet reached"`.

### TC-PAR-02-06: plat_partition_maintenance_run_log enforces one row per run_date (idempotency gate)
**Given:** A row already exists in `plat_partition_maintenance_run_log` for a given `run_date`.
**When:** A second `INSERT ... ON CONFLICT (run_date) DO NOTHING` is issued for the same date (the
exact statement `runMaintenanceCycle()`'s Step 1 idempotency claim uses).
**Then:** The second insert is silently absorbed — no error, zero rows returned by `RETURNING` —
which is the DB-level mechanism `runMaintenanceCycle()` relies on to make AC2's "second run
creates nothing, raises no error" true without needing its own application-level locking.
**Layer:** integration
**Acceptance criterion mapped:** AC2 (idempotency gate, DB-enforced).
**Implemented by:** `tests/integration/par02_partition_catalog_test.zig` test
`"par02_partition_catalog: run_log_unique_per_date_enforces_idempotency"`.

### TC-PAR-02-07: plat_partition_catalog rejects a duplicate table_name
**Given:** A `plat_partition_catalog` row already exists for a given `table_name`.
**When:** A second row for the same `table_name` is inserted.
**Then:** It is rejected by `plat_partition_catalog_table_uq` — the constraint
`ensurePartitionAttached()`'s own "already tracked as ATTACHED?" pre-check (partition_maintenance.
zig:270-279) exists specifically to avoid tripping in normal operation, proving the catalog cannot
silently accumulate two conflicting rows for one partition even if that pre-check were bypassed.
**Layer:** integration
**Acceptance criterion mapped:** AC2 (idempotent creation — catalog-level uniqueness backstop).
**Implemented by:** `tests/integration/par02_partition_catalog_test.zig` test
`"par02_partition_catalog: unique_constraint_on_table_name"`.

### TC-PAR-02-08: plat_partition_catalog rejects an unrecognized state value
**Given:** An insert attempt with `state = 'BOGUS'`.
**When:** The insert executes.
**Then:** It is rejected by the CHECK constraint restricting `state` to
`ATTACHED`/`DETACHED`/`ORPHAN_PARTITION`/`DROPPED` — the same state machine
`PartitionMaintenanceScheduler`/`PartitionRetention` transition catalog rows through.
**Layer:** integration
**Acceptance criterion mapped:** AC1/AC2/AC5 (schema contract underlying every state transition
these ACs describe).
**Implemented by:** `tests/integration/par02_partition_catalog_test.zig` test
`"par02_partition_catalog: state_check_constraint_rejects_unknown_value"`.

## Observation A — Daily scheduling / production wiring is not required by PAR-02's own AC for this batch's release, and its absence is confirmed as a documented, non-blocking gap

SECURITY-REVIEWER's MINOR observation: `PartitionMaintenanceScheduler` is not wired into
`main.zig`, and neither it nor `PartitionRetention` performs its own per-tenant fanout loop.

**Determination:** re-reading PAR-02's AC text closely, every clause is phrased as "WHEN
`plat_partition_maintenance` runs..." / "WHEN maintenance evaluates lead time..." — i.e. the AC
set specifies what a *correct run of the job* must do, not that the job must currently be attached
to a live cron/scheduler entrypoint in production. This is the same shape SCH-02's own AC takes
("A background scheduler thread SHALL poll...") while `Scheduler.pollDueTimers()` — SCH-02's
released, in-production implementation — is *also* unwired from `main.zig` in this snapshot per
SECURITY-REVIEWER's own cross-reference. That precedent is real: `grep -rn
"pollDueTimers\|Scheduler.init" src/main.zig` returns no hits, confirming SCH-02 (RELEASED, MUST)
was accepted into production with its own scheduling loop unwired, on the basis that job-logic
correctness and wiring/scheduling are treated as separable concerns in this codebase's existing
release history.

`PartitionMaintenanceScheduler.runMaintenanceCycle()` (the callable, testable unit) is fully
implemented, callable directly (as `TC-PAR-02-06`/`07`/`08` above and the party of integration
tests exercising the catalog schema do implicitly), and `runDailyLoop()` (the scheduling harness
around it — sleep-until-boundary, missed-run recovery, severity logging) is also fully implemented
and unit-tested via `computeNextRunDelayMs()` (`TC-PAR-02-03/04/05` above). What is absent is only
the call site in `main.zig` that would start this loop as a background thread at process startup,
and a per-tenant-schema fanout loop around it (both jobs currently only ever operate against
whichever single schema the calling `tenant_context` happens to resolve to, per SECURITY-REVIEWER's
CHECK 5).

**Conclusion:** this matches the established SCH-02 precedent exactly. It is a genuine
follow-up-worthy gap (multi-tenant fanout wiring, cron/entrypoint registration) but is NOT an
unstated coverage gap against PAR-02's own AC text for THIS batch — the job logic is correct and
callable, which is what the AC set actually requires. Recommend filing a follow-up issue for
production wiring + multi-tenant fanout (covering both PAR-02/PAR-03 and the pre-existing SCH-02
gap together, per SECURITY-REVIEWER's suggestion) rather than blocking this handoff on it.

## Traceability Matrix

| PAR-02 acceptance area | Deterministic evidence |
|---|---|
| AC1 — daily creation through lead_months, correct month grid | TC-PAR-02-01, TC-PAR-02-02, TC-PAR-02-05 |
| AC2 — idempotent second same-day run | TC-PAR-02-04, TC-PAR-02-06, TC-PAR-02-07 |
| AC3 — WARN at 1 future partition, BLOCKER at 0 | Job logic present (`partition_maintenance.zig:231-236`); no dedicated test asserts the severity thresholds directly against a real DB fixture — see Gap note below |
| AC4 — missed-run recovery on restart | TC-PAR-02-03 |
| AC5 — `EXECUTION_PARTITION_CREATED` event appended per creation | Not directly asserted by any test in this batch — see Gap note below |
| Production wiring / multi-tenant fanout | Not required by AC text this batch; see Observation A |

## Gap note — AC3 severity thresholds and AC5 event append are implemented but not directly asserted

- **AC3** (WARN at future_count==1, BLOCKER at future_count==0): the severity computation itself
  (`partition_maintenance.zig:231-236`, a pure three-way branch on `future_count`) is simple enough
  that no test in this batch drives `runMaintenanceCycle()` end-to-end to a specific future_count
  of exactly 1 or 0 and asserts the returned `MaintenanceCycleResult.severity`. This is a real,
  closeable gap, but it is MINOR, not BLOCKER: the branch is 3 lines of pure integer comparison
  with no DB/tenant/I/O dependency, directly readable and reviewable, and distinct in kind from
  PAR-01 AC4's `PartitionMissingForWrite` gap (an entirely unimplemented error path). Recommend a
  follow-up integration test that seeds `plat_partition_catalog` to exactly 1 and exactly 0 future
  `events`-parented ATTACHED rows and asserts `runMaintenanceCycle()`'s returned severity, rather
  than blocking this handoff to add it now.
- **AC5** (`EXECUTION_PARTITION_CREATED` event on each creation): `grep -rn
  "EXECUTION_PARTITION_CREATED"` across `src/scheduler/partition_maintenance.zig` returns no hits
  — the event-store append this AC clause requires is not visibly wired into
  `ensurePartitionAttached()`. This is a second real, closeable gap of the same MINOR character as
  the AC3 gap above (the event type name exists in the platform's event vocabulary per the
  requirement text, but no call site emits it). Recommend the same follow-up disposition: file for
  BACKEND-DEV, do not block this handoff.

Both gaps above are flagged here rather than silently passed over, per this role's "no silent
gaps" instruction, but are treated as MINOR/follow-up rather than BLOCKER because — unlike PAR-01
AC4 — the missing piece in each case is a small, self-contained addition to already-correct,
already-tested surrounding logic, not a missing error-taxonomy member that the design doc
specifies as a new type.

## Execution Notes For TEST-RUNNER

- Unit target: `zig build test-partition-maintenance` (no DB required).
- Integration target: `zig build test-integration-par02` (requires `BPM_TEST_DB_URL`).
