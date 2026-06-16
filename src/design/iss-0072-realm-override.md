# Module: ISS-0072 — Realm Override (tenant-config ?realm= hint)

Covers: ISS-0072

## Module purpose

This design addresses the missing realm hint mechanism identified in ISS-0072.
When multiple tenants share a single hostname (e.g. `127.0.0.1` in a dev
environment), the existing `?host=` lookup cannot disambiguate them.

Three coordinated changes add a `?realm=<slug>` override path so a platform
admin can navigate directly to any tenant's workspace without DNS configuration:

1. **Backend** — extend `GET /api/tenant-config` to accept an optional `?realm=`
   query parameter that bypasses hostname lookup and resolves config by tenant slug.
2. **Frontend (tenantConfig.ts)** — check sessionStorage and URL `?realm=` before
   falling back to the hostname lookup, and persist the resolved slug for page reloads.
3. **Frontend (OnboardingResultPage.tsx)** — render a "Open workspace" link on the
   completed onboarding screen that embeds `?realm=<slug>` in the URL.

No new tables, no migration, no schema changes.

---

## Public interface

### Backend — `src/api/routes/tenant_config.zig`

#### New function: `resolveTenantBySlug`

```zig
/// Query tenant by slug to get its idp_realm_id.
/// Returns null if no tenant row matches the slug.
fn resolveTenantBySlug(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    slug: []const u8,
) TenantConfigError!?[]const u8
```

- Executes: `SELECT idp_realm_id FROM tenant WHERE slug = $1 LIMIT 1`
- `slug` is bound as `$1` (prepared statement — no string interpolation).
- Returns a heap-allocated copy of the `idp_realm_id` string, owned by the caller.
- Returns `null` when no matching row is found; does **not** return an error.
- Error variants mirror `queryRealmByHostname`: `PoolExhausted`, `PersistenceFailed`, `OutOfMemory`.

#### Modified function: `handleTenantConfig`

Signature unchanged:

```zig
pub fn handleTenantConfig(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    query_str: []const u8,
) HandlerResult
```

Lookup priority (evaluated in order, first match wins):

1. If `?realm=<slug>` is present in `query_str`: call `resolveTenantBySlug(slug)`.
   - On match: use the returned `idp_realm_id`.
   - On no match or error: **fall through** to step 2 (do not return 404).
2. If `?host=<hostname>` is present: call `queryRealmByHostname(hostname)` (unchanged).
3. Default: use `"bpm-default"`.

The function continues to return HTTP 200 in all cases.

---

### Frontend — `web/src/auth/tenantConfig.ts`

#### New function: `resolveRealmFromUrl`

```ts
/**
 * Resolve a realm slug from URL/sessionStorage before falling back to hostname.
 *
 * Priority:
 *   1. sessionStorage key 'bpm_realm_slug' (set on a previous page load)
 *   2. URL query parameter 'realm'  (e.g. http://localhost:8080/?realm=swiftroute)
 *   3. null (caller falls back to hostname lookup)
 *
 * Side effect: if the slug is found in the URL it is written to sessionStorage
 * so that subsequent navigations within the SPA retain the correct realm.
 */
export function resolveRealmFromUrl(): string | null
```

Storage key: `bpm_realm_slug` (string, sessionStorage).  
Scope: session only — cleared when the browser tab closes.

#### Modified function: `fetchTenantConfig`

Signature unchanged:

```ts
export async function fetchTenantConfig(hostname: string): Promise<TenantConfig>
```

New behaviour before the existing hostname fetch:

1. Call `resolveRealmFromUrl()`.
2. If non-null: call `GET /api/tenant-config?realm=<slug>` via `client.get`.
3. If null: call existing `GET /api/tenant-config?host=<hostname>` path (unchanged).
4. Cache result in `_cachedConfig` as before.

---

### Frontend — `web/src/pages/admin/onboarding/OnboardingResultPage.tsx`

No new exported symbols. The change is additive JSX inside the existing
`phase === 'completed'` render branch.

**New UI element (workspace link):**

Rendered only when `view.result.slug` is defined (it is typed `slug?: string`).

```
Label: "Open [slug] workspace"
URL:   `${window.location.origin}/?realm=${view.result.slug}`
Target: same tab (no `target="_blank"`)
```

The link is placed below the existing summary table and above the "Back to Admin"
button, so the admin can copy or click it immediately after onboarding completes.

---

## Data flow diagram

```
Browser cold start with ?realm=swiftroute
──────────────────────────────────────────────────────────────
  1. tenantConfig.ts: resolveRealmFromUrl()
       → reads ?realm=swiftroute from URL
       → writes 'bpm_realm_slug'='swiftroute' to sessionStorage
       → returns 'swiftroute'

  2. fetchTenantConfig('127.0.0.1')
       → path: ?realm=swiftroute
       → GET /api/tenant-config?realm=swiftroute

  3. handleTenantConfig (backend)
       → getQueryParam(query_str, "realm") = "swiftroute"
       → resolveTenantBySlug("swiftroute")
           → SELECT idp_realm_id FROM tenant WHERE slug = $1
           → returns "swiftroute"
       → builds oidc_authority = "<BPM_IDP_BASE_URL>/realms/swiftroute"
       → returns {oidc_authority, client_id}

  4. OidcManager initialises with swiftroute authority
  5. Alice redirected to http://localhost:8081/realms/swiftroute — login succeeds

Browser reload (no ?realm= in URL)
──────────────────────────────────────────────────────────────
  1. resolveRealmFromUrl()
       → ?realm= absent from URL
       → reads sessionStorage 'bpm_realm_slug' = 'swiftroute'
       → returns 'swiftroute'
  2–5: same as above — realm retained across reloads

Onboarding result screen
──────────────────────────────────────────────────────────────
  OnboardingResultPage (phase=completed)
       → view.result.slug = 'swiftroute'
       → renders link: <origin>/?realm=swiftroute
       → admin clicks → cold start flow above
```

---

## Error taxonomy

All errors remain silent to callers (backend returns HTTP 200 with default realm;
frontend falls back to `DEFAULT_AUTHORITY`). This mirrors the existing behaviour of
`handleTenantConfig` and `fetchTenantConfig` — the login page always renders.

### Backend (`TenantConfigError` — unchanged error set)

| Variant | Cause | Behaviour |
|---|---|---|
| `PoolExhausted` | No DB connection available | Log WARN, use `bpm-default` |
| `PersistenceFailed` | Query or row-fetch failed | Log WARN, use `bpm-default` |
| `OutOfMemory` | Allocator cannot allocate | Fallback to hardcoded JSON literal |

`resolveTenantBySlug` uses the same `TenantConfigError` set as `queryRealmByHostname`.
No new error variants are introduced.

**Slug not found:** not an error — treated as "no match", falls through to hostname
lookup. This prevents a crafted `?realm=nonexistent` from returning an error page.

### Frontend

| Condition | Behaviour |
|---|---|
| `resolveRealmFromUrl` returns null | Falls through to `?host=` lookup (unchanged) |
| `GET /api/tenant-config?realm=` throws | `catch` block returns `DEFAULT_AUTHORITY` fallback |
| sessionStorage unavailable (private browsing) | `try/catch` wraps sessionStorage writes; degrades to URL-only path |

---

## State transitions

```
tenantConfig.ts lookup chain
──────────────────────────────
sessionStorage['bpm_realm_slug'] present?
  YES → use slug → GET ?realm=<slug>
  NO  → URL ?realm=<slug> present?
          YES → write sessionStorage → GET ?realm=<slug>
          NO  → GET ?host=<hostname>   [existing path]

handleTenantConfig lookup chain
────────────────────────────────
?realm=<slug> param present?
  YES → resolveTenantBySlug(slug)
          found?  → use returned idp_realm_id
          not found / error → continue
?host=<hostname> param present?
  YES → queryRealmByHostname(hostname)
          found?  → use returned idp_realm_id
          not found / error → continue
default: realm_id = "bpm-default"
```

---

## Dependencies

### Backend

| Dependency | Reason |
|---|---|
| `src/api/routes/tenant_config.zig` (existing) | Extended in place; new function added to same file |
| `tenant` table, `idp_realm_id` column | Queried by `resolveTenantBySlug` |
| `tenant_hostnames` table | Unchanged — used by existing `queryRealmByHostname` |
| `db_pool` (`pool.zig`) | Connection acquire/release |
| `obs/logger.zig` | WARN log on lookup failure |

`resolveTenantBySlug` MUST NOT join `tenant_hostnames` — it queries `tenant` directly
by `slug`. This keeps it independent of the hostname routing subsystem.

### Frontend

| Dependency | Reason |
|---|---|
| `web/src/auth/tenantConfig.ts` (existing) | Extended; `resolveRealmFromUrl` added, `fetchTenantConfig` modified |
| `web/src/pages/admin/onboarding/OnboardingResultPage.tsx` (existing) | Link added to `completed` render branch |
| `window.location.search` | URL param read |
| `window.sessionStorage` | Realm slug persistence |
| `window.location.origin` | Workspace link base URL |
| `@/api/client` | HTTP fetch (unchanged) |

`resolveRealmFromUrl` has no React dependency — it is a plain function callable
from `fetchTenantConfig` before any hook or component mounts.

---

## Security note

The `?realm=` parameter is read-only OIDC configuration. It selects which Keycloak
realm the browser is redirected to. It does not:

- Grant authentication or authorisation.
- bypass JWT validation in any middleware.
- allow the caller to access another tenant's data.

A user supplying an arbitrary `?realm=foo` can only redirect themselves to a Keycloak
login page for realm `foo`. If `foo` does not exist in Keycloak, the OIDC authorisation
request will fail at the IdP. No BPM server-side data is accessible without a valid JWT.

The slug is bound as `$1` in a prepared statement; SQL injection is not possible.

---

## Open questions

None. All design decisions are derivable from ISS-0072 root cause analysis and
the existing implementation patterns in `tenant_config.zig` and `tenantConfig.ts`.
