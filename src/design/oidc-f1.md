# Design Artefact — Stage F1.5: OIDC SSO Login

**Module:** `oidc-f1`  
**Requirements:** OIDC-F-01, OIDC-F-02, OIDC-F-03, OIDC-F-04  
**Produced by:** CODE-DESIGNER  
**Run:** WF02-oidcf-20260528  
**Status:** FINAL

---

## 1. Module Purpose

This module extends the existing token-based authentication (Stage F1) to support OIDC authorization code flow via Keycloak. Users gain a "Sign in with Keycloak" button on the login page. Internally, `oidc-client-ts` handles the PKCE flow and token exchange. The resulting access token is stored in memory via the existing `setToken()` API — no new storage path is introduced.

Four existing files are modified; two new files are added. The existing token-paste path is entirely preserved.

---

## 2. New Dependency

| Package | Version | Purpose |
|---|---|---|
| `oidc-client-ts` | `^3.1.0` | PKCE authorization code flow, token exchange, silent renew via hidden iframe, end-session endpoint |

Install command (implementor runs): `npm install oidc-client-ts` inside `web/`.

`oidc-client-ts` is a TypeScript-first OIDC/OAuth2 client with built-in support for in-memory storage, silent renew iframes, and end-session endpoints. No additional type packages are needed.

---

## 3. New Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `VITE_OIDC_AUTHORITY` | `http://localhost:8081/realms/bpm-default` | Full OIDC provider base URL (Keycloak realm URL). `oidc-client-ts` appends `/.well-known/openid-configuration` to discover endpoints. |
| `VITE_OIDC_CLIENT_ID` | `bpm-platform-api` | OIDC client ID registered in Keycloak. |

Both variables are read at module initialisation time in `OidcManager.ts`. If absent, defaults are used so the dev environment requires no extra configuration.

---

## 4. New File: `web/src/auth/OidcManager.ts`

### 4.1 Purpose

Singleton wrapper around `oidc-client-ts`'s `UserManager`. Owns all OIDC configuration; nothing else in the app imports `UserManager` directly.

### 4.2 UserManager Configuration

| Field | Value | Notes |
|---|---|---|
| `authority` | `VITE_OIDC_AUTHORITY` env var | Keycloak realm URL |
| `client_id` | `VITE_OIDC_CLIENT_ID` env var | Public client (no secret) |
| `redirect_uri` | `window.location.origin + '/auth/callback'` | Resolved at runtime to support any deployment base URL |
| `response_type` | `'code'` | Authorization code with PKCE (enforced by `oidc-client-ts` for public clients) |
| `scope` | `'openid profile'` | Requests `sub`, `name`, `preferred_username`; roles arrive in access token claims |
| `userStore` | `new InMemoryWebStorage()` | **Required by FNFR-06 and OIDC-F-02** — see §4.3 |
| `automaticSilentRenew` | `false` | Silent renew is started explicitly (§4.5) to allow AuthProvider to hook into the event before starting |

### 4.3 Why `InMemoryWebStorage` Is Required

FNFR-06 prohibits storing any session material in `localStorage` or `sessionStorage`. By default, `oidc-client-ts` persists the `User` object (containing the ID token, refresh token, and PKCE code verifier) in `sessionStorage`. Passing `userStore: new InMemoryWebStorage()` redirects all internal storage to a plain in-memory Map, satisfying FNFR-06 and OIDC-F-02.

Consequence: the OIDC session does not survive a page reload — consistent with the existing token-based session behaviour.

### 4.4 Public Functions

```typescript
// Design signatures — no implementation

/**
 * Initiates the OIDC authorization code flow.
 * Calls UserManager.signinRedirect(). Browser navigates away to Keycloak.
 * Returns a promise that resolves before redirect (used only for test hooks).
 */
signinRedirect(): Promise<void>

/**
 * Completes the OIDC flow on the /auth/callback page.
 * Calls UserManager.signinRedirectCallback().
 * Returns the oidc-client-ts User object containing access_token, profile, etc.
 */
signinRedirectCallback(): Promise<User>

/**
 * Initiates Keycloak end-session (OIDC logout).
 * Calls UserManager.signoutRedirect().
 * Browser navigates to Keycloak end-session endpoint, then back to post_logout_redirect_uri.
 * Used only when loginSource === 'oidc' (OIDC-F-04).
 */
signoutRedirect(): Promise<void>

/**
 * Starts the automatic silent renew loop.
 * Registers the 'userLoaded' event on UserManager to receive renewed tokens.
 * Called once by AuthProvider after a successful OIDC login.
 * The caller provides an onRenew callback to update the in-memory token.
 */
startSilentRenew(onRenew: (newToken: string) => void): void
```

### 4.5 Silent Renew Design (OIDC-F-03)

`startSilentRenew` sets `automaticSilentRenew = true` on the underlying `UserManager` and subscribes to `userManager.events.addUserLoaded`. When the event fires (new token available), it extracts `user.access_token` and calls the provided `onRenew` callback, which forwards it to `setToken()`. If silent renew fails (`addSilentRenewError` event), it dispatches `auth:session-expired` so the existing SH-02 flow takes over.

---

## 5. New File: `web/src/pages/OidcCallbackPage.tsx`

### 5.1 Purpose

Renders a transient loading screen while the OIDC callback is processed. No user interaction is required.

### 5.2 Props

```typescript
// Design interface — no implementation
// No props — OidcCallbackPage is rendered as a standalone route element.
```

### 5.3 Mount Behaviour (sequential steps)

1. Call `OidcManager.signinRedirectCallback()` to exchange the authorization code.
2. Extract `user.access_token` from the returned `User` object.
3. Decode the JWT payload with the existing `decodeTokenPayload()` utility.
4. Validate: `payload !== null` AND `payload.roles.length > 0`. On failure → go to step 7.
5. Call `setToken(user.access_token)` (in-memory token store).
6. Call `setSession({ token, display_name, roles, loginSource: 'oidc' })` via `AuthContext`.
7. On any error (invalid state, expired code, decode failure, missing roles): `window.location.replace('/login?reason=auth-error')`.
8. On success: `navigate('/', { replace: true })`.

### 5.4 `data-testid` Attributes

| Element | `data-testid` |
|---|---|
| Loading container | `page-oidc-callback` |
| Loading message span | `oidc-callback-status` |

### 5.5 Error Mapping

| Condition | Redirect target |
|---|---|
| `signinRedirectCallback()` throws | `/login?reason=auth-error` |
| `decodeTokenPayload()` returns `null` | `/login?reason=auth-error` |
| `payload.roles` is empty | `/login?reason=auth-error` |

---

## 6. Modified File: `web/src/types/api.ts`

### 6.1 `UserSession` — add `loginSource` field

```typescript
// Design interface — no implementation
export interface UserSession {
  token: string
  display_name: string
  roles: string[]
  loginSource: 'token' | 'oidc' | null   // NEW — tracks how the session was established
}
```

`loginSource: null` is the initial/empty-session value. `'token'` is set by the existing `login(token)` path. `'oidc'` is set by `OidcCallbackPage` via `setSession`.

---

## 7. Modified File: `web/src/auth/AuthContext.tsx`

### 7.1 Updated `AuthContextValue`

```typescript
// Design interface — no implementation
export interface AuthContextValue {
  session: UserSession | null
  isAuthenticated: boolean
  isLoading: boolean
  login: (token: string) => Promise<void>       // existing — unchanged
  logout: () => void                             // existing — OIDC-aware (see §8)
  setSession: (s: UserSession) => void           // NEW — called by OidcCallbackPage
}
```

`setSession` is added to allow `OidcCallbackPage` to populate the session directly (bypassing the health-check login path). It is not intended for general use.

---

## 8. Modified File: `web/src/auth/AuthProvider.tsx`

### 8.1 OIDC-aware `logout`

The existing `logout` function is modified to branch on `session.loginSource`:

```
if session.loginSource === 'oidc':
    clearToken()
    setSession(null)
    OidcManager.signoutRedirect()   // navigates to Keycloak end-session; no navigate() call needed
else:
    existing path: clearToken() + setSession(null) + navigate('/login')
```

### 8.2 Silent Renew Integration (OIDC-F-03)

`AuthProvider` calls `OidcManager.startSilentRenew(newToken => setToken(newToken))` after `setSession` is called with `loginSource === 'oidc'`. This is triggered via a `useEffect` that watches `session?.loginSource`.

### 8.3 `setSession` Implementation Guidance

`setSession` is a direct wrapper around the React `setSession` state setter:

```
setSession: (s: UserSession) => void
  → calls the internal React setState with the new session object
```

No validation logic is placed in `setSession`; that belongs in `OidcCallbackPage`.

### 8.4 Updated `AuthContextValue` Exposure

`setSession` is exposed on the context value so `OidcCallbackPage` can reach it via `useAuth()`.

---

## 9. Modified File: `web/src/pages/LoginPage.tsx`

### 9.1 Changes

- Add a "Sign in with Keycloak" `<button>` element below the existing form.
- On click: call `OidcManager.signinRedirect()`. No async handling is needed in the component — the browser will navigate away.
- Existing token paste form is **completely unchanged**.

### 9.2 New Element

```typescript
// Design interface — no implementation

// Props for the new SSO button (no separate component; inline in LoginPage)
interface SsoButtonProps {
  onClick: () => void
  disabled?: boolean   // disabled while OidcManager.signinRedirect() is in-flight
}
```

### 9.3 `data-testid` Attributes

| Element | `data-testid` |
|---|---|
| SSO button | `login-sso-button` |
| Auth error banner | `login-auth-error` |

### 9.4 `?reason=auth-error` Handling

When `location.search` contains `reason=auth-error`, `LoginPage` renders an error banner (similar to the existing `login-session-expired` banner):

> "Authentication failed. Please try again or use an API token."

---

## 10. Modified File: `web/src/router.tsx`

### 10.1 New Route

Add a top-level route for `/auth/callback` **before** the `/` route, wrapped in `AuthProvider` but **without** `ProtectedRoute`:

```typescript
// Design route entry — no implementation
{
  path: '/auth/callback',
  element: (
    <AuthProvider>
      <OidcCallbackPage />
    </AuthProvider>
  ),
}
```

`ProtectedRoute` must not wrap `OidcCallbackPage` because at the time the callback is processed, the user is not yet authenticated.

---

## 11. Complete Files Affected

| File | Action | Public Interfaces Changed |
|---|---|---|
| `web/src/auth/OidcManager.ts` | **NEW** | `signinRedirect()`, `signinRedirectCallback()`, `signoutRedirect()`, `startSilentRenew(onRenew)` |
| `web/src/pages/OidcCallbackPage.tsx` | **NEW** | No props; `data-testid="page-oidc-callback"` |
| `web/src/types/api.ts` | **MODIFY** | `UserSession` gains `loginSource: 'token' \| 'oidc' \| null` |
| `web/src/auth/AuthContext.tsx` | **MODIFY** | `AuthContextValue` gains `setSession(s: UserSession): void` |
| `web/src/auth/AuthProvider.tsx` | **MODIFY** | `logout` OIDC-aware; `setSession` exposed; silent renew wired |
| `web/src/pages/LoginPage.tsx` | **MODIFY** | SSO button added; `?reason=auth-error` banner added |
| `web/src/router.tsx` | **MODIFY** | `/auth/callback` route added (no ProtectedRoute) |

---

## 12. Requirements Coverage

| Requirement | Priority | Covered By |
|---|---|---|
| OIDC-F-01: SSO login button | MUST | §9 — LoginPage SSO button + OidcManager.signinRedirect() |
| OIDC-F-02: OIDC callback handler + InMemoryWebStorage | MUST | §5 — OidcCallbackPage; §4.2–4.3 — UserManager config |
| OIDC-F-03: Silent token renewal | SHOULD | §4.5 — startSilentRenew; §8.2 — AuthProvider wiring |
| OIDC-F-04: OIDC logout | SHOULD | §8.1 — OIDC-aware logout branch |

---

## 13. Open Constraints (Deferred to Implementor)

1. **`post_logout_redirect_uri`**: The URL Keycloak redirects to after end-session is not specified in requirements. Implementor should use `window.location.origin + '/login'` as a safe default and register it in the Keycloak client settings.

2. **Silent renew iframe URL**: `oidc-client-ts` requires a `silent_redirect_uri` for iframe-based silent renew. Implementor should set this to `window.location.origin + '/auth/silent-renew'` and add a minimal HTML file at `web/public/auth/silent-renew.html` that runs the silent renew callback. This file is outside the React router and does not need a route entry.

3. **`VITE_OIDC_AUTHORITY` trailing slash**: Keycloak realm URLs must not have a trailing slash or `oidc-client-ts` will double-slash the discovery URL. The implementor should strip any trailing slash when reading the env var.

4. **Role claim location**: Keycloak by default places realm roles in `realm_access.roles`, not a top-level `roles` array. The implementor must verify how the BPM Platform token mapper is configured and whether `decodeTokenPayload()` needs updating. If the mapper is already producing a top-level `roles` claim (as used by the existing token-paste login), no change to `tokenUtils.ts` is needed.

5. **`automaticSilentRenew` timing**: The `UserManager` `accessTokenExpiringNotificationTimeInSeconds` default is 60 seconds. The implementor may need to tune this based on the Keycloak token TTL configured for the realm.

6. **`setSession` vs `login` for `loginSource: 'token'`**: The existing `login(token)` path in `AuthProvider` must be updated to set `loginSource: 'token'` on the session it creates, to keep the union exhaustive and ensure OIDC-aware logout branches correctly.
