# fn:run-e2e-tests

**Category:** TEST  
**Used by:** `TEST-RUNNER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
PRE-CONDITION: Full stack running (backend + frontend + test DB)

1. Run island E2E tests:
     cd web && npx playwright test --reporter=json
   Parse Playwright JSON output.
   Collect: {test_name, file, status, screenshot_path_on_fail}

2. Run pipeline E2E tests:
     cd web && npx playwright test tests/e2e/pipelines/ --reporter=json
   Pipeline tests match **/*.pipeline.e2e.spec.ts and are discovered automatically
   (they match the global testMatch pattern), so step 1 already includes them
   when running the full suite. Run them separately only when targeting pipelines.

3. Classify results:
   - Island test failure        → severity per affected requirement (BLOCKER if MUST req)
   - Pipeline test failure      → MAJOR (broken user journey; does not block TESTED status
                                  for individual requirements, but blocks RELEASE)
   - Pipeline step that failed  → read from test.step() label in Playwright report
   - Checkpoint state           → web/tests/e2e/.pipeline-state/<name>.json
                                  (attach path to report for ISSUE-FIXER use)

4. Write results to tests/reports/report-<date>-<run_id>.yaml including:
   pipeline_results:
     - pipeline: <name>
       status: PASS | FAIL
       failed_step: "<step name or null>"
       checkpoint_state_path: "web/tests/e2e/.pipeline-state/<name>.json"
       severity: MAJOR
```
