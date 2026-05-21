---
id: API-11
title: OpenAPI specification
stage: 4
priority: SHOULD
status: VALIDATED
---

# API-11 — OpenAPI specification `[SHOULD]`

> The platform SHALL publish a machine-readable OpenAPI 3.1 specification at `GET /openapi.json`. The spec SHALL be generated from code, not manually maintained.

**Acceptance Criteria:**
- `GET /openapi.json` returns a valid OpenAPI 3.1 document describing all platform endpoints, request schemas, response schemas, and error shapes.
- The spec MUST be generated from code (annotations or schema registry); a manually maintained spec is not permitted.
- The spec MUST be accessible without authentication (HTTP 200 with no `Authorization` header required).
- The spec `info.version` field MUST match the platform release version.

**See:** API-01..API-12 (all endpoints appear in the spec)
