# Test Spec: ENV-03 — Process definition promotion from test tenant to production tenant

**Requirement:** ENV-03 — `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name` exports an ACTIVE definition from a test tenant and imports it as a new DRAFT on the linked production tenant.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ENV-03-01: Happy path — promotion returns DRAFT definition on production
**Given:** Test tenant T-test linked to production tenant T; actor has PROCESS_DESIGNER on both; T-test has an ACTIVE process definition named "test-process"  
**When:** `promoteDefinition(alloc, pool, T-test-id, "test-process", actor_id)` is called  
**Then:** Returns `PromotionResult` with `status = "DRAFT"` and a valid `definition_id`; promoted definition row exists in T's schema with `status = 'DRAFT'`  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 201 with DRAFT definition record on production tenant

### TC-ENV-03-02: Audit entries written on both tenants
**Given:** Same setup as TC-ENV-03-01  
**When:** Promotion completes successfully  
**Then:** `audit_entries` in T-test schema has a row with `action = 'DEFINITION_PROMOTED'`; `audit_entries` in T schema has a row with `action = 'DEFINITION_PROMOTED'`  
**Layer:** integration  
**Acceptance criterion mapped:** Audit entries on both tenants with `action='DEFINITION_PROMOTED'`

### TC-ENV-03-03: No ACTIVE definition → ActiveDefinitionNotFound
**Given:** T-test has no process definition named "nonexistent"  
**When:** `promoteDefinition(alloc, pool, T-test-id, "nonexistent", actor_id)` is called  
**Then:** Returns `PromotionError.ActiveDefinitionNotFound`  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 404 when no ACTIVE definition with given name exists in test tenant

### TC-ENV-03-04: Caller missing PROCESS_DESIGNER on production → MissingDesignerRoleOnProd
**Given:** Actor has PROCESS_DESIGNER on T-test but NOT on T (production); T-test has an ACTIVE definition  
**When:** `promoteDefinition(alloc, pool, T-test-id, "test-process", actor_id)` is called  
**Then:** Returns `PromotionError.MissingDesignerRoleOnProd`  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 403 when caller lacks PROCESS_DESIGNER on production tenant

### TC-ENV-03-05: Promoted definition is DRAFT, not ACTIVE
**Given:** Same setup as TC-ENV-03-01  
**When:** Promotion completes  
**Then:** The new definition row in T's schema has `status = 'DRAFT'`; querying T's schema confirms no second ACTIVE row for "test-process"  
**Layer:** integration  
**Acceptance criterion mapped:** Promoted definition is DRAFT — not automatically activated

### TC-ENV-03-06: Production tenant inactive → ProductionTenantInactive
**Given:** Production tenant T has `status = 'INACTIVE'`; T-test is linked to it  
**When:** `promoteDefinition(alloc, pool, T-test-id, "test-process", actor_id)` is called  
**Then:** Returns `PromotionError.ProductionTenantInactive`  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 409 when production tenant is not active

### TC-ENV-03-07: Version increment for existing name on production
**Given:** T production schema already has a DRAFT definition named "test-process" with version "1"  
**When:** Promotion is called for "test-process" in T-test  
**Then:** New definition row in T has `version > "1"` (incremented to "2" or max+1)  
**Layer:** integration  
**Acceptance criterion mapped:** Version increment — `version = current_max + 1` when name already exists on production
