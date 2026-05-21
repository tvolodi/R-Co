---
id: DLQ-UI-01
title: DLQ list
stage: F6
priority: MUST
status: DRAFT
type: frontend
---

# DLQ-UI-01 — DLQ list `[MUST]`

> The Dead Letter Queue page SHALL display a paginated table with columns: source type badge (event/timer/webhook), related instance (link to IN-UI-04), failure reason (truncated), retry count, created time, status.

**See:** EXT-03 (DLQ model — source_type, failure_reason, retry_count, status), API-08 (`GET /dlq` with status and source_type filters), DLQ-UI-02 (detail panel on row click)
