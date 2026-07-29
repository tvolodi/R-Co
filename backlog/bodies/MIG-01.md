> The platform SHALL record platform migration state in a single cross-tenant control table `platform.platform_migrations`, holding one row per `(migration_id, tenant_id)` with `status` in `pending`, `done`, `failed`, plus `error_msg`, `completed_at` and `run_id`. The table carries `UNIQUE (migration_id, tenant_id)` as the upsert anchor and the partial index `platform_migrations_resume_idx ON (migration_id, status) WHERE status IN ('pending','failed')` covering the resume query. This replaces reliance on the per-schema `schema_migrations` table as the only record of migration state.

**Acceptance Criteria:**
- GIVEN a fanout begins, WHEN the control rows are seeded, THEN exactly one row exists per enabled tenant at `status = 'pending'`, keyed by `(migration_id, tenant_id)`.
- GIVEN the table is created, WHEN its constraints are inspected, THEN `UNIQUE (migration_id, tenant_id)` exists and `status` is constrained by a CHECK over exactly `pending`, `done`, `failed`.
- GIVEN the resume query runs, WHEN its plan is inspected, THEN it uses `platform_migrations_resume_idx`.
- GIVEN a tenant fails, WHEN its row is written, THEN `error_msg` carries the SQLSTATE and the message text and `completed_at` is null.
- GIVEN a tenant succeeds, WHEN its row is written, THEN `completed_at` is set and `error_msg` is null.

**See:** SPT-01, MIG-02, MIG-04, MIG-05, ENV-01
