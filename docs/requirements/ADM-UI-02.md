---
id: ADM-UI-02
title: Create user
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-02 — Create user `[MUST]`

> A "New User" modal or page SHALL collect: username, display name, email, and initial role assignments. Submitting calls `POST /users`.

**See:** IDN-01 (user model fields), API-10 (`POST /users`), IDN-04 (initial password handling — service generates or prompts for reset), ADM-UI-01 (returns to user list on success)
