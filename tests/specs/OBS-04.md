# Test Spec: OBS-04 — Instance timeline view

**Requirement:** OBS-04 — The platform SHALL provide `GET /instances/:id/timeline` returning a deterministic, ascending chronological timeline with actor display name resolution, human-readable descriptions, API-06 pagination semantics, archived-event inclusion, and full history for terminal/cancelled instances.
**Priority:** MUST
**Test layer:** unit, integration, frontend-unit

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Missing instance returns 404 | TC-OBS-04-INT-01 |
| Deterministic ascending chronology by timestamp + sequence | TC-OBS-04-INT-02 |
| API-06 cursor pagination continuation behavior | TC-OBS-04-INT-03 |
| Archived events are included in timeline reads | TC-OBS-04-INT-02 |
| Actor display-name resolution (user, token fallback, system fallback) | TC-OBS-04-INT-04, TC-OBS-04-FE-01 |
| CANCELLED instance returns complete history including INSTANCE_CANCELLED | TC-OBS-04-INT-02 |
| Invalid cursor/base64/wrong endpoint/expired cursor mapping | TC-OBS-04-01, TC-OBS-04-03, TC-OBS-04-04, TC-OBS-04-05 |
| Frontend timeline secondary context rendering (node/task) | TC-OBS-04-FE-02, TC-OBS-04-FE-03, TC-OBS-04-FE-04 |
| Frontend timeline page merge behavior for first page vs load-more page | TC-OBS-04-FE-05 |
| Browser UI -> API -> DB timeline tab flow and visual state evidence | TC-OBS-04-E2E-01 |

## Test Cases

### TC-OBS-04-01: Invalid instance_id returns HTTP 422
**Given:** a malformed path UUID
**When:** `handleTimeline` is invoked
**Then:** response is HTTP 422 with `INVALID_INSTANCE_ID`
**Layer:** unit
**Acceptance criterion mapped:** input validation and error contract

### TC-OBS-04-03: Invalid cursor base64/prefix returns HTTP 422
**Given:** malformed or wrong-endpoint cursor value
**When:** `handleTimeline` is invoked with cursor
**Then:** response is HTTP 422 with `INVALID_CURSOR`
**Layer:** unit
**Acceptance criterion mapped:** API-06 cursor validation contract

### TC-OBS-04-04: Expired cursor returns HTTP 410
**Given:** an expired `TL:` cursor
**When:** `handleTimeline` is invoked
**Then:** response is HTTP 410 with `CURSOR_EXPIRED`
**Layer:** unit
**Acceptance criterion mapped:** API-06 cursor expiry contract

### TC-OBS-04-INT-01: Unknown instance returns HTTP 404
**Given:** no `instance_projections` row for the requested instance ID
**When:** `GET /instances/:id/timeline` handler is executed
**Then:** response is HTTP 404 with `INSTANCE_NOT_FOUND`
**Layer:** integration
**Acceptance criterion mapped:** instance-not-found behavior

### TC-OBS-04-INT-02: CANCELLED instance timeline includes archived + live events in deterministic ascending order
**Given:** a CANCELLED instance with early events in `events_archive` and later events in `events`
**When:** timeline is requested with default pagination
**Then:** all events are present in ascending order and include `INSTANCE_CANCELLED`
**Layer:** integration
**Acceptance criterion mapped:** chronological determinism, archived-event inclusion, cancelled-instance full history

### TC-OBS-04-INT-03: Cursor pagination is deterministic and non-overlapping across pages
**Given:** an instance with more timeline events than page size
**When:** first page is requested with `page_size=2`, then second page with `next_cursor`
**Then:** first page returns exactly two items and non-null cursor; second page continues with no duplicates
**Layer:** integration
**Acceptance criterion mapped:** API-06 pagination behavior

### TC-OBS-04-INT-04: Actor display-name resolution fallback order is applied
**Given:** events authored by (a) known user, (b) unknown user with token description metadata, and (c) unknown user without fallback metadata
**When:** timeline is requested
**Then:** actor display names resolve to user display name, token description, and `system` respectively
**Layer:** integration
**Acceptance criterion mapped:** actor display-name fallback behavior

### TC-OBS-04-FE-01: Frontend actor display helper falls back to `system`
**Given:** blank or missing actor display name in timeline entry
**When:** actor display utility resolves name
**Then:** returned value is `system`
**Layer:** frontend-unit
**Acceptance criterion mapped:** frontend display fallback for actor labels

### TC-OBS-04-FE-02: Frontend secondary context renders node + task identifiers
**Given:** timeline entry has both `node_id` and `task_id`
**When:** secondary context utility formats display string
**Then:** output includes both values in deterministic order
**Layer:** frontend-unit
**Acceptance criterion mapped:** timeline context field rendering

### TC-OBS-04-FE-03: Frontend secondary context renders node-only entries
**Given:** timeline entry has `node_id` only
**When:** secondary context utility formats display string
**Then:** output contains node context only
**Layer:** frontend-unit
**Acceptance criterion mapped:** timeline context rendering with partial fields

### TC-OBS-04-FE-04: Frontend secondary context renders empty string with no task/node context
**Given:** timeline entry has neither `node_id` nor `task_id`
**When:** secondary context utility formats display string
**Then:** output is an empty string
**Layer:** frontend-unit
**Acceptance criterion mapped:** timeline rendering behavior for context-less events

### TC-OBS-04-FE-05: Frontend merge behavior replaces on first page and appends on load-more
**Given:** existing rendered timeline items and a new page of timeline data
**When:** merge utility runs with no cursor vs non-empty cursor
**Then:** no-cursor path replaces items, cursor path appends items
**Layer:** frontend-unit
**Acceptance criterion mapped:** timeline data handling introduced in OBS-04 frontend implementation

### TC-OBS-04-E2E-01: Browser login -> instance detail -> timeline tab renders observable timeline state
**Given:** a running backend/API connected to DB and valid E2E credentials
**When:** user signs in through the web UI, opens an instance, and selects the Timeline tab
**Then:** timeline heading is visible and either timeline entries or deterministic empty-state text are rendered with screenshot evidence
**Layer:** e2e
**Acceptance criterion mapped:** browser-level UI->API->DB observability flow for timeline tab
