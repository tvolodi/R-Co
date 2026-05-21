---
id: IN-UI-07
title: Cancel instance
stage: F3
priority: MUST
status: DRAFT
type: frontend
---

# IN-UI-07 — Cancel instance `[MUST]`

> A Cancel button (operator+ role only) SHALL show a confirmation dialog and call `POST /instances/:id/cancel`. The UI SHALL update the status badge immediately (optimistic update with rollback on error).

**See:** EE-08 (`POST /instances/:id/cancel` — tasks, timers cancelled atomically), IDN-03 (PROCESS_OPERATOR or above required), API-03 (instance management endpoint), FNFR-05 (rollback error shown as recoverable message)
