> **Extends:** API-10, adding a capacity-driven refusal distinct from rate limiting.

> When outbox depth is at or above the cap, external ingress SHALL be refused with HTTP 429 and header `Retry-After: 5`, returned by middleware before `BEGIN` is issued, before a pool connection is taken, and before the idempotency key is recorded. The response body SHALL be `{"error":"outbox_at_capacity","depth":<n>,"cap":<n>}`. A refused request SHALL leave the caller's idempotency key unused.

**Acceptance Criteria:**
- GIVEN depth is at the cap, WHEN an external caller posts to ingress with idempotency key K, THEN the response is 429 with `Retry-After: 5`, and no row for K exists in `plat_idempotency_key`.
- GIVEN the same caller retries with key K after the gate reopens, WHEN the request is handled, THEN it is processed as a first attempt and not as a replay of a request that never ran.
- GIVEN a refused request, WHEN the database is inspected, THEN no transaction was opened and no connection was taken from the pool for that request.
- GIVEN outbox capacity is reached, WHEN a refusal is emitted, THEN the status code is 429 and never 400, 500, or 503; capacity is a throttling condition, not a client error and not a server fault.
- GIVEN a 429 is emitted on this path without the `Retry-After` header, WHEN the response is validated, THEN it is recorded as a defect; the header is unconditional.
- Every refusal appends `EXECUTION_INGRESS_REFUSED` carrying tenant, depth, and cap.

**See:** OBP-01 (the depth this reads), OBP-03 (the internal counterpart), OBP-04, API-10, DB-02 (no pooled connection is taken by a refused request)
