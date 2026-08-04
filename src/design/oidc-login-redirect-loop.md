# Design Artefact — WF-03: OIDC Login Redirect Loop Fix

**Module:** `oidc-login-redirect-loop`  
**Issue:** `ISS-0063`  
**Run:** `WF03-login-redirect-loop-20260601`  
**Status:** FINAL  
**Classification:** Type E

---

## 1. Module Purpose

This fix removes the login redirect loop by preserving the browser-visible origin through the Keycloak gateway, resolving the tenant OIDC authority from hostname on the backend, and keeping OIDC PKCE/callback state in browser session storage long enough for the callback to complete. The implementation addresses the root causes rather than adding a retry loop or a second login surface.

This is a mixed cross-cutting fix, not a reusable CRUD/list/migration pattern.

---

## 2. Classification

Type E is the correct classification because the issue spans three unrelated layers:

* nginx gateway forwarding for Keycloak
* backend tenant-config authority resolution
* frontend OIDC client configuration and state persistence

No first-match Type A, B, C, or D rule applies.

---

## 3. Behaviour Contract

### 3.1 Proxy contract

The nginx gateway must preserve the external host and port that the browser used. Keycloak must see the browser-visible authority, not the bare upstream hostname, so the generated authorization and logout URLs stay on `:8081` instead of falling back to port 80.

### 3.2 Backend contract

`GET /api/tenant-config?host={hostname}` resolves the authority and client ID for the current browser hostname. When the hostname is unknown or the database lookup fails, the endpoint falls back to the default localhost authority so the frontend can still start OIDC.

### 3.3 Frontend contract

The OIDC manager resolves its authority from tenant config, pins the OIDC metadata endpoints to that authority, and stores callback state in browser session storage. This keeps the PKCE verifier and callback state available across a reload or remount during `/auth/callback`.

---

## 4. Public Interface

### 4.1 Backend

```zig
pub const TenantConfigError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const TenantConfigResponse = struct {
    oidc_authority: []const u8,
    client_id: []const u8,
};

pub fn handleTenantConfig(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    query_str: []const u8,
) HandlerResult
```

### 4.2 Frontend

```ts
export interface TenantConfig {
  oidc_authority: string
  client_id: string
}

export async function fetchTenantConfig(hostname: string): Promise<TenantConfig>
export function getCachedTenantConfig(): TenantConfig

function buildOidcSettings(authority: string, clientId: string): UserManagerSettings

export async function getOidcManager(): Promise<UserManager>
export function startOidcSilentRenew(): void
```

### 4.3 Runtime consumers

* `AuthProvider` uses the OIDC manager to redirect unauthenticated or expired sessions back to Keycloak.
* `OidcCallbackPage` completes the callback flow and returns to `/` if the callback fails or the token is invalid.

---

## 5. Data Flow Diagram

```mermaid
flowchart LR
    B[Browser / SPA] --> N[nginx Keycloak gateway]
    N --> K[Keycloak]

    B --> T[GET /api/tenant-config?host=hostname]
    T --> L[tenant_config.zig]
    L --> D[(tenant_hostnames + tenant)]
    D --> J[JSON: oidc_authority + client_id]

    B --> F[fetchTenantConfig()]
    F --> M[getOidcManager()]
    M --> S[UserManager with sessionStorage-backed state store]
    S --> R[signinRedirect() / signinRedirectCallback()]
    R --> K

    R --> C[/auth/callback]
    C --> A[Authenticated app shell]

    A --> E[auth:session-expired / silent renew]
    E --> M
```

---

## 6. State Transitions

| State | Trigger | Next state |
|---|---|---|
| Unauthenticated | App mounts with no session | Resolve tenant config, then redirect to Keycloak |
| Redirecting | `signinRedirect()` starts | Callback pending |
| Callback pending | Keycloak returns to `/auth/callback` | Authenticated if PKCE state is present |
| Callback pending | Reload/remount during callback | Still pending because state lives in session storage |
| Authenticated | Access token near expiry | Silent renew |
| Authenticated | Session expires or logout happens | Clear session, then restart OIDC redirect |
| Callback failure | Invalid state, invalid code, or missing roles | Redirect to `/` and restart login from the app shell |

---

## 7. Error Taxonomy

### Backend `tenant_config.zig`

* `PoolExhausted` — no database connection available
* `PersistenceFailed` — query or row materialization failed
* `OutOfMemory` — response body or authority string allocation failed
* Unknown hostname or DB failure — not surfaced to the browser; the handler falls back to the default tenant config

### Frontend OIDC runtime

* Tenant-config fetch failure — cached fallback config is used
* Missing or invalid callback state — callback page redirects to `/`
* Missing or empty roles in the callback token — treated as an invalid login and redirected to `/`
* Silent renew failure — session expiry path fires and the app restarts the redirect flow

### Deployment dependency failures

* nginx strips the external port from `Host` — Keycloak generates the wrong authority
* hostname mismatch between browser origin and tenant config — OIDC starts on the wrong base URL

These are configuration failures, not user-facing application exceptions.

---

## 8. Dependencies

### 8.1 Backend dependencies

`tenant_config.zig` depends on:

* `db_pool.Pool`
* `response.HandlerResult`
* `obs/logger.zig`
* the `tenant_hostnames` and `tenant` tables

It must not depend on frontend state, router state, or any direct user-session storage.

### 8.2 Frontend dependencies

`OidcManager.ts` depends on:

* `fetchTenantConfig()` for hostname-based OIDC discovery
* `oidc-client-ts`
* `window.sessionStorage` via the OIDC client state store
* `window.location.origin` for the callback URL

It must not depend on `localStorage`, raw `fetch()` calls in components, or a hard-coded `/login` recovery route.

### 8.3 Config dependencies

Backend defaults:

* `BPM_IDP_BASE_URL` or `KEYCLOAK_BASE_URL` default to `http://localhost:8081`
* `OIDC_CLIENT_ID` defaults to `bpm-platform-api`

Frontend defaults:

* `VITE_OIDC_AUTHORITY` defaults to `http://localhost:8081/realms/bpm-default`
* `VITE_OIDC_CLIENT_ID` defaults to `bpm-platform-api`

The localhost fallback is intentional because the browser origin uses `localhost`, not `127.0.0.1`, during local development.

---

## 9. Open Questions

None for this fix. The current behavior is intentionally pinned to the browser-visible localhost origin and a hostname-based tenant-config lookup. If subdomain tenancy is reintroduced later, it should be a separate design.
