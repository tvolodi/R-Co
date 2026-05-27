# Test Spec: OIDC-07 - Claim validation

**Requirement:** OIDC-07 - Token verification MUST validate: signature against cached JWKS; `iss` matches the configured issuer for the tenant; `aud` includes the configured client ID; `exp` is in the future (with configurable clock skew, default 30 seconds); `nbf` is in the past or absent. Tokens failing any check MUST be rejected with HTTP 401.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-07-01: Wrong issuer is rejected
**Given:** A bearer token is routed to OIDC verification and contains an `iss` that does not match tenant issuer configuration.
**When:** The authentication middleware verifies the token.
**Then:** The request is rejected with HTTP 401 and machine code `token_invalid_issuer`.
**Layer:** unit, integration
**Acceptance criterion mapped:** Invalid case `wrong issuer` returns HTTP 401.
**Automated coverage:**
- `TC-OIDC-07-U01` in `tests/unit/test_api08_auth.zig`
- `TC-OIDC-07-I01` in `tests/integration/oidc07_claim_validation_auth_test.zig`

### TC-OIDC-07-02: Wrong audience is rejected
**Given:** A bearer token is routed to OIDC verification and its `aud` does not contain the configured client ID.
**When:** The authentication middleware verifies the token.
**Then:** The request is rejected with HTTP 401 and machine code `token_invalid_audience`.
**Layer:** unit, integration
**Acceptance criterion mapped:** Invalid case `wrong audience` returns HTTP 401.
**Automated coverage:**
- `TC-OIDC-07-U02` in `tests/unit/test_api08_auth.zig`
- `TC-OIDC-07-I02` in `tests/integration/oidc07_claim_validation_auth_test.zig`

### TC-OIDC-07-03: Expired token is rejected
**Given:** A bearer token is routed to OIDC verification and `exp` is outside the allowed skew window.
**When:** The authentication middleware verifies the token.
**Then:** The request is rejected with HTTP 401 and machine code `token_expired`.
**Layer:** unit, integration
**Acceptance criterion mapped:** Invalid case `expired` returns HTTP 401.
**Automated coverage:**
- `TC-OIDC-07-U03` in `tests/unit/test_api08_auth.zig`
- `TC-OIDC-07-I03` in `tests/integration/oidc07_claim_validation_auth_test.zig`
- `TC-OIDC-04-03` (expired-claim case) in `src/identity/provider/test_oidc02_keycloak_adapter.zig`

### TC-OIDC-07-04: Not-yet-valid token is rejected
**Given:** A bearer token is routed to OIDC verification and `nbf` is outside the allowed skew window.
**When:** The authentication middleware verifies the token.
**Then:** The request is rejected with HTTP 401 and machine code `token_not_yet_valid`.
**Layer:** unit, integration
**Acceptance criterion mapped:** Invalid case `not-yet-valid` returns HTTP 401.
**Automated coverage:**
- `TC-OIDC-07-U04` in `tests/unit/test_api08_auth.zig`
- `TC-OIDC-07-I04` in `tests/integration/oidc07_claim_validation_auth_test.zig`
- `TC-OIDC-04-03` (nbf-claim case) in `src/identity/provider/test_oidc02_keycloak_adapter.zig`

### TC-OIDC-07-05: Bad signature is rejected
**Given:** A bearer token is routed to OIDC verification and signature verification fails against JWKS material.
**When:** The authentication middleware verifies the token.
**Then:** The request is rejected with HTTP 401 and machine code `token_invalid_signature`.
**Layer:** unit, integration
**Acceptance criterion mapped:** Invalid case `bad signature` returns HTTP 401.
**Automated coverage:**
- `TC-OIDC-07-U05` in `tests/unit/test_api08_auth.zig`
- `TC-OIDC-07-I05` in `tests/integration/oidc07_claim_validation_auth_test.zig`

### TC-OIDC-07-06: Symmetric clock-skew handling is enforced
**Given:** Clock skew is configured (default 30 seconds) and claim validation evaluates both temporal bounds.
**When:** The verifier evaluates a token where `exp` is older than the permitted skew and another token where `nbf` is later than the permitted skew.
**Then:** The verifier rejects both cases deterministically (`TokenExpired` and `TokenNotYetValid`), proving symmetric skew handling for past and future boundaries.
**Layer:** unit
**Acceptance criterion mapped:** Clock skew is configurable and applied symmetrically.
**Automated coverage:**
- `TC-OIDC-04-03` (expired and nbf violation cases under fixed clock) in `src/identity/provider/test_oidc02_keycloak_adapter.zig`
- `TC-OIDC-07-U03` and `TC-OIDC-07-U04` error-to-401 mapping in `tests/unit/test_api08_auth.zig`

## Acceptance-to-Test Traceability

| OIDC-07 acceptance criterion | Test cases | Concrete test IDs and files |
|---|---|---|
| Wrong issuer returns HTTP 401 | TC-OIDC-07-01 | TC-OIDC-07-U01 in `tests/unit/test_api08_auth.zig`; TC-OIDC-07-I01 in `tests/integration/oidc07_claim_validation_auth_test.zig` |
| Wrong audience returns HTTP 401 | TC-OIDC-07-02 | TC-OIDC-07-U02 in `tests/unit/test_api08_auth.zig`; TC-OIDC-07-I02 in `tests/integration/oidc07_claim_validation_auth_test.zig` |
| Expired token returns HTTP 401 | TC-OIDC-07-03 | TC-OIDC-07-U03 in `tests/unit/test_api08_auth.zig`; TC-OIDC-07-I03 in `tests/integration/oidc07_claim_validation_auth_test.zig`; TC-OIDC-04-03 case in `src/identity/provider/test_oidc02_keycloak_adapter.zig` |
| Not-yet-valid token returns HTTP 401 | TC-OIDC-07-04 | TC-OIDC-07-U04 in `tests/unit/test_api08_auth.zig`; TC-OIDC-07-I04 in `tests/integration/oidc07_claim_validation_auth_test.zig`; TC-OIDC-04-03 case in `src/identity/provider/test_oidc02_keycloak_adapter.zig` |
| Bad signature returns HTTP 401 | TC-OIDC-07-05 | TC-OIDC-07-U05 in `tests/unit/test_api08_auth.zig`; TC-OIDC-07-I05 in `tests/integration/oidc07_claim_validation_auth_test.zig` |
| Clock skew configurable and symmetric | TC-OIDC-07-06 | TC-OIDC-04-03 temporal-claim cases in `src/identity/provider/test_oidc02_keycloak_adapter.zig`; TC-OIDC-07-U03/U04 in `tests/unit/test_api08_auth.zig` |

## Directive Alignment

- This spec does not introduce mocks/stubs for backend verification paths.
- HTTP 401 invalid-case behavior is anchored to real integration tests and deterministic unit checks.
