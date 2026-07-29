---
id: API-01
title: REST conventions
stage: 4
priority: MUST
status: RELEASED
---

# API-01 — REST conventions `[MUST]`

> All endpoints SHALL follow REST conventions: nouns for resources, HTTP verbs for actions, JSON request/response bodies, `Content-Type: application/json`. Error responses SHALL use RFC 9457 Problem Details format.

**Acceptance Criteria:**
- All platform endpoints use nouns for resource paths and standard HTTP verbs: GET (read), POST (create/action), PUT (full replace), PATCH (partial update), DELETE (remove).
- All request and response bodies use `Content-Type: application/json`.
- Requests that supply a body without `Content-Type: application/json` MUST be rejected with HTTP 415.
- All error responses MUST use RFC 9457 Problem Details format with at minimum: `type` (URI), `title` (human-readable), `status` (HTTP status code), `detail` (specific message).
- HTTP success codes: 200 (OK), 201 (Created), 204 (No content, no body).

**See:** API-07 (validation errors add an `errors` array to Problem Details), API-09 (tracing adds `trace_id` to all responses)

**Edge cases:**
- PUT with no body: HTTP 400 (body required for full replacement).
- POST to a non-existent resource path: HTTP 404.
