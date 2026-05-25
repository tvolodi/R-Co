# Test Spec: EXT-02 — Webhook event dispatch

**Requirement:** EXT-02 — The platform SHALL dispatch outbound webhook calls on: instance started, instance completed, instance errored, task activated, task completed. Subscribers register via API with a target URL and event filter. Delivery is at-least-once: failed deliveries are retried with exponential back-off up to 5 attempts. After 5 failures, the subscription is paused and the operator is notified via OBS-06. Subscribers SHOULD verify a shared HMAC-SHA256 signature in the X-BPM-Signature request header.
**Priority:** MUST
**Test layer:** unit, integration

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Module touchpoints |
|---|---|---|---|
| POST /webhooks/subscriptions creates subscription with target_url, event_types, optional secret and returns HTTP 201 | TC-EXT-02-U01, TC-EXT-02-U02, TC-EXT-02-INT-01 | unit, integration | src/api/routes/webhooks.zig, src/webhook/subscription_store.zig, migrations/023_ext02_webhook_event_dispatch.sql |
| GET /webhooks/subscriptions and DELETE /webhooks/subscriptions/:id are provided and require PLATFORM_ADMIN | TC-EXT-02-U03, TC-EXT-02-INT-02, TC-EXT-02-INT-03 | unit, integration | src/api/routes/webhooks.zig, src/webhook/subscription_store.zig |
| Matching event dispatch sends HTTP POST with JSON body contract fields and required delivery headers | TC-EXT-02-U04, TC-EXT-02-U05, TC-EXT-02-INT-04 | unit, integration | src/webhook/dispatcher.zig, src/webhook/subscription_store.zig |
| Optional HMAC signature behavior: X-BPM-Signature is present only when secret is configured and format is sha256=<digest> | TC-EXT-02-U06, TC-EXT-02-U07, TC-EXT-02-INT-05 | unit, integration | src/webhook/signing.zig, src/webhook/dispatcher.zig |
| At-least-once delivery retries non-2xx and timeout/transport failures with exponential backoff up to 5 attempts | TC-EXT-02-U08, TC-EXT-02-INT-06 | unit, integration | src/webhook/dispatcher.zig, migrations/023_ext02_webhook_event_dispatch.sql |
| After 5 consecutive failures, subscription transitions to PAUSED and emits OBS-06 alert trigger | TC-EXT-02-U09, TC-EXT-02-INT-07 | unit, integration | src/webhook/dispatcher.zig, src/obs/alerts.zig, src/webhook/subscription_store.zig |
| OBS-03 auditing for subscription create/delete in same transaction as state mutation | TC-EXT-02-U10, TC-EXT-02-INT-08 | unit, integration | src/webhook/subscription_store.zig, src/api/routes/webhooks.zig |
| Edge: HTTP 2xx with invalid/non-JSON response body is treated as delivery success | TC-EXT-02-U11, TC-EXT-02-INT-09 | unit, integration | src/webhook/dispatcher.zig |
| Edge: same source event fan-out to multiple subscriptions maintains independent retry counters and pause outcomes per subscription | TC-EXT-02-U12, TC-EXT-02-INT-10 | unit, integration | src/webhook/dispatcher.zig, src/webhook/subscription_store.zig, migrations/023_ext02_webhook_event_dispatch.sql |

---

## Unit Test Cases

Unit coverage is intended for helper/classification logic and route-level authorization/validation behavior in source-local test blocks and dedicated unit suites.

### TC-EXT-02-U01: Create request validation enforces URL policy and non-empty event_types
**Given:** create payload variants with missing URL, invalid scheme, empty event_types, and valid combinations
**When:** create request validation is executed in production and non-production modes
**Then:** invalid payloads are rejected, and valid payloads pass with deterministic error categories
**Layer:** unit
**Acceptance criterion mapped:** create API payload validation for target_url and event_types

### TC-EXT-02-U02: Event type parsing accepts only EXT-02 allowed wire values
**Given:** event type strings from request payloads
**When:** event type parsing and normalization run
**Then:** only instance.started, instance.completed, instance.errored, task.activated, and task.completed are accepted
**Layer:** unit
**Acceptance criterion mapped:** create API event filter contract

### TC-EXT-02-U03: Route authorization enforces PLATFORM_ADMIN for POST/GET/DELETE
**Given:** caller contexts for PLATFORM_ADMIN and non-admin roles
**When:** route handlers evaluate authorization
**Then:** non-admin callers receive 403 and admin callers proceed to data-layer calls
**Layer:** unit
**Acceptance criterion mapped:** PLATFORM_ADMIN enforcement on all subscription APIs

### TC-EXT-02-U04: Dispatch payload builder emits deterministic envelope keys
**Given:** fixed webhook envelope input containing event_type, instance_id, timestamp, payload, trace_id
**When:** dispatcher builds outbound JSON body
**Then:** body contains event_type, instance_id, timestamp, payload with stable key contract and payload forwarding
**Layer:** unit
**Acceptance criterion mapped:** outbound JSON body contract

### TC-EXT-02-U05: Dispatch headers include delivery metadata and trace context
**Given:** fixed delivery_id and attempt number
**When:** dispatcher builds outbound request headers
**Then:** content-type, x-bpm-event-type, x-bpm-delivery-id, x-bpm-attempt, and x-trace-id are present and deterministic
**Layer:** unit
**Acceptance criterion mapped:** outbound header contract for dispatch attempts

### TC-EXT-02-U06: Signature helper returns sha256=<hex> format for non-empty secret
**Given:** fixed secret and fixed request body bytes
**When:** signature header is generated
**Then:** output begins with sha256= and contains lowercase hexadecimal digest bytes
**Layer:** unit
**Acceptance criterion mapped:** optional HMAC signature format contract

### TC-EXT-02-U07: Signature header is omitted when no secret is configured
**Given:** subscription rows with and without secret
**When:** dispatcher prepares outbound headers
**Then:** x-bpm-signature exists only for secret-configured subscriptions
**Layer:** unit
**Acceptance criterion mapped:** optional signature behavior

### TC-EXT-02-U08: Retry delay is exponential and capped for attempts 1..5
**Given:** base_ms=1000 and cap_ms=30000
**When:** retry delay is computed for attempts 1 through 5 and a high attempt index
**Then:** delays follow exponential growth and never exceed cap
**Layer:** unit
**Acceptance criterion mapped:** exponential backoff semantics

### TC-EXT-02-U09: Failure classification triggers pause at terminal attempt budget
**Given:** delivery attempts with non-2xx/transport failure outcomes and max_attempts=5
**When:** dispatcher updates retry state at each failure
**Then:** attempts 1..4 schedule retry and attempt 5 marks delivery exhausted and subscription PAUSED
**Layer:** unit
**Acceptance criterion mapped:** pause-on-5-failures semantics

### TC-EXT-02-U10: Create/delete audit payload shape is deterministic and atomic intent is preserved
**Given:** successful create and delete state transitions
**When:** audit payloads are constructed for OBS-03 records
**Then:** create uses before_state=null and after_state snapshot; delete uses before_state snapshot and after_state=null
**Layer:** unit
**Acceptance criterion mapped:** OBS-03 auditing behavior for create/delete

### TC-EXT-02-U11: HTTP 2xx with invalid or non-JSON response body is classified as success
**Given:** HTTP 200/204 responses with plain text, malformed JSON, or empty body
**When:** dispatcher evaluates delivery result
**Then:** delivery is treated as success and no retry is scheduled
**Layer:** unit
**Acceptance criterion mapped:** EXT-02 edge case for 2xx response body handling

### TC-EXT-02-U12: Retry counters are isolated per subscription for same source event
**Given:** fan-out of one source event to two subscription delivery rows
**When:** one subscription succeeds and the other fails repeatedly
**Then:** attempt_count/consecutive_failures mutate independently and success path does not reset sibling state
**Layer:** unit
**Acceptance criterion mapped:** EXT-02 edge case for per-subscription retry isolation

---

## Integration Test Cases

Integration coverage is planned against real PostgreSQL and deterministic local HTTP endpoints, with each scenario seeded and cleaned up independently.

### TC-EXT-02-INT-01: Admin create subscription returns 201 and persists normalized row
**Given:** PLATFORM_ADMIN actor and valid create payload with optional secret variant
**When:** POST /webhooks/subscriptions is executed
**Then:** response is 201 with subscription_id and persisted row has ACTIVE status, consecutive_failures=0, max_attempts=5
**Layer:** integration
**Acceptance criterion mapped:** POST subscription creation contract

### TC-EXT-02-INT-02: GET subscriptions is admin-only and redacts secret value
**Given:** seeded subscriptions with and without secret
**When:** GET /webhooks/subscriptions is called as admin and non-admin
**Then:** admin gets 200 items list including status/failure fields and no secret leakage; non-admin gets 403
**Layer:** integration
**Acceptance criterion mapped:** GET endpoint behavior and PLATFORM_ADMIN enforcement

### TC-EXT-02-INT-03: DELETE subscription is admin-only and removes row
**Given:** existing subscription row and both admin/non-admin actors
**When:** DELETE /webhooks/subscriptions/:id is called
**Then:** admin receives 204 and row is deleted; non-admin receives 403; deleting unknown id returns 404
**Layer:** integration
**Acceptance criterion mapped:** DELETE endpoint behavior and PLATFORM_ADMIN enforcement

### TC-EXT-02-INT-04: Matching lifecycle event fans out and emits contract-compliant request body/headers
**Given:** active subscription with event filter including emitted event_type and deterministic trace_id
**When:** event is enqueued and due deliveries are dispatched
**Then:** receiver captures POST containing required JSON body fields and headers x-bpm-event-type, x-bpm-delivery-id, x-bpm-attempt, x-trace-id
**Layer:** integration
**Acceptance criterion mapped:** payload/header contract for outbound delivery

### TC-EXT-02-INT-05: Signature header is present only for secret-configured subscription and matches body HMAC
**Given:** two subscriptions for same event, one with secret and one without
**When:** dispatch runs for one source event
**Then:** signed subscription request includes x-bpm-signature sha256 digest over exact body bytes; unsigned subscription omits signature header
**Layer:** integration
**Acceptance criterion mapped:** optional HMAC signature behavior

### TC-EXT-02-INT-06: Non-2xx and timeout failures retry with at-least-once semantics through attempt 5 budget
**Given:** deterministic endpoint that returns 500 or times out for first attempts
**When:** dispatcher loop processes due rows across retry windows
**Then:** attempt_count increments per failure, next_attempt_at follows exponential backoff schedule, and duplicate deliveries are allowed per at-least-once model
**Layer:** integration
**Acceptance criterion mapped:** retry/backoff and at-least-once semantics

### TC-EXT-02-INT-07: Fifth consecutive failure pauses subscription and emits OBS-06 alert event
**Given:** subscription configured to fail for five consecutive attempts and alerting hooks enabled in deterministic test mode
**When:** dispatcher reaches fifth failed attempt
**Then:** subscription status becomes PAUSED with paused_at set and webhook_subscription_paused alert emission is recorded
**Layer:** integration
**Acceptance criterion mapped:** pause-on-5-failures with OBS-06 trigger

### TC-EXT-02-INT-08: Create/delete operations write OBS-03 audit rows atomically
**Given:** admin actor and deterministic subscription create/delete flow
**When:** create and delete requests are executed
**Then:** audit_entries contain webhook_subscription.create and webhook_subscription.delete with required before/after semantics, and business write rolls back if audit write fails
**Layer:** integration
**Acceptance criterion mapped:** OBS-03 auditing for create/delete

### TC-EXT-02-INT-09: 2xx with invalid/non-JSON response body is success without retry
**Given:** endpoint returns HTTP 200 with plain text or malformed JSON body
**When:** dispatcher executes delivery
**Then:** delivery row is marked success/delivered, subscription consecutive_failures resets to 0, and no retry row update occurs
**Layer:** integration
**Acceptance criterion mapped:** explicit edge case for invalid-JSON 2xx success

### TC-EXT-02-INT-10: Same source event with multiple subscriptions keeps retry counters independent
**Given:** two active subscriptions matching same event where one endpoint returns 200 and the other returns 500 repeatedly
**When:** one fan-out event is enqueued and dispatched through retry cycles
**Then:** successful subscription stays ACTIVE with failures reset while failing subscription increments independent counters and may pause without affecting sibling delivery state
**Layer:** integration
**Acceptance criterion mapped:** explicit edge case for independent per-subscription retry counters

---

## Fixture Plan

| Fixture | Purpose | Used by |
|---|---|---|
| ext02_admin_actor | PLATFORM_ADMIN auth context for API calls | TC-EXT-02-INT-01, TC-EXT-02-INT-02, TC-EXT-02-INT-03, TC-EXT-02-INT-08 |
| ext02_non_admin_actor | PROCESS_OPERATOR context for authz denial checks | TC-EXT-02-INT-02, TC-EXT-02-INT-03 |
| ext02_subscription_payload_signed | Valid create payload with target_url, event_types, and secret | TC-EXT-02-INT-01, TC-EXT-02-INT-05 |
| ext02_subscription_payload_unsigned | Valid create payload without secret | TC-EXT-02-INT-01, TC-EXT-02-INT-05 |
| ext02_event_envelope_task_completed | Deterministic source event envelope and trace_id | TC-EXT-02-INT-04, TC-EXT-02-INT-05, TC-EXT-02-INT-10 |
| ext02_receiver_ok_json | Local HTTP receiver returning 200 JSON | TC-EXT-02-INT-04, TC-EXT-02-INT-10 |
| ext02_receiver_ok_invalid_json | Local HTTP receiver returning 200 malformed/non-JSON body | TC-EXT-02-INT-09 |
| ext02_receiver_fail_500 | Local HTTP receiver returning deterministic non-2xx | TC-EXT-02-INT-06, TC-EXT-02-INT-07, TC-EXT-02-INT-10 |
| ext02_receiver_timeout | Local HTTP receiver exceeding timeout budget | TC-EXT-02-INT-06 |
| ext02_alert_sink | Deterministic OBS-06 capture endpoint or in-memory alert adapter fixture | TC-EXT-02-INT-07 |
| ext02_audit_probe | Query helpers for audit_entries assertions | TC-EXT-02-INT-08 |
| ext02_db_tx_rollback | Per-test DB transaction rollback harness | All integration cases |

---

## Execution Targets For TEST-RUNNER

- zig build test (covers source-local unit tests in src/webhook/dispatcher.zig, src/webhook/subscription_store.zig, src/webhook/signing.zig and route-level unit checks)
- zig build test-integration (covers EXT-02 integration scenarios in the integration harness using real PostgreSQL and deterministic local webhook receivers)

## Coverage Notes

- Every EXT-02 acceptance criterion and both mandatory edge cases are mapped to explicit unit and integration test IDs.
- Retry isolation is specified as an observable data invariant at delivery-row and subscription-counter levels.
- All tests are deterministic: fixed payloads, fixed trace IDs, controlled local HTTP responders, and per-test DB cleanup.
