# Test Spec: UAT-TM-02 - Realm-aware Keycloak Token Resolution

**Requirement:** UAT-TM-02 - Token helper functions support tenant realm selection, defaulting to bpm-default when realm is omitted.
**Priority:** MUST
**Test layer:** unit-like helper check, e2e helper integration

## Test Cases

### TC-UAT-TM-02-01: keycloakTokenUrl builds default and custom realm token URLs
**Given:** Pipeline helper module is loaded.
**When:** keycloakTokenUrl() is called with no realm and with 'swiftroute'.
**Then:** Generated endpoints target /realms/bpm-default/... and /realms/swiftroute/... respectively.
**Layer:** unit-like helper check
**Acceptance criterion mapped:** deterministic token endpoint generation for default and tenant realm paths
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-02-01)

### TC-UAT-TM-02-02: getKeycloakToken applies requested realm and returns realm-specific auth semantics
**Given:** Backend and Keycloak are reachable with bpm-default and swiftroute realms.
**When:** getKeycloakToken(request) succeeds for default realm and getKeycloakToken(request, 'admin-user', 'admin-pass', 'swiftroute') is executed.
**Then:** Default realm token issuer contains /realms/bpm-default, and the swiftroute call returns Keycloak invalid_grant (401) rather than a missing-realm failure; an unknown realm returns 404.
**Layer:** e2e helper integration
**Acceptance criterion mapped:** realm parameter flows through token retrieval and changes endpoint-level Keycloak behavior
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-02-02)

## Notes

- This requirement validates helper behavior only; it does not change application UI behavior.
- Integration coverage is direct Keycloak call coverage and requires BPM_IDP_BASE_URL to resolve correctly.
