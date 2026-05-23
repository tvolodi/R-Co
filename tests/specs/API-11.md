# Test Spec: API-11 — OpenAPI specification

**Requirement:** API-11 — The platform SHALL publish a machine-readable OpenAPI 3.1 specification at `GET /openapi.json`. The spec SHALL be generated from code, not manually maintained.  
**Priority:** SHOULD  
**Test layer:** unit, integration

---

## Coverage matrix

| Acceptance criterion | Test case(s) |
|---|---|
| `GET /openapi.json` returns valid OpenAPI 3.1 document | TC-API-11-01, TC-API-11-02, TC-API-11-INT-01 |
| Spec is generated from code, not static file | TC-API-11-04, TC-API-11-INT-02 |
| Endpoint is accessible without authentication | TC-API-11-01, TC-API-11-INT-01 |
| `info.version` matches platform release version | TC-API-11-02, TC-API-11-INT-03 |
| Spec includes expected endpoints and shared error shapes | TC-API-11-03, TC-API-11-INT-04 |

---

## Unit test cases

Unit tests are implemented in `src/api/routes/openapi.zig` and run with `zig build test`.

### TC-API-11-01: Public OpenAPI route returns HTTP 200
**Given:** The OpenAPI route handler is invoked with a test allocator and no auth context input  
**When:** `handleGetOpenApi(allocator)` is called  
**Then:** The handler returns status code `200`  
**Layer:** unit  
**Acceptance criterion mapped:** Endpoint is accessible without authentication and returns success

### TC-API-11-02: Response body is valid OpenAPI 3.1 JSON and version is correct
**Given:** The OpenAPI route handler output body  
**When:** The body is parsed as JSON and `openapi` and `info.version` are inspected  
**Then:**
- JSON parsing succeeds
- `openapi` starts with `3.1.`
- `info.version` equals `version_source.platformVersion(...)`  
**Layer:** unit  
**Acceptance criterion mapped:** OpenAPI 3.1 document and version-source correctness

### TC-API-11-03: Generated document includes core paths and shared problem components
**Given:** The JSON response from `handleGetOpenApi`  
**When:** `paths`, `components.schemas`, and `components.responses` are inspected  
**Then:**
- Paths include `/api/v1/definitions`, `/api/v1/instances`, `/api/v1/tasks`, `/openapi.json`
- Schemas include `ProblemDetails` and `ValidationProblem`
- Responses include `Error400`, `Error422`, and `Error500`  
**Layer:** unit  
**Acceptance criterion mapped:** Endpoint and shared error-shape coverage in spec

### TC-API-11-04: Route output is produced by builder+serializer code path
**Given:** A document produced via `openapi_builder.buildOpenApiDocument(defaultBuildInput())`  
**When:** It is serialized with `openapi_serialize.toJson(...)` and compared with `handleGetOpenApi` output  
**Then:** Serialized builder output exactly equals route response body  
**Layer:** unit  
**Acceptance criterion mapped:** Code-generated spec (not static fixture)

---

## Integration test cases (for TEST-RUNNER execution)

These cases verify behavior at the HTTP boundary using the running server.

### TC-API-11-INT-01: GET /openapi.json returns 200 without Authorization header
**Given:** BPM server is running  
**When:** `GET /openapi.json` is sent with no `Authorization` header  
**Then:**
- HTTP status is `200`
- `Content-Type` is JSON
- Body parses as JSON  
**Layer:** integration  
**Acceptance criterion mapped:** Public accessibility without auth

### TC-API-11-INT-02: OpenAPI payload is runtime generated, not file-served fixture
**Given:** BPM server is running  
**When:** `GET /openapi.json` is requested and source path instrumentation/log markers are captured  
**Then:** Handler executes builder/serializer path (no static file read path observed)  
**Layer:** integration  
**Acceptance criterion mapped:** Code-generation source of truth

### TC-API-11-INT-03: info.version equals platform release version
**Given:** BPM server is running and release version is known from build metadata  
**When:** `GET /openapi.json` is requested  
**Then:** `info.version` in response equals platform release version  
**Layer:** integration  
**Acceptance criterion mapped:** Version consistency

### TC-API-11-INT-04: OpenAPI document contains expected endpoint and shared problem references
**Given:** BPM server is running  
**When:** `GET /openapi.json` response is parsed  
**Then:**
- Core paths are present
- `components.schemas.ProblemDetails` and `components.schemas.ValidationProblem` are present
- Shared response refs (`Error400`, `Error422`, `Error500`) are present  
**Layer:** integration  
**Acceptance criterion mapped:** Core path/schema/response coverage
