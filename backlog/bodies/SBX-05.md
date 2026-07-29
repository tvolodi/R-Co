> **Extends:** SBX-04, closing the sandbox existence oracle across tenants.

> A sandbox that does not exist, a sandbox owned by another tenant, and a sandbox owned by another principal in the caller's tenant SHALL all return HTTP 403 `sandbox_not_accessible` with a byte-identical response body and an identical header set. One sentinel error covers all three cases, so no response code, body, header, or latency difference can be used to establish that a `sandbox_id` exists outside the caller's ownership. The tenant scope filter SHALL be applied in the same query that loads the sandbox row, so a found-then-rejected path that would differ in timing does not exist.

**Acceptance Criteria:**
- GIVEN a `sandbox_id` that exists in no tenant, WHEN an implementer references it, THEN the platform returns HTTP 403 `sandbox_not_accessible`.
- GIVEN a `sandbox_id` that exists in another tenant, WHEN an implementer references it, THEN the response body and headers are byte-identical to the unknown-sandbox case above.
- GIVEN a `sandbox_id` in the caller's tenant bound to another principal, WHEN an execution request is issued, THEN the same HTTP 403 `sandbox_not_accessible` is returned.
- GIVEN the sentinel is returned, WHEN the row is loaded, THEN the tenant predicate is part of the loading query, so the unknown and cross-tenant cases execute the same statement shape and return in the same latency band.
- GIVEN a caller probing 100 sequential UUIDs, WHEN each returns the sentinel, THEN no response distinguishes an existing sandbox from a nonexistent one, and after 20 sentinel responses in one minute the principal receives HTTP 429 `probe_rate_exceeded`.
- HTTP 409 `sandbox_already_claimed` of SBX-04 is returned only for a sandbox already visible to the caller within its own tenant, so it discloses no cross-tenant existence.

**See:** SBX-04, SBX-06, TNT-01, XC-05, FIL-06
