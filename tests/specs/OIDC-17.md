# Test Spec: OIDC-17 — Provisioning idempotency

**Requirement:** OIDC-17 — Mutating provisioning endpoints MUST accept idempotency keys and deduplicate retries by returning the original response.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-17-01: Same hash and key replays persisted response
**Given:** A reserved idempotency key and persisted final response
**When:** The same endpoint/key/hash is submitted again
**Then:** Replay returns hit with original response payload/status and no duplicate mutation intent
**Layer:** unit
**Acceptance criterion mapped:** Retry does not produce duplicate resources

### TC-OIDC-17-02: Same key with different hash returns conflict
**Given:** A reserved idempotency key for one request hash
**When:** A second request uses the same key but a different request hash
**Then:** Idempotency conflict is returned
**Layer:** unit
**Acceptance criterion mapped:** Behavior matches ES-03 conflict semantics

### TC-OIDC-17-03: Ledger unique index enforces dedup key at persistence layer
**Given:** A real PostgreSQL database with idp_operation_ledger
**When:** Two rows are inserted with same endpoint_fingerprint and idempotency_key
**Then:** The second insert fails due to uniqueness constraint
**Layer:** integration
**Acceptance criterion mapped:** Duplicate submissions are deduplicated by key
