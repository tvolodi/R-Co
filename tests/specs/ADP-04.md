# Test Spec: ADP-04 — User tenant binding

**Requirement:** ADP-04 — The user table MUST gain `tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'`. A user MAY be a member of exactly one tenant. Existing users remain valid and bound to the default tenant.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ADP-04-01: user creation without explicit tenant_id binds to actor tenant
**Given:** A PLATFORM_ADMIN actor authenticated in the default tenant and no existing user with the target username.  
**When:** The actor creates a user via identity API without providing `tenant_id`.  
**Then:** The user is created successfully and persisted with `tenant_id = 00000000-0000-0000-0000-000000000000`.  
**Layer:** integration  
**Acceptance criterion mapped:** Tenant-bound user behavior with explicit default-tenant fallback.

### TC-ADP-04-02: cross-tenant group membership add is blocked
**Given:** A group in tenant A, one user in tenant A, and one user in tenant B.  
**When:** Tenant A actor attempts to add the tenant B user into tenant A group membership.  
**Then:** The request is rejected with not-found semantics and no cross-tenant membership row is written.  
**Layer:** integration  
**Acceptance criterion mapped:** Negative tenant-isolation behavior for identity/group flow.

### TC-ADP-04-03: pre-existing user row without explicit tenant_id remains valid in default tenant
**Given:** A legacy-style user row inserted without specifying `tenant_id` so DB default applies.  
**When:** The user is read through tenant-scoped identity service lookups.  
**Then:** The user resolves as ACTIVE in default tenant, is not visible from another tenant, and stored `tenant_id` is default tenant.  
**Layer:** integration  
**Acceptance criterion mapped:** Default-tenant compatibility/backfill semantics for pre-existing users.

### TC-ADP-04-04: group task claim check enforces tenant isolation
**Given:** A group and active member in tenant A and another active user in tenant B.  
**When:** Group claim eligibility is evaluated for both users under tenant A context.  
**Then:** Tenant A user can claim, tenant B user cannot claim.  
**Layer:** integration  
**Acceptance criterion mapped:** Positive and negative tenant-isolation behavior in identity/group claim flow.
