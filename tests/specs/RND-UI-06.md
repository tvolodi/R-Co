# Test Spec: RND-UI-06 — Three-action write conflict resolution

**Requirement:** RND-UI-06 — When a `PATCH` write returns HTTP 409 with the `X-Resource-Version` response header, the Definition Editor must mount a three-action modal (`Refetch latest`, `Merge manually`, `Discard mine`) that owns no write side-effects of its own, keeps the local draft intact until the user explicitly confirms a discard, and disables `Merge manually` when `X-Resource-Version` is absent.
**Priority:** MUST
**Test layer:** unit (Vitest + Testing Library), e2e (Playwright — real backend, two browser contexts)

**Design reference:** `src/design/pw13-pw16-batch19-20260813.md` §2.1–§2.7, §5.2, §12.2.

## Test Cases

### TC-RND-UI-06-01: ConflictResolver mounts three actions via createPortal
**Given:** `<ConflictResolver serverPayload={…} localDraft={…} conflictVersion="v2" onRefetch onSaveMerged onDiscardConfirmed />`
**When:** the component is rendered
**Then:** three buttons mount with `data-testid` values `conflict-refetch`, `conflict-merge`, `conflict-discard` inside a `role="dialog"` portal at `document.body`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-1
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-01`)

### TC-RND-UI-06-02: Merge manually disabled when X-Resource-Version absent
**Given:** `conflictVersion={null}` (server did not emit `X-Resource-Version`)
**When:** the resolver renders
**Then:** `[data-testid="conflict-merge"]` has `disabled`, `aria-disabled="true"`, an `aria-describedby` pointing at an explanatory node; the other two buttons remain enabled
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-6 + §12.2 mode 1
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-02`)

### TC-RND-UI-06-03: Refetch fires onRefetch immediately
**Given:** `onRefetch={mockFn}`
**When:** `[data-testid="conflict-refetch"]` is clicked
**Then:** `onRefetch` is called once
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-3
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-04`)

### TC-RND-UI-06-04: Discard opens ConfirmDialog; Cancel does NOT fire onDiscardConfirmed
**Given:** a clean `<ConflictResolver>` with `conflictVersion="v2"`
**When:** `[data-testid="conflict-discard"]` is clicked, then `[data-testid="confirm-dialog-cancel"]`
**Then:** `onDiscardConfirmed` is NOT called; the resolver stays mounted; the Zustand draft is unchanged
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-5 + §12.2 mode 3
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-05`), `web/tests/unit/ConflictResolver.12.test.tsx` (`TC-CR-09`)

### TC-RND-UI-06-05: Discard confirm fires onDiscardConfirmed exactly once
**Given:** `onDiscardConfirmed={mockFn}`
**When:** `[data-testid="conflict-discard"]` then `[data-testid="confirm-dialog-confirm"]`
**Then:** `onDiscardConfirmed` is called once
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-5
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-06`)

### TC-RND-UI-06-06: Merge panel Save fires onSaveMerged with merged body + version
**Given:** `serverPayload={a:1, b:'server'}`, `localDraft={a:2, b:'local'}`, `conflictVersion="v42"`
**When:** the merge panel is opened and Save is clicked (default choice per field is "local")
**Then:** `onSaveMerged(mergedBody, 'v42')` is called once; `mergedBody.a === 2`, `mergedBody.b === 'local'`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-4
**Implemented by:** `web/tests/unit/ConflictResolver.test.tsx` (`TC-CR-07`)

### TC-RND-UI-06-07: StaleVersionError reads conflictVersion from error.details.xResourceVersion
**Given:** `<StaleVersionError error={{ status: 409, details: { xResourceVersion: 'v42' }, … }}>`
**When:** the boundary component renders
**Then:** the inner `<ConflictResolver>` is mounted with the three actions enabled
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-1
**Implemented by:** `web/tests/unit/StaleVersionError.test.tsx` (`TC-SVE-01`)

### TC-RND-UI-06-08: StaleVersionError with xResourceVersion=null disables Merge
**Given:** an `ApiError` whose `details.xResourceVersion == null`
**When:** `<StaleVersionError>` renders
**Then:** `[data-testid="conflict-merge"]` is disabled; Refetch and Discard remain enabled
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-6
**Implemented by:** `web/tests/unit/StaleVersionError.test.tsx` (`TC-SVE-02`)

### TC-RND-UI-06-09: definitionDraftStore setDraft / clearDraft semantics
**Given:** a fresh Zustand store
**When:** `setDraft({definitionId: 'def-1', body: {…}, …})` is called, then `clearDraft('def-1')`
**Then:** the draft is stored and then cleared; `clearDraft('def-2')` is a no-op
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-06 AC-3
**Implemented by:** `web/tests/unit/definitionDraftStore.test.ts` (`TC-DDS-01..04`)

### TC-RND-UI-06-10: ConflictResolver makes NO API calls between mount and first user click
**Given:** an active network observer on `**/api/v1/definitions/**`
**When:** the resolver mounts (after a real 409 in the E2E) and the user has not clicked yet
**Then:** the request count for `/api/v1/definitions/**` does NOT increase until the user picks one of the three actions
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-2
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-02`)

### TC-RND-UI-06-11: real two-context 409 mounts the resolver with X-Resource-Version
**Given:** two `browser.newContext()` instances both authenticated as `worker-user`, both editing the same definition
**When:** context A saves first (200), context B then saves (409 with `X-Resource-Version: <v>`)
**Then:** context A's editor renders `[data-testid="conflict-resolver"]` with three actions enabled
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-1
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-01`)

### TC-RND-UI-06-12: Refetch latest retains the local draft; DraftBanner remains
**Given:** the resolver mounted with a known draft in `definitionDraftStore`
**When:** `[data-testid="conflict-refetch"]` is clicked
**Then:** `definitionDraftStore.draft.body` is unchanged; `[data-testid="draft-banner"]` is visible above the editor
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-3
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-03`)

### TC-RND-UI-06-13: Merge manually → next PATCH carries X-Resource-Version as If-Match (or body.version)
**Given:** the resolver mounted with `X-Resource-Version: v42` on the 409
**When:** Merge is opened, fields picked, Save clicked
**Then:** the next PATCH/PUT request to `/api/v1/definitions/{id}` carries either `If-Match: v42` (header) or `body.version === 'v42'` — the version stamped equals the one the server returned
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-4
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-04`)

### TC-RND-UI-06-14: Discard confirm clears draft and dismisses resolver
**Given:** the resolver mounted with a draft
**When:** `[data-testid="conflict-discard"]` then `[data-testid="confirm-dialog-confirm"]`
**Then:** `definitionDraftStore.draft === null`; `[data-testid="conflict-resolver"]` is hidden; no PATCH was issued during the discard path
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-5
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-05`)

### TC-RND-UI-06-15: 409 without X-Resource-Version disables Merge (real backend fixture)
**Given:** the backend fixture strips the `X-Resource-Version` header on the 409
**When:** the resolver mounts in response to the 409
**Then:** `[data-testid="conflict-merge"]` is disabled; Refetch + Discard remain enabled
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-06 AC-6 + §12.2 mode 1
**Implemented by:** `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` (`TC-RND-UI-06-E2E-06`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| RND-UI-06 AC-1: three actions, portal-mounted | `TC-RND-UI-06-01`, `TC-RND-UI-06-07`, `TC-RND-UI-06-11` |
| RND-UI-06 AC-2: no PUT/POST between 409 and first click | `TC-RND-UI-06-10` |
| RND-UI-06 AC-3: Refetch latest retains draft, banner present | `TC-RND-UI-06-03`, `TC-RND-UI-06-09`, `TC-RND-UI-06-12` |
| RND-UI-06 AC-4: Merge → version field equals X-Resource-Version | `TC-RND-UI-06-06`, `TC-RND-UI-06-13` |
| RND-UI-06 AC-5: Discard → confirm-drop / cancel-keep | `TC-RND-UI-06-04`, `TC-RND-UI-06-05`, `TC-RND-UI-06-14` |
| RND-UI-06 AC-6: 409 w/o X-Resource-Version → Merge disabled | `TC-RND-UI-06-02`, `TC-RND-UI-06-08`, `TC-RND-UI-06-15` |
| §12.2 mode 1: 409 w/o X-Resource-Version → Merge disabled, others available | `TC-RND-UI-06-02`, `TC-RND-UI-06-08`, `TC-RND-UI-06-15` |
| §12.2 mode 2: 409 on non-definition endpoints (same resolver surface) | `web/tests/unit/StaleVersionError.test.tsx` (`TC-SVE-04` — instance / task type) |
| §12.2 mode 3: User dismisses Discard → no fire, draft intact | `TC-RND-UI-06-04`, `web/tests/unit/ConflictResolver.12.test.tsx` (`TC-CR-09`) |
| §12.2 mode 4: Network failure during Refetch → FetchError + draft intact | `web/tests/unit/StaleVersionError.test.tsx` (`TC-SVE-03`), `web/tests/unit/ConflictResolver.12.test.tsx` (`TC-CR-10`) |
| §12.2 mode 5: Server version older than local → mismatch banner, Merge still enabled | `web/tests/unit/ConflictResolver.12.test.tsx` (`TC-CR-11`) |

## Acceptance Test Coverage Matrix

| AC | E2E | Unit | Status |
|---|---|---|---|
| AC-1 | `TC-RND-UI-06-11` | `TC-RND-UI-06-01`, `TC-RND-UI-06-07` | COVERED |
| AC-2 | `TC-RND-UI-06-10` | (n/a — must be E2E) | COVERED |
| AC-3 | `TC-RND-UI-06-12` | `TC-RND-UI-06-03`, `TC-RND-UI-06-09` | COVERED |
| AC-4 | `TC-RND-UI-06-13` | `TC-RND-UI-06-06` | COVERED |
| AC-5 | `TC-RND-UI-06-14` | `TC-RND-UI-06-04`, `TC-RND-UI-06-05` | COVERED |
| AC-6 | `TC-RND-UI-06-15` | `TC-RND-UI-06-02`, `TC-RND-UI-06-08` | COVERED |
| §12.2 mode 1 | `TC-RND-UI-06-15` | `TC-RND-UI-06-02` | COVERED |
| §12.2 mode 2 | (covered) | `web/tests/unit/StaleVersionError.test.tsx` (`TC-SVE-04`) | COVERED |
| §12.2 mode 3 | (covered) | `TC-RND-UI-06-04`, `TC-CR-09` | COVERED |
| §12.2 mode 4 | (covered) | `TC-SVE-03`, `TC-CR-10` | COVERED |
| §12.2 mode 5 | (covered) | `TC-CR-11` | COVERED |

## Execution Notes For TEST-RUNNER

- The E2E uses **two `browser.newContext()` instances** so each `worker-user` has an isolated sessionStorage and cookie jar — this is required to drive a real 409 without mocking.
- Per-test isolation: each test creates its own definition via `POST /api/v1/definitions` and tears it down in `afterAll`; the draft state lives only in memory.
- `web/tests/e2e/rnd-ui-06.conflict-resolver.e2e.spec.ts` ships the no-mock contract verbatim — no `page.route()` for the API or auth endpoints.
- `web/tests/unit/ConflictResolver.12.test.tsx` is the §12.2 mode 3/4/5 regression suite (replaces the FRONTEND-DEV's earlier draft with explicit assertions).
