> **Extends:** AGT-01, making artifact submission safe to retry.

> Artifact submission SHALL be idempotent on `(tenant_id, task_spec_id, attempt_count)`, which is a unique index on `agent_artifacts`. The platform SHALL execute `INSERT ... ON CONFLICT (tenant_id, task_spec_id, attempt_count) DO UPDATE SET touched_at = now() RETURNING xmax = 0 AS inserted` and SHALL use `inserted` to distinguish a fresh insert from a re-hit: `true` returns HTTP 201, `false` with a matching `spec_hash` returns HTTP 200 carrying the existing `artifact_id`, and `false` with a differing `spec_hash` returns HTTP 409 `spec_hash_mismatch` carrying both hashes. A re-hit SHALL NOT replace the stored payload.

**Acceptance Criteria:**
- GIVEN no row exists for the triple, WHEN an artifact is submitted, THEN `xmax = 0` evaluates true, the platform returns HTTP 201, and `artifact_id` is the newly created UUID.
- GIVEN a row exists for the triple and the submitted `spec_hash` matches the stored one, WHEN the same envelope is resubmitted, THEN the platform returns HTTP 200 with the original `artifact_id`, `touched_at` advances, and the stored `payload` is byte-identical to the payload stored on the first call.
- GIVEN a row exists for the triple and the submitted `spec_hash` differs, WHEN the envelope is submitted, THEN the platform returns HTTP 409 `spec_hash_mismatch` carrying `stored_spec_hash` and `submitted_spec_hash`, and the stored row is unmodified.
- GIVEN an agent whose network call times out after the server committed, WHEN the agent retries the identical envelope, THEN it receives HTTP 200 and exactly one row exists for the triple.
- GIVEN the stored maximum `attempt_count` for a task spec is 3, WHEN an envelope with `attempt_count` of 2 is submitted, THEN the platform returns HTTP 409 `attempt_count_regressed`.
- GIVEN two submissions for the same triple arrive concurrently, WHEN both execute, THEN exactly one observes `xmax = 0` true and returns HTTP 201, and the other returns HTTP 200 or HTTP 409 by `spec_hash` comparison.

**See:** AGT-01, AGT-04, AGT-05, AGT-06, API-10
