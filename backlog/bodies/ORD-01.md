> A BPM Consumer SHALL claim a pending effect completion with `SELECT completion_id, correlation_id, sequence_no FROM plat_effect_completion WHERE status = 'PENDING' ORDER BY correlation_id, sequence_no FOR UPDATE SKIP LOCKED LIMIT 1`, executed inside the transaction that will apply it. `SKIP LOCKED` guarantees no two consumers hold the same completion row. The claim guard SHALL NOT be relied on to serialise two different rows of the same correlation; that is the execute guard of ORD-02.

**Acceptance Criteria:**
- GIVEN 8 consumers polling and one `PENDING` row, WHEN they claim concurrently, THEN exactly one consumer receives the row and the other 7 receive no row; none blocks waiting for the lock.
- GIVEN every `PENDING` row is already locked by another consumer, WHEN a consumer claims, THEN it receives no row, sleeps 200 ms, and repeats without raising an error.
- GIVEN a consumer process is killed while holding a claim, WHEN its backend exits, THEN the row lock is released with the transaction and the row returns to `PENDING` without operator action.
- GIVEN two `PENDING` rows of the same `correlation_id` with `sequence_no` 5 and 6, WHEN two consumers claim concurrently, THEN both claims succeed because they are different rows; ordering is decided downstream by ORD-02 and ORD-03, not here.
- The claim is ordered by `(correlation_id, sequence_no)`, so a consumer that wins a correlation takes its lowest outstanding sequence first.

**See:** ORD-02 (execute guard), ORD-03 (order guard), ORD-04, DB-02 (one pooled connection per claim transaction)
