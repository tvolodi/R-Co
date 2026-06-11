# Test Spec: ENV-02 — Test tenant is fully isolated from its paired production tenant

**Requirement:** ENV-02 — A test tenant's schema isolation from its paired production tenant is identical to its isolation from any unrelated tenant.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ENV-02-01: Test tenant search_path does not include production tenant schema
**Given:** Tenant T (production) and tenant T-test (test, linked to T) are both provisioned  
**When:** A connection is acquired scoped to T-test (via `tenant_context_mod.set(T-test-id)`)  
**Then:** `SHOW search_path` returns a path containing `tenant_<T-test-uuid>` but NOT `tenant_<T-uuid>`  
**Layer:** integration  
**Acceptance criterion mapped:** `search_path` is set to `tenant_<T-test-uuid>, public`; T's schema is not in path

### TC-ENV-02-02: Unqualified query in T-test resolves to T-test schema only
**Given:** T-test is provisioned; T's `process_definitions` has a row; T-test's `process_definitions` is empty  
**When:** `SELECT COUNT(*) FROM process_definitions` is executed on a T-test connection  
**Then:** Returns 0 (T-test's own empty table), not T's row count  
**Layer:** integration  
**Acceptance criterion mapped:** Unqualified table references in T-test resolve to `tenant_<T-test-uuid>.process_definitions`

### TC-ENV-02-03: Qualified cross-schema access fails or returns no production data
**Given:** T-test and T are both provisioned; T has schema `tenant_<T-uuid-no-dashes>`  
**When:** A T-test connection attempts `SELECT * FROM tenant_<T-uuid-no-dashes>.process_definitions`  
**Then:** PostgreSQL returns an error (42501 insufficient_privilege or 42P01 undefined_table) — success code 00000 is FORBIDDEN  
**Layer:** integration  
**Acceptance criterion mapped:** Platform DB user has no cross-schema grants; qualified cross-schema query must fail
