# Test Design Report: SCH-06 — Timer jitter

**Run ID:** WF02-sch06-20260523  
**Agent:** TEST-DESIGNER  
**Date:** 2026-05-23  

## Summary

Test specs and additional test code for requirement SCH-06 (Timer jitter) have been completed.

## Artifacts produced

| Artifact | Path |
|---|---|
| Test spec | `tests/specs/SCH-06.md` |
| Additional test cases (TC-SCH-06-14 through TC-SCH-06-16) | `tests/unit/sch06_timer_jitter_test.zig` |

## Coverage verification

### Acceptance criteria

| AC ID | Criterion | Covered by | Status |
|---|---|---|---|
| AC-01 | Jitter delay in range base ± jitter | TC-SCH-06-03, TC-SCH-06-13, TC-SCH-06-14, TC-SCH-06-16 | ✅ Covered |
| AC-02 | Independent randomisation per node | TC-SCH-06-10, TC-SCH-06-15 | ✅ Covered |
| AC-03 | Default jitter is 0 (disabled) | TC-SCH-06-01, TC-SCH-06-02, TC-SCH-06-08, TC-SCH-06-11 | ✅ Covered |
| AC-04 | Jitter not applied to fire_at | Design inspection (verified in scheduler.zig) | ✅ Verified |
| AC-EC-01 | Jitter > base clamped to 0 | TC-SCH-06-04 | ✅ Covered |

### New test cases added

| Test ID | Description | Layer |
|---|---|---|
| TC-SCH-06-14 | Minimum jitter (jitter_ms=1) covers both range extremes | unit |
| TC-SCH-06-15 | Different Scheduler instances have independent PRNG seeds | unit |
| TC-SCH-06-16 | Range covers most of [base-jitter, base+jitter] interval | unit |

## Existing test suite

All 13 existing tests (TC-SCH-06-01 through TC-SCH-06-13) remain unchanged and pass.

## Validation

`zig build test` exits 0 — all 16 SCH-06 tests pass (9 inline in scheduler.zig + 7 in sch06_timer_jitter_test.zig).
