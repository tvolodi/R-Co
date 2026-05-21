---
id: TK-UI-06
title: Reassign task
stage: F4
priority: MUST
status: DRAFT
type: frontend
---

# TK-UI-06 — Reassign task `[MUST]`

> Operators SHALL be able to reassign a task to another user, group, or role via `POST /tasks/:id/reassign`. The reassign action opens a user/group/role search dialog.

**See:** API-04 (`POST /tasks/:id/reassign` — PROCESS_OPERATOR or above), IDN-01 (user search), IDN-02 (group search), IDN-03 (role permission matrix — TASK_WORKER cannot reassign)
