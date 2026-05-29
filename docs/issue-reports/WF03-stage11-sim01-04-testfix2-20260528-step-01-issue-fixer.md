# WF03 Stage11 SIM01-04 Testfix2 - ISSUE-FIXER Report

## Handoff
- handoff_id: 5f8f21cf-f771-4ed3-a5d8-11b6e9be7a3f
- run_id: WF03-stage11-sim01-04-testfix2-20260528
- completed_at: 2026-05-28T17:03:11Z

## Diagnosis
- Category D/E blend: test-suite orchestration contamination and compatibility-trigger dependence in XC-05 fixture inserts.
- Prior issue knowledge checked from docs/issues/issue_index.json; relevant prior Stage11 and XC issue clusters were reviewed.

## Changes Applied
- build.zig
  - Added per-suite database cleanup commands for aggregate `test-integration` dependencies.
  - Wired each integration run artifact (`run_integration_tests`, OIDC08-15, OIDC34/35, XC01-06) to a dedicated clean command.
- tests/integration/xc05_deterministic_replay_test.zig
  - Added explicit `actor_id` and `sequence_number` fields to event inserts.
  - Replaced sequence text allocations with stack-buffer formatting.
  - Hardened idempotency keys to be instance-scoped.
- docs/issues/issue_index.json
  - Registered ISS-0047 (OPEN/BLOCKER) for remaining aggregate failures.

## Validation
- `zig build` -> pass
- `zig build test` -> pass
- `zig build test-xc05` -> pass
- `zig build test-integration` -> fail
  - Summary: `51/54 steps succeeded (2 failed); 420/472 tests passed (8 skipped, 44 failed)`
  - Remaining blocker includes `TC-SIM-01-01` and aggregate `TC-XC-05-05` failure path in full run.

## Outcome
- Partial improvement achieved.
- Aggregate integration remains blocked; follow-up WF-03 issue-fix rework is required for SIM-01 and remaining cross-module failures.
