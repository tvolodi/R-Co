# Test Spec: PRM-04 — Promotion review state machine

**Requirement:** PRM-04 (MUST, stage 16) — The platform SHALL persist promotion approvals in a `promotion_reviews` table holding `id`, `tenant_id`, `plan_digest`, `def_type`, `def_id`, the serialised plan, `status`, `requested_by`, `approved_by`, `approved_at`, `superseded_by`, `row_version`, `created_at` and `updated_at`. `status` is constrained by a CHECK over exactly six values. The permitted edges are pending_review→approved, pending_review→rejected, pending_review→superseded, approved→applied, approved→failed, approved→superseded. A partial unique index over `(tenant_id, plan_digest) WHERE status IN ('pending_review','approved')` permits at most one live review per digest.
**Priority:** MUST
**Test layer:** integration (domain `promotion_review` state machine + HTTP handlers + DB constraints)
**Source under test:** `src/definition/promotion_review.zig`, `src/api/routes/promotion_review.zig`, `migrations/096_promotion_reviews.sql`
**Implementation file:** `tests/integration/prm04_review_sm_test.zig` (also `tests/integration/promotion_reviews_test.zig` — umbrella-wired binary covering the same ACs)

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 2 | `promotion_reviews` table, CHECK constraint, partial unique index |
| Tenant isolation | 2 | Review rows + events are per-tenant |
| Transactional boundary | 1 | ACID transitions; event appended in the same transaction |
| **Total** | **5** | **Unit + integration** (no sandbox execution on this path) |

## Test Cases

### TC-PRM-04-01: pending_review → approved sets approved_by / approved_at
**Given:** A review in `pending_review` (row_version 1) for a random tenant + digest.
**When:** `approveReview(allocator, pool, review_id, tenant_id, actor_id, 1)` is called with a valid actor UUID.
**Then:** Status becomes `approved`; `approved_by == actor_id`; `approved_at != null`; `row_version == 2`; a `DEFINITION_PROMOTION_APPROVED` event exists in the tenant's `events` table.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC1 (approved with approved_by/approved_at set).

### TC-PRM-04-02: pending_review → rejected
**Given:** A review in `pending_review`.
**When:** `rejectReview(allocator, pool, review_id, tenant_id, 1)` is called.
**Then:** Status becomes `rejected`; `approved_by`/`approved_at` stay null; `row_version == 2`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC1 permitted edge pending_review→rejected.

### TC-PRM-04-03: Live review for (tenant_id, plan_digest) — second same-digest submit → DuplicateReview
**Given:** A pending review exists for `(tenant_id, plan_digest)`.
**When:** `submitReview` is called again with the same `tenant_id` + `plan_digest`.
**Then:** Returns `ReviewTransitionError.DuplicateReview` (raised by the partial unique index).
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC2 (partial unique index → 409 DuplicateReview).

### TC-PRM-04-04: approved → applied; DEFINITION_PROMOTION_APPLIED in same transaction
**Given:** An approved review.
**When:** `markReviewApplied(allocator, pool, review_id, tenant_id, actor_id, 2)` is called.
**Then:** Status becomes `applied`; `row_version == 3`; exactly one `DEFINITION_PROMOTION_APPLIED` event exists in the tenant's `events` table carrying `plan_digest`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC4 (approved→applied + event in the same transaction).

### TC-PRM-04-05: approved → failed on assertion re-run failure
**Given:** An approved review.
**When:** `markReviewFailed(allocator, pool, review_id, tenant_id, 2)` is called.
**Then:** Status becomes `failed`; `row_version == 3`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC3 (approved→failed).

### TC-PRM-04-06: applied → superseded
**Given:** An applied review (row_version 3).
**When:** `supersedeReview(allocator, pool, review_id, tenant_id, superseding_review_id, 3)` is called.
**Then:** Status becomes `superseded`; `superseded_by == superseding_review_id`; `row_version == 4`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC5 (superseded edge reachable).

### TC-PRM-04-07: failed → superseded
**Given:** A failed review (row_version 3).
**When:** `supersedeReview(..., expected_row_version=3)` is called.
**Then:** Status becomes `superseded` with `superseded_by` set.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC5 (superseded edge reachable).

### TC-PRM-04-08: rejected → superseded
**Given:** A rejected review (row_version 2).
**When:** `supersedeReview(..., expected_row_version=2)` is called.
**Then:** Status becomes `superseded` with `superseded_by` set.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC5 (superseded edge reachable).

### TC-PRM-04-09: Invalid transition (pending_review → applied directly) returns error
**Given:** A review in `pending_review`.
**When:** `markReviewApplied(..., expected_row_version=1)` is called directly.
**Then:** Returns `ReviewTransitionError.InvalidReviewTransition`; status stays `pending_review`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC1/AC5 (transition outside the edge set rejected).

### TC-PRM-04-10: Optimistic locking — stale row_version fails the transition
**Given:** A review in `pending_review` (row_version 1).
**When:** `approveReview(..., expected_row_version=2)` is called (stale).
**Then:** Returns `ReviewTransitionError.InvalidReviewTransition`; status stays `pending_review` with `row_version == 1`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 optimistic lock (`WHERE row_version = $expected`; zero rows → error).

### TC-PRM-04-11: CHECK constraint rejects an invalid status at the database
**Given:** A review row insert attempt with `status='invalid_status'`.
**When:** A direct SQL INSERT is executed against `promotion_reviews` in the tenant schema.
**Then:** The INSERT fails with a CHECK-constraint violation (`chk_promotion_reviews_status`).
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC5 (CHECK constraint rejects values outside the six-status set at the DB).

### TC-PRM-04-12: Invalid transition rejected with HTTP 400 at the API
**Given:** An approved review (or a review in any non-`pending_review` status).
**When:** `handleApproveReview(pool, alloc, actor, review_id, {"plan_digest":D})` is called with a digest matching the stored digest.
**Then:** HTTP **400** `INVALID_REVIEW_TRANSITION`; status unchanged.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 AC1/AC5 (any source status other than pending_review → 400 at the API).

### TC-PRM-04-13: getReview returns stored plan_digest and serialised_plan
**Given:** A submitted review.
**When:** `getReview(review_id)` is called.
**Then:** Returns a `ReviewRecord` whose `plan_digest` and `serialised_plan` match what was submitted, plus `def_type`/`def_id`/`status`/`row_version`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-04 storage contract + PRM-03 AC5 binding (stored plan/digest readable).
