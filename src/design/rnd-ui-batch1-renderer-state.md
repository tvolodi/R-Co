# Design: RND-UI Batch 1 — Renderer State Union and UI State Components

**Requirements:** RND-UI-01, RND-UI-02, RND-UI-03, RND-UI-04  
**Stage:** F8  
**Run ID:** WF02-pw13-rnd-ui-20260813  
**Artefact type:** E (novel / cross-cutting)

---

## Module purpose

This design defines a closed, six-state renderer union (`RendererState`) that every async
page body uses to describe its React Query lifecycle. A single classifier function
(`classifyError`) is the only place in the SPA that inspects HTTP status codes on query
errors. A gating component (`QueryStateBoundary`) switches exhaustively on the union and
mounts exactly one of four state subtrees at a time: skeleton (loading), the page body
(success), an error surface with a user-driven retry (fetch-failure), a leak-free
access-denied surface (permission-denied), or the appropriate future surfaces for the two
remaining states. No page body, hook, or API module reads `error.status` for the purpose
of branching on render state; that concern is fully isolated in `classifyError.ts`.

The change eliminates the pattern currently scattered across pages — inline `{isLoading && <p>…</p>}` / `{isError && <p>…</p>}` guards — and replaces it with a single boundary
that is impossible to leave incomplete without triggering a TypeScript exhaustiveness error.

---

## Type definitions

### `RendererState` — `web/src/utils/classifyError.ts`

```typescript
export type RendererState =
  | 'loading'
  | 'success'
  | 'fetch-failure'
  | 'permission-denied'
  | 'stale-version'
  | 'rate-limit'
```

This type is the canonical union. It must be exported from `classifyError.ts` only and
re-exported from nowhere else. Adding a seventh member without a corresponding switch arm
in `QueryStateBoundary` must cause `npm run type-check` to exit non-zero (enforced by the
`never` default arm).

### `classifyError` — `web/src/utils/classifyError.ts`

```typescript
export function classifyError(error: unknown): RendererState
```

**HTTP status → `RendererState` mapping (exhaustive):**

| Condition | Resulting state |
|---|---|
| `error` is falsy / not an `ApiError` | `'fetch-failure'` |
| `status === 401` | `'permission-denied'` |
| `status === 403` | `'permission-denied'` |
| `status === 409` | `'stale-version'` |
| `status === 429` **AND** `details.retryAfter` is present and non-null | `'rate-limit'` |
| `status === 429` **AND** `details.retryAfter` is absent or null | `'fetch-failure'` |
| all other non-2xx and transport failures | `'fetch-failure'` |

The function receives `unknown` — the type of `UseQueryResult.error` — and narrows to
`ApiError` (from `web/src/types/api.ts`) internally. It MUST NOT throw. It MUST NOT import
from any component or hook. Its only import is `ApiError` from `@/types/api`.

This function is the **only** place in `web/src/` that reads `error.status` or
`error.details.retryAfter` for the purpose of determining render state. The GRD-UI-02
static scan enforces pattern name `status-read-outside-classifier` on any other file that
accesses `error.response.status` or `error.status` in a conditional context.

---

## Component interfaces

### `QueryStateBoundary` — `web/src/components/ui/QueryStateBoundary.tsx`

```typescript
interface QueryStateBoundaryProps {
  state: RendererState
  children: React.ReactNode
  onRetry?: () => void
}
```

The component contains an exhaustive switch on `state`:

```
switch (state) {
  case 'loading':           → render <SkeletonLayout>
  case 'success':           → render children
  case 'fetch-failure':     → render <FetchError onRetry={onRetry ?? noop}>
  case 'permission-denied': → render <PermissionDenied>
  case 'stale-version':     → render stale-version surface (RND-UI-05, not in this batch)
  case 'rate-limit':        → render rate-limit surface (RND-UI-06, not in this batch)
  default: {
    const _exhaustive: never = state  // TypeScript exhaustiveness check
    return null
  }
}
```

Constraints:
- At most one state subtree is mounted at any point in time; no two can be rendered simultaneously.
- `onRetry` is forwarded only to `FetchError`. Other states do not use it.
- `SkeletonLayout`, `FetchError`, and `PermissionDenied` are imported from within `web/src/components/ui/`.
- `classifyError` is **not** called inside `QueryStateBoundary`. The caller (page component) derives `state` from `classifyError(query.error)` before passing it as a prop.

**Deriving `state` from a query — pattern a page MUST follow:**

```typescript
// Pseudocode — caller-side state derivation (no implementation here)
// (1) While loading:
state = 'loading'
// (2) On error:
state = classifyError(query.error)
// (3) On success:
state = 'success'
```

The canonical derivation order: if `query.isLoading` then `'loading'`; else if `query.isError` then `classifyError(query.error)`; else `'success'`.

---

### `SkeletonLayout` — `web/src/components/ui/SkeletonLayout.tsx`

```typescript
interface SkeletonColumn {
  widthPercent: number  // integer 1–100
}

interface SkeletonLayoutProps {
  columns: SkeletonColumn[]
  rowCount?: number  // default: 5
}
```

Accessibility contract:
- The content region root element carries `aria-busy="true"` while mounted (i.e., whenever the `loading` state is active and `SkeletonLayout` is rendered by `QueryStateBoundary`).
- `aria-busy` is **not** a prop; it is unconditionally set on the root element of `SkeletonLayout` itself.
- On transition from `loading` to `success`, `QueryStateBoundary` unmounts `SkeletonLayout` and mounts children; the `aria-busy` attribute is removed from the DOM by unmounting.

Styling contract:
- Skeleton rows draw exclusively from CSS custom properties `--color-neutral-200` (darker row) and `--color-neutral-100` (alternating/background). No literal colour value (`#…`, `rgb(…)`, named colour) may appear in the component source. The GRD-UI-02 static scan enforces pattern name `literal-colour`.
- Column widths are derived from the `columns` prop, not hardcoded. Each column's width as a percentage of the row must match the corresponding column width of the `DataTable` it replaces during loading.

The `rowCount` prop defaults to `5` when omitted.

---

### `FetchError` — `web/src/components/ui/FetchError.tsx`

```typescript
interface FetchErrorProps {
  onRetry: () => void
}
```

Accessibility contract:
- The root element carries `role="alert"`. This attribute is unconditional and must not depend on any prop.

Retry contract:
- One visible Retry control (button or equivalent) calls `onRetry` on activation.
- `onRetry` is bound by the caller to `query.refetch`. Since `retry` is `0` globally, the
  query will not auto-retry; the user action is the only retry path.
- A recovered read (state transitions from `fetch-failure` back through `loading` to
  `success`) MUST NOT fire a success toast. No `onSuccess` callback or mutation-success
  side-effect that shows a toast may be added to queries passing through `QueryStateBoundary`.

---

### `PermissionDenied` — `web/src/components/ui/PermissionDenied.tsx`

```typescript
// No props — fixed copy component
```

Render contract:
- The rendered subtree contains exactly the fixed copy string:
  `"You do not have access to this area. Contact your tenant administrator."`
  and a link to the Task Inbox.
- The component MUST NOT render any of the following, regardless of the error object:
  - HTTP status numbers (`401`, `403`, or any numeric HTTP code)
  - `problem.type` URIs (e.g. `urn:problem:…`, `application/problem+json`)
  - `problem.detail` text (backend-authored narrative)
  - Resource UUIDs (matches `/[0-9a-f]{8}-[0-9a-f]{4}-/`)
  - Any field sourced from the query error object
- The component receives no props; it does not accept an error object and cannot
  inadvertently render backend-authored content through prop drilling.
- Task Inbox link: renders as a navigable link to `/tasks` (the route for `TaskInboxPage`
  per `web/src/router.tsx:56`). The link label is the display name for the Task Inbox as
  used in the application navigation.
- Accessibility: the component must pass an axe audit with no `serious` or `critical`
  violation (GRD-UI-06).

---

## Data-flow diagram

```
page component
 │
 ├── calls useQuery (directly) or a hook that wraps useQuery
 │        │
 │        └── React Query fetches via client.ts
 │                   │
 │                   ├── success path → query.data, query.isLoading=false, query.isError=false
 │                   └── error path  → query.error: ApiError (status, code, details)
 │
 ├── derives RendererState:
 │        isLoading → 'loading'
 │        isError   → classifyError(query.error)   [ONLY call site for HTTP status read]
 │        otherwise → 'success'
 │
 └── renders:
      <QueryStateBoundary state={rendererState} onRetry={query.refetch}>
        {/* page body — only mounted when state === 'success' */}
      </QueryStateBoundary>

QueryStateBoundary (exhaustive switch)
 ├── 'loading'           → <SkeletonLayout columns={…} />      aria-busy="true"
 ├── 'success'           → children
 ├── 'fetch-failure'     → <FetchError onRetry={props.onRetry} />   role="alert"
 ├── 'permission-denied' → <PermissionDenied />                (no error data leaked)
 ├── 'stale-version'     → [RND-UI-05 — not in this batch]
 ├── 'rate-limit'        → [RND-UI-06 — not in this batch]
 └── default (never)     → TypeScript compile error if RendererState gains a new member

classifyError(error: unknown): RendererState
 ├── reads ApiError.status
 ├── reads ApiError.details.retryAfter (for 429 only)
 └── called only from page components (never inside QueryStateBoundary)
```

---

## Global retry configuration change

**File:** `web/src/main.tsx`

**Current default:** `retry: (failureCount, error) => { … return failureCount < 2 }`  
**Required default:** `retry: 0`

The current custom function is replaced by the literal `0`. The per-status suppression of
retries (401/403/404) is no longer needed because `QueryStateBoundary` surfaces those
states immediately and the user drives the retry explicitly via `FetchError.onRetry`.

No individual hook in `web/src/hooks/` may override `retry` inline (i.e., pass
`retry: <any value>` in their `useQuery` options). The GRD-UI-02 static scan enforces
this under the acceptance criterion "retry is 0 and no hook overrides it inline".

**Note:** `useTaskInbox` in `useTasks.ts` uses `refetchInterval` for polling — this is
unchanged; polling is not a retry and must not be removed.

---

## Pages that need `<QueryStateBoundary>` wrapping

Every page component listed below calls `useQuery` (directly or via a hook from
`web/src/hooks/`) and currently renders inline loading/error guards that must be replaced
by a `<QueryStateBoundary>` wrapper around the page body.

| Page file | Query source | Notes |
|---|---|---|
| `pages/admin/AuditLogPage.tsx` | direct `useQuery` | Two queries — primary data query needs boundary |
| `pages/admin/GroupsPage.tsx` | direct `useQuery` | Three queries |
| `pages/admin/HealthDashboardPage.tsx` | inline custom hook `useAdminHealthSnapshot` | Wraps `useQuery` |
| `pages/admin/MetricsPage.tsx` | inline custom hook `usePrometheusMetrics` | Wraps `useQuery` |
| `pages/admin/services/ServicesPage.tsx` | direct `useQuery` |
| `pages/admin/tenants/EditTenantPage.tsx` | direct `useQuery` |
| `pages/admin/tenants/TenantsPage.tsx` | direct `useQuery` |
| `pages/admin/TokensPage.tsx` | direct `useQuery` |
| `pages/admin/UsersPage.tsx` | direct `useQuery` |
| `pages/admin/UserDetailPage.tsx` | `useAdminUser`, `useAdminRoles`, `useAdminGroups` hooks |
| `pages/admin/users/UsersPage.tsx` | `useAdminUsers`, `useAdminRoles` hooks |
| `pages/dashboard/TenantDashboardPage.tsx` | direct `useQuery` |
| `pages/definitions/DefinitionListPage.tsx` | `useDefinitions`, `useDefinitionSearch` hooks |
| `pages/definitions/DefinitionEditorPage.tsx` | `useDefinition` hook |
| `pages/instances/InstanceBoardPage.tsx` | `useDefinition`, `useInstances` hooks |
| `pages/instances/InstanceDetailPage.tsx` | `useInstance` hook |
| `pages/tasks/TaskInboxPage.tsx` | `useTaskInbox`, `useTask` hooks |
| `pages/dlq/DlqPage.tsx` | direct `useQuery` |
| `pages/dlq/WebhooksPage.tsx` | direct `useQuery` |

Pages with multiple queries should derive state from the primary query. Secondary queries
(e.g., look-up lists used in forms) that are not visible in the page body skeleton may
still carry inline loading guards; the boundary applies to the primary data region.

`SkeletonLayout.columns` for each page should match the `DataTable` column widths in that
page. The specific `widthPercent` values for each page are a FRONTEND-DEV implementation
decision; the design constraint is that each column width must be identical between the
skeleton frame and the resolved `DataTable` frame (verified by Playwright E2E bounding-box
comparison per RND-UI-02 acceptance criterion 3).

---

## Dependencies

### `classifyError.ts` imports
- `ApiError` from `@/types/api` (read-only, narrows `unknown`)

### `QueryStateBoundary.tsx` imports
- `RendererState` from `@/utils/classifyError`
- `SkeletonLayout` from `@/components/ui/SkeletonLayout`
- `FetchError` from `@/components/ui/FetchError`
- `PermissionDenied` from `@/components/ui/PermissionDenied`
- `React` (JSX runtime)

### `SkeletonLayout.tsx` imports
- `React` only; no hook, no API call

### `FetchError.tsx` imports
- `React` only; no hook, no API call

### `PermissionDenied.tsx` imports
- Router `Link` primitive (react-router-dom); no hook, no API call, no error object

### Prohibition
None of these four new files may import from:
- `web/src/api/` (no direct API calls)
- `web/src/stores/` (no store reads)
- `web/src/hooks/` (no query hooks)
- Each other, except for `QueryStateBoundary` which imports the three sibling UI components

---

## Files NOT to change

| File | Reason |
|---|---|
| `web/src/api/client.ts` | Already throws `ApiError` with correct `status` and `details.retryAfter`; `classifyError` reads those fields |
| `web/src/types/api.ts` | `ApiError` shape is already correct; no new fields needed |
| `web/src/hooks/*.ts` | Hooks remain unchanged except removal of any `retry:` overrides if present (none found in current codebase) |
| `web/src/components/ui/ConfirmPromoteModal.tsx` | No query usage, out of scope |
| `web/src/components/ui/JsonDiffView.tsx` | No query usage, out of scope |
| `web/src/router.tsx` | Route table is unchanged |
| `web/src/main.tsx` | **Only** the `retry` option in `defaultOptions.queries` changes from the custom function to `0`; all other QueryClient config is preserved |
| `web/src/auth/` | Auth layer unchanged |
| All migration files in `migrations/` | No backend changes required for this batch |
| All Zig source files in `src/` | No backend changes required for this batch |

---

## Error taxonomy

| Error case | Who detects | Resulting `RendererState` | UI surface |
|---|---|---|---|
| HTTP 401 (expired token) | `classifyError` | `permission-denied` | `PermissionDenied` |
| HTTP 403 (role revoked mid-session) | `classifyError` | `permission-denied` | `PermissionDenied` |
| HTTP 404 (resource deleted) | `classifyError` | `fetch-failure` | `FetchError` with retry |
| HTTP 409 (stale version conflict) | `classifyError` | `stale-version` | RND-UI-05 (future batch) |
| HTTP 429 + Retry-After header | `classifyError` | `rate-limit` | RND-UI-06 (future batch) |
| HTTP 429 without Retry-After | `classifyError` | `fetch-failure` | `FetchError` with retry |
| HTTP 5xx (backend error) | `classifyError` | `fetch-failure` | `FetchError` with retry |
| Transport failure (network down) | `classifyError` | `fetch-failure` | `FetchError` with retry |
| Query in-flight | query `isLoading` | `loading` | `SkeletonLayout` |
| Query resolved | query `isSuccess` | `success` | page body / children |

---

## Open questions

None at the time of authoring. All ambiguities in the requirements are resolved by:
- RND-UI-01 fixing the exact 429-without-Retry-After edge case (`fetch-failure`).
- RND-UI-04 providing the exact fixed copy string.
- `ApiError.details.retryAfter` shape confirmed in `client.ts` line 101 (`details: { retryAfter }`).

---

## Acceptance criteria for FRONTEND-DEV

| # | Criterion | Verification method |
|---|---|---|
| AC-1 | `web/src/utils/classifyError.ts` exists and exports both `RendererState` type and `classifyError` function | `tsc --noEmit` (type-check) |
| AC-2 | `classifyError` is the only function in `web/src/` that reads `error.status` or `error.response.status` in a conditional context | GRD-UI-02 static scan, pattern `status-read-outside-classifier` |
| AC-3 | Adding a seventh member to `RendererState` without a switch arm in `QueryStateBoundary` causes `tsc` to exit non-zero | Pure static check — add a member, run type-check, revert |
| AC-4 | `web/src/components/ui/QueryStateBoundary.tsx` exists with the props interface and exhaustive switch | `tsc --noEmit` |
| AC-5 | All 19 pages listed in "Pages that need `<QueryStateBoundary>` wrapping" render their body inside `<QueryStateBoundary>` | GRD-UI-02 static scan, pattern `missing-query-state-boundary` |
| AC-6 | `web/src/components/ui/SkeletonLayout.tsx` renders `aria-busy="true"` on its root element unconditionally | Unit test or Playwright E2E first-frame capture |
| AC-7 | `SkeletonLayout` uses only `--color-neutral-200` and `--color-neutral-100`; no literal colour values | GRD-UI-02 static scan, pattern `literal-colour` |
| AC-8 | `web/src/components/ui/FetchError.tsx` renders `role="alert"` on its root element unconditionally | Unit test |
| AC-9 | `web/src/components/ui/PermissionDenied.tsx` renders exactly the fixed copy string plus Task Inbox link; `textContent` does not match `/40[13]|application\/problem|urn:problem|[0-9a-f]{8}-[0-9a-f]{4}-/` | Playwright E2E with a 403-returning SwiftRoute driver session |
| AC-10 | `main.tsx` `defaultOptions.queries.retry` is `0` | GRD-UI-02 static scan; no hook in `web/src/hooks/` overrides `retry` |
| AC-11 | A recovered read after `FetchError` does not fire a success toast | Playwright E2E success-frame inspection |
| AC-12 | Skeleton column widths are identical to resolved `DataTable` column widths | Playwright E2E bounding-box comparison |
