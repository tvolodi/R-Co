# Test Spec: API-06 — Shared Cursor-Based Pagination

**Requirement:** API-06 — All list endpoints SHALL support cursor-based pagination per the pagination spec above. Page size SHALL be configurable per request, default 50, maximum 200.
**Priority:** MUST
**Test layer:** unit

---

## Test Cases

### TC-API-06-01: validatePageSize(null) returns default 50
**Given:** No page_size parameter is provided (null)
**When:** `validatePageSize(null)` is called
**Then:** Returns `DEFAULT_PAGE_SIZE` (50)
**Layer:** unit
**Acceptance criterion mapped:** Default page size is 50

---

### TC-API-06-02: validatePageSize(0) returns error
**Given:** page_size = 0
**When:** `validatePageSize(0)` is called
**Then:** Returns `error.PageSizeTooLarge` (N ≤ 0 MUST be rejected per API-06 spec)
**Layer:** unit
**Acceptance criterion mapped:** N ≤ 0 MUST be rejected with HTTP 422

---

### TC-API-06-03: validatePageSize(1) returns 1 (minimum boundary)
**Given:** page_size = 1
**When:** `validatePageSize(1)` is called
**Then:** Returns 1
**Layer:** unit
**Acceptance criterion mapped:** Page size 1..200 is valid

---

### TC-API-06-04: validatePageSize(200) returns 200 (maximum boundary)
**Given:** page_size = 200
**When:** `validatePageSize(200)` is called
**Then:** Returns 200
**Layer:** unit
**Acceptance criterion mapped:** Maximum page size is 200

---

### TC-API-06-05: validatePageSize(201) returns error
**Given:** page_size = 201
**When:** `validatePageSize(201)` is called
**Then:** Returns `error.PageSizeTooLarge`
**Layer:** unit
**Acceptance criterion mapped:** N > 200 MUST be rejected with HTTP 422

---

### TC-API-06-06: encodeCursor / decodeCursor round-trip with valid prefix
**Given:** A raw cursor string "T:1716412800000000:abc123def4567890"
**When:** `encodeCursor` then `decodeCursor` with prefix "T:" and large expiry window
**Then:** Returns a `Cursor` whose `inner` equals the original raw string
**Layer:** unit
**Acceptance criterion mapped:** Cursors are opaque base64-encoded strings; clients MUST NOT parse them

---

### TC-API-06-07: decodeCursor with invalid base64url returns InvalidBase64
**Given:** A string that is not valid base64url (e.g. "!!!not-valid-base64!!!")
**When:** `decodeCursor` is called with prefix "T:" and offset 2
**Then:** Returns `error.InvalidBase64`
**Layer:** unit
**Acceptance criterion mapped:** Malformed cursors are rejected

---

### TC-API-06-08: decodeCursor with wrong prefix returns WrongEndpoint
**Given:** A cursor encoded with prefix "T:" (tasks endpoint)
**When:** `decodeCursor` is called with prefix "I:" (instances endpoint)
**Then:** Returns `error.WrongEndpoint`
**Layer:** unit
**Acceptance criterion mapped:** A cursor from one endpoint MUST NOT be usable on a different endpoint

---

### TC-API-06-09: decodeCursor with expired timestamp (>24h) returns Expired
**Given:** A cursor with an embedded timestamp far in the past (e.g. 1000000000000000)
**When:** `decodeCursor` is called with a 1µs expiry window
**Then:** Returns `error.Expired`
**Layer:** unit
**Acceptance criterion mapped:** Cursors expire 24 hours after creation

---

### TC-API-06-10: decodeCursor with malformed segments returns InvalidBase64
**Given:** A cursor with a valid base64url encoding but whose decoded content has no colon separator after the prefix (i.e. no timestamp segment)
**When:** `decodeCursor` is called
**Then:** Returns `error.InvalidBase64`
**Layer:** unit
**Acceptance criterion mapped:** Malformed cursor structure is rejected

---

### TC-API-06-11: decodeCursor with empty decoded payload returns error
**Given:** A cursor that decodes to an empty string or a string shorter than the prefix
**When:** `decodeCursor` is called with prefix "T:"
**Then:** Returns `error.WrongEndpoint` or `error.InvalidBase64`
**Layer:** unit
**Acceptance criterion mapped:** Edge case: empty cursor payload

---

### TC-API-06-12: decodeCursor with truncated timestamp (no trailing colon) returns InvalidBase64
**Given:** A cursor whose decoded content is "T:17164128" (timestamp segment present but no colon after it)
**When:** `decodeCursor` is called with prefix "T:" and offset 2
**Then:** Returns `error.InvalidBase64` (or succeeds by parsing entire remainder as timestamp)
**Layer:** unit
**Acceptance criterion mapped:** Robust timestamp extraction edge cases

---

### TC-API-06-13: buildRawCursor produces correct `PREFIX:ts:key` format
**Given:** prefix = "T:", timestamp_us = 1716412800000000, key = "abc123"
**When:** `buildRawCursor` is called
**Then:** Returns "T:1716412800000000:abc123"
**Layer:** unit
**Acceptance criterion mapped:** Cursor format convention

---

### TC-API-06-14: buildRawCursorTimestampKey produces correct format
**Given:** prefix = "I:", sort_timestamp_us = 1716412800000000, key = "abc123", cursor_created_at_us = 1716412860000000
**When:** `buildRawCursorTimestampKey` is called
**Then:** Returns "I:1716412800000000:abc123:1716412860000000"
**Layer:** unit
**Acceptance criterion mapped:** Three-segment cursor format for timestamp-sorted endpoints

---

### TC-API-06-15: parseIntFromCursor extracts correct value
**Given:** decoded = "T:1716412800000000:abc123", offset = 2, len = 16
**When:** `parseIntFromCursor` is called
**Then:** Returns 1716412800000000
**Layer:** unit
**Acceptance criterion mapped:** Helper function for cursor parsing

---

### TC-API-06-16: parseIntFromCursor with out-of-bounds range returns InvalidCursor
**Given:** decoded = "short", offset = 2, len = 100
**When:** `parseIntFromCursor` is called
**Then:** Returns `error.InvalidCursor`
**Layer:** unit
**Acceptance criterion mapped:** Robust error handling for malformed cursors

---

### TC-API-06-17: findNthColon locates correct colon positions
**Given:** "T:1716412800000000:abc123"
**When:** findNthColon called with n=1, n=2, n=3
**Then:** Returns indices 1, 18, null respectively
**Layer:** unit
**Acceptance criterion mapped:** Cursor segment parsing helper

---

### TC-API-06-18: findNthColon with no colons returns null
**Given:** "no-colons-here"
**When:** findNthColon called with n=1
**Then:** Returns null
**Layer:** unit
**Acceptance criterion mapped:** Edge case for cursor parsing helper

---

### TC-API-06-19: findNthColon with three-segment I: cursor
**Given:** "I:1716412800000000:abc123def456:1716412860000000"
**When:** findNthColon called with n=1, n=2, n=3
**Then:** All positions are valid non-null
**Layer:** unit
**Acceptance criterion mapped:** Three-segment cursor parsing for instance endpoint

---

### TC-API-06-20: Cursor.deinit frees inner buffer
**Given:** A successfully decoded Cursor
**When:** `cursor.deinit()` is called
**Then:** No memory leak (verifiable via allocator)
**Layer:** unit
**Acceptance criterion mapped:** Memory safety for cursor lifecycle
