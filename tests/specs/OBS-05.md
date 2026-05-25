# Test Spec: OBS-05 — Dead letter queue

**Requirement:** OBS-05 — Events or timer firings that fail processing after N retries (default 3) are moved to DLQ with full context, and PROCESS_OPERATOR+ can inspect/retry/discard via API.
**Priority:** MUST
**Test layer:** integration

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Exhausted retries move item to DLQ with full context fields (payload, instance_id, error chain, timestamps) | TC-OBS-05-INT-01 |
| `GET /dlq` requires operator role and supports deterministic pagination | TC-OBS-05-INT-01 |
| `GET /dlq` filter by `item_type` | TC-OBS-05-INT-01 |
| `GET /dlq` filter by `instance_id` | TC-OBS-05-INT-01 |
| `POST /dlq/:id/retry` requires operator role | TC-OBS-05-INT-02 |
| `POST /dlq/:id/retry` on CANCELLED instance returns 409 and discards item | TC-OBS-05-INT-02 |
| `POST /dlq/:id/retry` success resets retry count and removes DLQ item | TC-OBS-05-INT-02 |
| Retry success path emits retry audit context and keeps ACTIVE instance runnable/resumed path | TC-OBS-05-INT-02 |
| `POST /dlq/:id/discard` requires operator role | TC-OBS-05-INT-03 |
| `POST /dlq/:id/discard` removes item and appends OBS-03 audit in same transaction | TC-OBS-05-INT-03 |
| Discard path rollback on audit append failure keeps DLQ item intact | TC-OBS-05-INT-03 |

## Test Cases

### TC-OBS-05-INT-01: Exhausted retries persist full context and GET /dlq supports auth + pagination + filters
**Given:** deterministic DLQ fixtures for SERVICE_TASK, WEBHOOK, and TIMER failures inserted through `moveToDlq` with retry limit exhausted
**When:** list endpoint is called by non-operator and operator actors, then paged and filtered by `item_type` and `instance_id`
**Then:** non-operator receives `403`; operator receives paginated deterministic results; continuation cursor returns next page without overlap; filtered queries return only matching rows; persisted SERVICE_TASK row contains required full-context fields
**Layer:** integration
**Acceptance criterion mapped:** DLQ transition and context persistence; GET auth/pagination/filtering behavior

### TC-OBS-05-INT-02: Retry endpoint enforces auth, handles CANCELLED conflict path, and succeeds for ACTIVE instance
**Given:** one CANCELLED instance DLQ item and one ACTIVE instance DLQ item
**When:** retry is invoked by non-operator, then by operator for both items
**Then:** non-operator receives `403`; CANCELLED item returns `409` and is discarded; ACTIVE item returns `202` with retry count reset semantics, DLQ row removed, retry audit appended, and instance remains ACTIVE (resume-capable path)
**Layer:** integration
**Acceptance criterion mapped:** retry semantics, auth enforcement, CANCELLED conflict behavior, success-path removal/resume semantics

### TC-OBS-05-INT-03: Discard endpoint enforces auth and transactional OBS-03 audit behavior
**Given:** two DLQ items (normal path and fault-injection path)
**When:** discard is invoked by non-operator and operator; then audit insert failure is forced by trigger
**Then:** non-operator receives `403`; normal discard returns `200` and appends `dlq.discard` audit record; forced audit failure returns `500` and keeps DLQ row (rollback)
**Layer:** integration
**Acceptance criterion mapped:** discard auth and transactional audit guarantees
