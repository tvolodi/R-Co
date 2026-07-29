---
id: OBS-04
title: Instance timeline view
stage: 6
priority: MUST
status: RELEASED
---

# OBS-04 — Instance timeline view `[MUST]`

> The API SHALL provide `GET /instances/:id/timeline` returning a human-readable sequence of events, task completions, and actor actions, suitable for display in a monitoring UI.

**Acceptance Criteria:**
- `GET /instances/:id/timeline` returns HTTP 200 with events in ascending chronological order.
- Each timeline entry includes: `event_type`, `timestamp`, `actor_display_name` (or `"system"` for automated events), `description` (human-readable text), and relevant context fields (e.g. task_id, node_id).
- Results are paginated per API-06.
- Any authenticated role may access the timeline.
- HTTP 404 if the instance does not exist.

**See:** ES-02 (underlying event log), ES-07 (archived events included in timeline), API-06 (pagination), IDN-01 (actor display names resolved from user registry)

**Edge cases:**
- Instance created by an automated API token with no associated user: `actor_display_name = "system"` or the token's description.
- Timeline for a CANCELLED instance: returns complete event history including the `INSTANCE_CANCELLED` event.
