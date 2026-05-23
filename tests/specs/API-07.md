# Test Spec: API-07 — Input validation

**Requirement:** API-07 — The platform SHALL validate all incoming request payloads against defined schemas before processing. Validation errors MUST return HTTP 422 with a structured list of field-level errors in RFC 9457 format.
**Priority:** MUST
**Test layer:** unit

## Test Cases

| Test Case ID | Layer | Acceptance Criterion | Description |
|---|---|---|---|
| TC-API-07-01 | unit | AC1 — missing required field → HTTP 422 | `validateField` with required=true, json_value=null returns FieldError with constraint="required". |
| TC-API-07-02 | unit | AC2 — wrong type field → HTTP 422 | `validateField` with expected_type=.string, json_value=42 returns FieldError with constraint="type.string". |
| TC-API-07-03 | unit | AC5 — all errors listed | `validate()` on an object with 3 invalid fields returns .errors with all 3 FieldErrors, not just the first. |
| TC-API-07-04 | unit | AC4 — empty required string treated as missing | `validateField` with required=true, reject_empty_string=true, json_value="" returns FieldError with constraint="required". |
| TC-API-07-05 | unit | Edge — non-object JSON → HTTP 400 | `validate()` with a JSON array value returns .errors with field="(root)", constraint="type.object". |
| TC-API-07-06 | unit | AC6 — valid payload passes | `validate()` on a valid object matching the schema returns .ok with the parsed value. |
| TC-API-07-07 | unit | AC3 — validation before business logic | `enforceValidation()` with invalid payload returns .reject with status_code=422; no side effects occur. |

---

## Detailed Test Cases

### TC-API-07-01: Missing required field → HTTP 422 with field error

**Given:**
- A `FieldConstraint` with `name="title"`, `required=true`.
- `json_value` is null (field absent from JSON object).

**When:**
- `validateField(constraint, json_value)` is called.

**Then:**
- Returns a `FieldError` with:
  - `field = "title"`
  - `constraint = "required"`
  - `message = "field is required"`
  - `received = null`

**Layer:** unit
**Acceptance criterion mapped:** AC1 — GIVEN a request body missing a required field, THEN HTTP 422 is returned with an RFC 9457 body containing an `errors` array.

---

### TC-API-07-02: Wrong type field → HTTP 422 with type error

**Given:**
- A `FieldConstraint` with `name="count"`, `expected_type=.integer`.
- `json_value` is a JSON string `"not-a-number"`.

**When:**
- `validateField(constraint, json_value)` is called.

**Then:**
- Returns a `FieldError` with:
  - `field = "count"`
  - `constraint = "type.integer"`
  - `message = "expected integer"`

**Layer:** unit
**Acceptance criterion mapped:** AC2 — GIVEN a request body with a field of the wrong type, THEN HTTP 422 with field-level error detail.

---

### TC-API-07-03: Multiple errors → all listed in response

**Given:**
- A `Schema(TestBody)` with three fields: `name` (required, type string), `age` (type integer), `email` (required, type string).
- A JSON object `{"age": "not-an-integer"}` — missing both `name` and `email`, and `age` has wrong type.

**When:**
- `validate(TestBody, allocator, schema, json_value)` is called.

**Then:**
- Returns `.errors` with exactly 3 `FieldError` entries:
  - One for `name`: constraint="required"
  - One for `email`: constraint="required"
  - One for `age`: constraint="type.integer"
- All three errors are present; not just the first.

**Layer:** unit
**Acceptance criterion mapped:** AC5 — All 422 responses MUST list ALL validation errors found, not just the first.

---

### TC-API-07-04: Empty required string → treated as missing, HTTP 422

**Given:**
- A `FieldConstraint` with `name="title"`, `required=true`, `reject_empty_string=true`, `expected_type=.string`.
- `json_value` is a JSON string `""` (empty string).

**When:**
- `validateField(constraint, json_value)` is called.

**Then:**
- Returns a `FieldError` with:
  - `field = "title"`
  - `constraint = "required"`
  - `message = "field is required"`
- Empty string is treated identically to a missing field.

**Layer:** unit
**Acceptance criterion mapped:** AC4 — An empty required field (e.g. `""` for a required non-empty string) MUST be treated as missing and reported with HTTP 422.

---

### TC-API-07-05: Non-object JSON value → validation error

**Given:**
- A `Schema(TestBody)` with any fields.
- `json_value` is a JSON array `[1, 2, 3]` (not an object).

**When:**
- `validate(TestBody, allocator, schema, json_value)` is called.

**Then:**
- Returns `.errors` with 1 `FieldError`:
  - `field = "(root)"`
  - `constraint = "type.object"`
  - `message = "request body must be a JSON object"`

**Layer:** unit
**Acceptance criterion mapped:** Edge case — Non-object JSON body (would be HTTP 400 at the middleware level).

---

### TC-API-07-06: Valid payload → validation passes, no errors

**Given:**
- A `Schema(TestBody)` with fields: `name` (required, type string), `age` (type integer, optional).
- A JSON object `{"name": "Alice", "age": 30}` that matches all constraints.

**When:**
- `validate(TestBody, allocator, schema, json_value)` is called.

**Then:**
- Returns `.ok` with the parsed `TestBody` value.
- `TestBody.name` equals `"Alice"`.
- `TestBody.age` equals `30`.

**Layer:** unit
**Acceptance criterion mapped:** AC6 — Valid payload passes all checks and proceeds to business logic.

---

### TC-API-07-07: Validation runs before business logic (no side effects)

**Given:**
- A `Schema(TestBody)` where the JSON value is an array (invalid — not an object).
- `enforceValidation()` is called.

**When:**
- The middleware processes the request.

**Then:**
- Returns `.reject` with:
  - `status_code = 422`
  - `body` containing RFC 9457 Problem Details JSON
- The handler function is never invoked (no business logic execution, no side effects).
- The `.reject` path stops the request pipeline.

**Layer:** unit
**Acceptance criterion mapped:** AC3 — Validation MUST run before any business logic; no side effects (writes) occur for invalid requests.

---

## Additional Unit Tests

### validateField edge cases

| Test Case ID | Layer | Description |
|---|---|---|
| TC-API-07-08 | unit | Optional field absent (required=false, json_value=null) → returns null (no error). |
| TC-API-07-09 | unit | Optional field present with correct type → returns null (no error). |
| TC-API-07-10 | unit | String field exceeds max_length → FieldError with constraint="max_length". |
| TC-API-07-11 | unit | String field below min_length → FieldError with constraint="min_length". |
| TC-API-07-12 | unit | Non-required empty string with reject_empty_string=true → FieldError with constraint="not_empty". |
| TC-API-07-13 | unit | JSON null value with required=true → FieldError with constraint="required". |
| TC-API-07-14 | unit | JSON null value with required=false → returns null (no error). |
| TC-API-07-15 | unit | Number field below min_value → FieldError with constraint="min_value". |
| TC-API-07-16 | unit | Number field above max_value → FieldError with constraint="max_value". |
| TC-API-07-17 | unit | Array field below min_items → FieldError with constraint="min_items". |
| TC-API-07-18 | unit | Array field above max_items → FieldError with constraint="max_items". |

### serialiseValidationErrors tests

| Test Case ID | Layer | Description |
|---|---|---|
| TC-API-07-19 | unit | Single FieldError serialises to valid JSON with all expected fields. |
| TC-API-07-20 | unit | Multiple FieldErrors serialise as a JSON array with comma-separated entries. |
| TC-API-07-21 | unit | FieldError with received=null serialises `"received":null`. |
| TC-API-07-22 | unit | FieldError with received value serialises the fragment correctly. |

### enforceValidation middleware tests

| Test Case ID | Layer | Description |
|---|---|---|
| TC-API-07-23 | unit | Valid payload passes enforceValidation → .ok with parsed value. |
| TC-API-07-24 | unit | Invalid payload returns .reject with status_code=422 and RFC 9457 body. |
