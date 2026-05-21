---
id: API-07
title: Input validation
stage: 4
priority: MUST
status: VALIDATED
---

# API-07 — Input validation `[MUST]`

> The platform SHALL validate all incoming request payloads against defined schemas before processing. Validation errors MUST return HTTP 422 with a structured list of field-level errors in RFC 9457 format.

**Acceptance Criteria:**
- GIVEN a request body missing a required field, THEN HTTP 422 is returned with an RFC 9457 body containing an `errors` array, each entry identifying the field path, constraint violated, and actual value received.
- GIVEN a request body with a field of the wrong type, THEN HTTP 422 with field-level error detail.
- Validation MUST run before any business logic; no side effects (writes) occur for invalid requests.
- An empty required field (e.g. `""` for a required non-empty string) MUST be treated as missing and reported with HTTP 422.
- All 422 responses MUST list ALL validation errors found, not just the first.

**See:** API-01 (Problem Details format for error responses), ES-05 (domain-level validation adds to this layer)

**Edge cases:**
- Malformed JSON body: HTTP 400 (bad request), not HTTP 422.
- Valid JSON body with all fields empty strings when all are required: all required fields listed in the errors array.
