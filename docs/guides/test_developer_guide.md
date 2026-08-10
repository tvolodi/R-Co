# BPM Platform — Test Developer Guide

**Version:** 0.2 · 2026-08-01 (infrastructure rules added — see §12)  
**Agent ID:** `TEST-DESIGNER`, `TEST-RUNNER`  
**Audience:** Test Designer agent, Test Runner agent, Issue Fixer agent

> **See also:** `docs/guides/test_infrastructure_guide.md` — authoritative rules for test infrastructure health, the Green-Main gate, schema contract tests, and the three infrastructure invariants (INV-TI-1 through INV-TI-3). Those rules supersede this guide where they conflict.

---

## 1. Test Philosophy

### Core Testing Directives

> These three directives are absolute. They take precedence over every other rule in this guide.
> A handoff that violates any directive MUST be marked FAILED — it cannot be marked PASS.

**DIRECTIVE T-1 — No backend mocks or stubs**
Backend tests MUST execute against a real PostgreSQL database. In-memory databases, mock DB connections, fake repositories, and stub return values are FORBIDDEN in backend tests. The only permitted exception is code that calls a system outside project control (a third-party payment gateway, an external OAuth provider, etc.) — those call sites MAY use recorded HTTP fixtures (not dynamically generated mock responses). `error.SkipZigTest` does not constitute a passing test result. Any MUST requirement whose test cases are entirely skipped retains status `PENDING` — it does NOT advance to `TESTED`.

**DIRECTIVE T-2 — No frontend mocks or stubs**
Frontend tests MUST send requests to the real running backend server connected to a real database. MSW (Mock Service Worker), axios-mock-adapter, manual `fetch` intercepts, and any mechanism that prevents a real HTTP call from reaching the backend are FORBIDDEN. Test setup must start the backend server and seed required data via API calls before any browser scenario begins. The test flow is always: UI action → real HTTP request → real database write/read → UI state update.

**DIRECTIVE T-3 — Agents run visual E2E; no human UAT**
There is no human UAT step. Agents are responsible for all acceptance testing. After each significant UI action, `TEST-RUNNER` MUST take a screenshot and visually inspect it to confirm the expected UI state before recording a PASS. "No errors thrown" is not a passing criterion. The verdict must be stated as: _"Screen shows X after action Y"_ — not _"the action completed without error"_.

---

### Additional philosophy

1. **Pure functions first.** The transition function and graph validator must have comprehensive unit tests before integration testing begins. A broken pure function breaks everything above it.
2. **Tests are specifications.** A passing test suite is proof that requirements are met. Every MUST requirement must have at least one test that would fail if the requirement were violated.
3. **Deterministic only.** Tests must not depend on wall-clock time, random IDs, or network responses. Use fixed seeds and frozen clocks.
4. **No test pollution.** Each test creates its own data and cleans up after itself. Tests must be runnable in any order.

---

## 2. Test Layer Hierarchy

```
E2E Tests (Playwright)
  └── Scenario-level: full user workflows through the browser
      Coverage target: critical user journeys per stage (not exhaustive)

Integration Tests (Zig, real PostgreSQL)
  └── Module-level: each backend subsystem against a real DB
      Coverage target: all DB-touching code paths + concurrency cases

Frontend Unit Tests (Vitest + Testing Library)
  └── Component and hook level: React components, hooks, utility functions
      Coverage target: ≥ 80% line coverage on non-UI logic

Backend Unit Tests (Zig built-in test framework)
  └── Pure function level: transition.zig, validator.zig, cel.zig
      Coverage target: ≥ 90% line coverage; 100% branch coverage on gateway logic
```

### 2.1 Scored test-tier rubric (GH-295 / ISS-0080 / PI-05)

`TEST-DESIGNER` re-derives which layers above a given change needs on every
run. Instead of judging that from scratch each time, score the change
against the dimensions below and read off the tier. This replaces intuition
with a checklist `TEST-DESIGN-VALIDATOR` can also apply mechanically when
checking the resulting test spec is proportionate.

**Score every dimension the change touches, then sum:**

| Dimension | Points | Touches... |
|---|---|---|
| DB schema | 2 | A migration file, a new/changed table, column, constraint, or index |
| Tenant isolation | 2 | Any tenant-scoped table, tenant-id filtering logic, or cross-tenant boundary (e.g. `FIL-06`, `QRY-04`, `DDL-05`) |
| Wasm | 2 | `src/wasm/**`, the sandbox capability model, or anything executing untrusted process code (e.g. `SBX-05`) |
| Cross-module | 1 | Call sites or contracts spanning ≥ 2 top-level modules (e.g. `src/engine/` calling into `src/repository/`) |
| Transactional boundary | 1 | Code inside or wrapping a DB transaction — commit/rollback ordering, multi-statement atomicity |

**Read off the tier from the total:**

| Total score | Required test tier |
|---|---|
| 0 | Unit only |
| 1–2 | Unit + integration |
| 3+ | Unit + integration + sandbox |

**Worked examples:**

1. A migration adding a column to a tenant-scoped table (e.g. one of the
   `GBL-1xx` schema-reconciliation migrations under `migrations/`) — DB
   schema (2) + tenant isolation (2) = **4 points → sandbox tier.**
2. A change to `src/wasm/capabilities.zig` gating which host functions a
   process definition can call — Wasm (2) + tenant isolation (2, capability
   grants are tenant-scoped) = **4 points → sandbox tier.**
3. A pure-function fix inside `src/engine/transition.zig` that does not
   change its signature or call any other module — 0 dimensions touched =
   **0 points → unit only.**
4. A new field added to a single existing API response, resolved entirely
   within one module and one transaction — cross-module (0, single module)
   + transactional boundary (1, the existing transaction wrapping the
   handler) = **1 point → unit + integration.**

Record the computed score and tier in the test spec header (`tests/specs/<REQ-ID>.md`,
see §3) so `TEST-DESIGN-VALIDATOR` can confirm the chosen layers match the
score without re-deriving it.

**Fail-first rule:** see the TEST-DESIGN-VALIDATOR checklist in `CLAUDE.md`
— every new or modified test must be confirmed to fail against the
pre-change code. A test that passes both before and after the change proves
nothing.

---

## 3. Test Specification Format

`TEST-DESIGNER` writes test specs to `tests/specs/<REQ-ID>.md` before any test code is written.

```markdown
# Test Spec: <REQ-ID> — <Requirement short name>

**Requirement:** <REQ-ID> — verbatim requirement text  
**Priority:** MUST / SHOULD / COULD  
**Test layer:** unit | integration | e2e (may list multiple)

## Test Cases

### TC-<REQ-ID>-01: <Test case name>
**Given:** <preconditions>  
**When:** <action>  
**Then:** <expected outcome>  
**Layer:** unit / integration / e2e  
**Acceptance criterion mapped:** <which part of the requirement this proves>

### TC-<REQ-ID>-02: ...
```

Every **MUST** requirement MUST have at least one test case at the integration or unit layer. E2E alone is not sufficient to mark a requirement as TESTED.

---

## 4. Backend Unit Tests (Zig)

### 4.1 Location and naming

| Source file | Test file |
|---|---|
| `src/engine/transition.zig` | `tests/unit/engine_test.zig` |
| `src/definition/validator.zig` | `tests/unit/validator_test.zig` |
| `src/engine/cel.zig` | `tests/unit/cel_test.zig` |

Each test file imports the module under test and uses Zig's built-in `test` blocks.

### 4.2 Test structure template

```zig
const std = @import("std");
const testing = std.testing;
const engine = @import("../../src/engine/transition.zig");

// Shared test fixtures
const test_snapshot = engine.DefinitionSnapshot{
    .definition_id = "00000000-0000-0000-0000-000000000001",
    .nodes = &[_]engine.Node{
        .{ .id = "start", .node_type = .START },
        .{ .id = "task1", .node_type = .HUMAN_TASK, .name = "Review" },
        .{ .id = "end",   .node_type = .END },
    },
    .edges = &[_]engine.Edge{
        .{ .id = "e1", .source = "start", .target = "task1" },
        .{ .id = "e2", .source = "task1", .target = "end" },
    },
};

test "TC-EE-02-01: transition START event places token on first task node" {
    const alloc = testing.allocator;
    const initial_state = engine.InstanceState.initial("inst-001");

    const result = try engine.transition(alloc, test_snapshot, initial_state, .{
        .event_type = .INSTANCE_STARTED,
        .payload = "{}",
    });

    try testing.expectEqual(result.status, .ACTIVE);
    try testing.expectEqual(result.active_tokens.len, 1);
    try testing.expectEqualStrings(result.active_tokens[0], "task1");
}

test "TC-EE-05-01: exclusive gateway follows first matching condition" { ... }
test "TC-EE-05-02: exclusive gateway uses default edge when no condition matches" { ... }
test "TC-EE-05-03: exclusive gateway transitions to ERROR when no match and no default" { ... }
test "TC-EE-07-01: parallel join waits for all incoming tokens" { ... }
test "TC-EE-09-02: variable collision overwrites and logs VARIABLE_OVERWRITTEN" { ... }
test "TC-EE-09-03: variable schema violation triggers EXECUTION_ERROR" { ... }
```

### 4.3 Required test cases for transition function

The following test cases are mandatory before any integration work begins:

| Test case ID | Covers |
|---|---|
| TC-EE-02-01 | START event → token on first node |
| TC-EE-02-02 | TASK_COMPLETED → token advances |
| TC-EE-02-03 | Pure function has no side effects (called twice → same result) |
| TC-EE-05-01 | EXCLUSIVE_GATEWAY: first matching condition wins |
| TC-EE-05-02 | EXCLUSIVE_GATEWAY: default edge fallback |
| TC-EE-05-03 | EXCLUSIVE_GATEWAY: ERROR when no match, no default |
| TC-EE-06-01 | PARALLEL_GATEWAY split: all outgoing tokens created |
| TC-EE-07-01 | PARALLEL_GATEWAY join: waits for all branches |
| TC-EE-07-02 | PARALLEL_GATEWAY join: cancelled branch excluded from count |
| TC-EE-09-01 | Variable insertion (new key) |
| TC-EE-09-02 | Variable overwrite (existing key, valid schema) |
| TC-EE-09-03 | Variable schema violation → EXECUTION_ERROR |
| TC-EE-10-01 | ERROR state is terminal (no further transitions) |
| TC-EE-11-01 | Replay of N events produces same state as persisted state |

---

## 5. Integration Tests (Zig + PostgreSQL)

### 5.1 Test database setup

Integration tests use a separate `bpm_test` database. The test harness:
1. Runs all migrations against `bpm_test` before the suite starts
2. Wraps each test in a transaction that is rolled back after the test — never commits
3. Provides a `TestPool` struct that returns a single transaction-wrapped connection

```zig
// tests/integration/helpers.zig
pub const TestHarness = struct {
    pool: *Pool,
    conn: *Conn,
    tx: *Transaction,

    pub fn init() !TestHarness { ... }
    pub fn deinit(self: *TestHarness) void {
        self.tx.rollback() catch {};
        // connection returned to pool
    }
};
```

### 5.2 Integration test template

```zig
test "TC-ES-03-01: duplicate idempotency key returns original event" {
    var h = try TestHarness.init();
    defer h.deinit();

    const args = AppendArgs{
        .instance_id = "inst-001",
        .event_type = "TASK_COMPLETED",
        .payload = "{}",
        .idempotency_key = "idem-key-001",
        .actor_id = null,
    };

    const first  = try event_store.append(h.tx, args);
    const second = try event_store.append(h.tx, args);  // duplicate

    try testing.expectEqualStrings(first.event_id, second.event_id);
}
```

### 5.3 Concurrency tests

At least one concurrency test per area where race conditions are possible:

| Area | Concurrency test |
|---|---|
| Event append | Two goroutines append with same idempotency key simultaneously |
| Parallel gateway join | Two tokens arrive simultaneously at join node |
| Timer firing | Two scheduler nodes race to fire the same timer |
| Task claim | Two workers claim same group task simultaneously |

---

## 6. Frontend Tests

Frontend testing follows **DIRECTIVE T-2**: the real backend and real database are always in the loop. There is no middleware interception layer.

### 6.1 What may be pure-unit tested (Vitest, no network)

Only code with zero dependency on the network or API client may be unit-tested in isolation:

| Target | Tool |
|---|---|
| Utility functions (`utils/`) | Vitest, no render |
| Zod validation schemas | Vitest, no render |
| Pure date / format helpers | Vitest, no render |

These are the only cases where no backend is required, because the code under test is a pure function.

### 6.2 What MUST be tested via E2E (Playwright + real backend)

Everything that touches the API layer or renders UI driven by API data MUST be covered by E2E tests:

- Custom hooks that call the API (`useInstances`, `useTasks`, etc.)
- Page and feature components
- Form submission flows
- UI state transitions after receiving API responses

### 6.3 MSW and all HTTP-level mocking are FORBIDDEN

MSW (Mock Service Worker), axios-mock-adapter, manual `fetch`/`XMLHttpRequest` intercepts, and any mechanism that prevents a real HTTP request from reaching the backend server are FORBIDDEN. This constraint is not negotiable and cannot be overridden per-test. A test that does not exercise the real backend is not a valid test.

### 6.4 Test file naming

- Pure unit test files: `web/src/utils/<name>.test.ts`
- E2E test files: `web/tests/e2e/<feature>.spec.ts`

---

## 7. E2E Tests (Playwright)

E2E tests follow **DIRECTIVE T-3**: agents run all acceptance tests using Playwright visual tools. There is no human UAT step.

### 7.1 Visual verification requirement

After every significant UI action, `TEST-RUNNER` MUST:

1. Take a screenshot using `page.screenshot()` or the VS Code browser visual tool
2. Inspect the screenshot and confirm the expected UI state is visible on screen
3. Record the verdict as: _"Screen shows X after action Y"_

"No errors thrown" is NOT a sufficient pass condition on its own. The agent must confirm visually.

### 7.2 Coverage targets (critical journeys per stage)

| Stage | Critical journeys to cover |
|---|---|
| F1 | Login → see task inbox; login with bad token → error message |
| F2 | Create definition → draw nodes → save → activate |
| F3 | Start instance → instance appears on board → cancel instance |
| F4 | Claim task → fill form → complete task → task removed from inbox |
| F5 | Create user → issue token → see token once → revoke token |
| F6 | Trigger DLQ item → inspect → retry |

### 7.3 Page Object Model

Each page has a corresponding Page Object class in `web/tests/e2e/pages/`:

```typescript
// web/tests/e2e/pages/TaskInboxPage.ts
export class TaskInboxPage {
  constructor(private page: Page) {}

  async goto() { await this.page.goto('/tasks') }
  async getTaskCount() { return this.page.locator('[data-testid="task-row"]').count() }
  async openTask(name: string) { await this.page.getByText(name).click() }
  async completeTask(fields: Record<string, string>) { ... }
}
```

### 7.4 Test data setup

E2E tests use the bootstrap token + a dedicated test user created at suite setup. The suite creates all required definitions, instances, and tasks via API calls before running browser scenarios.

---

## 8. Coverage Thresholds

| Layer | Metric | Threshold |
|---|---|---|
| Backend unit (pure functions) | Line coverage | ≥ 90% |
| Backend unit (gateway logic specifically) | Branch coverage | 100% |
| Integration tests | All MUST requirements have ≥1 passing (non-skipped) test | 100% |
| Frontend unit (pure functions / Zod schemas only) | Line coverage | ≥ 90% |
| E2E | Critical journeys per stage | 100% of listed journeys |

Coverage below threshold is a **BLOCKER** for release validation.

> A skipped test (`error.SkipZigTest` or `test.skip`) does NOT count toward coverage or toward a requirement reaching `TESTED` status. Skipped MUST-requirement tests are treated as missing tests.

---

## 9. Test Report Format

`TEST-RUNNER` writes reports to `tests/reports/report-<date>-<workflow>.yaml`. **YAML is required — `.json` reports are forbidden.**

```yaml
run_id: <uuid>
workflow_id: <WF-04 or WF-02>
timestamp: <ISO8601>
summary:
  total: 142
  passed: 138
  failed: 3
  skipped: 1
failures:
  - test_id: TC-EE-05-03
    layer: unit
    file: tests/unit/engine_test.zig
    error_message: "..."
    severity: BLOCKER
    requirement_id: EE-05
coverage:
  backend_unit_line: 92.4
  frontend_unit_line: 83.1
nfr_results:
  - nfr_id: NFR-01
    target: "p99 ≤ 200ms reads"
    actual: "p99 = 143ms"
    passed: true
```

---

## 10. CI Integration Notes

In CI (GitHub Actions or equivalent), tests run in this order:

```
1. zig build                         # compile check
2. zig build test                    # unit tests (no DB)
3. Start test PostgreSQL container
4. zig build migrate (test DB)
5. zig build test-integration        # integration tests
6. cd web && npm run test            # frontend unit tests
7. Start full stack (backend + frontend)
8. npx playwright test               # E2E tests
9. zig build bench                   # NFR benchmarks (on schedule or pre-release only)
```

Any failure in steps 1–6 blocks steps 7–9 (fail fast).

### 10.1 Flaky-test policy (GH-297 / ISS-0082)

A test is **flaky** when it fails intermittently for reasons unrelated to
the correctness of the code under test — timing, concurrency ordering,
shared fixture state — rather than because a change broke a genuine
assertion. See `docs/issues/ISS-0658.json` / `ISS-0659.json` for a worked
example of exactly this distinction being diagnosed rather than assumed.

When a test is suspected flaky:

1. Do not silently retry, sleep-loop, or delete the assertion to make it
   pass — that hides the underlying defect (same principle as CLAUDE.md's
   "Never Satisfy a Gate by Editing What It Measures").
2. File it the same way any other discovered defect is filed: an ISS
   registry entry and a GitHub issue (CLAUDE.md "No Issue Left
   Local-Only"), with root-cause evidence if already known, or a note that
   root-cause is still open if not.
3. Mark the test in source with a comment directly above the `test` block:
   ```zig
   // FLAKY(GH-<issue-number>): <one-line symptom>. Filed <date>.
   test "TC-XXX-NN description" { ... }
   ```
   This is a marker for humans and agents reading the file — there is
   currently no automated skip-on-PR mechanism, because none of the tests
   that run in `.github/workflows/ci.yml` today are the ones affected by
   this class of flakiness (the known case, `zig build test-integration`,
   is not part of that workflow at all — see
   `src/design/ci-gate-tiering.md` §2). If a flaky test is later added to a
   gate that runs on every PR, build the skip mechanism at that point,
   against the real case, rather than in advance of one.
4. **Fix within 48 hours of the marker being added, or disable the test.**
   ISSUE-FIXER and TEST-RUNNER should treat a `FLAKY` marker older than 48
   hours (compare the filed date in the comment against the current date)
   as a BLOCKER-worthy finding when encountered — an unresolved flaky
   marker is itself a defect at that point, not a documented one.
5. Once fixed, remove the `FLAKY(...)` comment in the same change that
   resolves the underlying issue, and mark the ISS/GitHub issue RESOLVED
   per the usual procedure.

---

## 11. Pipeline Tests

### 11.1 What pipeline tests are

Pipeline tests are multi-step E2E workflows where each step's output is the next step's input. Unlike island tests (one test = isolated setup → action → teardown), pipeline tests accumulate real system state across steps and intentionally abort the entire chain if any step fails.

**When to write a pipeline test:**
- The feature involves a sequence of user actions that depend on each other's side effects
- Testing step N in isolation without steps 1..N-1 is meaningless (e.g. you cannot assign a role to a user that doesn't exist yet)
- You want to validate the system as a coherent whole, not just individual screens

**Pipeline tests do NOT replace island tests.** Island tests remain required for every MUST requirement. Pipeline tests are the regression guard for user journeys.

### 11.2 File locations

| Artefact | Location |
|---|---|
| Shared helper | `web/tests/e2e/pipeline.ts` |
| Pipeline test files | `web/tests/e2e/pipelines/*.pipeline.e2e.spec.ts` |
| Pipeline specs | `tests/specs/PIPELINE-<slug>.md` |
| Checkpoint state (git-ignored) | `web/tests/e2e/.pipeline-state/` |
| Pipeline screenshots | `tests/screenshots/pipelines/` |

### 11.3 Test structure rules

1. **One `test()` block = one workflow.** All steps live inside a single Playwright `test()` using `test.step()` for named sub-steps.
2. **State flows forward** through a plain object (`pl.state`). Each step reads values written by earlier steps — no re-setup.
3. **One login per chain.** Obtain the token once at the top; refresh only if the chain is very long (see `refreshTokenIfNeeded` in `pipeline.ts`).
4. **Hard gates for chain preconditions.** Use `pl.gate(condition, message)` after the action that produces an ID or state the rest of the chain depends on. A gate failure aborts all remaining steps.
5. **Soft assertions for UI polish.** Use `expect.soft()` for cosmetic checks (badge visibility, column order) that should not abort the chain.
6. **Register cleanup with `pl.onCleanup()`** — always, even if the last step is the cleanup action. The cleanup handler runs unconditionally after the chain, whether it passed or aborted.
7. **Screenshot after each step.** `createPipeline` takes a screenshot automatically at the end of every `pl.step()`. Do not add redundant manual shots.

### 11.4 Pipeline spec format

Write a spec file at `tests/specs/PIPELINE-<slug>.md` before writing the test code:

```markdown
# Pipeline Spec: <slug> — <Human-readable title>

## Journey
<one sentence describing the end-to-end user workflow>

## Steps

| Step | Name | Produces | Reads | Gate condition |
|---|---|---|---|---|
| 1 | ADM-UI-01: user list columns | — | adminToken | adminToken present |
| 2 | ADM-UI-02: create user | userId, username | — | userId extracted from URL |
| 3 | ADM-UI-03a: update profile | — | userId | Saved message visible |
| 4 | ADM-UI-03b: assign role | — | userId | — |
| 5 | ADM-UI-04: deactivate user | — | userId | status = INACTIVE |

## Cleanup
<what the cleanup handler deactivates/deletes and via which API>

## Requirement coverage
ADM-UI-01, ADM-UI-02, ADM-UI-03, ADM-UI-04
```

### 11.5 Checkpoint / resume

The pipeline helper automatically saves state to `web/tests/e2e/.pipeline-state/<name>.json` after each step. To resume a chain from step N when debugging:

```typescript
const pl = createPipeline<MyState>('my-pipeline', { page, request }, { resumeFrom: 'my-pipeline' })
// State is pre-populated from the checkpoint. Steps that already ran
// are re-entered but their gate conditions pass immediately.
```

This directory is git-ignored. Never commit checkpoint files.

### 11.6 TEST-DESIGNER responsibilities

When a new requirement belongs to a feature area that has an existing pipeline journey:

1. Write the per-requirement spec in `tests/specs/<REQ-ID>.md` (unchanged — still required).
2. Open the relevant `web/tests/e2e/pipelines/*.pipeline.e2e.spec.ts` file and insert the new step at the correct position in the chain.
3. Update `tests/specs/PIPELINE-<slug>.md` to add the new step row.

When a new requirement starts a new journey (no pipeline file exists yet) AND at least one prior requirement is part of the same sequential user workflow:

1. Create `tests/specs/PIPELINE-<slug>.md` with the chain topology.
2. Create `web/tests/e2e/pipelines/<slug>.pipeline.e2e.spec.ts`.

### 11.7 TEST-DESIGN-VALIDATOR check

In addition to existing checks, verify:
- [ ] Every MUST requirement that involves a sequential UI action has a step in the relevant pipeline test (MAJOR if missing — does not block TESTED status but must be addressed before release)
- [ ] Pipeline spec file exists at `tests/specs/PIPELINE-<slug>.md` and lists all covered requirement IDs

### 11.8 TEST-RUNNER: running pipeline tests

Pipeline tests are discovered automatically by Playwright (they match `**/*.e2e.spec.ts`). No separate command is needed. Pipeline failures are reported as **MAJOR** severity in the test report — they indicate a broken user journey, but individual island tests remain authoritative for per-requirement TESTED status.

In the test report YAML, pipeline results appear under a dedicated section:

```yaml
pipeline_results:
  - pipeline: admin-user-lifecycle
    status: PASS | FAIL
    failed_step: "ADM-UI-03a: update profile"   # null if PASS
    checkpoint_state_path: tests/e2e/.pipeline-state/admin-user-lifecycle.json
    severity: MAJOR
```

### 11.9 ISSUE-FIXER: using pipeline state for diagnosis

When a pipeline test fails, the checkpoint file at `web/tests/e2e/.pipeline-state/<name>.json` contains the real system state at the point of failure (IDs of created objects, last known token, etc.). ISSUE-FIXER MUST read this file before diagnosing the failure — it eliminates the "reproduce from scratch" step and often directly names the failing precondition.

### 11.10 Current pipeline inventory

| File | Journey | Requirement coverage |
|---|---|---|
| `pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts` | Login → list users → create → update → assign role → deactivate | ADM-UI-01..04 |
| `pipelines/onboarding-wizard.pipeline.e2e.spec.ts` | PLATFORM_ADMIN: nav entry → fill form → progress spinner → result screen | ONB-UI-01..04 |

Add new rows to this table when creating new pipeline files.

---

## 12. Test Infrastructure Rules (summary — see `test_infrastructure_guide.md` for full detail)

This section is a required-reading summary. Agents MUST read `docs/guides/test_infrastructure_guide.md` in full before writing or running tests.

### 12.1 The three non-negotiable invariants

| Invariant | Rule |
|---|---|
| **INV-TI-1 Deterministic Baseline** | Before any integration test binary runs, `zig build migrate` must exit 0 and the live schema must match the migration ledger exactly |
| **INV-TI-2 Strict Isolation** | No test reads, writes, or depends on state created by any other test or prior run. Per-test UUIDs are mandatory. Cleanup is unconditional (defer before any state-creating call). |
| **INV-TI-3 Contract Parity** | Application constants (status strings, enum values) must match DB CHECK constraints exactly. SQL placeholders in ambiguous type contexts must carry an explicit `::type_name` cast. |

### 12.2 TEST-RUNNER pre-flight checklist

TEST-RUNNER MUST complete this checklist before dispatching any test binary. Each failure = STOP + return FAIL BLOCKER:

```
[ ] db_test container healthy
[ ] zig build migrate exits 0, no error output
[ ] public.schema_migrations row count == migrations/*.sql file count
[ ] all tenant schemas in public.tenants exist as PostgreSQL schemas
[ ] zig build exits 0
[ ] python3 tools/lint_test_isolation.py tests/integration exits 0, no BLOCKER
```

### 12.3 Schema contract tests

When BACKEND-DEV writes a migration that creates or modifies a `CHECK` constraint, the TEST-DESIGNER MUST add a schema contract test in `tests/integration/schema_contracts/`. The test must:

1. Insert every application-side valid value — all must succeed.
2. Insert a known-invalid value — must fail with PostgreSQL error `23514`.
3. Verify the constraint row exists in `information_schema.check_constraints`.

TEST-DESIGN-VALIDATOR must fail the handoff if a new constraint migration lacks a corresponding schema contract test.

### 12.4 Green-Main gate (Step 00a in WF-02 and WF-03)

ORCH must not start implementation work when existing integration tests are already failing. Step 00a (run by TEST-RUNNER against `main` before git-setup) is a hard gate. See `test_infrastructure_guide.md §4` for the full procedure.

### 12.5 Shared-table advisory-lock requirement (ISS-0659 / GH-681)

Integration tests that touch any of the **shared tables** below MUST serialize via
`helpers.acquireIntegrationLock()` for the binary's full lifetime, OR use
`helpers.TestHarness`. Direct `db.Pool` use against these tables without one of
those two patterns is a **BLOCKER at lint time** (enforced mechanically by
`tools/lint_test_isolation.py`).

**Shared tables** (any test writing to these races against concurrent binaries
under `zig build test-integration`):

| Schema | Tables |
|---|---|
| `tenant_default` | timers, events, dead_letter_items, instance_projections, tasks, process_definitions |
| `public` | `tenant`, `tenant_schemas`, and any DDL object in the `tenant_default` schema |

**Two valid patterns:**

1. **Use `helpers.TestHarness`** — acquires the `bpm_test_migrations_public`
   advisory lock for the binary's full lifetime (added in PR #494 / ISS-0162).
   Preferred when the test needs `resetTestData()` between cases.
2. **Use `helpers.acquireIntegrationLock(allocator)`** at the top of every
   `test "..."` block, with `defer helpers.releaseIntegrationLock(&lock_conn)`
   immediately after. Used by the 31 self-managed-pool binaries that open their
   own `db.Pool` (see `src/design/integration-test-advisory-lock.md` for the
   full list and the rationale). Per-test acquire is intentional: it gives
   finer-grained lock release on test failure.

**Forbidden:**

```zig
// ❌ FORBIDDEN — shared table + raw Pool without lock
var pool = try makePool(allocator, url);
try pool.acquire().?.exec("DELETE FROM tenant_default.timers", .{});
```

```zig
// ✅ CORRECT — shared table + raw Pool + acquireIntegrationLock
var lock_conn = try helpers.acquireIntegrationLock(std.heap.page_allocator);
defer helpers.releaseIntegrationLock(&lock_conn);
var pool = try makePool(allocator, url);
try pool.acquire().?.exec("DELETE FROM tenant_default.timers", .{});
```

The mechanical enforcement lives in
`tools/lint_test_isolation.py` (added in WF03-GH681-20260810): any
`tests/integration/*.zig` file that imports `bpm.pool.Pool` and references
neither `helpers.acquireIntegrationLock` nor `TestHarness` is flagged as
BLOCKER. Existing baseline entries for the 31 already-migrated files are
recorded in `tools/lint_test_isolation.baseline.json`.

Reference: [GH-681](https://github.com/tvolodi/R-Co/issues/681),
`src/design/integration-test-advisory-lock.md`.
