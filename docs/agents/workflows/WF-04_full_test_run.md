# WF-04 — Full Test Run

**Version:** 0.3 · 2026-05-26  
**Trigger:** Pre-release gate, scheduled CI run, or explicit operator request  
**Owner:** `ORCH`

**Git protocol:** WF-04 runs Step 00 (`docs/agents/protocols/GIT_SETUP.md`) exactly once, at
the start, and Step Final (`docs/agents/protocols/GIT_MERGE.md`) exactly once, at the end.

**WF-04 is a reporting gate, not a fixing workflow.** Every failure it surfaces — unit,
integration, frontend, E2E, NFR, coverage — is **filed and forwarded to the global queue**
(`handoffs/global_queue.json`) per `docs/agents/protocols/ISSUE_QUEUE.md` (§8c of
`ORCHESTRATOR.md`), and fixed later in its own WF-03 run with its own branch and PR. WF-04
does not stop to fix what it finds; it completes its sweep, reports, and lets the loop
(`docs/agents/protocols/LOOP_PROTOCOL.md`) work through the queue.

> **Changed 2026-08-06.** WF-04 previously drained every failure inline, on its own branch,
> via repeated WF-03 Steps 1–7 passes before reaching Step Final. That inner loop was
> removed — a full-suite sweep that found 12 failures used to become a single unbounded run
> with 12 unrelated fixes on one branch.

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
│  pull → branch → push   │   fn:git-setup
│  Runs ONCE for the       │
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
     PASS? ├── NO ──► File + forward to global queue; record in report; CONTINUE
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 3: INTEGRATION    │ ← TEST-RUNNER
│  TESTS                  │
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► File + forward to global queue; record in report; CONTINUE
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 4: FRONTEND TESTS │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► File + forward to global queue; record in report; CONTINUE
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 5: E2E TESTS      │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► File + forward to global queue; record in report; CONTINUE
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
│  STEP FINAL: GIT MERGE  │ ← BACKEND-DEV — same agent as Step 00
│  rebase → PR → merge    │   fn:git-merge; runs ONCE, directly after Step 8
└──────────┬──────────────┘
           │ PASS
           ▼
[OUTPUT: Consolidated test report; release decision; every failure filed + queued;
 feature/<run-id> squash-merged]
```

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV`
**Protocol:** `docs/agents/protocols/GIT_SETUP.md`
**Runs exactly once per WF-04 run**, before Step 1.

ORCH supplies `context.branch_name = "feature/WF04-<stage>-<timestamp>"`. Follow
GIT_SETUP.md exactly. On PASS, ORCH routes to Step 1. Do **not** create a
`handoffs/<run_id>/issue_queue.json` — per-run issue queues were removed on 2026-08-06.
Every failure surfaced in Steps 1–8 is filed and forwarded to the global queue — see
**Issue Forwarding Rule** below.

WF-04 may legitimately produce no code changes at all (a fully green sweep changes only
reports). Step Final still runs, committing the run's reports and any forwarded-issue
bookkeeping.

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
   On FAIL: ORCH files each failure cluster (ISS + GitHub issue) and forwards it to the
   global queue (ISSUE_QUEUE.md). WF-04 records the failure in its report and CONTINUES
   to the next step — it does not stop to fix it
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
   On FAIL: ORCH files each failure and forwards it to the global queue (ISSUE_QUEUE.md);
   WF-04 records it in the report and CONTINUES to the next step
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
   On FAIL: ORCH files each failure and forwards it to the global queue (ISSUE_QUEUE.md);
   WF-04 records it in the report and CONTINUES to the next step
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
   On FAIL: ORCH files each failure and forwards it to the global queue (ISSUE_QUEUE.md);
   WF-04 records it in the report and CONTINUES to the next step
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

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` — same agent as Step 00
**Protocol:** `docs/agents/protocols/GIT_MERGE.md`
**Runs exactly once**, directly after Step 8. There is no queue check between them.

Use the RELEASE-VALIDATOR Step 8 decision summary as the commit and PR one-line summary.
List every `ISS-NNNN` this run filed and forwarded in the PR body, alongside the release
decision, so the reviewer sees the full set of findings even though none were fixed here.
Follow GIT_MERGE.md exactly.

---

## Issue Forwarding Rule (formerly "WF-03 Spawning Rule")

When any step in WF-04 fails and the failure is a code/test issue (not a config issue),
`ORCH` neither spawns a nested WF-03 nor fixes it on WF-04's branch. It files the issue and
forwards it to the global queue:

```
ORCH:
  1. File the issue (ISS file + mandatory GitHub issue, per WF-03 Step 0.5 - unchanged).

  2. -> fn:enqueue-issue: python3 tools/queue_add.py ISS-NNNN --severity <sev> ...
     (adds it to handoffs/global_queue.json - see LOOP_PROTOCOL.md)

  3. Record the failure in this run's test report, then CONTINUE to the next WF-04 step.
     WF-04 does not return to the failed step and does not block on the fix.

  4. The forwarded issue is fixed later as its own WF-03 run, with its own branch and PR,
     when a loop iteration claims it.
```

A WF-04 run therefore always completes its full sweep — Steps 1 through 8 — and its report
lists every failure found. The release decision (Step 8) still BLOCKS the release when
BLOCKER failures exist; forwarding changes *where the fix happens*, not whether the release
is gated on it.

**Exception — Step 1 (Build Check).** A build failure prevents every later step from running
at all, so it is not forwarded: it is reworked in place per the Unblock-Everything directive
before WF-04 continues.

**Direct routing to dev agents (Steps 6, 7):** NFR performance failures (Step 6) and
coverage gaps (Step 7) are filed and forwarded the same way. The `feature/WF04-nfr-*` /
`feature/WF04-cov-*` branch-naming convention that previously existed for these is retired.

`owned_modules` for the WF-04 run is recorded once, at its own Step 00. Because WF-04 no
longer fixes what it finds, its module footprint is small (reports only, in the common
case). Each forwarded issue declares its own `owned_modules` when its later WF-03 run
starts - see ORCHESTRATOR.md §10.

---

## Scheduled vs Pre-Release Modes

| Mode | Trigger | Scope | NFR benchmarks |
|---|---|---|---|
| **Scheduled** (CI) | Daily / per commit | All passing stages | Skipped (run weekly only) |
| **Pre-release** | Manual by ORCH before releasing a stage | Stage N being released | Always run |
| **Full validation** | Quarterly or after major refactor | All stages | Always run |
