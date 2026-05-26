# Test Spec: OIDC-01 -- Pluggable provider interface

**Requirement:** OIDC-01 -- The authentication subsystem MUST be implemented behind an abstract IdentityProvider interface, not coupled to Keycloak-specific APIs in any path used by the rest of the platform. The interface MUST expose at minimum token verification, user lookup, realm/tenant provisioning, user provisioning, role grant management, client provisioning, IDP federation management, and audit event retrieval.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-01-01: JWT-like bearer path calls IdentityProvider verify through manager
**Given:**
- Auth middleware is configured with an IdentityProvider manager using the stub adapter.
- A JWT-like bearer token (`a.b.c`) is provided.

**When:**
- `authenticate(allocator, "Bearer a.b.c", undefined)` is called.

**Then:**
- Stub provider verify call count increments to 1.
- Result is `AuthResult.authenticated`.
- Returned role/user/token fields are sourced from the provider principal.

**Layer:** unit
**Acceptance criterion mapped:** Every non-adapter auth call path uses the abstract interface for external bearer verification.
**Implemented by:** `tests/unit/test_api08_auth.zig` test `TC-OIDC-01-01`.

---

### TC-OIDC-01-02: Provider verification failures map to deterministic auth failures
**Given:**
- Auth middleware is configured with a stub provider that returns `error.InvalidToken`.
- A JWT-like bearer token (`a.b.c`) is provided.

**When:**
- `authenticate(allocator, "Bearer a.b.c", undefined)` is called.

**Then:**
- Stub provider verify call count increments to 1.
- Result is `AuthResult.unauthenticated` with HTTP 401.
- Problem detail body includes `invalid bearer token`.

**Layer:** unit
**Acceptance criterion mapped:** Interface-based auth path preserves deterministic pass/fail behavior when provider rejects tokens.
**Implemented by:** `tests/unit/test_api08_auth.zig` test `TC-OIDC-01-02`.

---

### TC-OIDC-01-03: Provider manager routes only JWT-like tokens when interface provider is configured
**Given:**
- A provider manager instance with no provider.
- A provider manager instance with stub provider configured.

**When:**
- `shouldVerifyExternalToken` is evaluated for JWT-like and opaque token strings.

**Then:**
- With no provider, external verification is not selected.
- With provider + `dual_accept`, JWT-like tokens route to external verification and opaque tokens do not.

**Layer:** unit
**Acceptance criterion mapped:** Interface-based boundary is explicit in provider-agnostic routing logic before any adapter-specific behavior.
**Implemented by:** `tests/unit/test_oidc01_provider_boundary.zig` test `TC-OIDC-01-03`.

---

### TC-OIDC-01-04: Local-only auth mode keeps non-provider path active
**Given:**
- A provider manager instance with stub provider configured and `auth_mode = local_only`.

**When:**
- `shouldVerifyExternalToken` is evaluated for JWT-like and opaque token strings.

**Then:**
- Both checks return false, proving local-token path preservation without adapter-specific coupling in auth-mode routing.

**Layer:** unit
**Acceptance criterion mapped:** Coexistence boundary is provider-agnostic and mode-controlled through manager interface.
**Implemented by:** `tests/unit/test_oidc01_provider_boundary.zig` test `TC-OIDC-01-04`.

---

### TC-OIDC-01-05: Manager exposes required OIDC-01 contract operations
**Given:**
- Provider manager is configured with stub adapter.

**When:**
- Test invokes manager methods for lookup, realm provisioning, user provisioning, role grants, client provisioning, federation upsert/delete, and audit-event listing.

**Then:**
- Each method dispatches through the interface and returns deterministic stub `error.NotImplemented`.
- Test fails immediately if any required contract surface is missing or not callable.

**Layer:** unit
**Acceptance criterion mapped:** IdentityProvider contract surface required by OIDC-01 is present and callable through provider-agnostic manager.
**Implemented by:** `tests/unit/test_oidc01_provider_stub.zig` test `TC-OIDC-01-05`.

## Traceability Matrix

| OIDC-01 acceptance area | Concrete test evidence |
|---|---|
| No Keycloak-specific code outside adapter package in non-adapter auth paths | Static source scan command in this spec's build-level checks + design boundary review |
| Auth subsystem call paths use IdentityProvider abstraction | `TC-OIDC-01-01`, `TC-OIDC-01-02`, `TC-OIDC-01-03`, `TC-OIDC-01-04` |
| Contract includes token/user/provisioning/roles/client/federation/audit operations | `TC-OIDC-01-05` |
| Artifacts are executable by TEST-RUNNER in next step | `zig build test` includes `tests/unit/test_oidc01_provider_boundary.zig` and `tests/unit/test_oidc01_provider_stub.zig` |

## Concrete Pass/Fail Signals

### Build-level checks
- **PASS:** `zig build test` compiles and executes OIDC-01 unit tests with exit code 0.
- **PASS:** `rg -n "keycloak" src --glob "*.zig"` returns only adapter/module-export references (`src/identity/provider/mod.zig` and `src/identity/provider/adapters/keycloak/*`).
- **FAIL:** compile error for missing contract members/import boundaries, any OIDC-01 unit test failure, or unexpected non-adapter matches in source scan.

### Runtime-level checks
- **PASS:** OIDC unit tests emit passing assertions for interface dispatch, deterministic 401 mapping, and boundary scans.
- **FAIL:** any assertion failure including direct file path evidence for forbidden coupling or mismatched auth behavior.

## Execution Notes For TEST-RUNNER

- Primary command: `zig build test`
- Focused rerun commands (if isolating failures):
  - `zig test tests/unit/test_oidc01_provider_boundary.zig`
  - `zig test tests/unit/test_oidc01_provider_stub.zig --dep api`
  - `zig test tests/unit/test_api08_auth.zig --dep api --dep pool`