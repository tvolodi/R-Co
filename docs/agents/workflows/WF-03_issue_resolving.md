# WF-03 — Issue Resolving

**Version:** 0.2 · 2026-05-26  
**Trigger:** Test failure, bug report, DLQ escalation, or regression detected during WF-02/WF-04  
**Owner:** `ORCH`

**Parallel-host runs:** Wrap this workflow with WF-05 (`docs/agents/workflows/WF-05_parallel_git_protocol.md`) when fixing issues that need to be committed on a feature branch to avoid conflicts with simultaneous work on other hosts.

---

## ⛔ Mandatory Rule for All Steps

**Every agent completing a step in this workflow MUST call `fn:register-inner-report` immediately before `fn:complete-handoff`.** This is not optional. An agent that calls `fn:complete-handoff` without first calling `fn:register-inner-report` has violated the workflow.

Step workflow chain template:
```
... (agent work) ... → fn:validate-completeness → fn:register-inner-report → fn:complete-handoff
```

---

## When to launch WF-03

WF-03 is launched by ORCH only when TEST-RUNNER in WF-02 Step 4 returns FAIL **and** the
failure is NOT eligible for inline fix. If TEST-RUNNER resolved the issue inline (see
WF-02 Step 4 inline fix authority), ORCH does NOT launch WF-03 — TEST-RUNNER resubmits
its handoff as PASS.

**Launch WF-03 when:**
- Failure is a logic error, DB error, or assertion failure (not a pure compile error)
- Compile failure touches > 2 files
- Compile failure requires a logic, schema, or API contract change
- TEST-RUNNER's inline fix attempt failed

**Do not launch WF-03 when:**
- TEST-RUNNER resolved a compile-only blocker inline and resubmitted PASS

**WF-05 wrapping:** WF-03 ALWAYS uses WF-05 (feature branch workflow). ORCH creates Step 00 (git-setup) before Step 1 and Step Final (git-merge) after Step 3. No detection check needed.

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV` (backend fixes) or `FRONTEND-DEV` (frontend fixes)  
**Function:** `fn:git-setup`

This step is ALWAYS executed for WF-03 runs. It creates the feature branch and announces the work to other hosts.

### Procedure

Follow the exact procedure defined in `docs/agents/workflows/WF-05_parallel_git_protocol.md` Step 00:

```
1. git checkout main
2. git pull --ff-only origin main
3. git checkout -b feature/WF03-<issue-id>-<timestamp>
4. Verify branch creation
5. → fn:register-inner-report
6. → fn:complete-handoff (status: PASS, next_action: "Route to ISSUE-FIXER for Step 1")
```

### Acceptance criteria

- [ ] `git pull --ff-only` exited 0
- [ ] `git branch --show-current` outputs `feature/WF03-<issue-id>-<timestamp>`
- [ ] No uncommitted changes remain on the new branch

---

## Overview

```
[INPUT: failing test report or bug description]
            │
            ▼
┌───────────────────────┐
│  STEP 00: GIT-SETUP   │ ← BACKEND-DEV (backend) or FRONTEND-DEV (frontend)
│  git pull + branch    │   (only when parallel-host mode; skip for single-host)
└──────────┬────────────┘
           │ PASS
           ▼
┌───────────────────────┐
│  STEP 1: DIAGNOSE     │ ← ISSUE-FIXER
│  Root cause analysis  │
└──────────┬────────────┘
           │
      CLEAR?├── NO ──► If design ambiguity: route to CODE-DESIGNER
           │            If requirement ambiguity: route to REQ-ANALYST (WF-01 rework)
          YES
           │
           ▼
┌───────────────────────┐
│  STEP 2: FIX          │ ← ISSUE-FIXER
│  Apply code change    │
└──────────┬────────────┘
           │
    COMPILES?├── NO ──► REWORK (max 3, same agent)
           │
          YES
           │
           ▼
┌───────────────────────┐
│  STEP 3: VERIFY       │ ← TEST-RUNNER
│  Re-run failing tests │
│  + regression suite   │
└──────────┬────────────┘
           │
     PASS? ├── NO ──► Back to STEP 2 (max 3 rework cycles total)
           │
          YES
           │
           ▼
┌───────────────────────┐
│  STEP FINAL:          │ ← same agent as step 00
│  GIT-MERGE            │   Rebase → PR → merge → cleanup
│  (parallel-host only) │   (skip for single-host)
└──────────┬────────────┘
           │ PASS
           ▼
[OUTPUT: PASS result → caller workflow (WF-02 Step 4 or WF-04) resumes]
```

**Note:** Steps 00 and Final are ALWAYS executed for agent-driven WF-03 runs. Inline fixes by TEST-RUNNER bypass WF-03 entirely (no handoff created).

---

## Step 1 — Diagnose

**Agent:** `ISSUE-FIXER`  
**Functions:** `fn:load-handoff`, `fn:load-requirements`, `fn:check-zig-build`, `fn:run-unit-tests`

### Procedure

```
1. → fn:load-handoff (from the triggering handoff)
2. Read the test report at tests/reports/<report file> (from handoff artifacts_in)
3. For each failing test:
   a. Read the test source file
   b. Read the source file under test
   c. Identify the failure category:

      CATEGORY A — Logic error in pure function
        Symptom: unit test fails; test code is correct; source code has wrong logic
        Action: proceed to Step 2 immediately

      CATEGORY B — Integration/DB error
        Symptom: integration test fails with SQL error or wrong data
        Check: is the migration correct? Is the query parameterised?
        Action: Step 2 to fix source or migration

      CATEGORY C — Design ambiguity
        Symptom: the requirement is unclear → multiple valid implementations
        Action: STOP; route to CODE-DESIGNER for design clarification
                Return here after clarification

      CATEGORY D — Requirement conflict
        Symptom: two requirements contradict each other
        Action: STOP; route to REQ-ANALYST via WF-01 rework
                Return here after requirement update

      CATEGORY E — Test code error
        Symptom: source code is correct but test has wrong expectation
        Check: does the test match the requirement's acceptance criterion?
        Action: Step 2 to fix the test

      CATEGORY F — Environment / configuration error
        Symptom: test fails only in CI, not locally; or missing env var
        Action: fix CI configuration or environment setup docs
                This is not a code fix; route to DOC-UPDATER for docs update

4. Produce diagnosis:
   { failing_test: string, category: A|B|C|D|E|F, root_cause: string,
     files_to_change: [string], is_blocker: bool }
5. → fn:complete-handoff (status: PASS if actionable, FAIL if blocked on external,
                           next_action: depends on category)
```

---

## Step 2 — Fix

**Agent:** `ISSUE-FIXER`  
**Functions:** `fn:check-zig-build`, `fn:check-frontend-build`, `fn:check-frontend-types`, `fn:run-unit-tests`

### Procedure

```
1. Apply the fix identified in Step 1 diagnosis:
   - For CATEGORY A/B: edit source file(s) in src/ or web/src/
   - For CATEGORY E: edit test file in tests/ or web/src/
   - For CATEGORY F: edit CI config or env documentation
2. → fn:check-zig-build (if backend files changed)
   OR fn:check-frontend-types + fn:check-frontend-build (if frontend files changed)
   If FAIL: fix compilation errors (counts as rework iteration)
3. → fn:run-unit-tests (module that was changed)
   Review: do the previously failing tests now pass?
   Are any previously passing tests now failing (regression introduced)?
4. Fix rules:
   [ ] Minimal change: fix only what is broken; do not refactor surrounding code
   [ ] If fix requires changing a function signature: check all callers
   [ ] If fix changes DB schema: write a new migration (never alter existing migrations)
   [ ] If fix changes a public API shape: notify ORCH — may require DOC-UPDATER run
5. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: [list of changed files],
                           next_action: "Route to TEST-RUNNER for verification")
```

### Fix size constraint

A single fix iteration MUST touch ≤ 5 source files. If the root cause requires changes across more than 5 files, the issue is architectural — `ISSUE-FIXER` MUST escalate to `ORCH`, who routes to `CODE-DESIGNER` for a design correction before any further fixing.

---

## Step 3 — Verify

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-unit-tests`, `fn:run-integration-tests`, `fn:run-frontend-unit-tests`, `fn:write-test-report`

### Procedure

```
1. → fn:run-unit-tests (full suite — check for regressions, not just the fixed test)
2. → fn:run-integration-tests (full suite)
3. → fn:run-frontend-unit-tests (if frontend was changed)
4. → fn:write-test-report
5. Classify results:
   - Previously failing test now passes: ✓
   - No new failures introduced: ✓
   - All previously passing tests still pass: ✓
6. If all three conditions met: status = PASS
7. If new failures introduced (regression):
   status = FAIL; include regression list in result.issues
8. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["tests/reports/report-<date>-WF03.json"],
                           next_action: PASS → "Return control to originating workflow"
                                        FAIL → "Route back to ISSUE-FIXER Step 2 (rework)")
```

---

## Rework Tracking

The rework counter for WF-03 is shared across Step 2 → Step 3 cycles. If the fix fails verification 3 times:

```
ORCH escalates with:
  - All three attempt reports
  - Root cause diagnosis from Step 1
  - List of files changed in each attempt
  - Recommendation: requires CODE-DESIGNER redesign of the affected module
```

---

## Issue Severity Classification

When `ISSUE-FIXER` completes Step 1, it classifies severity to help `ORCH` prioritise:

| Severity | Definition | Action |
|---|---|---|
| `BLOCKER` | Failing MUST requirement test; platform cannot release | Halt WF-02; fix immediately |
| `MAJOR` | Failing SHOULD requirement; significant degradation | Fix within current iteration |
| `MINOR` | Failing COULD requirement; cosmetic or edge case | Log and defer to next iteration |

`ORCH` MUST NOT advance WF-02 to release validation while any BLOCKER issues are open.

---

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` (backend fixes) or `FRONTEND-DEV` (frontend fixes) — same agent as Step 00  
**Function:** `fn:git-merge`

This step is ALWAYS executed for WF-03 runs. It merges the fix back into main via PR.

### Procedure

Follow the exact procedure defined in `docs/agents/workflows/WF-05_parallel_git_protocol.md` Step Final:

```
1. Verify current branch is feature/WF03-<issue-id>-<timestamp>
2. git add -A
3. git commit -m "fix(WF03-<issue-id>): <summary from ISSUE-FIXER>"
4. git fetch origin main
5. git rebase origin/main (with conflict handling per WF-05)
6. git push origin feature/WF03-<issue-id>-<timestamp>
7. gh pr create
8. gh pr merge --squash --delete-branch
9. git checkout main; git pull --ff-only; git branch -d feature/WF03-<issue-id>-<timestamp>
10. → fn:register-inner-report
11. → fn:complete-handoff (status: PASS, next_action: "WF-03 complete")
```

### Acceptance criteria

- [ ] `gh pr merge` exited 0
- [ ] `git branch --show-current` is `main`
- [ ] Feature branch deleted locally and remotely
