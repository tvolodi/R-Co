# Test Spec: ADM-UI-07 — Issue token

**Requirement:** ADM-UI-07 — An "Issue Token" form collects target user, role set, and optional expiry date. After calling `POST /tokens`, the generated token value SHALL be shown exactly once in a modal with a copy-to-clipboard button and a clear "This value will not be shown again" warning.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-07-01: issue-token flow shows the one-time modal, copy action, and close behavior
**Given:** a PLATFORM_ADMIN session and a unique target user fixture
**When:** the admin opens `/admin/tokens`, fills the issue-token form, and submits it
**Then:** the issued-token modal appears with the raw token value visible once, the warning text is shown, the copy button is available, and closing the modal removes the token value from the view
**Layer:** e2e
**Acceptance criterion mapped:** issue-token form, POST `/tokens`, one-time modal, copy button, warning copy, modal close clears token value
**Implemented by:** `tests/integration/idn04_api_token_management_test.zig` (`TC-IDN-04-01`, `TC-IDN-04-02`, `TC-IDN-04-06`) and `web/tests/e2e/f5-admin-groups-tokens.e2e.spec.ts` (`TC-ADM-UI-07-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-07: form collects target user, roles, and optional expiry | `TC-ADM-UI-07-01` |
| ADM-UI-07: POST `/tokens` returns a one-time token value | `TC-ADM-UI-07-01` |
| ADM-UI-07: warning copy is visible in the modal | `TC-ADM-UI-07-01` |
| ADM-UI-07: token value disappears after modal close | `TC-ADM-UI-07-01` |

## Execution Notes For TEST-RUNNER

- The test captures the real POST `/api/v1/auth/tokens` response so cleanup can revoke the issued token afterward.
- Clipboard permission is granted to exercise the copy button against the real browser context.
- Visual confirmation is captured after the modal opens and after it closes.