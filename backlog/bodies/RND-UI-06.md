> **Extends:** PD-08, giving optimistic concurrency a client-side resolution surface.

> On a 409 from a write, the SPA SHALL classify the state as `stale-version`, render `web/src/components/ui/StaleVersionError.tsx`, and mount `web/src/components/ui/ConflictResolver.tsx` in a portal offering exactly three actions: Refetch latest, Merge manually, Discard mine. The SPA SHALL NOT re-issue the write automatically at any point between the 409 and a user action. Refetch latest SHALL retain the local draft in the Zustand store and surface it as a banner. Merge manually SHALL open the existing `web/src/components/ui/JsonDiffView.tsx` with the server payload on the left and the local draft on the right, and SHALL post the merged body at the version carried by `X-Resource-Version`. Discard mine SHALL route through `<ConfirmDialog confirmVariant="danger">`.

**Acceptance Criteria:**
- GIVEN a Playwright E2E opens the same process definition in two browser contexts against the real backend and saves from the first, WHEN the second context saves, THEN the real backend returns 409 with `X-Resource-Version` and `ConflictResolver` mounts with three actions; no HTTP mocking is used.
- GIVEN the resolver is mounted, WHEN the page network log is inspected between the 409 and the first user click in that E2E, THEN no `PUT` or `POST` to the definition route was issued.
- GIVEN the user picks Refetch latest, WHEN the view updates, THEN the server payload is displayed, the draft banner is present, and the local draft is still readable from the Zustand store.
- GIVEN the user picks Merge manually and saves, WHEN the outbound request is inspected, THEN its version field equals the value from `X-Resource-Version` and its body is the merged document.
- GIVEN the user picks Discard mine and dismisses the confirmation, WHEN the store is read, THEN the local draft is intact and no write was issued; the draft is dropped only after the `ConfirmDialog` confirm action fires.
- GIVEN a 409 arrives without `X-Resource-Version`, WHEN the resolver mounts, THEN Merge manually is disabled and the other two actions stay available.

**See:** RND-UI-01, CAC-UI-04, PD-08, CMP-UI-03, PD-UI-07
