---
id: API-08
title: Bearer token auth
stage: 4
priority: MUST
status: VALIDATED
---

# API-08 — Bearer token auth `[MUST]`

> All API endpoints SHALL require a Bearer token in the `Authorization` header. Requests without a valid token MUST receive HTTP 401. Requests with insufficient permissions MUST receive HTTP 403. See bootstrapping note for Stage 4 testing.

**Acceptance Criteria:**
- GIVEN a request to any platform endpoint without an `Authorization` header, THEN HTTP 401 is returned with a `WWW-Authenticate: Bearer` header.
- GIVEN a request with `Authorization: Bearer <token>` where the token is unknown or revoked, THEN HTTP 401 is returned.
- GIVEN a request with a valid token but the caller's role does not permit the operation, THEN HTTP 403 is returned.
- GIVEN `BPM_ENV=production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN the platform MUST refuse to start (fatal error).
- GIVEN `BPM_ENV ≠ production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN requests with that token are accepted with PLATFORM_ADMIN role.
- Token validation MUST be performed on every request; no caching of authorisation decisions beyond the request lifetime.

**See:** IDN-03 (role permission matrix), IDN-04 (token issuance), API-01 (error format for 401/403)

**Edge cases:**
- Token present but `Bearer` prefix missing: HTTP 401 (malformed header).
- `BPM_BOOTSTRAP_TOKEN` set to an empty string: treated as not set; bootstrap auth disabled.
