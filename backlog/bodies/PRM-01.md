> **Extends:** ENV-03, replacing a direct test-tenant to production-tenant copy with a computed, reviewable plan.

> The platform SHALL compute a promotion plan before any write to the target tenant. The plan diffs the source tenant's definition version against the target tenant's active version across the process graph, the `variable_schema`, service catalog bindings (REPO-07) on SERVICE_TASK nodes, `module_ref` resolutions (PLC-01) on SUB_PROCESS nodes, and permission rules. Each plan entry carries `{type, id, change_kind, before, after}` with `change_kind` in `added`, `modified`, `removed`, and the plan is rendered as a human-readable change list alongside its JSON form. Submission is `POST /api/v1/promotions` and requires the `promotion.submit` permission.

**Acceptance Criteria:**
- GIVEN a caller without `promotion.submit`, WHEN it calls `POST /api/v1/promotions`, THEN the platform returns HTTP 403 and creates no `promotion_reviews` row.
- GIVEN the target tenant holds no version of `process_key`, WHEN the plan is computed, THEN every plan entry carries `change_kind = added` and the plan is accepted.
- GIVEN the source and target definitions are identical after canonicalisation, WHEN the plan is computed, THEN the platform returns HTTP 422 `EmptyPromotionPlan` and creates no review row.
- GIVEN `source_tenant_id` names a production tenant, WHEN the promotion is submitted, THEN the platform returns HTTP 422 `InvalidPromotionSource`.
- The plan is computed before any transaction that writes to the target tenant is opened.

**See:** ENV-03, PD-08, REPO-07, PLC-01, PRM-02, PRM-03, VLD-04
