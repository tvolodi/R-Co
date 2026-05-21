---
id: PD-UI-04
title: Create definition
stage: F2
priority: MUST
status: DRAFT
type: frontend
---

# PD-UI-04 — Create definition `[MUST]`

> A "New Definition" button SHALL open a form modal for entering name, version string, and description. On submit, it calls `POST /definitions` and navigates to the Process Designer canvas for the new DRAFT.

**See:** PD-01 (`POST /definitions` creates a DRAFT), PD-UI-09 (canvas opened after creation), API-07 (validation errors from server shown inline)
