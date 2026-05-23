# Test Spec: API-03 — Instance management (GET /instances/:id and GET /instances)

**Requirement:** API-03 — The API SHALL expose: `POST /instances` (start), `GET /instances/:id` (state + current tasks), `POST /instances/:id/cancel`, `GET /instances` (list, paginated, filterable by status/definition).  
**Priority:** MUST  
**Test layer:** integration

> Scope of this spec: the two new GET endpoints added in this delivery.
> `POST /instances` (handleCreate) and `POST /instances/:id/cancel` (handleCancel) are covered by existing EE-01 and EE-08 test specs.

---

## Test Cases

### TC-API-03-01: GET /instances/:id — ACTIVE instance returns 200 with full state
**Given:** An ACTIVE process instance exists in instance_projections with one PENDING task  
**When:** `InstanceStore.getById()` is called with the instance UUID  
**Then:** Returns `InstanceWithTasks` where `status = ACTIVE`, `tasks.len == 1`, `started_at > 0`, `completed_at == null`, `cancelled_at == null`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` returns instance state including `status`, `current_tasks`, `variables`, `started_at`

---

### TC-API-03-02: GET /instances/:id — unknown UUID returns InstanceNotFound
**Given:** A UUID that does not correspond to any row in instance_projections  
**When:** `InstanceStore.getById()` is called with the unknown UUID  
**Then:** Returns `GetByIdError.InstanceNotFound`  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 404 if not found

---

### TC-API-03-03: handleGetById — invalid UUID path param returns HTTP 422 INVALID_INSTANCE_ID
**Given:** The path parameter is not a valid 36-character hyphenated UUID string (e.g. "not-a-uuid")  
**When:** `handleGetById()` is called with that string  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_INSTANCE_ID" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** HTTP 422 with error code `INVALID_INSTANCE_ID` for malformed UUID

---

### TC-API-03-04: GET /instances/:id — COMPLETED instance returns 200 with completed_at set and empty current_tasks
**Given:** A COMPLETED process instance with `completed_at` set and no PENDING tasks  
**When:** `InstanceStore.getById()` is called with the instance UUID  
**Then:** Returns `InstanceWithTasks` where `status = COMPLETED`, `completed_at != null`, `tasks.len == 0`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` for a COMPLETED instance returns state correctly

---

### TC-API-03-05: GET /instances/:id — CANCELLED instance returns 200 with status=CANCELLED
**Given:** A CANCELLED process instance (cancelled via EE-08)  
**When:** `InstanceStore.getById()` is called  
**Then:** Returns `InstanceWithTasks` where `status = CANCELLED`, `cancelled_at != null`, `tasks.len == 0`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` for a CANCELLED instance returns `status = CANCELLED` (not HTTP 409)

---

### TC-API-03-06: GET /instances/:id — instance variables are returned as-stored
**Given:** An instance created with `initial_variables = {"amount": 500, "approved": false}`  
**When:** `InstanceStore.getById()` is called  
**Then:** The returned `variables` field is a JSON string that when parsed yields `{"amount": 500, "approved": false}`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` returns `variables` field

---

### TC-API-03-07: GET /instances — first page returns items in started_at DESC order
**Given:** Three ACTIVE instances created in sequence with distinct `started_at` values  
**When:** `InstanceStore.listInstances()` is called with `page_size = 50`, no filters, no cursor  
**Then:** Returns a slice where `rows[0].started_at >= rows[1].started_at >= rows[2].started_at`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` lists instances paginated, results sorted newest-first

---

### TC-API-03-08: GET /instances — empty result set returns empty slice (HTTP 200)
**Given:** No instances matching the given `status = "COMPLETED"` filter exist (fresh schema or cleaned up)  
**When:** `InstanceStore.listInstances()` is called with `status = "COMPLETED"` and `page_size = 50`  
**Then:** Returns a zero-length slice without error  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` empty result is HTTP 200 with `{ "items": [], "next_cursor": null, "count": 0 }`

---

### TC-API-03-09: handleList — invalid status value returns HTTP 422 INVALID_STATUS
**Given:** The query parameter `status` has the value `"UNKNOWN_STATUS"`  
**When:** `handleList()` is called with `ListInstancesParams { .status = "UNKNOWN_STATUS", .page_size = 50 }`  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_STATUS" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** Unknown `status` value yields HTTP 422 `INVALID_STATUS`

---

### TC-API-03-10: handleList — invalid page_size (0) returns HTTP 422 INVALID_PAGE_SIZE
**Given:** `page_size = 0`  
**When:** `handleList()` is called  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_PAGE_SIZE" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** `page_size <= 0` yields HTTP 422

---

### TC-API-03-11: handleList — page_size > 200 returns HTTP 422 INVALID_PAGE_SIZE
**Given:** `page_size = 201`  
**When:** `handleList()` is called  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_PAGE_SIZE" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** `page_size > 200` yields HTTP 422

---

### TC-API-03-12: handleList — invalid definition_id UUID format returns HTTP 422 INVALID_DEFINITION_ID
**Given:** `definition_id = "not-a-uuid"`  
**When:** `handleList()` is called  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_DEFINITION_ID" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** Malformed `definition_id` UUID format yields HTTP 422

---

### TC-API-03-13: handleList — malformed cursor returns HTTP 422 INVALID_CURSOR
**Given:** `cursor = "!!!not-valid-base64!!!"`  
**When:** `handleList()` is called  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_CURSOR" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** Malformed cursor yields HTTP 422 `INVALID_CURSOR`

---

### TC-API-03-14: handleList — expired cursor (age > 24h) returns HTTP 410 CURSOR_EXPIRED
**Given:** A cursor whose embedded `cursor_created_at_us` timestamp is more than 24 hours in the past  
**When:** `handleList()` is called with that cursor  
**Then:** Returns `HandlerResult { status_code = 410, body contains "CURSOR_EXPIRED" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** Expired cursor yields HTTP 410 `CURSOR_EXPIRED`

---

### TC-API-03-15: GET /instances — filter by status returns only matching instances
**Given:** Two ACTIVE instances and one COMPLETED instance in instance_projections  
**When:** `InstanceStore.listInstances()` is called with `status = "ACTIVE"` and `page_size = 50`  
**Then:** Returns only the ACTIVE instances (length == 2); no COMPLETED instance in the result  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` is filterable by `status`

---

### TC-API-03-16: GET /instances — filter by definition_id returns only matching instances
**Given:** Two instances of definition A and one instance of definition B  
**When:** `InstanceStore.listInstances()` is called with `definition_id = <UUID of definition A>` and `page_size = 50`  
**Then:** Returns exactly two rows; both have `definition_id == UUID of definition A`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` is filterable by `definition_id`

---

### TC-API-03-17: GET /instances — cursor-based pagination returns non-overlapping pages
**Given:** Three instances exist and `page_size = 2`  
**When:** First call to `InstanceStore.listInstances()` with no cursor returns page 1 (2 items + next_cursor signal); second call with the cursor from page 1 returns page 2  
**Then:** Page 1 has exactly 2 rows (the 3rd row causes `has_next = true`); page 2 has exactly 1 row; the union of the two pages contains exactly 3 distinct `instance_id` values  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` supports cursor-based pagination (API-06)

---

### TC-API-03-18: GET /instances — combined status + definition_id filter
**Given:** Instance A (definition X, ACTIVE), Instance B (definition X, COMPLETED), Instance C (definition Y, ACTIVE)  
**When:** `InstanceStore.listInstances()` is called with `status = "ACTIVE"` and `definition_id = <UUID of definition X>`  
**Then:** Returns exactly one row: Instance A  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances` supports combined filters

---

### TC-API-03-19: handleGetById — no task_store involvement for non-ACTIVE instances (tasks list is empty)
**Given:** A COMPLETED instance (no PENDING tasks in tasks table)  
**When:** `handleGetById()` is called  
**Then:** Returns HTTP 200 with `current_tasks: []` in the JSON body  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` returns `current_tasks` correctly for terminal instances

---

### TC-API-03-20: GET /instances/:id — correlation_key is null when not supplied
**Given:** An instance created without a `correlation_key`  
**When:** `InstanceStore.getById()` is called  
**Then:** `correlation_key` field is null in the returned `InstanceWithTasks`  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /instances/:id` returns optional fields correctly

---

### TC-API-03-21: handleList — cursor with valid base64 but invalid internal format returns HTTP 422 INVALID_CURSOR
**Given:** A cursor that is valid base64url but decodes to a string with only one colon (missing the third segment required by OQ-1 option a)  
**When:** `handleList()` is called  
**Then:** Returns `HandlerResult { status_code = 422, body contains "INVALID_CURSOR" }`  
**Layer:** integration (handler-level, no DB needed)  
**Acceptance criterion mapped:** Structurally malformed cursor yields HTTP 422 `INVALID_CURSOR`
