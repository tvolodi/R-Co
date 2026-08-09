# ISS-0115 / GH-378 — Task claim and group authorization behavior violates integration expectations

## Scope

GH-378 / ISS-0115 alleges that task claim and completion behavior does not
consistently enforce: (1) exactly one concurrency winner on double-claim,
(2) pending-state-only claim, (3) claimed-user-only completion, (4)
consistent group-membership evaluation across claim and completion. Named
failing tests: `TC-ISS-102-02`, `TC-ISS-102-04`, `TC-ISS-102-05`,
`TC-ISS-102-08`, `TC-IDN-02-06`, `TC-IDN-02-07`.

## Finding: already resolved on `main`

This is a **verification-only** WF-03 pass. All 6 named tests, plus their
sibling tests in the same two files (15 tests total: 8 in
`tests/integration/iss102_claim_test.zig`, 7 in
`tests/integration/idn02_group_management_test.zig`), pass repeatedly
against a live PostgreSQL database on current `main` (commit `db68a6e` at
the time this diagnosis was written). Evidence:

```
$ zig build test-integration-iss102 --summary all   (x6 consecutive runs)
Build Summary: 6/6 steps succeeded; 8/8 tests passed

$ zig build test-integration-idn02 --summary all     (x6 consecutive runs)
Build Summary: 6/6 steps succeeded; 7/7 tests passed
```

`test-integration-idn02` did not previously exist as a narrow `build.zig`
target — `tests/integration/idn02_group_management_test.zig` was only
reachable via the full `tests/integration/main_test.zig` aggregate
(`zig build test-integration`). This design adds a dedicated
`test-integration-idn02` step (mirroring the existing
`test-integration-iss102` pattern) so this cluster has the same fast,
isolated regression coverage the other resolved ISS/GH clusters have. This
is the only `build.zig` change — no production logic changes are
introduced by this fix, because none are needed.

## Root cause of the original (2026-08-01) failures — two prior, separate fixes

The evidence cited in the original ISS-0115 report
(`scratch/WF03-gh364-20260801-step03e/_integration_final.log`) was captured
during a full-suite run on 2026-08-01, before two later commits corrected
the actual defects:

### 1. `TC-IDN-02-06` / `TC-IDN-02-07` — fixed by ISS-0619 (GH-568, commit `eea8b9f`, 2026-08-08)

`src/api/routes/tasks.zig` `handleComplete`'s Branch 3 (unclaimed
GROUP-assigned task, TASK_WORKER actor) unconditionally denied completion
regardless of group membership:

```zig
// Branch 3: GROUP/ROLE pool task, not yet claimed — deny.
break :blk false;
```

This directly violated IDN-02's acceptance criterion "Task assignment with
`assignee_type = GROUP` allows any ACTIVE member of the group to claim and
complete the task" and ISS-0115's AC-3 ("Group membership is evaluated
consistently for claim and completion"). ISS-0619 replaced the
unconditional deny with a live membership check via
`identity.canClaimGroupTask(...)` (see `src/api/routes/tasks.zig` current
Branch 3, `src/design/iss-0619-group-tasks-fix.md`). This is the code now
present on `main` and exercised by both target tests.

A companion defect in `src/tasks/store.zig` `listCursor`'s GROUP clause
(`gm.group_id = tasks.assignee_ref` comparing UUID to TEXT, C42883) was
fixed in the same commit by casting `tasks.assignee_ref::uuid` inside the
`EXISTS` subquery. That defect affected `GET /tasks` list filtering, not
the claim/complete paths directly, but is part of the same authorization
surface and is now consistent.

### 2. `TC-ISS-102-02/04/05/08` — most likely explained by ISS-0124 (GH-390, commit `3bc063b`, 2026-08-02)

These four tests exercise `TaskStore.claimTask` and
`task_routes.handleComplete` directly — both already implemented the
correct atomic-CAS and ownership-check model at the time of the 2026-08-01
failing run (see `src/tasks/store.zig` `claimTask`, added by the original
ISS-102 fix, commit `c0b6f01`). `claimTask` performs a single-statement
conditional `UPDATE ... WHERE claimed_by IS NULL AND status = 'PENDING'
RETURNING ...`, which is the atomic compare-and-swap ISS-0115's AC-1 and
AC-2 require — there is no separate SELECT-then-UPDATE race.

The most plausible mechanism for the 2026-08-01 failures in this cluster is
infrastructure-level: the same full-suite run diagnosed and fixed 15+
PostgreSQL C42883 (`operator does not exist: text = integer` /
`uuid = text`) errors across 8 files in ISS-0124/GH-390, one day after
ISS-0115 was filed and from the same failing suite run's log window. A
query-level C42883 error surfaces to the Zig caller as a generic
`PoolError.QueryFailed` → `TaskError.InvalidInput` /
`ClaimError.InvalidInput`, which does not distinguish itself from a "real"
logic failure in a first-pass log read — consistent with why the original
report's root-cause field was left "TBD. Exact implementation divergence
remains TBD." This diagnosis pass re-ran the exact test files against a
current, healthy test database (`BPM_TEST_DB_URL` on port 5453, migrations
current) six times each with zero failures, including the concurrency test
(`TC-ISS-102-02`, two real OS threads racing `claimTask` against the same
row) — consistent with the underlying atomicity already being correct and
the original failures being transient/environmental rather than a logic
defect in `claimTask` itself.

No further production code changes are identified as necessary. The
`claimTask` atomic UPDATE and the `handleComplete` three-branch ownership
check (claimed_by-only → USER-assignee → GROUP-membership) already satisfy
all four ISS-0115 acceptance criteria as written, verified by direct test
execution rather than by code reading alone.

## Acceptance criteria mapping

| ISS-0115 AC | Verified by | Status |
|---|---|---|
| Concurrent claims produce exactly one winner and deterministic loser outcomes | `TC-ISS-102-02` (two real threads race `claimTask`) — passed 6/6 runs | PASS |
| Only pending tasks can be claimed, and only the authorized claimed user can complete them | `TC-ISS-102-01/03/04/05/06/07/08` — passed 6/6 runs | PASS |
| Group membership is evaluated consistently for claim and completion | `TC-IDN-02-06/07` — passed 6/6 runs | PASS |
| All affected cases pass repeatedly without weakening authorization assertions | All 15 tests across both files, 6 consecutive runs each, zero assertion changes made | PASS |

No test assertion in either file was loosened or removed. No production
authorization check was widened beyond what ISS-0619 already established
(claimed_by-only completion; USER-assignee completion; GROUP-membership
completion for unclaimed group-pool tasks). No new files beyond `build.zig`
(additive test target) and documentation/bookkeeping artifacts are
modified by this fix.

## Files changed by this fix

- `build.zig` — add `test-integration-idn02` narrow step (additive; no
  existing step's behavior changes).

## Out of scope (filed separately if found)

None found. No incidental defects were discovered while diagnosing this
issue.
