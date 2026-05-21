---
id: ADM-UI-04
title: Deactivate user
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-04 — Deactivate user `[MUST]`

> A "Deactivate" action SHALL set the user's status to INACTIVE. A confirmation dialog SHALL note that any active tasks remain assigned but the user cannot complete them until reactivated.

**See:** IDN-01 (INACTIVE status field), API-10 (`PATCH /users/:id` — sets status=INACTIVE), ADM-UI-03 (deactivate accessible from edit page), IDN-04 (token revocation not automatic — admin must also revoke tokens)
