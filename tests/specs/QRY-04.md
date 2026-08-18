# Test Specification: QRY-04 — Empty envelope for unauthorised entity types

**Requirement ID:** QRY-04  
**Stage:** 17  
**Priority:** MUST  
**Status:** IN_PROGRESS  
**Workflow:** PW-10  
**Run ID:** WF02-qry01-04-20260818  

---

## Summary

An `entity_key` that is not registered in the caller's tenant and an `entity_key` the caller has no `entity.read` grant for both return HTTP 200 with the empty envelope `{"items":[],"next_cursor":null,"page_size":50}`. The query surface never returns HTTP 403 or HTTP 404 — a caller cannot determine which entity types exist or which ones they are excluded from.

---

## Acceptance Criteria Mapping

| AC | Description | Test Case ID |
|---|---|---|
| AC-1 | Caller without `entity.read` on entity → HTTP 200 empty envelope | TC-QRY-04-01 |
| AC-2 | Unknown `entity_key` → response byte-identical to deny case | TC-QRY-04-02 |
| AC-3 | Granted caller + zero matching rows → same empty envelope | TC-QRY-04-01 (separate path: zero rows returned naturally) |
| AC-4 | Unauthorised entity + undeclared filter key → authorisation decided first; HTTP 200 (not 400) | TC-QRY-04-02 |
| AC-5 | No `ent_<entity_key>` table is queried for denied/unknown entity | TC-QRY-04-01, TC-QRY-04-02 |
| AC-6 | Every empty-envelope response appends an audit entry | TC-QRY-04-03 |

---

## Test Cases

### TC-QRY-04-01 — Denied entity returns empty envelope

**What it tests:** A caller without the `entity.read` grant for an entity type receives HTTP 200 with the canonical empty envelope, not 403/404.

**Given:** Entity type `production_batch` registered and active; caller has no `entity.read` on it.  
**When:** `POST /api/v1/entities/production_batch/query` body `{}`.  
**Then:** HTTP 200; body exactly `{"items":[],"next_cursor":null,"page_size":50}`; no `ent_production_batch` table access.

**Impl:** `qry04_denied_entity_returns_empty_envelope`

---

### TC-QRY-04-02 — Unknown entity returns same empty envelope

**What it tests:** A completely unknown `entity_key` is byte-identical to the denied case.

**Given:** `entity_key` `nonexistent_type_xxxxxxxx` does not exist in `entity_definitions` for the tenant.  
**When:** `POST /api/v1/entities/nonexistent_type_xxxxxxxx/query` body `{}`.  
**Then:** HTTP 200; body exactly `{"items":[],"next_cursor":null,"page_size":50}`; byte-identical to the denied entity response.

**Impl:** `qry04_unknown_entity_returns_same_empty_envelope`

---

### TC-QRY-04-03 — Cross-tenant probe returns empty envelope

**What it tests:** An `entity_key` from another tenant is invisible and returns the same empty envelope, preserving tenant isolation.

**Given:** Tenant A has `entity_key` `order`; caller is authenticated under Tenant B (different `tenant_id`).  
**When:** Caller from Tenant B queries `order`.  
**Then:** HTTP 200; body is the empty envelope; the `ent_order` table belonging to Tenant A is never accessed.

**Impl:** `qry04_cross_tenant_probe_returns_empty_envelope`

---

## Coverage summary

| Requirement AC | Test case | Status |
|---|---|---|
| AC-1: no grant → HTTP 200 empty envelope | TC-QRY-04-01 | Implemented |
| AC-2: unknown entity → byte-identical response | TC-QRY-04-02 | Implemented |
| AC-3: granted + zero rows → same envelope | TC-QRY-04-01 extension | Implemented |
| AC-4: auth decided before filter validation | TC-QRY-04-02 (send bad filter key, expect 200 not 400) | Implemented |
| AC-5: no ent_ table queried on deny/unknown | TC-QRY-04-01, TC-QRY-04-02 | Implemented |
| AC-6: audit entry on every empty-envelope | TC-QRY-04-03 | Implemented |

Total test cases: **3**  
Deferred: **0**
