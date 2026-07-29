> **Extends:** IDN-02, giving role enforcement a client-side surface that discloses nothing about the protected resource.

> The `permission-denied` state SHALL render `web/src/components/ui/PermissionDenied.tsx`. Its rendered subtree SHALL contain the string "You do not have access to this area. Contact your tenant administrator." and a link to the Task Inbox, and SHALL contain no HTTP status number, no `problem.type` URI, no `problem.detail` text, no resource UUID, and no backend-authored message. The state SHALL be reached on both 401 and 403 without a full page reload.

**Acceptance Criteria:**
- GIVEN a Playwright E2E signs in through the real Keycloak realm as a SwiftRoute driver who holds no `bpm-admin` role, WHEN the user navigates to the Definition List, THEN the real backend returns 403 and `PermissionDenied` renders; no HTTP mocking is used.
- GIVEN that rendered subtree, WHEN its `textContent` is matched in the same E2E against `/40[13]|application\/problem|urn:problem|[0-9a-f]{8}-[0-9a-f]{4}-/`, THEN there is no match.
- GIVEN that rendered subtree, WHEN its text is read, THEN it equals the fixed copy above plus the Task Inbox link label, and contains no other text node.
- GIVEN a user holds the role at page load and the role is revoked through the real Keycloak admin API mid-session, WHEN the next query fires in that E2E, THEN the boundary switches to `permission-denied` and the browser performs no navigation.
- GIVEN a page renders `PermissionDenied`, WHEN the axe scan of GRD-UI-06 runs on that surface, THEN there is no `serious` or `critical` violation.

**See:** RND-UI-01, IDN-02, IDN-05, ADM-UI-01, GRD-UI-06
