---
id: DLQ-UI-03
title: Retry action
stage: F6
priority: MUST
status: DRAFT
type: frontend
---

# DLQ-UI-03 — Retry action `[MUST]`

> A "Retry" button on a DLQ item SHALL call `POST /dlq/:id/retry`. The item status SHALL transition to RETRYING and update in the list/detail view.

**See:** EXT-03 (`POST /dlq/:id/retry`), DLQ-UI-01 (list updated after retry), DLQ-UI-02 (detail panel where button lives), FNFR-05 (error shown if retry fails immediately)
