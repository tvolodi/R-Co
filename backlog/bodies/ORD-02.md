> Inside the claim transaction a BPM Consumer SHALL evaluate `SELECT pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint)` before applying a completion. A `false` result SHALL cause an immediate `ROLLBACK`, returning the row to `PENDING` without incrementing any retry counter, and the consumer SHALL move to another correlation. The lock is transaction-scoped and SHALL NOT be released by an explicit unlock call.

**Acceptance Criteria:**
- GIVEN consumer A is applying a completion for correlation X, WHEN consumer B claims another completion for correlation X, THEN B's `pg_try_advisory_xact_lock` returns `false`, B rolls back, and B claims work for a different correlation within the same poll cycle.
- GIVEN the try-variant is used, WHEN a consumer loses the guard, THEN it does not block; `pg_advisory_xact_lock` is never called on this path, so no pooled connection is held waiting.
- GIVEN a consumer crashes mid-apply, WHEN its backend exits, THEN the advisory lock is released by the transaction abort and the correlation becomes available to another consumer without operator action.
- GIVEN two distinct `correlation_id` values whose `hashtext` results collide, WHEN both are claimed, THEN one waits for the other and throughput falls, but neither is misapplied: ordering is decided by the per-correlation cursor of ORD-03, not by the lock key.
- GIVEN a completion commits, WHEN the transaction ends, THEN the advisory lock is released at `COMMIT` and the successor becomes eligible on the next claim.

**See:** ORD-01 (claim guard), ORD-03 (order guard evaluated while this lock is held), ORD-04, DB-02
