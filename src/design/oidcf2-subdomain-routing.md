# Module: OIDCF2 — Subdomain Tenant Routing (OIDC-F-05, OIDC-F-06)

## Module purpose

Enable multi-tenant OIDC configuration discovery by hostname.  A new
`tenant_hostnames` table maps arbitrary hostnames to tenants.  A public
backend endpoint `GET /api/tenant-config?host={hostname}` returns the
correct `oidc_authority` and `client_id` for that tenant (or the
default tenant config when no binding is found).  The frontend fetches
this config on startup and uses it to initialise `OidcManager` instead
of static env vars.

**Requirements covered:** OIDC-F-05, OIDC-F-06.

---

## §1 — New DB migration: `050_tenant_hostnames.sql`

Migration file: `migrations/050_tenant_hostnames.sql`

Rationale for number: the highest existing migration is
`049_repository_service_catalog.sql`; the next sequential number is `050`.

```sql
-- 050_tenant_hostnames.sql
-- OIDCF2: per-tenant hostname registry for subdomain-based config discovery.

CREATE TABLE IF NOT EXISTS tenant_hostnames (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID        NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    hostname   TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_hostnames_hostname_uq UNIQUE (hostname)
);

CREATE INDEX IF NOT EXISTS tenant_hostnames_hostname_idx
    ON tenant_hostnames (hostname);
```

**Notes:**
- `tenant(id)` is the correct FK target (the existing table name confirmed
  in migration `031_adp04b_tenant_realm_binding.sql` — the table is
  `tenant`, not `tenants`).
- `ON DELETE CASCADE` ensures orphan rows are cleaned up when a tenant is
  deleted.
- The `UNIQUE` constraint on `hostname` is also the primary lookup index;
  the explicit `CREATE INDEX` is retained for performance explicitness.

---

## §2 — Backend module: `src/api/routes/tenant_config.zig`

### Error set

```zig
pub const TenantConfigError = error{
    /// Database pool exhausted — no connection available.
    PoolExhausted,
    /// Query or row-fetch failed.
    PersistenceFailed,
    /// Allocator out of memory.
    OutOfMemory,
};
```

### Response type

```zig
pub const TenantConfigResponse = struct {
    oidc_authority: []const u8,
    client_id: []const u8,
};
```

### Public function signature

```zig
/// Handle GET /api/tenant-config?host={hostname}.
///
/// Parameters:
///   allocator  — arena allocator for the request lifetime.
///   pool       — database connection pool (read-only usage).
///   query_str  — raw query string from the HTTP request target
///                (e.g. "host=acme1.localhost&foo=bar").
///
/// Returns a HandlerResult (status_code, body []const u8, content_type).
/// Never returns an error to the caller — internal errors produce a
/// 200 response with the default tenant config so that the frontend
/// login page always renders.
pub fn handleTenantConfig(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    query_str: []const u8,
) HandlerResult
```

### Resolution logic (step-by-step)

1. **Extract `host` query param** from `query_str` using the same inline
   `QS.get(query_str, "host")` helper already present in `main.zig`.

2. **Query the database** (prepared statement; `$1` = hostname):

   ```sql
   SELECT t.idp_realm_id
   FROM   tenant_hostnames th
   JOIN   tenant t ON t.id = th.tenant_id
   WHERE  th.hostname = $1
   LIMIT  1
   ```

   **Column name clarification:** the realm identifier is stored as
   `tenant.idp_realm_id` (confirmed by migrations `031` and `041` and
   `src/oidc/realm_tenant_binding.zig`).  There is **no** separate
   `oidc_realm_bindings` table in the schema; the correct join target is
   the `tenant` table directly.

3. **Construct authority URL:**
   - If a row is found: `oidc_authority = KEYCLOAK_BASE_URL + "/realms/" + idp_realm_id`
   - If no row is found (unknown hostname): `oidc_authority = KEYCLOAK_BASE_URL + "/realms/bpm-default"`
   - `KEYCLOAK_BASE_URL` is read from env; default `http://localhost:8081`.

4. **`client_id`** is always the value of env var `OIDC_CLIENT_ID`;
   default `bpm-platform-api`.  There is no per-tenant client ID in the
   current schema.

5. **On any DB error** fall through to the default config — same
   response as "hostname not found".  Log the error at WARN level.
   Never return a non-200 status; the frontend must always get a usable
   config response.

6. Serialise `TenantConfigResponse` to JSON and return
   `HandlerResult{ .status_code = 200, .body = json, .content_type = "application/json" }`.

### Imports required

```zig
const std = @import("std");
const db_pool = @import("pool");
const response = @import("../response.zig");
const errors = @import("../errors.zig");
const logger = @import("../../obs/logger.zig");
const metrics = @import("../../obs/metrics.zig");

pub const HandlerResult = response.HandlerResult;
```

---

## §3 — Router registration in `src/main.zig`

The existing router is a flat `if / else if` chain in `serveRequest()`.
Public routes (`/health/live`, `/health/ready`, `/metrics`, `/openapi.json`)
are matched **before** the authenticated `/api/v1/...` block.

`GET /api/tenant-config` must be registered in the **same pre-auth
section**, so it is reachable without a JWT.

### Pattern (existing example for reference)

```zig
// ── /metrics ─────────────────────────────────────────────────────────
else if (std.mem.eql(u8, path, "/metrics")) {
    const r = metrics_routes.handleMetrics(req_alloc);
    resp_status = r.status_code;
    resp_body = r.body;
    resp_content_type = r.content_type;
}
```

### New branch to add (immediately before the `/api/v1/...` block)

```zig
// ── GET /api/tenant-config  (public — no auth required) ──────────────
else if (std.mem.eql(u8, path, "/api/tenant-config") and method == .GET) {
    const r = tenant_config_routes.handleTenantConfig(req_alloc, pool, query_str);
    resp_status = r.status_code;
    resp_body = r.body;
    resp_content_type = r.content_type;
}
```

### Import declaration to add in `main.zig`

```zig
pub const tenant_config_routes = @import("api/routes/tenant_config.zig");
```

Add this alongside the existing `pub const health_routes = ...` line
(top-level pub const declarations in `main.zig`).

Pass `pool` directly — the same `*db_pool.Pool` pointer already passed to
other route handlers (`handleReady`, etc.).  No new state or service
object is required.

---

## §4 — Frontend: `web/src/auth/tenantConfig.ts`

New module.  No framework dependency (plain TypeScript module singleton
— no Zustand store required; the module-level variable achieves the same
caching guarantee without an extra dependency).

### Full module interface

```typescript
/** Module-level cache — set once per session, never cleared. */
let cachedConfig: { oidc_authority: string; client_id: string } | null = null;

/** Compile-time fallback values (VITE env vars or hardcoded defaults). */
const DEFAULT_AUTHORITY =
  (import.meta.env.VITE_OIDC_AUTHORITY as string | undefined) ??
  'http://localhost:8081/realms/bpm-default';

const DEFAULT_CLIENT_ID =
  (import.meta.env.VITE_OIDC_CLIENT_ID as string | undefined) ??
  'bpm-platform-api';

const DEFAULT_CONFIG = { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID };

/**
 * Fetch the OIDC config for the given hostname from the backend.
 *
 * - Returns `cachedConfig` immediately if already set (idempotent).
 * - Otherwise calls `GET /api/tenant-config?host={hostname}`.
 * - On any network or non-200 error, returns DEFAULT_CONFIG silently.
 * - Sets `cachedConfig` before returning, so subsequent calls are synchronous.
 */
export async function fetchTenantConfig(
  hostname: string,
): Promise<{ oidc_authority: string; client_id: string }>

/**
 * Return the cached config synchronously.
 * Returns DEFAULT_CONFIG if fetchTenantConfig has not completed yet.
 * Use only where async is impossible (backward-compat path).
 */
export function getCachedTenantConfig(): { oidc_authority: string; client_id: string }
```

### Behaviour contract

| Scenario | Return value |
|---|---|
| First call, backend returns 200 with valid JSON | backend values; sets cache |
| Subsequent call (any hostname) | cached value immediately |
| First call, network error | DEFAULT_CONFIG; sets cache to defaults |
| First call, non-200 response | DEFAULT_CONFIG; sets cache to defaults |
| `hostname` empty string | DEFAULT_CONFIG; no HTTP request |

---

## §5 — Frontend: `OidcManager.ts` refactor

### Current state

```typescript
// Sync singleton using static env vars
export const oidcManager = new UserManager(settings)
```

### Target state

Two exports must coexist to maintain backward compatibility with
`LoginPage`, `OidcCallbackPage`, and `AuthProvider`:

```typescript
/**
 * Backward-compatible sync export.
 * Built from DEFAULT_AUTHORITY / DEFAULT_CLIENT_ID at module load time.
 * Used by OidcCallbackPage.signinRedirectCallback() which cannot be async.
 * LoginPage MUST migrate to getOidcManager() for the SSO button.
 */
export const oidcManager: UserManager   // unchanged export; uses static env vars

/**
 * Lazy async factory — creates and caches a UserManager from the
 * live tenant config fetched by tenantConfig.ts.
 *
 * - First call awaits fetchTenantConfig(window.location.hostname).
 * - Subsequent calls return the cached manager synchronously (Promise wraps it).
 * - The returned manager is a different instance from `oidcManager` when the
 *   hostname has a non-default realm binding.
 */
export async function getOidcManager(): Promise<UserManager>
```

### Caching guarantee

`getOidcManager()` uses a module-level `let cachedManager: UserManager | null = null`.
Once set it is never replaced within the session.

### `startOidcSilentRenew` compatibility

`startOidcSilentRenew()` continues to operate on the sync `oidcManager`.
Silent renew runs against whatever realm the static config points to.
Post-login the access token is valid for the correct realm because the
user authenticated via the `getOidcManager()` instance.  No change to
`startOidcSilentRenew` signature or implementation required.

---

## §6 — Frontend startup: where `fetchTenantConfig` is called

### Pre-warm call (fire-and-forget)

`web/src/main.tsx` currently calls `ReactDOM.createRoot(...).render(...)` 
with no wrapper component.  To add a `useEffect` hook, extract a thin
`AppRoot` functional component inside `main.tsx`:

```typescript
// In main.tsx — new wrapper component
function AppRoot() {
  useEffect(() => {
    void fetchTenantConfig(window.location.hostname)
  }, [])
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
}

// Render call changes to:
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <AppRoot />
  </React.StrictMode>,
)
```

The `useEffect` is fire-and-forget.  It pre-warms the
`cachedConfig` before the user interacts with the page.  If the user
clicks the SSO button before the fetch completes, `getOidcManager()`
will `await` the same in-flight `fetchTenantConfig` promise (the module
singleton serialises concurrent callers).

### SSO button migration

`LoginPage.tsx` line 174 currently:
```typescript
onClick={() => { void oidcManager.signinRedirect() }}
```

Must change to:
```typescript
onClick={() => { void getOidcManager().then(mgr => mgr.signinRedirect()) }}
```

This ensures the correct realm-specific `UserManager` is used for login
when the hostname maps to a non-default tenant.

### `OidcCallbackPage` — no change required

`OidcCallbackPage` calls `oidcManager.signinRedirectCallback()`.
The callback URL is realm-agnostic (oidc-client-ts reads the `state`
parameter from the IdP redirect to match the correct session).  The
sync `oidcManager` instance is sufficient here; no async change needed.

### `AuthProvider` — no change required

`AuthProvider` uses `oidcManager` for silent renew and event listeners.
This continues to work with the sync export.  The tenant-specific
authority is baked into the access token's `iss` claim; silent renew
targets the same realm as the original login.

---

## §7 — Modified / new files and all public interfaces

| File | Status | Public interface summary |
|---|---|---|
| `migrations/050_tenant_hostnames.sql` | **NEW** | DDL only — no public Zig/TS interface |
| `src/api/routes/tenant_config.zig` | **NEW** | `TenantConfigError`, `TenantConfigResponse`, `handleTenantConfig(allocator, pool, query_str) HandlerResult` |
| `src/main.zig` | **MODIFIED** | Add `pub const tenant_config_routes` import; add `else if` branch for `GET /api/tenant-config` before `/api/v1/...` |
| `web/src/auth/tenantConfig.ts` | **NEW** | `fetchTenantConfig(hostname) Promise<{oidc_authority, client_id}>`, `getCachedTenantConfig()` |
| `web/src/auth/OidcManager.ts` | **MODIFIED** | Keep `export const oidcManager`; add `export async function getOidcManager(): Promise<UserManager>` |
| `web/src/main.tsx` | **MODIFIED** | Extract `AppRoot` component; add `useEffect` that calls `fetchTenantConfig` |
| `web/src/pages/LoginPage.tsx` | **MODIFIED** | SSO button `onClick` migrated from `oidcManager.signinRedirect()` to `getOidcManager().then(m => m.signinRedirect())` |

### Files unchanged

- `web/src/pages/OidcCallbackPage.tsx` — uses sync `oidcManager`, no change
- `web/src/auth/AuthProvider.tsx` — uses sync `oidcManager`, no change
- `web/src/router.tsx` — no change

---

## §8 — Open constraints (deferred to implementor)

1. **URL-decoding of `host` param**: The `QS.get` helper in `main.zig`
   does not URL-decode values.  If hostnames may contain percent-encoded
   characters in practice, the implementor should add a decode step.
   For ASCII hostnames (the common case) no decoding is needed.

2. **Port stripping**: Browsers include the port in `window.location.hostname`?
   No — `hostname` excludes the port (that is `window.location.host`).
   The implementation should use `window.location.hostname` (no port).
   If there is a desire to strip ports from stored hostnames for
   flexibility, that is a runtime normalisation decision left to the
   implementor.

3. **Response caching headers**: The requirements state the response is
   cacheable.  The implementor may add `Cache-Control: public, max-age=300`
   to the response headers if desired.  The current `HandlerResult`
   struct supports extra headers via the `content_type` field only; if
   cache headers are wanted, `HandlerResult` would need a small extension
   (out of scope for this feature).

4. **`getOidcManager` race between two concurrent SSO button clicks**:
   The module singleton pattern in TypeScript is synchronous-safe because
   JS is single-threaded.  A module-level `let managerPromise: Promise<UserManager> | null`
   (storing the in-flight promise, not the result) further ensures only
   one `fetchTenantConfig` call is made regardless of timing.  Implementor
   should use this pattern.

5. **CORS**: The `GET /api/tenant-config` endpoint may be called from a
   subdomain different from the API origin.  If the backend does not
   currently set CORS headers on public routes, adding
   `Access-Control-Allow-Origin: *` to this specific endpoint is
   appropriate (response contains no sensitive data).  Implementor to
   check current CORS policy.
