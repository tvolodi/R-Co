---
id: IN-UI-10
title: History scrubber
stage: F3
priority: SHOULD
status: DRAFT
type: frontend
---

# IN-UI-10 — History scrubber `[SHOULD]`

> The History tab SHALL include a sequence-number scrubber that allows the operator to view the reconstructed instance state at any past event (calling `GET /instances/:id/history?to_seq=N`). The read-only canvas SHALL reflect the state at the selected point in time.

**See:** EE-11 (state reconstruction from event log), API-05 (`GET /instances/:id/history` with sequence filter), IN-UI-05 (History tab this scrubber lives on), PD-UI-15 (read-only canvas updated to past state)
