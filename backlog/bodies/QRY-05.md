> **Extends:** QRY-01, enforcing field-level read grants on the server.

> Fields the caller has no read grant for SHALL be removed from every item before serialisation. A stripped field SHALL be absent from the JSON object, not present with a null value, an empty string, or a redaction marker, so the response carries no signal that the field exists. Stripping SHALL happen on the server; the client is never sent a value it is expected to hide. A stripped field remains usable as a filter or sort term only when the caller holds the read grant for it.

**Acceptance Criteria:**
- GIVEN a quality manager without `entity.read.cost`, WHEN the production batch list is queried, THEN no item carries a `unit_cost_eur` key at all.
- GIVEN a managing director holding `entity.read.cost`, WHEN the same query is issued, THEN every item carries `unit_cost_eur` and the row set is identical to the quality manager's row set.
- GIVEN a caller without the grant on `unit_cost_eur`, WHEN it filters on `unit_cost_eur`, THEN the platform returns HTTP 400 `filter_field_not_allowlisted` naming the field; an ungranted field is not a queryable field for that caller.
- GIVEN a caller without the grant on `unit_cost_eur`, WHEN it sorts on `unit_cost_eur`, THEN the same HTTP 400 is returned and no ordering by the ungranted field is performed.
- GIVEN stripping removes every field of an item except `record_id`, WHEN the response is serialised, THEN the item is still present with `record_id` alone; row visibility and field visibility are separate decisions.
- Stripping is applied to the serialised item after the statement returns, and the stripped field names are not listed anywhere in the response.

**See:** QRY-01, QRY-02, QRY-04, IDN-05, TNT-01
