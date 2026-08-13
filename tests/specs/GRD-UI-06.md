# Test Spec: GRD-UI-06 — Accessibility gate per canonical surface

**Requirement:** GRD-UI-06 — An axe-core based accessibility gate must run against the six canonical surfaces (Task Inbox, Instance List, Instance Detail, Definition List, Process Designer, Login), fail the run on any `serious` or `critical` violation, record `moderate` / `minor` violations at `MINOR` severity, and never disable the `color-contrast` rule.
**Priority:** MUST
**Test layer:** unit (Vitest — decision matrix, config), e2e (Playwright — axe-core via `@axe-core/playwright`, no mocks)

**Design reference:** `src/design/pw13-pw16-batch19-20260813.md` §3.1–§3.9, §5.3, §12.3.

**Six canonical surfaces:**

| # | Surface | Route |
|---|---|---|
| 1 | Task Inbox | `/tasks/inbox` |
| 2 | Instance List | `/instances/board` |
| 3 | Instance Detail | `/instances/:id` |
| 4 | Definition List | `/definitions` |
| 5 | Process Designer | `/definitions/:id` (editor) |
| 6 | Login | `/` (post-redirect OIDC callback) |

## Test Cases

### TC-GRD-UI-06-01: a11yConfig has no disabled rules; color-contrast is NOT in the disabled set
**Given:** the `a11yConfig` module exports the axe configuration
**When:** `Object.keys(a11yConfig.rules)` is inspected
**Then:** the rules object is empty (no rules disabled); `'color-contrast' in a11yConfig.rules` is `false`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-2 + §12.3 mode 4
**Implemented by:** `web/tests/unit/a11yConfig.test.ts` (`TC-AC-01`)

### TC-GRD-UI-06-02: a11yTags include the WCAG 2.1 A + AA tag set
**Given:** the `a11yTags` export
**When:** the array is inspected
**Then:** it contains `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-1 (axe tag set)
**Implemented by:** `web/tests/unit/a11yConfig.test.ts` (`TC-AC-02`)

### TC-GRD-UI-06-03: per-surface 30-second axe timeout
**Given:** `a11yRuleTimeoutMs` is exported
**When:** its value is read
**Then:** it equals `30_000`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-6
**Implemented by:** `web/tests/unit/a11yConfig.test.ts` (`TC-AC-03`)

### TC-GRD-UI-06-04: impact → severity decision matrix
**Given:** the `impactToSeverity` function and a synthetic axe violation list
**When:** the matrix is applied
**Then:**
- `serious` → `CRITICAL`
- `critical` → `CRITICAL`
- `moderate` → `MINOR`
- `minor` → `MINOR`
- `null` → `MINOR`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-1, AC-3
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-01..05`)

### TC-GRD-UI-06-05: classifyViolations maps impacts across a list
**Given:** a heterogeneous list with `serious` + `moderate` violations
**When:** `classifyViolations(surface, list)` is called
**Then:** the returned objects have `severity: 'CRITICAL'` and `severity: 'MINOR'` respectively
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-1, AC-3
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-06`)

### TC-GRD-UI-06-06: aggregateBlockingViolations returns only CRITICAL entries
**Given:** a list with one `serious` and one `moderate` violation
**When:** `aggregateBlockingViolations` is called
**Then:** the result has length 1 and that entry's `severity === 'CRITICAL'`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-1
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-07`)

### TC-GRD-UI-06-07: report writer renders YAML with empty list, one entry, multiple entries
**Given:** the `renderYamlReport` function
**When:** called with empty / single / multiple violations
**Then:** the output contains `runId`, `evaluatedSurfaces`, and either no `ruleId:` lines or matching ones per entry
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-3
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-08`)

### TC-GRD-UI-06-08: writeReport throws BLOCKER on directory collision
**Given:** the target YAML path collides with an existing directory
**When:** `writeReport(…)` is called
**Then:** it rejects with an error message containing `A11Y GATE BLOCKER`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-3 + §12.3 mode 5
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-09`)

### TC-GRD-UI-06-09: utcDateStamp returns YYYY-MM-DD in UTC
**Given:** a `Date(Date.UTC(2026, 0, 5))`
**When:** `utcDateStamp(date)` is called
**Then:** the result equals `"2026-01-05"`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-06 AC-3 (report path: `report-<date>-<run_id>.yaml`)
**Implemented by:** `web/tests/unit/a11yGate.test.ts` (`TC-AG-10`)

### TC-GRD-UI-06-10: real backend reachability probe (Keycloak + BPM API + PostgreSQL)
**Given:** the test environment has Keycloak at `BPM_IDP_BASE_URL`, BPM API at `BPM_TEST_URL`, and PostgreSQL at `BPM_TEST_DB_URL`
**When:** `verifyBackendReachable()` is called
**Then:** it resolves with no value (all three probes returned `ok`)
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-4
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-PROBE`)

### TC-GRD-UI-06-11: BLOCKER if any of Keycloak / BPM-API / PostgreSQL unreachable
**Given:** the BPM API is stopped (or pointed at a closed port)
**When:** `verifyBackendReachable({ apiBase: 'http://127.0.0.1:1' })` is called
**Then:** it rejects with an error message matching `/A11Y GATE BLOCKER/` and naming the failed service
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-4 + §12.3 mode 1
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-BLOCKER`)

### TC-GRD-UI-06-12: each canonical surface passes the axe gate (no serious / critical)
**Given:** the seeded data has 1 PENDING task for `worker-user`, 1 ACTIVE instance, 1 ACTIVE definition
**When:** each of the 6 surfaces is loaded and axe-core is run
**Then:** the gate does not throw (no `serious` / `critical` violations)
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-1, AC-6
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-SURFACE-01..06`)

### TC-GRD-UI-06-13: serious violation fails the gate with ruleId + impact + target
**Given:** the test fixture injects an `aria-valid-attr-value` violation (test-only build flag, NOT a mock of the application)
**When:** the gate runs against `/tasks/inbox`
**Then:** `runA11yGate` throws an `Error` whose message includes the rule id, the impact, and the target selector
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-1
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-FAIL`)

### TC-GRD-UI-06-14: moderate impact recorded-only; YAML report has severity MINOR
**Given:** the gate receives a synthetic `moderate` violation
**When:** `runA11yGate` returns
**Then:** the result has `severity: 'MINOR'`; the YAML file at `web/tests/reports/report-<date>-<run_id>.yaml` contains the violation with `severity: "MINOR"`
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-3
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-MINOR`)

### TC-GRD-UI-06-15: Task Inbox brand-override contrast check (axe + computed-style belt-and-braces)
**Given:** the seeded tenant has a non-default brand override active (`CMP-UI-04`)
**When:** axe scans `/tasks/inbox` AND a computed-style probe reads `[data-testid="task-row"]`'s `background-color` and text `color`
**Then:** no `serious` / `critical` `color-contrast` violation is reported; the computed contrast ratio is ≥ 4.5:1
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-5
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-CONTRAST`)

### TC-GRD-UI-06-16: per-surface runtime is bounded to 30 s
**Given:** the gate is run on each surface
**When:** the elapsed time is logged
**Then:** each surface completes in `< 30_000 ms` (the gate's own timeout)
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-06 AC-6 + §12.3 mode 2
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-BUDGET`)

### TC-GRD-UI-06-17: axe unknown rule ID is reported verbatim (no swallow)
**Given:** a synthetic violation with `ruleId: 'unknown-rule-2099-future'`
**When:** the gate fails the surface
**Then:** the thrown error and the YAML report both contain that exact rule ID
**Layer:** e2e
**Acceptance criterion mapped:** §12.3 mode 3
**Implemented by:** `web/tests/e2e/a11y-gate.e2e.spec.ts` (`TC-GRD-UI-06-E2E-UNKNOWN-RULE`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| GRD-UI-06 AC-1: serious/critical violation fails the gate with ruleId + impact + target | `TC-GRD-UI-06-04..06`, `TC-GRD-UI-06-13` |
| GRD-UI-06 AC-2: color-contrast is NOT disabled | `TC-GRD-UI-06-01` |
| GRD-UI-06 AC-3: moderate → MINOR; report written | `TC-GRD-UI-06-04`, `TC-GRD-UI-06-07`, `TC-GRD-UI-06-14` |
| GRD-UI-06 AC-4: BLOCKER if Keycloak / API / DB unreachable | `TC-GRD-UI-06-10`, `TC-GRD-UI-06-11` |
| GRD-UI-06 AC-5: brand-override contrast on Task Inbox | `TC-GRD-UI-06-15` |
| GRD-UI-06 AC-6: 30 s per-surface budget | `TC-GRD-UI-06-03`, `TC-GRD-UI-06-16` |
| §12.3 mode 1: Keycloak/API/PostgreSQL unreachable | `TC-GRD-UI-06-11` |
| §12.3 mode 2: 30 s budget exceeded | `TC-GRD-UI-06-16` |
| §12.3 mode 3: unknown rule ID | `TC-GRD-UI-06-17` |
| §12.3 mode 4: color-contrast disabled trip-wire | `TC-GRD-UI-06-01` |
| §12.3 mode 5: YAML write failure → BLOCKER | `TC-GRD-UI-06-08` |

## Acceptance Test Coverage Matrix

| AC | E2E | Unit | Status |
|---|---|---|---|
| AC-1 | `TC-GRD-UI-06-13`, `TC-GRD-UI-06-12` | `TC-GRD-UI-06-04..06` | COVERED |
| AC-2 | (covered by AC-5 E2E) | `TC-GRD-UI-06-01` | COVERED |
| AC-3 | `TC-GRD-UI-06-14` | `TC-GRD-UI-06-07` | COVERED |
| AC-4 | `TC-GRD-UI-06-11` | (n/a — network probes) | COVERED |
| AC-5 | `TC-GRD-UI-06-15` | (covered by AC-2 unit) | COVERED |
| AC-6 | `TC-GRD-UI-06-16` | `TC-GRD-UI-06-03` | COVERED |
| §12.3 mode 1 | `TC-GRD-UI-06-11` | (covered by AC-4 E2E) | COVERED |
| §12.3 mode 2 | `TC-GRD-UI-06-16` | (covered by AC-6) | COVERED |
| §12.3 mode 3 | `TC-GRD-UI-06-17` | (covered) | COVERED |
| §12.3 mode 4 | (covered) | `TC-GRD-UI-06-01` | COVERED |
| §12.3 mode 5 | (covered) | `TC-GRD-UI-06-08` | COVERED |

## Execution Notes For TEST-RUNNER

- The six canonical surfaces are loaded by Playwright with `verifyBackendReachable()` called inside `beforeAll`. Each surface uses `test.setTimeout(30_000)` per design §3.5.
- The `@axe-core/playwright` package is a dev dependency (design §7.2). If it is missing in a CI environment, the test must `test.skip(true, '@axe-core/playwright not installed')` — never silently swallow.
- Per-test isolation: each surface loads its own seeded data via a unique task/instance/definition UUID created via the BPM API. The `afterEach` block deletes the seeded row.
- The brand-override contrast assertion is independent of axe's colour picker — it reads the computed `background-color` and `color` of `[data-testid="task-row"]` and asserts a `4.5:1` ratio per WCAG AA.
