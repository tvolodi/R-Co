---
id: ADM-UI-07
title: Issue token
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-07 — Issue token `[MUST]`

> An "Issue Token" form SHALL collect: target user, role set, and optional expiry date, then call `POST /tokens`. The generated token value SHALL be shown exactly once in a modal with a copy button and a "will not be shown again" warning. Closing the modal does not allow retrieval of the token.

**See:** IDN-04 (`POST /tokens` — server returns raw value once), ADM-UI-06 (new row appears in token list after issue), FNFR-06 (no secrets stored in UI — token cleared from state after modal close)
