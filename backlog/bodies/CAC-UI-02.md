> On a tenant switch emitted by `web/src/components/TenantHeader.tsx`, the SPA SHALL call `queryClient.removeQueries()` for every cached key whose element 1 equals the outgoing slug, and SHALL complete that disposal before the first query of the incoming tenant is issued. On sign-out the SPA SHALL call `queryClient.clear()` before the identity provider redirect. The regression test covering this SHALL be named `cache-isolation-on-tenant-switch` and SHALL be referenced by that name in `tests/specs/PIPELINE-tenant-cache.md`. Client-side key scoping is defence in depth; the Platform API remains the enforcing tenant boundary.

**Acceptance Criteria:**
- GIVEN a Playwright E2E named `cache-isolation-on-tenant-switch` signs in as a user holding membership in both SwiftRoute and Vortex on the real backend, WHEN the user switches from SwiftRoute to Vortex without reloading, THEN reading `queryClient.getQueryCache().getAll()` in the page returns no key whose element 1 equals `swiftroute`.
- GIVEN that switch, WHEN the Instance List is re-rendered, THEN the intermediate frame shows `SkeletonLayout` and no SwiftRoute row appears in any captured frame.
- GIVEN a request to a SwiftRoute route is in flight when the switch fires, WHEN the response arrives, THEN it is discarded because its key was removed, and no SwiftRoute row enters the Vortex cache.
- GIVEN the user signs out, WHEN the cache is read immediately before the Keycloak redirect in that E2E, THEN `getQueryCache().getAll()` returns an empty array.
- GIVEN `tests/specs/PIPELINE-tenant-cache.md`, WHEN it is read, THEN it names `cache-isolation-on-tenant-switch` and maps it to CAC-UI-02; this is a pure static specification check.
- No HTTP mocking is used at any point; both tenants are real seeded tenants on the running backend.

**See:** CAC-UI-01, CAC-UI-04, IDN-02, IDN-05, ADM-UI-01
