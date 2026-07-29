# Process: Entity Record Query

| Field | Value |
|-------|-------|
| Process ID | `sys-entity-record-query` |
| Platform Workflow | PW-10 |
| Owner | Platform Admin / Tenant Admin |
| Scope | System-wide (exercised inside tenant `vortex`) |
| Requirements | QRY-01, QRY-02, QRY-03, QRY-04, QRY-05 |
| Source | `docs/workflows.yaml` (PW-10) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.10 |

## Summary

Governs the single structured query surface over tenant-defined entity
projections. A business user filters, sorts, and pages a list of entity records
through one endpoint that accepts a typed request document - never raw SQL.
Filters and sorts are accepted on typed projection columns and on JSONB keys
the entity type has declared filterable; an undeclared key returns 400. An
entity type the caller may not read returns 200 with an empty envelope, so the
response cannot be used to enumerate entity types. Fields the caller may not
read are stripped server-side before serialisation.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Quality Manager | Karl Fischer (Vortex) | Filters the production batch list to find quarantined batches from one supplier |
| CEO / MD | Dirk Haas (Vortex) | Reads the same list including the cost fields Karl is not granted |
| Tenant Admin | Vortex admin | Declares `filterable_jsonb_keys` on the entity type |
| BPM Platform | System | Compiles the request into a parameterised statement, enforces the allowlist, strips fields |
| Projection Store | System | Serves committed rows from `ent_<entity_key>` typed projection tables |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `entity_key` | string | Path segment; must be a registered entity type in the caller's tenant |
| `filters` | array of nodes | Each node is `{field, op, value}`; `op` in `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `contains` |
| `sort` | array of nodes | Each node is `{field, dir}`; `dir` in `asc`, `desc`; at most 2 nodes |
| `page_size` | integer | 1-200; default 50 |
| `cursor` | string | base64url of the previous page's last ordered tuple; omitted on the first page |
| `filterable_jsonb_keys` | string[] (entity type metadata) | Declared per entity type; each entry names a top-level key in `payload` and its type |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Quality Manager | Opens the Production Batches list and applies the filters "status is quarantined" and "supplier is Nordmetall" | - | Portal builds `POST /api/v1/entities/production_batch/query` with a structured body | QRY-01 |
| 2 | Platform | Parses the request document | Body contains a string that is passed to the database as statement text? | Rejected at the type boundary: the request model carries only enum operators and literal values | QRY-01 |
| 3 | Platform | Resolves `entity_key` against the tenant's entity type registry | Entity type unknown in this tenant? | -> 200 with `{"items":[],"next_cursor":null}` | QRY-04 |
| 4 | Platform | Checks the caller's read grant on the entity type | Caller lacks `entity.read` on `production_batch`? | -> 200 with `{"items":[],"next_cursor":null}`; 403 is never returned | QRY-04 |
| 5 | Platform | Validates every `filters[].field` and `sort[].field` against the allowlist: typed columns of `ent_production_batch` plus the entity type's declared `filterable_jsonb_keys` | Field is neither a typed column nor a declared key? | -> 400 `filter_field_not_allowlisted` naming the rejected field | QRY-02 |
| 6 | Platform | Validates each operator against the field's declared type | `contains` on a numeric column, or `lt` on a boolean? | -> 400 `operator_not_valid_for_type` naming field and operator | QRY-02 |
| 7 | Platform | Validates `page_size` | `page_size > 200`? | -> 400 `page_size_exceeds_max`; the request is not executed | QRY-03 |
| 8 | Platform | Compiles the filter tree into a parameterised statement: typed columns become `column = $n`, declared keys become `payload ->> 'key' = $n` with the declared cast | - | Every literal is bound as a parameter; no value reaches the statement text | QRY-01, QRY-02 |
| 9 | Platform | Appends `record_id` as the final sort term and decodes `cursor` into the keyset predicate | Cursor tuple arity differs from the current sort? | -> 400 `cursor_sort_mismatch`; the client restarts from the first page | QRY-03 |
| 10 | Projection Store | Executes the statement against `ent_production_batch` with `LIMIT page_size + 1` | Row count > `page_size`? | Last row is dropped and its ordered tuple becomes `next_cursor` | QRY-03 |
| 11 | Platform | Strips every field the caller has no read grant for from each item before serialisation | Caller lacks the grant on `unit_cost_eur`? | The key is absent from the item; it is not present with a null value | QRY-05 |
| 12 | Quality Manager | Reads the filtered list and pages forward with the returned cursor | `next_cursor` is null? | Last page reached; the portal disables the forward control | QRY-03 |
| 13 | CEO / MD | Runs the same query holding `entity.read.cost` | - | Items include `unit_cost_eur`; the row set is identical to Karl's | QRY-05 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Structured input only | The request carries enum operators, allowlisted field names, and literal values. No request field is concatenated into statement text. |
| Field allowlist | A field is queryable if it is a typed column on `ent_<entity_key>` or an entry in that entity type's `filterable_jsonb_keys`. Every other key is rejected with 400. |
| Declared keys carry a type | Each `filterable_jsonb_keys` entry declares `text`, `numeric`, `boolean`, or `timestamptz`. The compiler emits the matching cast; an operator outside that type's set is a 400. |
| Undeclared key is an error | An undeclared JSONB key is a 400, not an empty result and not a silent drop. The response names the field so the tenant admin can declare it. |
| Unauthorised entity type | An entity type the caller cannot read returns 200 with an empty `items` array and null `next_cursor`. The response is byte-identical to a query that matched no rows. |
| Field stripping is server-side | Fields outside the caller's grants are removed before serialisation. They are never sent as null, and never sent for the client to hide. |
| Max page size | 200. Default 50. A larger `page_size` is a 400 and the query is not executed. |
| Keyset pagination only | Ordering is always terminated by `record_id` to make the sort key total. The cursor encodes the last row's ordered tuple. Offset pagination is not offered. |
| Sort depth | At most 2 client-supplied sort nodes, plus the implicit `record_id` term. |
| Committed projections only | The query reads typed projection tables built from the event log. It performs no writes and holds no state between pages. |
| No placement state machine | This surface borrows the query contract only. It introduces no record placement states and no expand/contract field promotion - those exist to patch a mutable store, and R-Co projections are rebuilt from events instead. |
| Projection rebuild | A projection rebuild changes no part of this contract; `filterable_jsonb_keys` is entity type metadata, not query state. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `items` | Array of entity records with unauthorised fields removed |
| `next_cursor` | base64url of the last row's ordered tuple, or null on the last page |
| `page_size` | Echo of the effective page size after defaulting |
| 400 error body | `filter_field_not_allowlisted`, `operator_not_valid_for_type`, `page_size_exceeds_max`, or `cursor_sort_mismatch`, each naming the offending field |
| Empty envelope | `{"items":[],"next_cursor":null}` for an unknown or unauthorised entity type |
| Query audit entry | `EntityQueryExecuted` with `entity_key`, filter field names, and row count - filter values are not recorded |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Query response | 200 ms at page size 50 | Query request | Platform read NFR; breaches are recorded in the latency histogram |
| Statement timeout | 5 seconds | Statement execution | Statement is cancelled; 503 `query_timeout` returned; no partial page is emitted |
| Cursor validity | Unbounded | Cursor issued | A cursor stays valid across projection rebuilds because it encodes column values, not row offsets |
| No business timer | - | - | This process has no human task and no escalation path |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 400 `filter_field_not_allowlisted` | Filter or sort names a column that does not exist or a JSONB key the entity type has not declared | Tenant admin adds the key to `filterable_jsonb_keys`, or the caller removes the filter |
| 400 `operator_not_valid_for_type` | `contains` on a numeric field, `lt` on a boolean | Caller selects an operator in the field type's set |
| 400 `page_size_exceeds_max` | `page_size` above 200 | Caller lowers the page size and pages forward |
| 400 `cursor_sort_mismatch` | Sort changed between pages, so the cursor arity no longer matches | Client discards the cursor and restarts from the first page |
| 400 `cursor_malformed` | Cursor is not valid base64url or decodes to a non-tuple | Client discards the cursor and restarts from the first page |
| 200 empty envelope | Unknown entity type, or entity type the caller cannot read | Caller cannot distinguish the two cases; the tenant admin confirms the grant out of band |
| 503 `query_timeout` | Statement exceeded 5 seconds | Caller narrows the filter set; tenant admin declares an index-backed key |
| Missing field in item | Caller lacks the read grant on that field | Grant is issued by the tenant admin; the field appears on the next query |
| Projection lag | Query runs while the projection is catching up on recent events | Freshly written records appear once the projection commits; the query never reads uncommitted state |
