# Module: tenant-env-ui (ENV-04)

> **Scope:** Stage 14 — Test-tenant environment, frontend UI labelling.  
> **Produced by:** CODE-DESIGNER (WF02-env-batch2-20260610, Step 01)  
> **Requirements:** ENV-04

---

## Module Purpose

The `tenant-env-ui` module adds visual safeguards to the BPM Platform's React
frontend to prevent accidental actions in test-tenant sessions. It introduces
four tightly coupled UI elements: a persistent amber banner that appears on
every page when the current session belongs to a test tenant (driven by the
`tenant_type` field returned by the API, not by the tenant's display name); a
`[TEST]` label suffix and colour distinction applied to test-tenant entries in
any admin tenant switcher; a "Promote to Production" action button that appears
on the Process Definition detail page exclusively when the current tenant is a
test tenant and the definition is `ACTIVE`; and a confirmation modal that forces
the user to read the consequences before the promotion API call is dispatched.
All four elements read their state from a single `useTestEnvironment()` hook so
that the test-tenant signal is fetched once per session and shared across the
component tree without prop-drilling.

---

## ENV-04 Design

### 1. Tenant Context Data Requirement

The frontend requires two fields that are not currently present in the
`UserSession` object or in the `Tenant` interface exposed by `web/src/api/tenants.ts`:

| Field | Type | Source |
|---|---|---|
| `tenant_type` | `"production" \| "test"` | API response |
| `production_tenant_display_name` | `string \| null` | API response — null when `tenant_type = "production"` |

The backend ENV-01 changes already store these in the `tenant` table.  
A new endpoint `GET /api/v1/tenants/current` (backend responsibility — note as
dependency on ENV-01 implementation) MUST return:

```
{
  slug: string
  display_name: string
  tenant_type: "production" | "test"
  production_tenant_id: string | null
  production_tenant_display_name: string | null
}
```

The `Tenant` interface in `web/src/api/tenants.ts` MUST be extended with the
three new fields (`tenant_type`, `production_tenant_id`,
`production_tenant_display_name`). Existing callers that do not read these
fields are not affected.

### 2. useTestEnvironment Hook

A new hook `web/src/hooks/useTestEnvironment.ts` fetches the current tenant
context once per session (stale-time = `Infinity` unless manually invalidated)
and derives the two boolean/string values components need.

**Data flow:**

```
AuthContext (JWT decoded)
        │
        └─► useTestEnvironment()
                 │  calls GET /api/v1/tenants/current via tenantsApi.getCurrent()
                 │  caches under queryKeys.admin.tenantCurrent
                 ▼
        { isTestTenant: boolean, productionTenantName: string | null }
                 │
        ┌────────┴──────────────────────┐
        ▼                               ▼
TestEnvironmentBanner            PromoteToProductionButton
        │                               │
        └── renders amber bar           └── conditionally visible,
            on every page                   opens PromoteConfirmModal
```

The hook MUST NOT throw when the endpoint returns 404 or when the user is
unauthenticated — it returns `{ isTestTenant: false, productionTenantName: null }`
as a safe default.

### 3. TestEnvironmentBanner Component

**File:** `web/src/components/layout/TestEnvironmentBanner.tsx`

**Behaviour:**
- Rendered unconditionally inside `AppShell` directly above `<ApiConnectivityBanner>`
  (both sit at the top of the `<main>` content column)
- The component returns `null` when `isTestTenant === false` — no DOM node
  emitted for production sessions
- Fixed to the top of the viewport (`position: fixed; top: 0; left: 0; right: 0`)
  with a `z-index` value above the sidebar (`z-index: 200`) so it remains
  visible on scroll and over floating panels
- On narrow viewports (`max-width: 480px`) the banner text is shortened to
  `"TEST ENVIRONMENT"` only; the paired tenant name is hidden via a
  CSS media query (`display: none` on the parenthetical span)
- Not collapsible; no close button
- Background: amber/yellow (`#fef3c7`), border-bottom `#f59e0b`, text `#92400e`
- Main text: `"TEST ENVIRONMENT"` (bold) followed by `"(linked to: <productionTenantName>)"`
  when `productionTenantName` is non-null
- Adds `data-testid="test-env-banner"` for Playwright targeting
- `role="status"` + `aria-label="Test environment indicator"` for accessibility

**AppShell layout adjustment:** When the banner is rendered, the sidebar and
main content area must be pushed down by the banner height (~40 px) to prevent
content being hidden underneath the fixed banner. This is achieved by adding a
`paddingTop` style to the outer flex container that is conditionally set to
`"40px"` when `isTestTenant` is true and `"0"` otherwise. The
`useTestEnvironment()` hook is called once in `AppShell` and its result
passed as props to `TestEnvironmentBanner`.

### 4. Integration with AppShell

**File to modify:** `web/src/components/layout/AppShell.tsx`

Changes required:
1. Import `TestEnvironmentBanner` from `@/components/layout/TestEnvironmentBanner`
2. Import `useTestEnvironment` from `@/hooks/useTestEnvironment`
3. Call `const { isTestTenant, productionTenantName } = useTestEnvironment()` at
   the top of the component body (alongside the existing `useAuth()` call)
4. Add `paddingTop: isTestTenant ? '40px' : '0'` to the outer `<div>` style
5. In the `<main>` block, add `<TestEnvironmentBanner isTestTenant={isTestTenant} productionTenantName={productionTenantName} />` as the first child, above `<ApiConnectivityBanner />`

No changes are required to child page components or to the router.

### 5. Tenant Switcher Labels

The admin tenant list page (`web/src/pages/admin/tenants/TenantsPage.tsx`) renders
tenant rows in a table. FRONTEND-DEV MUST apply the following visual distinction
to each tenant row where `tenant_type === "test"`:

- Append `" [TEST]"` to the `display_name` cell text
- Apply amber text colour (`color: #92400e`) to the entire row's display-name cell
- Optionally add a small flask icon (SVG or Unicode `⚗`) before the `[TEST]` suffix

The `Tenant` interface must include `tenant_type` for TypeScript to accept
the conditional rendering without a cast.

This change requires no new component; it is a conditional in the existing row
render of `TenantsPage`.

### 6. Promote to Production Button

**File:** `web/src/components/definitions/PromoteToProductionButton.tsx`

**Visibility rule:** The button is rendered on `DefinitionEditorPage`
(`web/src/pages/definitions/DefinitionEditorPage.tsx`) when:
- `isTestTenant === true` (from `useTestEnvironment()`), AND
- `def.status === "ACTIVE"` (from the existing `useDefinition(id)` hook)

If either condition is false, the component returns `null`.

**Placement in DefinitionEditorPage:** Below the existing Save/Activate toolbar
row, as a secondary action button (right-aligned, amber/yellow colour to signal
the cross-tenant nature of the operation). The button label is
`"Promote to Production"`.

**Interaction:** Clicking opens `PromoteConfirmModal`. The button becomes
disabled (with a loading spinner) while the modal's API call is in-flight.

### 7. Promotion API Call

The promotion is dispatched via a new function added to
`web/src/api/tenants.ts`:

```
tenantsApi.promote(testTenantId: string, definitionName: string): Promise<{ promoted_definition_id: string }>
  calls POST /api/v1/tenants/:testTenantId/promote/:definitionName
```

The `testTenantId` is the slug of the current test tenant (from `useTestEnvironment()`).
The `definitionName` is `def.name` from the current definition loaded on the page.

### 8. PromoteConfirmModal Component

**File:** `web/src/components/definitions/PromoteConfirmModal.tsx`

**Trigger:** Opened by `PromoteToProductionButton` via a boolean `open` prop.

**Modal content:**
- Heading: `"Confirm Promotion"`
- Body text (parameterised):  
  `"You are about to promote '<definitionName>' to production tenant '<productionDisplayName>'. This will create a DRAFT version that requires separate activation. Confirm?"`
- Two buttons: `"Confirm"` (primary, calls API) and `"Cancel"` (dismisses modal)
- While the API call is in-flight: Confirm button shows a spinner and is disabled;
  Cancel button is also disabled to prevent double-action
- On success: dismiss modal, show success toast (`"Promoted successfully. A DRAFT version is now available in production."`), invalidate `queryKeys.definitions.list({})` to refresh the definition list
- On error: display error message inline in the modal (do not close); re-enable buttons

**Toast:** Use the existing UI toast mechanism if one exists in the codebase;
otherwise render a timed `role="alert"` div injected at the top of the page for
3 seconds.

### 9. Instance List Isolation

**ENV-04 Acceptance Criterion 5:** _"GIVEN the user is on a test tenant and
navigates to the Instance list, THEN only instances belonging to the test
tenant are shown; no production instances are visible."_

**Enforcement layer: backend, not frontend.**

The BPM Platform already enforces tenant isolation at the API level through two
complementary mechanisms:

1. **PostgreSQL search_path (TNT-03):** Every database connection within a
   request is pinned to the tenant's schema via `SET search_path = <tenant_slug>`.
   The `instances` table exists per-schema, so a query against `instances` can
   only return rows belonging to the active tenant — cross-tenant rows are
   structurally unreachable.

2. **JWT tenant context middleware:** Every authenticated API call carries the
   caller's `tenant_slug` in the JWT claims. The backend middleware extracts
   this claim and sets the database session's search_path before any handler
   runs. `GET /api/v1/instances` therefore returns only instances that exist
   in the schema of the authenticated tenant.

**No frontend filtering component is required.** The API response already
contains only the instances for the current session's tenant. Adding
client-side filtering that re-enforces server-side isolation would:

- Duplicate security logic in the wrong layer (violates defence-in-depth
  principle: the _primary_ guard must be on the server)
- Create a false sense of security if the client-side filter were ever removed
  or bypassed
- Be invisible to audit logs, which record the backend enforcement, not
  frontend rendering decisions

**Frontend responsibility for AC5:** The `TestEnvironmentBanner` rendered by
`AppShell` (§3) is the only frontend element related to this acceptance
criterion. It provides a persistent visual cue that the user is looking at
test-tenant data — which is how the user knows the instance list they see
belongs to the test tenant, not a production one. No additional component is
needed on the Instance list page beyond what `AppShell` already provides.

**FRONTEND-DEV MUST NOT** implement a client-side filter on `InstancesPage`
that attempts to filter out production instances. Any such filter would be
incorrect by definition (the API never sends production instances to a test
tenant session) and would mask bugs if the backend isolation were ever broken.

---

## Public Interface

### Extended `Tenant` interface (`web/src/api/tenants.ts`)

```typescript
interface Tenant {
  slug: string
  display_name: string
  idp_realm_id: string | null
  hostname?: string
  redirect_uris?: string[]
  status: 'ACTIVE' | 'INACTIVE'
  created_at: string
  // ENV-04 additions
  tenant_type: 'production' | 'test'
  production_tenant_id: string | null
  production_tenant_display_name: string | null
}
```

### `tenantsApi.getCurrent()` addition

```typescript
tenantsApi.getCurrent(): Promise<Tenant>
// calls GET /api/v1/tenants/current
```

### `tenantsApi.promote()` addition

```typescript
tenantsApi.promote(
  testTenantId: string,
  definitionName: string
): Promise<{ promoted_definition_id: string }>
// calls POST /api/v1/tenants/:testTenantId/promote/:definitionName
```

### `useTestEnvironment()` hook

```typescript
function useTestEnvironment(): {
  isTestTenant: boolean
  productionTenantName: string | null
  currentTenantSlug: string | null
  isLoading: boolean
}
```

- `isTestTenant` — `true` only when the current tenant's `tenant_type === "test"`
- `productionTenantName` — `production_tenant_display_name` from the API, or `null`
- `currentTenantSlug` — the slug of the current session's tenant (needed by the promotion call)
- `isLoading` — `true` while the tenant context fetch is in-flight (used to suppress banner flicker)

Query key: `queryKeys.admin.tenantCurrent` (new key to add to `queryKeys.admin`)

### `TestEnvironmentBanner` props

```typescript
interface TestEnvironmentBannerProps {
  isTestTenant: boolean
  productionTenantName: string | null
}
```

### `PromoteToProductionButton` props

```typescript
interface PromoteToProductionButtonProps {
  definitionName: string
  definitionStatus: DefinitionStatus
  onPromoteSuccess: () => void
}
```

### `PromoteConfirmModal` props

```typescript
interface PromoteConfirmModalProps {
  open: boolean
  definitionName: string
  productionDisplayName: string
  onConfirm: () => Promise<void>
  onCancel: () => void
}
```

---

## Error Taxonomy

| Error scenario | Source | UI handling |
|---|---|---|
| `GET /api/v1/tenants/current` returns 401 | Expired session | Auth layer handles — redirect to login |
| `GET /api/v1/tenants/current` returns 404 | Backend not yet deployed | Hook returns `isTestTenant: false` silently (no banner) |
| `GET /api/v1/tenants/current` returns 5xx | Transient backend error | Hook returns `isTestTenant: false`; React Query retries with exponential backoff |
| `POST /api/v1/tenants/:id/promote/:name` returns 404 | Definition or tenant not found | Modal displays `"Promotion failed: definition or tenant not found."` |
| `POST /api/v1/tenants/:id/promote/:name` returns 409 | Already promoted (duplicate) | Modal displays `"A version of this definition already exists in the production tenant."` |
| `POST /api/v1/tenants/:id/promote/:name` returns 422 | Validation error (not ACTIVE, wrong tenant type) | Modal displays the server's `message` field |
| `POST /api/v1/tenants/:id/promote/:name` returns 5xx | Transient backend error | Modal displays `"Promotion failed due to a server error. Please try again."` |

---

## State Transitions

The Promote to Production flow does not transition process definition state on
the test tenant. The button is visible only when `status === "ACTIVE"` and it
remains `ACTIVE` after the call succeeds. On the production tenant, a new
`DRAFT` version is created. No state transition occurs on the test tenant's
definition after a successful promotion.

---

## Dependencies

| Dependency | Module / endpoint | Notes |
|---|---|---|
| ENV-01 | `tenant_type` + `production_tenant_id` columns in DB and API response | Must be deployed before this UI reads `GET /api/v1/tenants/current` |
| ENV-03 | `POST /api/v1/tenants/:id/promote/:name` | Promotion API called by the modal |
| `AppShell.tsx` | Layout shell — injection point for banner | Minor structural change |
| `DefinitionEditorPage.tsx` | Definition detail page — injection point for promote button | Reads `def.status` and `def.name` from existing `useDefinition()` |
| `TenantsPage.tsx` | Admin tenant list — adds `[TEST]` suffix | Reads `tenant_type` from extended `Tenant` interface |
| `web/src/api/tenants.ts` | Extended with `getCurrent()` and `promote()` | New functions; no breaking changes |
| `web/src/api/queryKeys.ts` | Extended with `tenantCurrent` key | Additive |

---

## Open Questions

1. **Tenant slug from session:** The `GET /api/v1/tenants/current` endpoint must
   identify the caller's tenant from the JWT scope/claim without requiring a
   slug in the URL. If the backend JWT includes a `tenant_slug` claim, the
   frontend can derive this without an extra roundtrip. BACKEND-DEV should
   confirm whether the JWT includes a `tenant_slug` claim or whether
   `GET /api/v1/tenants/current` is the preferred mechanism.

2. **Toast component:** The codebase does not appear to have a shared toast/
   notification component. FRONTEND-DEV should implement a minimal
   `useToast()` hook + `ToastContainer` rendered in `AppShell`, or reuse any
   existing pattern found in the codebase. The modal success path depends on this.
