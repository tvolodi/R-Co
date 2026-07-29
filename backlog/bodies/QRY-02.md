> **Extends:** QRY-01, bounding the queryable surface to an explicit allowlist.

> A field SHALL be filterable or sortable only when it is a typed column of the `ent_<entity_key>` projection table or an entry in that entity type's declared `filterable_jsonb_keys`. Each `filterable_jsonb_keys` entry names a top-level key in the `payload` column and declares its type as `text`, `numeric`, `boolean`, or `timestamptz`; the compiler emits `payload ->> '<key>'` with the declared cast. A field that is neither a typed column nor a declared key SHALL be rejected with HTTP 400 `filter_field_not_allowlisted` naming the field. An undeclared key is an error, never an empty result and never a silently dropped predicate.

**Acceptance Criteria:**
- GIVEN entity type `production_batch` declares `filterable_jsonb_keys` of `supplier_name` (text) and `defect_rate` (numeric), WHEN a query filters on `supplier_name`, THEN the compiler emits `payload ->> 'supplier_name' = $1` and returns the matching rows.
- GIVEN a query filters on `payload` key `internal_note`, which is present in stored records but absent from `filterable_jsonb_keys`, WHEN the request is validated, THEN the platform returns HTTP 400 `filter_field_not_allowlisted` with `"field": "internal_note"` and executes no statement.
- GIVEN a query sorts on an undeclared key, WHEN the request is validated, THEN the same HTTP 400 `filter_field_not_allowlisted` is returned; the sort allowlist and the filter allowlist are the same set.
- GIVEN a filter applies `contains` to the numeric key `defect_rate`, WHEN the request is validated, THEN the platform returns HTTP 400 `operator_not_valid_for_type` naming the field and the operator.
- GIVEN a tenant admin adds `internal_note` to `filterable_jsonb_keys` with type `text`, WHEN the earlier rejected query is re-issued, THEN it executes and returns rows without any change to the request document.
- A typed column and a declared key of the same name resolve to the typed column; the entity type registry rejects a `filterable_jsonb_keys` entry that shadows a typed column name at declaration time.

**See:** QRY-01, QRY-03, QRY-05, ADP-09, TNT-01
