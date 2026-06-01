# WF-03 — Issue Resolving

**Version:** 0.4 · 2026-06-01  
**Trigger:** Bug report / user request, test failure, DLQ escalation, or regression detected during WF-02/WF-04  
**Owner:** `ORCH`

---

## ⛔ Mandatory Rule for All Steps

**Every agent completing a step in this workflow MUST call `fn:register-inner-report` immediately before `fn:complete-handoff`.** This is not optional. An agent that calls `fn:complete-handoff` without first calling `fn:register-inner-report` has violated the workflow.

Step workflow chain template:
```
... (agent work) ... → fn:validate-completeness → fn:register-inner-report → fn:complete-handoff
```

---

## When to launch WF-03

WF-03 is launched by ORCH in **two distinct situations**:

### Situation A — Internal: triggered by TEST-RUNNER failure

WF-03 is launched when TEST-RUNNER in WF-02 Step 4 returns FAIL **and** the failure is NOT eligible for inline fix.

**Launch WF-03 when:**
- Failure is a logic error, DB error, or assertion failure (not a pure compile error)
- Compile failure touches > 2 files
- Compile failure requires a logic, schema, or API contract change
- TEST-RUNNER's inline fix attempt failed

**Do not launch WF-03 when:**
- TEST-RUNNER resolved a compile-only blocker inline and resubmitted PASS

### Situation B — External: triggered by user-reported issue or bug description

WF-03 is launched when the user describes a bug, problem, or defect — even without a failing test. Trigger phrases include: "fix this", "there is a problem with", "the X is broken", "resolve this issue".

ORCH classifies the prompt as a WF-03 trigger when:
- The user describes unexpected behaviour in the running system
- The user describes a defect found during manual testing
- The user reports an error or crash not yet captured by the test suite
- The prompt implies finding and fixing a root cause (not adding new functionality)

If unsure whether a prompt is WF-03 (issue fix) or WF-02 (new requirement): WF-03 is correct if the expected behaviour already exists in the requirements spec; WF-02 is correct if the feature has not been specified yet.

---

## Overview

```
[INPUT: bug report, failing test report, or user description of a defect]
            │
            ▼
┌───────────────────────────────┐
│  STEP 00: GIT SETUP           │ ← BACKEND-DEV (backend) or FRONTEND-DEV (frontend)
│  pull → branch → push         │   fn:git-setup  (see docs/agents/protocols/GIT_SETUP.md)
└──────────────┬────────────────┘
               │ PASS
               ▼
┌───────────────────────────────┐
│  STEP 0.5: ISSUE REGISTRY     │ ← ISSUE-FIXER
│  search → create or update    │   fn:search-issues, fn:register-issue / fn:update-issue
│  ISS file                     │
└──────────────┬────────────────┘
               │ PASS
               ▼
┌───────────────────────────────┐
│  STEP 1: DIAGNOSE             │ ← ISSUE-FIXER
│  Root cause analysis          │   fn:load-handoff, fn:check-zig-build, fn:run-unit-tests
│  Failure category             │
└──────────────┬────────────────┘
               │
        CLEAR? ├── NO ──► If requirement ambiguity: route to REQ-ANALYST (WF-01 rework)
               │           Return here after clarification
              YES
               │
               ▼
┌───────────────────────────────┐
│  STEP 2: SOLUTION DESIGN      │ ← CODE-DESIGNER
│  Produce fix design artefact  │   fn:read-backend-conventions / fn:read-frontend-conventions
│  (Type E prose or Type A–D    │
│  parameter file)              │
└──────────────┬────────────────┘
               │
               ▼
┌───────────────────────────────┐
│  STEP 2b: DESIGN VALIDATION   │ ← CODE-DESIGN-VALIDATOR     ← HARD GATE
│  Verify design covers root    │
│  cause and acceptance criteria│
└──────────────┬────────────────┘
               │ PASS
               ▼
┌───────────────────────────────┐
│  STEP 3: FIX                  │ ← BACKEND-DEV (backend) or FRONTEND-DEV (frontend)
│  Implement per design         │
│  fn:check-zig-build /         │
│  fn:check-frontend-build      │
└──────────────┬────────────────┘
               │
        COMPILES? ├── NO ──► REWORK (max 3, same agent)
               │
              YES
               │
               ▼
     ┌─────────┴───────────┐
     │  Fix scope check     │
     │  (see §Fix Scope)    │
     └────┬───────────┬─────┘
          │           │
    ADDS/MODIFIES  PURE REGRESSION
    BUSINESS LOGIC     FIX
          │           │
          ▼           ▼
┌──────────────────┐  ┌──────────────────────────────┐
│ STEP 4:          │  │ STEP 5: VERIFY (direct)       │
│ TEST DESIGN      │  │  ← TEST-RUNNER                │
│ ← TEST-DESIGNER  │  │  Re-run failing tests         │
└────────┬─────────┘  │  + regression suite           │
         │            └──────────────┬───────────────┘
         ▼                           │
┌──────────────────┐                 │
│ STEP 4b:         │                 │
│ TEST DESIGN      │                 │
│ VALIDATION       │                 │
│ ← TEST-DESIGN-   │                 │
│   VALIDATOR      │                 │
│   (HARD GATE)    │                 │
└────────┬─────────┘                 │
         │ PASS                      │
         ▼                           │
┌──────────────────┐                 │
│ STEP 5: VERIFY   │                 │
│ ← TEST-RUNNER    │                 │
│ Re-run failing   │                 │
│ tests + suite    │                 │
└────────┬─────────┘                 │
         └──────────┬────────────────┘
                    │
             PASS? ├── NO ──► Back to STEP 3 (max 3 rework cycles total)
                    │
                   YES
                    │
                    ▼
┌───────────────────────────────┐
│  STEP 6: RELEASE VALIDATION   │ ← RELEASE-VALIDATOR
│  (BLOCKER severity only)      │   fn:run-nfr-benchmarks, fn:load-requirement-status
│  Skip for MINOR/MAJOR          │
└──────────────┬────────────────┘
               │ PASS (or skipped)
               ▼
┌───────────────────────────────┐
│  STEP 7: DOC UPDATE           │ ← DOC-UPDATER
│  Changelog + issue status     │   fn:update-changelog, fn:update-issue
└──────────────┬────────────────┘
               │ PASS
               ▼
┌───────────────────────────────┐
│  STEP FINAL: GIT MERGE        │ ← same agent as Step 00
│  rebase → PR → merge          │   fn:git-merge  (see docs/agents/protocols/GIT_MERGE.md)
└──────────────┬────────────────┘
               │ PASS
               ▼
[OUTPUT: PASS result → caller workflow (WF-02 Step 4 or WF-04) resumes, or pipeline DONE]
```

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV` (backend fixes) or `FRONTEND-DEV` (frontend fixes)  
**Protocol:** `docs/agents/protocols/GIT_SETUP.md`

ORCH supplies `context.branch_name = "feature/WF03-<issue-id>-<timestamp>"` in this handoff.  
Follow GIT_SETUP.md exactly. On PASS, ORCH routes to Step 0.5.

---

## Step 0.5 — Issue Registry

**Agent:** `ISSUE-FIXER`  
**Functions:** `fn:search-issues`, `fn:register-issue`, `fn:update-issue`

### Purpose

Every issue must be logged before diagnosis begins. This step is separate from Step 1 so that the registry entry is created even if diagnosis is later blocked or reworked.

### Procedure

```
1. → fn:search-issues
   Search docs/issues/issue_index.json for existing entries matching:
   - Same affected source files
   - Same error message pattern or failure category
   - Same requirement IDs (if known)
   Similarity threshold: match ≥ 2 of the above 3 criteria → consider it the same issue.

2a. If a matching issue is found:
    - Read the existing ISS-NNNN.json file
    - Append a new occurrence entry:
      {
        "occurred_at": "<ISO8601>",
        "run_id": "<current run_id>",
        "handoff_id": "<current handoff_id>",
        "trigger": "user_report | test_failure | regression",
        "context": "<brief description of this occurrence>"
      }
    - Update "status" to "REOPENED" if it was RESOLVED
    - Do NOT create a new ISS file — this is a recurrence of an existing issue
    - Note the existing issue's root_cause and resolution for Step 1 (diagnosis shortcut)

2b. If no matching issue is found:
    - → fn:register-issue
    - Create docs/issues/ISS-<next_id>.json:
      {
        "issue_id": "ISS-<NNNN>",
        "title": "<short description>",
        "status": "OPEN",
        "severity": "<BLOCKER|MAJOR|MINOR — preliminary, updated in Step 1>",
        "category": null,       ← filled in Step 1
        "run_id": "<run_id>",
        "workflow_id": "WF-03",
        "handoff_id": "<handoff_id>",
        "requirement_ids": [],  ← filled in Step 1
        "summary": "<one paragraph from the trigger description>",
        "root_cause": null,     ← filled in Step 1
        "resolution": null,     ← filled in Step 3
        "occurrences": [
          {
            "occurred_at": "<ISO8601>",
            "run_id": "<run_id>",
            "handoff_id": "<handoff_id>",
            "trigger": "user_report | test_failure | regression",
            "context": "<trigger description verbatim>"
          }
        ],
        "files_changed": [],
        "created_at": "<ISO8601>",
        "resolved_at": null,
        "prevention": []
      }
    - Update docs/issues/issue_index.json: increment next_issue_id, append index entry

3. → fn:register-inner-report
4. → fn:complete-handoff (status: PASS,
                           artifacts_out: ["docs/issues/ISS-<NNNN>.json"],
                           next_action: "Route to ISSUE-FIXER Step 1 (Diagnose)",
                           note: "existing_issue: true/false, issue_id: ISS-NNNN")
```

---

## Step 1 — Diagnose

**Agent:** `ISSUE-FIXER`  
**Functions:** `fn:load-handoff`, `fn:load-requirements`, `fn:check-zig-build`, `fn:run-unit-tests`

### Procedure

```
1. → fn:load-handoff (from the triggering handoff)
2. Read the ISS file from Step 0.5 artifacts_out.
   If this is a recurrence (existing issue), read previous root_cause and resolution —
   they provide a strong prior for diagnosis. If the prior resolution was applied and
   the issue recurred, the root cause is deeper than previously diagnosed.
3. If triggered by a test report: read tests/reports/<report file> (from handoff artifacts_in)
   For each failing test:
     a. Read the test source file
     b. Read the source file under test
4. Identify the failure category:

      CATEGORY A — Logic error in pure function
        Symptom: unit test fails; test code is correct; source code has wrong logic
        Action: proceed to Step 2

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
        Action: Step 2 to fix the test (no business logic change)

      CATEGORY F — Environment / configuration error
        Symptom: test fails only in CI, not locally; or missing env var
        Action: fix CI configuration or environment setup docs;
                route to DOC-UPDATER for docs update if needed

5. Produce diagnosis and write to ISS file:
   - Update "category" field
   - Update "severity" to final classification (BLOCKER / MAJOR / MINOR)
   - Update "requirement_ids"
   - Write "root_cause": { "type": "<slug>", "details": "<paragraph>" }
   - Write "files_to_change": ["<path>", ...] — used by CODE-DESIGNER in Step 2

6. → fn:register-inner-report
7. → fn:complete-handoff (status: PASS if actionable, FAIL if blocked on external,
                           next_action: "Route to CODE-DESIGNER Step 2",
                           artifacts_out: ["docs/issues/ISS-<NNNN>.json"])
```

---

## Step 2 — Solution Design

**Agent:** `CODE-DESIGNER`  
**Functions:** `fn:read-backend-conventions`, `fn:read-frontend-conventions`

### Purpose

Produces the design artefact that `BACKEND-DEV` or `FRONTEND-DEV` will implement in Step 3. This is the same role CODE-DESIGNER plays in WF-02 Step 1, applied to a fix instead of a new feature.

### Procedure

```
1. Read the ISS file from Step 1 (artifacts_out).
   Focus on: root_cause, category, files_to_change, requirement_ids.

2. Classify the fix type per templates/lego-catalog.md:
   - If the fix is isolated to one module with no API contract change: Type E prose design
   - If the fix requires a new migration: Type C parameter file
   - If the fix changes a CRUD endpoint signature: Type A parameter file
   - Mixed: produce one file per type

3. Produce the design artefact:
   - Type E: src/design/fix-<issue-id>.md following backend_developer_guide.md §6
     Include: what changes (not how), public function signatures before/after,
     error taxonomy changes (if any), migration plan (if any), callers impacted
   - Type A/C: templates/specs/<issue-id>.<type>.yaml

4. Design constraints (hard rules):
   - Do NOT write implementation code (no function bodies, no SQL DDL outside Type C YAML)
   - Design MUST address the root_cause in the ISS file — not a workaround
   - If the fix scope requires changing > 5 source files: flag in design and note that
     ORCH should consider whether this is an architectural issue requiring WF-02 instead
   - Design MUST be minimal: fix only what the root_cause requires

5. → fn:register-inner-report
6. → fn:complete-handoff (status: PASS,
                           artifacts_out: ["src/design/fix-<issue-id>.md"],
                           next_action: "Route to CODE-DESIGN-VALIDATOR Step 2b")
```

---

## Step 2b — Design Validation

**Agent:** `CODE-DESIGN-VALIDATOR`  
**Hard gate — Step 3 (Fix) MUST NOT start until this returns PASS.**

### Procedure

Same checks as WF-02 Step 1b, applied to the fix design:

```
1. Read the ISS file and the design artefact from Step 2.
2. Verify:
   a. Design addresses the diagnosed root_cause (not a superficial workaround)
   b. All public function signatures before/after are documented (Type E)
   c. No implementation code is present in the design
   d. Error taxonomy is updated if error variants change
   e. Callers that must be updated are listed
   f. Fix scope ≤ 5 files (flag if exceeded — ORCH may escalate to architectural fix)
   g. For Type A/C: run `python tools/codegen_<type>.py <artefact> --dry-run` → exit 0
3. FAIL if any check fails. On FAIL: ORCH reworks to CODE-DESIGNER (max 3).
4. → fn:register-inner-report
5. → fn:complete-handoff (status: PASS or FAIL,
                           next_action: PASS → "Route to BACKEND-DEV or FRONTEND-DEV Step 3")
```

---

## Step 3 — Fix

**Agent:** `BACKEND-DEV` (backend fixes) or `FRONTEND-DEV` (frontend fixes)  
**Functions:** `fn:check-zig-build`, `fn:check-frontend-build`, `fn:check-frontend-types`, `fn:run-unit-tests`

### Procedure

```
1. Read the design artefact from Step 2 (from handoff artifacts_in).
2. Apply the fix per the design:
   - For Type E prose design: write Zig/TypeScript source per the design
   - For Type A/C: run codegen, then edit only CUSTOM blocks
   - For CATEGORY E (test code error): edit the test file only
   - For CATEGORY F (environment): edit CI config or env setup docs
3. → fn:check-zig-build (if backend files changed)
   OR fn:check-frontend-types + fn:check-frontend-build (if frontend files changed)
   If FAIL: fix compilation errors (counts as rework iteration)
4. → fn:run-unit-tests (module that was changed)
5. Fix rules:
   [ ] Minimal change: fix only what the design prescribes; do not refactor surrounding code
   [ ] If fix changes a function signature: verify all callers compile
   [ ] If fix changes DB schema: write a new migration (never alter existing migrations)
   [ ] No mocks, stubs, or stub return values in any test file (DIRECTIVE T-1)
6. Update ISS file: set "files_changed" to the list of files actually modified
7. Commit to feature branch:
   git add -A
   git commit -m "fix(<run-id>): <short description> (<issue-id>)"
   git push origin feature/<run-id>
8. → fn:register-inner-report
9. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: [list of changed files],
                           next_action: "Route to TEST-DESIGNER Step 4 OR TEST-RUNNER Step 5")
```

### Fix Scope Rule

**The fix agent MUST assess whether business logic was added or modified:**

| Fix type | Test design steps required |
|---|---|
| Adds or modifies business logic (new conditions, new error paths, new state transitions) | Route to TEST-DESIGNER (Step 4) → TEST-DESIGN-VALIDATOR (Step 4b) → TEST-RUNNER (Step 5) |
| Pure regression fix (test was wrong, compilation error, env config, test isolation) | Skip to TEST-RUNNER directly (Step 5) — existing tests cover the behaviour |

The fix agent MUST state which path applies in `result.next_action`.

### Fix size constraint

A single fix iteration MUST touch ≤ 5 source files. If the design prescribed more, and the fix agent confirms this at Step 3, the issue is architectural — STOP, ORCH escalates: the issue requires a CODE-DESIGNER redesign of the affected module (potentially a WF-02 run for the affected requirements).

---

## Step 4 — Test Design (conditional)

**Agent:** `TEST-DESIGNER`  
**Condition:** Only if Step 3 fix agent reported `next_action` includes "TEST-DESIGNER"

Same procedure as WF-02 Step 3. Write test specs to `tests/specs/<issue-id>-fix.md` and test source files covering the changed business logic. **No deferred work.** Set `next_action: "Route to TEST-DESIGN-VALIDATOR Step 4b"`.

---

## Step 4b — Test Design Validation (conditional)

**Agent:** `TEST-DESIGN-VALIDATOR`  
**Condition:** Only if Step 4 ran.  
**Hard gate — TEST-RUNNER must not start until this returns PASS.**

Same checks as WF-02 Step 3b. On PASS, set `next_action: "Route to TEST-RUNNER Step 5"`.

---

## Step 5 — Verify

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-unit-tests`, `fn:run-integration-tests`, `fn:run-frontend-unit-tests`, `fn:write-test-report`

### Pre-checks (same as WF-02 Step 4)

```bash
docker-compose ps 2>/dev/null | grep -E "keycloak|db"
curl -sf http://localhost:8081/health/ready > /dev/null && echo "KC_OK" || echo "KC_DOWN"
psql "$BPM_TEST_DB_URL" -c "SELECT 1" > /dev/null 2>&1 && echo "DB_OK" || echo "DB_DOWN"
```
If any service is down: STOP. Return FAIL with severity BLOCKER. ORCH handles infrastructure restart (see ORCHESTRATOR.md §8b).

### Procedure

```
1. → fn:run-unit-tests (full suite — check for regressions, not just the fixed test)
2. → fn:run-integration-tests (full suite)
3. → fn:run-frontend-unit-tests (if frontend was changed)
4. → fn:write-test-report (to tests/reports/report-<date>-<run_id>-step05-verify.yaml)
5. Classify results:
   - Previously failing test now passes: ✓
   - No new failures introduced: ✓
   - All previously passing tests still pass: ✓
6. If all three conditions met: status = PASS
7. If new failures introduced (regression):
   status = FAIL; include regression list in result.issues
8. → fn:register-inner-report
9. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["tests/reports/report-<date>-<run_id>-step05-verify.yaml"],
                           next_action: PASS → "Route to RELEASE-VALIDATOR Step 6 (if BLOCKER) or DOC-UPDATER Step 7"
                                        FAIL → "Route back to BACKEND-DEV/FRONTEND-DEV Step 3 (rework)")
```

---

## Step 6 — Release Validation (conditional)

**Agent:** `RELEASE-VALIDATOR`  
**Condition:** Only if issue severity is `BLOCKER`. Skip for MAJOR and MINOR.

Run NFR benchmarks and perform the release check per `docs/agents/workflows/WF-04_full_test_run.md` §Steps 6–8. Set `next_action: "Route to DOC-UPDATER Step 7"`.

---

## Step 7 — Doc Update

**Agent:** `DOC-UPDATER`  
**Functions:** `fn:update-changelog`, `fn:update-issue`

```
1. → fn:update-changelog: add entry for the fix under the current version
2. → fn:update-issue: set ISS file status to RESOLVED, fill resolved_at, resolution, prevention
3. Update docs/issues/issue_index.json: set status = "RESOLVED", set resolved_at
4. → fn:register-inner-report
5. → fn:complete-handoff (next_action: "Route to Step Final git-merge")
```

---

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` (backend fixes) or `FRONTEND-DEV` (frontend fixes) — same agent as Step 00  
**Protocol:** `docs/agents/protocols/GIT_MERGE.md`

ORCH supplies `context.branch_name` in this handoff.  
Use ISSUE-FIXER's Step 1 `result.summary` and the ISS file title as the commit and PR one-line summary.  
Use commit prefix `fix` instead of `feat`.  
Follow GIT_MERGE.md exactly.

---

## Rework Tracking

The rework counter for WF-03 is shared across Step 3 → Step 5 cycles. If the fix fails verification 3 times:

```
ORCH escalates with:
  - All three attempt reports
  - Root cause diagnosis from Step 1
  - ISS file (docs/issues/ISS-NNNN.json) with all occurrence records
  - List of files changed in each attempt
  - Recommendation: requires CODE-DESIGNER redesign of the affected module
```

---

## Issue Severity Classification

When `ISSUE-FIXER` completes Step 1, it classifies severity to help `ORCH` prioritise:

| Severity | Definition | Action |
|---|---|---|
| `BLOCKER` | Failing MUST requirement test; platform cannot release | Halt WF-02; fix immediately; run Step 6 (RELEASE-VALIDATOR) |
| `MAJOR` | Failing SHOULD requirement; significant degradation | Fix within current iteration; skip Step 6 |
| `MINOR` | Failing COULD requirement; cosmetic or edge case | Log and defer to next iteration; skip Step 6 |

`ORCH` MUST NOT advance WF-02 to release validation while any BLOCKER issues are open.

---

## WF-03 Pipeline Summary Table

| Step | Agent | Condition | Gate |
|---|---|---|---|
| 00 | BACKEND-DEV / FRONTEND-DEV | Always | Hard gate |
| 0.5 | ISSUE-FIXER | Always | — |
| 1 | ISSUE-FIXER | Always | — |
| 2 | CODE-DESIGNER | Always | — |
| **2b** | **CODE-DESIGN-VALIDATOR** | **Always** | **Hard gate** |
| 3 | BACKEND-DEV / FRONTEND-DEV | Always | — |
| 4 | TEST-DESIGNER | Business logic changed | — |
| **4b** | **TEST-DESIGN-VALIDATOR** | **Business logic changed** | **Hard gate** |
| 5 | TEST-RUNNER | Always | — |
| 6 | RELEASE-VALIDATOR | BLOCKER severity only | — |
| 7 | DOC-UPDATER | Always | — |
| Final | BACKEND-DEV / FRONTEND-DEV | Always | Hard gate |
