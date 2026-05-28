# Test Spec: OIDC-19 — Provisioning audit

**Requirement:** OIDC-19 — Every adapter call is audited with actor/method/status/timing and sensitive fields redacted.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-19-01: Redaction masks secrets and credentials fields
**Given:** JSON payload containing client_secret, password, mfa_seed, token fields
**When:** Redaction is applied
**Then:** Sensitive values are replaced with "[REDACTED]" and originals do not appear
**Layer:** unit
**Acceptance criterion mapped:** No secret material appears in audit content

### TC-OIDC-19-02: Non-sensitive fields are preserved
**Given:** Payload with safe metadata and sensitive keys mixed
**When:** Redaction is applied
**Then:** Safe fields remain intact while only sensitive fields are replaced
**Layer:** unit
**Acceptance criterion mapped:** Audit retrieval preserves useful timeline context

### TC-OIDC-19-03: Audit table accepts redacted request/response payloads
**Given:** A real PostgreSQL database and redacted payload JSON
**When:** An idp_adapter_audit row is inserted
**Then:** Row persists required actor/method/status/timing/redaction fields
**Layer:** integration
**Acceptance criterion mapped:** Full provisioning timeline can be retrieved
