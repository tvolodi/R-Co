> **Extends:** DDL-03, specifying the backfill phase.

> The backfill phase SHALL be idempotent and batched. The generated statement is `UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM t WHERE c IS NULL LIMIT $1))`, executed in a loop with one transaction per batch until an iteration reports zero updated rows. The loop SHALL NOT run inside an outer transaction. `backfill_batch_size` defaults to 5000 rows with an upper bound of 50000. A generated backfill whose predicate is not bounded by `IS NULL` SHALL be rejected with `NonIdempotentBackfill`.

**Acceptance Criteria:**
- GIVEN a backfill is interrupted after 40 of 100 batches and the migration runner restarts, WHEN the migration is re-run, THEN it resumes against the same `c IS NULL` predicate, rows already backfilled are skipped, and the end state is identical to an uninterrupted run.
- GIVEN a generated backfill whose predicate is not bounded by `IS NULL`, WHEN validated, THEN `NonIdempotentBackfill` is returned and no statement is executed.
- GIVEN a backfill batch, WHEN it executes, THEN it holds `ROW EXCLUSIVE` on the table and commits before the next batch begins; no transaction spans two batches.
- GIVEN a batch exceeds 5 s, WHEN the next batch is planned, THEN `backfill_batch_size` is halved for that tenant with a floor of 500 rows.
- GIVEN ten consecutive iterations report no progress, WHEN the loop detects the stall, THEN it stops and escalates with the remaining `IS NULL` row count for each tenant.
- Rows updated per batch and remaining `IS NULL` rows per tenant are recorded in `plat_migration_state`.

**See:** DDL-03 (the three phases), DDL-02 (why the backfill must precede the constraint), MIG-01, DB-02 (one pooled connection per batch, released between batches)
