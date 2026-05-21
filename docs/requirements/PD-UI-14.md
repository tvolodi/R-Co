---
id: PD-UI-14
title: Save
stage: F2
priority: MUST
status: DRAFT
type: frontend
---

# PD-UI-14 — Save `[MUST]`

> A Save button SHALL call `PUT /definitions/:id` (full graph replacement for DRAFTs) and display a success toast or inline error. Unsaved changes SHALL be tracked; navigating away with unsaved changes triggers a confirmation dialog.

**See:** API-02 (`PUT /definitions/:id` — DRAFT only), PD-02 (server-side validation errors surfaced inline), PD-UI-13 (client-side validation must pass before save is enabled)
