---
id: ADM-UI-11
title: Audit log viewer
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-11 — Audit log viewer `[MUST]`

> The Admin section SHALL include a paginated, filterable audit log page. Filters: actor (user search), resource type, and time range. Each row SHALL expand to show a before/after state diff rendered as a JSON diff view.

**See:** OBS-06 (audit log model — actor, resource_type, before/after state), API-11 (`GET /audit` with filter and pagination params), IDN-03 (SYSTEM_ADMIN only), IDN-01 (actor display name lookup)
