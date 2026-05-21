---
id: API-10
title: Rate limiting
stage: 4
priority: SHOULD
status: VALIDATED
---

# API-10 — Rate limiting `[SHOULD]`

> The API SHALL enforce per-token rate limits (configurable, default 1,000 req/min). Exceeded limits MUST return HTTP 429 with a `Retry-After` header.

**Acceptance Criteria:**
- GIVEN a token T that has exceeded 1,000 requests in the current 1-minute window, WHEN request N+1 arrives, THEN HTTP 429 is returned with a `Retry-After` header indicating seconds until the window resets.
- The rate limit is per-token, not per-IP.
- The default limit of 1,000 req/min MUST be overridable per-token via configuration.
- Requests that receive HTTP 429 MUST NOT be processed (no state changes occur).

**See:** API-08 (token identity used to bucket the counter)

**Edge cases:**
- Token with no configured limit: uses the global default.
- `Retry-After: 0`: window has just reset; client may retry immediately.
