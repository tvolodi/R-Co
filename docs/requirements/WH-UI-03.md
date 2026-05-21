---
id: WH-UI-03
title: Pause / resume subscription
stage: F6
priority: MUST
status: DRAFT
type: frontend
---

# WH-UI-03 — Pause / resume subscription `[MUST]`

> Paused subscriptions SHALL be visually distinct in the list (e.g. dimmed row, PAUSED badge). A one-click toggle SHALL call `POST /webhooks/:id/pause` or `POST /webhooks/:id/resume` as appropriate.

**See:** EXT-01 (subscription status field), API-07 (`POST /webhooks/:id/pause`, `POST /webhooks/:id/resume`), WH-UI-01 (subscription list where toggle lives)
