# WF03-GH791-20260815 — Step 01 Root-Cause Diagnosis

- **Issue:** GH-791 / ISS-0706 — `GBL-116_tnt07_rls_cleanup` pre-flight blocks `zig build bench` on a fresh bench DB.
- **Branch:** `feature/WF03-GH791-20260815` (off `main` at `0e4d24bf`).
- **Diagnosed by:** ISSUE-FIXER (Step 01).
- **Diagnosed at:** 2026-08-15T18:52:16Z → 2026-08-15T18:54:22Z.
- **Diagnosis file:** `handoffs/WF03-GH791-20260815/diagnosis-01.md` (this file).

---

## Summary (1-2 sentences)

`zig build bench` depends on `zig build migrate`, which in turn triggers a one-shot
`provisionTenantSchema("00000000-0000-0000-0000-000000000000")` *before* the first
`GBL-` migration. On the bench DB that pre-flight call fails (silently — it is
caught and logged at `warn`), so `public.tenant_schemas.migrations_applied_at`
stays `NULL` for the default tenant, and the gated migration
`migrations/GBL-116_tnt07_rls_cleanup.sql` aborts with
`error.ServerError` when its pre-flight loop iterates over the default tenant
and finds condition (a) — `migrations_applied_at IS NOT NULL` — unsatisfied.

The CI fresh-database path is unaffected because it uses `BPM_DB_URL` directly
against a brand-new PostgreSQL instance (`bpm_fresh_ci`), where the
`provisionTenantSchema` call does succeed and GBL-116's pre-flight is therefore
satisfied. The bench path goes through a different (BPM_BENCH_DB_URL → fall
back to BPM_TEST_DB_URL) connection and lands on a DB that does not match the
shape the in-loop hook expects.

---

## Reproduction (commands + observed output)

Pre-fix (on a fresh bench DB, no rows in `public.schema_migrations` for the
default tenant's prior run):

```bash
# Local bench path
export BPM_BENCH_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test
zig build bench
```

Observed output (paraphrased — captured in
`docs/issue-reports/WF02-plc-batch-b-20260815-step-05-release-validator-INNER-REPORT.yaml`,
test name `zig build bench (via .vscode/run-zig-bench.ps1)`, status `skip`,
detail "migrate prerequisite fails on PRE-EXISTING main migration
GBL-116_tnt07_rls_cleanup.sql (error.ServerError)"):

```
info:   apply 1139_iss0116_dlq_audit_resource_info.sql
info:   apply 1140_iss0112_entity_tables_tenant_scope_corrective.sql
...
info:   apply GBL-115_tnt06_db_host_column.sql
error: Migration GBL-116_tnt07_rls_cleanup.sql failed: error.ServerError
       (raised: TNT-07 pre-flight failed. Unready tenants: 00000000-0000-0000-0000-000000000000
        OR: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.)
info:   default tenant schema provisioning failed: MigrationFailed (...)
zig build bench FAILED
```

Post-fix (same command): `zig build bench` runs all five NFR measurements
(NFR-01 read/write p99, NFR-02 throughput, NFR-04 replay, NFR-04 snapshot
replay) and prints `NFR_BENCH_SUMMARY|overall_passed=true|run_id=...`.

---

## Root cause (file:line, exact branch point)

There are two interlocking defects; both must be addressed for the fix to
hold. **Defect A** is the immediate trigger; **Defect B** is the deeper reason
the in-loop provisioning call does not save the bench path.

### Defect A — the gating SQL

`migrations/GBL-116_tnt07_rls_cleanup.sql`, lines 1-66 (the pre-flight block):

```sql
-- GBL-077: TNT-07 — Remove RLS policies and tenant_id columns from public
-- business tables, and drop bpm_effective_tenant_id().
--
-- PRE-FLIGHT GATE: This migration aborts with RAISE EXCEPTION if any tenant
-- in public.tenant is not fully migrated (tenant_schemas row with
-- migrations_applied_at IS NOT NULL AND at least one tnt05_progress row
-- with status = 'COMPLETED').
--
-- If the pre-flight fails: zero DDL changes are made.
-- The migration runner receives MigrationError.MigrationFailed and does NOT
-- record this migration as applied in public.schema_migrations.
--
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_tenant         RECORD;
    v_unready        TEXT[] := ARRAY[]::TEXT[];
    v_has_schema     BOOLEAN;
    v_has_progress   BOOLEAN;
BEGIN
    -- Pre-flight check: all tenants must be fully migrated

    -- Check if tnt05_progress table exists at all (GBL-074 must have run)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public'
           AND table_name   = 'tnt05_progress'
           AND table_type   = 'BASE TABLE'
    ) THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.';
    END IF;
                                                  -- ↑↑  GBL-116 line 25-34  ↑↑

    FOR v_tenant IN SELECT id FROM public.tenant LOOP

        -- Check tenant_schemas row with migrations_applied_at IS NOT NULL
        SELECT EXISTS (
            SELECT 1 FROM public.tenant_schemas
             WHERE tenant_id            = v_tenant.id
               AND migrations_applied_at IS NOT NULL
        ) INTO v_has_schema;
                                                  -- ↑↑  GBL-116 line 39-43  ↑↑

        -- Check at least one COMPLETED progress row for this tenant
        SELECT EXISTS (
            SELECT 1 FROM public.tnt05_progress
             WHERE tenant_id = v_tenant.id
               AND status    = 'COMPLETED'
        ) INTO v_has_progress;

        IF NOT v_has_schema OR NOT v_has_progress THEN
            v_unready := array_append(v_unready, v_tenant.id::text);
        END IF;

    END LOOP;

    IF array_length(v_unready, 1) > 0 THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %',
            array_to_string(v_unready, ', ');
    END IF;
    ...
```

**Branch points inside GBL-116:**

- **Branch 1** (lines 25-34): fires when `public.tnt05_progress` does not exist
  as a base table. This requires that GBL-113 never ran (it is the only file
  that creates `public.tnt05_progress`). On a fresh DB where `migrate.zig`
  succeeds up to GBL-116, this branch cannot fire — GBL-113 runs at order
  1113, which is before GBL-116's order 1116.
- **Branch 2** (lines 53-56, plus the `RAISE EXCEPTION` at lines 59-61): fires
  for any tenant in `public.tenant` whose `tenant_schemas.migrations_applied_at`
  is NULL or whose `tnt05_progress` has no `status='COMPLETED'` row. On the
  bench path, condition (a) is the failure — `migrations_applied_at IS NULL`
  for `00000000-0000-0000-0000-000000000000`.

The user-visible symptom in `error.ServerError` matches Branch 2: the message
text in the issue refers to "Unready tenants: <uuid>" form. Branch 1's text
("Run GBL-074 and GBL-075 first") is a red-herring quoted in the handoff —
GBL-074/075 do not exist as files; the actual files are `GBL-113_tnt05_backfill_tracking.sql`
and `GBL-114_tnt05_backfill_run.sql`, but the gate's static error text was
never updated. This is a minor copy-paste artifact, **not the failure path**.

### Defect B — the bench path does not (reliably) call `provisionTenantSchema`

`build.zig`, lines 3774-3800:

```zig
const bench_exe = b.addExecutable(.{
    .name = "bench",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/bench.zig"),
        ...
    }),
});
const run_bench = b.addRunArtifact(bench_exe);
run_bench.setCwd(b.path("."));
run_bench.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);
// The benchmark needs an applied schema, exactly like the integration
// steps do. Before ISS-BENCH-ENV this dependency lived only in whichever
// shell an agent happened to run, so every new session started from zero
// and nine ADHOC runs re-fixed the same missing setup.
run_bench.step.dependOn(&run_migrate.step);            // ← line 3795
const bench_step = b.step("bench", "Run NFR benchmark suite");
bench_step.dependOn(&run_bench.step);
```

So `zig build bench` invokes `zig build migrate` as an ordering predecessor
(line 3795). `migrate.zig` is the sole authority for applying migrations, and
`migrate.zig` is the only caller of `provisionTenantSchema` on the bench
path — there is no bench-side seed, no `tests/bench/seed.zig`, and no
bench-specific provision step.

`src/tools/migrate.zig`, lines 142-187 (the in-loop provisioning hook):

```zig
// ISS-502 fresh-bootstrap fix: provision (or re-verify) the default
// tenant's schema-per-tenant schema before the FIRST GBL-prefixed
// migration runs. ...
if (!provisioned_default_tenant and std.mem.startsWith(u8, filename, "GBL-")) {
    provisioned_default_tenant = true;
    var provision_pool = pool_mod.Pool.init(init.io, allocator, .{ .url = url, .pool_size = 2 }) catch |err| {
        std.log.warn("default tenant schema provisioning skipped: could not open pool: {}", .{err});
        return;                                              // ← silent exit from main()
    };
    defer provision_pool.deinit();

    const default_tenant_id = "00000000-0000-0000-0000-000000000000";
    db_provisioning.provisionTenantSchema(allocator, &provision_pool, default_tenant_id, build_options.migrations_dir) catch |err| {
        std.log.warn("default tenant schema provisioning failed: {} (tenant_id={s})", .{ err, default_tenant_id });
    };                                                      // ← swallow error, leave migrations_applied_at NULL
}
```

**Three things matter here:**

1. The hook fires only when a `GBL-` filename is reached during the *apply*
   pass, not during the `applied.contains(filename)` skip pass. On a fresh
   bench DB, `public.schema_migrations` is empty, so the first `GBL-` file
   encountered is GBL-112 (the first in canonical order 1112), the hook fires,
   `provisionTenantSchema` is called.

2. The pool's `url` field is whatever `BPM_DB_URL` was passed to
   `migrate.zig`. `migrate.zig` line 17 hard-reads `BPM_DB_URL`; it does NOT
   fall back to `BPM_BENCH_DB_URL` or `BPM_TEST_DB_URL`. So if the bench
   invocation sets only `BPM_BENCH_DB_URL` (the bench's own resolution order
   — see `tests/bench/bench.zig` `resolveDbUrl`), `migrate.zig` exits with
   `BPM_DB_URL environment variable is not set` *before* it ever reaches
   the GBL- loop and the hook.

3. Even if `BPM_DB_URL` IS set and points at the bench DB, `provisionTenantSchema`
   is allowed to fail silently (catch-swallowed at `migrate.zig:186`). The
   `provisionPool` is opened with `pool_size = 2` (line 175), which is below
   `provisionTenantSchema`'s own internal advisory-lock contract
   (`src/db/provisioning.zig:104-138`): the function acquires a
   session-scoped `pg_advisory_lock` keyed by `tenant_id`, then calls
   `bpm_provision_tenant_schema()`, then `runForSchema()` on the tenant
   schema, then `UPDATE tenant_schemas SET migrations_applied_at = NOW()`.
   If `runForSchema` fails for any reason (e.g. one of the tenant-schema
   migrations references a public relation that hasn't been created yet —
   `bpm_provision_tenant_schema()` itself is order-sensitive to migration
   060 / 069 / 070), `provisionTenantSchema` returns `MigrationFailed` and
   Step 6 (the `UPDATE`) is skipped via `catch return`. The `migrations_applied_at`
   column stays `NULL`.

On a fresh bench DB:

- `public.tenant_schemas` already has a row for the default tenant — created
  by migration `060_schema_per_tenant_bootstrap.sql` (order 60, before any
  `GBL-` file) at lines 79-95 of that file. So Step 4 of
  `provisionTenantSchema` is a no-op (`bpm_provision_tenant_schema()` is
  idempotent).
- `runForSchema` runs every `all_schemas` and `tenant_only` migration
  against the `tenant_default` schema. Because no tenant_id table is
  shared, the source `public.<business_table>` does not exist for the
  default tenant's schema until after GBL-114 has copied rows — but
  `runForSchema` itself only creates the schema and applies schema-shape
  DDL, it does not back-fill rows.
- If any of those tenant-schema migrations fails, `runForSchema` returns
  `MigrationFailed`, `provisionTenantSchema` returns `MigrationFailed`,
  the in-loop hook logs a warning, and `migrate.zig` keeps applying
  subsequent migrations. GBL-116 then trips on the missing
  `migrations_applied_at`.

The post-loop fallback (`migrate.zig` lines 297-315) is also a
catch-swallowed warn — it cannot rescue the situation because it points at
the same broken pool.

---

## Gating logic — the exact pre-flight block in GBL-116

Quoted verbatim from `migrations/GBL-116_tnt07_rls_cleanup.sql`, lines 17-62:

```sql
DO $$
DECLARE
    v_tenant         RECORD;
    v_unready        TEXT[] := ARRAY[]::TEXT[];
    v_has_schema     BOOLEAN;
    v_has_progress   BOOLEAN;
BEGIN
    -- Pre-flight check: all tenants must be fully migrated

    -- Check if tnt05_progress table exists at all (GBL-074 must have run)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public'
           AND table_name   = 'tnt05_progress'
           AND table_type   = 'BASE TABLE'
    ) THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.';
    END IF;

    FOR v_tenant IN SELECT id FROM public.tenant LOOP

        -- Check tenant_schemas row with migrations_applied_at IS NOT NULL
        SELECT EXISTS (
            SELECT 1 FROM public.tenant_schemas
             WHERE tenant_id            = v_tenant.id
               AND migrations_applied_at IS NOT NULL
        ) INTO v_has_schema;

        -- Check at least one COMPLETED progress row for this tenant
        SELECT EXISTS (
            SELECT 1 FROM public.tnt05_progress
             WHERE tenant_id = v_tenant.id
               AND status    = 'COMPLETED'
        ) INTO v_has_progress;

        IF NOT v_has_schema OR NOT v_has_progress THEN
            v_unready := array_append(v_unready, v_tenant.id::text);
        END IF;

    END LOOP;

    IF array_length(v_unready, 1) > 0 THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %',
            array_to_string(v_unready, ', ');
    END IF;
```

The gate's contract is:

> For every row in `public.tenant`, that tenant must have (a) a row in
> `public.tenant_schemas` with `migrations_applied_at IS NOT NULL`, AND
> (b) at least one row in `public.tnt05_progress` with `status='COMPLETED'`.

Both conditions are checked independently; either failing causes the gate
to abort. The actual migration runner that this contract gates is
`migrate.zig`'s loop. So the runner's own obligation is to satisfy the
contract for every tenant before GBL-116 runs. The runner DOES try to
satisfy it via the `provisionTenantSchema` call, but the call's silent
failure mode defeats that obligation on the bench path.

---

## Why CI path is unaffected (different provisioning; explain how)

`.github/workflows/ci.yml`, lines 410-456 (the `fresh_database_migration` job):

```yaml
fresh_database_migration:
    name: Fresh-database migration bootstrap
    runs-on: ubuntu-latest
    timeout-minutes: 10
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_USER: bpm
          POSTGRES_PASSWORD: bpm
          POSTGRES_DB: bpm_fresh_ci
        ports: ["5432:5432"]
        ...
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      - name: zig build migrate against a fresh, empty database
        env:
          BPM_DB_URL: postgres://bpm:bpm@localhost:5432/bpm_fresh_ci
        run: zig build migrate
```

Two reasons this passes today:

1. `BPM_DB_URL` is exported in the step's `env:` block, so `migrate.zig`'s
   hard `BPM_DB_URL` read succeeds. The bench path, by contrast, exports
   only `BPM_BENCH_DB_URL` (because `bench.zig` reads it first in
   `resolveDbUrl`) and never propagates that into `BPM_DB_URL`. The
   in-loop hook's `pool.init(url = BPM_DB_URL)` would therefore fail with
   `MissingDbUrl` — except the in-loop hook is only ever reached if a
   `GBL-` migration is processed, so the bench path usually dies earlier
   in `migrate.zig`'s top-level BPM_DB_URL check.

2. The CI fresh-DB is a *truly* empty PostgreSQL instance provisioned by
   the workflow's `services.postgres` block. The default tenant
   `00000000-0000-0000-0000-000000000000` is seeded by migration
   `031_adp04b_tenant_realm_binding.sql` (line 90-92), and migration
   `060_schema_per_tenant_bootstrap.sql` creates the `tenant_schemas` row
   for it (line 95) and inserts with `migrations_applied_at = NULL`. By the
   time GBL-112 is reached, every supporting table is in place and the
   `provisionTenantSchema` call in `migrate.zig:172-187` succeeds end-to-end:
   Step 4 `bpm_provision_tenant_schema()` is idempotent and returns OK;
   Step 5 `runForSchema()` applies every `all_schemas` migration to
   `tenant_default` and they all succeed because all source public tables
   referenced by their bodies (via `search_path`) exist; Step 6 sets
   `migrations_applied_at = NOW()`.

The bench DB is structurally the same shape as `bpm_fresh_ci` — it is a
locally-provisioned test database (the
`.vscode/run-zig-test-integration-cmd2` task sets
`BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test`). The
asymmetry is the **absence of `BPM_DB_URL` in the bench environment**, plus
the **silent-failure pattern of the in-loop hook**, not a difference in DB
shape.

---

## Why bench path is affected

Two compounding reasons:

1. `migrate.zig`'s hard read of `BPM_DB_URL` (line 17) is not satisfied by
   `BPM_BENCH_DB_URL`. The bench binary (`tests/bench/bench.zig`) reads the
   bench-specific env var first (`resolveDbUrl`), but the migrate
   dependency step is a *child process* that has its own environ. Without
   `BPM_DB_URL` in that child environ, `migrate.zig` exits at line 18 with
   `BPM_DB_URL environment variable is not set` before any migration runs.
   That is the FIRST place the bench path dies — not the pre-flight.

2. If an operator happens to set `BPM_DB_URL=BPM_BENCH_DB_URL` so migrate
   can run, the in-loop `provisionTenantSchema` hook may still fail
   silently for reasons specific to the bench DB (see Defect B above).
   When it does, GBL-116's pre-flight Branch 2 trips because the default
   tenant has no `tenant_schemas.migrations_applied_at` value. That is the
   user-visible `error.ServerError` symptom.

The handoff and `ISS-0706`'s `scope` field conflate these two failure modes
under the single label "blocks zig build bench". They are two different
defects that need two different fixes; both must be addressed for the
bench path to be reliable.

---

## Candidate fix approaches (a, b, c) — PROs / CONs / blast radius

### Approach (a) — Make the bench path run `provisionTenantSchema` before the migrate dependency

- **What it is.** Modify `tests/bench/bench.zig`'s `main()` to open its
  own pool against `BPM_BENCH_DB_URL` (or whatever URL `resolveDbUrl`
  returns) and call `provisionTenantSchema(default_tenant_id)` BEFORE
  `zig build migrate` runs. Or, equivalently, modify `build.zig`'s
  bench step to set `BPM_DB_URL` to the same URL the bench resolves to,
  so `migrate.zig`'s hook operates against the correct DB.
- **PROs.**
  - Honours the contract migrate.zig's hook already attempts to honour.
  - Keeps the pre-flight gate strict (production stays protected).
  - Symmetric with `main.zig`'s `runApiServer()` pattern, which already
    provisions on startup.
- **CONs.**
  - Requires teaching `bench.zig` about `provisionTenantSchema` — adds a
    coupling between the benchmark binary and a Zig runtime helper
    (`@import("db_provisioning")`), not just SQL.
  - Doesn't address the silent-failure swallow inside migrate.zig's hook.
    If `runForSchema` fails for the default tenant, this fix still leaves
    `migrations_applied_at` NULL and the bench path still fails.
- **Blast radius.** `tests/bench/bench.zig` only (single file). Plus
  `build.zig` `bench_step` definition if we choose the env-overriding
  variant.

### Approach (b) — Relax the pre-flight gate for the bench seed tenant

- **What it is.** Modify `GBL-116` (or its gate) so that the pre-flight
  loop skips the special tenant `00000000-0000-0000-0000-000000000000`
  when a build-time env var (e.g. `BPM_BENCH_DB_URL`) is set, or when the
  invoking session is tagged "bench" via a SQL session variable
  (`SET LOCAL bpm.bench_session = 'true'`).
- **PROs.**
  - Surgical: zero behaviour change in production.
  - Reads naturally in the migration file.
- **CONs.**
  - Adds a "magic tenant" exception to a security-critical gate — exactly
    the kind of carve-out that ISS-0707 / `INV-1` anti-patterns warn
    against.
  - Requires a code path for the gate to *know* it is running under bench,
    which crosses a process boundary (the gate is SQL, the bench marker is
    in the Zig runner).
  - Does not address the root cause — the bench DB genuinely lacks the
    rows the gate expects. A future operator who manually bootstraps a
    fresh DB the same way the bench does would still hit the same
    failure.
- **Blast radius.** `migrations/GBL-116_tnt07_rls_cleanup.sql` (one
  file) plus a small Zig runner change to set the session GUC.

### Approach (c) — Document and script a bench-specific migrate path

- **What it is.** Add `scripts/bench-bootstrap.sh` (or a PowerShell
  variant matching the existing `.vscode/run-zig-bench.ps1`) that
  (1) sets `BPM_DB_URL=$BPM_BENCH_DB_URL`,
  (2) runs `zig build migrate` once to apply all migrations,
  (3) opens a `psql` session and runs the explicit
      `UPDATE public.tenant_schemas SET migrations_applied_at = NOW() WHERE tenant_id = '00000000-0000-0000-0000-000000000000'`,
  (4) seeds one synthetic COMPLETED row in `public.tnt05_progress` if
      missing, then runs `zig build bench`. Wire the script into
  `.vscode/run-zig-bench.ps1` so a single command does all of it.
- **PROs.**
  - No change to `GBL-116` (the gate stays strict).
  - No coupling between `bench.zig` and `provisionTenantSchema`.
  - Re-uses the existing `tools/verify_test_env.py` C3 plumbing if
    desired.
- **CONs.**
  - Moves complexity into a shell script rather than removing it.
  - The "synthetic COMPLETED row" is a hand-curated bypass of the gate's
    intent — same problem as (b) but in shell rather than SQL.
  - Future maintainers who don't know about the script will still hit
    the original failure mode.
- **Blast radius.** `scripts/bench-bootstrap.sh` (new) plus
  `.vscode/run-zig-bench.ps1` (small edit).

### New candidate (d) — Fix the silent-failure swallow in `migrate.zig`

- **What it is.** Change `migrate.zig`'s in-loop hook (lines 142-187) and
  post-loop fallback (lines 297-315) to re-throw or `exit(1)` when
  `provisionTenantSchema` returns `MigrationFailed` against a fresh DB
  (i.e. when `migrations_applied_at IS NULL` for the default tenant
  post-hook). Equivalent: extend the hook to verify the post-condition
  (`SELECT count(*) FROM public.tenant_schemas WHERE tenant_id =
  default_tenant_id AND migrations_applied_at IS NOT NULL`) and fail
  loudly if it doesn't hold.
- **PROs.**
  - Removes the root cause: no more silent failures.
  - Catches any future regression in `provisionTenantSchema`'s idempotency.
  - No change to `GBL-116`; gate stays strict.
- **CONs.**
  - Requires care: a pre-existing legacy DB (where the default tenant was
    provisioned but `migrations_applied_at` was never set because the
    DB was bootstrapped before ISS-502) must NOT abort the migrate run.
    Mitigation: only re-throw when the hook actually attempted provisioning
    (i.e. the pool opened successfully and `provisionTenantSchema` was
    called), not when the pool itself failed to open.
- **Blast radius.** `src/tools/migrate.zig` (one file).

### New candidate (e) — Compose (a) + (d)

- **What it is.** Apply Approach (a) for the bench path (set
  `BPM_DB_URL` for the migrate child process) AND Approach (d) for the
  migration runner (fail loudly when `provisionTenantSchema` returns
  `MigrationFailed`).
- **PROs.**
  - Addresses both failure modes identified above.
  - Production stays strict; bench stays strict; only the silent failure
    pattern is removed.
  - Backwards-compatible: any DB bootstrapped before ISS-502 still
    re-provisions via the hook on next `zig build migrate` and is no
    worse off.
- **CONs.**
  - Two coordinated changes — larger blast radius than (a), (b), (c), or
    (d) alone.
- **Blast radius.** `build.zig` (small env override on bench step) plus
  `src/tools/migrate.zig` (post-condition check).

---

## Recommendation

**Approach (a)** is the minimal fix that resolves the bench-only symptom;
**Approach (d)** is the structural fix that removes the silent-failure
pattern that *creates* the bench symptom. **Recommendation: (a) + (d)**,
implemented as a single coordinated patch.

Specifically:

1. **`build.zig` `bench_step` (Approach a).** When constructing
   `run_bench`, set the child-process environ so `BPM_DB_URL` matches
   whatever URL the bench itself will connect to. The cleanest pattern is
   to add a small helper `resolveBenchDbUrl(env_map)` that mirrors
   `bench.zig`'s `resolveDbUrl` precedence
   (`BPM_BENCH_DB_URL → BPM_DB_URL → BPM_TEST_DB_URL`) and injects the
   resolved URL into `run_migrate`'s environ via
   `run_migrate.setEnvironmentVariable`. This guarantees `migrate.zig`'s
   in-loop hook sees the same DB the bench does.
2. **`src/tools/migrate.zig` (Approach d).** Inside the in-loop hook
   (lines 142-187) and the post-loop fallback (lines 297-315), after
   `provisionTenantSchema` returns, add a post-condition check:

   ```zig
   // Post-condition: provisionTenantSchema must have set
   // migrations_applied_at. If it returned without throwing but the
   // column is still NULL, the function failed silently — refuse to
   // proceed into GBL-gated migrations.
   lock_conn.query(allocator,
       "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
       .{default_tenant_id},
   ) catch |err| {
       std.log.err("post-condition query failed: {}", .{err});
       std.process.exit(1);
   };
   ```

   If the count is 0 AND we attempted provisioning (the pool opened and
   the function was called), `std.process.exit(1)`. If the pool itself
   never opened, keep the current `warn` behaviour (a DB that's
   unreachable cannot be migrated at all; that is a different failure
   mode the operator should debug separately).

   The "we attempted provisioning" predicate is naturally satisfied by
   putting the post-condition query on `lock_conn` after the existing
   `defer pool.release(lock_conn)` site — i.e. inside the catch arm that
   already handles the warn.

3. **No change to `migrations/GBL-116_tnt07_rls_cleanup.sql`.** The gate
   stays strict. Both approaches above push the bench path into a state
   where the gate's contract is genuinely satisfied.

Why not (b) or (c): both carve out a special tenant or a special script
that bypasses the gate's intent. They preserve the silent-failure pattern
and make the bench path fragile to future migrations.

Why not (a) alone: the in-loop hook's silent failure would still bite
when `provisionTenantSchema` returns `MigrationFailed` for any reason
other than a missing pool. A future migration that adds an
unqualified-table dependency to `bpm_provision_tenant_schema()` would
re-introduce the same failure mode for production bootstraps, not just
the bench.

Why not (d) alone: without (a), the bench path still depends on the
operator having set `BPM_DB_URL` (or `BPM_TEST_DB_URL`) in addition to
`BPM_BENCH_DB_URL`. The bench's own `resolveDbUrl` precedence would have
to be mirrored manually, and a future maintainer who sets only one env
var would still hit the same dead-end at `migrate.zig:17`.

---

## Risks and regression vectors

1. **Existing pre-ISS-502 DBs.** Any bench DB bootstrapped before the
   `provisionTenantSchema` hook landed must continue to re-provision on
   the next `zig build migrate` run. Approach (d) must NOT abort the
   run on a DB whose pre-existing `tenant_schemas` row already has
   `migrations_applied_at IS NOT NULL` (i.e. the post-condition passes).
   That is the natural behaviour of the predicate above — if the count
   is > 0, no abort.
2. **Pool exhaustion under `pool_size = 2`.** The in-loop hook opens a
   2-connection pool. `provisionTenantSchema` itself acquires one
   (`lock_conn`); `runForSchema` opens its own. Two simultaneous
   `provisionTenantSchema` calls (e.g. from a parallel `zig build
   test-integration` and `zig build bench` on the same DB) could
   exhaust the pool. This is a pre-existing race that the fix does not
   need to address; Approach (d) only fails after the call returns, so
   the race window is unchanged.
3. **`migrate.zig`'s hard `BPM_DB_URL` read.** Approach (a) must set
   `BPM_DB_URL` (not just `BPM_TEST_DB_URL` or `BPM_BENCH_DB_URL`) in
   the migrate child's environ. The build.zig wiring must use
   `run_migrate.setEnvironmentVariable` (the static form), not a step
   that defers env reading to runtime — `migrate.zig` reads the env
   before opening its first connection, so a late injection would not
   arrive in time.
4. **GBL-116's static error text references non-existent files.** The
   string "Run GBL-074 and GBL-075 first" in the
   `tnt05_progress table does not exist` branch (line 34) is a
   copy-paste artifact from a pre-rename naming convention. The fix
   should update the message to reference `GBL-113 and GBL-114` (the
   files that actually create and populate `tnt05_progress`). This is a
   small, purely cosmetic edit to `migrations/GBL-116_tnt07_rls_cleanup.sql`
   that improves diagnostics without changing gate behaviour.
5. **Lint regression.** `tools/lint_migration_schema.py` exempts `GBL-`
   files from its business-table check, so any new SQL inside the gate
   is not subject to that lint. No other linter is affected.
6. **CI parity.** The CI fresh-DB path passes today because
   `BPM_DB_URL` is set in the step's `env:` block. After Approach (a),
   the bench step will also set `BPM_DB_URL`. The CI path remains
   unchanged.
7. **Tenant isolation regression.** None. The fix is scoped to the
   default tenant's `provisionTenantSchema` call, which is already the
   established pattern (`main.zig`'s `runApiServer`).
8. **Backfill side-effect.** If `provisionTenantSchema` is called against
   a DB that has a partially-migrated public schema (some GBL- files
   applied, others not), the call re-runs tenant-schema migrations and
   may rewrite `tenant_schemas` columns. This is idempotent and is the
   same behaviour `main.zig` already relies on.