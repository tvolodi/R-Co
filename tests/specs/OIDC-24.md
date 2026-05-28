# Test Spec: OIDC-24 — Federated user attribute mapping

**Requirement:** OIDC-24 — Adapter SHOULD support configurable claim-to-attribute mapping with graceful handling of unmapped attributes.

**Priority:** SHOULD
**Test layer:** unit

## Test Cases

### TC-OIDC-24-01: Unknown claims are preserved and do not cause failure
**Given:** Mapping config and inbound claims with unmapped fields
**When:** applyFederationMapping is executed
**Then:** Mapping completes successfully and unmapped claims are handled gracefully
**Layer:** unit
**Acceptance criterion mapped:** Unmapped attributes are ignored gracefully

### TC-OIDC-24-02: Mapping config structure can be supplied per realm/federation
**Given:** FederationMappingConfig with attribute and role rules JSON
**When:** Mapping is invoked
**Then:** Configuration is accepted without runtime schema failure in mapping function
**Layer:** unit
**Acceptance criterion mapped:** Documented mapping configuration can be applied
