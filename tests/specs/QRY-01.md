# Test Specification: QRY-01 — Structured entity query surface

**Requirement ID:** QRY-01  
**Stage:** 17  
**Priority:** MUST  
**Status:** IN_PROGRESS  
**Workflow:** PW-10  
**Run ID:** WF02-qry01-04-20260818  

---

## Summary

The platform exposes `POST /api/v1/entities/{entity_key}/query` accepting a filter/sort/pagination DSL. No request field is concatenated into SQL text. The surface reads committed typed projection tables `ent_<entity_key>` and performs no write. An `EntityQueryExecuted` audit row is appended with filter field names and row count but never filter values.

---

## Acceptance Criteria Mapping

| AC | Description | Test Case ID |
|---|---|---|
| AC-1 | `op` outside enum → HTTP 400 `operator_not_recognised`, no statement executed | TC-QRY-01-02 |
| AC-2 | Filter value `' OR 1=1 --` bound as positional param; statement text contains no part of the value | TC-QRY-01-03 |
| AC-3 | Raw SQL fragment in any field rejected before compilation; no field's contents reach DB as statement text | TC-QRY-01-01, TC-QRY-01-03 |
| AC-4 | Valid query reads only `ent_<entity_key>` in caller's tenant; issues no INSERT/UPDATE/DELETE | TC-QRY-01-04 |
| AC-5 | `EntityQueryExecuted` appended with `entity_key`, filter field names, row count; filter values NOT recorded | TC-QRY-01-05 |

---

## Test Cases

### TC-QRY-01-01 — Valid eq filter returns matching rows

**What it tests:** A well-formed query with a single `eq` filter returns exactly the rows whose field matches the supplied value.

**Given:** A tenant has `ent_<entity_key>` with 3 rows; one row has `status = 'active'`.  
**When:** `POST /query` body `{"filters":[{"field":"status","op":"eq","value":"active"}]}`.  
**Then:** Response HTTP 200; `items` contains exactly 1 row; the matching row's `status` column value is `"active"`.

**Impl:** `qry01_valid_eq_filter_returns_matching_rows`

---

### TC-QRY-01-02 — Unknown operator returns 400 `operator_not_recognised`

**What it tests:** An `op` value not in the `FilterOp` enum is rejected before SQL compilation.

**Given:** A registered entity type the caller has access to.  
**When:** `POST /query` body `{"filters":[{"field":"status","op":"LIKE","value":"act%"}]}`.  
**Then:** HTTP 400; error code `operator_not_recognised`; no row scan occurs (audit row is **not** `EntityQueryExecuted` — no statement executed).

**Impl:** `qry01_unknown_op_returns_400_operator_not_recognised`

---

### TC-QRY-01-03 — Filter value is positional param, not interpolated into SQL

**What it tests:** SQL injection defence — the compiled SQL contains `$N`, not the literal filter value.

**Given:** A registered entity type with an allowlisted `status` text field.  
**When:** `POST /query` body `{"filters":[{"field":"status","op":"eq","value":"' OR 1=1 --"}]}`.  
**Then:** The compiled SQL string (inspected via compiler unit-level call) contains `$` parameter placeholders; the literal string `' OR 1=1 --` does NOT appear anywhere in the SQL text.

**Impl:** `qry01_filter_value_is_positional_param_not_interpolated`

---

### TC-QRY-01-04 — Query executes SELECT only, no DML

**What it tests:** The query surface is read-only; no INSERT/UPDATE/DELETE is issued in the handler.

**Given:** A registered entity type; 2 rows exist.  
**When:** `POST /query` with empty filters.  
**Then:** HTTP 200 returned; row count in table is unchanged after the query.

**Impl:** `qry01_read_only_no_dml`

---

### TC-QRY-01-05 — Audit event recorded without filter values

**What it tests:** `EntityQueryExecuted` audit row is written with field names and row count; filter values are absent from the audit payload.

**Given:** A registered entity type with `status` text field allowlisted; 1 matching row.  
**When:** `POST /query` body `{"filters":[{"field":"status","op":"eq","value":"secret_value_123"}]}`.  
**Then:** Audit log contains one `EntityQueryExecuted` row for the caller+tenant+entity_key; the payload contains `filter_field_names` including `"status"`; the payload does NOT contain the string `"secret_value_123"`.

**Impl:** `qry01_audit_event_recorded_without_filter_values`

---

## Coverage summary

| Requirement AC | Test case | Status |
|---|---|---|
| AC-1: unknown op → 400 | TC-QRY-01-02 | Implemented |
| AC-2: SQL injection defence (positional param) | TC-QRY-01-03 | Implemented |
| AC-3: no field content reaches DB as statement text | TC-QRY-01-01, TC-QRY-01-03 | Implemented |
| AC-4: read-only, SELECT only | TC-QRY-01-04 | Implemented |
| AC-5: audit records field names not values | TC-QRY-01-05 | Implemented |

Total test cases: **5**  
Deferred: **0**
