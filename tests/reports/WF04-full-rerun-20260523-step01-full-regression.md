# WF04 Full Regression Rerun Report

- Run ID: WF04-full-rerun-20260523
- Step: 01 (TEST-RUNNER)
- Timestamp (UTC): 2026-05-23T15:16:33Z
- Handoff: handoffs/WF04-full-rerun-20260523/step-01-test-runner.json

## Execution Summary

Required command sequence executed exactly as requested:

1. `zig build` -> PASS (exit 0)
2. `zig build test` -> PASS (exit 0)
3. `zig build test-integration` -> FAIL (exit 1)
4. `cd web && npm run type-check` -> PASS (exit 0)
5. `cd web && npm run build` -> PASS (exit 0)
6. `cd web && npm run test` -> FAIL (exit 1)

Overall verdict: FAIL

Failing commands: 2/6

## Command Outputs (Failures)

### 3) zig build test-integration (FAIL)

Output excerpt:

```text
failed command: ".\\.zig-cache\\o\\2673dc44c18f99ee281a5c88b1c3226d\\test.exe" "--cache-dir=.\\.zig-cache" --seed=0x135bd1ad --listen=-

Build Summary: 2/4 steps succeeded (1 failed); 145/152 tests passed (6 skipped, 1 failed)
test-integration transitive failure
+- run test 145 pass, 6 skip, 1 fail (152 total); 919 leaks

error: the following build command failed with exit code 1:
.zig-cache\o\8676ce4e768cc763e3d5046c842afa80\build.exe ... test-integration
```

Primary failing test signal in output:

```text
error: 'api03_instance_read_test.test.TC-API-03-20: getById returns null correlation_key when not set at create time' leaked ... allocations
```

### 6) cd web && npm run test (FAIL)

Output:

```text
> bpm-web@0.1.0 test
> vitest run

No test files found, exiting with code 1
```

Count: 0 discovered test files.

## Severity Classification (Per Handoff Rules)

- MAJOR: `TC-API-03-20` integration failure with allocator leaks (requirement ID: API-03, SHOULD)
  - Affected files from stack/output:
    - `tests/integration/api03_instance_read_test.zig`
    - `src/engine/instance.zig`
    - `src/engine/transition.zig`
- MINOR: Frontend unit test command failed because no test files were found in `web/`.

No BLOCKER failures were identified from this run output.

## Artifacts

- Report: `tests/reports/WF04-full-rerun-20260523-step01-full-regression.md`
- Integration raw output: `tests/reports/WF04-full-rerun-20260523-step01-integration-output.log`
