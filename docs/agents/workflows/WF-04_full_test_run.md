# WF-04 — Full Test Run

**Version:** 0.3 · 2026-05-26  
**Trigger:** Pre-release gate, scheduled CI run, or explicit operator request  
**Owner:** `ORCH`

**Git protocol:** WF-04 itself runs Step 00 (`docs/agents/protocols/GIT_SETUP.md`) exactly
once, at the start, and Step Final (`docs/agents/protocols/GIT_MERGE.md`) exactly once, at
the end. Every failure any step surfaces — unit, integration, frontend, E2E, NFR,
coverage — is **enqueued** onto this one run's `handoffs/<run_id>/issue_queue.json` and
drained via WF-03 Steps 1–7 **on this same branch**, per
`docs/agents/protocols/ISSUE_QUEUE.md` (§8c of `ORCHESTRATOR.md`). WF-03 is never
re-entered at its own Step 00 from inside a WF-04 run — see **WF-03 Spawning Rule**
below, which now describes queueing, not nested branching.

---

## ⛔ Mandatory Rule for All Steps

**Every agent completing a step in this workflow MUST call `fn:register-inner-report` immediately before `fn:complete-handoff`.** This is not optional. An agent that calls `fn:complete-handoff` without first calling `fn:register-inner-report` has violated the workflow.

Step workflow chain template:
```
... (agent work) ... → fn:validate-completeness → fn:register-inner-report → fn:complete-handoff
```

---

## Overview

```
[INPUT: stage to validate, or "all"]
          │
          ▼
┌─────────────────────────┐
│  STEP 00: GIT SETUP     │ ← BACKEND-DEV
│  pull → branch → push   │   fn:git-setup; creates handoffs/<run_id>/issue_queue.json
│  Runs ONCE for the       │   (empty) immediately after PASS
│  whole WF-04 run         │
└──────────┬──────────────┘
          │ PASS
          ▼
┌─────────────────────────┐
│  STEP 1: BUILD CHECK    │ ← TEST-RUNNER
│  Compile backend +      │
│  frontend               │
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Route to BACKEND-DEV or FRONTEND-DEV (REWORK)
           │          Then restart STEP 1
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 2: UNIT TESTS     │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Enqueue + drain (WF-03 Steps 1-7, same branch); return to STEP 2
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 3: INTEGRATION    │ ← TEST-RUNNER
│  TESTS                  │
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Enqueue + drain (WF-03 Steps 1-7, same branch); return to STEP 3
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 4: FRONTEND TESTS │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Enqueue + drain (WF-03 Steps 1-7, same branch); return to STEP 4
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 5: E2E TESTS      │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Enqueue + drain (WF-03 Steps 1-7, same branch); return to STEP 5
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 6: NFR BENCHMARKS │ ← RELEASE-VALIDATOR
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Route to BACKEND-DEV (performance); return to STEP 6
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 7: COVERAGE CHECK │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Route to TEST-DESIGNER (add missing tests); return to STEP 7
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 8: FULL REPORT    │ ← TEST-RUNNER + RELEASE-VALIDATOR
└──────────┬──────────────┘
           │
           ▼
┌─────────────────────────┐
│  QUEUE CHECK            │ ← ORCH — any QUEUED items left in issue_queue.json?
└──────────┬──────────────┘
           │
    MORE QUEUED? ── YES ──► Drain oldest (WF-03 Steps 1-7, same branch); re-check
           │
           NO
           │
           ▼
┌─────────────────────────┐
│  STEP FINAL: GIT MERGE  │ ← BACKEND-DEV — same agent as Step 00
│  rebase → PR → merge    │   fn:git-merge; runs ONCE, after queue is empty
└──────────┬──────────────┘
           │ PASS
           ▼
[OUTPUT: Consolidated test report; release decision; feature/<run-id> squash-merged]
```

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV`
**Protocol:** `docs/agents/protocols/GIT_SETUP.md`
**Runs exactly once per WF-04 run**, before Step 1.

ORCH supplies `context.branch_name = "feature/WF04-<stage>-<timestamp>"`. Follow
GIT_SETUP.md exactly. On PASS, ORCH creates `handoffs/<run_id>/issue_queue.json`
(`items: []`) per `docs/agents/protocols/ISSUE_QUEUE.md`, then routes to Step 1. Every
failure surfaced anywhere in Steps 1–8 is drained onto this one queue and this one
branch — see **Issue Queue Draining Rule** below.

---

## Step 1 — Build Check

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:check-zig-build`, `fn:check-frontend-build`, `fn:check-frontend-types`

```
1. → fn:check-zig-build
2. → fn:check-frontend-types
3. → fn:check-frontend-build
4. If any FAIL: status = FAIL with error details
   ORCH routes to BACKEND-DEV or FRONTEND-DEV based on which build failed
5. → fn:complete-handoff
```

---

## Step 2 — Unit Tests

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-unit-tests`

```
1. → fn:run-unit-tests (no module filter — run all)
2. Classify failures:
   - BLOCKER: test covers a MUST requirement
   - MAJOR: test covers a SHOULD requirement
   - MINOR: other
3. If BLOCKER or MAJOR failures: status = FAIL
4. → fn:complete-handoff
   On FAIL: ORCH enqueues the failure list (ISSUE_QUEUE.md) and drains it via WF-03
   Steps 1-7 on this run's existing branch; WF-04 resumes at this step once drained
```

---

## Step 3 — Integration Tests

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-integration-tests`

```
PRE-CONDITION: Test PostgreSQL database running; migrations applied
1. → fn:run-integration-tests
2. Classify failures as in Step 2
3. Pay special attention to:
   - Idempotency tests (ES-03)
   - Transaction atomicity (DB-03)
   - Concurrency tests (EE-12, scheduler)
4. → fn:complete-handoff (PASS/FAIL)
   On FAIL: ORCH enqueues (ISSUE_QUEUE.md) and drains via WF-03 Steps 1-7, same branch
```

### Test-database lifecycle policy (ISS-0090)

`db_test` (the `bpm_test` Postgres container) is **long-lived, not ephemeral-per-run** — it is not torn down between sessions, and its data volume survives ordinary `docker-compose down`/`up` cycles. The chosen policy is a **scripted reset before every integration run**, not a full container rebuild:

- `zig build test-integration` (and every other `test_integration_*` build step) depends on the `clean-test-db` step, which runs `tools/clean_test_db.py` automatically before tests execute — no manual step is required in the normal case.
- `clean_test_db.py` truncates transient business tables (both `public` and `tenant_default`), deletes test/non-default tenant rows, and — as of ISS-0090 — sweeps `public.tenant_schemas` to `DROP SCHEMA ... CASCADE` every per-test tenant schema except `tenant_default`, clearing their `tenant_schemas`/`schema_migrations` rows too. This closes the orphaned-schema leak where a killed/timed-out test skips its `defer cleanupTenant()`.
- `schema_migrations` (and `tenant_default`'s own per-schema tracking) is deliberately **not** wiped by the reset — this is what lets migrations stay skip-on-already-applied instead of re-running non-idempotent DDL against a container that already has it.
- A full destructive rebuild (`docker-compose down -v db_test && docker-compose up -d db_test && zig build migrate`) remains available as a manual escape hatch for drift that the scripted reset cannot fix (e.g. a corrupted volume), but is not part of the standard per-run flow and is not automated — TEST-RUNNER must not invoke `down -v` itself.

---

## Step 4 — Frontend Unit Tests

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-frontend-unit-tests`

```
1. → fn:run-frontend-unit-tests (no path filter — run all)
2. Classify failures
3. → fn:complete-handoff (PASS/FAIL)
   On FAIL: ORCH enqueues (ISSUE_QUEUE.md) and drains via WF-03 Steps 1-7, same branch
```

---

## Step 5 — E2E Tests

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-e2e-tests`

```
PRE-CONDITION: Full stack running (backend on :8080, frontend on :5173, test DB)
ORCH is responsible for verifying the stack is up before routing to this step.

1. → fn:run-e2e-tests
2. A failing E2E test is BLOCKER only if it covers a critical journey listed in
   test_developer_guide.md §7.1 for the stage under test
3. → fn:complete-handoff (PASS/FAIL)
   On FAIL: ORCH enqueues (ISSUE_QUEUE.md) and drains via WF-03 Steps 1-7, same branch
             (E2E failures may be frontend or backend — include Playwright screenshots
             in artifacts_out for diagnosis)
```

---

## Step 6 — NFR Benchmarks

**Agent:** `RELEASE-VALIDATOR`  
**Functions:** `fn:run-nfr-benchmarks`

```
1. → fn:run-nfr-benchmarks
2. NFR benchmark results:
   NFR-01: p99 read ≤ 200ms; p99 write ≤ 500ms
   NFR-02: event append ≥ 1,000/sec sustained
   NFR-04: 10,000-event replay ≤ 5 seconds
3. Any NFR failure = BLOCKER; cannot release
4. → fn:complete-handoff
   On FAIL: ORCH routes to BACKEND-DEV with benchmark profile data
            (Note to ORCH: NFR fixes may require CODE-DESIGNER redesign — use judgment)
```

---

## Step 7 — Coverage Check

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:check-code-coverage`, `fn:load-test-specs`

```
1. → fn:check-code-coverage
2. → fn:load-test-specs (all requirement IDs for the stage under test)
3. Verify: every MUST requirement has at least one passing test case in test specs
4. If coverage below threshold OR missing test specs for MUST requirements:
   status = FAIL
   ORCH routes to TEST-DESIGNER to add missing tests
5. → fn:complete-handoff
```

---

## Step 8 — Full Report & Release Decision

**Agent:** `TEST-RUNNER` (compiles report) + `RELEASE-VALIDATOR` (makes release decision)

### TEST-RUNNER procedure

```
1. Aggregate all step reports from Steps 1–7
2. → fn:write-test-report (full combined report)
   Output: tests/reports/report-<date>-WF04-<stage>.json
```

### RELEASE-VALIDATOR procedure

```
1. Read the full report
2. → fn:load-requirement-status (verify all MUST requirements for stage = TESTED)
3. → fn:check-doc-freshness
4. Produce release decision:
   {
     stage: "Stage N",
     decision: "RELEASE" | "BLOCK",
     blockers: [...],       // must be empty for RELEASE
     major_issues: [...],   // documented, not blocking
     recommendation: "..."
   }
5. Write decision to docs/status/release-<stage>-<date>.json
6. → fn:complete-handoff (status: PASS if RELEASE, FAIL if BLOCK)
```

**Release is BLOCKED if any of the following are true:**
- Any BLOCKER test failure remains open
- Any NFR benchmark fails
- Any MUST requirement for the stage is not in TESTED or RELEASED status
- Coverage thresholds are not met

---

## Queue Check (between Step 8 and Step Final)

**Owner:** `ORCH`

```
1. Read handoffs/<run_id>/issue_queue.json.
2. If any item has status QUEUED: pop the oldest, set IN_PROGRESS, stamp started_at, and
   drain it via WF-03 Steps 1-7 on THIS run's existing branch (no new Step 00). Resume
   WF-04 at whichever step the drained issue came from once it reaches DRAINED.
3. If no QUEUED items remain: proceed to Step Final.
```

Full mechanism: `docs/agents/protocols/ISSUE_QUEUE.md`.

---

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` — same agent as Step 00
**Protocol:** `docs/agents/protocols/GIT_MERGE.md`
**Runs exactly once**, after the Queue Check above finds no QUEUED items remaining.

Use the RELEASE-VALIDATOR Step 8 decision summary as the commit and PR one-line summary.
List every `ISS-NNNN` drained during the run in the PR body alongside the release
decision. Follow GIT_MERGE.md exactly.

---

## Issue Queue Draining Rule (formerly "WF-03 Spawning Rule")

When any step in WF-04 fails and the failure is a code/test issue (not a config issue),
`ORCH` no longer spawns WF-03 as a separate branched sub-workflow. Instead it enqueues
the failure onto **this WF-04 run's own** `handoffs/<run_id>/issue_queue.json` (created
once, at WF-04's own Step 00) and drains it in place:

```
ORCH:
  1. File the issue (ISS file + mandatory GitHub issue, per WF-03 Step 0.5 — unchanged)
     and → fn:enqueue-issue onto handoffs/<run_id>/issue_queue.json.

  2. Drain per docs/agents/protocols/ISSUE_QUEUE.md: re-enter WF-03 at Step 1 (Diagnose)
     for this issue, on WF-04's EXISTING branch — WF-03's own Step 00 does NOT run.
     Run WF-03 Steps 1 → 2 → 2b → 3 → (4 → 4b) → 5 → 6 → 7.

  3. On drain PASS (item reaches DRAINED): resume WF-04 at the step that failed.
  4. On rework exhaustion (item reaches ESCALATED): pause WF-04; surface for human review.
  5. Repeat for every item the drain itself surfaces (any depth) before resuming WF-04.
```

The WF-04 step counter does NOT reset when an issue is drained. WF-04 resumes at the
exact step it left, once the queue has no QUEUED/IN_PROGRESS items blocking that step.

**Direct routing to dev agents (Steps 6, 7):** NFR performance fixes (Step 6) and
coverage gaps (Step 7) are enqueued and drained the same way — **not** wrapped with their
own Step 00/Step Final. They land as ordinary commits on WF-04's one branch, same as any
other drained issue. (The `feature/WF04-nfr-*` / `feature/WF04-cov-*` branch-naming
convention that previously existed for these is retired — there is only ever the one
`feature/<run-id>` branch for the whole WF-04 run.)

`owned_modules` for the WF-04 run is recorded once, at its own Step 00, and covers every
issue drained during the run — see ISSUE_QUEUE.md "owned_modules — no new lock per queue
item" and ORCHESTRATOR.md §10. Deconfliction against a *separate, concurrent* WF-02 run
(a different top-level run entirely) is unchanged.

---

## Scheduled vs Pre-Release Modes

| Mode | Trigger | Scope | NFR benchmarks |
|---|---|---|---|
| **Scheduled** (CI) | Daily / per commit | All passing stages | Skipped (run weekly only) |
| **Pre-release** | Manual by ORCH before releasing a stage | Stage N being released | Always run |
| **Full validation** | Quarterly or after major refactor | All stages | Always run |
