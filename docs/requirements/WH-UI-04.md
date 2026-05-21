---
id: WH-UI-04
title: Delivery log
stage: F6
priority: SHOULD
status: DRAFT
type: frontend
---

# WH-UI-04 — Delivery log `[SHOULD]`

> Each webhook subscription detail view SHOULD show recent delivery attempts with columns: status (success/failed), HTTP response code, timestamp. Failed deliveries SHALL be visually highlighted.

**See:** EXT-01 (delivery attempt model), EXT-04 (retry policy — failure history visible here), API-07 (`GET /webhooks/:id/deliveries`), WH-UI-01 (detail accessed from subscription list)
