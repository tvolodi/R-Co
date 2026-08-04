# WF03 Stage11 SIM05-08 Issue Fixer Report (Step 01)

- Handoff ID: 6a7aa30d-f4fc-4788-b855-2b00a84cef56
- Run ID: WF03-stage11-sim05-08-testfix-20260529
- Category: E_ENVIRONMENT
- Timestamp (UTC): 2026-05-29T11:16:23Z

## Diagnosis

- Failure symptom from WF02 Step 04 rework2: integration execution repeatedly appeared stalled at `db_integration_test.test.TC-DB-01-01: migrations`.
- Prior issue search matched historical contention patterns (ISS-0050/ISS-0051): overlapping integration runners and startup contention can create non-deterministic hangs.
- Classification: Environment contention in integration startup path (not SIM assertion logic defect).

## Fix Applied

1. `tests/integration/helpers.zig`
- Added `configureSessionTimeouts()` and applied it during `TestHarness.init()`.
- Session settings:
  - `lock_timeout = 5s`
  - `statement_timeout = 60s`
  - `idle_in_transaction_session_timeout = 120s`
- Result: integration harness now fails fast under contention instead of waiting indefinitely.

2. `build.zig`
- Added focused target `test-integration-sim05-08` bound to `tests/integration/sim05_08_scenario_runner_test.zig` with existing integration imports and pre-clean step.
- Enables deterministic requirement-scoped reruns for SIM-05..SIM-08.

3. `tests/unit/db_test.zig`
- Fixed unit-test compile blocker by switching pool imports to `@import("bpm").pool.*` (matching current build wiring).

## Verification

- `zig build` -> PASS
- `zig build test` -> PASS
- `zig build test-integration-sim05-08 --summary all` (with BPM env vars set) -> PASS
  - `Build Summary: 5/5 steps succeeded; 18/18 tests passed`
  - `SIM0508_INTEGRATION_EXIT_CODE=0`

## Artifacts

- `tests/integration/helpers.zig`
- `build.zig`
- `tests/unit/db_test.zig`
- `docs/issues/ISS-0057.json`
- `docs/issues/issue_index.json`
