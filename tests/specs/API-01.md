# Test Spec: API-01 — REST conventions

**Requirement:** API-01 — All endpoints SHALL follow REST conventions: nouns for resources, HTTP verbs for actions, JSON request/response bodies, `Content-Type: application/json`. Error responses SHALL use RFC 9457 Problem Details format.
**Priority:** MUST
**Test layer:** unit

---

## Acceptance Criteria

| AC | Verified by |
|---|---|
| Requests with body and wrong/absent Content-Type → HTTP 415 | TC-API-01-10 through TC-API-01-13, TC-API-01-17 through TC-API-01-18 |
| All error responses use RFC 9457 Problem Details | TC-API-01-01 through TC-API-01-09 |
| RFC 9457 fields: type, title, status, detail | TC-API-01-08 |
| HTTP 200, 201, 204 for successes | TC-API-01-19, TC-API-01-20, TC-API-01-21 |
| PUT with no body → HTTP 400 | TC-API-01-14 |
| GET / DELETE not subject to Content-Type enforcement | TC-API-01-15, TC-API-01-16 |

---

## Test Cases

### TC-API-01-01: problemBadRequest produces status=400 and type URI contains bad-request
**Given:** The errors module is imported  
**When:** `problemBadRequest("test detail")` is called  
**Then:** The returned ProblemDetails has `status = 400` and `type` contains the substring `"bad-request"`  
**Layer:** unit  
**Acceptance criterion mapped:** All error responses use RFC 9457 Problem Details; error type URI identifies the problem class

### TC-API-01-02: problemNotFound produces status=404
**Given:** The errors module is imported  
**When:** `problemNotFound("not found")` is called  
**Then:** The returned ProblemDetails has `status = 404`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 404 class

### TC-API-01-03: problemConflict produces status=409
**Given:** The errors module is imported  
**When:** `problemConflict("conflict")` is called  
**Then:** The returned ProblemDetails has `status = 409`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 409 class

### TC-API-01-04: problemUnprocessable produces status=422
**Given:** The errors module is imported  
**When:** `problemUnprocessable("unprocessable")` is called  
**Then:** The returned ProblemDetails has `status = 422`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 422 class

### TC-API-01-05: problemUnsupportedMediaType produces status=415
**Given:** The errors module is imported  
**When:** `problemUnsupportedMediaType("unsupported")` is called  
**Then:** The returned ProblemDetails has `status = 415`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 415 class

### TC-API-01-06: problemInternalError produces status=500
**Given:** The errors module is imported  
**When:** `problemInternalError("internal")` is called  
**Then:** The returned ProblemDetails has `status = 500`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 500 class

### TC-API-01-07: problemServiceUnavailable produces status=503
**Given:** The errors module is imported  
**When:** `problemServiceUnavailable("unavailable")` is called  
**Then:** The returned ProblemDetails has `status = 503`  
**Layer:** unit  
**Acceptance criterion mapped:** Error constructor returns correct HTTP status for 503 class

### TC-API-01-08: serialise outputs valid JSON with all 4 RFC 9457 fields
**Given:** An allocator and a ProblemDetails value  
**When:** `serialise(allocator, pd)` is called  
**Then:** The returned JSON string contains the keys `"type"`, `"title"`, `"status"`, `"detail"`, starts with `{` and ends with `}`  
**Layer:** unit  
**Acceptance criterion mapped:** All error responses MUST use RFC 9457 Problem Details format with at minimum: type, title, status, detail

### TC-API-01-09: serialise JSON contains correct numeric status value
**Given:** A ProblemDetails with status=409  
**When:** `serialise(allocator, pd)` is called  
**Then:** The returned JSON contains the substring `409` as an unquoted numeric value (not `"409"`)  
**Layer:** unit  
**Acceptance criterion mapped:** RFC 9457 `status` field is the HTTP status code as a number

### TC-API-01-10: POST with Content-Type application/json passes
**Given:** A POST request with `Content-Type: application/json` and a non-empty body  
**When:** `checkContentType("POST", "application/json", true)` is called  
**Then:** Returns `null` (request passes through)  
**Layer:** unit  
**Acceptance criterion mapped:** All request bodies use Content-Type: application/json

### TC-API-01-11: POST with Content-Type text/plain returns 415
**Given:** A POST request with `Content-Type: text/plain` and a non-empty body  
**When:** `checkContentType("POST", "text/plain", true)` is called  
**Then:** Returns a non-null ProblemDetails with `status = 415`  
**Layer:** unit  
**Acceptance criterion mapped:** Requests that supply a body without Content-Type: application/json MUST be rejected with HTTP 415

### TC-API-01-12: POST with no Content-Type returns 415
**Given:** A POST request with no Content-Type header and a non-empty body  
**When:** `checkContentType("POST", null, true)` is called  
**Then:** Returns a non-null ProblemDetails with `status = 415`  
**Layer:** unit  
**Acceptance criterion mapped:** Requests that supply a body without Content-Type: application/json MUST be rejected with HTTP 415

### TC-API-01-13: PUT with Content-Type application/json and body passes
**Given:** A PUT request with `Content-Type: application/json` and a non-empty body  
**When:** `checkContentType("PUT", "application/json", true)` is called  
**Then:** Returns `null` (request passes through)  
**Layer:** unit  
**Acceptance criterion mapped:** All request bodies use Content-Type: application/json

### TC-API-01-14: PUT with no body returns 400
**Given:** A PUT request with no body  
**When:** `checkContentType("PUT", null, false)` is called  
**Then:** Returns a non-null ProblemDetails with `status = 400`  
**Layer:** unit  
**Acceptance criterion mapped:** PUT with no body: HTTP 400 (body required for full replacement)

### TC-API-01-15: GET passes regardless of Content-Type
**Given:** A GET request with no Content-Type header  
**When:** `checkContentType("GET", null, false)` is called  
**Then:** Returns `null` (GET is not subject to Content-Type enforcement)  
**Layer:** unit  
**Acceptance criterion mapped:** Standard HTTP verbs: GET (read) — no body expected, not checked

### TC-API-01-16: DELETE passes regardless of Content-Type
**Given:** A DELETE request with no Content-Type header  
**When:** `checkContentType("DELETE", null, false)` is called  
**Then:** Returns `null` (DELETE is not subject to Content-Type enforcement)  
**Layer:** unit  
**Acceptance criterion mapped:** Standard HTTP verbs: DELETE (remove) — no body expected, not checked

### TC-API-01-17: PATCH with Content-Type application/json passes
**Given:** A PATCH request with `Content-Type: application/json` and a non-empty body  
**When:** `checkContentType("PATCH", "application/json", true)` is called  
**Then:** Returns `null` (request passes through)  
**Layer:** unit  
**Acceptance criterion mapped:** All request bodies use Content-Type: application/json

### TC-API-01-18: PATCH with wrong Content-Type returns 415
**Given:** A PATCH request with `Content-Type: text/xml` and a non-empty body  
**When:** `checkContentType("PATCH", "text/xml", true)` is called  
**Then:** Returns a non-null ProblemDetails with `status = 415`  
**Layer:** unit  
**Acceptance criterion mapped:** Requests that supply a body without Content-Type: application/json MUST be rejected with HTTP 415

### TC-API-01-19: ok() returns status_code 200
**Given:** A pre-serialised JSON body string  
**When:** `ok(body)` is called  
**Then:** The returned HandlerResult has `status_code = 200`  
**Layer:** unit  
**Acceptance criterion mapped:** HTTP success codes: 200 (OK)

### TC-API-01-20: created() returns status_code 201
**Given:** A pre-serialised JSON body string  
**When:** `created(body)` is called  
**Then:** The returned HandlerResult has `status_code = 201`  
**Layer:** unit  
**Acceptance criterion mapped:** HTTP success codes: 201 (Created)

### TC-API-01-21: noContent() returns status_code 204 and empty body
**Given:** No inputs  
**When:** `noContent()` is called  
**Then:** The returned HandlerResult has `status_code = 204` and `body = ""`  
**Layer:** unit  
**Acceptance criterion mapped:** HTTP success codes: 204 (No content, no body)

### TC-API-01-22: problemResponse() returns status_code matching ProblemDetails status
**Given:** A ProblemDetails with status=400 and an allocator  
**When:** `problemResponse(allocator, pd)` is called  
**Then:** The returned HandlerResult has `status_code = 400` (matches pd.status)  
**Layer:** unit  
**Acceptance criterion mapped:** All error responses MUST use RFC 9457 Problem Details format; status_code in HandlerResult mirrors ProblemDetails.status
