---
id: EXT-02
title: Webhook event dispatch
stage: 6
priority: MUST
status: RELEASED
---

# EXT-02 — Webhook event dispatch `[MUST]`

> The platform SHALL dispatch outbound webhook calls on: instance started, instance completed, instance errored, task activated, task completed. Subscribers register via API with a target URL and event filter. Delivery is **at-least-once**: failed deliveries are retried with exponential back-off up to 5 attempts. After 5 failures, the subscription is paused and the operator is notified via OBS-06. Subscribers SHOULD verify a shared HMAC-SHA256 signature in the `X-BPM-Signature` request header.

**Acceptance Criteria:**
- `POST /webhooks/subscriptions` creates a subscription with: `target_url`, `event_types` (array), optional `secret` for HMAC. Returns HTTP 201.
- GIVEN a matching event occurs, WHEN the platform dispatches the webhook, THEN it sends an HTTP POST to `target_url` with: JSON body (event type, instance_id, timestamp, payload), `X-BPM-Signature: sha256=<HMAC-SHA256-of-body>` header (if `secret` is configured).
- Delivery is at-least-once: if the target returns non-2xx or times out, the platform retries with exponential backoff, up to 5 attempts.
- GIVEN 5 consecutive delivery failures, THEN the subscription status is set to PAUSED and an OBS-06 alert is triggered.
- `GET /webhooks/subscriptions` and `DELETE /webhooks/subscriptions/:id` are provided. Requires PLATFORM_ADMIN.

**See:** OBS-06 (alerts on subscription pause), OBS-03 (subscription creation/deletion is audited), EXT-01 (SERVICE_TASK is a different outbound mechanism)

**Edge cases:**
- Target URL returns HTTP 200 but with an invalid JSON body: treated as a successful delivery (HTTP 2xx received).
- Same event triggers multiple subscriptions: each subscription has its own independent retry counter.
