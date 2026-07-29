> **Extends:** PIN-01, tying artifact retention to the version pair the artifact was produced against.

> Artifact retention SHALL be a dual sweep. Sweep 1 deletes artifacts in state `needs_review` whose `created_at` is older than `STAGING_REVIEW_TTL_DAYS` (default 30). Sweep 2 deletes an artifact in state `verified` only when the pinned `(task_spec_version, process_definition_version)` pair recorded in `artifact_version_pins` has been collected AND `verified_at` is older than `STAGING_VERIFIED_TTL_DAYS` (default 365); the later of the two moments governs. A verified artifact is exempt from the needs-review TTL for as long as anything still pins its version pair.

**Acceptance Criteria:**
- GIVEN an artifact in state `needs_review` created 31 days ago, WHEN sweep 1 runs, THEN the row is deleted and the authoring agent must resubmit to restore it.
- GIVEN an artifact in state `verified` created 400 days ago, WHEN sweep 1 runs, THEN the row is untouched; the state predicate excludes verified artifacts from the needs-review TTL.
- GIVEN a verified artifact whose pinned version pair is still collected-pending and whose `verified_at` is 400 days old, WHEN sweep 2 runs, THEN the row is retained because the pin has not been collected.
- GIVEN a verified artifact whose pinned version pair was collected 100 days ago and whose `verified_at` is 200 days old, WHEN sweep 2 runs, THEN the row is retained because 365 days have not elapsed since verification.
- GIVEN a verified artifact whose pin was collected and whose `verified_at` is 366 days old, WHEN sweep 2 runs, THEN the row is deleted.
- GIVEN an artifact transitions to `verified`, WHEN the transition commits, THEN an `artifact_version_pins` row carrying `(artifact_id, task_spec_version, process_definition_version)` is written in the same transaction.
- Both sweeps run on a daily schedule at 03:00 UTC, sweep 1 before sweep 2, and each carries a state predicate that makes a re-run a no-op.

**See:** PIN-01, PIN-02, ES-07, AGT-03, AGT-04, IR-07
