> **Extends:** API-06, applying keyset paging to the generic entity query surface.

> Pagination SHALL be keyset-based. `page_size` defaults to 50 and SHALL NOT exceed 200; a larger value returns HTTP 400 `page_size_exceeds_max` and the query is not executed. The platform SHALL append `record_id` as the final sort term on every query so the ordering key is total, and SHALL accept at most 2 client-supplied sort nodes. `cursor` is the base64url encoding of the previous page's last row ordered tuple; the platform decodes it into the keyset predicate. Offset pagination is not offered on this surface.

**Acceptance Criteria:**
- GIVEN `page_size` of 500, WHEN the query is validated, THEN the platform returns HTTP 400 `page_size_exceeds_max` carrying the maximum of 200, and executes no statement.
- GIVEN `page_size` omitted, WHEN the query executes, THEN 50 rows at most are returned and the response echoes `page_size` of 50.
- GIVEN a sort of `created_at desc`, WHEN the statement is compiled, THEN the ORDER BY is `created_at DESC, record_id DESC`, and two rows sharing a `created_at` value have a deterministic relative order across pages.
- GIVEN a page whose row count reaches `page_size`, WHEN the platform selects `LIMIT page_size + 1`, THEN the extra row is dropped from `items` and its ordered tuple is encoded as `next_cursor`; the final page returns `next_cursor` of null.
- GIVEN a cursor issued under a sort of `created_at desc` and a follow-up request sorting on `batch_number asc`, WHEN the cursor is decoded, THEN the platform returns HTTP 400 `cursor_sort_mismatch` and the client restarts from the first page.
- GIVEN a cursor that is not valid base64url or that decodes to a non-tuple, WHEN it is decoded, THEN the platform returns HTTP 400 `cursor_malformed`.
- GIVEN rows are inserted between two page requests, WHEN the second page is fetched with the cursor, THEN no row from the first page reappears; the cursor encodes column values, not a row offset.

**See:** API-06, QRY-01, QRY-02, ADP-09
