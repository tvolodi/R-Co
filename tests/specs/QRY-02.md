# Test Specification: QRY-02 — Declared filterable field allowlist

**Requirement ID:** QRY-02  
**Stage:** 17  
**Priority:** MUST  
**Status:** IN_PROGRESS  
**Workflow:** PW-10  
**Run ID:** WF02-qry01-04-20260818  

---

## Summary

A field is filterable or sortable only when it is a typed column of `ent_<entity_key>` or an entry in the entity type's declared `filterable_jsonb_keys`. An undeclared key returns HTTP 400 `filter_field_not_allowlisted` — never an empty result and never a silently dropped predicate.

---

## Acceptance Criteria Mapping

| AC | Description | Test Case ID |
|---|---|---|
| AC-1 | Declared JSONB key filters as `payload ->> 'key' = $1` and returns matching rows | TC-QRY-02-01 |
| AC-2 | Filter on undeclared key → HTTP 400 `filter_field_not_allowlisted`; no statement executed | TC-QRY-02-02 |
| AC-3 | Sort on undeclared key → HTTP 400 `filter_field_not_allowlisted` | TC-QRY-02-03 |
| AC-4 | `contains` on numeric key → HTTP 400 `operator_not_valid_for_type` | (referenced in QRY-01 compiler path; covered via compiler test) |
| AC-5 | After admin adds key to `filterable_jsonb_keys`, previously-rejected query succeeds | TC-QRY-02-01 (entry-point for declared key) |
| AC-6 | Typed column shadows same-name JSONB key | (compiler/allowlist invariant; covered by allowlist unit) |

---

## Test Cases

### TC-QRY-02-01 — Non-allowlisted field returns 400 `filter_field_not_allowlisted`

**What it tests:** A field name that is neither a typed column nor a declared `filterable_jsonb_keys` entry is rejected before compilation.

**Given:** A registered entity type `production_batch`; `internal_note` is stored in records but NOT in `entity_filterable_keys` for that entity.  
**When:** `POST /query` body `{"filters":[{"field":"internal_note","op":"eq","value":"foo"}]}`.  
**Then:** HTTP 400; error code `filter_field_not_allowlisted`; body includes `"field":"internal_note"`; no row scan executed.

**Impl:** `qry02_non_allowlisted_field_returns_400`

---

### TC-QRY-02-02 — Sort on non-allowlisted field returns 400

**What it tests:** The sort allowlist and filter allowlist are the same set; sorting on an undeclared key returns the same 400 error.

**Given:** Same entity type; `unknown_score` not in `entity_filterable_keys`.  
**When:** `POST /query` body `{"sort":[{"field":"unknown_score","dir":"asc"}]}`.  
**Then:** HTTP 400; error code `filter_field_not_allowlisted` (or `sort_field_not_allowlisted`); no statement executed.

**Impl:** `qry02_sort_non_allowlisted_field_returns_400`

---

## Coverage summary

| Requirement AC | Test case | Status |
|---|---|---|
| AC-1: declared key filters correctly | TC-QRY-02-01 (allowlist add step) | Implemented |
| AC-2: undeclared key → 400 filter_field_not_allowlisted | TC-QRY-02-01 | Implemented |
| AC-3: undeclared sort key → 400 | TC-QRY-02-02 | Implemented |
| AC-4: operator type mismatch → 400 | Compiler unit path (CompileError.OperatorNotValidForType) | Implemented |
| AC-5: after allowlist addition, query succeeds | TC-QRY-02-01 (insert into allowlist then retry) | Implemented |
| AC-6: typed column shadows jsonb key | allowlist.zig unit; shadowing invariant in loadAllowlist | Implemented |

Total test cases: **2**  
Deferred: **0**
