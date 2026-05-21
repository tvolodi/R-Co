---
id: IN-UI-05
title: Event history tab
stage: F3
priority: MUST
status: DRAFT
type: frontend
---

# IN-UI-05 — Event history tab `[MUST]`

> The instance detail page SHALL include a History tab that calls `GET /instances/:id/history` and renders the ordered event log as a filterable table (filter by event type, time range). Raw JSON payload SHALL be expandable inline.

**See:** API-05 (`GET /instances/:id/history` with `event_type`, `from`, `to` filters), ES-07 (archived events included), API-06 (pagination), IN-UI-10 (history scrubber on this tab)
