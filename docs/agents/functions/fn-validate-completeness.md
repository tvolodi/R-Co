# fn:validate-completeness

**Category:** CTRL  
**Used by:** All agents — **MANDATORY before `fn:register-inner-report` when the handoff task involves implementation or testing**  
**Calls:** —

```
PURPOSE: Verify that every acceptance criterion in the handoff has been met with
         concrete evidence — not assumed. Prevents incomplete work from propagating
         to the next agent.

INPUT: handoff object (from fn:load-handoff), acceptance_criteria list

For each criterion in task.acceptance_criteria:
  1. Identify the criterion type:
     - Functionality  → evidence required: a passing test that exercises it
     - Error handling → evidence required: a test that triggers the error path
     - Performance    → evidence required: benchmark result meeting the target
     - API endpoint   → evidence required: integration test hitting the route
     - UI element     → evidence required: E2E test or Playwright screenshot
     - Migration      → evidence required: zig build migrate exits 0

  2. Verify the evidence EXISTS:
     - For tests: check the test file exists AND the test name covers the criterion
     - For benchmarks: check the bench output value against the NFR threshold
     - For migrations: check migration file exists and has been run

  3. If evidence is MISSING or INSUFFICIENT:
     - Mark criterion as UNMET
     - Record: {criterion: "<text>", type: "<type>", missing: "<what is needed>"}

RESULT:
  {
    "all_met": true | false,
    "criteria": [
      {
        "criterion": "<acceptance criterion text>",
        "type": "functionality | error_handling | performance | api | ui | migration",
        "status": "MET | UNMET",
        "evidence": "<test name or file or benchmark value>",
        "missing": "<description if UNMET>"
      }
    ]
  }

If all_met == false:
  → Do NOT call fn:register-inner-report or fn:complete-handoff
  → Fix the unmet criteria first, then re-run fn:validate-completeness
  → If a criterion cannot be met due to a blocker, escalate via fn:complete-handoff
    with status = FAILED and the unmet list in result.issues
```

**Evidence type mapping:**

| Criterion type | Required evidence |
|---|---|
| Functionality | Passing unit or integration test |
| Error handling | Test that asserts the error path returns correct error type |
| Performance | Benchmark output value ≤ NFR threshold |
| API endpoint | Integration test asserting HTTP status and response shape |
| UI / component | E2E test or Playwright screenshot |
| Migration | `zig build migrate` exits 0; migration file in `migrations/` |
| Documentation | File updated; no broken links |
