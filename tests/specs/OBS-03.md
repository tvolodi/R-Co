# Test Spec: OBS-03 — Audit log

**Requirement:** OBS-03 — All state-changing API actions SHALL be recorded in an audit log with actor_id, action, resource_type, resource_id, timestamp, and before/after state diff.
**Priority:** MUST
**Test layer:** integration

## Requirement Traceability

| Requirement clause | Test case IDs |
|---|---|
| Successful state-changing writes produce audit records with required fields | TC-OBS-03-INT-01 |
| Read-only GET requests do not produce audit records | TC-OBS-03-INT-02 |
| Audit insert failure rolls back whole business write transaction | TC-OBS-03-INT-03 |
| Audit records are immutable (no modify/delete path) | TC-OBS-03-INT-04 |
| GET /audit supports actor/resource/time filters | TC-OBS-03-INT-05 |
| GET /audit API-06-compatible pagination and deterministic ordering | TC-OBS-03-INT-05 |
| Canceled-token post-auth action is still audited | TC-OBS-03-INT-06 |

## Test Cases

### TC-OBS-03-INT-01: State-changing writes emit required audit fields
**Given:** deterministic fixture entities for definition and token resources
**When:** create/update/delete state-changing writes are executed
**Then:** an audit record is written for each write and each record includes non-empty `audit_id`, `action`, `resource_type`, `resource_id`, `timestamp`, and expected `before_state`/`after_state` semantics
**Layer:** integration
**Acceptance criterion mapped:** state-changing writes create audit records with complete contract fields

### TC-OBS-03-INT-02: Read-only GET operations do not emit new audit records
**Given:** an existing resource with a known audit count
**When:** read-only operations are executed (`getById`, `GET /audit` list)
**Then:** audit count for that resource remains unchanged
**Layer:** integration
**Acceptance criterion mapped:** read-only requests MUST NOT generate audit records

### TC-OBS-03-INT-03: Audit persistence failure rolls back business mutation
**Given:** a deterministic fault-injection trigger that raises on `audit_entries` insert
**When:** a state-changing write is attempted
**Then:** the write fails and neither the business row nor the audit row is persisted
**Layer:** integration
**Acceptance criterion mapped:** audit write is atomic with state change; failure rolls back full transaction

### TC-OBS-03-INT-04: Audit records are immutable
**Given:** an existing audit record
**When:** update and delete operations are attempted on `audit_entries`
**Then:** both operations fail and the original row remains unchanged
**Layer:** integration
**Acceptance criterion mapped:** no modify/delete path for audit records

### TC-OBS-03-INT-05: GET /audit filtering, ordering, and pagination are deterministic
**Given:** deterministic audit rows with controlled timestamps and IDs
**When:** `GET /audit` is requested with `actor_id`, `resource_type`, `resource_id`, `from`, `to`, and paginated with cursor + `page_size`
**Then:** only matching rows are returned, primary order is `timestamp DESC`, tie-breaker order is `audit_id DESC`, and next-page cursor advances without duplicates
**Layer:** integration
**Acceptance criterion mapped:** GET /audit filtering and API-06-compatible pagination/ordering behavior

### TC-OBS-03-INT-06: Canceled-token action remains auditable post-auth
**Given:** authenticated actor context captured in transaction-local `bpm.actor_id`
**When:** token revoke/cancel action is executed successfully
**Then:** an audit row is persisted with `resource_type=token`, `action=token.revoke`, and `actor_id` equal to captured actor context
**Layer:** integration
**Acceptance criterion mapped:** canceled-token post-auth action auditing