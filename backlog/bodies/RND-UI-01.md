> **Extends:** API-06, narrowing the platform error contract into a closed client-side state union.

> The SPA SHALL export the type `RendererState = 'loading' | 'success' | 'fetch-failure' | 'permission-denied' | 'stale-version' | 'rate-limit'` from `web/src/utils/classifyError.ts`, and `classifyError()` SHALL be the only function in `web/src/` that reads an HTTP status off a query error. The mapping is fixed: 401 and 403 to `permission-denied`, 409 to `stale-version`, 429 carrying `Retry-After` to `rate-limit`, every other non-2xx status and every transport failure to `fetch-failure`. `web/src/components/ui/QueryStateBoundary.tsx` SHALL be the only consumer of the union and SHALL switch on it exhaustively with a `never` default arm. Every page component under `web/src/pages/` that calls `useQuery` SHALL render its body inside `<QueryStateBoundary>`.

**Acceptance Criteria:**
- GIVEN a page component under `web/src/pages/` that calls `useQuery` without wrapping its body in `<QueryStateBoundary>`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails with pattern name `missing-query-state-boundary` and the file path; this is a pure static scan with no HTTP.
- GIVEN a seventh member is added to `RendererState` without a matching switch arm, WHEN `npm run type-check` runs, THEN it exits non-zero at the `never` default arm of `QueryStateBoundary`; this is a pure static check with no HTTP.
- GIVEN a file under `web/src/` other than `classifyError.ts` that reads `error.response.status`, WHEN the source scan runs, THEN the scan fails with pattern name `status-read-outside-classifier`.
- GIVEN a Playwright E2E against the real backend drives a page through a 403 and then a successful read, WHEN each frame is inspected, THEN exactly one state subtree is present at a time and no error component is mounted beside a populated `DataTable`.
- GIVEN a 429 response arrives with no `Retry-After` header from the real rate limiter, WHEN `classifyError()` runs in a Playwright E2E, THEN it returns `fetch-failure` rather than `rate-limit`.

**See:** RND-UI-02, RND-UI-03, RND-UI-04, RND-UI-05, RND-UI-06, GRD-UI-02, API-06
