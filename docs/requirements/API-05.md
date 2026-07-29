---
id: API-05
title: History endpoint
stage: 4
priority: MUST
status: RELEASED
---

# API-05 — History endpoint `[MUST]`

> `GET /instances/:id/history` SHALL return the full ordered event log for an instance, with optional filtering by event type and time range.

**Acceptance Criteria:**
- `GET /instances/:id/history` returns all events for the instance in ascending sequence order. HTTP 404 if instance not found.
- Optional query parameters: `event_type` (filter to a specific event type), `from` (ISO 8601 timestamp, inclusive), `to` (ISO 8601 timestamp, inclusive).
- Results are paginated per API-06.
- Each event in the response includes all fields from the event record (ES-01) plus the sequence number.
- Any authenticated role may access instance history.
- Archived events (ES-07) MUST be included in their correct sequence position.

**See:** ES-02 (ordered read backing this endpoint), ES-06 (timestamp filtering uses point-in-time query), API-06 (pagination)

**Edge cases:**
- Instance with no events: returns empty list, HTTP 200.
- `from` > `to`: HTTP 422.
