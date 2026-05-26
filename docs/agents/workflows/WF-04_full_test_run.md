# WF-04 — Full Test Run

**Version:** 0.2 · 2026-05-26  
**Trigger:** Pre-release gate, scheduled CI run, or explicit operator request  
**Owner:** `ORCH`

**Git protocol:** When WF-04 spawns WF-03 or routes directly to BACKEND-DEV/FRONTEND-DEV/TEST-DESIGNER for fixes, those sub-workflows ALWAYS use WF-05 (`docs/agents/workflows/WF-05_parallel_git_protocol.md`) — feature branch creation is mandatory for all agent work.

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
     PASS? ├── NO ──► Spawn WF-03; on WF-03 PASS: return to STEP 2
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 3: INTEGRATION    │ ← TEST-RUNNER
│  TESTS                  │
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Spawn WF-03; on WF-03 PASS: return to STEP 3
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 4: FRONTEND TESTS │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Spawn WF-03; on WF-03 PASS: return to STEP 4
           │
          YES
           │
           ▼
┌─────────────────────────┐
│  STEP 5: E2E TESTS      │ ← TEST-RUNNER
└──────────┬──────────────┘
           │
     PASS? ├── NO ──► Spawn WF-03; on WF-03 PASS: return to STEP 5
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
[OUTPUT: Consolidated test report; release decision]
```

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
   On FAIL: ORCH spawns WF-03 with the failure list; WF-03 must resolve before WF-04 continues
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
   On FAIL: ORCH spawns WF-03
```

---

## Step 4 — Frontend Unit Tests

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-frontend-unit-tests`

```
1. → fn:run-frontend-unit-tests (no path filter — run all)
2. Classify failures
3. → fn:complete-handoff (PASS/FAIL)
   On FAIL: ORCH spawns WF-03
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
   On FAIL: ORCH spawns WF-03 (E2E failures may be frontend or backend — include
             Playwright screenshots in artifacts_out for diagnosis)
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

## WF-03 Spawning Rule

When any step in WF-04 fails and the failure is a code/test issue (not a config issue), `ORCH` spawns WF-03 as a sub-workflow:

```
ORCH:
  1. Create WF-03 handoff with:
       workflow_id = "WF03-<timestamp>"
       context.related_handoff_ids = [failing WF-04 handoff id]
       task.description = "Fix the following failures: <failure list>"
  
  2. Launch WF-03 with WF-05 wrapping (always):
       a. Create WF-03 Step 00 handoff (git-setup) first
       b. Run WF-03 Steps 00 → 1 → 2 → 3 → Final
  
  3. On WF-03 PASS: resume WF-04 at the step that failed
  4. On WF-03 ESCALATED: pause WF-04; surface for human review
```

The WF-04 step counter does NOT reset when WF-03 is run. WF-04 resumes at the exact step it left.

**Direct routing to dev agents (Steps 6, 7):** When WF-04 routes directly to BACKEND-DEV (NFR performance fixes) or TEST-DESIGNER (coverage gaps), ORCH wraps those with WF-05 (Step 00 → work → Step Final).

---

## Scheduled vs Pre-Release Modes

| Mode | Trigger | Scope | NFR benchmarks |
|---|---|---|---|
| **Scheduled** (CI) | Daily / per commit | All passing stages | Skipped (run weekly only) |
| **Pre-release** | Manual by ORCH before releasing a stage | Stage N being released | Always run |
| **Full validation** | Quarterly or after major refactor | All stages | Always run |
