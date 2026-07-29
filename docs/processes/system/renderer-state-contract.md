# Process: Renderer State and Error Contract

| Field | Value |
|-------|-------|
| Process ID | `sys-renderer-state-contract` |
| Platform Workflow | PW-13 |
| Owner | Frontend Platform Team / FRONTEND-DEV |
| Scope | System-wide (every data-bearing screen in `web/src/pages/`) |
| Requirements | RND-UI-01, RND-UI-02, RND-UI-03, RND-UI-04, RND-UI-05, RND-UI-06 |
| Source | `docs/workflows.yaml` (PW-13) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §3.1, §3.6 |

## Summary

Every screen that reads from the Platform API resolves into exactly one of six
states: `loading`, `success`, `fetch-failure`, `permission-denied`,
`stale-version`, `rate-limit`. The state is derived by a single narrowing
helper, `classifyError()`, and rendered by a single boundary component,
`QueryStateBoundary`. A write that collides with a newer server version never
overwrites it; the user is given three explicit resolution actions instead.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Business User | SwiftRoute dispatcher, ops manager, driver | Experiences the state; chooses retry or conflict resolution |
| Tenant Admin | Human | Experiences `permission-denied` when a role was revoked mid-session |
| SPA Renderer | System (`web/src/`) | Classifies the query result and renders exactly one state component |
| Platform API | System | Returns 200, 401/403, 409, 429, 4xx/5xx and the `Retry-After` / `X-Resource-Version` headers |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| React Query result | `UseQueryResult` | Carries `isPending`, `error`, `data` from `api/client.ts` |
| HTTP status | integer | 200, 401, 403, 409, 429, or any other 4xx/5xx |
| `Retry-After` header | integer seconds | Present on every 429; drives the countdown |
| `X-Resource-Version` header | integer | Present on 409; the server's current version of the contested resource |
| Local draft payload | JSON | The unsaved user edit held in the Zustand store during a 409 |
| `problem.type` | string | RFC 7807 type URI; consumed by `classifyError()`, never rendered |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | SPA Renderer | Wrap the page body in `<QueryStateBoundary query={...}>` | Boundary present on this page? | Absent -> PW-16 source scan fails the build | RND-UI-01 |
| 2 | SPA Renderer | Call `classifyError(result)` in `web/src/utils/classifyError.ts` | Result narrows to one member of the union? | Returns `'loading' \| 'success' \| 'fetch-failure' \| 'permission-denied' \| 'stale-version' \| 'rate-limit'` | RND-UI-01 |
| 3 | SPA Renderer | Switch on the union with an exhaustive `never` default arm | New union member added without an arm? | TypeScript compile error at `npm run type-check` | RND-UI-01 |
| 4 | SPA Renderer | `loading` -> render `<SkeletonLayout rows={5} />` with `aria-busy="true"` | Query still pending? | Skeleton rows occupy the final table geometry; no layout shift on resolve | RND-UI-02 |
| 5 | SPA Renderer | `success` -> render page content | - | `aria-busy` cleared; `DataTable` receives `isLoading={false}` | RND-UI-02 |
| 6 | Platform API | Return a non-2xx or fail the connection | Status 401/403? 409? 429? other? | Routed to steps 7, 9, 11, 13 respectively | RND-UI-01 |
| 7 | SPA Renderer | Any other 4xx/5xx or transport failure -> render `<FetchError onRetry={refetch} />` | User presses Retry? | `refetch()` fires; state returns to `loading` | RND-UI-03 |
| 8 | Business User | Read the failure text and press Retry or navigate away | Retry succeeds? | State becomes `success`; `toast.success` is not fired for a recovered read | RND-UI-03 |
| 9 | SPA Renderer | 401 or 403 -> render `<PermissionDenied />` | Does the rendered subtree contain a status code, `problem.type`, `problem.detail`, or a backend message? | Any leak fails the Playwright assertion in step 10 | RND-UI-04 |
| 10 | Business User | Read a role-level explanation and a link back to the Task Inbox | - | Screen shows "You do not have access to this area. Contact your tenant administrator." and nothing else | RND-UI-04 |
| 11 | Platform API | Return 429 with `Retry-After` | Header present? | Absent -> `classifyError()` returns `'fetch-failure'`, not `'rate-limit'` | RND-UI-05 |
| 12 | SPA Renderer | Render `<RateLimitBackpressure retryAfter={n} />` | Countdown reaches zero? | Countdown ticks once per second in `aria-live="polite"`; at zero `refetch()` fires once | RND-UI-05 |
| 13 | Platform API | Return 409 with `X-Resource-Version` on a write | Local draft differs from server payload? | `classifyError()` returns `'stale-version'` | RND-UI-06 |
| 14 | SPA Renderer | Render `<StaleVersionError />` and mount `<ConflictResolver />` in a portal | - | Three actions offered: Refetch latest, Merge manually, Discard mine | RND-UI-06 |
| 15 | Business User | Choose "Refetch latest" | - | Server payload replaces the view; local draft is retained in the Zustand store and shown as a banner | RND-UI-06 |
| 16 | Business User | Choose "Merge manually" | - | `<JsonDiffView>` opens with server payload left, local draft right; save posts the merged body at the server version | RND-UI-06 |
| 17 | Business User | Choose "Discard mine" | Confirmed through `<ConfirmDialog confirmVariant="danger">`? | Local draft is dropped only after confirmation; unconfirmed dialog leaves the draft intact | RND-UI-06 |
| 18 | SPA Renderer | Resubmit the write carrying the server version from step 13 | Second 409? | Loop returns to step 14 with the new server version | RND-UI-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Exactly one state | `QueryStateBoundary` renders one and only one of the six states; no page renders a partial table beside an error |
| Single classifier | `classifyError()` is the only place HTTP status is mapped to a state; pages never read `error.response.status` |
| Status-to-state map | 401, 403 -> `permission-denied`; 409 -> `stale-version`; 429 with `Retry-After` -> `rate-limit`; all other non-2xx and transport failures -> `fetch-failure` |
| Permission denied leaks nothing | The `permission-denied` subtree contains no HTTP status number, no `problem.type`, no `problem.detail`, no resource UUID |
| No silent overwrite | A 409 never triggers an automatic re-POST of the local draft; a write proceeds only after the user picks one of the three `ConflictResolver` actions |
| Discard is destructive | "Discard mine" routes through `<ConfirmDialog confirmVariant="danger">` per design system §7.3 |
| Countdown is bounded | `RateLimitBackpressure` fires one `refetch()` at zero and does not auto-retry a second time |
| No raw colour | State components consume `--color-error`, `--color-warning`, `--color-neutral-500` from `web/src/styles/tokens.css` (PW-14 dependency) |
| Test substrate | DIRECTIVE T-2 forbids MSW and every form of HTTP mocking; each state is provoked by a real backend condition in a Playwright pipeline step, never by an intercepted response |

---

## Outputs

| Output | Description |
|--------|-------------|
| `web/src/utils/classifyError.ts` | The narrowing helper and the exported `RendererState` union type |
| `web/src/components/ui/QueryStateBoundary.tsx` | The exhaustive switch and the only consumer of `classifyError()` |
| `web/src/components/ui/SkeletonLayout.tsx` | Loading state, `aria-busy="true"` |
| `web/src/components/ui/FetchError.tsx` | Fetch failure with `onRetry`, `role="alert"` |
| `web/src/components/ui/PermissionDenied.tsx` | Permission denied, leak-free copy |
| `web/src/components/ui/StaleVersionError.tsx` | Stale version banner |
| `web/src/components/ui/RateLimitBackpressure.tsx` | 429 countdown, `aria-live="polite"` |
| `web/src/components/ui/ConflictResolver.tsx` | Portal-mounted three-action resolver over `JsonDiffView.tsx` |
| `web/tests/e2e/pipelines/renderer-states.pipeline.e2e.spec.ts` | One chained Playwright test covering all six states |
| `tests/specs/PIPELINE-renderer-states.md` | Step table mapping each `pl.step()` to RND-UI-01..06 |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Skeleton hold | `SkeletonLayout` renders from the first frame of the pending query; no blank frame precedes it |
| Retry cadence | `FetchError` retries only on user press; React Query automatic retry is set to 0 for the boundary's queries |
| 429 countdown | Ticks at 1 s intervals from the `Retry-After` value to zero, then refetches once |
| Conflict dialog | `ConflictResolver` stays mounted until the user picks an action; it has no auto-dismiss timer |
| Guard escalation | A page without `QueryStateBoundary` is a PW-16 source-scan BLOCKER, routed to FRONTEND-DEV through WF-03 |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| Unclassifiable error | `classifyError()` receives an error with no HTTP status and no transport code | Returns `'fetch-failure'`; `FetchError` renders with the retry action |
| 429 without `Retry-After` | Rate limiter omits the header | State is `fetch-failure`; user-driven retry replaces the countdown |
| 409 without `X-Resource-Version` | Write conflict reported with no server version | `StaleVersionError` renders; `ConflictResolver` offers Refetch latest and Discard mine only, Merge manually is disabled |
| Role revoked mid-session | Keycloak role removed while the page is open | Next query returns 403; boundary switches to `permission-denied` without a full page reload |
| Backend unreachable | `docker-compose restart bpm-platform` during the pipeline chain | Transport failure -> `fetch-failure`; Retry succeeds once the container reports healthy |
| Repeated conflict | Third party writes again between step 16 and step 18 | Loop re-enters step 14 with the newer version; the merged draft is preserved across the loop |
| Missing exhaustive arm | A seventh state added to the union without a switch arm | `npm run type-check` exits non-zero at the `never` default arm |
