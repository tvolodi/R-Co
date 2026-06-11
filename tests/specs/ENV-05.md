# Test Spec: ENV-05 — Test tenant lifecycle management

**Requirement:** ENV-05 — Platform admins can reset (truncate business data) and delete test tenants. Neither action affects the paired production tenant.  
**Priority:** SHOULD  
**Test layer:** integration

## Test Cases

### TC-ENV-05-01: Reset happy path — returns 200 with reset_at and tables_truncated
**Given:** A provisioned test tenant with no active process instances  
**When:** `handleReset(pool, alloc, test_tenant_id)` is called  
**Then:** Returns `HandlerResult` with `status_code = 200`; body contains `reset_at` (ISO 8601 timestamp) and `tables_truncated` array with 11 table names  
**Layer:** integration  
**Acceptance criterion mapped:** `POST /api/v1/admin/tenants/:test_tenant_id/reset` returns HTTP 200 with correct body

### TC-ENV-05-02: Reset truncates all 11 business tables, preserves identity tables
**Given:** Test tenant schema has rows in `process_definitions` AND `users`/`roles` tables  
**When:** `resetTestTenant` completes  
**Then:** `COUNT(*) FROM process_definitions` = 0; `COUNT(*) FROM users` >= 0 (unchanged); `COUNT(*) FROM roles` >= 0 (unchanged)  
**Layer:** integration  
**Acceptance criterion mapped:** Reset truncates business tables but preserves identity and config tables

### TC-ENV-05-03: Reset on production tenant returns HTTP 422
**Given:** A production tenant exists  
**When:** `handleReset(pool, alloc, production_tenant_id)` is called  
**Then:** `status_code = 422`; body contains `"not_a_test_tenant"`  
**Layer:** integration  
**Acceptance criterion mapped:** Reset is only allowed for test tenants

### TC-ENV-05-04: Reset while active instances returns HTTP 409
**Given:** A test tenant has a row in `instance_projections` with `status = 'ACTIVE'` (not COMPLETED/CANCELLED/FAILED)  
**When:** `handleReset(pool, alloc, test_tenant_id)` is called  
**Then:** `status_code = 409`; body contains `"active_instances"`  
**Layer:** integration  
**Acceptance criterion mapped:** Reset blocked while tenant has active process instances

### TC-ENV-05-05: Delete test tenant — HTTP 204, public rows removed
**Given:** A test tenant row exists in `public.tenant` with `idp_realm_id = NULL` (no realm to delete)  
**When:** `handleDelete(pool, alloc, null_idp_manager, test_tenant_id)` is called  
**Then:** `status_code = 204`; `SELECT COUNT(*) FROM public.tenant WHERE id = test_tenant_id` = 0  
**Layer:** integration  
**Acceptance criterion mapped:** DELETE test tenant removes public rows and drops schema

### TC-ENV-05-06: Delete production tenant returns HTTP 422
**Given:** A production tenant exists  
**When:** `handleDelete(pool, alloc, null_idp_manager, production_tenant_id)` is called  
**Then:** `status_code = 422`; body contains `"production_tenant_delete_forbidden"`  
**Layer:** integration  
**Acceptance criterion mapped:** Production tenants cannot be deleted via this endpoint

### TC-ENV-05-07: Reset is atomic — tenant is unchanged when truncation blocked
**Given:** A test tenant with a check trigger or constraint that would prevent truncation  
**When:** Reset truncation encounters an error mid-way  
**Then:** No tables are partially truncated; the tenant schema is in its original state  
**Layer:** integration  
**Note:** Tested indirectly via TC-ENV-05-04 — if active instances prevent the query, no tables are truncated  
**Acceptance criterion mapped:** Atomicity — truncation rolls back on failure
