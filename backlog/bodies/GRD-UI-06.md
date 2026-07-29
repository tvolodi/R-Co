> An accessibility gate SHALL run `@axe-core/playwright` against each canonical surface - Task Inbox, Instance List, Instance Detail, Definition List, Process Designer and Login - as one Playwright test per surface against the real backend. Any violation with impact `serious` or `critical` SHALL fail the gate, naming the rule ID, the impact and the target selector. Violations with impact `moderate` or `minor` SHALL be recorded in the run report at severity MINOR and SHALL NOT block. The `color-contrast` rule SHALL remain enabled, because the gate executes in a real Chromium page where pixel measurement is available.

**Acceptance Criteria:**
- GIVEN each of the six canonical surfaces loaded against the real backend with seeded data, WHEN axe runs on it in a Playwright test, THEN the gate fails on any `serious` or `critical` violation and the failure names the rule ID, the impact and the target selector; no HTTP mocking is used.
- GIVEN the axe configuration for the gate, WHEN it is read, THEN `color-contrast` is not in the disabled rule set.
- GIVEN a `moderate` violation on the Instance Detail surface, WHEN the gate completes, THEN it exits 0 and the violation is written to `tests/reports/report-<date>-<run_id>.yaml` at severity MINOR.
- GIVEN Keycloak, PostgreSQL or the API is unreachable, WHEN the gate starts, THEN it returns FAIL with severity BLOCKER naming the unreachable services and runs no surface, rather than reporting a clean pass.
- GIVEN a tenant brand override applied per CMP-UI-04, WHEN the gate runs on the Task Inbox, THEN `color-contrast` reports no `serious` violation for text drawn on `--surface-card`.
- GIVEN all six surfaces, WHEN the gate runs, THEN each completes within a 30 s budget.

**See:** GRD-UI-07, CMP-UI-01, CMP-UI-04, TK-UI-01, IN-UI-05, PD-UI-07
