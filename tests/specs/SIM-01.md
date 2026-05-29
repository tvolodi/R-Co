# Test Spec: SIM-01 - Simulation tenant

**Requirement:** SIM-01 - Every platform deployment MUST provide an internal simulation execution context that is isolated from all real tenants. Simulation runs MUST NOT produce events visible in any real tenant's event store.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SIM-01-01: Simulation events are isolated from real tenant queries
**Given:** A simulation run context with a deterministic simulation tenant and a real tenant with its own event
**When:** One event is appended through the simulation tenant path and one event is appended for the real tenant
**Then:** Real tenant event query returns only the real tenant event and excludes simulation tenant events
**Layer:** integration
**Acceptance criterion mapped:** Simulation events are stored separately and are not returned by tenant event queries
**Fixture isolation/cleanup:** Test creates per-test UUID-derived instance IDs, tenant IDs, and idempotency keys; it performs explicit DB teardown of inserted projections, sequence rows, events, and event registry rows in `defer` cleanup

### TC-SIM-01-02: Simulation tenant cannot be queried through real tenant query API
**Given:** A simulation tenant identifier derived from a simulation run
**When:** Tenant event query API is called with the simulation tenant identifier
**Then:** The call fails with SimulationVisibilityViolation
**Layer:** integration
**Acceptance criterion mapped:** Simulation events are isolated from real tenant read paths
**Fixture isolation/cleanup:** Test performs explicit tenant-scoped teardown in `defer` cleanup so simulation-tenant fixtures cannot leak across tests
