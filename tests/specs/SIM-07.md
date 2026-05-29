# Test Spec: SIM-07 - Scenario runner

**Requirement:** SIM-07 - The platform MUST provide an API to run a scenario against a specific definition version and return a structured result (pass/fail per assertion, full event trace, timing).
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SIM-07-01: Run API returns structured result fields
**Given:** A valid scenario payload for a definition version
**When:** The scenario run API is invoked
**Then:** The response includes runId, passed, elapsedMs, assertionResults, and eventTrace
**Layer:** integration
**Acceptance criterion mapped:** POST /test/run returns a structured result

### TC-SIM-07-02: Run API includes per-assertion pass/fail results
**Given:** A valid scenario with multiple assertions
**When:** The scenario run API is invoked
**Then:** The response includes assertion result entries with assertion ID/type and pass/fail status
**Layer:** integration
**Acceptance criterion mapped:** Result includes pass/fail status per assertion
