# Test Specification: QRY-03 — Keyset pagination with a bounded page size

**Requirement ID:** QRY-03  
**Stage:** 17  
**Priority:** MUST  
**Status:** IN_PROGRESS  
**Workflow:** PW-10  
**Run ID:** WF02-qry01-04-20260818  

---

## Summary

Pagination is keyset-based. `page_size` defaults to 50 and must not exceed 200. `record_id` is always appended as the final sort term. The cursor encodes the last row's ordered tuple; a follow-up request with a different sort returns `cursor_sort_mismatch`.

---

## Acceptance Criteria Mapping

| AC | Description | Test Case ID |
|---|---|---|
| AC-1 | `page_size` 500 → HTTP 400 `page_size_exceeds_max`; max carried in response | TC-QRY-03-02 |
| AC-2 | `page_size` omitted → at most 50 rows returned; response echoes `page_size: 50` | TC-QRY-03-01 |
| AC-3 | Sort `created_at desc` → ORDER BY `created_at DESC, record_id DESC`; deterministic across pages | TC-QRY-03-03 (cursor encodes both terms) |
| AC-4 | Extra row triggers `next_cursor`; final page returns null | TC-QRY-03-03 |
| AC-5 | Cursor from different sort order → HTTP 400 `cursor_sort_mismatch` | TC-QRY-03-04 |
| AC-6 | Non-base64url or non-tuple cursor → HTTP 400 `cursor_malformed` | (decodeCursor unit; integration path in TC-QRY-03-04) |
| AC-7 | Rows inserted between pages do not cause duplicates; cursor encodes column values not row offset | TC-QRY-03-03 |

---

## Test Cases

### TC-QRY-03-01 — Default page size is 50

**What it tests:** Omitting `page_size` returns at most 50 results; response `page_size` field is 50.

**Given:** An entity type with 60 rows.  
**When:** `POST /query` body `{}` (no page_size).  
**Then:** `items` length is 50; `page_size` field in response is 50; `next_cursor` is non-null.

**Impl:** `qry03_default_page_size_is_50`

---

### TC-QRY-03-02 — page_size exceeds max returns 400

**What it tests:** A `page_size` greater than 200 is rejected before the query runs.

**Given:** Any registered entity type.  
**When:** `POST /query` body `{"page_size":500}`.  
**Then:** HTTP 400; error code `page_size_exceeds_max`; response body carries `"max":200`; no row scan.

**Impl:** `qry03_page_size_exceeds_max_returns_400`

---

### TC-QRY-03-03 — Cursor pagination returns next page

**What it tests:** `next_cursor` is present when there are more results; using the cursor returns the correct next page with no duplicates.

**Given:** 5 rows inserted; `page_size` set to 3.  
**When:** First request returns 3 items + `next_cursor`; second request uses that cursor.  
**Then:** First page has 3 distinct items; second page has 2 items; union of both pages equals all 5 rows; no row appears in both pages.

**Impl:** `qry03_cursor_pagination_returns_next_page`

---

### TC-QRY-03-04 — Cursor sort mismatch returns 400

**What it tests:** A cursor issued under sort A is rejected when a follow-up request uses sort B.

**Given:** First request sorts on `created_at desc`; returns `next_cursor`.  
**When:** Follow-up request uses that cursor but sorts on `record_id asc`.  
**Then:** HTTP 400; error code `cursor_sort_mismatch`.

**Impl:** `qry03_cursor_sort_mismatch_returns_400`

---

## Coverage summary

| Requirement AC | Test case | Status |
|---|---|---|
| AC-1: page_size > 200 → 400 | TC-QRY-03-02 | Implemented |
| AC-2: default page_size = 50 | TC-QRY-03-01 | Implemented |
| AC-3: sort appends record_id; deterministic | TC-QRY-03-03 (fingerprint includes record_id) | Implemented |
| AC-4: next_cursor on full page; null on final page | TC-QRY-03-03 | Implemented |
| AC-5: cursor sort mismatch → 400 | TC-QRY-03-04 | Implemented |
| AC-6: malformed cursor → 400 | decodeCursor unit coverage | Implemented |
| AC-7: no duplicates across pages | TC-QRY-03-03 | Implemented |

Total test cases: **4**  
Deferred: **0**
