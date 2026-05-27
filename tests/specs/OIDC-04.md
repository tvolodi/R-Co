# Test Spec: OIDC-04 -- Standards compliance boundary

**Requirement:** OIDC-04 -- All token verification MUST use only standard OIDC mechanisms: JWKS endpoint for signing keys, discovery document (`/.well-known/openid-configuration`) for endpoint resolution, and standard claims (`iss`, `sub`, `aud`, `exp`, `nbf`, `iat`). Provider-specific token features MUST NOT be required for core authentication.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-04-02: Standards-only token verifies without provider-specific claim extensions
**Given:**
- Adapter verification is executed through the `IdentityProvider` abstraction.
- Discovery and JWKS endpoints are available.
- Token contains only standards claims plus `preferred_username` (no provider extension claims such as `realm_access` or `resource_access`).

**When:**
- `verifyToken` is called with expected audience and current clock.

**Then:**
- Discovery URL and JWKS URI are used for verification.
- Token authenticates successfully.
- Principal roles are empty instead of requiring provider-specific role extensions.

**Layer:** unit
**Acceptance criterion mapped:** No provider-specific token extension is required for successful authentication.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-04-02`.

---

### TC-OIDC-04-03: Standards claim validation rejects issuer/audience/time violations
**Given:**
- Discovery and JWKS calls succeed.
- A matrix of otherwise-valid tokens each violating one standard claim rule (`iss`, `aud`, `exp`, `nbf`, `iat`).
- A matrix of otherwise-valid tokens each violating one standard claim rule (`aud`, `exp`, `nbf`, `iat`).

**When:**
- `verifyToken` is called for each matrix row.

**Then:**
- Each invalid row fails with the expected deterministic provider error:
  - audience mismatch -> `TokenAudienceMismatch`
  - expired token -> `TokenExpired`
  - not-before in the future -> `InvalidToken`
  - issued-at in the future -> `ClaimValidationFailed`

**Layer:** unit
**Acceptance criterion mapped:** Core auth verification depends on standard claims only and rejects standards-invalid tokens.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-04-03`.

---

### TC-OIDC-04-06: Explicit issuer override rejects mismatched `iss`
**Given:**
- Token `iss` points to one tenant issuer.
- Verifier input sets a different explicit expected issuer.
- Discovery and JWKS for the token issuer are reachable.

**When:**
- `verifyToken` is called.

**Then:**
- Verification fails with `TokenIssuerMismatch`.

**Layer:** unit
**Acceptance criterion mapped:** Standard issuer validation (`iss`) controls verification decisions.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-04-06`.

---

### TC-OIDC-04-04: Discovery document contract failure blocks verification
**Given:**
- Discovery endpoint returns a document missing required standards metadata (`jwks_uri`).

**When:**
- `verifyToken` is called.

**Then:**
- Verification fails with `UpstreamProtocolError`.
- No fallback to provider-specific token extension behavior occurs.

**Layer:** unit
**Acceptance criterion mapped:** Discovery document is mandatory standards input for verification.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-04-04`.

---

### TC-OIDC-04-05: JWKS key-selection failure rejects signature verification
**Given:**
- Discovery endpoint returns a valid `jwks_uri`.
- JWKS response does not include the JWT `kid`.

**When:**
- `verifyToken` is called.

**Then:**
- Verification fails with `SignatureVerificationFailed`.

**Layer:** unit
**Acceptance criterion mapped:** Signature verification is driven by standards JWKS key selection.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-04-05`.

## Negative Matrix Coverage (OIDC-04)

| Matrix ID | Invalid condition | Expected error |
|---|---|---|
| MX-OIDC-04-01 | `iss` does not match expected/discovery issuer | `error.TokenIssuerMismatch` |
| MX-OIDC-04-02 | `aud` does not include expected audience | `error.TokenAudienceMismatch` |
| MX-OIDC-04-03 | `exp` is already expired | `error.TokenExpired` |
| MX-OIDC-04-04 | `nbf` is in the future | `error.InvalidToken` |
| MX-OIDC-04-05 | `iat` is in the future | `error.ClaimValidationFailed` |
| MX-OIDC-04-06 | Discovery document missing `jwks_uri` | `error.UpstreamProtocolError` |
| MX-OIDC-04-07 | JWKS does not contain matching `kid` | `error.SignatureVerificationFailed` |

## Traceability Matrix

| OIDC-04 acceptance area | Concrete test evidence |
|---|---|
| Discovery document is used for endpoint resolution | `TC-OIDC-04-02`, `TC-OIDC-04-04` |
| JWKS endpoint is used for signing key selection | `TC-OIDC-04-02`, `TC-OIDC-04-05` |
| Standard claim validation (`iss`,`sub`,`aud`,`exp`,`nbf`,`iat`) governs pass/fail | `TC-OIDC-04-02` (valid standards path), `TC-OIDC-04-03` (aud/exp/nbf/iat matrix), `TC-OIDC-04-06` (issuer mismatch) |
| Provider-specific token extensions are not required for core auth success | `TC-OIDC-04-02` (no extension claims, still passes) |
| Artifacts are executable by TEST-RUNNER | `zig build test` includes `src/identity/provider/test_oidc02_keycloak_adapter.zig` |

## Concrete Pass/Fail Signals

### Build-level checks
- **PASS:** `zig build test` exits 0 and executes OIDC-04 mapped unit tests.
- **FAIL:** compile failure or OIDC-04 test assertion failures in `src/identity/provider/test_oidc02_keycloak_adapter.zig`.

### Runtime-level checks
- **PASS:** standards-only token succeeds without provider extension claims.
- **PASS:** claim/signature/discovery negative rows fail with expected errors.
- **FAIL:** any row passes unexpectedly, fails with wrong error, or requires provider-specific extension claims.

## Execution Notes For TEST-RUNNER

- Primary command: `zig build test`
- Focused rerun command (if isolating failures):
  - `zig test src/identity/provider/test_oidc02_keycloak_adapter.zig`
