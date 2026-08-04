# Test Designer Inner Report - WF02-f3a-batch1-20260529 Step 03 Rework 1

Agent: TEST-DESIGNER
Run ID: WF02-f3a-batch1-20260529
Handoff ID: f3a-step03r1-008
Related validator handoff: f3a-step03b-007
Date: 2026-05-29

## Rework objective

Close all hard-gate findings from TEST-DESIGN-VALIDATOR for IN-UI-01, IN-UI-02, IN-UI-03, IN-UI-04:
- spec/test count mismatch
- shared fixtures via beforeAll
- missing cleanup hooks
- missing per-test UUID fixtures
- hardcoded credentials
- self-sufficiency assumptions

## Changes completed

1. Spec and test parity remediated to 8/8:
- tests/specs/IN-UI-01.md now maps to TC-INUI01-01 and TC-INUI01-02
- tests/specs/IN-UI-02.md now maps to TC-INUI02-01 and TC-INUI02-02
- tests/specs/IN-UI-03.md now maps to TC-INUI03-01 and TC-INUI03-02
- tests/specs/IN-UI-04.md now maps to TC-INUI04-01 and TC-INUI04-02
- web/tests/e2e/f3-instance-monitoring.e2e.spec.ts now contains 8 requirement-mapped Playwright tests

2. Fixture isolation remediated:
- Removed shared mutable fixture setup from beforeAll
- Added per-test fixture state keyed by Playwright testId
- Added per-test fixture creation helper with isolated seeded data

3. Cleanup remediated:
- Added afterEach cleanup hook for created instances and definitions
- Added afterAll state clear hook

4. Per-test UUID policy remediated:
- Replaced Date.now fixture identifiers with randomUUID-based labels

5. Hardcoded credential violation remediated:
- Removed hardcoded username/password constants from source
- Added required env var usage: E2E_KEYCLOAK_USERNAME and E2E_KEYCLOAK_PASSWORD

6. Self-sufficiency remediated:
- Added explicit prerequisite checks with clear failure messages:
  - backend readiness endpoint
  - IDP OIDC discovery endpoint
  - required auth env vars

## Validation evidence

Playwright execution after rework:
- Command: npx playwright test tests/e2e/f3-instance-monitoring.e2e.spec.ts
- Result: 7 passed, 1 failed
- Remaining failing case: TC-INUI02-02 (definition filter URL persistence after full reload)
- Failure is a product behavior mismatch in current app flow, not one of the Step 03b structural hard-gate violations.

## Completeness decision

PASS for Step 03 rework scope.
All validator-listed structural and policy findings were remediated in specs and test implementation.

## Artifacts out

- tests/specs/IN-UI-01.md
- tests/specs/IN-UI-02.md
- tests/specs/IN-UI-03.md
- tests/specs/IN-UI-04.md
- web/tests/e2e/f3-instance-monitoring.e2e.spec.ts
- docs/issue-reports/WF02-f3a-batch1-20260529-step-03-rework1-test-designer-INNER-REPORT.md
