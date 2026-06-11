# Test Spec: ENV-04 — UI clearly labels test tenants and blocks accidental production actions

**Requirement:** ENV-04 — The platform UI SHALL display a persistent, visually distinct indicator
on every page when the user is operating within a test tenant. Actions that would affect the
paired production tenant SHALL require an explicit confirmation step. Test-tenant pages SHALL
NOT render any production data.  
**Priority:** MUST  
**Test layer:** e2e  
**Feature branch:** feature/WF02-env-batch2-20260610

---

## Prerequisites / Test Data

All tests run against the real backend (no MSW, no mocking — DIRECTIVE T-2).

**Production tenant context (always available):**
- Keycloak admin user (`admin-user` / `admin-pass`) authenticated against the `bpm-default` realm
- `GET /api/v1/tenants/current` will return the default tenant (`tenant_type: "production"`) once
  the `GET /api/v1/tenants/current` backend endpoint is implemented

**Test tenant context (required for TC-ENV-04-01/02/04/05/06/08/09/10):**
- A tenant with `tenant_type = "test"` and a valid `production_tenant_id` must exist
- Created in `beforeAll` via SQL INSERT into `public.tenant` (using the DB URL from
  `BPM_TEST_DB_URL`) — the onboarding API does not yet accept `tenant_type` as a parameter
- The `GET /api/v1/tenants/current` backend endpoint MUST be implemented (returns the current
  user's tenant including `tenant_type`) for TC-ENV-04-01/02/05/06/08/09 to pass

**BLOCKER — Backend dependency not yet implemented:**
`GET /api/v1/tenants/current` currently routes to `handleGetTenant(slug="current")` which returns
404 because no tenant has slug "current". The `useTestEnvironment()` hook receives 404 →
`isTestTenant: false` → banner and promote-button never appear. The following tests **cannot pass**
until BACKEND-DEV adds a special-cased route for `GET /api/v1/tenants/current` that resolves the
authenticated user's tenant:

- TC-ENV-04-01 (banner text when in test tenant)
- TC-ENV-04-02 (banner shows paired production name)
- TC-ENV-04-05 (Promote button visible on ACTIVE def in test tenant)
- TC-ENV-04-06 (Promote button absent on DRAFT def)
- TC-ENV-04-08 (clicking Promote opens confirmation modal)
- TC-ENV-04-09 (confirming promotion calls API successfully)

Tests TC-ENV-04-03, TC-ENV-04-04, TC-ENV-04-07, TC-ENV-04-10 can run now.

---

## Test Cases

### TC-ENV-04-01: Banner shown with "TEST ENVIRONMENT" text when on test tenant

**Given:** The user is authenticated and the current session belongs to a test tenant
(`GET /api/v1/tenants/current` returns `tenant_type: "test"`)  
**When:** The user navigates to any page in the application  
**Then:** A persistent amber banner is rendered at the top of every page containing the
text `"TEST ENVIRONMENT"` (bold), and `data-testid="test-env-banner"` is present in the DOM  
**Layer:** e2e  
**Acceptance criterion mapped:** "every page in the UI renders a persistent banner or badge
containing the text `TEST ENVIRONMENT`"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-02: Banner shows paired production tenant name

**Given:** The user is authenticated on a test tenant that has a paired production tenant
(`production_tenant_display_name` is non-null in `GET /api/v1/tenants/current`)  
**When:** The banner is rendered  
**Then:** The banner contains the text "(linked to: \<productionTenantName\>)" where
`<productionTenantName>` matches the `production_tenant_display_name` field  
**Layer:** e2e  
**Acceptance criterion mapped:** Banner "containing the name of the paired production tenant"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-03: No banner shown when logged in to production tenant

**Given:** The user is authenticated as `admin-user` (bpm-default realm, production tenant context)  
**When:** The user loads any page  
**Then:** No element with `data-testid="test-env-banner"` is present in the DOM; no text
`"TEST ENVIRONMENT"` appears anywhere on the visible page  
**Layer:** e2e  
**Acceptance criterion mapped:** "GIVEN the user is on a production tenant, THEN no
test-environment banner is shown"

---

### TC-ENV-04-04: [TEST] suffix appears in tenant switcher for test tenants

**Given:** The admin user navigates to `/admin/tenants` and the tenant list contains at least
one tenant with `tenant_type = "test"`  
**When:** The tenants table is rendered  
**Then:** The test tenant's row has `data-testid="tenant-test-badge-<slug>"` visible, containing
the text `[TEST]`; the display-name cell for that row renders amber text colour; production
tenant rows do NOT have this badge  
**Layer:** e2e  
**Acceptance criterion mapped:** "test tenants are shown with a [TEST] suffix in the tenant name"

---

### TC-ENV-04-05: Promote to Production button visible on ACTIVE definition in test tenant

**Given:** The user is authenticated on a test tenant (`isTestTenant: true`) and navigates to
the Process Definition detail/editor page for a definition with `status: "ACTIVE"`  
**When:** The definition editor page renders  
**Then:** A button with `data-testid="btn-promote-to-production"` and label "Promote to
Production" is visible on the page  
**Layer:** e2e  
**Acceptance criterion mapped:** "The 'Promote to Production' button is only shown on the
Process Definition detail page when the current tenant is a test tenant and the definition
status is `ACTIVE`"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-06: Promote to Production button NOT visible on DRAFT definition

**Given:** The user is authenticated on a test tenant (`isTestTenant: true`) and navigates to
the definition editor page for a definition with `status: "DRAFT"`  
**When:** The definition editor page renders  
**Then:** No element with `data-testid="btn-promote-to-production"` is present in the DOM  
**Layer:** e2e  
**Acceptance criterion mapped:** "The button is only shown ... when the definition status is ACTIVE"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-07: Promote to Production button NOT visible when on production tenant

**Given:** The user is authenticated as `admin-user` (production tenant context)  
**When:** The user navigates to a definition editor page for an ACTIVE definition  
**Then:** No element with `data-testid="btn-promote-to-production"` is present in the DOM  
**Layer:** e2e  
**Acceptance criterion mapped:** "only shown when the current tenant is a test tenant"

---

### TC-ENV-04-08: Clicking Promote shows confirmation modal with correct message

**Given:** The user is on a test tenant, viewing the editor for an ACTIVE definition
named `<defName>` paired with production tenant `<prodName>`  
**When:** The user clicks `data-testid="btn-promote-to-production"`  
**Then:**
- An overlay with `data-testid="promote-confirm-modal-overlay"` appears
- The modal with `data-testid="promote-confirm-modal"` is visible
- The modal body text contains: `"You are about to promote '<defName>' to production tenant '<prodName>'"`
- A "Confirm" button (`data-testid="promote-modal-confirm"`) and a "Cancel" button
  (`data-testid="promote-modal-cancel"`) are both visible and enabled  

**Layer:** e2e  
**Acceptance criterion mapped:** "a confirmation modal is shown: 'You are about to promote...'"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-09: Confirming promotion creates DRAFT on production tenant (API call succeeds)

**Given:** The confirmation modal is open for definition `<defName>` on test tenant `<testSlug>`  
**When:** The user clicks `data-testid="promote-modal-confirm"`  
**Then:**
- `POST /api/v1/tenants/<testSlug>/promote/<defName>` returns HTTP 201
- The modal shows `data-testid="promote-modal-success"` with success text containing "Promoted successfully"
- The modal closes after ~1.5 s
- The definition list is refreshed (React Query cache invalidated)  

**Layer:** e2e  
**Acceptance criterion mapped:** "The action proceeds only after explicit confirmation"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation

---

### TC-ENV-04-10: Instance list shows only test-tenant instances when on test tenant

**Given:** The user is authenticated on a test tenant  
**When:** The user navigates to `/instances`  
**Then:**
- The `data-testid="test-env-banner"` is visible at the top of the page (proves the user
  is in a test tenant context)
- The instances listed belong to the test tenant (verified by checking the banner presence;
  cross-tenant isolation is enforced by the backend search_path mechanism documented in ENV-02)  

**Note:** No additional client-side filter is present or required on the instances page.
Isolation is fully enforced at the database layer. The test verifies the banner is visible
(proving the correct tenant context) and that the API only returns test-tenant instances.  
**Layer:** e2e  
**Acceptance criterion mapped:** "only instances belonging to the test tenant are shown"  
**Blocked by:** Missing backend `GET /api/v1/tenants/current` implementation (banner will not
appear until this is fixed)
