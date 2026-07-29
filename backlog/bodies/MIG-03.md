> The platform SHALL apply a migration across a snapshot of enabled tenants ordered by `tenant_id`, holding `pg_try_advisory_lock(hashtext(migration_id))` on the platform database for the duration of the run. A failure in tenant N SHALL NOT prevent tenants N+1 through M from being attempted; per-tenant errors are collected and the run continues to the end of the snapshot.

**Acceptance Criteria:**
- GIVEN tenant N fails, WHEN the run continues, THEN tenants N+1 through M are still attempted and each has a `done` or `failed` row when the run ends.
- GIVEN the advisory lock for `migration_id` is already held, WHEN a second run is requested, THEN the platform returns HTTP 409 `MigrationAlreadyRunning`.
- GIVEN two different `migration_id` values, WHEN both are run, THEN they may execute concurrently because the lock key is derived from `migration_id`.
- GIVEN a tenant is created after the snapshot is taken, WHEN it is provisioned, THEN the tenant onboarding path applies the full migration set and inserts `done` rows, so the tenant is not left behind by the concurrent fanout.
- GIVEN the snapshot is exhausted, WHEN the run returns, THEN the response carries `{run_id, done, failed, pending}` counts.

**See:** SPT-01, MIG-01, MIG-02, MIG-04, MIG-06
