---
id: DLQ-UI-05
title: DLQ depth indicator
stage: F6
priority: SHOULD
status: DRAFT
type: frontend
---

# DLQ-UI-05 — DLQ depth indicator `[SHOULD]`

> The DLQ navigation entry SHOULD display a badge with the count of PENDING items. The badge SHALL be amber if the count is greater than zero, and red if the count exceeds a configured alert threshold.

**See:** EXT-03 (DLQ PENDING status), API-08 (`GET /dlq?status=PENDING&count=true`), FNFR-02 (timely count update), DLQ-UI-01 (the DLQ list page)
