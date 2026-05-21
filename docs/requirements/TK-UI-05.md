---
id: TK-UI-05
title: Claim task
stage: F4
priority: MUST
status: DRAFT
type: frontend
---

# TK-UI-05 — Claim task `[MUST]`

> For tasks assigned to a group or role (not yet personally assigned), a "Claim" button SHALL call `POST /tasks/:id/assign` with the current user's ID. Claimed tasks appear in "My Tasks".

**See:** API-04 (`POST /tasks/:id/assign`), IDN-02 (group membership determines eligibility to claim), TK-UI-01 (inbox view updated after claim)
