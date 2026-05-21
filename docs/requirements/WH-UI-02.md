---
id: WH-UI-02
title: Create webhook subscription
stage: F6
priority: MUST
status: DRAFT
type: frontend
---

# WH-UI-02 — Create webhook subscription `[MUST]`

> A "New Subscription" form SHALL collect: target URL and event types (multi-select checkboxes). Submitting calls `POST /webhooks`. The server-generated HMAC signing secret SHALL be shown once in a modal with a copy button and "will not be shown again" warning.

**See:** EXT-01 (HMAC secret generated server-side), EXT-02 (event type enum — shown as checkbox options), API-07 (`POST /webhooks`), FNFR-06 (secret cleared from UI state after modal close)
