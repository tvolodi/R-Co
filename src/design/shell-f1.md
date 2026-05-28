# Design Artefact — Stage F1: Application Shell & Authentication

**Module:** `shell-f1`  
**Requirements:** SH-01, SH-02, SH-03, SH-04  
**Produced by:** CODE-DESIGNER  
**Run:** WF02-shf1a-20260528  
**Status:** FINAL

---

## 1. Module Purpose

The Application Shell & Authentication layer is the foundational UI module that all other views build upon. It owns three responsibilities:

1. **Token-based authentication** — a login screen that accepts a bearer token, validates it against the backend, and decodes user identity from the JWT payload.
2. **In-memory session management** — stores the active token as a module-level variable (never in localStorage or sessionStorage per FNFR-06); clears on page reload; redirects to login on expiry.
3. **Role-aware navigation shell** — renders the persistent sidebar showing only the navigation items the current user's role set permits, plus an active user indicator with logout.

This module does not contain any business logic. It delegates all data to the platform REST API.

---

## 2. Files Affected

| File | Action |
|---|---|
| `web/src/api/client.ts` | Replace localStorage token storage with module-level variables |
| `web/src/auth/AuthContext.tsx` | Replace `AuthContextValue` interface; add `UserSession` type |
| `web/src/auth/AuthProvider.tsx` | Replace `login(email, password)` with `login(token)` + health check + JWT decode |
| `web/src/pages/LoginPage.tsx` | Replace email/password fields with single token input |
| `web/src/components/layout/AppShell.tsx` | Replace `adminOnly` guard with full role-to-nav matrix |
| `web/src/types/api.ts` | Add `UserSession`, `JwtPayload` types |

---

## 3. New / Updated Types

### 3.1 `JwtPayload`

The decoded payload of a BPM Platform API token. Located in `web/src/types/api.ts`.

```typescript
// Design interface — no implementation
export interface JwtPayload {
  sub: string                  // user UUID (may be used for future /me fetch)
  display_name?: string        // preferred display name
  name?: string                // fallback display name
  preferred_username?: string  // second fallback
  roles: string[]              // PLATFORM_ADMIN | PROCESS_DESIGNER | PROCESS_OPERATOR | TASK_WORKER
  exp?: number                 // expiry epoch (seconds)
  iat?: number                 // issued-at epoch (seconds)
  iss?: string                 // issuer
}
```

### 3.2 `UserSession`

Represents the active in-memory session state. Located in `web/src/types/api.ts`.

```typescript
// Design interface — no implementation
export interface UserSession {
  token: string           // raw JWT string — kept here for Authorization header injection
  display_name: string    // resolved from JwtPayload (display_name ?? name ?? preferred_username ?? sub)
  roles: string[]         // normalised copy of JwtPayload.roles
}
```

### 3.3 Updated `AuthContextValue`

Located in `web/src/auth/AuthContext.tsx`.

```typescript
// Design interface — no implementation
export interface AuthContextValue {
  session: UserSession | null   // null = not authenticated
  isAuthenticated: boolean      // derived: session !== null
  isLoading: boolean            // true only during session restore on mount
  login: (token: string) => Promise<void>   // CHANGED: was (email, password)
  logout: () => void                        // CHANGED: synchronous (no API call needed)
}
```

**Removed from interface:** `user` (replaced by `session`), `refreshUser` (no refresh endpoint in token flow).

---

## 4. Public Function Signatures

### 4.1 `decodeTokenPayload`

Located in `web/src/auth/tokenUtils.ts` (new file).

```typescript
// Design signature — no implementation
export function decodeTokenPayload(token: string): JwtPayload | null
```

**Algorithm:**
1. Split token on `.`
2. Guard: must have exactly 3 segments (header.payload.signature)
3. Take segment `[1]` (payload)
4. Pad base64 string to a multiple of 4 (`=` padding) — required for `atob`
5. `atob(paddedSegment)` → JSON string
6. `JSON.parse(...)` → object
7. Return as `JwtPayload` or null on any thrown exception
8. Log no output — silently return null on decode failure

**Error propagation:** Never throws. Returns `null` for all failure cases (see §8 error taxonomy).

### 4.2 `resolveDisplayName`

Located in `web/src/auth/tokenUtils.ts`.

```typescript
// Design signature — no implementation
export function resolveDisplayName(payload: JwtPayload): string
```

**Resolution order:** `payload.display_name` → `payload.name` → `payload.preferred_username` → `payload.sub` → `"Unknown User"`.

### 4.3 Updated `client.ts` token storage — module-level variables

Replace the current `localStorage`-backed functions with module-level variables.

```typescript
// Design — module-level state (no localStorage, no sessionStorage)
let _token: string | null = null

export function getToken(): string | null   // returns _token
export function setToken(token: string): void   // sets _token = token
export function clearToken(): void              // sets _token = null
```

**Removed functions:** `getRefreshToken`, `setRefreshToken`, `clearRefreshToken` — no refresh token in the token-based login flow.

### 4.4 `AuthProvider.login(token: string): Promise<void>`

Located in `web/src/auth/AuthProvider.tsx`.

```typescript
// Design signature — no implementation
login: (token: string) => Promise<void>
```

**Procedure:**
1. Call `GET /health/ready` with `Authorization: Bearer <token>`
2. If response is not 200: throw `ApiError` with `status = response.status`
3. If 200: call `decodeTokenPayload(token)` → `payload`
4. If `payload === null`: throw `ApiError` with status 400, code `TOKEN_DECODE_INVALID`
5. If `payload.roles` is absent or empty array: throw `ApiError` with code `TOKEN_MISSING_ROLES`
6. Call `setToken(token)` (in-memory via client.ts)
7. Set `session` state: `{ token, display_name: resolveDisplayName(payload), roles: payload.roles }`

### 4.5 `AuthProvider.logout(): void`

```typescript
// Design signature — no implementation
logout: () => void
```

**Procedure:**
1. Call `clearToken()` (clears in-memory variable)
2. Set `session` state to `null`
3. Navigate to `/login`

No API call required — the token is discarded client-side. The token remains valid server-side until expiry (acceptable for the platform's security model).

### 4.6 `LoginPage`

```typescript
// Design interface — no implementation
export default function LoginPage(): JSX.Element
```

Props: none (reads from `useAuth()` and `useNavigate()`).

Rendered elements:
- `data-testid="page-login"` wrapper
- `data-testid="login-form"` form with `onSubmit`
- `data-testid="login-token-input"` — `<input type="password">` for token entry (password type prevents browser autofill leaking)
- `data-testid="login-submit"` — submit button, disabled while `submitting === true`
- `data-testid="login-error"` — conditionally rendered error alert (role `alert`)
- Session-expired message: when `new URLSearchParams(location.search).get('reason') === 'session-expired'`, render `data-testid="login-session-expired"` with text "Your session has expired. Please log in again."

### 4.7 `AppShell`

```typescript
// Design interface — no implementation
export function AppShell(): JSX.Element
```

Props: none (reads from `useAuth()` and `useNavigate()`).

---

## 5. NAV_ITEMS Definition and Role-to-Nav Matrix

Located in `web/src/components/layout/AppShell.tsx`.

```typescript
// Design constant shape — no implementation
interface NavItem {
  to: string
  label: string
  roles: Role[]   // visible if session.roles has ANY of these
}

type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER'

const NAV_ITEMS: NavItem[] = [
  { to: '/instances',     label: 'Instances',   roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER', 'PROCESS_OPERATOR'] },
  { to: '/tasks',         label: 'My Tasks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR', 'TASK_WORKER'] },
  { to: '/definitions',  label: 'Definitions', roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER'] },
  { to: '/dlq',           label: 'DLQ',         roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/webhooks',      label: 'Webhooks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/admin/users',   label: 'Users',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/groups',  label: 'Groups',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/tokens',  label: 'Tokens',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/audit',   label: 'Audit',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/health',  label: 'Health',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/metrics', label: 'Metrics',     roles: ['PLATFORM_ADMIN'] },
]
```

### Role-to-nav summary matrix

| Nav item | PLATFORM_ADMIN | PROCESS_DESIGNER | PROCESS_OPERATOR | TASK_WORKER |
|---|:---:|:---:|:---:|:---:|
| Instances | ✅ | ✅ | ✅ | ❌ |
| My Tasks | ✅ | ❌ | ✅ | ✅ |
| Definitions | ✅ | ✅ | ❌ | ❌ |
| DLQ | ✅ | ❌ | ✅ | ❌ |
| Webhooks | ✅ | ❌ | ✅ | ❌ |
| Users | ✅ | ❌ | ❌ | ❌ |
| Groups | ✅ | ❌ | ❌ | ❌ |
| Tokens | ✅ | ❌ | ❌ | ❌ |
| Audit | ✅ | ❌ | ❌ | ❌ |
| Health | ✅ | ❌ | ❌ | ❌ |
| Metrics | ✅ | ❌ | ❌ | ❌ |

**Filtering rule:** An item is rendered if and only if `item.roles.some(r => session.roles.includes(r))`. Items for unpermitted areas are **not rendered** — no disabled state, no hidden-but-present DOM nodes.

**Multiple roles:** A user holding `['PROCESS_DESIGNER', 'PROCESS_OPERATOR']` sees the union of both columns (Instances, My Tasks, Definitions, DLQ, Webhooks).

---

## 6. Data Flow Diagram

```
[LoginPage]
    │
    │ handleSubmit(token)
    ▼
[AuthProvider.login(token)]
    │
    ├─── GET /health/ready  ─────────────────────────────┐
    │    Authorization: Bearer <token>                   │
    │                                                    │
    │    200 OK ──────────────────────────────────┐      │
    │    non-200 ─ throw ApiError ────────────────┼──────┘
    │                               (LoginPage    │
    │                                shows error) │
    ▼                                             │
[decodeTokenPayload(token)]                       │
    │                                             │
    │    valid JwtPayload ─────────────────────── ┘
    │    null ─ throw ApiError(TOKEN_DECODE_INVALID)
    │
    ▼
[setToken(token)]          ← module-level var in client.ts
[setSession({ token,
              display_name,
              roles })]     ← React state in AuthProvider
    │
    ▼
[navigate(from || '/')]
    │
    ▼
[AppShell]
    ├─── Sidebar: NAV_ITEMS filtered by session.roles
    ├─── Header:  session.display_name + session.roles
    └─── Logout button ──► clearToken() + setSession(null)
                        ──► navigate('/login')

─────────────────────────────────────────────────────────
Session expiry path (any API call → 401):
    client.ts dispatches window event 'auth:session-expired'
    AuthProvider listener:
        clearToken()
        setSession(null)
        navigate('/login?reason=session-expired')
    LoginPage: reads URLSearchParams, shows expiry banner
```

---

## 7. Session Persistence Design (SH-02)

**Storage mechanism:** Token is stored in a module-level JavaScript variable in `client.ts`:

```typescript
// module-level — design only, not implementation
let _token: string | null = null
```

This is the sole location of the token. It is never written to localStorage, sessionStorage, or a cookie.

**Behaviour on page reload:** On page reload the JavaScript module is reset, so `_token` is `null`. `ProtectedRoute` reads `session` from `AuthContext` (which derives from `_token`); when `session === null` it redirects to `/login?reason=session-expired`. `LoginPage` reads `new URLSearchParams(location.search).get('reason')` and, when the value is `'session-expired'`, renders the `data-testid="login-session-expired"` banner with text "Your session has expired. Please log in again."

**Session-expired redirect (401 during active session):** When any API request receives 401 (not an auth endpoint), `client.ts` dispatches `window.dispatchEvent(new CustomEvent('auth:session-expired'))`. `AuthProvider` listens for this event and calls `clearToken()`, sets `session` to `null`, then calls `navigate('/login?reason=session-expired')`. `LoginPage` shows the expiry banner via the same URLSearchParams check above.

**Removed: refresh token flow.** The current `AuthProvider` has a refresh token cycle via `/api/v1/auth/refresh`. This is removed in the new design:
- No `getRefreshToken` / `setRefreshToken` / `clearRefreshToken` functions
- No `refreshAccessToken()` function in `client.ts`
- The 401 handler in `client.ts` goes directly to session-expired dispatch, no retry
- `refreshUser` removed from `AuthContextValue`

**Rationale:** The platform uses long-lived API tokens in development/staging. A refresh cycle would require a backend refresh endpoint that does not exist in the current API surface (API-08 is login only). If token rotation is needed in a future stage, it can be re-introduced alongside the backend endpoint.

---

## 8. Error Taxonomy

| Error code | Trigger | User-facing message |
|---|---|---|
| `LOGIN_TOKEN_EMPTY` | Submit with empty token field | "Please enter an API token." |
| `LOGIN_HEALTH_CHECK_FAILED` | `GET /health/ready` returns non-200 (e.g. 401, 403) | "Invalid token or access denied." |
| `LOGIN_SERVER_UNAVAILABLE` | Network error during health check | "Cannot reach the server. Check your connection." |
| `TOKEN_DECODE_INVALID` | `atob` throws or `JSON.parse` throws on JWT payload | "Token format is invalid." |
| `TOKEN_MISSING_ROLES` | Decoded payload has no `roles` field or empty array | "Token does not contain role assignments. Contact your administrator." |
| `SESSION_EXPIRED` | `auth:session-expired` event from `client.ts` | "Your session has expired. Please log in again." (rendered as `data-testid="login-session-expired"`) |

**Display:** All login-page errors render inside `data-testid="login-error"` with `role="alert"`. Session-expired renders as a separate `data-testid="login-session-expired"` banner above the form.

---

## 9. SH-04 Active User Indicator

Located in the footer area of the `AppShell` sidebar.

**Rendered elements:**
- `data-testid="user-display-name"` — renders `session.display_name`
- `data-testid="user-roles"` — renders `session.roles.join(', ')` (comma-separated role list)
- `data-testid="logout-button"` — calls `logout()` on click; no confirmation dialog needed

**Note:** The current `AppShell` renders `user?.email`. In the new design, `email` is not available (not present in the token payload by default). The header renders `display_name` instead.

---

## 10. Security Notes

1. **No localStorage / sessionStorage (FNFR-06).** The token is held exclusively in a module-level JavaScript variable. It is not written to any Web Storage API or cookie. A page reload erases it.

2. **Token input field type is `password`.** This prevents browser autofill managers from pre-filling the field with credentials from other sites and prevents shoulder surfing.

3. **`atob` decode is for display only.** The decoded JWT payload provides `display_name` and `roles` for rendering purposes only. All authorization decisions are made server-side. The client must never trust its own role display for security enforcement.

---

## 11. Open Constraints

### OC-01 — SH-02 vs FNFR-06 Persistence Conflict

**Conflict:**

SH-02 (MUST) states: _"SHALL persist across page reloads (stored in httpOnly cookie or in-memory with a silent re-auth flow)."_

FNFR-06 (MUST) states: _"token MUST NOT be stored in localStorage or sessionStorage."_

These two requirements can only be simultaneously satisfied via one of:
- **(a)** httpOnly cookie managed by the backend, or
- **(b)** an in-memory token combined with a silent re-auth flow (i.e. a refresh-token endpoint)

**Chosen resolution (this stage):** In-memory only — FNFR-06 compliant, SH-02 partially satisfied.

| Requirement | Satisfied? | Notes |
|---|:---:|---|
| FNFR-06: no localStorage/sessionStorage | ✅ | Token in module-level variable only |
| SH-02: cross-reload persistence | ⚠️ Partial | In-memory portion implemented; persistence across reload deferred |

**Why full SH-02 compliance is deferred:**

1. **httpOnly cookie path** requires a backend `/api/v1/auth/set-cookie` endpoint that sets a `Secure; HttpOnly; SameSite=Strict` cookie. This endpoint does not exist in the current API surface.
2. **Silent re-auth flow path** requires a backend refresh-token endpoint (e.g. `/api/v1/auth/refresh`). API-08 covers only direct token login; no refresh endpoint exists.

**User experience consequence:** After a page reload or browser close, `_token` resets to `null`. `ProtectedRoute` redirects to `/login?reason=session-expired`. The user must re-enter their API token. This is the documented, expected behaviour for this stage.

**Resolution path (future stage):** Implement either (a) backend httpOnly-cookie endpoint, or (b) a refresh endpoint and silent re-auth cycle. Either path requires a new CODE-DESIGNER artefact before implementation.

**Open question for REQ-ANALYST (OQ-SHF1-01):** Which persistence mechanism (httpOnly cookie vs refresh token) is preferred for the next stage? Resolution affects both backend and frontend scope.

4. **No token logging.** `decodeTokenPayload` and `resolveDisplayName` must not write the token or its contents to `console.log`, `console.error`, or any telemetry sink.

5. **`Authorization` header injection.** `client.ts` injects `Authorization: Bearer <token>` on every non-auth request using the module-level `getToken()` function. This is already the existing behaviour and requires no change beyond the storage backend switch.

6. **Session-expired dispatch.** The `auth:session-expired` event is dispatched by `client.ts` on 401 responses. This ensures a single, centralised path for session termination — no component needs its own 401 handler.

---

## 11. Dependencies

| Dependency | Direction | Notes |
|---|---|---|
| `GET /health/ready` | Outbound — backend health API | Used for token validation on login; also polled by SH-06 (connectivity banner) |
| `react-router-dom` | External library | `useNavigate`, `useLocation`, `NavLink`, `Outlet` |
| `web/src/api/client.ts` | Internal | Token storage; `request()` wrapper used by all API calls |
| `web/src/types/api.ts` | Internal | `UserSession`, `JwtPayload`, `ApiError` type definitions |

**Must NOT depend on:**
- Any backend endpoint other than `GET /health/ready` during the login flow
- Any Zig backend module (this is a pure frontend module)
- `localStorage` or `sessionStorage`

---

## 12. Open Questions

None — all requirements are sufficiently specified for implementation.

---

## 13. Acceptance Criteria Traceability

| Acceptance criterion | Covered by |
|---|---|
| SH-01: Token input field, health check validation | §4.4 login procedure, §4.6 LoginPage |
| SH-01: JWT decode for roles + display_name | §4.1 decodeTokenPayload, §4.2 resolveDisplayName |
| SH-01: Error on non-200 | §8 error taxonomy `LOGIN_HEALTH_CHECK_FAILED` |
| SH-02: In-memory storage only | §4.3 client.ts, §7 session persistence design |
| SH-02: Session-expired redirect | §6 data flow, §8 `SESSION_EXPIRED` |
| SH-03: Role-filtered nav (hidden, not disabled) | §5 NAV_ITEMS + role matrix |
| SH-04: display_name + roles in header | §9 active user indicator |
| SH-04: Logout clears session | §4.5 logout signature |
