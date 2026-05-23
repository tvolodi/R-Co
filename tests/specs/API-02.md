# Test Spec: API-02 — Process Definition CRUD

**Requirement:** API-02 — The API SHALL expose: `POST /definitions`, `GET /definitions`, `GET /definitions/:id`, `PUT /definitions/:id` (full replacement of DRAFT only), `PATCH /definitions/:id` (partial update of DRAFT only), `DELETE /definitions/:id` (hard delete of DRAFT; archive of ACTIVE/DEPRECATED), `POST /definitions/:id/activate`.
**Priority:** MUST
**Test layer:** unit (handler input-validation), integration (Store + real PostgreSQL)

---

## Test Cases

### TC-API-02-01: POST /definitions — valid body returns HTTP 201 + Definition
**Given:** a valid CreateDefinitionBody with name, version, graph (START → HUMAN_TASK → END)
**When:** handleCreate is called with that body and a valid actor_id
**Then:** HTTP 201, response body contains `"status":"DRAFT"` and a non-zero `"id"`
**Layer:** unit (pure-handler stub), integration
**Acceptance criterion mapped:** `POST /definitions` creates a definition; returns HTTP 201 with definition ID

---

### TC-API-02-02: POST /definitions — duplicate name+version returns HTTP 409
**Given:** a definition with name="dup-proc" and version="1.0" already exists in the store
**When:** handleCreate is called with the same name and version
**Then:** HTTP 409, body contains `"duplicate_name_version"`
**Layer:** integration
**Acceptance criterion mapped:** name+version conflict → HTTP 409

---

### TC-API-02-03: POST /definitions — invalid graph returns HTTP 422 with violations array
**Given:** a CreateDefinitionBody whose graph contains no START node
**When:** handleCreate is called
**Then:** HTTP 422, response body contains an `"errors"` array with at least one entry whose `"code"` is `"MISSING_START_NODE"`
**Layer:** unit (pure-handler stub), integration
**Acceptance criterion mapped:** all write operations trigger PD-02 graph validation; validation failures return HTTP 422

---

### TC-API-02-04: POST /definitions — invalid UUID actor returns HTTP 422
**Given:** handleCreate is called with a body that contains an empty name
**When:** the handler runs validation
**Then:** HTTP 422, body contains `"name_invalid"`
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** input validation failure → HTTP 422

---

### TC-API-02-05: GET /definitions — returns HTTP 200 with items array and cursor
**Given:** at least one definition exists in the store
**When:** handleList is called with no filters
**Then:** HTTP 200, body contains `"items"` array and `"cursor"` key (null when no next page)
**Layer:** integration
**Acceptance criterion mapped:** `GET /definitions` lists definitions, paginated

---

### TC-API-02-06: GET /definitions — invalid status filter returns HTTP 422
**Given:** handleList is called with `status="INVALID_STATUS"`
**When:** the handler validates the query parameter
**Then:** HTTP 422, body contains an error message about the invalid status value
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid `?status=` value → HTTP 422

---

### TC-API-02-07: GET /definitions — page_size=0 returns HTTP 422
**Given:** handleList is called with `page_size=0`
**When:** the handler validates the query parameter
**Then:** HTTP 422
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** `?page_size=` ≤ 0 → HTTP 422

---

### TC-API-02-08: GET /definitions — invalid cursor returns HTTP 422
**Given:** handleList is called with a cursor string containing non-base64url characters
**When:** decodeCursor fails to decode the cursor
**Then:** HTTP 422, body contains "invalid cursor"
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid `?cursor=` → HTTP 422

---

### TC-API-02-09: GET /definitions/:id — existing id returns HTTP 200 + Definition
**Given:** a definition with a known UUID exists in the store
**When:** handleGetById is called with that UUID string
**Then:** HTTP 200, body contains the definition JSON with correct `"id"` and `"status":"DRAFT"`
**Layer:** integration
**Acceptance criterion mapped:** `GET /definitions/:id` returns definition

---

### TC-API-02-10: GET /definitions/:id — unknown id returns HTTP 404
**Given:** no definition exists for the given UUID
**When:** handleGetById is called with that UUID string
**Then:** HTTP 404, body contains `"not found"`
**Layer:** integration
**Acceptance criterion mapped:** `GET /definitions/:id` HTTP 404 if not found

---

### TC-API-02-11: GET /definitions/:id — malformed UUID returns HTTP 422
**Given:** handleGetById is called with an id_str that is not a valid UUID (e.g. "not-a-uuid")
**When:** parseUuid fails
**Then:** HTTP 422, body contains an error message
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid UUID format → HTTP 422

---

### TC-API-02-12: PUT /definitions/:id — DRAFT definition succeeds with HTTP 200
**Given:** a DRAFT definition exists
**When:** handlePut is called with a valid PutDefinitionBody and the definition's UUID
**Then:** HTTP 200, body contains the updated Definition JSON with status DRAFT
**Layer:** integration
**Acceptance criterion mapped:** `PUT /definitions/:id` full replacement; only valid for DRAFT definitions

---

### TC-API-02-13: PUT /definitions/:id — ACTIVE definition returns HTTP 409
**Given:** an ACTIVE definition exists
**When:** handlePut is called with that definition's UUID
**Then:** HTTP 409, body contains `"not_draft"`
**Layer:** integration
**Acceptance criterion mapped:** `PUT /definitions/:id` HTTP 409 if status ≠ DRAFT; PUT/PATCH on ACTIVE → HTTP 409

---

### TC-API-02-14: PUT /definitions/:id — unknown id returns HTTP 404
**Given:** no definition exists for the given UUID
**When:** handlePut is called with that UUID
**Then:** HTTP 404, body contains `"not_found"`
**Layer:** integration
**Acceptance criterion mapped:** `PUT /definitions/:id` not found → HTTP 404

---

### TC-API-02-15: PUT /definitions/:id — invalid graph returns HTTP 422
**Given:** a DRAFT definition exists
**When:** handlePut is called with a PutDefinitionBody whose graph has no START node
**Then:** HTTP 422, body contains `"errors"` array with `"MISSING_START_NODE"`
**Layer:** integration
**Acceptance criterion mapped:** all write operations trigger PD-02 graph validation; failures → HTTP 422

---

### TC-API-02-16: PUT /definitions/:id — malformed UUID returns HTTP 422
**Given:** handlePut is called with an id_str that is not a valid UUID
**When:** parseUuid fails
**Then:** HTTP 422, body contains `"invalid_id_format"`
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid UUID format → HTTP 422

---

### TC-API-02-17: PATCH /definitions/:id — partial update of DRAFT succeeds with HTTP 200
**Given:** a DRAFT definition exists
**When:** handlePatch is called with a PatchDefinitionBody that sets only description (other fields null)
**Then:** HTTP 200, response body contains updated definition JSON
**Layer:** integration
**Acceptance criterion mapped:** `PATCH /definitions/:id` partial update; only valid for DRAFT

---

### TC-API-02-18: PATCH /definitions/:id — ACTIVE definition returns HTTP 409
**Given:** an ACTIVE definition exists
**When:** handlePatch is called with that definition's UUID
**Then:** HTTP 409, body contains `"not_draft"`
**Layer:** integration
**Acceptance criterion mapped:** `PATCH /definitions/:id` HTTP 409 if status ≠ DRAFT

---

### TC-API-02-19: PATCH /definitions/:id — unknown id returns HTTP 404
**Given:** no definition exists for the given UUID
**When:** handlePatch is called with that UUID
**Then:** HTTP 404, body contains `"not_found"`
**Layer:** integration
**Acceptance criterion mapped:** `PATCH /definitions/:id` not found → HTTP 404

---

### TC-API-02-20: PATCH /definitions/:id — invalid UUID returns HTTP 422
**Given:** handlePatch is called with an id_str that is not a valid UUID
**When:** parseUuid fails
**Then:** HTTP 422, body contains `"invalid_id_format"`
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid UUID format → HTTP 422

---

### TC-API-02-21: PATCH /definitions/:id — graph field provided with invalid graph returns HTTP 422
**Given:** a DRAFT definition exists
**When:** handlePatch is called with a PatchDefinitionBody that includes a graph with no START node
**Then:** HTTP 422, body contains `"errors"` array
**Layer:** integration
**Acceptance criterion mapped:** PATCH with graph supplied → graph validation runs; failure → HTTP 422

---

### TC-API-02-22: DELETE /definitions/:id — DRAFT hard-delete returns HTTP 204
**Given:** a DRAFT definition that was never activated exists
**When:** handleDelete is called with that definition's UUID
**Then:** HTTP 204, no body (empty string)
**Layer:** integration
**Acceptance criterion mapped:** `DELETE /definitions/:id` hard delete of never-activated DRAFT → HTTP 204

---

### TC-API-02-23: DELETE /definitions/:id — ACTIVE definition returns HTTP 200 + ARCHIVED Definition
**Given:** an ACTIVE definition exists
**When:** handleDelete is called with that definition's UUID
**Then:** HTTP 200, body contains Definition JSON with `"status":"ARCHIVED"`
**Layer:** integration
**Acceptance criterion mapped:** DELETE on ACTIVE definition triggers archive (not hard delete), HTTP 200

---

### TC-API-02-24: DELETE /definitions/:id — DEPRECATED definition returns HTTP 200 + ARCHIVED Definition
**Given:** a DEPRECATED definition exists
**When:** handleDelete is called with that definition's UUID
**Then:** HTTP 200, body contains Definition JSON with `"status":"ARCHIVED"`
**Layer:** integration
**Acceptance criterion mapped:** archive of ACTIVE or DEPRECATED → HTTP 200

---

### TC-API-02-25: DELETE /definitions/:id — ARCHIVED definition returns HTTP 409
**Given:** an ARCHIVED definition exists
**When:** handleDelete is called with that definition's UUID
**Then:** HTTP 409, body contains `"already_archived"`
**Layer:** integration
**Acceptance criterion mapped:** `DELETE /definitions/:id` → HTTP 409 when already ARCHIVED

---

### TC-API-02-26: DELETE /definitions/:id — unknown id returns HTTP 404
**Given:** no definition exists for the given UUID
**When:** handleDelete is called with that UUID
**Then:** HTTP 404, body contains `"not_found"`
**Layer:** integration
**Acceptance criterion mapped:** `DELETE /definitions/:id` HTTP 404 if not found

---

### TC-API-02-27: DELETE /definitions/:id — invalid UUID returns HTTP 422
**Given:** handleDelete is called with an id_str that is not a valid UUID
**When:** parseUuid fails
**Then:** HTTP 422, body contains `"invalid_id_format"`
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid UUID format → HTTP 422

---

### TC-API-02-28: POST /definitions/:id/activate — DRAFT transitions to ACTIVE, returns HTTP 200
**Given:** a DRAFT definition with a valid graph exists
**When:** handleActivate is called with that definition's UUID
**Then:** HTTP 200, body contains Definition JSON with `"status":"ACTIVE"`
**Layer:** integration
**Acceptance criterion mapped:** `POST /definitions/:id/activate` transitions DRAFT → ACTIVE

---

### TC-API-02-29: POST /definitions/:id/activate — already ACTIVE is idempotent, returns HTTP 200
**Given:** an ACTIVE definition exists
**When:** handleActivate is called with that definition's UUID
**Then:** HTTP 200, body contains Definition JSON with `"status":"ACTIVE"` (no state change)
**Layer:** integration
**Acceptance criterion mapped:** activating an already-ACTIVE definition returns HTTP 200 (idempotent)

---

### TC-API-02-30: POST /definitions/:id/activate — DEPRECATED returns HTTP 409
**Given:** a DEPRECATED definition exists
**When:** handleActivate is called with that definition's UUID
**Then:** HTTP 409, body contains `"not_draft"`
**Layer:** integration
**Acceptance criterion mapped:** `POST /definitions/:id/activate` HTTP 409 if status ≠ DRAFT

---

### TC-API-02-31: POST /definitions/:id/activate — graph re-validation failure returns HTTP 422
**Given:** a DRAFT definition whose stored graph is structurally invalid (no START node — possible only via a direct DB write bypassing normal create path)
**When:** handleActivate is called with that definition's UUID
**Then:** HTTP 422, body contains `"errors"` array
**Layer:** integration
**Acceptance criterion mapped:** activate triggers PD-02 graph re-validation; failure → HTTP 422

---

### TC-API-02-32: POST /definitions/:id/activate — unknown id returns HTTP 404
**Given:** no definition exists for the given UUID
**When:** handleActivate is called with that UUID
**Then:** HTTP 404, body contains `"not_found"`
**Layer:** integration
**Acceptance criterion mapped:** not found → HTTP 404

---

### TC-API-02-33: POST /definitions/:id/activate — invalid UUID returns HTTP 422
**Given:** handleActivate is called with an id_str that is not a valid UUID
**When:** parseUuid fails
**Then:** HTTP 422, body contains `"invalid_id_format"`
**Layer:** unit (pure-handler stub)
**Acceptance criterion mapped:** invalid UUID format → HTTP 422

---

### TC-API-02-34: Role guard — DELETE requires PLATFORM_ADMIN (design verification)
**Given:** the route table shows DELETE /definitions/:id requires PLATFORM_ADMIN only
**When:** a request is made by a PROCESS_DESIGNER
**Then:** HTTP 403 (enforced by rbac middleware, upstream of the handler)
**Layer:** integration (middleware layer — requires running server)
**Acceptance criterion mapped:** DELETE requires PLATFORM_ADMIN

---

### TC-API-02-35: Role guard — POST/PUT/PATCH/activate require PROCESS_DESIGNER or PLATFORM_ADMIN (design verification)
**Given:** the route table shows write routes require PROCESS_DESIGNER or PLATFORM_ADMIN
**When:** an unauthenticated request is made
**Then:** HTTP 401 (enforced by auth middleware)
**Layer:** integration (middleware layer — requires running server)
**Acceptance criterion mapped:** role/auth guards enforced for all write operations
