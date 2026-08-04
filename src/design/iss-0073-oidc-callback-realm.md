# ISS-0073 Fix Design: Embed realm slug in OIDC redirect_uri

Covers: OIDC-F-02

## Module Purpose

The OIDC login initiation flow (ProtectedRoute / AuthProvider) must embed the tenant
realm slug as a `?realm=<slug>` query parameter in the `redirect_uri` passed to
`signinRedirect()`. This guarantees that when Keycloak redirects the browser back to
`/auth/callback`, the callback URL contains `?realm=<slug>` and
`resolveRealmFromUrl()` can identify the correct realm independently of `sessionStorage`
state, eliminating the redirect loop described in ISS-0073.

This is a two-part fix (Fix A and Fix B). Fix A is the active change; Fix B confirms
that no additional change is required in `OidcCallbackPage.tsx` given Fix A.

---

## Public Interface

No new exported symbols are introduced. The change is a call-site amendment at two
existing call sites that already hold a `UserManager` instance obtained from
`getOidcManager()`.

**Affected call sites (Fix A):**

```
File: web/src/auth/ProtectedRoute.tsx
Function: anonymous useEffect callback (line ~15)
Current call: void m.signinRedirect()
New call:     void m.signinRedirect(buildRedirectArgs())
```

```
File: web/src/auth/AuthProvider.tsx
Function: auth:session-expired event handler (line ~37)
Current call: void m.signinRedirect()
New call:     void m.signinRedirect(buildRedirectArgs())
```

**Helper function `buildRedirectArgs` (module-local, not exported):**

Signature:
```
function buildRedirectArgs(): { redirect_uri: string } | undefined
```

Behaviour:
- Calls `resolveRealmFromUrl()` (imported from `@/auth/tenantConfig`)
- If the returned slug is non-null: returns `{ redirect_uri: window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug) }`
- If slug is null: returns `undefined` (preserves existing behaviour — UserManager uses its configured `redirect_uri`)

Both call sites (`ProtectedRoute.tsx` and `AuthProvider.tsx`) should define this
helper inline as a local arrow function or as a shared utility in
`web/src/auth/oidcRedirectArgs.ts` if the project desires a single definition.

**Existing symbols exercised by the fix (no signature changes needed):**

| Symbol | File | Role |
|---|---|---|
| `resolveRealmFromUrl()` | `web/src/auth/tenantConfig.ts` | Returns current realm slug from sessionStorage or `?realm=` URL param |
| `getOidcManager()` | `web/src/auth/OidcManager.ts` | Returns async-resolved tenant UserManager |
| `buildOidcSettings()` | `web/src/auth/OidcManager.ts` | Builds UserManager settings; `redirect_uri` field set at line 11 |
| `signinRedirect(args?)` | oidc-client-ts `UserManager` | Accepts optional `{ redirect_uri: string }` override in `args` |

---

## Data Flow

```
User visits protected route (no session)
        │
        ▼
ProtectedRoute.useEffect
  → getOidcManager()           [resolves swiftroute UserManager]
  → resolveRealmFromUrl()      [reads sessionStorage 'bpm_realm_slug' or ?realm= param]
  → slug = "swiftroute"
  → m.signinRedirect({
        redirect_uri: origin + '/auth/callback?realm=swiftroute'
    })
        │
        ▼  (full browser navigation to Keycloak)
Keycloak SwiftRoute login page
        │  user authenticates
        ▼
Keycloak issues auth code, redirects browser to:
  /auth/callback?realm=swiftroute&code=AUTH_CODE&state=PKCE_STATE
        │
        ▼
OidcCallbackPage.useEffect
  → getOidcManager()
      → _resolvedManager is null (fresh page load)
      → fetchTenantConfig(hostname)
          → resolveRealmFromUrl()
              → ?realm=swiftroute  ←──  PRESENT in URL (Fix A guarantees this)
          → GET /api/tenant-config?realm=swiftroute
          → returns swiftroute oidc_authority
      → builds swiftroute UserManager, stores in _resolvedManager
  → m.signinRedirectCallback()
      → reads PKCE state from sessionStorage (stored under swiftroute authority key)
      → exchanges code at swiftroute token endpoint
      → returns User with valid access_token
        │
        ▼
setSession() → navigate('/') → Alice is logged in
```

---

## Fix A — Embed realm in redirect_uri

**Problem:** `buildOidcSettings()` (`OidcManager.ts` line 11) sets
`redirect_uri = window.location.origin + '/auth/callback'` with no realm parameter.
OAuth2 / Keycloak does not forward custom query parameters from the authorization
request through to the redirect. When the browser lands on `/auth/callback`, the URL
has no `?realm=` parameter. `resolveRealmFromUrl()` then reads
`sessionStorage['bpm_realm_slug']`; if that key is absent (e.g. tab was opened fresh
via a direct `/auth/callback` bookmark, or sessionStorage was cleared), it returns
`null`, and `fetchTenantConfig` falls back to `?host=hostname` → bpm-default realm.

**Fix:** At each `signinRedirect()` call site, read `resolveRealmFromUrl()` before
dispatching the redirect. If a slug is available, pass
`{ redirect_uri: window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug) }`
as the argument. This embeds the realm directly in the OAuth2 `redirect_uri` value.
Keycloak will include this exact URI when redirecting back, appending its own
`?code=...&state=...` params to it. The resulting callback URL will be
`/auth/callback?realm=swiftroute&code=...&state=...`.

**Do not change `buildOidcSettings()`:** The `redirect_uri` in `UserManagerSettings`
is the default URI registered with Keycloak. Changing it there would affect all
UserManager instances including the sync `oidcManager` constant and any silent-renew
flows. The override is a per-call argument only.

**Keycloak client registration prerequisite:** The swiftroute Keycloak realm's
`bpm-platform-api` client must have a registered redirect URI that accepts
`/auth/callback?realm=swiftroute`. Keycloak supports a trailing-wildcard pattern:
registering `http://<host>/auth/callback*` covers all `?realm=` variants. This
is an infrastructure configuration requirement, not a code change.

---

## Fix B — OidcCallbackPage callback manager is sufficient

`OidcCallbackPage.tsx` already calls `getOidcManager()` (line 35) which chains into
`fetchTenantConfig → resolveRealmFromUrl`. With Fix A applied, the callback URL will
contain `?realm=swiftroute`. `resolveRealmFromUrl()` reads `?realm=` from the URL at
priority 2 (after sessionStorage, before hostname fallback) and returns `'swiftroute'`.
`fetchTenantConfig` sends `?realm=swiftroute` to the backend and caches the correct
swiftroute config. `_resolvedManager` is then a swiftroute `UserManager`.

**No separate "one-time UserManager" is needed.** The diagnosis report's tertiary
factor (sync `oidcManager` export) is a pre-existing smell but does not block this fix:
`OidcCallbackPage` exclusively uses `getOidcManager()` (the async path) and never
imports the sync `oidcManager` constant.

**PKCE state authority alignment:** `signinRedirect()` is called on the swiftroute
UserManager (resolved by `getOidcManager()` at login-initiation time, when
`?realm=swiftroute` is in the app URL). The stored PKCE state is keyed by the oidc
state token (URL `state=` param), not by authority. `signinRedirectCallback()` finds
the state entry regardless of the manager's authority; it uses the `redirect_uri`
stored inside the state entry (which is `/auth/callback?realm=swiftroute`) when
calling the token endpoint. Both managers (at initiation and at callback) resolve to
swiftroute, so the authority and token endpoint are consistent.

---

## Error Taxonomy

| Error case | Where it occurs | Handling |
|---|---|---|
| `resolveRealmFromUrl()` returns null at login-initiation time | ProtectedRoute / AuthProvider | `buildRedirectArgs()` returns `undefined`; `signinRedirect()` uses default `redirect_uri` (no realm param). Callback falls back to sessionStorage or bpm-default. Behaviour is unchanged from today. |
| Keycloak rejects `redirect_uri` with `?realm=<slug>` (not registered) | Keycloak login page | Keycloak returns error page; user sees error. Fix: register wildcard redirect URI in Keycloak client config. |
| `encodeURIComponent(slug)` on an untrusted value | `buildRedirectArgs()` | `encodeURIComponent` encodes all URI-reserved characters; malicious slugs cannot inject additional query parameters or fragment identifiers. |
| `fetchTenantConfig` cache already populated with bpm-default from a previous page load in the same session | OidcCallbackPage | Not possible: each full-page navigation (Keycloak redirect) re-imports all modules, resetting `_cachedConfig = null` and `_resolvedManager = null`. Module-level state does not survive cross-page navigation in the browser. |

---

## Dependencies

| Dependency | Direction | Notes |
|---|---|---|
| `resolveRealmFromUrl()` from `tenantConfig.ts` | consumed by ProtectedRoute, AuthProvider | Already exported; no signature change |
| `signinRedirect(args?)` from oidc-client-ts | consumed by call sites | `SigninRedirectArgs.redirect_uri` is part of the stable oidc-client-ts API |
| Keycloak client registration | external config | Wildcard redirect URI `http://<host>/auth/callback*` must be registered |
| `fetchTenantConfig` cache reset on navigation | runtime property | Module-level variables reset on full-page load — guaranteed by browser module re-evaluation |

This module must not depend on: backend code, Zig modules, migration files, or any
other auth sub-modules beyond `tenantConfig.ts` and `OidcManager.ts`.

---

## Open Questions

None. Diagnosis is confirmed. Fix approach is fully determined.
