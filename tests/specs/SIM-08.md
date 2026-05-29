# Test Spec: SIM-08 - Batch execution

**Requirement:** SIM-08 - The runner MUST support batch execution of all scenarios for a definition version, with configurable parallelism per tenant.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SIM-08-01: Batch runner executes 100 scenarios and reports aggregate counts
**Given:** A batch payload containing 100 scenarios for one definition version
**When:** The batch runner is invoked with valid per-tenant parallelism
**Then:** The result reports total=100 with passed and failed counts consistent with scenario outcomes
**Layer:** integration
**Acceptance criterion mapped:** Runner supports batch execution for a definition version

### TC-SIM-08-02: Batch elapsed time is less than sequential aggregate under parallelism
**Given:** A batch run result and tenant parallelism greater than 1
**When:** Batch elapsedMs is compared with sequential aggregate elapsed from scenario results
**Then:** Batch elapsedMs is lower than sequential aggregate elapsed for the same batch
**Layer:** integration
**Acceptance criterion mapped:** Batch execution completes faster than sequential execution

### TC-SIM-08-03: Batch runner rejects invalid per-tenant parallelism
**Given:** A batch run request with per-tenant parallelism set to zero
**When:** The batch runner is invoked
**Then:** The call fails with InvalidParallelism
**Layer:** integration
**Acceptance criterion mapped:** Parallelism is configurable and validated per tenant
