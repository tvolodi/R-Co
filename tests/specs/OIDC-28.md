# Test Spec: OIDC-28 — Local development realm

**Requirement:** OIDC-28 — Repository MUST provide docker-compose setup for Keycloak 26.x with seeded bpm-default realm, platform client, and three role-distinct users.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-28-01: Compose file defines Keycloak 26.x import path and startup contract
**Given:** Repository docker-compose artifact
**When:** Compose file is read
**Then:** Keycloak service uses 26.x image, import-realm startup command, and realm import volume path
**Layer:** unit
**Acceptance criterion mapped:** No manual post-start Keycloak configuration step

### TC-OIDC-28-02: Realm seed contains required users and role bindings
**Given:** infrastructure/keycloak/realms/bpm-default.json
**When:** Seed JSON is parsed
**Then:** admin-user, designer-user, and worker-user exist with PLATFORM_ADMIN, PROCESS_DESIGNER, and TASK_WORKER roles respectively
**Layer:** unit
**Acceptance criterion mapped:** Three test users with distinct role bindings are pre-seeded

### TC-OIDC-28-03: Local realm verification tooling passes against repository artifacts
**Given:** Compose and seed artifacts from the current branch
**When:** Development realm verifier runs in CI/local validation stage
**Then:** Tool reports success for keycloak service presence, seed validity, and seed wiring
**Layer:** integration
**Acceptance criterion mapped:** docker compose up path is immediately usable for authentication test setup

## Planned test source and execution
- tests/unit/test_oidc28_local_dev_realm.zig
- tests/integration/oidc31_end_to_end_auth_suite_test.zig
- Command: zig build test
- Command: zig build test-integration-oidc31
