# Test Spec: SIM-05 - Scenario schema

**Requirement:** SIM-05 - Scenarios MUST conform to a stable JSON schema including: definition reference, initial variables, sequence of user actions, mocked service responses, expected events, expected final state.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SIM-05-01: Schema submission succeeds for a valid versioned payload
**Given:** A scenario payload containing schema metadata, definition reference, initial variables, actions, mocks, and assertions
**When:** The payload is submitted to scenario validation
**Then:** Validation returns valid=true and no errors
**Layer:** integration
**Acceptance criterion mapped:** The scenario schema is versioned and validated on submission

### TC-SIM-05-02: Invalid schema payload is rejected with structured errors
**Given:** A scenario payload missing required schema fields
**When:** The payload is submitted to scenario validation
**Then:** Validation returns 422 with structured errors that include failing paths
**Layer:** integration
**Acceptance criterion mapped:** Invalid scenarios are rejected at submission time with structured errors

### TC-SIM-05-03: Unsupported schema version is rejected
**Given:** A scenario payload with an unsupported schema version
**When:** The payload is submitted to scenario validation
**Then:** Validation fails with an unsupported schema version response
**Layer:** integration
**Acceptance criterion mapped:** The scenario schema is versioned and version checks are enforced
