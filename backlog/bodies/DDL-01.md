> **Extends:** MIG-01, adding a pre-flight gate ahead of the tenant fanout.

> The platform SHALL validate every migration statement through `ValidatePlatformDDL`, a pure function over parsed statement descriptors that holds no database handle, opens no connection, reads no clock, and reads no environment variable. It SHALL reject the statement classes that hold `ACCESS EXCLUSIVE` for a duration proportional to table size -- `DROP COLUMN`, `CLUSTER`, `VACUUM FULL`, `REINDEX` without `CONCURRENTLY`, and `ALTER COLUMN ... SET DATA TYPE` -- and index statements written without `CONCURRENTLY`. Validation SHALL complete before the fanout of MIG-01 opens a connection to any tenant schema, so a rejected file set touches zero schemas.

**Acceptance Criteria:**
- GIVEN a file set containing `ALTER TABLE events DROP COLUMN legacy_flag`, WHEN the migration plan runs, THEN `ValidatePlatformDDL` returns `UnboundedExclusiveLock` naming that statement, the plan exits with status 2, and zero connections are opened to any tenant schema.
- GIVEN a file set containing `CREATE INDEX idx_events_actor ON events (actor_id)` without `CONCURRENTLY`, WHEN validated, THEN `NonConcurrentIndexBuild` is returned and the file set is REJECTED.
- GIVEN a file set containing `ALTER TABLE events ALTER COLUMN payload SET DATA TYPE JSONB`, WHEN validated, THEN `UnboundedExclusiveLock` is returned; the accepted route for a type change is the three phases of DDL-03 followed by a rename swap.
- GIVEN one descriptor list, WHEN `ValidatePlatformDDL` is called from a unit test with no database reachable and no `BPM_DB_URL` set, THEN the call succeeds and returns the same verdict as the in-process call made during a real migration plan.
- GIVEN a file set of 200 accepted statements, WHEN validated, THEN the verdict is returned in under 100 ms.
- The verdict and the offending statement text are written to `plat_migration_plan`, and `EXECUTION_MIGRATION_VALIDATED` is appended to the event log.

**See:** MIG-01 (the tenant fanout this gates), DDL-02 (ordering check run in the same pass), DDL-03 (the accepted rewrite), DDL-05 (namespace check run in the same pass), ADP-12 (regression suite exercising the validator against the default tenant)
