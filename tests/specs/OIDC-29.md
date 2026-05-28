# Test Spec: OIDC-29 — Realm seed as versioned artifact

**Requirement:** OIDC-29 — Realm export JSON used for development Keycloak seeding MUST be version-controlled and validated for import/drift checks.

**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-29-01: Seed JSON validates with required structural fields
**Given:** Seed JSON content
**When:** Realm seed validation executes
**Then:** Validation marks valid, importable, deterministic as true
**Layer:** unit
**Acceptance criterion mapped:** Seed artifact imports cleanly

### TC-OIDC-29-02: Drift detector flags digest mismatch
**Given:** Expected digest and runtime-exported JSON with changed content
**When:** Drift check executes
**Then:** Drift is detected
**Layer:** unit
**Acceptance criterion mapped:** Drift controls detect changes

### TC-OIDC-29-03: Seed file path in repository is used as source artifact
**Given:** Repository checkout
**When:** Seed file validator runs against infrastructure/keycloak/realms/bpm-default.json
**Then:** Validation succeeds from the versioned file location
**Layer:** unit
**Acceptance criterion mapped:** Version-controlled seed file is the canonical source

## Planned test source and execution
- tests/unit/test_oidc29_realm_seed.zig
- Command: zig build test
