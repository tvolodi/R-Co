# Test Spec: OIDC-02 -- Keycloak adapter

**Requirement:** OIDC-02 -- A concrete adapter implementing the `IdentityProvider` interface against Keycloak's Admin REST API and OIDC endpoints MUST be provided. The adapter is the only place in the platform that references Keycloak-specific URLs, payloads, or behaviour. All Keycloak Admin REST API references MUST target the current 26.x Quarkus-based distribution.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-02-01: Provider root remains compile-isolated from Keycloak adapter exports
**Given:**
- The provider abstraction root is imported through `api.identity_provider`.
- The adapter package exists under `src/identity/provider/adapters/keycloak/`.

**When:**
- The boundary test evaluates public declarations on the provider root and adapter namespace.

**Then:**
- `api.identity_provider.adapters.stub` is available.
- `api.identity_provider.adapters.keycloak` is not exported through the provider root.
- Non-adapter modules keep compiling without a Keycloak export dependency.

**Layer:** unit
**Acceptance criterion mapped:** Removing the Keycloak adapter from the build does not affect compilation of any other module.
**Implemented by:** `tests/unit/test_oidc01_provider_boundary.zig` test `TC-OIDC-02-01`.

---

### TC-OIDC-02-02: Keycloak adapter verifies OIDC tokens through discovery and JWKS while returning provider-shaped principal data
**Given:**
- A Keycloak adapter configured with deterministic transport, clock, and secret-resolver fixtures.
- Discovery and JWKS responses representing a Keycloak 26.x realm.
- A JWT-like bearer token with standard OIDC claims and Keycloak role data.

**When:**
- `verifyToken` is invoked through the adapter's `IdentityProvider` view.

**Then:**
- The adapter requests `/.well-known/openid-configuration` and the returned `jwks_uri`.
- Principal fields are mapped into the provider contract shape.
- Realm and role information are returned without exposing Keycloak DTOs to non-adapter code.

**Layer:** unit
**Acceptance criterion mapped:** A different adapter can be substituted without changes outside the adapter package because token verification is exercised only through the abstract provider contract.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-02-02`.

---

### TC-OIDC-02-03: Keycloak admin operations stay confined to adapter-specific routes and payloads
**Given:**
- A Keycloak adapter configured with deterministic transport, clock, and secret-resolver fixtures.
- Scripted Keycloak 26.x admin-token, realm, user, role, client, federation, and audit responses.

**When:**
- The adapter executes lookup, provisioning, role grant, federation, and audit operations through the `IdentityProvider` contract.

**Then:**
- Admin calls target only Keycloak-specific Quarkus routes under `/realms/.../protocol/openid-connect/token` and `/admin/realms/...`.
- Request bodies use adapter-local Keycloak payload shapes.
- Returned values are mapped back into provider types, preserving non-adapter compile boundaries.

**Layer:** unit
**Acceptance criterion mapped:** Keycloak-specific URLs, payloads, and behaviour remain isolated to the adapter package while the rest of the platform depends only on the provider contract.
**Implemented by:** `src/identity/provider/test_oidc02_keycloak_adapter.zig` test `TC-OIDC-02-03`.

## Traceability Matrix

| OIDC-02 acceptance area | Concrete test evidence |
|---|---|
| Removing the Keycloak adapter does not affect compilation of other modules | `TC-OIDC-02-01`; source scan of `src/**/*.zig` for `keycloak` matches only adapter-local files and the adapter-local unit test file |
| A different adapter can be substituted without non-adapter changes | `TC-OIDC-02-02`; provider contract shape is exercised via `asIdentityProvider()` result rather than non-adapter Keycloak types |
| Keycloak-specific URLs, payloads, and admin semantics are isolated to adapter modules | `TC-OIDC-02-03`; adapter-local transport assertions prove Quarkus route ownership and payload confinement |
| Artifacts are executable by TEST-RUNNER in the next step | `zig build test` includes `tests/unit/test_oidc01_provider_boundary.zig` and `src/identity/provider/test_oidc02_keycloak_adapter.zig` |

## Concrete Pass/Fail Signals

### Build-level checks
- **PASS:** `zig build test` exits 0 and executes the OIDC-02 mapped unit tests.
- **PASS:** `rg -n "keycloak" src --glob "*.zig"` returns matches only under `src/identity/provider/adapters/keycloak/` and `src/identity/provider/test_oidc02_keycloak_adapter.zig`.
- **FAIL:** any unexpected non-adapter `keycloak` reference appears under `src/**/*.zig`, or the mapped unit tests fail to compile/run.

### Runtime-level checks
- **PASS:** `TC-OIDC-02-01` confirms the provider root does not export the Keycloak adapter.
- **PASS:** `TC-OIDC-02-02` confirms discovery/JWKS-based token verification and provider-type principal mapping.
- **PASS:** `TC-OIDC-02-03` confirms Keycloak admin routes and payloads stay adapter-local while returned values remain provider-shaped.
- **FAIL:** any assertion failure showing provider-root export leakage, missing discovery/JWKS calls, non-Quarkus route usage, or provider-contract mapping regressions.

## Execution Notes For TEST-RUNNER

- Primary command: `zig build test`
- Focused rerun commands (if isolating failures):
  - `zig test tests/unit/test_oidc01_provider_boundary.zig --dep api`
  - `zig test src/identity/provider/test_oidc02_keycloak_adapter.zig`
  - `rg -n "keycloak" src --glob "*.zig"`