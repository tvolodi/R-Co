---
id: TK-UI-01
title: Task inbox
stage: F4
priority: MUST
status: DRAFT
type: frontend
---

# TK-UI-01 — Task inbox `[MUST]`

> The inbox SHALL show a list of tasks filterable by: My Tasks (assigned to me), My Group Tasks (assigned to a group I belong to), All Tasks (operator+). Columns: task name, instance ID, status, assignee, created time.

**See:** API-04 (`GET /tasks` with `assignee_id`, `status`, `instance_id` filters), IDN-02 (group membership determines "My Group Tasks"), IDN-03 (TASK_WORKER sees own tasks only; row-level filter), TK-UI-02 (task detail panel on click)
