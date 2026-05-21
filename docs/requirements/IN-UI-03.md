---
id: IN-UI-03
title: Start instance
stage: F3
priority: MUST
status: DRAFT
type: frontend
---

# IN-UI-03 — Start instance `[MUST]`

> A "Start Instance" button SHALL open a form where the user selects a definition (by name, active version auto-selected), enters an optional correlation key, and provides an initial variables JSON object (with a JSON editor widget).

**See:** EE-01 (`POST /instances` start logic), PD-07 (`GET /definitions/active/:name` to auto-select active version), API-03 (instance management endpoint)
