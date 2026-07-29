> Each key factory in `web/src/api/queryKeys.ts` SHALL declare one of three cache lifetime tiers defined in `web/src/api/cacheTiers.ts`. The `volatile` tier applies to `instance`, `task`, `timer` and `dlq` with `staleTime` 0 s and `gcTime` 30 s. The `session` tier applies to `definition`, `eventType`, `user` and `role` with `staleTime` 60 s and `gcTime` 5 min. The `reference` tier applies to `branding` and `health` with `staleTime` 15 min and `gcTime` 30 min. The tier SHALL be declared on the factory; a hook SHALL NOT override `staleTime` or `gcTime` at the call site.

**Acceptance Criteria:**
- GIVEN every exported factory in `web/src/api/queryKeys.ts`, WHEN the tier declaration is read, THEN each factory names exactly one of `volatile`, `session` or `reference`; an undeclared factory fails this pure static check with no HTTP.
- GIVEN a hook passing `staleTime` or `gcTime` inline to `useQuery`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails reporting the file path and pattern name `inline-stale-time`; this is a pure static scan with no HTTP.
- GIVEN a Playwright E2E opens the Instance List against the real backend, navigates to the Definition List and returns, WHEN the page network log is read, THEN the instance list was refetched on the second mount because its `staleTime` is 0 s.
- GIVEN the same E2E returns to the Definition List within 60 s, WHEN the network log is read, THEN no definition list request was issued, because the `session` tier holds the data fresh.
- GIVEN the branding key, WHEN the same E2E navigates across five routes inside 15 min, THEN exactly one branding request appears in the network log.
- GIVEN the tier values in `cacheTiers.ts`, WHEN they are compared against the six numbers stated above, THEN each matches.

**See:** CAC-UI-01, GRD-UI-02, IN-UI-05, DLQ-UI-01, WH-UI-04
