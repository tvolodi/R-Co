> A completion SHOULD be applied only when `sequence_no = applied_seq + 1`, where `applied_seq` is read from `plat_correlation_cursor` for that `correlation_id` while the execute guard of ORD-02 is held. A completion that is not next in sequence SHALL cause a silent `ROLLBACK` with no error and no retry-count increment, leaving the row `PENDING`. The apply and the cursor advance `UPDATE plat_correlation_cursor SET applied_seq = $2 WHERE correlation_id = $1 AND applied_seq = $2 - 1` SHALL commit in one transaction.

**Acceptance Criteria:**
- GIVEN `applied_seq = 4` for correlation X and the completion for sequence 6 arrives before sequence 5, WHEN sequence 6 is claimed, THEN it is not applied, the transaction rolls back silently, its retry counter is unchanged, and the row remains `PENDING`.
- GIVEN sequence 5 then arrives, WHEN it is applied, THEN `applied_seq` advances to 5 and sequence 6 is applied on the next claim, so the engine observes 5 before 6.
- GIVEN the conditional cursor update reports 0 updated rows, WHEN the consumer evaluates it, THEN the transaction rolls back and the completion is re-claimed; this guard makes a double-apply impossible even if both other guards were bypassed.
- GIVEN the apply raises a typed engine error, WHEN the transaction rolls back, THEN neither the instance state change nor the cursor advance is committed, so applied state and `applied_seq` cannot diverge.
- GIVEN a successor has been `PENDING` for longer than `gap_timeout_seconds` (default 300) while its predecessor is absent, WHEN the gap sweeper runs on its 60 s cadence, THEN every `PENDING` row of that correlation moves to `status = 'DEAD'` and is routed to the dead letter queue as one unit, so no correlation is left half-applied.
- GIVEN the Effects Worker re-inserts an existing `(correlation_id, sequence_no)`, WHEN the insert runs, THEN it is absorbed by `ON CONFLICT DO NOTHING` and no second apply occurs.

**See:** ORD-01, ORD-02 (the lock under which the cursor is read and advanced), ORD-04, OBS-05 (dead letter queue receiving a swept correlation)
