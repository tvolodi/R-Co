# Test Spec: PRM-02 — Conflict pre-flight rejection

**Requirement:** PRM-02 (MUST, stage 16) — The platform SHALL run conflict detection as the first step of the promotion pipeline, before any transaction opens. A conflict exists when the target tenant's active version of `process_key` is greater than the `base_version` the source branched from. On conflict the platform returns a typed `ConflictRejection` naming each conflicting definition with its source-side change and its target-side change, appends exactly one `DEFINITION_PROMOTION_REJECTED` event in its own transaction, and moves no version pointer.
**Priority:** MUST
**Test layer:** integration (domain `rejectIfConflicts` / `rejectIfConflictsMulti` + HTTP `handleSubmitPromotion`)
**Source under test:** `src/definition/promotion_conflict.zig`, `src/api/routes/promotion_review.zig`
**Implementation file:** `tests/integration/prm02_conflict_test.zig`

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 2 | Reads `process_definitions` in the target tenant schema; appends to per-tenant `events` + `plat_event_idempotency` |
| Tenant isolation | 2 | Cross-tenant conflict check; per-tenant event append |
| Transactional boundary | 1 | Rejection event appended in its own independent transaction |
| **Total** | **5** | **Unit + integration** (no sandbox/Wasm execution on this path — the tier label caps at what this code touches) |

## Test Cases

### TC-PRM-02-01: No conflict when target has no ACTIVE version
**Given:** The target tenant holds no ACTIVE `process_definitions` row for a random `process_key`.
**When:** `rejectIfConflicts(target_tenant_id, process_key, base_version=1, ...)` is called.
**Then:** Returns `null` — no conflict; no `DEFINITION_PROMOTION_REJECTED` event is appended; the pipeline may continue.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 conflict condition (`target_active_version > base_version`); zero rows ⇒ no conflict.

### TC-PRM-02-02: No conflict when target_version == base_version
**Given:** The target tenant holds an ACTIVE `process_definitions` row at version 3 for a random `process_key`.
**When:** `rejectIfConflicts(..., base_version=3, ...)` is called.
**Then:** Returns `null` — `target_version (3) <= base_version (3)` is not a conflict.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 conflict condition is strictly `target_active_version > base_version`.

### TC-PRM-02-03: Conflict detected when target_version > base_version
**Given:** The target tenant holds an ACTIVE `process_definitions` row at version 5 for a random `process_key`, `base_version=3`.
**When:** `rejectIfConflicts(..., base_version=3, ...)` is called.
**Then:** Returns a populated `ConflictRejection` with `target_version=5`, `target_definition_id` equal to the target row's id, `source_change="branched from version 3"`, `target_change="target is now at version 5"`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 conflict detection + typed rejection fields (`{definition_id, source_change, target_change}`).

### TC-PRM-02-04: Multi-definition conflict names each conflicting definition
**Given:** The target tenant holds ACTIVE definitions for two random `process_key`s; one has `version > base_version`, the other has `version == base_version`.
**When:** `rejectIfConflictsMulti(..., process_keys=[pk1, pk2], base_versions=[b1, b2], ...)` is called.
**Then:** Returns a slice containing exactly one `ConflictRejection` — the conflicting key; the non-conflicting key contributes no rejection.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 AC1 — 409 body "naming each conflicting definition" (per-definition rejection collection).

### TC-PRM-02-05: HTTP 409 PROMOTION_CONFLICT body shape on conflict
**Given:** A test source tenant with an ACTIVE definition for `process_key` and a test target tenant with an ACTIVE definition for the same `process_key` at `version > base_version`; the caller holds `promotion.submit`.
**When:** `handleSubmitPromotion` is called with body `{source_tenant_id, target_tenant_id, process_key, base_version}`.
**Then:** HTTP **409**; body contains `"error":"PROMOTION_CONFLICT"`, `"message":"Target tenant has advanced past base_version"`, and a `conflicts[]` entry with `process_key`, `target_definition_id`, `target_version`, `source_change`, `target_change`. No `promotion_reviews` row is created and no `DEFINITION_PROMOTION_APPROVED` / `DEFINITION_PROMOTION_APPLIED` event exists (ordering: conflict precedes review insert).
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 AC1 (409 typed body), AC3 (no review/assertion-runs row), AC5 (conflict before digest/review insert).

### TC-PRM-02-06: Exactly one rejection event; target active pointer unchanged
**Given:** A conflict exists (target version 5 > base version 3) for a random `process_key`.
**When:** `rejectIfConflicts(..., promotion_id, ...)` is called, then called a second time with the **same** `promotion_id`.
**Then:** Exactly one `DEFINITION_PROMOTION_REJECTED` row exists in `events` (idempotency key `DEFINITION_PROMOTION_REJECTED-<promotion_id>`); exactly one row in `plat_event_idempotency`; the target `process_definitions` row still has `version=5` (pointer unchanged).
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 AC2 (exactly one event, idempotency; no pointer move).

### TC-PRM-02-07: No promotion_reviews / promotion_assertion_runs row on conflict
**Given:** A conflict is detected for a random `process_key` and `promotion_id`.
**When:** `rejectIfConflicts(...)` returns the rejection.
**Then:** `SELECT COUNT(*)` for that tenant + process in `promotion_reviews` is 0 and in `promotion_assertion_runs` is 0.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 AC3 (handler returns before review insert / assertion-runs insert).

### TC-PRM-02-08: Rejection event committed in its own independent transaction
**Given:** A conflict is detected.
**When:** `rejectIfConflicts(...)` returns the rejection.
**Then:** The `DEFINITION_PROMOTION_REJECTED` event is visible from a fresh connection immediately (committed in its own transaction, not held open against the target schema), and no `DEFINITION_PROMOTION_APPROVED` / `DEFINITION_PROMOTION_APPLIED` event exists for the promotion.
**Layer:** integration
**Acceptance criterion mapped:** PRM-02 AC4 (no transaction open against the target schema at conflict time), AC5 ordering.
