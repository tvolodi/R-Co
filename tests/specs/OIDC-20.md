# Test Spec: OIDC-20 — Service accounts for agents

**Requirement:** OIDC-20 — Each agent identity must map to dedicated provider client credentials with isolation and auth_source distinction.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-20-01: Agent kind taxonomy is explicit for all workflow agents
**Given:** The declared AgentKind enumeration
**When:** Agent kinds are enumerated
**Then:** Orchestrator, developer, tester, validator, and updater identities are represented
**Layer:** unit
**Acceptance criterion mapped:** Each agent has its own client identity slot

### TC-OIDC-20-02: Scope gate separates human and agent authorization paths
**Given:** Human and agent principals
**When:** Scope checks are evaluated for agent-scoped operations
**Then:** Principal role/scope requirements are enforced deterministically
**Layer:** unit
**Acceptance criterion mapped:** Agent tokens are differentiated by source and privilege

### TC-OIDC-20-03: Active binding uniqueness is isolated by realm and agent kind
**Given:** A real PostgreSQL database with agent_identity_binding
**When:** Multiple active rows are inserted for different kinds and duplicate same-kind rows are attempted
**Then:** Different kinds coexist; duplicate active same-kind row is rejected; revoked row can be replaced
**Layer:** integration
**Acceptance criterion mapped:** Revoking one agent credential does not affect others
