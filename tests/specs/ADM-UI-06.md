# Test Spec: ADM-UI-06 — Token list

**Requirement:** ADM-UI-06 — A table listing all API tokens: associated user, roles, expiry, created date, and revocation status. Token values are never shown in this view.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-06-01: token list shows metadata and never reveals the raw token value
**Given:** a PLATFORM_ADMIN session and a freshly issued token for a unique user fixture
**When:** the admin opens `/admin/tokens`
**Then:** the table shows the token owner, role set, expiry state, created date, and active/revoked status, and the raw token value is absent from the list view
**Layer:** e2e
**Acceptance criterion mapped:** token list columns and no token-value exposure
**Implemented by:** `tests/integration/idn04_api_token_management_test.zig` (`TC-IDN-04-01`, `TC-IDN-04-03`, `TC-IDN-04-05`) and `web/tests/e2e/f5-admin-groups-tokens.e2e.spec.ts` (`TC-ADM-UI-06-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-06: token owner and role metadata render | `TC-ADM-UI-06-01` |
| ADM-UI-06: expiry and created timestamps render | `TC-ADM-UI-06-01` |
| ADM-UI-06: revocation state is visible | `TC-ADM-UI-06-01` |
| ADM-UI-06: token values never appear in the list view | `TC-ADM-UI-06-01` |

## Execution Notes For TEST-RUNNER

- The fixture token is created through the real backend before the page is opened.
- The assertion for token secrecy checks the rendered page text, not a mocked API response.
- Visual confirmation is captured after the table loads.