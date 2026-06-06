# Module: Stage F8 — Tenant Management API

**Requirements covered:** TM-01, TM-02, TM-03
**Classification:** Type E (novel/cross-cutting — PATCH endpoint spans Registry, Keycloak adapter, and IdentityProvider interface; `GET /api/v1/tenants` is a new platform-scoped endpoint absent from any existing Type A template)
**Related designs:**
- `src/design/adp-04b-tenant-realm-binding.md` — tenant Registry contracts
- `src/design/onboarding_gui.md` — existing `/admin/onboarding/new` route (reused by TM-02)
- `src/design/adp-03-tenant-context-resolution-api.md` — AuthPrincipal and RBAC enforcement

---

## 1. Module purpose

This module introduces two new platform-admin capabilities:

- **GET /api/v1/tenants** — list all registered tenants with pagination and optional slug/display-name search. Used by the TM-01 tenant list page.
- **PATCH /api/v1/tenants/:slug** — update mutable tenant fields (`display_name`, `hostname`, `redirect_uris`). Slug and `idp_realm_id` are immutable — any attempt to set them in the request body is rejected at the handler boundary before any storage is touched. `hostname` and `redirect_uris` are propagated to the Keycloak realm client; `display_name` is persisted in the `tenant` database table.

**TM-02 (navigation concern only):** No new backend route or database change is required. The "Add Tenant" button on the tenant list page links to the existing `/admin/onboarding/new` route already delivered in Stage F7 (ONB-UI-02). This is a frontend navigation concern only, documented here to close the requirement traceability.

Both endpoints are restricted to `PLATFORM_ADMIN`. Non-admin callers receive `403 Forbidden` from the existing RBAC middleware before route handlers execute.

---

## 2. Public interface

### 2.1 New types — `src/identity/registry.zig`

```zig
pub const ListTenantsParams = struct {
    search: ?[]const u8,
    limit: u16,
    offset: u32,
};

pub const TenantListPage = struct {
    items: []Tenant,
    total: u64,

    pub fn deinit(self: TenantListPage, allocator: std.mem.Allocator) void;
};
```

### 2.2 New Registry methods — `src/identity/registry.zig`

```zig
/// Return all tenants matching the optional search filter, ordered
/// by created_at DESC. Caller owns the returned TenantListPage.
pub fn listTenants(
    self: *Registry,
    allocator: std.mem.Allocator,
    params: ListTenantsParams,
) RegistryError!TenantListPage;

/// Fetch a single tenant by slug. Returns null if not found.
/// Caller owns the returned Tenant if non-null.
pub fn selectTenantBySlug(
    self: *Registry,
    allocator: std.mem.Allocator,
    slug: []const u8,
) RegistryError!?Tenant;

/// Update the display_name field for the tenant identified by slug.
/// Returns the full updated Tenant row. Returns error.TenantNotFound
/// if no row matches the slug.
pub fn updateTenantDisplayName(
    self: *Registry,
    allocator: std.mem.Allocator,
    slug: []const u8,
    display_name: []const u8,
) RegistryError!Tenant;
```

`RegistryError` already contains `TenantNotFound`, `PoolExhausted`, `PersistenceFailed`, and `OutOfMemory` — no additions needed to the error set.

### 2.3 New types — `src/identity/provider/types.zig`

```zig
/// Input for updating the redirect URIs of an existing Keycloak client.
pub const UpdateClientInput = struct {
    realm_id: []const u8,
    /// The clientId value (equals the tenant slug in this platform).
    client_name: []const u8,
    redirect_uris: []const []const u8,
};

pub const UpdateClientResult = struct {
    client_id: []const u8,

    pub fn deinit(self: UpdateClientResult, allocator: std.mem.Allocator) void;
};

/// Input for updating the frontend (hostname) URL of an existing Keycloak realm.
pub const UpdateRealmFrontendUrlInput = struct {
    realm_id: []const u8,
    /// The new frontend URL, e.g. "https://tenant.bpm.example.com".
    frontend_url: []const u8,
};
```

### 2.4 New IdentityProvider interface functions — `src/identity/provider/interface.zig`

Two new function pointers must be added to the `IdentityProvider` vtable:

```zig
/// Update the redirectUris list for the named client in the given realm.
updateClientFn: *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    input: types.UpdateClientInput,
) errors.ProviderError!types.UpdateClientResult,

/// Update the frontend URL attribute of an existing realm.
updateRealmFrontendUrlFn: *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    input: types.UpdateRealmFrontendUrlInput,
) errors.ProviderError!void,
```

The Keycloak adapter (`src/identity/provider/adapters/keycloak/provider.zig`) must implement both functions and register them in `Adapter.asIdentityProvider`.

**Keycloak Admin REST API calls implied by the two functions:**

`updateClient`:
1. `GET /admin/realms/{realm_id}/clients?clientId={client_name}` — resolve Keycloak-internal client UUID.
2. `GET /admin/realms/{realm_id}/clients/{uuid}` — fetch full client representation.
3. Merge `redirect_uris` into the representation.
4. `PUT /admin/realms/{realm_id}/clients/{uuid}` — persist the updated representation.

`updateRealmFrontendUrl`:
1. `GET /admin/realms/{realm_id}` — fetch current realm representation.
2. Merge `{ attributes: { frontendUrl: frontend_url } }` into the representation.
3. `PUT /admin/realms/{realm_id}` — persist.

### 2.5 Service-layer functions — `src/identity/identity_service.zig` (or equivalent module)

```zig
pub const PatchTenantInput = struct {
    slug: []const u8,
    display_name: ?[]const u8,
    hostname: ?[]const u8,
    redirect_uris: ?[]const []const u8,
};

pub const PatchTenantError = error{
    TenantNotFound,
    ImmutableFieldUpdate,
    NoRealmBound,
    KeycloakSyncFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

/// Apply a partial update to a tenant. Caller must hold PLATFORM_ADMIN.
/// Propagates hostname and redirect_uris changes to Keycloak if the
/// tenant has a bound realm (idp_realm_id non-null).
/// Returns error.NoRealmBound when hostname or redirect_uris are present
/// in the input but the tenant has no idp_realm_id.
pub fn patchTenant(
    allocator: std.mem.Allocator,
    actor: auth_mod.AuthPrincipal,
    registry: *registry_mod.Registry,
    provider: *provider_interface.IdentityProvider,
    input: PatchTenantInput,
) PatchTenantError!registry_mod.Tenant;

/// List all tenants. Caller must hold PLATFORM_ADMIN.
/// Thin delegation to registry.listTenants after RBAC check.
pub fn listTenants(
    allocator: std.mem.Allocator,
    actor: auth_mod.AuthPrincipal,
    registry: *registry_mod.Registry,
    params: registry_mod.ListTenantsParams,
) registry_mod.RegistryError!registry_mod.TenantListPage;
```

### 2.6 API route handlers — `src/api/routes/identity.zig`

```zig
/// GET /api/v1/tenants
/// Query params: search (optional string), limit (optional u16), offset (optional u32).
/// Role gate: PLATFORM_ADMIN.
/// Response 200: { items: Tenant[], total: u64 }
pub fn handleListTenants(
    allocator: std.mem.Allocator,
    principal: auth_mod.AuthPrincipal,
    registry: *registry_mod.Registry,
    query_params: registry_mod.ListTenantsParams,
) routes.HandlerResult;

/// PATCH /api/v1/tenants/:slug
/// Body: { display_name?: string, hostname?: string, redirect_uris?: string[] }
/// Role gate: PLATFORM_ADMIN.
/// Immutability: reject body containing "slug" or "idp_realm_id" keys → 422.
/// Response 200: updated Tenant object.
pub fn handlePatchTenant(
    allocator: std.mem.Allocator,
    principal: auth_mod.AuthPrincipal,
    registry: *registry_mod.Registry,
    provider: *provider_interface.IdentityProvider,
    slug: []const u8,
    body: []const u8,
) routes.HandlerResult;
```

### 2.7 Frontend API module — `web/src/api/tenants.ts` (new file)

TypeScript interfaces and API functions required by both the generated `TenantsPage` and the custom `EditTenantPage`:

```typescript
export interface Tenant {
  slug: string;
  display_name: string;
  idp_realm_id: string | null;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
}

export interface TenantListPage {
  items: Tenant[];
  total: number;
}

export interface PatchTenantBody {
  display_name?: string;
  hostname?: string;
  redirect_uris?: string[];
}

export function listTenants(params?: {
  search?: string;
  limit?: number;
  offset?: number;
}): Promise<TenantListPage>;

export function patchTenant(slug: string, body: PatchTenantBody): Promise<Tenant>;
```

Both functions call through `apiClient` from `web/src/api/client.ts`. No raw `fetch`.

### 2.8 Frontend routes to add — `web/src/router.tsx`

| Path | Component | Purpose |
|---|---|---|
| `/admin/tenants` | `TenantsPage` (generated from `tenant-list.list-page.yaml`) | TM-01 list |
| `/admin/tenants/:slug/edit` | `EditTenantPage` (custom) | TM-03 edit form |

Both routes live inside the existing `ProtectedRoute` + `AppShell` guard exactly as all other admin pages. The "Tenants" nav entry should be added to the admin sidebar, visible only to `PLATFORM_ADMIN` (same DOM-hiding pattern as the "Register Tenant" entry).

### 2.9 EditTenantPage (TM-03 frontend form — custom component)

File: `web/src/pages/admin/tenants/EditTenantPage.tsx`

This page is **not** generated by codegen — it is a custom component because it:
- has two distinct field categories (DB-backed vs. Keycloak-backed), and
- requires read-only display of immutable fields (`slug`, `idp_realm_id`) alongside editable fields.

Fields:
- `slug` — read-only display
- `idp_realm_id` — read-only display (may be null)
- `display_name` — editable text input
- `hostname` — editable text input
- `redirect_uris` — dynamic list (add/remove entries), at least one required

On mount: the page may seed form values from the tenant list query cache or from a separate `GET /api/v1/tenants` call filtered by slug. FRONTEND-DEV decides the appropriate data-loading strategy.

On submit: calls `patchTenant(slug, body)`. On 200 → navigate to `/admin/tenants`. On 4xx/5xx → display error banner with the resolved error message (see error taxonomy below).

---

## 3. Data flow diagram

```
PLATFORM_ADMIN browser
    │
    ├─ GET /admin/tenants ─────────────────────────────────────────────────┐
    │       TenantsPage (generated)                                        │
    │       queryFn: GET /api/v1/tenants                                   │
    │           │                                                          │
    │           └─► handleListTenants                                      │
    │                   │                                                  │
    │                   └─► Registry.listTenants ──► tenant table (SELECT) │
    │                                                                      │
    └─ PATCH /api/v1/tenants/:slug ──────────────────────────────────────┐
            EditTenantPage (custom)                                      │
            useMutation: PATCH /api/v1/tenants/:slug                    │
                │                                                        │
                └─► handlePatchTenant                                    │
                        │                                                │
                        ├─ Immutability check (slug/idp_realm_id)        │
                        │       └─ reject → 422                          │
                        │                                                │
                        ├─► Registry.selectTenantBySlug                  │
                        │       └─ not found → 404                       │
                        │                                                │
                        ├─► [if display_name present]                    │
                        │       Registry.updateTenantDisplayName         │
                        │           └─► tenant table (UPDATE)            │
                        │                                                │
                        ├─► [if hostname present AND idp_realm_id set]   │
                        │       provider.updateRealmFrontendUrl          │
                        │           └─► Keycloak PUT /admin/realms/{id}  │
                        │                                                │
                        ├─► [if redirect_uris present AND idp_realm_id]  │
                        │       provider.updateClient                    │
                        │           ├─► Keycloak GET clients?clientId=…  │
                        │           ├─► Keycloak GET clients/{uuid}      │
                        │           └─► Keycloak PUT clients/{uuid}      │
                        │                                                │
                        └─► Registry.selectTenantBySlug (re-fetch)      │
                                └─ return updated Tenant as 200 JSON    │
```

---

## 4. Error taxonomy

### 4.1 Backend error set — `PatchTenantError`

| Variant | HTTP status | JSON error code | Condition |
|---|---|---|---|
| `TenantNotFound` | 404 | `tenant_not_found` | Slug does not exist in the `tenant` table |
| `ImmutableFieldUpdate` | 422 | `immutable_field_update` | Request body contains `slug` or `idp_realm_id` key |
| `NoRealmBound` | 422 | `no_realm_bound` | `hostname` or `redirect_uris` update requested, but `tenant.idp_realm_id` is null |
| `KeycloakSyncFailed` | 502 | `keycloak_sync_failed` | Keycloak adapter returned a non-success status for client or realm update |
| `PoolExhausted` | 503 | `service_unavailable` | DB connection pool exhausted |
| `PersistenceFailed` | 500 | `internal_error` | Unexpected DB error |
| `OutOfMemory` | 500 | `internal_error` | Allocator failure |

### 4.2 Frontend error display

`EditTenantPage` maps the API error code to a user-visible banner message:

| `error` field | Banner text |
|---|---|
| `tenant_not_found` | "This tenant no longer exists." |
| `immutable_field_update` | "Slug and IDP realm ID cannot be changed." |
| `no_realm_bound` | "This tenant has no Keycloak realm. Hostname and redirect URIs cannot be set." |
| `keycloak_sync_failed` | "The change was saved locally but could not be propagated to Keycloak. Retry or contact an administrator." |
| *(other / network)* | "An unexpected error occurred. Please try again." |

---

## 5. Immutability contract

The `PATCH /api/v1/tenants/:slug` handler MUST inspect the raw JSON request body for the presence of `"slug"` or `"idp_realm_id"` keys **before** any registry or provider call. If either key is present (regardless of value), the handler returns 422 with:

```json
{
  "error": "immutable_field_update",
  "field": "<slug | idp_realm_id>"
}
```

This check is a hard requirement: it prevents client bugs from silently sending immutable fields and receiving an apparent success.

---

## 6. RBAC enforcement

Both `GET /api/v1/tenants` and `PATCH /api/v1/tenants/:slug` require `PLATFORM_ADMIN`. Enforcement follows the existing pattern in `identity.zig`:

```
if (!principalHasRole(principal, .PLATFORM_ADMIN))
    return errorResult(allocator, 403, "forbidden");
```

No other roles are permitted. Tenant-scoped callers (non-default tenants) are also excluded because these endpoints operate on the global tenant registry — the principal's tenant scope is irrelevant and should not be checked.

---

## 7. Dependencies

| Dependency | Nature |
|---|---|
| `src/identity/registry.zig` | New Registry methods; existing `Tenant`, `RegistryError`, and `Registry` types |
| `src/identity/provider/interface.zig` | Two new vtable function pointers (`updateClientFn`, `updateRealmFrontendUrlFn`) |
| `src/identity/provider/types.zig` | Two new input types (`UpdateClientInput`, `UpdateRealmFrontendUrlInput`) and one result type (`UpdateClientResult`) |
| `src/identity/provider/adapters/keycloak/provider.zig` | Two new private functions registered in `asIdentityProvider` |
| `src/api/routes/identity.zig` | Two new handler functions |
| `src/api/middleware/auth.zig` | Existing `AuthPrincipal`, `principalHasRole` — unchanged |
| `web/src/api/queryKeys.ts` | New `queryKeys.admin.tenants` entry |
| `web/src/api/tenants.ts` | New file |
| `web/src/router.tsx` | Two new routes |
| `templates/specs/tenant-list.list-page.yaml` | Drives codegen for `TenantsPage` |

**Must NOT depend on:**
- `src/engine/transition.zig` — no engine interaction
- Any other tenant's scoped data — these are platform-wide operations

---

## 8. Open questions

1. **Keycloak client update atomicity:** The `updateClient` flow (GET existing representation → merge → PUT back) is not atomic with respect to Keycloak concurrent updates. Is an optimistic-lock / ETag check required, or is the risk acceptable for an admin-only flow?

2. **Partial success handling:** If `display_name` update succeeds but the subsequent Keycloak `redirect_uris` update fails, the DB and Keycloak are out of sync. Should the handler return `keycloak_sync_failed` (leaving the DB update in place) or attempt a DB rollback? Recommend: leave DB update in place and return 502 with the `keycloak_sync_failed` code — the frontend banner already communicates the partial state.

3. **Tenant list pagination defaults:** `limit` default is 50, `offset` default is 0 — confirm these are acceptable for the expected tenant count at this stage.

4. **Sidebar nav label:** Should the new nav entry read "Tenants" or "Manage Tenants"? Consistent with "Users", "Groups" → recommend "Tenants".
