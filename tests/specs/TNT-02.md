# Test Spec: TNT-02 — Migration runner enforces schema-path isolation

**Requirement:** TNT-02 — The migration runner SHALL execute each migration file inside
the target tenant schema by setting `search_path = <tenant_schema>, public` on the
connection before running the SQL. Migration files SHALL NOT use explicit `public.`
table qualifiers for business tables. A linter SHALL reject any migration file that
references `public.<business_table>` at CI time.  
**Priority:** MUST  
**Test layer:** integration (DB-level checks), process (linter subprocess call)

## Test Cases

### TC-TNT-02-01: runForSchema creates table in tenant schema not public
**Given:** A fresh tenant schema is provisioned via `provisionTenantSchema` with a per-test UUID  
**When:** `pg_tables` is queried for `schemaname = <tenant_schema> AND tablename = 'events'`  
**Then:** Exactly 1 row is returned, confirming `events` was created in the tenant schema.
Also verify `pg_tables WHERE schemaname = 'public' AND tablename = 'events'` returns 0 rows.  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN `migrations.runForSchema` is called, WHEN a
migration file contains `CREATE TABLE events (...)`, THEN the table is created in
`tenant_abc123.events`, not `public.events`"

### TC-TNT-02-02: Migration runner sets search_path before any migration SQL
**Given:** A fresh tenant is provisioned  
**When:** A connection is acquired and `SHOW search_path` is executed immediately after
calling `runForSchema` with that tenant's schema name  
**Then:** The reported `search_path` contains the tenant schema name;
unqualified table references on that connection resolve to the tenant schema  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN the migration runner acquires a connection,
THEN it issues `SET search_path = <tenant_schema>, public` as the first statement
on that connection before executing any migration SQL"

### TC-TNT-02-03: Linter rejects migration file with public.events reference
**Given:** A temporary SQL file is created in `scratch/` containing the string `public.events`  
**When:** `python3 tools/lint_migration_schema.py` is invoked with that file's path  
**Then:** The process exits with code 1 and the file name and offending line appear in
the output  
**Layer:** process (subprocess)  
**Acceptance criterion mapped:** "GIVEN a migration file contains the string
`public.events`, WHEN the CI linter runs, THEN the pipeline fails with an error"

### TC-TNT-02-04: Linter accepts migration file with public.schema_migrations reference
**Given:** A temporary SQL file is created in `scratch/` containing `public.schema_migrations`
but no business table references  
**When:** `python3 tools/lint_migration_schema.py` is invoked with that file's path  
**Then:** The process exits with code 0; no BLOCKER error is emitted for that reference  
**Layer:** process (subprocess)  
**Acceptance criterion mapped:** "GIVEN a migration file contains `public.schema_migrations`
(legitimate global references), WHEN the CI linter runs, THEN no error is raised"

### TC-TNT-02-05: schema_migrations uses (schema_name, version) composite primary key
**Given:** Two tenants A and B are provisioned with different UUIDs  
**When:** `public.schema_migrations` is queried for `(schema_name, version)` rows for both tenants  
**Then:** Rows exist with `schema_name = <tenant_A_schema>` and with `schema_name = <tenant_B_schema>`;
no row with the same `(schema_name, version)` pair appears twice (PK constraint enforced);
the `public` rows and tenant rows coexist independently  
**Layer:** integration  
**Acceptance criterion mapped:** "The `schema_migrations` table in `public` tracks
`(schema_name, version)` as a composite primary key"

### TC-TNT-02-06: Applying migration to schema A does not touch schema B tracking rows
**Given:** Two tenants A and B are provisioned  
**When:** The count of `schema_migrations` rows for tenant B is recorded; then
`provisionTenantSchema` is called again for tenant A (idempotent second call)  
**Then:** The count of schema_migrations rows for tenant B is unchanged  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN two tenant schemas A and B exist, WHEN a migration
is applied to schema A, THEN schema B is not touched and its `schema_migrations` tracking
row is unchanged"
