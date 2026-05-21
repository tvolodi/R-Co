---
id: ADM-UI-03
title: Edit user
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-03 — Edit user `[MUST]`

> A user detail/edit page SHALL allow editing: display name, email, status (ACTIVE/INACTIVE), group memberships, and role assignments. Changes call the appropriate `PATCH /users/:id` endpoint.

**See:** IDN-01 (user model), IDN-02 (group membership managed here), API-10 (`PATCH /users/:id`), ADM-UI-04 (deactivate action available on this page)
