---
id: TK-UI-08
title: Badge count
stage: F4
priority: SHOULD
status: DRAFT
type: frontend
---

# TK-UI-08 — Badge count `[SHOULD]`

> The Task Inbox navigation entry SHALL display a badge showing the count of pending tasks assigned to the current user (or their groups). The count SHALL poll every 30 seconds.

**See:** TK-UI-01 (the inbox whose count is shown), API-04 (`GET /tasks?assignee_id=me&status=PENDING&count=true`), FNFR-02 (responsive indicator for new work)
