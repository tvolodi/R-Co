# Test Spec: OIDC-35 — Company Onboarding Orchestration

**Requirement:** OIDC-35 — Company onboarding orchestration providing a high-level, multi-step API for provisioning a new company tenant end-to-end (create tenant, provision Keycloak realm, create admin user, grant PLATFORM_ADMIN role, create OIDC client, bind hostname, verify discovery). All operations are idempotent via `Idempotency-Key` header.

**Priority:** MUST
**Test layer:** integration, e2e

---

## Test Cases

### TC-OIDC-35-01: Fresh idempotency key creates pending onboarding_registry record
**Given:** A clean test database with migrations applied  
**When:** An INSERT is performed into `onboarding_registry` with a new UUID idempotency key and request hash  
**Then:** The record is created with `state = 'pending'`, `response_status = 201`, and a valid UUID `onboarding_id`  
**Layer:** integration  
**Acceptance criterion mapped:** AC #5 — Idempotency — fresh key creates new record

### TC-OIDC-35-02: Same idempotency key + same request body returns existing record (replay)
**Given:** An existing `onboarding_registry` record with a known idempotency key and request hash  
**When:** A second insert is attempted with the same idempotency key and matching request hash via `ON CONFLICT DO NOTHING`  
**Then:** The insert is a no-op; querying by idempotency key returns the original record  
**Layer:** integration  
**Acceptance criterion mapped:** AC #5 — Idempotency — same key twice returns original result

### TC-OIDC-35-03: Same idempotency key + different request body returns conflict
**Given:** An existing `onboarding_registry` record with a known idempotency key and request hash  
**When:** A second insert is attempted with the same idempotency key but a different request hash  
**Then:** Request hash comparison detects mismatch; the operation returns an idempotency conflict error  
**Layer:** integration  
**Acceptance criterion mapped:** AC #5 — Idempotency — different body with same key is conflict

### TC-OIDC-35-04: GET onboarding by onboarding_id retrieves the record
**Given:** A completed `onboarding_registry` record with a known `onboarding_id`  
**When:** The record is selected by `onboarding_id`  
**Then:** The correct record is returned with matching `idempotency_key`, `state`, and `response_body_json`  
**Layer:** integration  
**Acceptance criterion mapped:** AC #2 — Platform-admin retrieves tenant provisioning result

### TC-OIDC-35-05: GET onboarding by hostname retrieves completed record
**Given:** A completed `onboarding_registry` record with a known `hostname`  
**When:** The record is selected by `hostname` with `state = 'completed'`  
**Then:** The correct record is returned  
**Layer:** integration  
**Acceptance criterion mapped:** AC #4 — Hostname bindings retrievable via API

### TC-OIDC-35-06: Onboarding saga creates tenant and binds hostname (requires Keycloak)
**Given:** A running Keycloak instance (BPM_IDP_BASE_URL configured)  
**When:** The `executeSaga` function is called with valid OnboardingInput  
**Then:** A tenant is created in the `tenant` table, a hostname binding in `tenant_hostnames`, and an OnboardingResult is returned with all fields populated  
**Layer:** integration  
**Acceptance criterion mapped:** AC #2, AC #3, AC #4, AC #6

### TC-OIDC-35-07: Saga compensation cleans up tenant on failure
**Given:** A Keycloak instance where realm provisioning will fail (e.g., unreachable)  
**When:** The `executeSaga` function is called and fails at the realm provisioning step  
**Then:** Compensating actions undo completed steps: the tenant row is deleted from the DB  
**Layer:** integration  
**Acceptance criterion mapped:** AC #3 — Provisioning API creates/reconciles provider resources with compensation

### TC-OIDC-35-08: Input validation detects missing required fields
**Given:** A malformed onboarding request body  
**When:** Input parsing is attempted with missing `slug`, `display_name`, `admin_email`, `admin_username`, `admin_display_name`, or `hostname`  
**Then:** Validation fails with an appropriate error  
**Layer:** integration  
**Acceptance criterion mapped:** AC #1 — Versioned API contract — validation rules enforced

### TC-OIDC-35-09: Slug validation rejects invalid formats
**Given:** An onboarding request with an invalid `slug` (too short, too long, contains uppercase letters, or contains invalid characters)  
**When:** Input parsing is attempted  
**Then:** Validation fails  
**Layer:** integration  
**Acceptance criterion mapped:** AC #1 — Versioned API contract — slug format enforced

### TC-OIDC-35-10: Hostname binding enforces uniqueness
**Given:** An existing hostname bound to one tenant  
**When:** An attempt is made to bind the same hostname to another tenant  
**Then:** The operation fails with `DuplicateHostname` error  
**Layer:** integration  
**Acceptance criterion mapped:** AC #4 — Hostname bindings are unique

### TC-OIDC-35-11: Tenant slug enforces uniqueness
**Given:** An existing tenant with a known `slug`  
**When:** An attempt is made to create another tenant with the same `slug`  
**Then:** The operation fails with `DuplicateTenantSlug` error  
**Layer:** integration  
**Acceptance criterion mapped:** AC #2 — Tenant slugs are unique

### TC-OIDC-35-12: Non-existent onboarding_id returns null
**Given:** A random UUID that does not exist in `onboarding_registry`  
**When:** A lookup by onboarding_id is performed  
**Then:** The result is `null` (not found)  
**Layer:** integration  
**Acceptance criterion mapped:** AC #2 — Not-found case handled gracefully

### TC-OIDC-35-13: Non-existent hostname returns null
**Given:** A hostname that has no completed onboarding record  
**When:** A lookup by hostname is performed  
**Then:** The result is `null` (not found)  
**Layer:** integration  
**Acceptance criterion mapped:** AC #4 — Hostname not-found case handled gracefully
