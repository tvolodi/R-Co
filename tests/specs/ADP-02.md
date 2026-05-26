# Test Spec: ADP-02 — Tenant Column on Definition, Instance, and Audit Tables

**Requirement:** ADP-02 — The definition, instance, task, transition, and audit tables include additive `tenant_id` with default-tenant backward compatibility; tenant scoping must prevent cross-tenant leakage.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ADP-02-01: migration provisions tenant columns, tenant indexes, and tenant policies
**Given:** Migrations are applied in the integration database.  
**When:** Schema metadata and policy metadata are queried for ADP-02 tables.  
**Then:** All six ADP-02 tables expose non-null `tenant_id` defaults and tenant indexes/policies required by migration `028_adp02_tenant_scope_persistence.sql`.  
**Layer:** integration  
**Acceptance criterion mapped:** ADP-02 additive schema/index/policy contract is present.

### TC-ADP-02-02: definition uniqueness is tenant-partitioned and reads are tenant-scoped
**Given:** Two tenants write the same definition name/version pair.  
**When:** Reads are executed once per tenant scope.  
**Then:** Each tenant observes only its own row and no cross-tenant definition row is visible.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant leakage is blocked for definition persistence and retrieval.

### TC-ADP-02-03: instance persistence is tenant-scoped with default-tenant fallback
**Given:** Two tenant-scoped instance rows share correlation values, and a legacy-style write omits explicit tenant context.  
**When:** Instance reads are executed under each tenant scope and on the legacy/default path.  
**Then:** Each tenant sees only its own row, and the legacy/default write resolves to tenant `00000000-0000-0000-0000-000000000000`.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant isolation and default-tenant compatibility for instance persistence.

### TC-ADP-02-04: task and transition persistence are isolated across tenants
**Given:** Two tenants each create one token row and one task row for analogous instance flow state.  
**When:** Token/task reads are executed in each tenant scope.  
**Then:** Each scope returns only in-tenant token/task rows; out-of-tenant IDs are not visible.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant isolation for task and transition persistence paths.

### TC-ADP-02-05: audit persistence is tenant-scoped for audit_entries and audit_log
**Given:** Two tenants append audit rows into both `audit_entries` and `audit_log`.  
**When:** Audit reads are executed per tenant scope.  
**Then:** Each tenant reads only its own audit rows from both tables.  
**Layer:** integration  
**Acceptance criterion mapped:** Cross-tenant isolation for OBS-03 audit persistence paths.

## Traceability

- ADP-02 acceptance criteria: TC-ADP-02-01, TC-ADP-02-02, TC-ADP-02-03, TC-ADP-02-04, TC-ADP-02-05.
- Regression linkage PD-01 (create definition path): TC-ADP-02-02.
- Regression linkage PD-07 (definition retrieval path): TC-ADP-02-02.
- Regression linkage EE-01 (instance start persistence path): TC-ADP-02-03.
- Regression linkage OBS-03 (audit persistence path): TC-ADP-02-05.

## Execution Notes For TEST-RUNNER

- Test source file: `tests/integration/adp02_tenant_scope_test.zig`.
- Required env: `BPM_TEST_DB_URL` reachable and migration-capable.
- Tests use deterministic UUID fixtures and explicit tenant context switching via `set_config('bpm.tenant_id', ..., false)`.