# Test Spec: PLC-04 — Cross-tenant module distribution

**Requirement:** PLC-04 — verbatim requirement text:
> A process module published to the catalog by one tenant (the "publishing tenant") MAY be shared
> to other tenants ("subscribing tenants") via an explicit platform-admin-authorised sharing grant.
> A subscribing tenant sees only modules explicitly granted to it; by default, no tenant's
> catalog is visible to any other tenant. `module_ref` resolution (PLC-01) only considers versions
> visible to the resolving tenant.

**Priority:** SHOULD
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2, `process_module_catalog_share`
table) + tenant isolation (2, cross-tenant visibility boundary) = 4 points → unit + integration.

## Test Cases

### TC-PLC-04-01: tenant A's module is invisible to tenant B without a grant
**Given:** tenant A owns an ACTIVE module  
**When:** tenant B calls `resolveModuleRef` for that module_id  
**Then:** resolution returns `{resolved: false, error_code: "UNRESOLVED_MODULE_REF"}` — no information leak  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 AC1 — isolation without grant

### TC-PLC-04-02: grant makes module visible to receiving tenant
**Given:** tenant A owns an ACTIVE module; a PLATFORM_ADMIN grant exists to tenant B  
**When:** tenant B calls `resolveModuleRef` for that module_id  
**Then:** resolution succeeds using tenant A's ACTIVE version  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 AC2 — grant enables cross-tenant resolution

### TC-PLC-04-03: grantModuleVisibility creates a share grant row
**Given:** a valid granting tenant and receiving tenant  
**When:** `grantModuleVisibility` is called  
**Then:** a row appears in `process_module_catalog_share` for the (granting_tenant, module_id, receiving_tenant) triplet  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — grant creates share record

### TC-PLC-04-04: duplicate grant returns SharingGrantAlreadyExists
**Given:** a grant already exists between tenant A and tenant B for a module  
**When:** `grantModuleVisibility` is called again with the same parameters  
**Then:** `SharingGrantAlreadyExists` error is returned (ON CONFLICT DO NOTHING)  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — idempotent grant handling

### TC-PLC-04-05: revokeModuleVisibility removes the grant
**Given:** an active grant exists  
**When:** `revokeModuleVisibility` is called with the grant's UUID  
**Then:** the grant row is deleted and subsequent resolve from the receiving tenant fails  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — revocation removes visibility

### TC-PLC-04-06: revokeModuleVisibility returns error for unknown grant
**Given:** no grant with the given grant_id exists  
**When:** `revokeModuleVisibility` is called  
**Then:** `SharingGrantNotFound` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — revocation of non-existent grant

### TC-PLC-04-07: listVisibleModules shows only owned and shared ACTIVE modules
**Given:** tenant A owns 2 ACTIVE modules; tenant B is granted 1 of them  
**When:** `listVisibleModules` is called for tenant B  
**Then:** exactly 1 module is visible (the shared one, not tenant B's own)  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — visibility filtering on list

### TC-PLC-04-08: grant does not allow tenant B to see tenant A's other modules
**Given:** tenant A owns modules "mod-x" and "mod-y"; tenant B is granted only "mod-x"  
**When:** tenant B calls `listVisibleModules`  
**Then:** "mod-y" does not appear in the results  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-04 — explicit grant required per module
