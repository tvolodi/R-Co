# Test Spec: OIDC-22 — Bootstrap agent identity

**Requirement:** OIDC-22 — Bootstrap succeeds once, then disables until manual re-enable.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-22-01: First bootstrap success disables subsequent bootstrap calls
**Given:** A fresh bootstrap store
**When:** bootstrapFirstAgent is called twice
**Then:** First call succeeds and disables bootstrap; second call returns BootstrapDisabled
**Layer:** unit
**Acceptance criterion mapped:** First-run bootstrap succeeds once, then disables

### TC-OIDC-22-02: Manual re-enable allows bootstrap again
**Given:** A bootstrap store disabled by first success
**When:** setBootstrapEnabled(true) is executed and bootstrap is retried
**Then:** Retry succeeds and store disables again
**Layer:** unit
**Acceptance criterion mapped:** Re-enable requires explicit manual action

### TC-OIDC-22-03: Bootstrap singleton and audit event constraints are enforced
**Given:** A real PostgreSQL database with bootstrap state and audit tables
**When:** Duplicate singleton rows or invalid audit event types are inserted
**Then:** Invalid writes are rejected by constraints
**Layer:** integration
**Acceptance criterion mapped:** Bootstrap enable/disable state has auditable and controlled transitions
