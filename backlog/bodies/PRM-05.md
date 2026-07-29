> The platform SHALL require an approved review before a promotion is applied, and SHALL provide no request parameter, header, flag or configuration value that bypasses the check. The principal recorded in `requested_by` cannot approve its own review. `GET /api/v1/promotions/{id}/context` returns the stored plan, the assertions carried by the artifact, the `NEEDS_REVIEW` package and the `plan_digest`, so the reviewer decides on exactly the diff the digest binds.

**Acceptance Criteria:**
- GIVEN a review whose status is not `approved`, WHEN `POST /api/v1/promotions/{id}/apply` is called, THEN the platform returns HTTP 400 `InvalidReviewTransition` and claims no sandbox.
- GIVEN an approve request whose principal equals `requested_by`, WHEN it is processed, THEN the platform returns HTTP 403 and the review remains in `pending_review`.
- GIVEN a request body carrying an unrecognised field intended to skip the gate, WHEN it is processed, THEN the platform returns HTTP 422 for the unknown field; no skip field exists in the schema.
- GIVEN a pre-vetted platform-published template installed during provisioning, WHEN it reaches the target tenant, THEN it is promoted through a separate entry point that never calls apply, rather than through a bypass flag on apply.
- The context response contains the serialised plan, `assertions[]`, the `NEEDS_REVIEW` package and `plan_digest` in one document.

**See:** PRM-03, PRM-04, PRM-06, SOL-02, IDN-05
