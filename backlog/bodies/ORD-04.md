> Completions belonging to different `correlation_id` values SHALL continue to be applied in parallel: distinct correlations take distinct advisory lock keys and distinct `plat_correlation_cursor` rows, so `consumer_count` correlations (default 8) are applied concurrently. The platform SHALL expose per-correlation lag `max(sequence_no) - applied_seq`, the age of the oldest `PENDING` row, and the rate at which the execute guard of ORD-02 returns `false`.

**Acceptance Criteria:**
- GIVEN 8 correlations each holding a pending completion that is next in sequence, WHEN 8 consumers poll, THEN all 8 are applied concurrently and none is serialised behind another.
- GIVEN per-correlation lag exceeds 100 unapplied completions, WHEN the sweeper evaluates it, THEN `EXECUTION_CORRELATION_LAG` is appended carrying the `correlation_id`, the lag, and the age of the oldest `PENDING` row, and Platform Admin is escalated.
- GIVEN the execute guard returns `false` for more than 50 per cent of claim attempts in one minute, WHEN contention is evaluated, THEN `EXECUTION_CORRELATION_CONTENTION` is appended and `consumer_count` is reduced by 2 with a floor of 2.
- GIVEN a correlation is dead-lettered, WHEN the escalation is raised, THEN it names the `correlation_id` and lists every unapplied `sequence_no`, so the missing emit is identifiable without querying the table.
- Every applied completion appends `EXECUTION_EFFECT_APPLIED` carrying `correlation_id` and `sequence_no`, so apply order is auditable from the event log alone.

**See:** ORD-01, ORD-02, ORD-03, OBS-05, PAR-01 (these events are appended to the partitioned event log)
