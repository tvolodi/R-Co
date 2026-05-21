---
id: IDN-04
title: API token management
stage: 5
priority: MUST
status: VALIDATED
---

# IDN-04 — API token management `[MUST]`

> Authorised PLATFORM_ADMINs SHALL be able to issue, list, and revoke API tokens scoped to a specific user and role set. Tokens SHALL carry an optional expiry. Once issued, token values are shown only once and are not retrievable again.

**Acceptance Criteria:**
- GIVEN a PLATFORM_ADMIN calls `POST /tokens` with `{ "user_id": "...", "roles": [...], "expires_at": "..." }`, THEN the platform returns HTTP 201 with the token value (shown once only) and a `token_id`.
- Token values MUST be stored as a cryptographic hash (e.g. SHA-256); the plain-text value is returned only at creation time and never again.
- `GET /tokens` lists token metadata (`token_id`, `user_id`, `roles`, `expires_at`, `status`) but NEVER the token value.
- `DELETE /tokens/:id` revokes the token immediately; subsequent requests using that token receive HTTP 401.
- An expired token (`created_at > expires_at`) MUST be rejected with HTTP 401 on use.
- `expires_at` is optional; tokens without an expiry are valid until revoked.

**See:** IDN-01 (user_id must exist), IDN-03 (roles specified must be valid role names), API-08 (token validation uses this registry)

**Edge cases:**
- Creating a token with `expires_at` in the past: rejected with HTTP 422.
- Revoking a token mid-request: the in-flight request completes (token was valid at request start); subsequent requests are rejected.
