> The `fetch-failure` state SHALL render `web/src/components/ui/FetchError.tsx` with `role="alert"` and a single `onRetry` action bound to the query's `refetch()`. React Query automatic retry SHALL be set to 0 for every query passing through `QueryStateBoundary`, so a retry occurs only on a user action. A recovered read SHALL NOT fire a success toast.

**Acceptance Criteria:**
- GIVEN a Playwright E2E deletes a process definition through the real API and then navigates to that definition's detail route, WHEN the real 404 arrives, THEN `FetchError` renders with `role="alert"` and one Retry control; no HTTP mocking is used, the 404 comes from the real backend.
- GIVEN the same E2E restarts the API container with `docker-compose restart bpm-platform` and requests the Instance List, WHEN the transport failure surfaces, THEN `FetchError` renders and no partial table is shown.
- GIVEN the container reports healthy again, WHEN the user presses Retry in that E2E, THEN the state returns to `loading`, then to `success`, and the screen shows the instance rows.
- GIVEN a query resolves after a failed attempt, WHEN the success frame is inspected, THEN no toast is present in the toast region.
- GIVEN any query registered on `QueryStateBoundary`, WHEN its options object is read in a pure static scan of `web/src/hooks/`, THEN `retry` is 0 and no hook overrides it inline.

**See:** RND-UI-01, RND-UI-05, GRD-UI-02, API-06, IN-UI-05
