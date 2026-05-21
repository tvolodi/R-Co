---
id: TK-UI-04
title: Complete task
stage: F4
priority: MUST
status: DRAFT
type: frontend
---

# TK-UI-04 — Complete task `[MUST]`

> A "Complete" button SHALL collect the form field values as the output variables map and call `POST /tasks/:id/complete`. On success, the task is removed from the inbox and a success toast is shown. On server-side error (e.g. variable schema violation), the error is shown inline.

**See:** EE-04 (`POST /tasks/:id/complete` with output_variables), EE-09 (variable merge on server side), EE-10 (schema violation error path — error shown inline), TK-UI-03 (form fields collected here)
