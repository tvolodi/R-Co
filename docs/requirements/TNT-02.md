---
id: TNT-02
title: Migration runner enforces schema-path isolation
stage: 12
priority: MUST
status: DRAFT
---

# TNT-02 — Migration runner enforces schema-path isolation `[MUST]`

> The migration runner SHALL execute each migration file inside the target
> tenant schema by setting `search_path = <tenant_schema>, public` on the
> connection before running the SQL. Migration files SHALL NOT use explicit
> `public.` table qualifiers for business tables. A linter SHALL reject any
> migration file that references `public.<business_table>` at CI time.

**Acceptance Criteria:**
- GIVEN `migrations.runForSchema(pool, migrations_dir, "tenant_abc123")` is
  called, WHEN a migration file contains `CREATE TABLE events (...)`, THEN the
  table is created in `tenant_abc123.events`, not `public.events`.
- GIVEN the migration runner acquires a connection, THEN it issues
  `SET search_path = <tenant_schema>, public` as the first statement on that
  connection before executing any migration SQL.
- GIVEN a migration file contains the string `public.events`,
  `public.instance_projections`, `public.tasks`, `public.tokens`,
  `public.timers`, `public.audit_entries`, `public.audit_log`, `public.users`,
  `public.groups`, `public.group_members`, `public.roles`, `public.user_roles`,
  `public.api_tokens`, `public.webhook_subscriptions`,
  `public.dead_letter_items`, `public.event_type_registry`, or
  `public.repository_form_schemas`, WHEN the CI linter runs, THEN the pipeline
  fails with an error identifying the file and the offending line.
- GIVEN a migration file contains `public.tenant_schemas`, `public.tenant`, or
  `public.schema_migrations` (legitimate global references), WHEN the CI linter
  runs, THEN no error is raised for those specific references.
- GIVEN two tenant schemas A and B exist, WHEN a migration is applied to schema
  A, THEN schema B is not touched and its `schema_migrations` tracking row is
  unchanged.
- The `schema_migrations` table in `public` tracks `(schema_name, version)` as
  a composite primary key; a migration applied to `tenant_abc` records
  `(schema_name='tenant_abc', version=NNN)` and does not affect the
  `(schema_name='public', version=NNN)` row.

**See:** TNT-01 (business tables in tenant schemas), TNT-03 (search_path on
connection checkout), TNT-05 (backfill migration applies this runner to
existing tenants)

**Edge cases:**
- Migration file that uses a DO $$ BEGIN … END $$ block with dynamic SQL: the
  linter checks string literals within the block for `public.<business_table>`
  patterns.
- Migration that creates a function in `public` (e.g. a trigger helper): allowed
  if the function does not reference business tables by schema-qualified name.
- Migration applied to `public` schema (global infrastructure): runner uses
  `search_path = public`; no tenant schema is set; linter rules do not apply
  to global-scope migration files (distinguished by filename prefix `GBL-`).
