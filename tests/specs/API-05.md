# Test Spec: API-05 — History endpoint

**Requirement:** API-05 — `GET /instances/:id/history` SHALL return the full ordered event log for an instance, with optional filtering by event type and time range.  
**Priority:** MUST  
**Test layer:** unit, integration

> API-06 pagination is also covered here as it is inseparable from API-05.

---

## Test Cases

### TC-API-05-01: GET /instances/:id/history returns events in ascending sequence order (happy path)
**Given:** An ACTIVE instance with 5 events (INSTANCE_STARTED, TASK_CREATED, TASK_COMPLETED, INSTANCE_COMPLETED, VARIABLE_UPDATED)  
**When:** `GET /instances/:id/history` with default page_size=50  
**Then:** Returns HTTP 200, `count = 5`, `items` in sequence_number 1→5 order, `next_cursor = null`  
**Layer:** integration  
**Acceptance criterion mapped:** Returns all events for the instance in ascending sequence order

---

### TC-API-05-02: Instance not found → HTTP 404
**Given:** A UUID that does not exist in instance_projections  
**When:** `GET /instances/:id/history`  
**Then:** Returns HTTP 404 with error code INSTANCE_NOT_FOUND  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 404 if instance not found

---

### TC-API-05-03: Instance exists but has no events → empty list, HTTP 200
**Given:** An instance exists in instance_projections but has zero events  
**When:** `GET /instances/:id/history`  
**Then:** Returns HTTP 200, `items = []`, `count = 0`, `next_cursor = null`  
**Layer:** integration  
**Acceptance criterion mapped:** Instance with no events returns empty list, HTTP 200

---

### TC-API-05-04: Filter by event_type returns only matching events
**Given:** An instance with events of types INSTANCE_STARTED, TASK_CREATED, TASK_COMPLETED  
**When:** `GET /instances/:id/history?event_type=TASK_CREATED`  
**Then:** Returns only events where `event_type = "TASK_CREATED"`  
**Layer:** integration  
**Acceptance criterion mapped:** Optional query parameter `event_type` filters to a specific event type

---

### TC-API-05-05: Filter by from/to timestamps (inclusive bounds)
**Given:** An instance with events at times t1, t2, t3 (t1 < t2 < t3)  
**When:** `GET /instances/:id/history?from=<t2>&to=<t3>`  
**Then:** Returns events with created_at between t2 and t3 (inclusive)  
**Layer:** integration  
**Acceptance criterion mapped:** `from` and `to` ISO 8601 timestamps, inclusive

---

### TC-API-05-06: from > to → HTTP 422
**Given:** `from = "2026-06-01T00:00:00Z"`, `to = "2026-01-01T00:00:00Z"`  
**When:** `GET /instances/:id/history?from=...&to=...`  
**Then:** Returns HTTP 422 with error code INVALID_TIMESTAMP_RANGE  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** `from` > `to` yields HTTP 422

---

### TC-API-05-07: Unknown event_type → HTTP 422
**Given:** An unregistered `event_type` value  
**When:** `GET /instances/:id/history?event_type=NONEXISTENT_TYPE`  
**Then:** Returns HTTP 422 with error code UNKNOWN_EVENT_TYPE  
**Layer:** integration (requires registry)  
**Acceptance criterion mapped:** Unknown event_type returns proper error

---

### TC-API-05-08: Cursor pagination — next_cursor present when more events
**Given:** An instance with 120 events, `page_size = 50`  
**When:** `GET /instances/:id/history` (first page)  
**Then:** Returns HTTP 200, `count = 50`, `next_cursor` is a non-null base64url string starting with "H:" prefix pattern when decoded  
**Layer:** integration  
**Acceptance criterion mapped:** Results are paginated per API-06, next_cursor present

---

### TC-API-05-09: Last page has null next_cursor
**Given:** An instance with 60 events, `page_size = 50`  
**When:** Request second page via cursor from first page  
**Then:** Returns HTTP 200, `count = 10`, `next_cursor = null`  
**Layer:** integration  
**Acceptance criterion mapped:** Last page has null next_cursor

---

### TC-API-05-10: Invalid cursor format → HTTP 422
**Given:** A malformed cursor string that is not valid base64url  
**When:** `GET /instances/:id/history?cursor=!!!invalid!!!`  
**Then:** Returns HTTP 422 with error code INVALID_CURSOR  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Invalid cursor yields HTTP 422

---

### TC-API-05-11: Expired cursor (>24h) → HTTP 410
**Given:** A cursor encoded with `now_us` older than 24 hours  
**When:** `GET /instances/:id/history?cursor=<expired-cursor>`  
**Then:** Returns HTTP 410 with error code CURSOR_EXPIRED  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Expired cursor yields HTTP 410

---

### TC-API-05-12: page_size validation (≤0 → 422, >200 → 422, default 50)
**Given:** Various invalid page_size values  
**When:** `GET /instances/:id/history?page_size=0` and `?page_size=201`  
**Then:** Both return HTTP 422 with error code INVALID_PAGE_SIZE  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** page_size ≤ 0 and > 200 yield HTTP 422

---

### TC-API-05-13: Archived events returned interleaved with live events in correct sequence
**Given:** An instance where some events have been archived (exist in events_archive) and some remain in events  
**When:** `GET /instances/:id/history`  
**Then:** All events are returned in correct sequence_number order regardless of which table they came from  
**Layer:** integration  
**Acceptance criterion mapped:** Archived events (ES-07) MUST be included in their correct sequence position

---

### TC-API-05-14: ISO 8601 timestamp parsing (UTC, timezone offsets)
**Given:** Valid ISO 8601 timestamps in various formats  
**When:** Passed as `from` or `to` to handleHistory  
**Then:** Parse correctly (no HTTP 422) for valid formats; HTTP 422 INVALID_TIMESTAMP for invalid formats  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** ISO 8601 timestamps accepted

---

### TC-API-05-15: Invalid instance_id UUID → HTTP 422
**Given:** A non-UUID string as the instance_id path parameter  
**When:** `handleHistory()` is called with `instance_id_str = "not-a-uuid"`  
**Then:** Returns HTTP 422 with error code INVALID_INSTANCE_ID  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Invalid UUID format yields HTTP 422

---

### TC-API-05-16: Cursor decode — valid cursor with correct "H:" prefix
**Given:** A properly encoded cursor: base64url_no_pad("H:1234567890:42")  
**When:** Passed as `cursor` to handleHistory with a valid UUID  
**Then:** The handler extracts `after_sequence = 42` and proceeds to readHistory  
**Layer:** unit (handler-level decode, store access will fail with SkipZigTest)  
**Acceptance criterion mapped:** Cursor-based pagination works correctly

---

### TC-API-05-17: Cursor decode — cross-endpoint cursor (e.g. "T:" prefix) → HTTP 422
**Given:** A cursor encoded with a different endpoint prefix: base64url_no_pad("T:...")  
**When:** Passed as `cursor` to handleHistory  
**Then:** Returns HTTP 422 with error code INVALID_CURSOR  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Cross-endpoint cursor reuse properly rejected

---

### TC-API-05-18: Invalid from timestamp → HTTP 422
**Given:** `from = "not-a-date"`  
**When:** handleHistory is called  
**Then:** Returns HTTP 422 with error code INVALID_TIMESTAMP  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Invalid timestamps yield HTTP 422

---

### TC-API-05-19: Invalid to timestamp → HTTP 422
**Given:** `to = "2026-13-01T00:00:00Z"` (month 13 is invalid)  
**When:** handleHistory is called  
**Then:** Returns HTTP 422 with error code INVALID_TIMESTAMP  
**Layer:** unit (handler-level validation, no DB needed)  
**Acceptance criterion mapped:** Invalid timestamps yield HTTP 422
