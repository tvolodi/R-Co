# ISS-0185 — Eliminate duplicate tables across public and tenant_default

**Run ID:** WF03-GH518-20260808
**Issue:** GH-518 / ISS-0185
**Severity:** MAJOR
**Author:** ISSUE-FIXER
**Status:** DESIGN

## 1. Problem

The BPM Platform provisions two PostgreSQL schemas on every fresh database:
`public` and `tenant_default` (plus one `tenant_<uuid>` per tenant). The
migration runner replays every non-GBL migration once per schema, so any
non-GBL migration that issues an unqualified `CREATE TABLE <name>` creates
a copy of that table in both `public` and every tenant schema. 45 such
duplicates exist on a freshly migrated database, with diverging columns
because later GBL-only ALTER statements land on the public copy alone.

Because TestHarness sets `search_path = "tenant_default,public"`, any
unqualified reference silently resolves to the stale tenant_default copy.
This produces a recurring, silently-wrong-schema failure mode (column X
does not exist, on a column that demonstrably exists), which has now been
patched call-site-by-call-site at least four times (ISS-0089, ISS-0126,
ISS-0144, ISS-0150) without anyone addressing the underlying schema
duplication. See `docs/issue-reports/ISS-0185-diagnosis.yaml`.

## 2. Per-table classification

Classification is measured from three signals on the long-lived
`localhost:5434/bpm_test` database:

1. **Column shape on each copy** (information_schema.columns diff).
2. **Presence of `tenant_id` / `scope` / `owner_tenant_id` columns**.
3. **Application-code references** (grep of `src/**/*.zig` for
   `public.<name>` and unqualified `<name>`).

Result (see diagnosis report for full table): 37 GLOBAL_REGISTRY
(public canonical; tenant_default is the stray shadow); 8 PER_TENANT
(tenant_default canonical; public is the stray shadow); 0
intentionally-shared.

## 3. Fix plan

### 3.1 Scope header on every source migration

The runner's `migrationScope(filename, header)` returns `.public_only`
when the filename begins with `GBL-` OR the header contains
`-- scope: public`. The default for non-GBL files is `.all_schemas`,
which is the wrong default for global-registry tables.

**Action:** Add the `-- scope: public` header to every non-GBL
migration file that creates one of the 37 GLOBAL tables. Add the
explicit `-- scope: all_schemas` header to the 8 PER_TENANT
migrations (semantic no-op for the runner today, but makes intent
explicit and lint-detectable). Each file gets the header in the first
1 KiB so `migrationScope` picks it up.

This stops the bleeding on future fresh provisions.

### 3.2 Cleanup migrations

Two GBL-prefixed cleanup migrations run once on existing databases
to drop the stray copies:

- **GBL-134_iss0185_drop_global_registry_shadows.sql** — for the 37
  GLOBAL tables, drop `<schema>.table_name` from every tenant schema
  (`tenant_default` + each `tenant_<uuid>` derived from `public.tenant`).
  Idempotent (`DROP TABLE IF EXISTS`). Wrapped in a single transaction
  with `RAISE NOTICE` per drop so the run log shows the work.
- **GBL-135_iss0185_drop_per_tenant_shadows.sql** — for the 8
  PER_TENANT tables, drop `public.<name>`. Idempotent.

Pattern reused from GBL-132 (drop stray tenant schema_migrations
shadows) and GBL-104.

### 3.3 Linter guards

Two new linter pieces:

- **tools/lint_dual_schema_table_names.py** — at migration time, run
  inside the test-env-verify pipeline. Reads every migration file and
  parses out `CREATE TABLE [IF NOT EXISTS] <name>`. If `<name>` already
  exists in `public` AND `tenant_default` (information_schema.tables
  query) after applying all migrations, fail with BLOCKER listing the
  duplicated names and pointing at this design doc.
- **tools/lint_migration_schema.py extension** — augment the existing
  linter's "business tables" check to refuse any new migration that
  declares a CREATE TABLE on a name already present in any other
  schema. Allows the historical GLOBAL_REGISTRY list as exempt
  (their source migrations are pre-fix).

### 3.4 Acceptance

After applying GBL-134 + GBL-135 on a freshly migrated database:

```
SELECT t FROM (
  SELECT table_name FROM information_schema.tables
   WHERE table_schema='public' AND table_type='BASE TABLE'
) p INTERSECT SELECT table_name FROM information_schema.tables
 WHERE table_schema='tenant_default' AND table_type='BASE TABLE';
```

Expected result: **0 rows**.

## 4. Files touched

- `migrations/GBL-134_iss0185_drop_global_registry_shadows.sql` (new)
- `migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql` (new)
- `migrations/<45 source files>` (one-line header annotation each)
- `tools/lint_dual_schema_table_names.py` (new)
- `tools/lint_migration_schema.py` (extended)
- `tests/integration/iss0185_dual_schema_test.zig` (new regression test)
- `CHANGELOG.md` (DOC-UPDATER step)

## 5. Verification

- `zig build` exits 0
- `zig build test` exits 0
- `python3 tools/lint_dual_schema_table_names.py` exits 0
- `python3 tools/lint_migration_schema.py` exits 0
- The intersection query above returns 0 rows on a freshly migrated
  database AND on the long-lived shared `bpm_test` database after
  GBL-134 + GBL-135 are applied.

## 6. Out of scope

- Rewriting application code to consistently qualify table names
  (`public.<name>` for global, `<name>` or `tenant_default.<name>`
  for per-tenant). The current pattern works once the shadow copies
  are gone; the recurring failure mode the issue describes was caused
  by the shadow, not by the lack of qualifications.
- Renaming any duplicated table.
- Migration of fixture rows. The shadow copies are empty on a freshly
  migrated database (verified by the info_schema counts in the
  diagnosis report). The long-lived shared `bpm_test` may have rows in
  public shadow copies — those are leftovers and should be discarded.
