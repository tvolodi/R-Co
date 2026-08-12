# Module: env04-test-tenant-ui (ENV-04)

> **Scope:** Stage 14 — Test-tenant environment (UI layer).
> **Produced by:** CODE-DESIGNER (WF02-env04-20260812, Step 01)
> **Requirement:** ENV-04 (UI clearly labels test tenants and blocks accidental production actions)
> **Classification:** Type E — novel/cross-cutting UI.
> **Depends on:** ENV-01 (tenant_type field in DB/API), ENV-03 (promotion API endpoint)

---

## Module Purpose

This module adds all ENV-04 UI behaviour to the BPM Platform frontend. It covers five
discrete concerns:

1. **Persistent test-environment banner** — visible on every page when `tenant_type = 'test'`;
   fixed-position, non-collapsible, yellow, showing "TEST ENVIRONMENT" and the paired
   production tenant's display name.
2. **Confirmation modal for Promote to Production** — gates the ENV-03 API call behind an
   explicit acknowledgement dialog with exact prescribed text.
3. **"Promote to Production" button** — shown only on the Process Definition detail page when
   the current tenant is a test tenant and the definition status is `ACTIVE`.
4. **Admin tenant switcher labelling** — `[TEST]` suffix and visual distinction on test tenant
   rows in the `TenantsPage` admin list.
5. **Session type enrichment** — propagating `tenant_type` and `production_tenant_display_name`
   from the login-time tenant API call into `UserSession` and `useTenantContext`.

No new database migrations or backend routes are required beyond the cross-module backend
dependency noted in §8 (Open Questions).

---

## Files to Create

| File | Type |
|---|---|
| `web/src/components/layout/TestEnvironmentBanner.tsx` | new component |
| `web/src/components/ui/ConfirmPromoteModal.tsx` | new component |

## Files to Modify

| File | Change |
|---|---|
| `web/src/types/api.ts` | Add `tenant_type`, `production_tenant_id`, `production_tenant_display_name` to `Tenant`; add `tenant_type`, `production_tenant_display_name`, `tenant_id` to `UserSession` |
| `web/src/api/tenants.ts` | Update `Tenant` interface to match new `api.ts` fields |
| `web/src/auth/useTenantContext.ts` | Expose `tenantType` and `productionDisplayName` |
| `web/src/auth/AuthProvider.tsx` | Store `tenant_id`, `tenant_type`, `production_tenant_display_name` at login |
| `web/src/components/layout/AppShell.tsx` | Insert `<TestEnvironmentBanner />` above `<ApiConnectivityBanner />` |
| `web/src/pages/definitions/DefinitionEditorPage.tsx` | Add Promote button + ConfirmPromoteModal |
| `web/src/api/definitions.ts` | Add `promote(testTenantId, definitionName)` method |
| `web/src/pages/admin/tenants/TenantsPage.tsx` | Render `[TEST]` suffix + distinct background on test tenant rows |

---

## Public Interface

### 1. `web/src/types/api.ts` — type additions

**`Tenant` interface additions:**

```
tenant_type: 'production' | 'test'
production_tenant_id: string | null      // UUID; non-null only when tenant_type='test'
production_tenant_display_name: string | null  // denormalized by backend; non-null when tenant_type='test'
```

**`UserSession` interface additions:**

```
tenant_id: string | null                       // UUID of the current tenant
tenant_type: 'production' | 'test' | null
production_tenant_display_name: string | null  // null when tenant_type='production' or unknown
```

### 2. `web/src/auth/useTenantContext.ts` — extended hook

```
export interface TenantContextValue {
  tenantSlug: string | null
  tenantId: string | null                      // new
  tenantDisplayName: string
  isUnknown: boolean
  tenantType: 'production' | 'test' | null     // new
  productionDisplayName: string | null         // new; null when tenantType='production'
}

export function useTenantContext(): TenantContextValue
```

Implementation note: all four new fields are read directly from `session` (no extra API
call). The hook stays synchronous and always returns a stable reference when the session
object is unchanged.

### 3. `TestEnvironmentBanner` component

File: `web/src/components/layout/TestEnvironmentBanner.tsx`

```
export function TestEnvironmentBanner(): React.ReactElement | null
```

Props: none. Reads context via `useTenantContext()`.

Render conditions:
- Returns `null` if `tenantType !== 'test'` (covers production tenants and the `null`/loading
  case during session initialisation).
- Renders a sticky yellow bar when `tenantType === 'test'`.

Rendered content (exact strings):
- Primary text: `"TEST ENVIRONMENT"`
- Secondary text (when `productionDisplayName` is non-null):
  `"Paired with production: <productionDisplayName>"`
- Secondary text (when `productionDisplayName` is null — open-question fallback):
  `"Paired with production: (unknown)"` — see §8 OQ-1.

Visual spec (inline style, consistent with `ApiConnectivityBanner` pattern):
- `position: 'sticky'`, `top: 0`, `zIndex: 200` (above `ApiConnectivityBanner`'s 100)
- `background: '#fef08a'` (yellow-200), `color: '#713f12'` (amber-900)
- `borderBottom: '1px solid #eab308'`
- `fontWeight: 700` for the "TEST ENVIRONMENT" text; `fontWeight: 400` for secondary text
- Not collapsible; no close button.

Accessibility:
- `role="banner"`, `data-testid="test-environment-banner"`
- `aria-label="Test environment indicator"`

### 4. `ConfirmPromoteModal` component

File: `web/src/components/ui/ConfirmPromoteModal.tsx`

```
export interface ConfirmPromoteModalProps {
  definitionName: string
  productionDisplayName: string
  onConfirm: () => void
  onCancel: () => void
  isLoading: boolean
}

export function ConfirmPromoteModal(props: ConfirmPromoteModalProps): React.ReactElement
```

Modal body text (exact, per ENV-04 acceptance criteria):

> "You are about to promote '<definitionName>' to production tenant
> '<productionDisplayName>'. This will create a DRAFT version that requires
> separate activation. Confirm?"

(Note: `<definitionName>` and `<productionDisplayName>` are runtime values interpolated
into this string; the surrounding text is fixed.)

Visual spec:
- Overlay: fixed full-screen backdrop, `background: 'rgba(0,0,0,0.4)'`, `zIndex: 500`
- Modal card: centred, `background: '#fff'`, `borderRadius: '8px'`, `padding: '1.5rem'`,
  `maxWidth: '480px'`, `width: '90vw'`
- Two buttons: "Cancel" (secondary, closes modal) and "Confirm" (primary, `background:
  '#dc2626'` danger red — because this is a cross-tenant destructive-adjacent action)
- While `isLoading`: "Confirm" button shows a spinner and is disabled; "Cancel" is also
  disabled.
- `data-testid="promote-confirm-modal"`
- Confirm button: `data-testid="promote-confirm-btn"`
- Cancel button: `data-testid="promote-cancel-btn"`

### 5. `definitionsApi.promote` method addition

File: `web/src/api/definitions.ts`

```
promote: (testTenantId: string, definitionName: string) => Promise<PromoteResult>
```

Calls: `POST /api/v1/tenants/:testTenantId/promote/:definitionName`

```
export interface PromoteResult {
  definition_id: string
  version: string
  status: string
}
```

### 6. `DefinitionEditorPage` modification (Promote button + modal)

The "Promote to Production" button is shown only when ALL of the following are true:
- `tenantType === 'test'` (from `useTenantContext`)
- `def.status === 'ACTIVE'` (from the loaded definition)
- User has a designer role (`hasDesignerRole === true`)

Button label: `"Promote to Production"`
Button style: secondary/outlined, placed in the page's action toolbar alongside existing
Save/Activate/Deprecate/Archive controls.
`data-testid="promote-to-production-btn"`

Clicking the button opens `ConfirmPromoteModal`. Modal `productionDisplayName` is populated
from `productionDisplayName` in `useTenantContext`. If `productionDisplayName` is null, the
button is shown but the modal falls back to "(unknown)" per §8 OQ-1 guidance.

The mutation calls `definitionsApi.promote(session.tenant_id!, def.name)`. On success:
- Close the modal.
- Invalidate the definitions query (`queryKeys.definitions.all` or equivalent).
- Show a transient success message: `"Definition promoted. A DRAFT version is now available
  in production."` (inline, same pattern as existing `saved` state in the page).

On API error, extract the error code and surface a message:
- `not_a_test_tenant` → `"This operation requires a test tenant."`
- `production_tenant_inactive` → `"The paired production tenant is inactive. Contact your platform administrator."`
- `forbidden` → `"You do not have the required role on both tenants."`
- all others → `"Promotion failed. Please try again."`

### 7. `TenantsPage` modification (admin tenant switcher)

The `TenantsPage` admin list already fetches all tenants via `tenantsApi.list()`. After the
type additions in §1, each `Tenant` item carries `tenant_type`.

For each row where `tenant_type === 'test'`:
- Append `" [TEST]"` to the display name cell (do NOT change the underlying data; append in
  the render only).
- Apply a subtle background: `background: '#fefce8'` (yellow-50) on the `<tr>`.
- Add a small badge before the display name: `"TEST"` rendered as a yellow pill (same
  shape as the existing status badge but amber: `background: '#fef08a'`, `color: '#713f12'`).
- `data-testid={`tenant-type-badge-${row.slug}`}` on the badge.

For production tenants: no change to current render.

---

## Data Flow Diagram

### Part 1 — Login: session enrichment with tenant_type

```
┌─────────────────────────────────────────────────────────────────────┐
│ Login: AuthProvider.login(token)                                    │
│                                                                     │
│  JWT payload ──► resolveTenantSlug(payload) ──► tenantSlug         │
│                                                                     │
│  tenantsApi.getBySlug(tenantSlug)                                   │
│  GET /api/v1/tenants/:slug                                          │
│  Response: { tenant_id, display_name, tenant_type,                  │
│              production_tenant_id,                                  │
│              production_tenant_display_name }  ← NEW fields         │
│                                                                     │
│  Stored into UserSession:                                           │
│    tenant_id, tenant_display_name, tenant_type,                     │
│    production_tenant_display_name                                   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ session in AuthContext
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ useTenantContext()                                                  │
│   tenantSlug, tenantId, tenantDisplayName,                          │
│   tenantType, productionDisplayName                                 │
└──────┬──────────────────────────────────────────────────────────────┘
       │
       ├──► TestEnvironmentBanner (in AppShell before ApiConnectivityBanner)
       │      tenantType === 'test' → render yellow banner
       │      tenantType !== 'test' → return null
       │
       └──► DefinitionEditorPage (see Part 2)
```

### Part 2 — Promote-to-Production flow (DefinitionEditorPage)

```
DefinitionEditorPage
  tenantType === 'test' && def.status === 'ACTIVE'
    → show "Promote to Production" button
    → on click: open ConfirmPromoteModal
       onConfirm → definitionsApi.promote(tenant_id, def.name)
                  POST /api/v1/tenants/:id/promote/:name
                  → invalidate definitions query
                  → show success message
```

### Part 3 — AppShell render tree and TenantsPage

```
┌─────────────────────────────────────────────────────────────────────┐
│ AppShell render tree                                                │
│                                                                     │
│  <div style="display:flex">                                         │
│    <aside> ← sidebar with TenantHeader, nav, user footer           │
│    <main style="flex:1">                                            │
│      <TestEnvironmentBanner />   ← NEW (sticky, z=200)             │
│      <ApiConnectivityBanner />   ← existing (sticky, z=100)        │
│      <Outlet />                  ← page content                    │
│    </main>                                                          │
│  </div>                                                             │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ TenantsPage (admin tenant switcher)                                 │
│                                                                     │
│  tenantsApi.list() → items (each with tenant_type)                  │
│  For test rows: yellow <tr> bg + "TEST" badge + "[TEST]" in name    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Error Taxonomy

| Source | Error | HTTP | Handling |
|---|---|---|---|
| `definitionsApi.promote` | `not_found` | 404 | "Definition not found." |
| `definitionsApi.promote` | `not_a_test_tenant` | 422 | "This operation requires a test tenant." |
| `definitionsApi.promote` | `production_tenant_inactive` | 409 | "The paired production tenant is inactive. Contact your platform administrator." |
| `definitionsApi.promote` | `forbidden` | 403 | "You do not have the required role on both tenants." |
| `definitionsApi.promote` | `service_unavailable` | 503 | "Service temporarily unavailable. Please try again." |
| `definitionsApi.promote` | any other | 5xx | "Promotion failed. Please try again." |
| `tenantsApi.getBySlug` at login | any error | — | `tenant_type` and `production_tenant_display_name` default to `null`; banner shows fallback text or is suppressed until session is refreshed |

---

## State Transitions

`DefinitionEditorPage` promote state machine:

```
idle
  └─[click "Promote to Production"]──► confirming
        ├─[click "Cancel"]──────────► idle
        └─[click "Confirm"]─────────► submitting
              ├─[API success]────────► idle  (success message visible, modal closed)
              └─[API error]──────────► error (error message in modal, modal stays open)
                    └─[click "Cancel"]► idle
```

The modal stays open on error to allow the user to read the failure reason before dismissing.

---

## Security

- The banner shows only the production tenant's **display name** — data the user already has
  access to by virtue of being logged into the linked test tenant. No production process
  definitions, instances, or task data are fetched or rendered.
- The `ConfirmPromoteModal` adds a friction step but does not add a permission check — the
  backend is the authoritative enforcement point (403 Forbidden if missing roles).
- The "Promote to Production" button guard (`tenantType === 'test' && def.status === 'ACTIVE'`)
  is a UX convenience only. The backend enforces all invariants. The frontend guard must not
  be treated as a security boundary.

---

## Instance List Isolation

No frontend filter is needed. The instance list (`GET /api/v1/instances`) is already scoped
to the requesting user's tenant by backend JWT claim extraction + tenant column filtering
(ENV-02 schema isolation). A test-tenant user cannot see production instances through this
API regardless of frontend behaviour.

---

## Dependencies

- **Calls:** `useTenantContext` → `useAuth` → `AuthContext` (existing)
- **Calls:** `tenantsApi.getBySlug` at login (existing, extended to consume new fields)
- **Calls:** `definitionsApi.promote` (new method on existing file)
- **Reads:** `tenantsApi.list` items, `tenant_type` field (already returned by backend)
- **Must NOT depend on:** per-page `useEffect` data fetch to determine `tenant_type`; the
  value must come from the session context populated at login, not from a lazy fetch.
- **Must NOT depend on:** the tenant display name containing the word "test" or "staging" —
  the `tenant_type` field is the sole driver.

Cross-module dependency — **BACKEND-DEV must complete before FRONTEND-DEV can use
production tenant name**:

> `GET /api/v1/tenants/:slug` (`serializeTenant` in `src/api/routes/identity.zig`) must be
> augmented to include `production_tenant_display_name: string | null`. This requires a
> second lookup or JOIN on the `tenant` table using the `production_tenant_id` foreign key
> when `tenant_type = 'test'`. The field should be `null` for production tenants.
>
> Additionally, `UserSession` needs `tenant_id` (the UUID). `serializeTenant` already
> includes `tenant_id` in the response; `AuthProvider.login()` must read and store it.

---

## §8 Open Questions

**OQ-1 (BLOCKER — backend):** `GET /api/v1/tenants/:slug` currently returns
`production_tenant_id` (a UUID). The frontend has no by-UUID tenant lookup endpoint. The
banner needs the production tenant's display name. Required: augment `serializeTenant` to
include `production_tenant_display_name` (denormalized join on `production_tenant_id`). Until
this is done, FRONTEND-DEV should implement the banner in "fallback mode" — show "TEST
ENVIRONMENT" text with `"Paired with production: (unknown)"` as the secondary line — and
replace it with the real name once the backend field is available. This is acceptable as a
partial delivery per the requirement note ("no banner without the production name" is not
stated as a hard requirement).

**OQ-2 (FRONTEND-DEV — E2E test fixture update):** The `tryRestoreE2eSession` path in
`AuthProvider` reads a fixed shape from `sessionStorage`. When `tenant_id`, `tenant_type`,
and `production_tenant_display_name` are added to `UserSession`, all E2E test session seeds
in `web/tests/` that write to `sessionStorage` must include these new fields. FRONTEND-DEV
must update affected fixtures; absence of the fields will cause `useTenantContext` to return
`null` for `tenantType`, suppressing the banner in E2E tests even for test tenants.

**OQ-3 (minor — REQ-ANALYST confirm):** The requirement states "Promote to Production button
only on the Process Definition detail page". The current codebase has two candidates: the
canvas editor (`DefinitionEditorPage`, route `/definitions/:id`) and the list page
(`DefinitionListPage`). The design places the button in `DefinitionEditorPage` only. Confirm
this is the intended location, as `DefinitionListPage` has row-level actions (Activate,
Archive) that could logically include Promote. If the list page should also carry the button,
FRONTEND-DEV must add it there too.
