# Test Spec: OIDC-18 — Provisioning transactional semantics

**Requirement:** OIDC-18 — Multi-step bundle provisioning must behave atomically from API perspective with reverse-order compensation on failure.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-18-01: Failed step triggers compensation and marks transaction not committed
**Given:** A transaction plan where a mid-step execute function fails
**When:** Transaction execution is run
**Then:** Result indicates committed=false, compensated=true, and failed_step points to failing index
**Layer:** unit
**Acceptance criterion mapped:** Failure leaves equivalent pre-request state via rollback

### TC-OIDC-18-02: Compensation order is reverse of successful forward steps
**Given:** Forward steps completed before failure
**When:** Compensation is executed
**Then:** Compensation calls occur in reverse completion order
**Layer:** unit
**Acceptance criterion mapped:** Reverse-order compensating delete behavior

### TC-OIDC-18-03: Transaction log stores forward and compensation records
**Given:** A real PostgreSQL database and a bundle transaction ID
**When:** Forward and compensation log rows are persisted
**Then:** Both directions are queryable for the same transaction as timeline evidence
**Layer:** integration
**Acceptance criterion mapped:** Transaction semantics are externally auditable
