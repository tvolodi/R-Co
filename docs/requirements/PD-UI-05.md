---
id: PD-UI-05
title: Lifecycle actions
stage: F2
priority: MUST
status: DRAFT
type: frontend
---

# PD-UI-05 — Lifecycle actions `[MUST]`

> Each definition row SHALL surface contextual actions based on current status: DRAFT → [Edit, Activate, Delete]; ACTIVE → [View, Deprecate]; DEPRECATED → [View, Archive]; ARCHIVED → [View]. Actions unavailable for the current user's role SHALL be hidden.

**See:** PD-04 (definition lifecycle transitions), API-02 (CRUD endpoints for each action), IDN-03 (role permission matrix — actions hidden by role), PD-UI-06 (activation confirmation dialog)
