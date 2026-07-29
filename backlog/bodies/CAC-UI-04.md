> **Extends:** PIN-01, carrying instance version pinning through to the client fetch.

> A task payload read SHALL request the definition version recorded on the task row as `task.definition_version` through `GET /api/v1/definitions/{key}?version={n}`, and SHALL cache it under the key `['definition', tenantSlug, key, version]`. The currently active version SHALL NOT be substituted for a pinned version at any point. The SPA SHALL compare the `X-Definition-Version` response header against the requested version and, on a mismatch, SHALL discard the response and render `StaleVersionError` rather than open a form against the wrong schema.

**Acceptance Criteria:**
- GIVEN a Playwright E2E creates an instance from definition version 3 on the real backend and then publishes version 5 of the same definition key, WHEN the user opens the task from that instance, THEN the page network log shows a request carrying `version=3`; no HTTP mocking is used.
- GIVEN that request resolves, WHEN `queryClient.getQueryCache().getAll()` is read in the page, THEN the cached key equals `['definition', <slug>, <key>, 3]` and no unversioned definition key is present.
- GIVEN version 5 of the same definition is already cached from the Definition List, WHEN the task opens, THEN the version 5 entry does not satisfy the version 3 read and a separate request is issued.
- GIVEN the task form renders, WHEN its fields are compared against the version 3 `form_schema` fetched directly from the real API, THEN the field set matches version 3 and not version 5.
- GIVEN the backend returns `X-Definition-Version: 5` for a request that asked for version 3, WHEN the response is processed, THEN it is discarded and `StaleVersionError` renders per RND-UI-06.
- GIVEN the pinned version has been purged and the API returns 404, WHEN the state is classified, THEN it is `fetch-failure` and `FetchError` renders with its Retry action.

**See:** CAC-UI-01, RND-UI-06, RND-UI-03, PIN-01, PD-08, TK-UI-01
