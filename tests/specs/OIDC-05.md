# Test Spec: OIDC-05 -- Bearer token acceptance

**Requirement:** OIDC-05 -- The existing API-08 Bearer token verification path MUST be extended to recognise OIDC-issued JWTs. The platform MUST distinguish OIDC tokens from internally-issued tokens (per IDN-04) by token format inspection without ambiguity.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-05-01: OIDC JWT routes to OIDC verifier and authenticates
**Given:**
- Identity provider manager is configured in `dual_accept` mode with a stub provider.
- Authorization header contains a valid JWT-shape bearer token.

**When:**
- `authenticate` is called with `Bearer <jwt>`.

**Then:**
- OIDC verifier path is selected.
- Provider verify function is called exactly once.
- Request is authenticated and returns principal context from provider claims.

**Layer:** unit
**Acceptance criterion mapped:** `GIVEN a request with an OIDC JWT, THEN the platform authenticates it via OIDC verification.`
**Implemented by:** `tests/unit/test_api08_auth.zig` test `TC-OIDC-01-01`.

---

### TC-OIDC-05-02: Internal opaque token routes to IDN-04 path and never calls OIDC verifier
**Given:**
- Identity provider manager is configured in `dual_accept` mode.
- Authorization header contains an opaque (no-dot) bearer token.

**When:**
- `authenticate` is called with `Bearer <opaque-token>`.

**Then:**
- Internal token route is selected.
- OIDC verifier call count remains `0`.
- Internal verification path succeeds for valid internal token input.

**Layer:** unit
**Acceptance criterion mapped:** `GIVEN a request with an internally-issued token, THEN the platform authenticates it via IDN-04 verification.`
**Implemented by:** `tests/unit/test_api08_auth.zig` test `TC-OIDC-05-02`.

---

### TC-OIDC-05-03: Malformed/indeterminate token returns structured HTTP 401 without fallback
**Given:**
- Identity provider manager is configured in `dual_accept` mode.
- Authorization header contains malformed JWT-like token `a.b.c`.

**When:**
- `authenticate` is called with malformed token.

**Then:**
- Response is HTTP 401 with structured unauthorized payload.
- Error payload includes `token_type_indeterminate` and `malformed_indeterminate`.
- OIDC verifier call count remains `0`.
- Internal token verification is not attempted.

**Layer:** unit
**Acceptance criterion mapped:** `GIVEN a request with a malformed token of indeterminate type, THEN the platform returns HTTP 401 with a structured error.`
**Implemented by:** `tests/unit/test_api08_auth.zig` test `TC-OIDC-05-01`.

---

### TC-OIDC-05-04: Route gate prevents ambiguous fallback for JWT-like invalid and opaque tokens
**Given:**
- Manager route gate uses lexical token inspection before external verification.

**When:**
- `shouldVerifyExternalToken` is evaluated for:
  - valid JWT-shape token
  - malformed JWT-like token `a.b.c`
  - opaque token `opaque-token`

**Then:**
- JWT-shape token is eligible for OIDC verification.
- Malformed JWT-like and opaque tokens are not eligible for OIDC verification.
- No ambiguous cross-path fallback can occur.

**Layer:** unit
**Acceptance criterion mapped:** Deterministic token-format inspection without ambiguity.
**Implemented by:** `tests/unit/test_oidc01_provider_boundary.zig` test `TC-OIDC-01-03`.

## OIDC-05 Deterministic Routing Matrix

| Matrix ID | Input token shape | Expected route | OIDC verifier called? | Expected outcome | No-ambiguous-fallback assertion | Evidence |
|---|---|---|---|---|---|---|
| MX-OIDC-05-01 | Valid JWT shape (`header.payload.signature`) | `oidc_jwt` | Yes (1) | Auth success via provider | Internal path not used | `TC-OIDC-01-01` |
| MX-OIDC-05-02 | Opaque token (`no dots`) | `internal_token` | No (0) | Auth success via internal token path | OIDC path not used | `TC-OIDC-05-02` |
| MX-OIDC-05-03 | Malformed JWT-like (`a.b.c`) | `malformed_indeterminate` | No (0) | HTTP 401 structured error | Neither verifier fallback path used | `TC-OIDC-05-01` |
| MX-OIDC-05-04 | Route gate with malformed JWT-like and opaque inputs | `not external-verifiable` | No (false from gate) | Deterministic non-external routing | External verifier bypass confirmed | `TC-OIDC-01-03` |

## No-Ambiguous-Fallback Checks (Explicit)

- Any token classified as `malformed_indeterminate` must terminate at HTTP 401 and must not call OIDC or IDN-04 verification.
- Opaque tokens (`dot_count == 0`) must not call OIDC verifier under dual-accept mode.
- JWT-like tokens failing JWT-shape validation (`a.b.c`) must not degrade into internal token verification.

## Traceability Matrix

| OIDC-05 acceptance area | Concrete test evidence |
|---|---|
| OIDC JWT accepted via OIDC verification path | `tests/unit/test_api08_auth.zig` -> `TC-OIDC-01-01` |
| Internal token accepted via IDN-04 verification path | `tests/unit/test_api08_auth.zig` -> `TC-OIDC-05-02` |
| Malformed/indeterminate token returns structured HTTP 401 | `tests/unit/test_api08_auth.zig` -> `TC-OIDC-05-01` |
| No ambiguous fallback between token types | `tests/unit/test_api08_auth.zig` -> `TC-OIDC-05-01`, `TC-OIDC-05-02`; `tests/unit/test_oidc01_provider_boundary.zig` -> `TC-OIDC-01-03` |

## Step 04 Execution Targets (Exact)

- `tests/unit/test_api08_auth.zig`
  - `TC-OIDC-01-01`
  - `TC-OIDC-05-01`
  - `TC-OIDC-05-02`
- `tests/unit/test_oidc01_provider_boundary.zig`
  - `TC-OIDC-01-03`
- `src/api/middleware/auth.zig` embedded classifier tests:
  - `inspectBearerToken: opaque token routes to internal verification`
  - `inspectBearerToken: valid JWT shape routes to OIDC verification`
  - `inspectBearerToken: malformed JWT-like token is indeterminate`

## Step 04 Pass/Fail Criteria

- PASS:
  - All mapped tests above pass with deterministic route behavior.
  - `TC-OIDC-05-01` confirms `401` + `token_type_indeterminate` and zero verifier calls.
  - `TC-OIDC-05-02` confirms zero verifier calls for opaque internal token path.
- FAIL:
  - Any malformed JWT-like token is accepted or falls through to internal verification.
  - Any opaque token calls OIDC verifier.
  - Any mapped test fails or becomes skipped.
