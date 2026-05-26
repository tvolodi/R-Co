# Test Spec: ADP-03 — Tenant Context Resolution on API

**Requirement:** ADP-03 — Bearer tokens without `tenant_id` resolve to default tenant, tokens with `tenant_id` scope all operations to that tenant, and the API blocks cross-tenant operations within a request while preserving API-08 auth behavior.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ADP-03-01: legacy token without tenant claim resolves deterministically to default tenant
**Given:** An authenticated legacy opaque token payload without a `tenant_id` claim.  
**When:** Tenant context is resolved repeatedly for the same token in the same process.  
**Then:** Every resolution returns tenant `00000000-0000-0000-0000-000000000000` and source `default_fallback`.  
**Layer:** integration  
**Acceptance criterion mapped:** A token without `tenant_id` behaves identically to pre-migration.

### TC-ADP-03-02: token with tenant_id claim resolves deterministically to claim tenant
**Given:** A JWT-like token payload containing `tenant_id = 22222222-2222-2222-2222-222222222222`.  
**When:** Tenant context is resolved repeatedly for the same token.  
**Then:** Every resolution returns that tenant and source `token_claim`.  
**Layer:** integration  
**Acceptance criterion mapped:** A token with `tenant_id` scopes operations to that tenant.

### TC-ADP-03-03: resolved tenant context is applied to request-scoped DB session behavior
**Given:** A token with `tenant_id` claim is resolved in middleware-equivalent flow.  
**When:** The resolved tenant is injected through `set_config('bpm.tenant_id', ...)` and request-scoped queries execute.  
**Then:** `bpm_effective_tenant_id()` and tenant-filtered reads operate only within that tenant context.  
**Layer:** integration  
**Acceptance criterion mapped:** Token claim tenant scopes subsequent operations.

### TC-ADP-03-04: malformed tenant claim is rejected before any scoped operation
**Given:** A JWT-like token with malformed `tenant_id` claim (`not-a-uuid`).  
**When:** Tenant resolution runs before request execution.  
**Then:** Resolution fails with `InvalidTenantClaimFormat` and no tenant-scoped persistence/read operation is attempted.  
**Layer:** integration  
**Acceptance criterion mapped:** Invalid tenant claim path is explicitly handled while preserving API-08 auth semantics.

### TC-ADP-03-05: cross-tenant read visibility is blocked under request tenant scope
**Given:** Two tenants each own a process definition row with distinct IDs.  
**When:** A request scoped to tenant A queries tenant B's row ID (and vice versa) using tenant-filtered predicates.  
**Then:** Each out-of-tenant read yields zero visible rows.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant operation is prevented within a request.

### TC-ADP-03-06: cross-tenant mutation attempt is rejected by tenant-scoped predicates
**Given:** Two tenants each own a process definition row with distinct IDs.  
**When:** A request scoped to tenant A attempts to mutate tenant B's row using repository-style `WHERE id = ... AND tenant_id = bpm_effective_tenant_id()`.  
**Then:** The update affects zero rows; no cross-tenant mutation occurs.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant request behavior is rejected for write paths.

### TC-ADP-03-07: legacy default-tenant compatibility remains intact for request persistence flow
**Given:** A legacy token without `tenant_id` claim and a write path that omits explicit `tenant_id`.  
**When:** The request runs under resolved default tenant context and writes a new row via DB defaults.  
**Then:** The row persists with tenant `00000000-0000-0000-0000-000000000000` and remains readable in default tenant scope only.  
**Layer:** integration  
**Acceptance criterion mapped:** Default-tenant compatibility is explicitly validated for legacy tokens.

## Traceability

- ADP-03 acceptance criteria:
  - Token without `tenant_id` compatibility: TC-ADP-03-01, TC-ADP-03-07.
  - Token with `tenant_id` scoping: TC-ADP-03-02, TC-ADP-03-03.
  - Cross-tenant prevention in-request: TC-ADP-03-05, TC-ADP-03-06.
- API-08 (Bearer authentication semantics preserved): TC-ADP-03-04 (invalid claim treated as auth failure path), TC-ADP-03-01 (legacy token continuity).
- OIDC-13 (tenant claim is trusted IdP claim and not client override): TC-ADP-03-02, TC-ADP-03-04.
- ADP-01 (tenant-scoped event-store baseline consumed by API context): TC-ADP-03-03.
- ADP-02 (tenant-scoped definition/instance/task/audit persistence consumed by API context): TC-ADP-03-05, TC-ADP-03-06, TC-ADP-03-07.

## Execution Notes For TEST-RUNNER

- Test source file: `tests/integration/adp03_tenant_context_resolution_test.zig`.
- Required env: `BPM_TEST_DB_URL` reachable and migration-capable.
- Isolation assertions must use tenant-aware predicates (`tenant_id = bpm_effective_tenant_id()`) to validate request-scope behavior.
- Cleanup must clear seeded rows in both tenant scopes to keep the suite order-independent.
