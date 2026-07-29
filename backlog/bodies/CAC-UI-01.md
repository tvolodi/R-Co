> **Extends:** IDN-02, extending tenant isolation from the API boundary into the client cache.

> Every factory exported from `web/src/api/queryKeys.ts` SHALL emit a key of the shape `[kind, tenantSlug, ...rest]` with `tenantSlug` at index 1, for every kind in `definition`, `instance`, `task`, `eventType`, `timer`, `dlq`, `audit`, `user`, `role`, `branding`, `metrics` and `health`. The factory SHALL read the slug from `auth/tenantConfig.getActiveTenantSlug()`; a caller SHALL NOT pass a slug into a factory, so a stale component prop cannot widen a key. A factory invoked before the session resolves SHALL throw `MissingTenantContextError` rather than emit a key without the segment. No `useQuery`, `useMutation` or `queryClient` call SHALL take an inline array literal as its key.

**Acceptance Criteria:**
- GIVEN every exported factory in `web/src/api/queryKeys.ts`, WHEN each is invoked with a fixed active slug, THEN element 1 of the returned array equals that slug; a factory missing the segment fails this pure static key-shape check with no HTTP.
- GIVEN any factory signature accepting a `tenantSlug` parameter, WHEN the key-shape check runs, THEN it fails naming that factory, since the slug is read from the session and not from a caller.
- GIVEN a hook passing an inline array literal to `useQuery`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails reporting the file path and pattern name `inline-query-key`; this is a pure static scan with no HTTP.
- GIVEN a Playwright E2E signs in to SwiftRoute against the real backend and opens the Instance List, WHEN `queryClient.getQueryCache().getAll()` is read in the page, THEN every cached key holds `swiftroute` at index 1 and no key omits the segment.
- GIVEN a factory is invoked before `auth/tenantConfig` resolves the session, WHEN it runs, THEN `MissingTenantContextError` is thrown and no request is issued.

**See:** CAC-UI-02, CAC-UI-03, CAC-UI-04, GRD-UI-02, IDN-02, ENV-01
