# UAT Tenant URL — Design Artefact

**Module:** `uat-tenant-url`
**Type:** E — Cross-cutting (pipeline test infrastructure + documentation)
**Requirements:** UAT-TM-01, UAT-TM-02, UAT-TM-03, UAT-TM-04
**Status:** Draft

---

## 1. Module purpose

The UAT Tenant URL feature enables the UAT Runner and pipeline tests to
authenticate against per-tenant Keycloak realms instead of the single
hardcoded `bpm-default` realm. The only input a caller needs is a tenant
slug (e.g. `swiftroute`); the system resolves the Keycloak realm
automatically via the existing `GET /api/v1/tenants/:slug` endpoint.

This is a **test-infrastructure-only** change — no production code is
modified. The affected files are:

1. `web/tests/e2e/pipeline.ts` — TypeScript helper functions
2. `docs/agents/UAT_RUNNER.md` — workflow documentation
3. `docs/agents/uat-scenario-schema.md` — schema documentation

---

## 2. Public interface

### 2.1 Existing functions — modified signatures

All changes are **backward-compatible**. New parameters are optional with
defaults matching current behaviour.

#### `getKeycloakToken()` (modified)

```typescript
// BEFORE:
export async function getKeycloakToken(
  request: APIRequestContext,
  username?: string,        // default: 'admin-user'
  password?: string,        // default: 'admin-pass'
): Promise<string>

// AFTER:
export async function getKeycloakToken(
  request: APIRequestContext,
  username?: string,        // default: 'admin-user'
  password?: string,        // default: 'admin-pass'
  realm?: string,           // default: 'bpm-default'  ← NEW
): Promise<string>
```

**Behaviour change:**
- The module-level `KEYCLOAK_TOKEN_URL` constant is removed.
- The token URL is now built dynamically:
  `KEYCLOAK_BASE_URL + '/realms/' + (realm ?? 'bpm-default') + '/protocol/openid-connect/token'`
- `KEYCLOAK_BASE_URL` remains a module-level constant from
  `process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081'`.
- When `realm` is omitted, behaviour is identical to the current code.

#### `refreshTokenIfNeeded()` (modified)

```typescript
// BEFORE:
export async function refreshTokenIfNeeded(
  request: APIRequestContext,
  token: string,
  username?: string,        // default: 'admin-user'
  password?: string,        // default: 'admin-pass'
): Promise<string>

// AFTER:
export async function refreshTokenIfNeeded(
  request: APIRequestContext,
  token: string,
  username?: string,        // default: 'admin-user'
  password?: string,        // default: 'admin-pass'
  realm?: string,           // default: 'bpm-default'  ← NEW
): Promise<string>
```

**Behaviour change:**
- Passes `realm` through to `getKeycloakToken()`.
- When `realm` is omitted, behaviour is identical to the current code.

### 2.2 New function — `resolveTenantContext()`

```typescript
export interface TenantContext {
  /** UUID of the tenant — for API calls that require tenant_id */
  tenantId: string
  /** Keycloak realm name (e.g. 'swiftroute'). Same as slug for non-default tenants. */
  realm: string
  /** Tenant slug (e.g. 'swiftroute') */
  slug: string
  /** Fully-qualified Keycloak token endpoint URL for this realm */
  tokenUrl: string
}

/**
 * Resolve a tenant slug into a TenantContext by calling
 * GET /api/v1/tenants/:slug.
 *
 * Results are cached in-memory per slug for the lifetime of the
 * test process to avoid repeated API calls.
 *
 * @param request  - Playwright APIRequestContext
 * @param companySlug - tenant slug from scenario YAML (e.g. 'swiftroute')
 * @param adminToken - a valid admin token (bpm-default realm) to authorise the API call
 * @returns TenantContext
 * @throws Error if tenant not found (404) or API unreachable
 */
export async function resolveTenantContext(
  request: APIRequestContext,
  companySlug: string,
  adminToken: string,
): Promise<TenantContext>
```

**Resolution chain:**

```
company_id (e.g. "swiftroute")
  → GET /api/v1/tenants/swiftroute
    (with Authorization: Bearer <admin-token>)
  → Response: { tenant_id, slug, idp_realm_id, ... }
  → TenantContext {
      tenantId: response.tenant_id,
      realm: response.idp_realm_id ?? response.slug,
      slug: response.slug,
      tokenUrl: KEYCLOAK_BASE_URL + '/realms/' + realm + '/protocol/openid-connect/token'
    }
```

**Caching:**
- Module-level `Map<string, TenantContext>` keyed by slug.
- First call for a slug hits the API; subsequent calls return cached value.
- Cache is never invalidated (test process lifetime is short).

**Error handling:**

| Condition | Error message |
|---|---|
| 404 from tenant API | `"Tenant not found: ${companySlug}"` |
| Non-200 from tenant API | `"Tenant lookup failed (${status}): ${body}"` |
| `idp_realm_id` is null | Falls back to slug as realm name |

### 2.3 Existing functions — unchanged

These functions are **not modified** but become usable with tenant-scoped
tokens produced by the functions above:

- `loginWithToken(page, token)` — injects any valid JWT into sessionStorage
- `authHeaders(token)` — returns `{ Authorization: 'Bearer ...', 'x-bpm-user-id': ... }`
- `jwtSubject(token)` — extracts sub from any JWT

---

## 3. Data flow diagram

```
                    Scenario YAML
                    company_id: "swiftroute"
                          │
                          ▼
              ┌─── resolveTenantContext() ───┐
              │                               │
              │  GET /api/v1/tenants/swiftroute│
              │  (with admin token)            │
              │                               │
              │  Response:                     │
              │  { tenant_id: "uuid-...",      │
              │    slug: "swiftroute",          │
              │    idp_realm_id: "swiftroute" } │
              │                               │
              └───────────┬───────────────────┘
                          │
                          ▼
                 TenantContext { tenantId, realm, slug, tokenUrl }
                          │
          ┌───────────────┼───────────────────┐
          ▼               ▼                   ▼
   getKeycloakToken(  getKeycloakToken(   refreshTokenIfNeeded(
     req,                req,                req,
     actor.user,         actor.user,         token,
     actor.pass,         actor.pass,         actor.user,
     ctx.realm           ctx.realm           actor.pass,
   )                     )                    ctx.realm
     │                   │                     │
     ▼                   ▼                     ▼
   JWT for            JWT for               Refreshed JWT
   swiftroute         swiftroute            for swiftroute
   realm              realm                 realm
     │                   │                     │
     ▼                   ▼                     ▼
  loginWithToken()    authHeaders()         authHeaders()
  (for GUI steps)     (for API steps)       (for API steps)
```

---

## 4. Error taxonomy

| Error | Cause | Effect |
|---|---|---|
| `Tenant not found: <slug>` | `GET /api/v1/tenants/:slug` returns 404 | UAT-RUNNER aborts scenario with BLOCKER |
| `Tenant lookup failed (N): <body>` | Non-200 response from tenant API | UAT-RUNNER aborts scenario with BLOCKER |
| `Keycloak token request failed (N): <body>` | Token endpoint returns non-200 (wrong realm, wrong credentials) | UAT-RUNNER aborts step; scenario FAIL |
| `idp_realm_id is null` | Tenant exists but has no Keycloak realm | Falls back to slug as realm name — may fail at token request |

---

## 5. State transitions

No state machine applies. The resolution chain is a single request-response
with caching. The overall UAT execution flow gains one new step:

```
Current:  Load scenarios → Execute → Evaluate → Report
After:    Load scenarios → Resolve tenant context → Execute → Evaluate → Report
```

---

## 6. Dependencies

### Calls (this module uses):

| Dependency | Direction | Notes |
|---|---|---|
| `GET /api/v1/tenants/:slug` | Outbound | Existing endpoint — returns `tenant_id`, `slug`, `idp_realm_id` |
| `KEYCLOAK_BASE_URL` env var | Config | Already used; no change |
| `@playwright/test` (APIRequestContext) | Test infra | Already imported |
| Tenant's Keycloak realm `/protocol/openid-connect/token` | Outbound | Dynamic URL built from resolved realm |

### Must NOT depend on:

| Module | Reason |
|---|---|
| Production source files (`src/`) | Test infrastructure only |
| MSW or any HTTP mocking layer | Per DIRECTIVE T-2 |
| Direct database connections | All data through HTTP API |
| Backend Zig modules | TypeScript test code |

---

## 7. Documentation updates

### 7.1 `docs/agents/UAT_RUNNER.md` — new Step 2.5

Insert a new step between current Step 2 (Load and validate scenarios) and
Step 3 (Execute each scenario):

> **Step 2.5 — Resolve tenant context**
>
> Before executing scenarios, resolve each unique `company_id` to a tenant
> context:
>
> 1. Collect unique `company_id` values from all loaded scenarios.
> 2. For each slug, call `resolveTenantContext(request, slug, adminToken)`.
> 3. Store the resulting `TenantContext` objects for use during execution.
>
> During execution:
> - For `via: gui` steps — `loginWithToken(page, token)` where `token` was
>   obtained via `getKeycloakToken(request, actor.user, actor.pass, ctx.realm)`.
> - For `via: api` steps — `authHeaders(token)` where `token` was obtained
>   the same way.
> - `refreshTokenIfNeeded(request, token, actor.user, actor.pass, ctx.realm)`
>   is used before any API call if the token is near expiry.
>
> **Pre-flight addition:** Verify `GET /api/v1/tenants/<slug>` returns 200
> for each unique company_id. If any returns 404, BLOCKER.

### 7.2 `docs/agents/uat-scenario-schema.md` — company_id note

Add a note to the `company_id` field documentation:

> `company_id` is the **sole tenant identifier** in a scenario. UAT Runner
> resolves it to a Keycloak realm automatically via
> `GET /api/v1/tenants/{company_id}`. No additional fields (realm, token URL)
> are needed in the scenario YAML — the resolution is invisible to the
> scenario author.
>
> The resolution chain is:
> ```
> company_id  →  GET /api/v1/tenants/{company_id}  →  idp_realm_id  →  Keycloak token URL
> ```

---

## 8. Open questions

None. The user's key insight is clear: the slug is the only input, and all
Keycloak machinery is resolved automatically by the system.

---

## 9. Backward compatibility

| Caller | Impact |
|---|---|
| Existing pipeline tests that call `getKeycloakToken(req, user, pass)` | Zero impact — `realm` defaults to `bpm-default` |
| Existing pipeline tests that call `refreshTokenIfNeeded(req, token, user, pass)` | Zero impact — `realm` defaults to `bpm-default` |
| New UAT scenarios with `company_id: swiftroute` | Use `resolveTenantContext()` + realm-aware token calls |
| Existing E2E tests without tenant context | Zero impact — no code change required |

No existing test file needs modification. The changes are purely additive.
