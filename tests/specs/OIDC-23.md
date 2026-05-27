# Test Spec: OIDC-23 — IDP federation support

**Requirement:** OIDC-23 — Adapter supports federation lifecycle (create/list/delete) with per-realm alias control and JIT linkage integration.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-23-01: Federation endpoint routes are declared for create/list/delete
**Given:** OpenAPI route descriptors
**When:** IDP federation paths are queried
**Then:** Create, list, and delete federation routes exist
**Layer:** unit
**Acceptance criterion mapped:** Federation added via API surface

### TC-OIDC-23-02: Active federation alias must be unique per realm
**Given:** Real PostgreSQL idp_federation_binding rows
**When:** Duplicate ACTIVE alias rows are inserted for same realm
**Then:** Second insert fails
**Layer:** integration
**Acceptance criterion mapped:** Federation lifecycle consistency for realm/provider alias

### TC-OIDC-23-03: Deleted federation alias can be recreated
**Given:** An ACTIVE alias changed to DELETED
**When:** A new ACTIVE row with same alias is inserted
**Then:** Insert succeeds
**Layer:** integration
**Acceptance criterion mapped:** Delete then recreate workflow is supported
