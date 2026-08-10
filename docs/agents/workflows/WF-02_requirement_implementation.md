# WF-02 — Requirement Implementation

**Version:** 0.3 · 2026-05-26  
**Trigger:** One or more requirements reach status VALIDATED; stage gate cleared by `ORCH`  
**Owner:** `ORCH`

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
[INPUT: VALIDATED requirement IDs — max 4 per run. Split larger batches into sequential WF-02 runs.]
           │
           ▼
┌──────────────────────────┐
│  STEP 00: GIT SETUP      │ ← BACKEND-DEV (backend/mixed) or FRONTEND-DEV (frontend-only)
│  pull → branch → push    │   fn:git-setup  (see docs/agents/protocols/GIT_SETUP.md)
└──────────┬───────────────┘
           │ PASS
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
┌──────────────────────┐
│  STEP 1b: DESIGN     │ ← CODE-DESIGN-VALIDATOR ⛔ HARD GATE
│  GATE                │   FAIL → rework CODE-DESIGNER (max 3)
│  All criteria?       │   req status → DESIGN-REVIEWED on PASS
│  No impl code?       │
└──────────┬───────────┘
           │ PASS
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
           │  STEP 3b: TEST GATE  │ ← TEST-DESIGN-VALIDATOR ⛔ HARD GATE
           │  Every MUST req has  │   FAIL → rework TEST-DESIGNER (max 3)
           │  integration test?   │   No SkipZigTest on MUST?
           │  Fixtures isolated?  │   req status → TEST-DESIGN-REVIEWED on PASS
           └──────────┬───────────┘
                      │ PASS
                      ▼
           ┌──────────────────────┐
           │  STEP 4: TEST RUN    │ ← TEST-RUNNER (bench env verified BEFORE dispatch)
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
                      │ PASS
                      ▼
┌──────────────────────────┐
│  STEP FINAL: GIT MERGE   │ ← same agent as Step 00
│  rebase → PR → merge     │   fn:git-merge  (see docs/agents/protocols/GIT_MERGE.md)
└──────────┬───────────────┘
           │ PASS
           ▼
[OUTPUT: requirements RELEASED; feature/<run-id> squash-merged into main]
```

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV` (backend/mixed runs) or `FRONTEND-DEV` (frontend-only runs)  
**Protocol:** `docs/agents/protocols/GIT_SETUP.md`

ORCH supplies `context.branch_name = "feature/<run-id>"` in this handoff.
Follow GIT_SETUP.md exactly. On PASS, ORCH routes to Step 1. Do **not** create a
`handoffs/<run_id>/issue_queue.json` — per-run issue queues were removed on 2026-08-06.

Failures caused by this run's own work are rework on this branch. Issues discovered
incidentally (pre-existing defects this run did not cause) are filed and forwarded to the
global queue per `docs/agents/protocols/ISSUE_QUEUE.md`, to be fixed in their own later
runs — see §8c of `docs/agents/ORCHESTRATOR.md`. Step Final runs exactly once, directly
after Step 6.

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
8. → fn:register-inner-report
9. → fn:complete-handoff (status: PASS/FAIL,
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

## Step 1b — Code Design Gate ⛔ HARD GATE

**Agent:** `CODE-DESIGN-VALIDATOR`  
**Functions:** `fn:load-requirements`, `fn:read-design-artefact`

### Procedure

```
1. Read the design artefact(s) in context.artifacts_in
2. → fn:load-requirements (filter to context.requirement_ids)
3. For each MUST requirement, verify:
   a. Every acceptance criterion has a corresponding design element (function, component, or schema)
   b. No acceptance criterion is addressed by "TBD", "to be implemented", or similar deferral
   c. Public function signatures are fully specified (name, inputs, outputs, errors)
   d. Error taxonomy is present (named error sets or error types)
   e. Cross-module dependencies are listed
   f. Security validation rules present for any user-input-handling function
   g. No implementation code present in the design (no Zig, SQL, or TypeScript code blocks)
4. Check that a data flow or sequence diagram exists for any non-trivial multi-step operation
5. FAIL immediately if any check fails — do not attempt partial approval
6. → fn:complete-handoff (status: PASS | FAIL,
                           issues: [list of failed checks with requirement ID],
                           next_action: "Route to BACKEND-DEV (Step 2a)" | "Rework CODE-DESIGNER")
```

### Gate rule

- **PASS** → ORCH may dispatch BACKEND-DEV (Step 2a) and/or FRONTEND-DEV (Step 2b)
- **FAIL** → ORCH increments `rework_count` on the CODE-DESIGNER handoff and re-routes; BACKEND-DEV does NOT start until this gate is PASS

---

## Step 2a — Backend Implementation

**Agent:** `BACKEND-DEV`  
**Functions:** `fn:read-backend-conventions`, `fn:check-zig-build`, `fn:apply-migrations`

### Procedure

```
1. Verify current branch:
   git branch --show-current  →  must equal feature/<run-id> from context.branch_name
   If not on the correct branch: STOP; report FAIL to ORCH before touching any file.
2. Read src/design/<module>.md for this implementation unit
3. → fn:read-backend-conventions
4. Implement source code in src/<module>/*.zig per the design
5. Write SQL migration file(s) in migrations/ per the design spec
6. → fn:check-zig-build
   If FAIL: fix compilation errors; retry (counts as rework)
7. → fn:apply-migrations (test DB)
   If FAIL: fix migration SQL; retry
8. Build and formatting gate (mandatory — run before self-review):
   zig build check
   PI-03 gate (GH-293/ISS-0078): build (error sets fail via the normal compile exit
   code — no separate grep needed) + zig fmt --check scoped to this branch's changed
   .zig files. If non-zero: fix before proceeding.
9. Self-review checklist:
   [ ] No string interpolation of user input into SQL (prepared statements only)
   [ ] All allocations accept an allocator parameter
   [ ] No I/O inside transition.zig (if modified)
   [ ] Each error type is in the module's error set
   [ ] If any function signature changed: verify all call sites compile
   [ ] New public functions have a doc comment (one line)
10. → fn:register-inner-report
11. → fn:complete-handoff (status: PASS/FAIL,
                            artifacts_out: ["src/...", "migrations/NNN_*.sql"],
                            next_action: "Route to TEST-DESIGNER once Step 2b also complete")
```

### Acceptance criteria for this step

- [ ] `zig build` exits 0 with no "error set" warnings in stderr
- [ ] All migrations apply cleanly against fresh DB
- [ ] No SQL string interpolation of user data
- [ ] Pure transition function has no I/O (if modified)
- [ ] All callers of any changed function signature compile without error

---

## Step 2b — Frontend Implementation

**Agent:** `FRONTEND-DEV`  
**Functions:** `fn:read-frontend-conventions`, `fn:check-frontend-build`, `fn:check-frontend-types`, `fn:check-frontend-lint`

### Procedure

```
1. Verify current branch:
   git branch --show-current  →  must equal feature/<run-id> from context.branch_name
   If not on the correct branch: STOP; report FAIL to ORCH before touching any file.
2. Read src/design/<module>.md for frontend components/hooks
3. → fn:read-frontend-conventions
4. Implement components in web/src/ per the design
5. → fn:check-frontend-types
   If FAIL: fix TypeScript errors; retry
6. → fn:check-frontend-lint
   If FAIL: fix lint errors; retry (warnings do not block)
7. → fn:check-frontend-build
   If FAIL: fix build errors; retry
8. Self-review checklist:
   [ ] No raw API calls in components (all via api/ modules)
   [ ] Destructive actions use ConfirmDialog
   [ ] Role-gating hides (not disables) unauthorized elements
   [ ] All interactive elements have accessible labels
   [ ] No hardcoded hex colors (all from design token variables)
   [ ] Token never stored in localStorage/sessionStorage
9. → fn:register-inner-report
10. → fn:complete-handoff (status: PASS/FAIL,
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
5. → fn:register-inner-report
6. → fn:complete-handoff (status: PASS/FAIL,
                           artifacts_out: ["tests/specs/...", "tests/unit/...", ...],
                           next_action: "Route to TEST-RUNNER")
```

### Acceptance criteria for this step

- [ ] Every MUST requirement in context.requirement_ids has at least one test case
- [ ] Test specs are written before test code (spec file present for each test file)
- [ ] No test depends on wall-clock time or random values without a fixed seed

---

## Step 3b — Test Design Gate ⛔ HARD GATE

**Agent:** `TEST-DESIGN-VALIDATOR`  
**Functions:** `fn:load-requirements`, `fn:load-test-specs`

### Procedure

```
1. Read test spec files and test source files in context.artifacts_in
2. → fn:load-requirements (context.requirement_ids)
3. For each MUST requirement, verify ALL of:
   a. At least one runnable integration test file exists targeting that requirement
   b. No `error.SkipZigTest` on test blocks covering MUST criteria without a counterpart
      separately-passing integration test
   c. No "TODO: implement test" or deferred spec cases in the spec file
   d. Count of spec cases in .md matches count of test functions in .zig (within ±1)
   e. Every integration test fixture uses a per-test UUID (not shared mutable state)
   f. Every integration test has a `defer cleanup()` or equivalent teardown
   g. Tests fail clearly (non-zero exit, meaningful error) if BPM_TEST_DB_URL is absent
      (silent skip or exit-0 on missing env is NOT acceptable)
   h. Tests are self-sufficient — they do not depend on other tests running first
   i. No hardcoded secrets or connection strings in test files
   j. Parameterised SQL used for all DB operations (no string interpolation of test data)
4. FAIL immediately on any check failure — do not attempt partial approval
5. If the failure is infrastructure-related (e.g., BPM_TEST_DB_URL missing from CI env):
   FAIL with severity BLOCKER and note: "ORCH must route ADHOC BACKEND-DEV handoff to
   set up test environment before TEST-RUNNER can run"
6. → fn:complete-handoff (status: PASS | FAIL,
                           issues: [list of failed checks with requirement ID and test file],
                           next_action: "Route to TEST-RUNNER (Step 4)" | "Rework TEST-DESIGNER")
```

### Gate rule

- **PASS** → ORCH verifies bench env (`zig build bench 2>&1 | head -5`), then dispatches TEST-RUNNER
- **FAIL** → ORCH increments `rework_count` on TEST-DESIGNER handoff and re-routes; TEST-RUNNER does NOT start until this gate is PASS

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
7. → fn:register-inner-report
8. → fn:complete-handoff (status: PASS/FAIL/PARTIAL,
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

When TEST-RUNNER returns FAIL for non-compile errors **in this run's own implementation**,
that is this run's own failure: ORCH reworks the responsible agent (BACKEND-DEV /
FRONTEND-DEV, or TEST-DESIGNER if the test itself is wrong) per ORCHESTRATOR.md §4.2, then
returns to this Step 4 to re-verify. This stays on the run's existing branch and does not
create a new run.

If the same full-suite run also surfaces failures unrelated to what TEST-RUNNER was
dispatched to check (pre-existing regressions this implementation didn't cause), those are
**filed and forwarded to the global queue** per `docs/agents/protocols/ISSUE_QUEUE.md` —
they do not block this step's own PASS verdict, and they are not fixed in this run. They
become their own WF-03 runs later.

---

## Step 5 — Release Validation

**Agent:** `RELEASE-VALIDATOR`  
**Functions:** `fn:load-requirement-status`, `fn:run-nfr-benchmarks`, `fn:run-integration-tests`, `fn:check-doc-freshness`

### ORCH pre-dispatch benchmark environment check

**ORCH MUST run this check before dispatching RELEASE-VALIDATOR.**

```powershell
# PowerShell
zig build test-env-verify
if ($LASTEXITCODE -ne 0) {
    Write-Host "BLOCKED: test environment not ready — route to BACKEND-DEV first"
    exit 1
}
Write-Host "CLEARED: test environment ready"
```

```bash
# bash / CI
zig build test-env-verify || { echo "BLOCKED: test environment not ready"; exit 1; }
echo "CLEARED: test environment ready"
```

> **Judge this gate by the exit code, never by matching text in the output.**
> This check previously grepped `zig build bench` stdout for `BPM_DB_URL` /
> `BENCHMARK_SETUP_ERROR` / `missing`. On 2026-05-30 an ADHOC handoff was phrased as
> "no such token in head output", and the agent satisfied it by renaming those labels
> in `tests/bench/bench.zig` rather than fixing the environment. A pass-condition an
> implementing agent can rewrite will eventually be rewritten instead of met. See
> `docs/anti-patterns.md`.

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
6. → fn:register-inner-report
7. → fn:complete-handoff (status: PASS/FAIL,
                           next_action: PASS → "Route to DOC-UPDATER"
                                        FAIL → "Identify blocker and route to correct agent")
```

On FAIL, `ORCH` inspects the blocking issue type:
- NFR benchmark failure caused by this run's implementation → `BACKEND-DEV` (performance
  work), as rework on this run's existing branch
- Benchmark environment missing → `BACKEND-DEV` (env provisioning; run pre-check again before next RV dispatch)
- Test regression caused by this run → rework the responsible agent on this branch
- Pre-existing failure or NFR gap this run did not cause → file and forward to the global
  queue per `docs/agents/protocols/ISSUE_QUEUE.md`; do not fix it in this run
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
5. → fn:register-inner-report
6. → fn:complete-handoff (status: PASS,
                           next_action: "Route to BACKEND-DEV or FRONTEND-DEV for Step Final")
```

---

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` (backend/mixed runs) or `FRONTEND-DEV` (frontend-only runs) — same agent as Step 00
**Protocol:** `docs/agents/protocols/GIT_MERGE.md`
**Precondition:** Step 6 (DOC-UPDATER) returned PASS. This step follows it directly — there
is no queue check between them.

ORCH supplies `context.branch_name` and `context.requirement_ids` in this handoff.
Use DOC-UPDATER's `result.summary` as the commit and PR one-line summary, and list this
run's requirement IDs in the PR body. If the run forwarded any incidental discoveries to
the global queue, list their `ISS-NNNN` IDs under a "Forwarded, not fixed here" note.
Follow GIT_MERGE.md exactly.

---

## Parallel Execution Rule

Steps 2a (backend) and 2b (frontend) MAY run in parallel when both are present. Both run on the same feature branch created in Step 00. ORCH MUST wait for both to return PASS before routing to Step 3. ORCH MUST NOT assign overlapping `owned_modules` to two concurrent WF-02 runs (see ORCHESTRATOR.md §10 Parallel-Host Coordination).
