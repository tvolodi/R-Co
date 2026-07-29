> The platform SHALL enforce semantic validation at two points: on definition draft save and on `POST /api/v1/definitions/{id}/validate`, and again at promotion submit before the PRM-01 plan is computed. A clean pass records a `semantically_valid` verdict on the definition version together with the CEL compiler version that produced it; a verdict produced by a different compiler version is re-verified rather than trusted. Compilation is bounded at 5 seconds per definition.

**Acceptance Criteria:**
- GIVEN any finding at draft save, WHEN the request completes, THEN the platform returns HTTP 422 and the version is not marked `semantically_valid`.
- GIVEN any finding at promotion submit, WHEN the request completes, THEN the platform returns HTTP 422, computes no promotion plan and creates no `promotion_reviews` row.
- GIVEN a stored verdict produced by an earlier compiler version, WHEN promotion submit runs, THEN validation re-runs instead of accepting the stored verdict.
- GIVEN compilation exceeds 5 seconds, WHEN the budget expires, THEN the platform returns HTTP 422 `ValidationTimeout` naming the sites compiled before expiry.
- A clean pass appends `DEFINITION_VALIDATED`; a failure appends `DEFINITION_VALIDATION_FAILED` carrying the finding count.

**See:** VLD-02, VLD-03, PRM-01, PD-06, EE-05
