# Test Spec: OIDC-32 — Agent test identities

**Requirement:** OIDC-32 — Development realm seed MUST include service-account clients for agent-architect, agent-developer, and agent-devops with minimum required role grants.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-32-01: Seed artifact contains required agent clients with service accounts enabled
**Given:** infrastructure/keycloak/realms/bpm-default.json
**When:** Seed JSON is parsed
**Then:** Required clients exist and serviceAccountsEnabled is true for each
**Layer:** unit
**Acceptance criterion mapped:** Required agent clients are seeded

### TC-OIDC-32-02: Agent identity policy artifact declares AGENT_RUNNER minimum role
**Given:** infrastructure/keycloak/policies/agent-test-identities.json
**When:** Policy JSON is parsed
**Then:** Each required identity declares AGENT_RUNNER in requiredRoles
**Layer:** unit
**Acceptance criterion mapped:** Minimum-role policy is explicit and enforceable

### TC-OIDC-32-03: Integration verifier confirms seed and policy stay aligned
**Given:** Seed and policy artifacts from current branch
**When:** Agent identity verification tool runs
**Then:** Validation passes for all required identities
**Layer:** integration
**Acceptance criterion mapped:** Agent integration setup works without manual identity provisioning

## Planned test source and execution
- tests/unit/test_oidc32_agent_test_identities.zig
- tests/integration/oidc31_end_to_end_auth_suite_test.zig
- Command: zig build test
- Command: zig build test-integration-oidc31
