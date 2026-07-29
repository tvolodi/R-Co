# Process: Tenant-Scoped Client Cache

| Field | Value |
|-------|-------|
| Process ID | `sys-tenant-scoped-client-cache` |
| Platform Workflow | PW-15 |
| Owner | Frontend Platform Team / FRONTEND-DEV |
| Scope | System-wide (`web/src/api/queryKeys.ts`, every React Query hook in `web/src/hooks/`) |
| Requirements | CAC-UI-01, CAC-UI-02, CAC-UI-03, CAC-UI-04 |
| Source | `docs/workflows.yaml` (PW-15) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §3.2 (query keys) |

## Summary

Puts the tenant slug into position 2 of every React Query key so no cached
response is ever served across a tenant boundary, sets a cache lifetime per
data class instead of one global default, and pins task payload fetches to the
definition version the task was created against rather than the currently
active version. Today `web/src/api/queryKeys.ts` carries no tenant segment even
though `auth/tenantConfig` and `TenantHeader` establish a per-tenant session.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Business User | Human holding membership in two tenants | Switches tenant inside one browser session; must never see the previous tenant's rows |
| Tenant Admin | Human | Same exposure through the admin surfaces (definitions, event types, DLQ) |
| SPA Cache | System (React Query `QueryClient`) | Stores responses under tenant-segmented keys and evicts by data class |
| Tenant Switcher | System (`web/src/auth/tenantConfig.ts`, `TenantHeader.tsx`) | Sets the active tenant slug and drives cache disposal |
| Platform API | System | Enforces tenant isolation server-side; returns `X-Definition-Version` on task payloads |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `tenantSlug` | string | Read from the active session in `auth/tenantConfig`; never from a route parameter |
| Resource kind | enum | `definition`, `instance`, `task`, `eventType`, `timer`, `dlq`, `audit`, `user`, `role`, `branding`, `metrics`, `health` |
| Resource id | UUID | Optional; absent for list keys |
| `definitionVersion` | integer | The version pinned on the task row, taken from `task.definition_version` |
| Data class | enum | `volatile`, `session`, `reference` - determines the cache lifetime tier |
| Tenant switch event | event | Emitted by `TenantHeader` when the user picks another tenant |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | FRONTEND-DEV | Change every factory in `web/src/api/queryKeys.ts` to emit `[kind, tenantSlug, ...rest]` | Is `tenantSlug` at index 1 in every factory? | A factory without the segment fails the key-shape test in step 3 | CAC-UI-01 |
| 2 | FRONTEND-DEV | Take `tenantSlug` from `auth/tenantConfig.getActiveTenantSlug()` inside the factory | Does any caller pass the slug in from a component prop? | Caller-supplied slug is rejected; the factory reads the session so a stale prop cannot widen the key | CAC-UI-01 |
| 3 | CI gate | Assert every exported factory returns an array whose element 1 equals the active slug | Any factory fails? | BLOCKER routed to FRONTEND-DEV | CAC-UI-01 |
| 4 | CI gate | Assert no hook builds a key as an inline array literal | Inline array passed to `useQuery`? | PW-16 forbidlist pattern `inline-query-key` fails the source scan | CAC-UI-01 |
| 5 | Business User | Sign in to SwiftRoute and open the Instance List | - | Screen shows SwiftRoute instances; cache holds `['instance','swiftroute','list',{...}]` | CAC-UI-02 |
| 6 | Business User | Switch to Vortex through `TenantHeader` without reloading the page | - | Active slug becomes `vortex`; every subsequent key carries `vortex` | CAC-UI-02 |
| 7 | Tenant Switcher | Call `queryClient.removeQueries()` for every key whose element 1 is the outgoing slug | Any SwiftRoute entry left in the cache? | Remaining entry fails the named regression test `cache-isolation-on-tenant-switch` | CAC-UI-02 |
| 8 | Business User | Open the Instance List again under Vortex | Does any SwiftRoute row appear, even for one frame? | Screen shows only Vortex instances; the intermediate frame is a `SkeletonLayout`, not stale rows | CAC-UI-02 |
| 9 | SPA Cache | Apply the `volatile` tier to `instance`, `task`, `timer`, `dlq` keys | - | `staleTime` 0 s, `gcTime` 30 s; every navigation refetches | CAC-UI-03 |
| 10 | SPA Cache | Apply the `session` tier to `definition`, `eventType`, `user`, `role` keys | - | `staleTime` 60 s, `gcTime` 5 min | CAC-UI-03 |
| 11 | SPA Cache | Apply the `reference` tier to `branding` and `health` keys | - | `staleTime` 15 min, `gcTime` 30 min | CAC-UI-03 |
| 12 | CI gate | Assert every factory declares a tier and no hook overrides `staleTime` inline | Inline override present? | PW-16 forbidlist pattern `inline-stale-time` fails the source scan | CAC-UI-03 |
| 13 | Business User | Open a task whose definition was published at version 3 while version 5 is active | - | Task Detail requests `GET /api/v1/definitions/{key}?version=3` | CAC-UI-04 |
| 14 | SPA Cache | Store the payload under `['definition','swiftroute',key,3]` | Does the key omit the version? | An unversioned key fails the key-shape test; version 5 must never satisfy a version 3 read | CAC-UI-04 |
| 15 | Platform API | Return `X-Definition-Version: 3` on the pinned response | Header value differs from the requested version? | SPA discards the response and renders `StaleVersionError` per PW-13 | CAC-UI-04 |
| 16 | SPA Renderer | Render the task form from the version 3 `form_schema` | - | Screen shows the field set the task was created against, not the version 5 field set | CAC-UI-04 |
| 17 | Business User | Sign out | - | `queryClient.clear()` runs before the Keycloak redirect; no key survives the session | CAC-UI-02 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Tenant segment position | Every key is `[kind, tenantSlug, ...rest]`; `tenantSlug` sits at index 1 in all factories without exception |
| Slug source | The factory reads the active slug from `auth/tenantConfig`; components never pass a slug into a key factory |
| No inline keys | `useQuery`, `useMutation` and `queryClient` calls take keys from `api/queryKeys.ts`; an inline array literal is a guard violation |
| Switch disposal | A tenant switch removes every cached entry for the outgoing slug before the first query of the incoming tenant fires |
| Sign-out disposal | `queryClient.clear()` runs before the identity provider redirect |
| Named regression test | The isolation test is named `cache-isolation-on-tenant-switch` and is referenced by ID in `tests/specs/PIPELINE-tenant-cache.md` |
| Cache tiers | `volatile` 0 s / 30 s; `session` 60 s / 5 min; `reference` 15 min / 30 min; the tier is declared on the factory, not at the call site |
| Version pinning | A task payload read uses `task.definition_version`; the active version is never substituted |
| Version verification | The SPA compares `X-Definition-Version` against the requested version and discards a mismatch |
| Client cache is not the boundary | Key scoping is defence in depth; the Platform API remains the enforcing tenant boundary |
| Test substrate | DIRECTIVE T-2 forbids MSW and HTTP mocking; isolation is proven by a Playwright E2E that signs in as a real dual-tenant user against the real backend |

---

## Outputs

| Output | Description |
|--------|-------------|
| `web/src/api/queryKeys.ts` | Tenant-segmented factories with a declared cache tier per kind |
| `web/src/api/cacheTiers.ts` | The three tier definitions and their `staleTime` / `gcTime` values |
| `web/src/auth/tenantConfig.ts` | `getActiveTenantSlug()` and the switch-time `removeQueries` disposal |
| `web/src/components/TenantHeader.tsx` | Emits the switch event that drives disposal |
| `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts` | Chained Playwright test for `platform-tenant-switch-cache-isolation`, containing `cache-isolation-on-tenant-switch` |
| `tests/specs/PIPELINE-tenant-cache.md` | Step table mapping each `pl.step()` to CAC-UI-01..04 |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Switch disposal window | Disposal completes before the first query of the incoming tenant is issued; the user sees `SkeletonLayout` in between |
| Volatile refetch | Instance, task, timer and DLQ lists refetch on every mount and on window focus |
| Reference refetch | Branding and health refetch after 15 minutes or on an explicit `invalidateQueries` |
| Pinned-version miss | A version mismatch surfaces as `stale-version` through PW-13, never as a silent substitution |
| Escalation | A cache entry surviving a tenant switch is a security-relevant BLOCKER routed to FRONTEND-DEV through WF-03 and recorded in `docs/issues/` |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| Active slug absent | A query fires before `auth/tenantConfig` resolves the session | The factory throws `MissingTenantContextError`; the hook is suspended until the slug is present, and no key is built without it |
| Slug changes mid-flight | Tenant switched while a request is in flight | The in-flight response is dropped because its key belongs to the outgoing slug and that key was already removed |
| Pinned version deleted | The definition version referenced by the task was purged | API returns 404; PW-13 renders `fetch-failure` with retry |
| Version header mismatch | `X-Definition-Version` differs from the requested version | Response is discarded and `StaleVersionError` renders; the task form does not open against the wrong schema |
| Inline key literal | A hook builds its own key array | PW-16 source scan fails with the file path and pattern name `inline-query-key` |
| Sign-out race | User signs out while a mutation is pending | `queryClient.clear()` cancels pending queries; the mutation result is discarded rather than written into a cleared cache |
| Cross-tenant leak found in production | A cached row from another tenant is observed | WF-03 opens with severity BLOCKER; the regression test is extended with the observed key shape before the fix is merged |
