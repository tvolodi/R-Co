# Test Spec: PRM-05 — Non-skippable human approval gate

**Requirement:** PRM-05 (MUST, stage 16) — The platform SHALL require an approved review before a promotion is applied, and SHALL provide no request parameter, header, flag or configuration value that bypasses the check. The principal recorded in `requested_by` cannot approve its own review. `GET /api/v1/promotions/{id}/context` returns the stored plan, the assertions carried by the artifact, the `NEEDS_REVIEW` package and the `plan_digest`, so the reviewer decides on exactly the diff the digest binds.
**Priority:** MUST
**Test layer:** integration (HTTP handlers `handleApproveReview` / `handleApplyReview` / `handleGetPromotionContext`)
**Source under test:** `src/api/routes/promotion_review.zig`, `src/definition/promotion_review.zig`
**Implementation file:** `tests/integration/prm05_review_gate_test.zig`

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| Tenant isolation | 2 | Gate + context read per-tenant review rows |
| Transactional boundary | 1 | Apply transitions inside an ACID transaction |
| **Total** | **3** | **Unit + integration** (no sandbox/Wasm execution on this path) |

## Test Cases

### TC-PRM-05-01: Apply blocked when review is pending_review → HTTP 400, no sandbox
**Given:** A review in `pending_review`.
**When:** `handleApplyReview(pool, alloc, actor, review_id, {"plan_digest":D})` is called with the matching digest.
**Then:** HTTP **400** `INVALID_REVIEW_TRANSITION`; status stays `pending_review`; zero `promotion_assertion_runs` rows for `(tenant_id, review_id)` (no sandbox claimed).
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC1 (apply with status != approved → 400, no sandbox).

### TC-PRM-05-02: Apply blocked when review is rejected → HTTP 400, no sandbox
**Given:** A review first rejected.
**When:** `handleApplyReview` is called.
**Then:** HTTP **400** `INVALID_REVIEW_TRANSITION`; no sandbox claimed.
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC1.

### TC-PRM-05-03: Apply blocked when review is failed → HTTP 400, no sandbox
**Given:** A review first approved then marked failed.
**When:** `handleApplyReview` is called.
**Then:** HTTP **400** `INVALID_REVIEW_TRANSITION`; no sandbox claimed.
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC1.

### TC-PRM-05-04: Apply succeeds when review is approved with matching digest
**Given:** An approved review with stored digest `D`.
**When:** `handleApplyReview(pool, alloc, actor, review_id, {"plan_digest":D})` is called.
**Then:** HTTP **200**; status becomes `applied` (positive control proving the gate admits the legitimate path).
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 gate correctness (approved review applies).

### TC-PRM-05-05: Self-approval → HTTP 403, stays pending_review
**Given:** A pending review with `requested_by == R`.
**When:** `handleApproveReview(..., actor.user_id == R, {"plan_digest":D})` is called.
**Then:** HTTP **403** `SELF_APPROVAL_FORBIDDEN`; status stays `pending_review`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC2 (principal in requested_by cannot approve its own review).

### TC-PRM-05-06: A different principal can approve
**Given:** A pending review with `requested_by == R` and an actor `A != R`.
**When:** `handleApproveReview(..., actor.user_id == A, {"plan_digest":D})` is called.
**Then:** HTTP **200**; status becomes `approved` with `approved_by == A` (positive control for the separation-of-duties gate).
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC2 (non-self approver succeeds).

### TC-PRM-05-07: Reject does NOT enforce the self-approval restriction
**Given:** A pending review with `requested_by == R`.
**When:** `handleRejectReview(..., actor.user_id == R, {})` is called.
**Then:** HTTP **200**; status becomes `rejected` (a submitter may reject their own request; separation of duties is about approval).
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC2 design note (no self-rejection restriction).

### TC-PRM-05-08: Apply body with unknown field → HTTP 422 UNKNOWN_FIELD (no skip field exists)
**Given:** An approved review.
**When:** `handleApplyReview(..., {"plan_digest":D, "skip_approval":true})` is called.
**Then:** HTTP **422** `UNKNOWN_FIELD`; status stays `approved` (no bypass field exists in the apply schema).
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC3 (unrecognised field → 422; no skip field).

### TC-PRM-05-09: Approve body with unknown field → HTTP 422 UNKNOWN_FIELD
**Given:** A pending review.
**When:** `handleApproveReview(..., {"plan_digest":D, "approved_by":"<uuid>"})` is called.
**Then:** HTTP **422** `UNKNOWN_FIELD` (INV-2 — the approver identity is server-derived, not client-supplied); status stays `pending_review`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC3 (unrecognised field → 422).

### TC-PRM-05-10: Context endpoint returns stored plan + assertions[] + NEEDS_REVIEW package + plan_digest in one document
**Given:** A pending review with a stored serialised plan.
**When:** `handleGetPromotionContext(review_id)` is called.
**Then:** HTTP **200**; the response body is one JSON document containing `review_id`, `plan_digest`, `serialised_plan`, `assertions` (a non-empty array), `needs_review_package` (a non-empty object), `status`, `requested_by`, `def_type`, `def_id`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC5 (context response has plan + assertions[] + NEEDS_REVIEW package + plan_digest in one document).

### TC-PRM-05-11: Digest mismatch on approve → HTTP 409, stays pending_review
**Given:** A pending review with stored digest `D`.
**When:** `handleApproveReview(..., {"plan_digest":"D'"})` (D' ≠ D) is called.
**Then:** HTTP **409** `PLAN_DIGEST_MISMATCH`; status stays `pending_review`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC2 through the PRM-05 gate.

### TC-PRM-05-12: Digest mismatch on apply → HTTP 409, no sandbox
**Given:** An approved review with stored digest `D`.
**When:** `handleApplyReview(..., {"plan_digest":"D'"})` (D' ≠ D) is called.
**Then:** HTTP **409** `PLAN_DIGEST_MISMATCH`; status stays `approved`; zero `promotion_assertion_runs` rows (no sandbox claimed).
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC3 through the PRM-05 gate.

### TC-PRM-05-13: No bypass configuration or parameter — apply gate is structural
**Given:** A review in `pending_review` and the apply handler's request contract (`ApplyBody` = exactly `{plan_digest}`).
**When:** Any plausible bypass-shaped payload is attempted — an unknown field (TC-08) or a payload on a non-approved review (TC-01/02/03).
**Then:** Every path returns 400/422 and no transition occurs; the apply handler admits no bypass flag, header, or parameter. (Verifies PRM-05 AC4's structural guarantee at the apply surface — pre-vetted templates are routed through a separate provisioning entry point, never a conditional bypass inside apply.)
**Layer:** integration
**Acceptance criterion mapped:** PRM-05 AC4 (no bypass mechanism on apply; separate entry point is routing-level, not a flag).
