# Module: ISS-0091 Fix — Unify Test-Harness Migration Tracking with the Canonical Tracker

## Module purpose

Retires the second, un-synchronized migration tracker that `tests/integration/helpers.zig` has
maintained since before ISS-504. `TestHarness.init()` will call the real
`bpm.migrations.Migrations.runForSchema()` — the same canonical migrator every other caller uses —
instead of its own local `runMigrations`/`runMigrationsForSchema` functions that track applied
versions in a schema-local `schema_migrations` table. This implements acceptance-criterion option
(a) from ISS-0091 / GitHub #343.

## Root cause (adopted from ISS-0091 diagnosis, docs/issues/ISS-0091.json)

Two independent trackers apply the same `migrations/*.sql` files to the same tenant schema but
consult different bookkeeping:

1. **Canonical tracker** — `src/db/migrations.zig::Migrations.runForSchema()` records applied
   versions in `public.schema_migrations(schema_name, version)`. This is the single source of
   truth per `src/design/iss504_migration_tracking.md`.
2. **Legacy harness tracker** — `tests/integration/helpers.zig::runMigrations()` /
   `runMigrationsForSchema()` create and query their own `schema_migrations` table that resolves
   (via `search_path`) to live inside `public` or the tenant schema itself, entirely independent
   of tracker 1.

A migration recorded "applied" by the harness's tracker is invisible to the canonical tracker.
Test files whose own `makePool()` calls `Migrations.runForSchema()` directly (bypassing
`TestHarness`) then see the migration as not-yet-applied and re-attempt it, colliding with
non-idempotent inline named constraints/indexes left behind by later rename migrations
(e.g. `047_repository_form_schemas.sql`'s `uq_form_schema_field` after `072_tnt01_rename_legacy_tables.sql`
renames the table).

## Scope and non-goals

- In scope: `tests/integration/helpers.zig` — replace `runMigrations`/`runMigrationsForSchema`
  bodies with calls to the real `Migrations.run()` / `Migrations.runForSchema()`.
- In scope: reconciling any already-diverged local `bpm_test` container (drop the stray
  schema-local `schema_migrations` tables so no volume wipe is required).
- In scope: a regression test asserting a fresh `TestHarness.init()` and a fresh direct
  `Migrations.runForSchema()` call against the same schema agree on applied-migration state.
- Out of scope: changing `Migrations.runForSchema()` itself (already correct per ISS-504).
- Out of scope: the GBL-074/075/077 skip-list behavior in the harness (orthogonal — these are
  skipped for isolated test runs regardless of which tracker is used; preserved as-is).
- Out of scope: `applyCompatibilityShims`, `resetTestData`, `ensureDefaultOidcSeeds` — unrelated
  to migration tracking, left untouched.

## Design

### 1. `runMigrations` (public schema) → delegate to `Migrations.run()`

Replace the body of `fn runMigrations(io, allocator, conn: *pg.Conn) !void` with a version that:

1. Reads `BPM_TEST_DB_URL` is already available in the caller (`TestHarness.init`) — thread the
   `url: []const u8` parameter through instead of only a `*pg.Conn`, since `Migrations.run()`
   requires a `*Pool`, not a raw `*pg.Conn`.
2. Opens a short-lived `Pool` scoped to this function (`bpm.pool.Pool` / `bpm.pool.PoolConfig`,
   matching the import pattern already used by `tests/integration/iss102_claim_test.zig`'s
   `makePool`):
   ```zig
   var mig_pool = try bpm.pool.Pool.init(io, allocator, .{ .url = url, .pool_size = 2 });
   defer mig_pool.deinit();
   try bpm.migrations.Migrations.run(allocator, &mig_pool, migrations_dir);
   ```
   `migrations_dir` resolution: `build_options.migrations_dir` is always an absolute path (set at
   build time via `b.path("migrations").getPath(b)` in `build.zig:11`), and `BPM_MIGRATIONS_DIR`
   (when set, e.g. by `build.zig`'s `setEnvironmentVariable` calls for test targets) is likewise
   always populated with that same absolute path — never a bare relative override. So the existing
   `env_migrations_dir orelse build_options.migrations_dir` resolution already yields an absolute
   path suitable for `Migrations.runForSchema()`'s `std.Io.Dir.openDirAbsolute()` call; no new
   realpath conversion is needed. The harness's `migration_candidates` relative-path fallback loop
   (`"migrations"`, `"../migrations"`, ...) existed only to handle the case where neither the env
   var nor the build option was set — a defensive fallback that has never been exercised in
   practice for this codebase's test targets (all of which set `BPM_MIGRATIONS_DIR` via
   `build.zig`). **Drop this fallback loop entirely** when delegating to `Migrations.run()`/
   `runForSchema()` — pass `env_migrations_dir orelse build_options.migrations_dir` straight
   through. If it is ever unset in some future test target, `Migrations.runForSchema()` will
   correctly return `MigrationError.MigrationsDirectoryNotFound` instead of silently trying
   relative paths.
3. Keep the advisory lock (`pg_advisory_lock(hashtext('bpm_test_migrations_public'))`) wrapping
   the whole pass — still needed for ISS-0090 (concurrent test binaries), taken on `conn` (the
   harness's own connection) before opening the migration pool, released after.
4. Remove the local `CREATE TABLE IF NOT EXISTS schema_migrations (...)` bootstrap, the manual
   file-scan/applied-set/apply loop, and the `GBL-074/075/077` skip-list — **except** the skip-list
   must be preserved somehow, because it is test-environment-specific behavior that
   `Migrations.runForSchema()` does not know about.

   **Skip-list reconciliation (important design decision):** `Migrations.runForSchema()` has no
   hook for "skip these specific files in this specific caller." Two options:
   - (i) Extend `MigrationError`/`runForSchema` with an optional `skip_files: []const []const u8`
     parameter, defaulting to `&.{}` for all production callers.
   - (ii) Keep skipping at the harness level by pre-recording those three filenames as "applied"
     directly in `public.schema_migrations` (schema_name='public') before calling
     `Migrations.run()`, so the canonical tracker itself skips them (idempotent no-op if already
     present, via `INSERT ... ON CONFLICT (schema_name, version) DO NOTHING`).

   **Decision: use option (ii).** It requires no change to the canonical, production-facing
   `Migrations.runForSchema()` signature (avoiding any risk to non-test callers) and keeps the
   test-only skip behavior entirely inside the test harness where it has always lived.
   Insert rows for `GBL-074_tnt05_backfill_tracking.sql`, `GBL-075_tnt05_backfill_run.sql`,
   `GBL-077_tnt07_rls_cleanup.sql` under `schema_name='public'` before calling `Migrations.run()`.

### 2. `runMigrationsForSchema` (tenant schema) → delegate to `Migrations.runForSchema()`

Replace the body of `fn runMigrationsForSchema(io, allocator, conn: *pg.Conn, schema: []const u8) !void`
similarly:

1. Keep the existing advisory lock (`pg_advisory_lock(hashtext($1))` keyed by schema name) and the
   `already_migrated` fast-path check against `public.tenant_schemas.migrations_applied_at` — both
   remain valid optimizations independent of which tracker applies migrations, and the fast-path
   check already queries the canonical `public.tenant_schemas` table, not the legacy tracker.
2. If not already fully migrated, call:
   ```zig
   var mig_pool = try bpm.pool.Pool.init(io, allocator, .{ .url = url, .pool_size = 2 });
   defer mig_pool.deinit();
   try bpm.migrations.Migrations.runForSchema(allocator, &mig_pool, migrations_dir, schema);
   ```
3. `Migrations.runForSchema()` already skips `GBL-`-prefixed files for non-`"public"` schema names
   (see `src/db/migrations.zig:203-207`) — the harness's own `if (std.mem.startsWith(u8, filename, "GBL-")) continue;`
   line becomes redundant and is removed; no replacement needed.
4. After `runForSchema` returns, the harness's `conn.exec(set_path_sql, ...)` (SET search_path)
   call after the fast-path branch must remain — `Migrations.runForSchema()` sets `search_path` on
   its own pool connection, not on the harness's original `conn`, which must still have its
   `search_path` set for the rest of `TestHarness.init()` (compatibility shims, resetTestData,
   etc. operate on `conn`, not on the migration pool).
5. Remove the local `CREATE TABLE IF NOT EXISTS schema_migrations` bootstrap and the manual
   scan/apply loop.

### 3. Threading `url` into both functions

`TestHarness.init()` already holds `url` (read from `BPM_TEST_DB_URL`) before calling
`runMigrations`/`runMigrationsForSchema`. Add `url: []const u8` as a parameter to both functions
(call sites already have it in scope at `tests/integration/helpers.zig:589` and `:597`).

### 4. `migrations_dir` is already absolute — no new resolution needed

Confirmed by inspection of `build.zig:11` and `src/db/provisioning.zig:112` (the production
`provisionTenantSchema()` caller, which passes `build_options.migrations_dir` straight into
`Migrations.runForSchema()` with no path conversion). The harness should do the same: read
`BPM_MIGRATIONS_DIR` via the existing `environ.getAlloc` call, fall back to
`build_options.migrations_dir` if unset, and pass the result directly. See point 2 above.

### 5. Reconciling already-diverged local `bpm_test` state

For any developer's already-running `bpm_test` container where the divergence has already
happened: after this fix ships, the next `TestHarness.init()` run will consult
`public.schema_migrations` instead of the stray `tenant_default.schema_migrations` /
`public.schema_migrations`-shadowed-by-search_path copy. Since the canonical tracker is missing
rows for migrations the legacy tracker already applied, `Migrations.runForSchema()` will attempt
to re-apply them and hit the same "already exists" collision once, on the first run after the fix.

**Reconciliation approach:** a one-time idempotent backfill migration (or a documented manual
step) is out of scope for the code fix itself but must ship alongside it: add a `scratch/`-local
one-off SQL script (not a tracked migration — this is dev-environment repair, not a schema change)
that backfills `public.schema_migrations` rows for `schema_name='tenant_default'` for every
version already present in the stray local tracker, so existing containers do not need a volume
wipe. BACKEND-DEV should provide this as a documented step in the handoff result, not a tracked
migration file (no production schema change is needed — this is purely reconciling test-only
tracking state).

## Public interface changes

- `tests/integration/helpers.zig::runMigrations` — signature gains `url: []const u8` parameter.
  Internal-only (not exported), so this is not a breaking public API change.
- `tests/integration/helpers.zig::runMigrationsForSchema` — signature gains `url: []const u8`
  parameter. Internal-only.
- No changes to `src/db/migrations.zig` — `Migrations.run()` / `Migrations.runForSchema()` keep
  their existing signatures untouched, preserving every production call site.

## Error taxonomy

No new error types. `runMigrations`/`runMigrationsForSchema` continue to return `!void` (Zig
error unions); errors now propagate from `bpm.migrations.MigrationError` and `PoolError` (via the
new inner `Pool.init`/`runForSchema` calls) instead of from raw `pg.Conn` calls. `TestHarness.init()`
already wraps every migration call site with a `catch |err| { std.debug.print(...); return err; }`
block — no change needed there, since the wrapped calls still return `!void`.

## Dependencies

- `src/db/migrations.zig::Migrations.run()` / `Migrations.runForSchema()` (unchanged, canonical).
- `src/db/pool.zig::Pool.init()` / `Pool.deinit()` (existing API, new caller).
- ISS-504 (`src/design/iss504_migration_tracking.md`) — this fix realizes ISS-504's decision for
  the one caller (test harness) that predated and violated it. Add a short note at the end of
  ISS-504's design doc cross-referencing this fix (see Documentation update below).

## Documentation update

Append to `src/design/iss504_migration_tracking.md` (new section, do not edit existing content):

```markdown
## Addendum (ISS-0091 / GitHub #343)

`tests/integration/helpers.zig`'s `TestHarness.init()` bootstrapper predated this design and
maintained its own schema-local `schema_migrations` tracking table, independent of
`public.schema_migrations`. This was not covered by ISS-504's original verification scope. Fixed
by ISS-0091: the harness now calls the real `Migrations.run()` / `Migrations.runForSchema()`
directly, so there is exactly one migration tracker for every caller, test or production.
```

## Implementation notes from CODE-DESIGN-VALIDATOR review (both MINOR, non-blocking)

1. Besides `tests/integration/iss102_claim_test.zig`, at least three other files read the bare
   unqualified `schema_migrations` table directly on `harness.conn`:
   `tests/integration/db_integration_test.zig` (TC-DB-01-01/02),
   `tests/integration/xc06_backwards_compatibility_test.zig` (TC-XC-06-01), and
   `tests/integration/adp12_default_tenant_regression_test.zig` (TC-ADP-12-03). Once the harness
   stops creating a schema-local `schema_migrations` table, these unqualified references resolve
   to `public.schema_migrations` only (via `search_path`) — their existing assertions
   (count > 0, rows.len == 1, EXISTS) still hold, but re-run these three files explicitly after
   the fix and refresh any comments that assumed a single-schema-only row count.
2. Use `bpm.pool.Pool` / `bpm.pool.PoolConfig` for the short-lived migration pool (see snippets
   above) — matches the import pattern already used by `iss102_claim_test.zig`'s `makePool`.

## Verification points (for TEST-DESIGNER)

1. Regression test (new file, e.g. `tests/integration/iss0091_harness_tracker_unification_test.zig`):
   - Call `TestHarness.init()` for a fresh test.
   - Independently open a pool and call `Migrations.runForSchema()` directly against
     `tenant_default` (mirroring `iss102_claim_test.zig`'s `makePool` pattern).
   - Assert both observe the same set of applied versions in `public.schema_migrations WHERE
     schema_name = 'tenant_default'` (e.g. `SELECT count(*)` matches, and specifically that
     `047_repository_form_schemas.sql` is present).
   - Assert no schema-local `schema_migrations` table exists as a *second, divergent* row set —
     i.e. querying `schema_migrations` with `search_path` set to `tenant_default,public` returns
     the exact same row count as `public.schema_migrations WHERE schema_name='tenant_default'`
     (this is naturally true now since it's the same table).
2. Existing failing case from ISS-0091 (`zig build test-integration-iss102`) must pass without the
   `already exists` `C42P07` error.
3. `047_repository_form_schemas.sql` is recorded in `public.schema_migrations` with
   `schema_name='tenant_default'` after a fresh `TestHarness.init()` run.

## Files to change

- `tests/integration/helpers.zig` — `runMigrations`, `runMigrationsForSchema`, `TestHarness.init()`
  call sites (thread `url` through).
- `src/design/iss504_migration_tracking.md` — addendum note (append-only).
- New regression test file under `tests/integration/` (TEST-DESIGNER step).
- `scratch/` — one-off local reconciliation SQL script (not committed as a migration; documented
  in the BACKEND-DEV handoff result for any developer with an already-diverged local container).
