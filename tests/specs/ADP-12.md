# Test Spec: ADP-12 -- Default-tenant regression suite

**Requirement:** ADP-12 -- Before and after applying the schema migration, the platform MUST pass an automated regression suite exercising every Stage 1-6 endpoint against the default tenant. Diffs in response payloads (status, body, headers excluding new informational fields) MUST be zero.
**Priority:** MUST
**Test layer:** integration

## Acceptance Criteria Coverage

- Stage 1-6 default-tenant matrix is loaded with deterministic case identity and complete stage presence.
- Canonicalization excludes only the bounded informational allowlists (headers + JSON pointers) and preserves stable business fields.
- Pre/post execution yields deterministic zero-diff invariants and writes required ADP-12 report artifacts.
- Failure taxonomy is classified so TEST-RUNNER can distinguish requirement failures (`ResponseDiffDetected`, `SnapshotPairingMismatch`) from infrastructure/flaky failures (`FixtureSeedFailed`, `MigrationApplyFailed`, `AsyncStabilizationTimeout`, `FlakyBaselineDetected`).
- Release gate for ADP-12 remains strict: any diff, missing pair, or flaky signal is a FAIL.

## Test Cases

### TC-ADP-12-01: stage matrix includes deterministic Stage 1-6 coverage
**Given:** The ADP-12 regression coverage matrix loader.
**When:** The matrix is loaded for execution.
**Then:** The matrix includes entries for every stage 1 through 6, each case has non-empty deterministic identifiers (`case_id`, `route`, `method`), and cardinality is stable (`>= 44` baseline).
**Layer:** integration
**Acceptance criterion mapped:** Stage 1-6 endpoint coverage and deterministic pairing precondition.
**Implemented by:** `tests/integration/adp12_default_tenant_regression_test.zig` test `TC-ADP-12-01: stage matrix includes deterministic Stage 1-6 coverage`.

### TC-ADP-12-02: canonicalizer excludes only allowed informational fields
**Given:** A deterministic response payload containing both informational fields (`trace_id`, `timestamp`, `duration_ms`, tracing headers) and stable business fields.
**When:** The ADP-12 canonicalizer processes headers/body with ADP-12 allowlists.
**Then:** Only allowlisted informational fields are excluded; stable fields remain; non-allowlisted headers remain in canonical output.
**Layer:** integration
**Acceptance criterion mapped:** Canonicalization exclusions and flaky-signal control via bounded exclusion surface.
**Implemented by:** `tests/integration/adp12_default_tenant_regression_test.zig` test `TC-ADP-12-02: canonicalizer excludes only allowed informational fields`.

### TC-ADP-12-03: deterministic pre/post suite emits zero diff report artifacts
**Given:** Deterministic ADP-12 matrix, migration metadata available, and report writer configured.
**When:** The orchestrator executes pre/post comparison and writes report artifacts.
**Then:** Pre/post counts and pair counts match matrix size, `zero_diff_pass == true`, `flaky_signals_detected == false`, and summary artifact includes `"requirement_id":"ADP-12"` and `"zero_diff":true`.
**Layer:** integration
**Acceptance criterion mapped:** Deterministic pass/fail criteria for zero-diff invariants and report artifact generation.
**Implemented by:** `tests/integration/adp12_default_tenant_regression_test.zig` test `TC-ADP-12-03: deterministic pre/post suite emits zero diff report artifacts`.

## Deterministic Pass/Fail Rules (ADP-12 Gate)

- PASS only when all compared pairs satisfy `status_equal && headers_equal && body_equal`.
- PASS only when `pre_case_count == post_case_count == pair_count` and equals matrix cardinality.
- PASS only when `flaky_signals_detected == false`.
- FAIL when any diff or pairing mismatch exists.
- FAIL when baseline flake gate detects unstable pre-migration canonical outputs.
- FAIL when harness/migration execution errors occur before comparison.

## Expected Execution Artifacts

- `tests/reports/adp12/adp12-regression-summary.json`
- `tests/reports/adp12/pre-snapshots.ndjson`
- `tests/reports/adp12/post-snapshots.ndjson`
- `tests/reports/adp12/diffs.ndjson`
- `tests/reports/adp12/flaky-signals.json`

## Failure Classification For TEST-RUNNER

| Classification | Error signals | ADP-12 outcome |
|---|---|---|
| Requirement regression FAIL | `ResponseDiffDetected`, `SnapshotPairingMismatch` | FAIL |
| Flaky gate FAIL | `FlakyBaselineDetected` | FAIL |
| Infrastructure FAIL | `FixtureSeedFailed`, `MigrationApplyFailed`, `PhaseExecutionFailed`, `AsyncStabilizationTimeout`, `ReportWriteFailed` | FAIL |

## Traceability Matrix

| ADP-12 acceptance area | Deterministic evidence |
|---|---|
| Stage 1-6 matrix coverage for default tenant | `TC-ADP-12-01` |
| Canonicalization exclusions are bounded and deterministic | `TC-ADP-12-02` |
| Pre/post zero-diff invariants and report outputs | `TC-ADP-12-03` |
| Release gate fail conditions (diff/pairing/flaky/infrastructure) | `TC-ADP-12-03` + error taxonomy mapping |

## Execution Notes For TEST-RUNNER

- Primary target: `zig build test-integration` (with `BPM_TEST_DB_URL` set).
- Focus file: `tests/integration/adp12_default_tenant_regression_test.zig`.
- Focus filters: `TC-ADP-12-*`.
- Artifact verification paths: `tests/reports/adp12/*`.
