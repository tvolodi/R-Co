# Test Spec: PRM-04 — Promotion review state machine

**Requirement:** PRM-04 — The platform MUST enforce exactly 7 permitted state transitions on a promotion review, with optimistic locking via `row_version`, and a partial unique index enforcing at most one live review per `(tenant_id, plan_digest)`.
**Priority:** MUST
**Test layer:** integration

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 2 | New `promotion_reviews` table |
| Tenant isolation | 2 | Per-tenant review records |
| Transactional boundary | 1 | State transitions in transactions |
| **Total** | **5** | **Unit + integration** |

## Test Cases

### TC-PRM-04-01: pending_review → approved transition

**Given:** A `pending_review` review record.

**When:** `approveReview(review_id, actor_id, expected_row_version)` is called with the correct row_version.

**Then:** Review status becomes `approved`, `approved_by` is set, `approved_at` is set, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC1 — `pending_review → approved` is a permitted edge.

---

### TC-PRM-04-02: pending_review → rejected transition

**Given:** A `pending_review` review record.

**When:** `rejectReview(review_id, expected_row_version)` is called with the correct row_version.

**Then:** Review status becomes `rejected`, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC1 — `pending_review → rejected` is a permitted edge.

---

### TC-PRM-04-03: pending_review → superseded (duplicate digest)

**Given:** A `pending_review` review with digest D exists for tenant T.

**When:** A second promotion submits with the same digest D for tenant T.

**Then:** Second submission fails with HTTP 409 `DUPLICATE_REVIEW`. The partial unique index `promotion_reviews_plan_digest_active_uniq` prevents two `pending_review` or `approved` reviews with the same `(tenant_id, plan_digest)`.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC — at most one live review per `(tenant_id, plan_digest)`.

---

### TC-PRM-04-04: approved → applied transition

**Given:** An `approved` review record.

**When:** `markReviewApplied(review_id, expected_row_version)` is called with the correct row_version.

**Then:** Review status becomes `applied`, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC4 — `approved → applied` is a permitted edge.

---

### TC-PRM-04-05: approved → failed transition

**Given:** An `approved` review record.

**When:** `markReviewFailed(review_id, expected_row_version)` is called with the correct row_version.

**Then:** Review status becomes `failed`, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC3 — `approved → failed` is a permitted edge.

---

### TC-PRM-04-06: applied → superseded transition

**Given:** An `applied` review record.

**When:** `supersedeReview(review_id, superseding_review_id, expected_row_version)` is called.

**Then:** Review status becomes `superseded`, `superseded_by` is set to `superseding_review_id`, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC4 — `applied → superseded` is a permitted edge.

---

### TC-PRM-04-07: failed → superseded transition

**Given:** A `failed` review record.

**When:** `supersedeReview(review_id, superseding_review_id, expected_row_version)` is called.

**Then:** Review status becomes `superseded`, `superseded_by` is set, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC4 — `failed → superseded` is a permitted edge.

---

### TC-PRM-04-08: rejected → superseded transition

**Given:** A `rejected` review record.

**When:** `supersedeReview(review_id, superseding_review_id, expected_row_version)` is called.

**Then:** Review status becomes `superseded`, `superseded_by` is set, `row_version` increments by 1.

**Layer:** integration  
**Acceptance criterion:** PRM-04 AC4 — `rejected → superseded` is a permitted edge (new edge, closes the rejection lifecycle).

---

### TC-PRM-04-09: Invalid transition returns error

**Given:** A `pending_review` review record.

**When:** `markReviewApplied(...)` is called directly (bypassing approve).

**Then:** Returns `InvalidReviewTransition` (row_version mismatch — UPDATE returns 0 rows).

**Layer:** integration  
**Acceptance criterion:** PRM-04 — only the 7 permitted edges are allowed.

---

### TC-PRM-04-10: Row version optimistic locking

**Given:** A review with `row_version=3`.

**When:** `approveReview(review_id, actor_id, expected_row_version=2)` is called (stale version).

**Then:** Returns `InvalidReviewTransition`. The review is unmodified.

**Layer:** integration  
**Acceptance criterion:** PRM-04 design — "WHERE row_version = $expected_version; if zero rows match, transition fails."

---

### TC-PRM-04-11: CHECK constraint enforces valid statuses

**Given:** The `promotion_reviews` table has a CHECK constraint `status IN ('pending_review','approved','rejected','applied','failed','superseded')`.

**When:** An UPDATE attempts to set `status = 'unknown_status'`.

**Then:** Postgres raises a CHECK constraint violation. The transition fails.

**Layer:** integration  
**Acceptance criterion:** PRM-04 design — "status field is CHECK-constrained to exactly six values."

---

### TC-PRM-04-12: getReview returns stored plan and digest

**Given:** A review was submitted with a specific `plan_digest` and `serialised_plan`.

**When:** `getReview(allocator, pool, review_id)` is called.

**Then:** Returns a `ReviewRecord` where `plan_digest` and `serialised_plan` match what was stored.

**Layer:** integration  
**Acceptance criterion:** PRM-03 / PRM-04 — context endpoint reads stored values, not live recomputation.
