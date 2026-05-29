# Test Spec: SIM-02 - Service mocking

**Requirement:** SIM-02 - In simulation mode, calls to external services MUST be intercepted and answered from a scenario-supplied mock catalog. Real network calls MUST NOT occur during simulation.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-SIM-02-01: Service call resolves from mock catalog
**Given:** A simulation context and a mock catalog entry for service key plus request fingerprint
**When:** executeMockedServiceCall is invoked with the matching key and fingerprint
**Then:** The configured mock response is returned
**Layer:** unit
**Acceptance criterion mapped:** A scenario specifying a mock response for service X causes that mock to be returned

### TC-SIM-02-02: Missing mock returns deterministic miss without fallback
**Given:** A simulation context and an empty mock catalog for requested key+fingerprint
**When:** executeMockedServiceCall is invoked
**Then:** The call fails with MockResponseNotFound
**Layer:** unit
**Acceptance criterion mapped:** Simulation execution does not perform real network fallback when mock is absent
