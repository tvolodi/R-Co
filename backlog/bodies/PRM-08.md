> **Extends:** PD-08. Because every instance carries a definition snapshot, reverting the active version affects only instances started afterwards.

> The platform SHALL support promotion rollback as a version pointer move: `POST /api/v1/definitions/{process_key}/rollback` re-points the tenant's active version to a version that was previously active in that tenant and appends `DEFINITION_VERSION_ROLLED_BACK`. No DDL executes, because a promotion carries none. In-flight instances continue on their PD-08 snapshot and their PIN-02 pin set, and the `promotion_reviews` row that applied the reverted version moves to `superseded`.

**Acceptance Criteria:**
- GIVEN version V2 is active and V1 was active before it, WHEN rollback to V1 is requested, THEN the active pointer becomes V1, `DEFINITION_VERSION_ROLLED_BACK` is appended, and no schema change is executed.
- GIVEN instances started under V2, WHEN the rollback completes, THEN those instances continue on their PD-08 snapshot and their recorded `pinned_versions[]` are unchanged.
- GIVEN a version that was never active in this tenant, WHEN rollback names it, THEN the platform returns HTTP 422 `VersionNeverActive`.
- GIVEN the rollback succeeds, WHEN the review is closed, THEN the `promotion_reviews` row that applied V2 moves to `superseded` with `superseded_by` naming the rollback event.
- GIVEN a caller without the platform-admin role, WHEN rollback is requested, THEN the platform returns HTTP 403.

**See:** PD-08, PRM-04, PRM-06, PIN-02, ENV-03
