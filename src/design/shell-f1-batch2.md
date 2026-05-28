# Design Artefact — Stage F1 Batch 2: Global Error Boundary & API Connectivity Banner

**Module:** `shell-f1-batch2`  
**Requirements:** SH-05, SH-06  
**Produced by:** CODE-DESIGNER  
**Run:** WF02-shf1b-20260528  
**Status:** FINAL

---

## 1. Overview

This batch extends the Application Shell (SH-01 through SH-04, implemented in WF02-shf1a) with two resilience features:

- **SH-05 — Global Error Boundary:** A React class component wrapping the authenticated view tree. Any unhandled JavaScript render error (thrown during React's render, lifecycle, or Suspense boundary resolution) is caught here and replaced with a recoverable error panel. The user never sees a blank screen; the panel provides a "Try again" button that resets the error state and attempts to re-render the subtree.

- **SH-06 — API Connectivity Banner:** A polling-based connectivity indicator that periodically calls `GET /health/ready`. When the backend is unreachable (network failure or non-2xx response), a non-blocking sticky banner is shown at the top of the shell content area. The banner is purely informational — it does not block navigation or prevent UI interaction. It dismisses automatically when connectivity is restored.

Neither component owns business logic. Both are pure shell-level concerns and depend on no page-level state.

---

## 2. Component Inventory

| Component / Hook | File | New or Modified |
|---|---|---|
| `ErrorBoundary` | `web/src/components/layout/ErrorBoundary.tsx` | **New** |
| `ApiConnectivityBanner` | `web/src/components/layout/ApiConnectivityBanner.tsx` | **New** |
| `useApiConnectivity` | `web/src/hooks/useApiConnectivity.ts` | **New** |
| `router.tsx` | `web/src/router.tsx` | **Modified** — wrap `<AppShell />` in `<ErrorBoundary>` |
| `AppShell.tsx` | `web/src/components/layout/AppShell.tsx` | **Modified** — render `<ApiConnectivityBanner />` above `<Outlet />` |
| `health.ts` | `web/src/api/health.ts` | **Modified** — add `healthReady()` raw-fetch function |

---

## 3. SH-05: ErrorBoundary

### 3.1 Rationale for class component

React 18 does not provide a hook equivalent for `componentDidCatch` / `getDerivedStateFromError`. Error boundaries must be implemented as class components. This is a React platform constraint, not a design preference.

### 3.2 State interface

```typescript
// Design — no implementation
interface ErrorBoundaryState {
  hasError: boolean
  error: Error | null
}
```

### 3.3 Props interface

```typescript
// Design — no implementation
interface ErrorBoundaryProps {
  children: React.ReactNode
  /**
   * Optional: render a custom fallback instead of the default panel.
   * Receives the caught error and a reset callback.
   */
  fallback?: (error: Error, reset: () => void) => React.ReactNode
}
```

### 3.4 Class interface

```typescript
// Design — no implementation
class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  // Static lifecycle: sets hasError = true on any render error in the subtree
  static getDerivedStateFromError(error: Error): ErrorBoundaryState

  // Instance lifecycle: receives error + React component stack
  // Does NOT call any API — logging only via console.error in dev
  componentDidCatch(error: Error, info: React.ErrorInfo): void

  // Resets state to { hasError: false, error: null }
  // Called by the "Try again" button and exposed to custom fallback via prop
  handleReset(): void

  render(): React.ReactNode
}
```

### 3.5 Default fallback UI specification

When `hasError === true` and no `fallback` prop is provided, render:

```
┌─────────────────────────────────────────────────────────────┐
│  [!] Something went wrong                                    │
│                                                              │
│  An unexpected error occurred in this view.                  │
│  Your session and other tabs are not affected.               │
│                                                              │
│  Error details (collapsible <details> element):              │
│    error.message (string)                                    │
│                                                              │
│  [ Try again ]   [ Go to dashboard ]                         │
└─────────────────────────────────────────────────────────────┘
```

- Container: centered in available space, card-style with `--surface-card` background and `--color-error-light` border
- Icon: warning/error icon (inline SVG or design system icon, `--color-error` fill)
- "Try again" button: calls `handleReset()` — primary style using `--color-brand-600`
- "Go to dashboard" button: navigates to `/instances` using a plain `<a>` (not React Router `<Link>`, because the boundary may have unmounted the router context if placement is outside the router — see §5)
- `data-testid="error-boundary-panel"` on the container
- `data-testid="error-boundary-reset"` on the "Try again" button
- `data-testid="error-boundary-details"` on the `<details>` element
- Error details are shown only when `import.meta.env.DEV === true`; hidden in production

### 3.6 What ErrorBoundary catches

| Error category | Caught by ErrorBoundary | How |
|---|---|---|
| Render-phase `throw` in any child component | ✅ Yes | `getDerivedStateFromError` |
| Error thrown in `componentDidMount` / `useLayoutEffect` (synchronous) | ✅ Yes | `componentDidCatch` |
| Error thrown in `useEffect` cleanup (asynchronous) | ❌ No | Must be handled in the effect itself |
| `Promise` rejection not caught in TanStack Query | ❌ No | Not a render error |
| API errors surfaced by TanStack Query | ❌ No | Components render error states via `isError` |
| Errors thrown inside event handlers | ❌ No | Must be caught in handler code |
| Errors outside the React tree (global `unhandledrejection`) | ❌ No | Out of scope for SH-05 |

The ErrorBoundary does NOT suppress or rethrow any error — it intercepts render errors only.

---

## 4. SH-06: ApiConnectivityBanner

### 4.1 `useApiConnectivity` hook interface

```typescript
// Design — no implementation
interface UseApiConnectivityOptions {
  /**
   * Polling interval in milliseconds.
   * Defaults to VITE_HEALTH_POLL_INTERVAL_MS env variable (default: 30000).
   */
  intervalMs?: number
}

interface UseApiConnectivityResult {
  /** true = backend is reachable; false = unreachable; null = not yet checked */
  isOnline: boolean | null
  /** ISO timestamp of the last successful check, or null */
  lastOnlineAt: string | null
  /** ISO timestamp of when the outage began, or null if currently online */
  outageSince: string | null
}

export function useApiConnectivity(options?: UseApiConnectivityOptions): UseApiConnectivityResult
```

**Polling logic (prose, no code):**
1. On mount, run an immediate health check.
2. Set a recurring `setInterval` at `intervalMs`. Clear on unmount.
3. Each check calls the `healthReady()` function from `web/src/api/health.ts` (raw fetch to `GET /health/ready`, see §4.3).
4. If the response is 2xx: set `isOnline = true`, record `lastOnlineAt`, clear `outageSince`.
5. If the response is non-2xx or a network error is thrown: set `isOnline = false`, set `outageSince` to current ISO timestamp if it was not already set (do not reset the outage start on repeated failures).
6. While `isOnline === null` (initial state before first check completes), the banner is not shown (no flash of connectivity warning on load).
7. The hook does NOT use TanStack Query — it manages its own interval independently of the query cache to avoid interfering with page-level data loading.

### 4.2 `ApiConnectivityBanner` component interface

```typescript
// Design — no implementation
interface ApiConnectivityBannerProps {
  /**
   * Forwarded to useApiConnectivity; defaults to VITE_HEALTH_POLL_INTERVAL_MS.
   */
  pollIntervalMs?: number
}

export function ApiConnectivityBanner(props: ApiConnectivityBannerProps): React.ReactElement | null
```

**Render contract:**
- Returns `null` when `isOnline === null` (loading) or `isOnline === true` (connected)
- Returns a sticky banner element when `isOnline === false`

**Banner element specification:**

```
┌─────────────────────────────────────────────────────────────────────┐
│  ⚠  Platform is currently unavailable — some actions may fail.      │
└─────────────────────────────────────────────────────────────────────┘
```

- Position: `position: sticky; top: 0; z-index: 100` — stays at the top of the `<main>` scroll container, above page content
- Background: `--color-warning-light`; border-bottom: `1px solid --color-warning`; text: `--color-warning-dark`
- No dismiss button — the banner is auto-dismissed by connectivity recovery
- `data-testid="connectivity-banner"` on the root element
- `role="status"` for accessibility (non-assertive ARIA live region)
- `aria-live="polite"` — screen readers announce it without interrupting current focus

### 4.3 `healthReady()` — new function in `health.ts`

The existing `healthApi.get()` uses the authenticated `client.get()` path (injects Bearer token, follows the RFC 9457 error contract). The connectivity probe must use a raw fetch to distinguish network failure from API error, and should not trigger a `401 → auth:session-expired` event if the backend is temporarily unreachable.

```typescript
// Design signature — no implementation
/**
 * Raw connectivity probe. Calls GET /health/ready without the API client wrapper.
 * Returns true if response status is 2xx, false for any other response or network failure.
 * Never throws.
 */
export async function healthReady(): Promise<boolean>
```

**Behaviour:**
- Uses native `fetch` directly (not the `client` wrapper)
- Injects `Authorization: Bearer <token>` via `getToken()` from `client.ts` if a token is present (the endpoint requires auth per current backend spec — see Open Constraints §7)
- Returns `true` on any 2xx response; `false` on non-2xx or caught exception
- Does NOT parse the response body
- Sets `signal: AbortSignal.timeout(5000)` to avoid hanging if the server is slow

---

## 5. Integration Points

### 5.1 `router.tsx` — ErrorBoundary placement

The `<ErrorBoundary>` wraps `<AppShell />` inside the `ProtectedRoute`, so it covers the entire authenticated view tree but does not wrap the login page or the auth loading state.

**Current structure (relevant portion):**
```
<AuthProvider>
  <ProtectedRoute>
    <AppShell />    ← Outlet renders child pages here
  </ProtectedRoute>
</AuthProvider>
```

**Target structure after SH-05:**
```
<AuthProvider>
  <ProtectedRoute>
    <ErrorBoundary>
      <AppShell />
    </ErrorBoundary>
  </ProtectedRoute>
</AuthProvider>
```

This placement ensures:
- The router context, `AuthProvider`, `QueryClientProvider`, and `ProtectedRoute` are all outside the boundary and cannot be crashed by a page-level error.
- The "Go to dashboard" link in the fallback UI can safely use a plain `<a href="/instances">` because the router context is above the boundary.
- A render error in any page component, including `AppShell` itself, is caught. If `AppShell` throws during render, the user sees the recovery panel (not a blank screen).

### 5.2 `AppShell.tsx` — ApiConnectivityBanner placement

`<ApiConnectivityBanner />` is rendered inside the `<main>` element, above `<Outlet />`:

**Current structure:**
```
<main style={{ flex: 1, overflow: 'auto', background: '#f8fafc' }}>
  <Outlet />
</main>
```

**Target structure after SH-06:**
```
<main style={{ flex: 1, overflow: 'auto', background: '#f8fafc' }}>
  <ApiConnectivityBanner />
  <Outlet />
</main>
```

This placement ensures:
- The banner is sticky within the scrollable main area, always visible at the top of the content region without overlapping the sidebar.
- It does not affect the sidebar or header layout.
- The `position: sticky; top: 0` on the banner works correctly because `<main>` is the scroll container.

---

## 6. Error Taxonomy

### SH-05 error categories

| Category | Caught | Recovery action |
|---|---|---|
| React render error in any page component | ✅ | `handleReset()` triggers re-render of subtree |
| React render error in `AppShell` itself | ✅ | Same — boundary is above `AppShell` |
| Error in `useLayoutEffect` (synchronous throw) | ✅ | Same |
| Error thrown in TanStack Query `queryFn` | ❌ — TanStack handles it | Component renders via `isError` state |
| `401` from API → `auth:session-expired` event | ❌ — handled by `AuthProvider` listener | Redirect to `/login` |
| Network failure in `fetch` call | ❌ — async, not a render error | Component or hook handles it |
| `useEffect` callback that throws asynchronously | ❌ | Must be caught inside the effect |

### SH-06 connectivity probe — error categories

| Category | `healthReady()` return | Banner shown |
|---|---|---|
| `GET /health/ready` returns 2xx | `true` | No |
| `GET /health/ready` returns 4xx or 5xx | `false` | Yes |
| Network failure (DNS failure, connection refused, timeout) | `false` | Yes |
| `AbortError` (timeout after 5 s) | `false` | Yes |
| `getToken()` returns null (not authenticated) | — (probe still runs, no auth header) | Depends on backend response |

---

## 7. Open Constraints

### OC-1: `/health/ready` authentication requirement

The SH-06 requirement text says `GET /health/ready`. The existing backend health endpoint is `GET /health` (mapped to `/api/v1/health` via `healthApi.get()`). It is unclear whether a `/health/ready` sub-path exists or is planned, and whether it requires authentication.

**Recommended resolution for BACKEND-DEV review:** The connectivity probe should call the cheapest available health endpoint. If `/health/ready` is not implemented, `GET /health` (no auth required) is acceptable for connectivity detection. The endpoint choice must be confirmed before FRONTEND-DEV implements `healthReady()`.

**Impact:** If the endpoint requires authentication, probing before login is not meaningful; the hook should only be mounted inside the authenticated shell (current design already satisfies this).

### OC-2: "reload this view" vs "Try again" button label

SH-05 requirement text says "reload this view" but the design uses "Try again" (resets React error state) and "Go to dashboard" (hard navigation). A full page reload (`window.location.reload()`) would also satisfy the requirement. The design prefers React state reset over a hard reload to preserve in-memory session state (avoiding re-login). If the product preference is a hard reload, FRONTEND-DEV should use `window.location.reload()` in the button handler instead.

### OC-3: Error reporting in production

The design suppresses error details (`error.message`, component stack) in production builds (`import.meta.env.DEV === false`). If the platform requires production error reporting (e.g., Sentry integration), that is out of scope for SH-05 and should be a separate requirement.

### OC-4: New environment variable

`VITE_HEALTH_POLL_INTERVAL_MS` (default `30000`) is a new variable not currently in `web/.env.local` or the frontend developer guide. FRONTEND-DEV must add it to the guide's environment variable table and to `web/.env.local.example` if one exists.
