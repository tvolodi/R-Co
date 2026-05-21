---
id: API-03
title: Instance management
stage: 4
priority: MUST
status: VALIDATED
---

# API-03 — Instance management `[MUST]`

> The API SHALL expose: `POST /instances` (start), `GET /instances/:id` (state + current tasks), `POST /instances/:id/cancel`, `GET /instances` (list, paginated, filterable by status/definition).

**Acceptance Criteria:**
- `POST /instances`: starts instance; body contains `definition_id` (or `name` + `version`), optional `correlation_key`, optional `initial_variables`. Returns HTTP 201 with `instance_id` and `status = ACTIVE`. Requires PROCESS_OPERATOR or above.
- `GET /instances/:id`: returns instance state including `status`, `current_tasks`, `variables`, `started_at`. HTTP 404 if not found. Any authenticated role.
- `POST /instances/:id/cancel`: cancels instance per EE-08. HTTP 409 if already terminal. Requires PROCESS_OPERATOR or above.
- `GET /instances`: lists instances, paginated (API-06), filterable by `status` and `definition_id`. Any authenticated role.

**See:** EE-01 (start logic), EE-08 (cancel logic), API-06 (pagination), API-08 (auth)

**Edge cases:**
- `GET /instances/:id` for a CANCELLED instance: returns instance with `status = CANCELLED`.
- Starting with a `definition_id` that belongs to a DRAFT definition: HTTP 409.
