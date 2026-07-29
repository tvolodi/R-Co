> **Extends:** FIL-05, closing the existence oracle on the attachment read path.

> A request for an attachment that does not exist and a request for an attachment owned by another tenant SHALL both return HTTP 404 `attachment_not_found` with a byte-identical response body and an identical header set. The attachment read path SHALL NOT return HTTP 403 for a cross-tenant reference at any endpoint, so no response code, body, header, or latency difference can be used to establish that an `attachment_id` exists in another tenant.

**Acceptance Criteria:**
- GIVEN a `swiftroute` session and an `attachment_id` that exists in `vortex`, WHEN metadata is requested, THEN the platform returns HTTP 404 `attachment_not_found`.
- GIVEN the same session and a UUID that exists in no tenant, WHEN metadata is requested, THEN the response body and headers are byte-identical to the cross-tenant case above.
- GIVEN a cross-tenant `attachment_id`, WHEN a download link is requested, THEN the platform returns HTTP 404 and issues no signed URL, so the signing path leaks no existence signal either.
- GIVEN a cross-tenant reference, WHEN the tenant scope filter is applied, THEN it is applied in the same query that loads the row, so a found-then-rejected code path that would differ in latency does not exist.
- Every cross-tenant attachment reference appends an audit entry naming the session tenant, the requested `attachment_id`, and the owning tenant, even though the response carries no such detail.

**See:** FIL-05, FIL-02, TNT-01, XC-05, OBS-03
