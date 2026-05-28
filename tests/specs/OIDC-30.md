# Test Spec: OIDC-30 — Test token issuance helper

**Requirement:** OIDC-30 — Test helper MUST issue OIDC tokens for test flows and MUST be inaccessible in production builds.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-30-01: Helper rejects production environment
**Given:** Environment is production
**When:** Test token helper guard is evaluated
**Then:** HelperDisabledInProduction is returned
**Layer:** unit
**Acceptance criterion mapped:** Helper is absent in production path

### TC-OIDC-30-02: Password/client credential requests enforce required credentials
**Given:** Invalid helper requests with missing required credentials
**When:** Token issue function validates request
**Then:** MissingCredentials is returned
**Layer:** unit
**Acceptance criterion mapped:** Helper enforces request shape before token flow

### TC-OIDC-30-03: Integration path obtains token for test automation in non-production
**Given:** Development realm is available and helper is enabled in testing environment
**When:** Integration suite requests role-specific token
**Then:** Token is returned and accepted by protected API checks
**Layer:** integration
**Acceptance criterion mapped:** Integration tests authenticate via helper without manual token retrieval

## Planned test source and execution
- tests/unit/test_oidc30_test_token_helper.zig
- tests/integration/oidc31_end_to_end_auth_suite_test.zig
- Command: zig build test
- Command: zig build test-integration-oidc31
