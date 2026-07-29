---
id: API-06
title: Pagination
stage: 4
priority: MUST
status: RELEASED
---

# API-06 — Pagination `[MUST]`

> All list endpoints SHALL support cursor-based pagination. Page size SHALL be configurable per request, default 50, maximum 200.

**Acceptance Criteria:**
- All list endpoints return a `cursor` field in the response body when more pages are available. If `cursor` is absent, the caller has received the last page.
- Callers pass the cursor via `?cursor=<value>` on subsequent requests.
- Cursors are opaque base64-encoded strings; clients MUST NOT parse them.
- Cursors expire 24 hours after creation. An expired cursor returns HTTP 410 with a message to start fresh.
- Default page size is 50. Callers specify `?page_size=N` where N ≤ 200. N > 200 MUST be rejected with HTTP 422. N ≤ 0 MUST be rejected with HTTP 422.
- A cursor from one endpoint MUST NOT be usable on a different endpoint.

**See:** API-01 (REST conventions), API-02..API-05 (all apply this pagination contract)

**Edge cases:**
- Empty result set: HTTP 200, empty `items` array, no `cursor`.
- Single item fitting on the first page: HTTP 200, no `cursor`.
- Data changes between pages: new records after cursor creation may not appear until a fresh query.
