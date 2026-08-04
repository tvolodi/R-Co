# Issue Fix Report - ADHOC-fix-integration-20260528 Step 05

- Timestamp: 2026-05-29T07:19:43Z
- Agent: ISSUE-FIXER
- Handoff: 20260528-audit-isolation-fix

## Scope
Fix all currently failing tests observed in baseline run.

## Diagnosis
- Category: D - Test error / stale test assumptions
- Failures were concentrated in Playwright E2E suites:
  - F2 definition list tests assumed created definitions would always appear in the first unfiltered page.
  - OBS-04 timeline test used obsolete email/password login selectors while app uses token-based login.

## Fixes Applied
1. Updated F2 E2E tests to filter by unique test suffix before row visibility assertions.
2. Updated OBS-04 E2E login flow to token-based UI selectors and added deterministic health check route stub.

## Verification
- `npx --no-install playwright test tests/e2e/f2-definition-list.e2e.spec.ts tests/e2e/obs04.timeline.e2e.spec.ts --reporter=list` => 14 passed
- `npx --no-install playwright test --reporter=list` => 54 passed
- `npm run type-check` => exit 0
- `zig build` => exit 0
- `zig build test` => exit 0

## Artifacts
- web/tests/e2e/f2-definition-list.e2e.spec.ts
- web/tests/e2e/obs04.timeline.e2e.spec.ts
