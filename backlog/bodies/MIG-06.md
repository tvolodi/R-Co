> The platform SHALL expose a migration admin surface requiring the platform-operator role: `POST /api/v1/admin/migrations/run` to start a fanout, `GET /api/v1/admin/migrations/{migration_id}/status` returning aggregate `pending`, `done` and `failed` counts with a per-tenant list carrying `error_msg` and `completed_at`, and `POST /api/v1/admin/migrations/{migration_id}/resume`. A defective migration is corrected by authoring a new `migration_id` that fixes forward; issuing compensating DDL across tenant schemas is prohibited, because a partial compensation leaves schemas divergent.

**Acceptance Criteria:**
- GIVEN a caller without the platform-operator role, WHEN it calls run, status or resume, THEN the platform returns HTTP 403.
- GIVEN a `migration_id` matching no file in the migration set, WHEN run is called, THEN the platform returns HTTP 404 `UnknownMigration` and writes no control rows.
- GIVEN a fanout that ended with failures, WHEN status is called, THEN the response carries the three counts and a per-tenant list with `error_msg` and `completed_at`.
- GIVEN a defective migration already applied to some tenants, WHEN it is corrected, THEN the correction is a new `migration_id` with its own fanout and no reverse DDL is issued across tenant schemas.
- GIVEN any migration has outstanding `pending` rows, WHEN the application starts, THEN it refuses to serve traffic and names the migration.

**See:** SPT-01, MIG-01, MIG-03, MIG-04, API-06
