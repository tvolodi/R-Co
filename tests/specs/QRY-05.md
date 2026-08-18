# Test Spec: QRY-05 — Server-side field stripping on query results

**Requirement:** QRY-05  
**Stage:** 17  
**Run ID:** WF02-qry05-sbx01-03-20260818  
**Design:** src/design/WF02-qry05-sbx01-03-20260818.md  
**Implementation:** tests/integration/qry05_field_stripping_test.zig

---

## Scope

QRY-05 adds a field-level read-grant layer to the entity query endpoint
(`POST /api/v1/entities/{entity_key}/query`). Fields a caller has no read
grant for are absent (not null, not redacted) from serialised items. Ungranted
fields are excluded from the filter/sort surface for that caller.

---

## Test cases

### TC-QRY-05-01: Ungranted caller — restricted field absent from every item

**Preconditions:**
- Entity `qry05_a_<rand>` registered with typed field `unit_cost_eur`
- Field restriction row: `(entity_key, field_name='unit_cost_eur', required_grant='entity.read.cost')`
- Caller user does NOT hold `entity.read.cost` in `user_entity_grants`
- Two rows in `ent_qry05_a_<rand>` with non-null `unit_cost_eur` values

**Steps:** Call `handleEntityQuery` with that caller's auth.

**Expected:**
- HTTP 200
- `items` array has 2 elements
- No item object contains a `unit_cost_eur` key at any level

---

### TC-QRY-05-02: Granted caller — restricted field present in every item

**Preconditions:** Same entity and rows as TC-QRY-05-01.  
Caller HOLDS `entity.read.cost` in `user_entity_grants`.

**Steps:** Call `handleEntityQuery`.

**Expected:**
- HTTP 200
- `items` has same count as TC-QRY-05-01 (2 rows)
- Every item contains a `unit_cost_eur` key with a non-null value

---

### TC-QRY-05-03: Ungranted caller filters on restricted field → HTTP 400

**Preconditions:** Same setup as TC-QRY-05-01. Caller lacks grant.

**Steps:** Call `handleEntityQuery` with a filter `{field: "unit_cost_eur", op: "eq", value: 99}`.

**Expected:**
- HTTP 400
- Response body contains `filter_field_not_allowlisted`

---

### TC-QRY-05-04: Ungranted caller sorts on restricted field → HTTP 400

**Preconditions:** Same as TC-QRY-05-01.

**Steps:** Call `handleEntityQuery` with `sort: [{field: "unit_cost_eur", direction: "asc"}]`.

**Expected:**
- HTTP 400
- Response body contains `filter_field_not_allowlisted` (sort uses same gate)

---

### TC-QRY-05-05: All restricted fields stripped — item retains record_id

**Preconditions:**
- Entity registered with two typed fields: `unit_cost_eur`, `secret_note`
- Both fields have restrictions; caller holds grants for neither
- One row in the entity table

**Steps:** Call `handleEntityQuery` with no filter/sort.

**Expected:**
- HTTP 200
- `items` has 1 element
- The item JSON object contains `record_id`
- The item JSON object does NOT contain `unit_cost_eur` or `secret_note`

---

### TC-QRY-05-06: Cross-tenant isolation — field grant for tenant A does not affect tenant B

**Preconditions:**
- Entity key `qry05_x_<rand>` registered for BOTH tenant A and tenant B
- Tenant A: restriction on `unit_cost_eur`; user A HOLDS the grant
- Tenant B: same restriction; user B does NOT hold the grant
- Each tenant has a row in its `ent_qry05_x_<rand>` table

**Steps:** Call `handleEntityQuery` once for each tenant's auth context.

**Expected:**
- Tenant A response includes `unit_cost_eur` in items
- Tenant B response has items WITHOUT `unit_cost_eur`

---

## Coverage mapping

| Test case | MUST acceptance criterion |
|---|---|
| TC-QRY-05-01 | Caller without grant → field absent from every item |
| TC-QRY-05-02 | Granted caller → field present; row set identical |
| TC-QRY-05-03 | Ungranted filter → HTTP 400 filter_field_not_allowlisted |
| TC-QRY-05-04 | Ungranted sort → HTTP 400 filter_field_not_allowlisted |
| TC-QRY-05-05 | Stripping preserves record_id even when all other fields stripped |
| TC-QRY-05-06 | Cross-tenant: grant in tenant A does not affect tenant B |

Total spec cases: 6 | Total implemented `test "..."` blocks: 6
