> The platform SHALL bind every approval to a `plan_digest`: the lowercase hexadecimal SHA-256 over the canonical JSON serialisation of the promotion plan, where canonical means object keys sorted lexicographically and no insignificant whitespace, over the entry shape `{type, id, changes}`. The digest and the full serialised plan are stored on the `promotion_reviews` row at submit time. Approve and apply both require the digest in the request body, and a mismatch is rejected with HTTP 409 `PlanDigestMismatch`.

**Acceptance Criteria:**
- GIVEN two byte-identical plans, WHEN each is digested, THEN both produce the same 64-character lowercase hexadecimal string.
- GIVEN an approve request whose body digest differs from the stored digest, WHEN it is processed, THEN the platform returns HTTP 409 `PlanDigestMismatch` and the review remains in `pending_review`.
- GIVEN an apply request whose body digest differs from the stored digest, WHEN it is processed, THEN the platform returns HTTP 409 `PlanDigestMismatch` and claims no sandbox.
- GIVEN the source definition changes after an approval, WHEN a new promotion is submitted, THEN a new digest and a new review row are created, and the earlier approval cannot be applied to the new plan.
- The reviewer context endpoint serves the plan stored at submit time and never re-computes a live diff.

**See:** PRM-01, PRM-02, PRM-04, PRM-05, PRM-06
