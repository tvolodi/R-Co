---
id: OBS-03
title: Audit log
stage: 6
priority: MUST
status: VALIDATED
---

# OBS-03 — Audit log `[MUST]`

> All state-changing API actions SHALL be recorded in an audit log with: `actor_id`, `action`, `resource_type`, `resource_id`, `timestamp`, and before/after state diff.

**Acceptance Criteria:**
- GIVEN any state-changing API request (POST/PUT/PATCH/DELETE) succeeds, THEN an audit record is written in the same transaction as the state change, containing: `audit_id` (UUID), `actor_id`, `action` (e.g. `definition.activate`), `resource_type`, `resource_id`, `timestamp`, `before_state` (JSON or null), `after_state` (JSON or null).
- `GET /audit` lists audit records; filterable by `actor_id`, `resource_type`, `resource_id`, `from` / `to` timestamps. Paginated (API-06).
- Audit records are immutable after creation; no API permits modification or deletion of audit records.
- Read-only requests (GET) MUST NOT generate audit records.

**See:** OBS-05 (discard action from dead letter queue requires an audit record), DB-03 (audit write is atomic with state change)

**Edge cases:**
- Audit log table unavailable during a write: the entire transaction (including the state change) MUST fail to maintain consistency.
- Audit records for cancelled token requests: audit is still written if the request authenticated and took an action.
