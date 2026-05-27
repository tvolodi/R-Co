# Test Spec: OIDC-25 — Provider health check

**Requirement:** OIDC-25 — /health/ready includes provider connectivity check and reports degraded/recovered readiness.

**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-25-01: Provider probe success reports ready
**Given:** A readiness probe that succeeds
**When:** Provider readiness is checked
**Then:** checkProviderReadiness returns true and subsystem checker yields no identity_provider failure
**Layer:** unit
**Acceptance criterion mapped:** Recovery reflects on next readiness check

### TC-OIDC-25-02: Provider probe failure reports not-ready subsystem
**Given:** A readiness probe that fails
**When:** runCheckers evaluates default critical checkers
**Then:** Result includes identity_provider with IDP_NOT_READY retryable failure detail
**Layer:** unit
**Acceptance criterion mapped:** Downtime is reflected as provider subsystem not-ready

### TC-OIDC-25-03: Degraded then recovered transition is observable
**Given:** Probe configured to fail then reconfigured to pass
**When:** Readiness checks are run in sequence
**Then:** First check fails and subsequent check passes without manual reset
**Layer:** unit
**Acceptance criterion mapped:** Automatic readiness recovery behavior
