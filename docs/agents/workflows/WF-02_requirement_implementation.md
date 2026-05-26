# WF-02 — Requirement Implementation

**Version:** 0.2 · 2026-05-26
**Trigger:** One or more requirements reach status VALIDATED; stage gate cleared by `ORCH`
**Owner:** `ORCH`
**Git protocol:** This workflow ALWAYS uses WF-05 (`docs/agents/workflows/WF-05_parallel_git_protocol.md`) — feature branch creation is mandatory for all agent work. ORCH adds Step 00 (git-setup) before Step 01 and Step Final (git-merge) after Step 06.

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
[INPUT: VALIDATED requirement IDs]
           │
           ▼
┌──────────────────────┐
│  STEP 1: CODE DESIGN │ ← CODE-DESIGNER
│  Interfaces, types,  │
│  data-flow diagrams  │
└──────────┬───────────┘
           │
      VALID?├── NO ──► REWORK (max 3)
           │
          YES
           │
           ▼
┌──────────────────────┐        ┌──────────────────────┐
│  STEP 2a: BACKEND    │        │  STEP 2b: FRONTEND   │
│  Implement Zig code  │        │  Implement React/TS  │
│  + migrations        │        │  components + hooks  │
└──────────┬───────────┘        └──────────┬───────────┘
           │                               │
     COMPILES?                       COMPILES?
     + STYLE?                        + TYPES?
           │                               │
      FAIL─► REWORK                   FAIL─► REWORK
           │                               │
          YES                             YES
           └────────────┬─────────────────┘
                        │
                        ▼
           ┌──────────────────────┐
           │  STEP 3: TEST DESIGN │ ← TEST-DESIGNER
           │  Write test specs    │
           │  + test code         │
           └──────────┬───────────┘
                      │
                 VALID?├── NO ──► REWORK (max 3)
                      │
                     YES
                      │
                      ▼
           ┌──────────────────────┐
           │  STEP 4: TEST RUN    │ ← TEST-RUNNER
           │  Execute test suite  │
           └──────────┬───────────┘
                      │
                PASS? ├── NO ──► STEP 5 (fix) → back to STEP 4
                      │
                     YES
                      │
                      ▼
           ┌──────────────────────┐
           │  STEP 5: RELEASE     │ ← RELEASE-VALIDATOR
           │  VALIDATION          │
           └──────────┬───────────┘
                      │
                PASS? ├── NO ──► Identify blocking issue → route to correct agent
                      │
                     YES
                      │
                      ▼
           ┌──────────────────────┐
           │  STEP 6: DOC UPDATE  │ ← DOC-UPDATER
           │  Status → RELEASED   │
           │  Changelog, OpenAPI  │
           └──────────┬───────────┘
                      │
                      ▼
           [OUTPUT: requirements RELEASED]
```

---

## Step 1 — Code Design

**Agent:** `CODE-DESIGNER`  
**Functions:** `fn:load-requirements`, `fn:read-backend-conventions`, `fn:read-frontend-conventions`

### Procedure

```
1. → fn:load-requirements (filter to context.requirement_ids)
2. → fn:read-backend-conventions
3. → fn:read-frontend-conventions (if frontend requirements present)
4. For each affected module, produce a design file at src/design/<module>.md:
   - Public function signatures with input/output types
   - Key data structures
   - Invariants that must hold
   - DB tables/columns touched
   - Cross-module dependencies
   - Identified risks or open questions
5. For each new DB table or schema change:
   - Specify the migration SQL (structure only, not the file — BACKEND-DEV writes it)
   - Note: column types, constraints, indexes required
6. For frontend-touching requirements:
   - Specify which components need to be created or modified
   - Specify the API call signatures (request/response shapes)
   - Note any new design system tokens or components needed
7. Validate design against requirements:
   - Every acceptance criterion maps to at least one designed function/component
   - No acceptance criterion is left unaddressed
8. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["src/design/<module>.md", ...],
                           next_action: "Route to BACKEND-DEV and/or FRONTEND-DEV")
```

### Acceptance criteria for this step

- [ ] Every requirement's acceptance criterion maps to a concrete design element
- [ ] All new types/structs are defined
- [ ] No circular module dependencies introduced
- [ ] DB schema changes described (table name, columns, indexes, constraints)
- [ ] Open questions listed (not silently ignored)

---

## Step 2a — Backend Implementation

**Agent:** `BACKEND-DEV`  
**Functions:** `fn:read-backend-conventions`, `fn:check-zig-build`, `fn:apply-migrations`

### Procedure

```
1. Read src/design/<module>.md for this implementation unit
2. → fn:read-backend-conventions
3. Implement source code in src/<module>/*.zig per the design
4. Write SQL migration file(s) in migrations/ per the design spec
5. → fn:check-zig-build
   If FAIL: fix compilation errors; retry (counts as rework)
6. → fn:apply-migrations (test DB)
   If FAIL: fix migration SQL; retry
7. Error-set validation (mandatory — run before self-review):
   zig build 2>&1 | grep -i "error set"
   If any output: the return type of a function does not cover all errors it can
   propagate. Fix all error-set declarations before proceeding. This is the
   single most common cause of downstream TEST-RUNNER compile failures and
   WF-03 dispatches. Do not skip this step.
8. Self-review checklist:
   [ ] No string interpolation of user input into SQL (prepared statements only)
   [ ] All allocations accept an allocator parameter
   [ ] No I/O inside transition.zig (if modified)
   [ ] Each error type is in the module's error set
   [ ] If any function signature changed: verify all call sites compile
   [ ] New public functions have a doc comment (one line describing behaviour)
9. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["src/...", "migrations/NNN_*.sql"],
                           next_action: "Route to TEST-DESIGNER once Step 2b also complete")
```

### Acceptance criteria for this step

- [ ] `zig build` exits 0 with no "error set" warnings in stderr
- [ ] All migrations apply cleanly against fresh DB (`fn:apply-migrations` PASS)
- [ ] No SQL string interpolation of user data
- [ ] Pure transition function has no I/O (if modified)
- [ ] All callers of any changed function signature compile without error

---

## Step 2b — Frontend Implementation

**Agent:** `FRONTEND-DEV`  
**Functions:** `fn:read-frontend-conventions`, `fn:check-frontend-build`, `fn:check-frontend-types`, `fn:check-frontend-lint`

### Procedure

```
1. Read src/design/<module>.md for frontend components/hooks
2. → fn:read-frontend-conventions
3. Implement components in web/src/ per the design
4. → fn:check-frontend-types
   If FAIL: fix TypeScript errors; retry
5. → fn:check-frontend-lint
   If FAIL: fix lint errors; retry (warnings do not block)
6. → fn:check-frontend-build
   If FAIL: fix build errors; retry
7. Self-review checklist:
   [ ] No raw API calls in components (all via api/ modules)
   [ ] Destructive actions use ConfirmDialog
   [ ] Role-gating hides (not disables) unauthorized elements
   [ ] All interactive elements have accessible labels
   [ ] No hardcoded hex colors (all from design token variables)
   [ ] Token never stored in localStorage/sessionStorage
8. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["web/src/..."],
                           next_action: "Route to TEST-DESIGNER once Step 2a also complete")
```

### Acceptance criteria for this step

- [ ] `npx tsc --noEmit` exits 0
- [ ] `npm run lint` exits 0 (no errors)
- [ ] `npm run build` exits 0
- [ ] Token not stored in localStorage/sessionStorage

---

## Step 3 — Test Design

**Agent:** `TEST-DESIGNER`  
**Functions:** `fn:load-requirements`, `fn:load-test-specs`

### Procedure

```
1. → fn:load-requirements (context.requirement_ids)
2. → fn:load-test-specs (context.requirement_ids) — identify existing specs
3. For each requirement without a test spec (or with outdated spec):
   a. Write tests/specs/<REQ-ID>.md per the test spec format
      (see test_developer_guide.md §3)
   b. Write test code:
      - Unit tests: tests/unit/<module>_test.zig
      - Integration tests: tests/integration/<area>_test.zig
      - Frontend unit tests: web/src/**/*.test.ts
      - E2E tests: web/tests/e2e/<journey>.spec.ts (for critical journeys only)
4. Verify: every MUST requirement has ≥1 unit or integration test case
5. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["tests/specs/...", "tests/unit/...", ...],
                           next_action: "Route to TEST-RUNNER")
```

### Acceptance criteria for this step

- [ ] Every MUST requirement in context.requirement_ids has at least one test case
- [ ] Test specs are written before test code (spec file present for each test file)
- [ ] No test depends on wall-clock time or random values without a fixed seed

---

## Step 4 — Test Run

**Agent:** `TEST-RUNNER`  
**Functions:** `fn:run-unit-tests`, `fn:run-frontend-unit-tests`, `fn:run-integration-tests`, `fn:check-code-coverage`, `fn:write-test-report`

### Procedure

```
1. → fn:run-unit-tests (modules affected by this implementation)
2. → fn:run-frontend-unit-tests (if frontend changes present)
3. → fn:run-integration-tests
4. → fn:check-code-coverage
5. → fn:write-test-report (all results combined)
6. Read the report:
   - If any BLOCKER failures: status = FAIL; classify failure type (see below)
   - If coverage below threshold: status = FAIL
   - If only MINOR failures: status = PARTIAL (Orchestrator decides)
7. → fn:complete-handoff (status: PASS/FAIL/PARTIAL,
                           artifacts_out: ["tests/reports/report-<date>-WF02.json"],
                           next_action: PASS → "Route to RELEASE-VALIDATOR"
                                        FAIL (compile) → "Inline fix authority granted — see below"
                                        FAIL (logic/DB) → "Route to ISSUE-FIXER")
```

### Inline fix authority for compile-only blockers

When `status = FAIL` and **every** blocking failure is a compile-time error (not a logic,
DB, or assertion failure), TEST-RUNNER MAY fix the compile error inline without a WF-03
dispatch, provided:

- The fix touches ≤ 2 source files
- The error category is one of: error-set mismatch, mutability mismatch (`*T` vs `*const T`),
  missing import, or unused variable
- No logic, schema, or API contract change is required

**Inline fix procedure:**
```
a. Edit the offending file(s) to resolve the compile error
b. Re-run: zig build 2>&1 | head -20
c. If zig build now exits 0: re-run the full test suite from step 1 above
d. If zig build still fails, or if the fix scope exceeds the limits above:
   revert inline changes, set status = FAIL, route to ISSUE-FIXER per WF-03
```

All inline fixes MUST be listed in `result.artifacts_out` and summarised in `result.summary`.
If inline fix succeeds, `result.summary` MUST note: "Compile blocker resolved inline; no WF-03 required."

When TEST-RUNNER returns FAIL for non-compile errors, ORCH routes to `ISSUE-FIXER` (see WF-03), then returns to Step 4.

---

## Step 5 — Release Validation

**Agent:** `RELEASE-VALIDATOR`  
**Functions:** `fn:load-requirement-status`, `fn:run-nfr-benchmarks`, `fn:run-integration-tests`, `fn:check-doc-freshness`

### ORCH pre-dispatch benchmark environment check

**ORCH MUST run this check before dispatching RELEASE-VALIDATOR.** If it fails, ORCH routes
to BACKEND-DEV to provision the environment — do NOT dispatch RELEASE-VALIDATOR into an
environment where benchmarks will error on missing configuration.

```bash
# PowerShell
$result = zig build bench 2>&1 | Select-Object -First 5
if ($result -match "BPM_DB_URL|BENCHMARK_SETUP_ERROR|missing.*URL") {
    Write-Host "BLOCKED: benchmark environment not ready — route to BACKEND-DEV first"
    exit 1
}
Write-Host "CLEARED: benchmark environment ready"
```

```bash
# bash / CI
zig build bench 2>&1 | head -5 | grep -qiE "BPM_DB_URL|BENCHMARK_SETUP_ERROR|missing.*URL" \
  && echo "BLOCKED: benchmark environment not ready" && exit 1 \
  || echo "CLEARED: benchmark environment ready"
```

If BLOCKED: ORCH creates an interim BACKEND-DEV handoff to set up `BPM_DB_URL` and
`BPM_TEST_DB_URL`, then re-runs this pre-check before dispatching RELEASE-VALIDATOR.
Log the block with action `BENCH_ENV_BLOCK` in `handoffs/orchestrator.log`.

### Procedure

```
1. → fn:load-requirement-status
   Verify: all requirement_ids in context have status >= IMPLEMENTED
2. → fn:run-nfr-benchmarks (for the stage being released)
   Any failed NFR = BLOCKER
3. → fn:run-integration-tests (full suite, not just this feature's tests)
   Any regression = BLOCKER
4. → fn:check-doc-freshness
   Any stale docs = MAJOR issue
5. Stage gate check (ORCH responsibility, not RELEASE-VALIDATOR):
   - All MUST requirements for this stage = TESTED
6. → fn:complete-handoff (status: PASS/FAIL,
                           next_action: PASS → "Route to DOC-UPDATER"
                                        FAIL → "Identify blocker and route to correct agent")
```

On FAIL, `ORCH` inspects the blocking issue type:
- NFR benchmark failure → `BACKEND-DEV` (performance work)
- Benchmark environment missing → `BACKEND-DEV` (env provisioning; run pre-check again before next RV dispatch)
- Test regression → `ISSUE-FIXER`
- Documentation stale → `DOC-UPDATER`

---

## Step 6 — Documentation Update

**Agent:** `DOC-UPDATER`  
**Functions:** `fn:update-requirement-status`, `fn:update-changelog`, `fn:generate-openapi`, `fn:check-doc-freshness`

### Procedure

```
1. For each requirement_id in context.requirement_ids:
   → fn:update-requirement-status(id, "RELEASED", { released_in: "Stage N" })
2. → fn:update-changelog (stage, requirement summaries)
3. If any new API endpoints were added:
   → fn:generate-openapi
4. → fn:check-doc-freshness (final verification)
   If issues remain: fix them inline
5. → fn:complete-handoff (status: PASS,
                           next_action: "Implementation complete.")
```

---

## Parallel Execution Rule

Steps 2a (backend) and 2b (frontend) MAY run in parallel when both are present. The Orchestrator MUST wait for both to return PASS before routing to Step 3.

Steps 2a, 2b, and 3 MUST all complete before Step 4. The Orchestrator MUST NOT start a test run against incomplete code.
