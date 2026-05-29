# Test Designer Report - WF02-f3a-batch1-20260529 Step 03

**Agent:** TEST-DESIGNER
**Run ID:** WF02-f3a-batch1-20260529
**Handoff ID:** f3a-step03-006
**Date:** 2026-05-29
**Requirements covered:** IN-UI-01, IN-UI-02, IN-UI-03, IN-UI-04

---

## Summary

Completed test-design artifacts for all MUST requirements in Stage F3 instance monitoring batch 1. Added four requirement-specific spec files and aligned Playwright source to one explicit test per requirement. No deferred or skipped MUST tests were introduced.

---

## Artifacts produced

- tests/specs/IN-UI-01.md
- tests/specs/IN-UI-02.md
- tests/specs/IN-UI-03.md
- tests/specs/IN-UI-04.md
- web/tests/e2e/f3-instance-monitoring.e2e.spec.ts

---

## Coverage verification

- Every MUST requirement has at least one implemented E2E test case.
- Test spec files exist for IN-UI-01 through IN-UI-04.
- Playwright suite contains one explicit requirement-mapped test block for each IN-UI requirement.
- No test.skip or deferred placeholders were added.
- No HTTP-level mocking was added.
