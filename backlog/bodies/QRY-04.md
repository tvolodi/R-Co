> **Extends:** QRY-01, closing the entity type existence oracle.

> An `entity_key` that is not registered in the caller's tenant and an `entity_key` the caller has no `entity.read` grant for SHALL both return HTTP 200 with the empty envelope `{"items": [], "next_cursor": null}`. The query surface SHALL NOT return HTTP 403 or HTTP 404 for an entity type at any point, so a caller cannot use the response to establish which entity types a tenant has defined or which ones it is excluded from.

**Acceptance Criteria:**
- GIVEN a caller without `entity.read` on `production_batch`, WHEN it queries that entity type, THEN the platform returns HTTP 200 with `{"items": [], "next_cursor": null}`.
- GIVEN a caller queries `entity_key` `nonexistent_type`, WHEN the registry lookup misses, THEN the response body and headers are byte-identical to the unauthorised case above.
- GIVEN a caller with the grant queries an entity type holding zero matching rows, WHEN the query executes, THEN the response is the same empty envelope; the three cases are indistinguishable to the client.
- GIVEN an unauthorised entity type, WHEN the request also carries an undeclared filter key, THEN the authorisation outcome is decided first and the response is HTTP 200 with the empty envelope, not HTTP 400; the QRY-02 error path is not reachable without a read grant.
- GIVEN an unauthorised or unknown entity type, WHEN the request is handled, THEN no `ent_<entity_key>` table is queried and the response is produced from the registry lookup alone.
- Every empty-envelope response for an unauthorised or unknown entity type appends an audit entry naming the caller, the tenant, and the requested `entity_key`.

**See:** QRY-01, QRY-02, QRY-05, IDN-05, TNT-01, OBS-03
