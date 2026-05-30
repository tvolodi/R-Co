# Test Spec: ADM-UI-08 — Revoke token

**Requirement:** ADM-UI-08 — A Revoke action (with confirmation) calls the revoke endpoint. Revoked tokens are visually struck-through in the list.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-08-01: revoke flow confirms the action and marks the token row as revoked
**Given:** a PLATFORM_ADMIN session and a freshly issued token fixture
**When:** the admin clicks Revoke, confirms the dialog, and returns to the token list
**Then:** the confirmation dialog is shown, the revoke endpoint is called, the token row displays revoked status, and the row is visually struck through
**Layer:** e2e
**Acceptance criterion mapped:** revoke confirmation, revoke endpoint, revoked-row styling
**Implemented by:** `tests/integration/idn04_api_token_management_test.zig` (`TC-IDN-04-03`, `TC-IDN-04-06`) and `web/tests/e2e/f5-admin-groups-tokens.e2e.spec.ts` (`TC-ADM-UI-08-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-08: revoke action is visible and confirmable | `TC-ADM-UI-08-01` |
| ADM-UI-08: revoke endpoint is called | `TC-ADM-UI-08-01` |
| ADM-UI-08: revoked tokens show revoked state | `TC-ADM-UI-08-01` |
| ADM-UI-08: revoked tokens are visually struck through | `TC-ADM-UI-08-01` |

## Execution Notes For TEST-RUNNER

- The fixture token is created against the real backend, then revoked through the real UI confirmation flow.
- The test checks the row styling after the revoke mutation completes.
- Visual confirmation is captured for the confirmation dialog and the struck-through list row.