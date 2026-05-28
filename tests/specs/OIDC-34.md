# Test Spec: OIDC-34 — Migration helper

**Requirement:** OIDC-34 — Platform SHOULD provide admin helper APIs to enumerate unmigrated users and assist bulk OIDC provisioning/linking.

**Priority:** SHOULD
**Test layer:** integration

## Test Cases

### TC-OIDC-34-01: Unlinked internal user enumeration returns only internal users without external linkage
**Given:** Test users with mixed auth_source and external_id states
**When:** listUnlinkedInternalUsers is executed
**Then:** Result set contains only internal users with external_id NULL
**Layer:** integration
**Acceptance criterion mapped:** Admin can list unmigrated users

### TC-OIDC-34-02: Agent-prefixed principals are excluded from migration candidates
**Given:** Internal user whose username starts with agent-
**When:** listUnlinkedInternalUsers is executed
**Then:** Agent identity is excluded from candidate list
**Layer:** integration
**Acceptance criterion mapped:** Agent test identities remain outside migration helper candidate set

### TC-OIDC-34-03: Tenant-scoped enumeration limits candidates to requested tenant
**Given:** Internal users across multiple tenants
**When:** listUnlinkedInternalUsers is called with tenant_id filter
**Then:** Only users belonging to the requested tenant are returned
**Layer:** integration
**Acceptance criterion mapped:** Candidate enumeration supports tenant-scoped rollout controls

## Planned test source and execution
- tests/integration/oidc34_migration_helper_test.zig
- Command: zig build test-integration
