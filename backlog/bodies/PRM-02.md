> The platform SHALL run conflict detection as the first step of the promotion pipeline, before any transaction opens. A conflict exists when the target tenant's active version of `process_key` is greater than the `base_version` the source branched from. On conflict the platform returns a typed `ConflictRejection` naming each conflicting definition with its source-side change and its target-side change, appends exactly one `DEFINITION_PROMOTION_REJECTED` event in its own transaction, and moves no version pointer.

**Acceptance Criteria:**
- GIVEN the target active version is greater than `base_version`, WHEN the promotion is submitted, THEN the platform returns HTTP 409 `PromotionConflict` with a body listing `{definition_id, source_change, target_change}` for each conflict.
- GIVEN a conflict is detected, WHEN the rejection is recorded, THEN exactly one `DEFINITION_PROMOTION_REJECTED` event is appended and the target tenant's active version pointer is unchanged.
- GIVEN a conflict is detected, THEN no `promotion_reviews` row and no `promotion_assertion_runs` row is created.
- GIVEN a conflict is detected, THEN the rejection path holds no transaction open against the target tenant schema at the time the conflict is raised.
- The conflict check executes before the plan digest is computed (PRM-03) and before the review row is inserted (PRM-04); no ordering makes it run later.

**See:** PRM-01, PRM-03, PRM-04, PRM-05, ENV-03
