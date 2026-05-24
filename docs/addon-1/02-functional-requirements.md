# BPM Platform — Functional Requirements (Extension)

**Version:** 0.4-draft
**Scope:** Stages 6.5–11 covering Identity Provider Integration, Execution Layers (DSL, Lua, Wasm), Platform Repository, and Test Runner. Stage 12 (Agent Pipeline) is deferred; future Stages 13–16 are sketched in the Architecture document's roadmap.
**Companion document:** `01-architecture.md`
**Predecessor:** Original Functional Requirements (Stages 1–6) covering BPM Kernel, REST API, Scheduler, Internal Identity Registry

**Note on ordering:** Stage 6.5 (Identity Provider Integration) is placed before Stages 7–11 because authenticated end-to-end testing of the platform must be possible before the extension stages are built. Stages 6.5 and 7–11 are independent in their core design and MAY be implemented in parallel where team capacity allows; see §"Parallelisation Guide" below.

---

## How to Read This Document

Each requirement has:
- **Stable ID** (e.g., `DSL-03`) that is never reused
- **Title** — short imperative phrase
- **Description** — normative behaviour using MUST / SHOULD / MAY (RFC 2119)
- **Priority** — MUST / SHOULD / COULD
- **Acceptance hints** — testable conditions an implementing agent can verify

**For implementing agents:** When a requirement conflicts with the architecture document, this document wins. When two requirements conflict, raise a discrepancy report. When a requirement is ambiguous, prefer the interpretation consistent with the Guiding Principles (Architecture §2).

---

## Priority Legend

- **MUST** — required for stage completion
- **SHOULD** — strongly recommended; deferral requires recorded rationale
- **COULD** — desirable; defer freely if capacity is tight

---

## Parallelisation Guide

The in-scope stages have the following dependency structure. Stages on the same row can be implemented in parallel; arrows indicate hard dependencies.

```
Already shipped:  Stages 1–6  (BPM kernel, REST, scheduler, identity)
                       │
                       ▼
              ┌────────┴────────┐
              │                 │
        Stage 6.5          Stage 7 (DSL)
        (IDP / OIDC)            │
              │                 │
              │           ┌─────┴─────┐
              │           │           │
              │      Stage 8       Stage 9
              │      (Lua)         (Wasm)
              │           │           │
              └─────┬─────┴───────────┘
                    │
                    ▼
              Stage 10 (Repository)
                    │
                    ▼
              Stage 11 (Test Runner)
                    │
                    ▼
              Stage 12 (Agent Pipeline — deferred)
```

**Parallelisation rules:**

- **Stage 6.5 is independent of Stages 7–9.** It can run in parallel with the execution-tier work. The two streams converge at Stage 10 (which needs tenants from 6.5 and the schema registry indexes from 7–9).
- **Stages 7, 8, 9 share no code and have no dependencies between them.** Three agents can work in parallel on DSL, Lua, and Wasm respectively. Each has its own host integration point in the kernel; integration tests join them at the end.
- **Stage 10 depends on Stages 7–9 because the schema registry indexes form schemas, event types, and service catalog entries that the execution tiers define.** It also depends on Stage 6.5 because activations are tenant-scoped (REPO-09).
- **Stage 11 depends on Stage 10** because test scenarios are stored as artifacts. It can begin with a partial repository implementation and grow alongside it.

**Recommended team allocation for parallel work** (if four streams are possible):

| Stream | Focus | Independent until |
|---|---|---|
| A | Stage 6.5 — IDP integration, Keycloak adapter, OIDC middleware | Stage 10 (provides tenant model) |
| B | Stage 7 — DSL parser, evaluator, host API | Stage 10 (registers built-in functions) |
| C | Stage 8 — Lua embedding, sandbox, host API | Stage 10 (registers script artifacts) |
| D | Stage 9 — Wasm runtime, compile pipeline, capability sandbox | Stage 10 (registers module artifacts) |

The four streams converge at Stage 10, where the Platform Repository ties everything together. Stage 11 is then a sequential next step on top of Stage 10.

---

## Stage 6.5 — Identity Provider Integration

**Goal:** Replace the platform's existing internal authentication mechanism with delegated authentication via an OIDC-compliant external identity provider. Keycloak is the primary implementation target, but the integration layer MUST remain provider-agnostic at the contract level. After this stage, real human users can authenticate and exercise the full Stage 1–6 platform end-to-end; this is the foundation for any later stage that requires tenancy or agent identities.

**Relationship to existing IDN-* requirements:** Existing internal user records, tokens, and roles continue to work for backwards compatibility (per the Stage 1–6 contract). This stage adds an alternative authentication path. Internal users may be deprecated in a future migration after all consumers have moved to OIDC.

**Realm strategy:** One realm per BPM tenant (full isolation). The default tenant maps to a realm named `bpm-default`. New tenants get realms named `bpm-<tenant_slug>`. This decision is recorded here so all subsequent requirements assume it.

### Provider-Agnostic Integration Layer

**OIDC-01 — Pluggable Provider Interface (MUST)**
The authentication subsystem MUST be implemented behind an abstract `IdentityProvider` interface, not coupled to Keycloak-specific APIs in any path used by the rest of the platform. The interface MUST expose at minimum: token verification, user lookup, realm/tenant provisioning, user provisioning, role grant management, client (OIDC application) provisioning, IDP federation management, and audit event retrieval.
*Acceptance:* The platform compiles with a stub `IdentityProvider` implementation; no Keycloak-specific code appears outside the Keycloak adapter package.

**OIDC-02 — Keycloak Adapter (MUST)**
A concrete adapter implementing the `IdentityProvider` interface against Keycloak's Admin REST API and OIDC endpoints MUST be provided. The adapter is the only place in the platform that references Keycloak-specific URLs, payloads, or behaviour.
*Acceptance:* Removing the Keycloak adapter from the build does not affect compilation of any other module; a different adapter could be substituted.

**OIDC-03 — Configuration Source (MUST)**
The active identity provider MUST be selected via platform configuration (stored as an artifact per XC-03 once Stage 10 is operational; via environment variable until then). The configuration MUST include: provider type, base URL, admin credentials reference, default realm/tenant identifier.
*Acceptance:* Switching the configured provider type triggers loading the corresponding adapter; misconfiguration produces a clear startup error.

**OIDC-04 — Standards Compliance Boundary (MUST)**
All token verification MUST use only standard OIDC mechanisms: JWKS endpoint for signing keys, discovery document (`/.well-known/openid-configuration`) for endpoint resolution, and standard claims (`iss`, `sub`, `aud`, `exp`, `nbf`, `iat`). Provider-specific token features MUST NOT be required for core authentication.
*Acceptance:* A token verifier configured against any OIDC-compliant provider's discovery URL works without code changes.

### Token Verification

**OIDC-05 — Bearer Token Acceptance (MUST)**
The existing API-08 Bearer token verification path MUST be extended to recognise OIDC-issued JWTs. The platform MUST distinguish OIDC tokens from internally-issued tokens (per IDN-04) by token format inspection without ambiguity.
*Acceptance:* Both token types coexist; a request with either succeeds; a request with a malformed token of indeterminate type fails with a structured error.

**OIDC-06 — JWKS Caching (MUST)**
The platform MUST cache JWKS keys per realm with a configurable TTL (default 10 minutes). On verification failure due to an unknown key ID (`kid`), the cache MUST be refreshed once before final failure. Cache refresh MUST be rate-limited to prevent JWKS-endpoint hammering.
*Acceptance:* Key rotation at the provider is picked up within TTL + one refresh; pathological refresh storms are bounded.

**OIDC-07 — Claim Validation (MUST)**
Token verification MUST validate: signature against cached JWKS; `iss` matches the configured issuer for the tenant; `aud` includes the configured client ID; `exp` is in the future (with configurable clock skew, default 30 seconds); `nbf` is in the past or absent. Tokens failing any check MUST be rejected with HTTP 401.
*Acceptance:* Each invalid case is tested individually.

**OIDC-08 — Standard Claim Mapping (MUST)**
On successful verification, the platform MUST extract: `sub` → external user ID; configurable claim (default `tenant_id`) → tenant; configurable claim (default `realm_access.roles` for Keycloak, falling back to `roles`) → role list; standard claims `email`, `preferred_username`, `name` → user attributes. Mapping rules MUST be configurable per realm to accommodate other providers.
*Acceptance:* Tokens from different configured providers produce equivalent internal user contexts.

### Just-In-Time User Provisioning

**OIDC-09 — JIT User Creation (MUST)**
On first successful authentication of an external user, the platform MUST create a local user record (per IDN-01 schema) mirroring the OIDC identity, with `external_id` (the OIDC `sub`), `external_realm`, and `tenant_id` populated. The local user MUST be marked as externally authenticated (no local password).
*Acceptance:* First login of a new OIDC user creates exactly one local record; subsequent logins do not create duplicates.

**OIDC-10 — Attribute Synchronisation (MUST)**
On every successful authentication, the platform MUST update the local user record with current values from token claims for: display name, email, status. Roles MUST be reconciled: token roles are authoritative; local role bindings sourced from OIDC are replaced; locally-assigned roles (from IDN-03) are preserved.
*Acceptance:* Changing a user's role in Keycloak takes effect on next token issuance and is reflected locally.

**OIDC-11 — External User Identity Stability (MUST)**
The `sub` claim MUST be treated as the stable identifier. Changes to email or username at the provider MUST NOT cause the platform to treat the user as a different person.
*Acceptance:* A user renamed in Keycloak retains the same local user_id and all task assignments, audit attribution, and history.

### Tenant Provisioning via Provider

**OIDC-12 — Realm-Tenant Binding (MUST)**
Each BPM tenant (per IR-01 and ADP-04) MUST be associated with exactly one realm at the provider. The `tenant` table MUST gain an `idp_realm_id` column referencing the provider's realm identifier.
*Acceptance:* Tenant creation API requires an idp_realm_id; lookup by realm ID returns the tenant.

**OIDC-13 — Tenant Claim Source (MUST)**
The `tenant_id` claim required by ADP-03 MUST be populated by the identity provider, not constructed by the client. For Keycloak, this MUST be implemented via a protocol mapper at the realm or client level that injects the tenant_id from realm metadata.
*Acceptance:* Tokens issued by Keycloak for a given realm contain the corresponding tenant_id claim; clients cannot override it.

**OIDC-14 — Realm Provisioning via Adapter (MUST)**
The `IdentityProvider` interface MUST support programmatic realm creation, including: realm name, display name, default token lifetimes, default password policy, default MFA policy, signing key generation, protocol mapper for tenant_id claim. The Keycloak adapter implements this via the Admin REST API.
*Acceptance:* Creating a tenant via platform API results in a fully configured realm at the provider; the realm is immediately ready to issue tokens.

**OIDC-15 — Realm Deletion Safety (MUST)**
Realm deletion via the adapter MUST be a two-step operation: mark for deletion (no new tokens issued, existing tokens accepted until expiry), then hard delete (after a configurable grace period, default 7 days). Hard deletion MUST be irreversible and audit-logged.
*Acceptance:* Marked realms continue to authenticate existing sessions; new logins are refused; after grace period, all data is removed.

### Agent-Driven Provisioning

**OIDC-16 — Full Lifecycle API for Agents (MUST)**
The platform MUST expose REST endpoints wrapping the adapter for: create/list/get/update/delete realms; create/list/get/update/delete users in a realm; assign/revoke roles; create/list/update/delete OIDC clients (applications); create/list/delete IDP federations (SAML, social); rotate client secrets. Endpoints MUST require `PLATFORM_ADMIN` or `AGENT_RUNNER` with the appropriate sub-scope.
*Acceptance:* An agent with proper credentials can provision a complete tenant (realm + admin user + OIDC client + federation) via REST calls alone.

**OIDC-17 — Provisioning Idempotency (MUST)**
All provisioning endpoints MUST accept an idempotency key. Repeated submission with the same key MUST be deduplicated; the original response is returned.
*Acceptance:* An agent retrying after a network timeout does not produce duplicate realms or users.

**OIDC-18 — Provisioning Transactional Semantics (MUST)**
A multi-step provisioning request (e.g., "create realm, admin user, OIDC client, federation in one call") MUST be a single platform-level transaction from the API perspective: either all steps succeed and are committed at the provider, or all steps are rolled back (provider-side rollback may require compensating delete calls).
*Acceptance:* Failure at any step leaves the provider in a state equivalent to before the request.

**OIDC-19 — Provisioning Audit (MUST)**
Every adapter call (read or write) MUST be recorded in the platform audit log with: actor identity, adapter method, provider response status, timing. Sensitive payload fields (secrets, passwords, MFA seeds) MUST be redacted before logging.
*Acceptance:* Audit retrieval shows full provisioning timeline; no secret material appears in audit content.

### Agent Identity at the Provider

**OIDC-20 — Service Accounts for Agents (MUST)**
Each AI agent identity (per ADP-07) MUST be represented at the provider as a dedicated client with the service account flow enabled, scoped to the minimum roles required (`AGENT_RUNNER` plus role-specific grants). Agent tokens MUST be obtained via the client credentials flow, not the password flow.
*Acceptance:* Each agent has its own client credentials; revoking one agent's credentials does not affect others.

**OIDC-21 — Agent Token Rotation (MUST)**
Agent client secrets MUST be rotatable via the adapter API without service interruption. The platform MUST support overlapping validity (old and new secret both work) for a configurable grace period (default 1 hour).
*Acceptance:* Rotation in progress does not cause in-flight agent invocations to fail.

**OIDC-22 — Bootstrap Agent Identity (MUST)**
The platform MUST support a bootstrap mechanism for the first agent (used during tenant provisioning when no agent yet exists at the provider). Bootstrap MUST require a one-time secret presented out-of-band (e.g., environment variable on first startup). Once any persistent agent exists, the bootstrap path is disabled until manually re-enabled.
*Acceptance:* First-run bootstrap succeeds once; re-attempts fail with explicit error.

### Federation and SSO

**OIDC-23 — IDP Federation Support (MUST)**
The adapter MUST support adding identity provider federations (SAML 2.0, OIDC providers, social providers where supported) to a realm. Configuration parameters per federation type are passed through the adapter API.
*Acceptance:* A federation added via API allows authentication via the federated provider; users authenticated through federation appear as JIT-provisioned local users.

**OIDC-24 — Federated User Attribute Mapping (SHOULD)**
The adapter SHOULD support configurable mapping from federated provider claims (SAML attributes, OIDC claims from social providers) to internal user attributes and roles.
*Acceptance:* Mapping configuration from documentation produces expected internal user records.

### Health and Observability

**OIDC-25 — Provider Health Check (MUST)**
The platform's `/health/ready` endpoint MUST include an identity provider connectivity check. Failure of this check MUST set the platform to not-ready (per the existing API-12 semantics).
*Acceptance:* Provider downtime is reflected in readiness; recovery restores readiness.

**OIDC-26 — Provider Metrics (MUST)**
The platform MUST expose Prometheus metrics for: token verification rate, verification latency, JWKS cache hit ratio, adapter call rate per method, adapter call error rate.
*Acceptance:* Metrics are present at `/metrics` and reflect actual traffic.

**OIDC-27 — Token Verification Performance (SHOULD)**
P95 token verification latency (with warm JWKS cache) SHOULD be under 2 ms. Cold-cache verification SHOULD be under 100 ms (one network round-trip to JWKS).
*Acceptance:* Benchmark suite reports against these targets.

### Development and Test Infrastructure

**OIDC-28 — Local Development Realm (MUST)**
The platform repository MUST include a docker-compose configuration that starts Keycloak with a pre-seeded `bpm-default` realm, a pre-configured OIDC client for the platform, and at least three test users with distinct role bindings (`PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `TASK_WORKER`).
*Acceptance:* A developer runs `docker compose up`, waits for health, and can immediately authenticate against the BPM API with any seeded test user.

**OIDC-29 — Realm Seed as Versioned Artifact (MUST)**
The realm export JSON used to seed development Keycloak MUST be stored in the repository under version control. Updates to the seed are reviewed like any other code change.
*Acceptance:* Repository contains `infrastructure/keycloak/realms/bpm-default.json`; CI validates that it imports cleanly.

**OIDC-30 — Test Token Issuance Helper (MUST)**
A test helper utility MUST be provided that issues OIDC tokens for the development realm via the password grant or client credentials flow, suitable for use in integration tests. The helper MUST NOT be reachable in production builds.
*Acceptance:* Integration test suites authenticate via this helper; the helper is gated by a build flag or environment check.

**OIDC-31 — End-to-End Authentication Test Suite (MUST)**
After Stage 6.5 completion, the platform CI MUST include an end-to-end test suite that: starts Keycloak from compose, starts the platform, exercises the full Stage 1–6 API surface authenticated via OIDC tokens, and confirms equivalence with pre-OIDC test results.
*Acceptance:* CI green confirms OIDC integration does not regress Stage 1–6 behaviour.

**OIDC-32 — Agent Test Identities (MUST)**
The development realm seed MUST include service-account clients for the three pipeline agents (`agent-architect`, `agent-developer`, `agent-devops`), each with appropriate role bindings. Agents in development obtain tokens via these clients.
*Acceptance:* Agent integration tests authenticate using these seeded service accounts without manual setup.

### Migration from Internal Authentication

**OIDC-33 — Coexistence Period (MUST)**
After Stage 6.5 deployment, internal authentication (per existing IDN-04 tokens) MUST continue to work indefinitely. There is no forced migration. Internal and OIDC tokens are both valid simultaneously.
*Acceptance:* A token issued before Stage 6.5 deployment continues to authenticate successfully after.

**OIDC-34 — Migration Helper (SHOULD)**
The platform SHOULD provide an administrative API to enumerate internal users not yet linked to an OIDC identity, and to assist in their provisioning at the provider (creating matching Keycloak users in bulk).
*Acceptance:* Admin can list unmigrated users; bulk provisioning succeeds end-to-end.

---

## Stage 7 — Expression DSL

**Goal:** A safe, total expression language usable for gateway conditions, simple validations, and edge transforms. Pure Zig implementation. Zero external dependencies.

### Parser and Grammar

**DSL-01 — Grammar Conformance (MUST)**
The DSL parser MUST accept all expressions conforming to the grammar defined in Architecture §5.1 and MUST reject all others with structured error messages including line and column.
*Acceptance:* For each grammar production, at least one positive and one negative parser test exists.

**DSL-02 — AST Stability (MUST)**
The parser MUST produce an AST whose shape is deterministic for a given input. Two parses of the same input MUST yield structurally identical ASTs.
*Acceptance:* Equality check over AST after parsing same input twice.

**DSL-03 — Error Recovery (SHOULD)**
On parse error, the parser SHOULD report all errors in a single pass where possible, not stop at the first error.
*Acceptance:* A test input with three syntax errors yields a report with three entries.

### Type System

**DSL-04 — Supported Types (MUST)**
The DSL MUST support these value types: `null`, `bool`, `int64`, `float64`, `string`, `timestamp`. No other types are valid.
*Acceptance:* Each type has a literal form (where applicable) and round-trips through parse → evaluate.

**DSL-05 — Type Coercion Rules (MUST)**
The evaluator MUST implement coercion rules as a documented table:
- `int64` ↔ `float64`: automatic in arithmetic, never silent in comparison
- `string` to/from other types: only via explicit built-in functions
- `null` compared to anything except `null` returns `null` (three-valued logic)
*Acceptance:* Coercion table is implemented as test matrix.

**DSL-06 — Total Evaluation (MUST)**
Evaluation of a well-typed expression MUST always terminate and produce one of: a typed value, a typed `null`, or a structured evaluation error. Evaluation MUST NOT crash the host or enter an unbounded loop.
*Acceptance:* Property-based test: random valid-grammar expressions all evaluate within fixed step bound.

### Built-in Functions

**DSL-07 — Function Whitelist (MUST)**
The evaluator MUST support exactly the built-in functions listed in Architecture §5.1. No other functions are callable. Unknown function names are a parse-time error.
*Acceptance:* Each built-in has a dedicated test; calling an unlisted name fails at parse time.

**DSL-08 — Function Purity (MUST)**
Every built-in function MUST be pure: same inputs yield same outputs, no side effects, no I/O.
*Acceptance:* Each built-in's tests verify determinism.

**DSL-09 — Date Built-ins (MUST)**
`now()` MUST return the platform's current time. `date_add(ts, n, unit)` and `date_diff(ts1, ts2, unit)` MUST support units: `second`, `minute`, `hour`, `day`. Time math MUST use UTC; no implicit timezone handling.
*Acceptance:* Cross-DST boundary test confirms UTC arithmetic.

### Variable Access

**DSL-10 — Context Resolution (MUST)**
Identifier expressions (e.g., `order.total`) MUST resolve against a provided context map. Unresolved identifiers MUST evaluate to typed `null`, not crash.
*Acceptance:* Test evaluates expression against context with missing fields; result is `null`.

**DSL-11 — Dot Path Traversal (MUST)**
Dot paths MUST traverse nested objects. Accessing a field on `null` MUST yield `null` (null-propagation), not an error.
*Acceptance:* `a.b.c.d` evaluated where `a.b` is null returns null without error.

### Integration

**DSL-12 — Engine API (MUST)**
The DSL MUST expose a host API:
```
parse(source: []const u8) → !ParsedExpr
evaluate(expr: *ParsedExpr, ctx: *Context) → EvalResult
```
Parsed expressions MUST be cacheable and reusable across evaluations.
*Acceptance:* Same parsed expression evaluated against different contexts yields different correct results.

**DSL-13 — Performance Target (SHOULD)**
A typical expression (5–10 nodes in AST) SHOULD evaluate in under 10 microseconds on commodity hardware.
*Acceptance:* Benchmark suite measures and reports against this target.

---

## Stage 8 — Lua Script Execution

**Goal:** Embedded LuaJIT runtime with sandboxing, capability enforcement, and resource limits. Used for moderate-complexity logic generated by the Developer Agent.

### Embedding

**LUA-01 — LuaJIT Integration (MUST)**
The platform MUST embed LuaJIT and expose it through Zig C-interop. Linking MUST be static.
*Acceptance:* Platform binary depends on no external Lua shared library at runtime.

**LUA-02 — State Isolation (MUST)**
Each script execution MUST occur in a fresh `lua_State` or a fully reset state. State MUST NOT leak between script invocations.
*Acceptance:* Setting a global in one execution does not affect another.

### Sandboxing

**LUA-03 — Stdlib Restriction (MUST)**
The Lua sandbox MUST NOT load: `io`, `os`, `package`, `debug`. The sandbox MUST load only: `math`, `string`, `table`. Within loaded modules, MUST remove: `string.dump`, `os.execute` (if reachable), `loadstring`, `load`, `loadfile`, `dofile`.
*Acceptance:* Each forbidden function returns `nil` or raises a sandbox error when accessed from a script.

**LUA-04 — Bytecode Loading Disabled (MUST)**
The sandbox MUST refuse to load Lua bytecode; only source text MAY be loaded.
*Acceptance:* Attempt to load bytecode is rejected with error.

**LUA-05 — Host API Registration (MUST)**
The platform MUST register exactly the `platform.*` functions defined in Architecture §5.2 and no others. Each function MUST check the caller's capability grant before executing.
*Acceptance:* Calling `platform.call_service("X")` without `service:call:X` grant returns structured error.

### Capability Enforcement

**LUA-06 — Capability Check at Call Site (MUST)**
Every host function MUST check the script's declared capabilities before executing. Missing capability MUST raise a Lua error with structured details (function, capability required, capabilities granted).
*Acceptance:* Capability denial test for every host function.

**LUA-07 — Capability Manifest Validation (MUST)**
On script load, the platform MUST validate the script's manifest against the script artifact. Manifest hash MUST be recorded with each execution.
*Acceptance:* Modified manifest without re-registration is rejected.

### Resource Limits

**LUA-08 — Instruction Limit (MUST)**
Each script execution MUST have a configurable maximum instruction count. Exceeding the limit MUST terminate the script with a structured timeout error.
*Acceptance:* Infinite loop terminates within configured limit.

**LUA-09 — Memory Limit (MUST)**
Each script execution MUST have a configurable memory limit. Allocations exceeding the limit MUST fail gracefully and terminate the script.
*Acceptance:* Script attempting to allocate 1 GB with 16 MB limit fails cleanly.

**LUA-10 — Wall Clock Timeout (MUST)**
Each script execution MUST have a configurable wall clock timeout enforced by the host (not relying on Lua to cooperate).
*Acceptance:* Script that blocks on a host function MUST still be terminable.

### Host API

**LUA-11 — Variable Read/Write (MUST)**
`platform.read_variable(name)` MUST return the current value or `nil`. `platform.write_variable(name, value)` MUST stage a write; writes are applied atomically on script success and discarded on script failure.
*Acceptance:* Failed script does not leave partial variable writes in instance state.

**LUA-12 — Service Call (MUST)**
`platform.call_service(service_id, payload)` MUST invoke a registered service synchronously. Response MUST be returned as Lua table. Service call failures MUST return a structured error, not raise.
*Acceptance:* Calling a registered service round-trips through host.

**LUA-13 — Logging (MUST)**
`platform.log(level, message, context)` MUST emit a structured log entry tagged with the script's identity, instance ID, and trace ID.
*Acceptance:* Log entry appears with correct correlation IDs.

**LUA-14 — Time Source (MUST)**
`platform.now()` MUST return the platform's authoritative time as ISO 8601 UTC. Lua's `os.time` MUST NOT be available.
*Acceptance:* `os.time` is `nil`; `platform.now()` returns valid timestamp.

### Error Handling

**LUA-15 — Structured Failure (MUST)**
`platform.fail(reason, details)` MUST terminate the script and propagate a structured failure to the engine. The engine MUST record a SCRIPT_FAILED event and transition the instance per the node's error policy.
*Acceptance:* Test confirms structured failure produces expected event and routing.

**LUA-16 — Runtime Error Capture (MUST)**
Uncaught Lua errors MUST be captured by the host and converted to structured SCRIPT_ERROR events with stack trace, instruction count consumed, and capability state at failure.
*Acceptance:* Division by zero in script yields rich error report.

---

## Stage 9 — Wasm Module Execution

**Goal:** Embedded Wasmtime runtime executing compiled Wasm modules with strict capability sandboxing. Used for complex custom node types and integrations.

### Embedding

**WASM-01 — Wasmtime Integration (MUST)**
The platform MUST embed Wasmtime via its C API, linked statically into the platform binary.
*Acceptance:* No external Wasm runtime dependency at deploy time.

**WASM-02 — Module ABI (MUST)**
Every module loaded by the platform MUST export the functions defined in Architecture §5.3 (`init`, `execute`, `deinit`, `get_capabilities`). Modules missing required exports MUST be rejected at registration.
*Acceptance:* Registration of a module without `execute` export fails with structured error.

### Compilation Pipeline

**WASM-03 — Source Compilation Job (MUST)**
The platform MUST provide a compilation job that takes Zig source for a Wasm module and produces a validated `.wasm` artifact. The job MUST run out-of-band, not on the execution path.
*Acceptance:* Compilation request returns a job ID; completion notification carries artifact hash.

**WASM-04 — Compile Caching (MUST)**
Compiled `.wasm` artifacts MUST be cached in the repository keyed by source hash plus toolchain version. Equal sources MUST NOT be recompiled.
*Acceptance:* Submitting identical source twice produces one compilation.

**WASM-05 — Build Reproducibility (SHOULD)**
Compilation SHOULD be reproducible: same source + same toolchain version yields byte-identical `.wasm`.
*Acceptance:* Two compilations of same input produce identical bytes.

### Capability Sandboxing

**WASM-06 — Import Whitelist (MUST)**
The Wasmtime instance MUST provide only the host functions corresponding to capabilities declared in the module manifest. Imports outside the whitelist MUST cause instantiation to fail.
*Acceptance:* Module declaring `var:read` only cannot import `platform_call_service`.

**WASM-07 — No Filesystem Access (MUST)**
Wasm modules MUST NOT be granted WASI filesystem capabilities by default. Any future grant MUST be explicit in the capability manifest.
*Acceptance:* Module attempting to import `wasi:filesystem/types` is rejected.

**WASM-08 — Memory Isolation (MUST)**
Modules MUST execute in isolated linear memory. The host MUST validate all pointer/length pairs received from the module before dereferencing.
*Acceptance:* Malformed pointer from module yields structured trap, not host crash.

### Resource Limits

**WASM-09 — Fuel-Based Execution Limit (MUST)**
The host MUST enable Wasmtime's fuel mechanism (or equivalent) and set a per-invocation fuel budget. Exhaustion MUST terminate execution with a structured error.
*Acceptance:* Infinite loop terminates within budget.

**WASM-10 — Memory Cap (MUST)**
Linear memory growth MUST be capped per module instance. Attempt to grow beyond cap MUST trap.
*Acceptance:* Module attempting to allocate beyond cap traps cleanly.

**WASM-11 — Wall Clock Timeout (MUST)**
A per-invocation wall clock timeout MUST be enforced. Exceeding the timeout MUST interrupt execution.
*Acceptance:* Host-blocking call respects timeout.

### Host API Parity

**WASM-12 — Parity with Lua Host API (MUST)**
The semantic behaviour of `platform.read_variable`, `platform.write_variable`, `platform.call_service`, `platform.log`, `platform.now`, `platform.uuid`, `platform.fail` MUST be identical whether called from Lua or Wasm. Differences MUST be limited to ABI (string encoding, return shape).
*Acceptance:* Same test scenario passes against Lua implementation and Wasm implementation of an equivalent script.

### Module Lifecycle

**WASM-13 — Instance Pooling (SHOULD)**
The host SHOULD pool Wasm instances per module to amortise instantiation cost, while ensuring per-invocation isolation (memory reset between invocations).
*Acceptance:* Repeated invocation of same module shows reduced p50 latency vs cold instantiation.

**WASM-14 — Hot Reload (MUST)**
When a new version of a module is activated, in-flight invocations of the prior version MUST complete normally. New invocations MUST use the new version.
*Acceptance:* Activation during execution does not interrupt running invocations.

---

## Stage 10 — Platform Repository

**Goal:** Versioned, content-addressed artifact store. The source of truth for all platform artifacts (definitions, forms, scripts, modules, projections, tests).

### Storage Model

**REPO-01 — Content Addressing (MUST)**
Every artifact MUST be stored under a SHA-256 hash of its canonical content representation. Equal content MUST deduplicate.
*Acceptance:* Two uploads of identical content reference the same stored bytes.

**REPO-02 — Immutability (MUST)**
A stored artifact MUST NOT be modifiable. All changes produce new artifacts with new hashes.
*Acceptance:* Attempt to update an artifact in place returns error; PUT replacing returns a new hash.

**REPO-03 — Versioning (MUST)**
Each named artifact MAY have multiple versions. Versions are ordered. Each version references a specific artifact hash and optionally a parent version (for lineage).
*Acceptance:* History query returns ordered list with parent linkage.

**REPO-04 — Canonical Serialisation (MUST)**
JSON artifacts MUST be hashed after canonical serialisation (sorted keys, no insignificant whitespace, normalised number forms). The canonicaliser MUST be specified and tested.
*Acceptance:* Same logical content with different whitespace/key order produces same hash.

### Schema Registry

**REPO-05 — Form Schema Indexing (MUST)**
Every form schema artifact MUST be indexed by its field names, types, and labels for queryability by agents.
*Acceptance:* `schema_registry.search(field_type='currency')` returns all form schemas with currency fields.

**REPO-06 — Event Type Registry (MUST)**
Every event type used in any active definition MUST be registered with name, JSON schema, and producing definition(s).
*Acceptance:* Listing event types returns full set with schemas.

**REPO-07 — Service Catalog (MUST)**
External services callable by scripts MUST be registered with: service_id, endpoint URL, request schema, response schema, required auth method.
*Acceptance:* A script declaring `service:call:X` is rejected at registration if service X is not in the catalog.

### Activation

**REPO-08 — Atomic Activation (MUST)**
Activating a definition version MUST atomically activate all its dependent artifacts (forms, scripts, projections) in a single transaction. Partial activation MUST NOT be observable.
*Acceptance:* Concurrent reads during activation see either old version everywhere or new version everywhere.

**REPO-09 — Per-Tenant Activation (MUST)**
Activations MUST be scoped per tenant. The same artifact version MAY be active in one tenant and not another.
*Acceptance:* Activating in tenant A does not affect tenant B.

**REPO-10 — Activation History (MUST)**
Every activation MUST be recorded with: tenant, artifact version, activator identity, timestamp, rationale (free text from the activator).
*Acceptance:* Activation history query returns full chronological record.

### Repository API

**REPO-11 — Create Artifact (MUST)**
`POST /repository/artifacts` MUST accept content + kind, compute hash, deduplicate, return artifact descriptor.
*Acceptance:* Roundtrip create → get → equal content.

**REPO-12 — List Versions (MUST)**
`GET /repository/<kind>/<name>/versions` MUST return all versions in chronological order with metadata.
*Acceptance:* Versions list pagination + ordering tested.

**REPO-13 — Tenant Activations (MUST)**
`GET /tenants/<id>/activations` MUST return active versions per artifact name for that tenant.
*Acceptance:* Activations consistent with `POST .../activate` history.

**REPO-14 — Bulk Bundle Operations (SHOULD)**
The repository SHOULD support creating and activating an "artifact bundle" (multiple related artifacts) in a single transactional operation.
*Acceptance:* Developer Agent's bundle activates atomically or not at all.

---

## Stage 11 — Test Runner and Simulation Mode

**Goal:** Execute test scenarios against process definitions in isolation. Enable Developer Agent to verify generated artifacts before promotion.

### Simulation Mode

**SIM-01 — Simulation Tenant (MUST)**
Every platform deployment MUST provide an internal simulation execution context that is isolated from all real tenants. Simulation runs MUST NOT produce events visible in any real tenant's event store.
*Acceptance:* Simulation events are stored separately and not returned by tenant event queries.

**SIM-02 — Service Mocking (MUST)**
In simulation mode, calls to external services MUST be intercepted and answered from a scenario-supplied mock catalog. Real network calls MUST NOT occur during simulation.
*Acceptance:* Scenario specifying mock response for service X causes that mock to be returned, no network traffic.

**SIM-03 — Time Control (MUST)**
In simulation mode, `platform.now()` MUST return the scenario-controlled time, not wall clock time. Scenarios MAY advance time programmatically.
*Acceptance:* Scenario asserting time-dependent behaviour passes deterministically.

**SIM-04 — Deterministic UUIDs (MUST)**
In simulation mode, `platform.uuid()` MUST return deterministic UUIDs from a seeded sequence, not random values.
*Acceptance:* Same scenario produces same UUID sequence across runs.

### Scenario Format

**SIM-05 — Scenario Schema (MUST)**
Scenarios MUST conform to a stable JSON schema including: definition reference, initial variables, sequence of user actions, mocked service responses, expected events, expected final state.
*Acceptance:* Scenario schema is versioned and validated on submission.

**SIM-06 — Assertion Vocabulary (MUST)**
Scenarios MUST support assertions on: event sequence (with wildcards), final variable values, final instance status, task assignments, no-occurrence of forbidden events.
*Acceptance:* Each assertion type has dedicated tests.

### Test Execution

**SIM-07 — Scenario Runner (MUST)**
The platform MUST provide an API to run a scenario against a specific definition version and return a structured result (pass / fail per assertion, full event trace, timing).
*Acceptance:* `POST /test/run` with scenario + definition returns result.

**SIM-08 — Batch Execution (MUST)**
The runner MUST support batch execution of all scenarios for a definition version, with parallelism configurable per tenant.
*Acceptance:* Batch run of 100 scenarios completes in less time than sequential.

**SIM-09 — Test Result Storage (MUST)**
Test results MUST be stored as artifacts in the repository, linked to the definition version tested. Re-running tests does not delete prior results.
*Acceptance:* Test result history retrievable.

**SIM-10 — Failure Diagnostics (MUST)**
A failed scenario result MUST include: which assertion failed, expected vs. actual, full event trace up to failure, variable state at failure point.
*Acceptance:* Failure diagnostics enable agent to formulate a fix.

---

## Stage 12 — AI Agent Pipeline (DEFERRED)

**Status:** Specification withdrawn pending implementation of Stages 6.5 and 7–11.

**Rationale:** A prior draft of Stage 12 (35 requirements covering Architect / Developer / DevOps agents with detailed prompt structures, handoff schemas, and iteration loops) has been removed from this document. That draft was written before the platform's MCP surface (future Stage 14), Tier 4 LLM execution (future Stage 13), and the policy document silo (future Stage 15) were considered. Several Stage 12 design choices would foreclose those future stages or duplicate work they will absorb.

**Constraints preserved for the eventual re-specification:**
- The pipeline agents will be MCP clients of the platform, not architecturally privileged components
- The pipeline will operate over the Platform Repository (Stage 10) and Test Runner (Stage 11)
- Capability discipline, audit chaining, and human checkpoints remain non-negotiable
- The Architect Agent's tier assignment must apply the four-tier model from Architecture §5.4, including the irreversibility discriminator

**What to do in the interim:** Stages 6.5 and 7–11 do not depend on Stage 12. They can and should be implemented while Stage 12 is re-specified. When Stage 6.5 + 7–11 are operational, a fresh Stage 12 specification will be written informed by what was learned.

**For implementing agents:** Do not implement any AGT-*, ARC-*, DEV-*, OPS-*, QG-*, or X-AGT-* requirement. Those identifiers are reserved but their content is withdrawn. Treat the agent pipeline as an out-of-scope concern for current work.

---

## Cross-Cutting Requirements

These apply across all stages above.

**XC-01 — Trace Propagation (MUST)**
A `trace_id` originating at the API request boundary (REST entry point, scheduler firing, or future MCP tool call) MUST propagate through every system action including database writes (where supported), script executions, and downstream service calls.
*Acceptance:* End-to-end trace query returns coherent timeline.

**XC-02 — Audit Immutability (MUST)**
Audit entries MUST be append-only and cryptographically chained (each entry includes hash of prior). Tampering with prior entries MUST be detectable.
*Acceptance:* Audit chain validation catches simulated tampering.

**XC-03 — Configuration in Repository (MUST)**
Platform configuration (capability defaults, tier-selection rules, budget limits, monitoring thresholds) MUST be stored as artifacts in the repository, versioned and activated like any other artifact.
*Acceptance:* Configuration changes follow the same activation flow as definitions.

**XC-04 — Kernel Determinism (MUST)**
The platform kernel paths — event append, state transition, scheduler firing, task activation, audit chaining — MUST NOT make LLM calls. The kernel is deterministic by design. LLM execution is permitted only within nodes whose execution tier is explicitly Tier 4 (see Architecture §5.4, introduced as a future stage). Any future Tier 4 implementation MUST sit alongside Tiers 1–3, not inside the kernel.
*Acceptance:* Static analysis of kernel modules (event store writer, scheduler, transition engine, audit chain writer) shows no LLM API calls. Tier 4 calls, when introduced, are scoped strictly to node-level execution.

**XC-05 — Deterministic Replay for Non-LLM Tiers (SHOULD)**
Given an instance's event log and the snapshotted definition + script versions, replaying the instance through Tier 1, 2, and 3 nodes SHOULD produce identical state at every step. Tier 4 nodes, when present, replay from their recorded output (the LLM is not re-invoked); the audit log captures the original LLM response as the canonical result for replay.
*Acceptance:* Replay test compares state at each event boundary to original. Tier 4 nodes' replay uses recorded outputs.

**XC-06 — Backwards Compatibility (MUST)**
A new platform version MUST be able to load and continue all instances created by the prior platform version. Definition format changes MUST be migration-pathed.
*Acceptance:* Upgrade test loads pre-upgrade instances and continues them.

---

## Appendix A — Requirement Counts

| Stage | MUST | SHOULD | COULD | Total |
|---|---:|---:|---:|---:|
| 6.5 — Identity Provider Integration | 30 | 4 | 0 | 34 |
| 7 — Expression DSL | 11 | 2 | 0 | 13 |
| 8 — Lua Execution | 14 | 0 | 0 | 14 |
| 9 — Wasm Execution | 13 | 1 | 0 | 14 |
| 10 — Platform Repository | 13 | 1 | 0 | 14 |
| 11 — Test Runner | 10 | 0 | 0 | 10 |
| 12 — Agent Pipeline | — | — | — | (deferred) |
| Cross-cutting | 5 | 1 | 0 | 6 |
| **Total (in-scope)** | **96** | **9** | **0** | **105** |

---

## Appendix B — Open Questions

These remain to be resolved by design notes before or during implementation. They are referenced here so implementing agents know to ask rather than guess.

1. **Wasm distribution.** For modules above a size threshold, do we stream from object storage or inline in repository? Threshold value?
2. **Cross-tenant artifact sharing.** Global vs. per-tenant copy semantics for shared artifacts?
3. **Human escape hatches.** When Developer Agent exhausts iterations, can a human directly edit the bundle and resubmit, or must they fix via the Architect Agent?
4. **DSL extension policy.** Conditions under which new built-in functions are added vs. forcing escalation to Lua?
5. **Idempotency retention.** How long are idempotency keys retained?
6. **Multi-LLM support.** Is the agent runtime tied to one LLM provider or designed for substitution?
7. **Concurrent pipeline runs.** Are pipeline runs for the same definition serialised, or do we permit concurrent runs with merge conflict resolution at activation time?

---

## Document Status

This document is **0.2-draft**. Implementing agents may begin work on stages where requirements are marked MUST. SHOULD-only sections may be deferred. Discrepancies, ambiguities, and proposed amendments should be raised as discrepancy reports referencing requirement IDs.
