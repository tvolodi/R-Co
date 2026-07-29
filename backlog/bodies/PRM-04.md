> The platform SHALL persist promotion approvals in a `promotion_reviews` table holding `id`, `tenant_id`, `plan_digest`, `def_type`, `def_id`, the serialised plan, `status`, `requested_by`, `approved_by`, `approved_at`, `superseded_by`, `row_version`, `created_at` and `updated_at`. `status` is constrained by a CHECK over exactly six values: `pending_review`, `approved`, `rejected`, `applied`, `failed`, `superseded`. The permitted edges are pending_review to approved, pending_review to rejected, pending_review to superseded, approved to applied, approved to failed, and approved to superseded. A partial unique index `promotion_reviews_plan_digest_active_uniq` over `(tenant_id, plan_digest) WHERE status IN ('pending_review','approved')` permits at most one live review per digest.

**Acceptance Criteria:**
- GIVEN a review in `pending_review`, WHEN it is approved, THEN `status` becomes `approved` with `approved_by` and `approved_at` set; from any other source status the platform returns HTTP 400 `InvalidReviewTransition`.
- GIVEN a live review for `(tenant_id, plan_digest)`, WHEN a second submission produces the same digest, THEN the platform returns HTTP 409 `DuplicateReview` raised by the partial unique index.
- GIVEN a review in `approved` whose assertion re-run fails, WHEN the failure is recorded, THEN `status` becomes `failed`.
- GIVEN a promotion applies, WHEN the version pointer moves, THEN `status` moves `approved` to `applied` and `DEFINITION_PROMOTION_APPLIED` is appended in the same transaction as the pointer move.
- A transition outside the enumerated edge set is rejected by the CHECK constraint at the database and with HTTP 400 at the API.

**See:** PRM-02, PRM-03, PRM-05, PRM-06, PRM-08
