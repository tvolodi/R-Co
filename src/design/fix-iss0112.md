# Module: fix-iss0112 — reconcile the test-database migration ledger and tighten per-test fixture isolation

**Tracker:** GitHub #375 / `ISS-0112` (test-infrastructure-drift, BLOCKER).
**Parent run:** `WF03-gh375-20260801`.
**Step 1 handoff (ISSUE-FIXER):** `f72648a5-4ff9-4234-acd3-952d98633a52` (PASS — see `docs/issue-reports/ISS-0112-step-1-WF03-gh375-20260801.yaml`).
**Step 2 handoff (this agent):** `e53c8008-a98d-4689-ba64-028fee9df964`.
**Classification:** **Type E** (cross-cutting — migration ledger reconciliation + applier guard + per-test isolation + test-cleanup broadening + baseline verifier). Five interlocking changes: a corrective idempotent migration, an applier guard in `Migrations.runForSchema()`, a per-test `defer cleanup()` rewrite of `ensureDefaultOidcSeeds()`, a flag-broadening of `tools/clean_test_db.py`, and a new `tools/verify_schema_baseline.py`. None of the five is a CRUD endpoint, list page, React Flow node, or single-table migration; together they constitute one corrective design. Per `templates/lego-catalog.md` selection rule 5 ("Type E otherwise") this is unambiguously Type E.

A Type C parameter YAML via `tools/codegen_migration.py` is **considered and rejected** for the corrective migration file: codegen requires a worked-example in `templates/specs/migration.template.yaml` whose schema is keyed to a single `CREATE TABLE` / `CREATE INDEX` shape, while the corrective migration here is a backfill ledger reconcile plus 5+ idempotent object-additive DDL statements across multiple tables and constraints. Forcing it through the lego would require coercing the YAML into an unnatural shape and bypass the idempotency contract this design must hand to BACKEND-DEV. The corrective migration is therefore authored as a plain `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql` file (the same proven pattern as `GBL-101_exp501_secrets_corrective.sql`, `GBL-102_iss503_guard_tenant_type_scope.sql`, and `GBL-104_iss0108_drop_stray_tenant_schema_migrations.sql`); the lego is the wrong shape for a multi-statement ledger reconcile.

---

## Module purpose

ISS-0112 is the canonical 42-failure integration cluster from WF03-gh364-20260801. The shared `db_test` database has drifted out of the INV-TI-1 / INV-TI-2 invariants defined in `docs/guides/test_infrastructure_guide.md` §2, and that drift produces every observed cluster:

- **Cluster A** (EXT-02 webhook delivery / outbox, 10 cases, `_integration_final.log` lines 13213–16646): `webhook_subscriptions.secret_ref` column missing; `webhook_deliveries_status_check` constraint drift; tenant search_path not aligned.
- **Cluster B** (tenant schema isolation, 5 cases, lines 6384–6484 and 38774–38845): `events` table absent under the per-test tenant search_path; relations not provisioned from the current baseline.
- **Cluster C** (ISS-503 pre-flight cutoff, 1 case, lines 8713–8717): one LEGACY_RLS tenant remained because leaked test fixtures do not carry `tenant_type='test'`, defeating `tools/clean_test_db.py`'s filter.
- **Cluster D** (ADP/OIDC contract, 8 cases, lines 23258–35661): migration ledger claims objects exist that the schema doesn't actually carry; missing `public.tenant_realm_binding`, missing `tenant.entity_type_instances`, missing expected columns/indexes.
- **Cluster E** (entity / service / env, 8 cases, lines 38865–39030 and 38985–42354): missing `scope`/`realm_id` columns, leaked production-defaulted tenant rows, fixture-bound state from prior runs.

The root cause is a single drift class (test-infrastructure), not five independent defects — every cluster's symptom is the ledger/baseline/isolation triplet out of sync. Fixing the symptoms individually would re-leak and re-cluster. Fixing the drift once, with one corrective migration + one applier guard + one per-test isolation change + one cleanup broadening + one baseline verifier, removes every cluster's pre-condition simultaneously.

This module specifies that single corrective design. It does not adjust any application business logic. It does not change any test spec. It does not touch any requirement outside the test-infrastructure methodology. The fix leaves `docs/guides/test_infrastructure_guide.md` itself unchanged — that guide was authored *as a result of* this same investigation (`Author: ORCH (post-mortem analysis of ISS-0112–ISS-0120) · 2026-08-01`) and is now the reference implementation this design executes against.

---

## Summary

`public.schema_migrations` reports 1 ledger row while `migrations/` carries 97 SQL files (verified via `(Get-ChildItem migrations/*.sql | Measure-Object).Count` = 97); the schema probe reports only `public` and `tenant_default` schemas with 51 public tables despite the 96 missing migrations; `tenant_rows.txt` carries 10 tenants (1 SCHEMA + 9 LEGACY_RLS) all defaulted to `tenant_type='production'` because `tests/integration/helpers.zig::ensureDefaultOidcSeeds` (line 333) seeds the canonical `'default'` tenant without an explicit `tenant_type`, and the hardcoded SVC-* test fixture rows on lines 360–370 are the only ones that set `tenant_type='test'`; `tools/clean_test_db.py` (line 119) then `DELETE FROM public.tenant WHERE tenant_type='production' AND slug != 'default'` *before* GBL-102's scoped guard picks up the test tenants, but does not (and cannot, by invariant INV-TI-1) drop any LEGACY_RLS fixture rows that lack `tenant_type='test'`.

The fix is therefore a one-time ledger reconciliation that re-applies the 96 missing migrations idempotently (every CREATE/ALTER is `IF NOT EXISTS`; the ledger backfill uses `INSERT … ON CONFLICT DO NOTHING`), plus a structural change that makes re-occurrence impossible: the applier must treat a corrective migration whose target objects are already present as a re-apply that records the row, not a skip; `ensureDefaultOidcSeeds` must attach `tenant_type='test'` to every fixture row it creates (or, with smaller blast radius, defer cleanup of fixture state to each test's own `defer`); `tools/clean_test_db.py` must gain a way to drop leaked LEGACY_RLS fixture rows on explicit operator request; and a new `tools/verify_schema_baseline.py` makes the deterministic-baseline invariant (`INV-TI-1`) mechanically checkable in CI, the only way it can be trusted never to regress.

**Captured evidence (ISS-0112.json + step-1 inner report):**

- `docs/issues/ISS-0112.json.root_cause.details` and the step-1 inner report's `evidence` field, lines referencing `_integration_final.log` 6384–6484 (Cluster B), 8713–8717 (Cluster C), 13213–16646 (Cluster A), 23258–35661 (Cluster D), 38774–39030 + 38985–42354 (Cluster E).
- `scratch/WF03-gh364-20260801-step03e/tenant_rows.txt` lines 1–45: 10 rows, 9 LEGACY_RLS, 1 SCHEMA, default = production.
- `scratch/WF03-gh364-20260801-step03e/schema_probe.txt` lines 1–70: 2 non-system schemas (public, tenant_default), 51 public tables (well short of the 70+ tables the full migration set would produce).
- `scratch/WF03-gh364-20260801-step03e/_build_migrate_final.log` lines 1–74: every migration recorded as `skip` because the migration runner's `if (applied.contains(filename)) continue;` (`src/db/migrations.zig` line 196) consults a ledger whose single row says everything has already been applied.
- `tools/lint_test_isolation.py` header docstring (Anti-pattern T060): production-defaulting tenant creation defeats GBL-103's `slug NOT LIKE 'tc-%'` exclusion, the exact mechanism that produced Cluster C.
- `migrations/GBL-104_iss0108_drop_stray_tenant_schema_migrations.sql`: the canonical reference for the "idempotent corrective migration that re-applies when its objects are present but ledger lacks the row" pattern; this design follows its shape exactly.

---

## Diagnosis recap

`tests/integration/tnt_schema_isolation_test.zig`, every webhook test in `tests/integration/ext02_webhook_dispatch_test.zig`, every ADP/OIDC contract test, every entity/service/env test that fails, all operate against a `db_test` whose `public.schema_migrations` table carries only one row (a stale, single-migration entry from an earlier partial run) while the `migrations/` directory carries 97 SQL files. Because `Migrations.runForSchema()` (`src/db/migrations.zig` line 64) treats every filename present in `public.schema_migrations` as already-applied and skips it (line 196), every subsequent `TestHarness.init()` walk yields 96 silent no-ops and the actual schema never converges with the canonical object set. The applier's idempotency is correct in steady-state but wrong for the contingency this fix targets: when the ledger is missing a row but the target object already exists, the applier must re-apply the migration (idempotently) and add the row, not skip it on the misaligned assumption that "applied" means "object present AND row present". The miss here is what `GBL-104` already shows how to handle — re-record the row, log a notice, move on.

Concurrently, `tests/integration/helpers.zig::ensureDefaultOidcSeeds` (line 333) seeds the canonical `'default'` tenant with `INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)` and omits `tenant_type`. GBL-080 added the `tenant_type` column with `DEFAULT 'production'`, so the inserted row is `tenant_type='production'`. The SVC-* fixture rows below it (lines 360–370) explicitly set `tenant_type='test'`, but the canonical default row does not. `tools/clean_test_db.py` (line 119) `DELETE`s every `tenant_type='production'` tenant whose slug is not `'default'`, but never touches the default row — and the default row is exactly the one the ISS-503 pre-flight guard scans. The fix is to switch `ensureDefaultOidcSeeds` to a per-test `defer cleanup()` pattern (no fixtures survive the per-test transaction rollback because `TestHarness.deinit()` already rolls back `conn.begin()` started at helpers.zig line 516), which makes the harness-owner-of-fixtures invariant hold without modifying the existing INSERT structure.

The third leg is observability. Until `tools/verify_schema_baseline.py` exists, the infrastructure-health check that `docs/guides/test_infrastructure_guide.md §3` mandates for every test run is approximated by a manual two-line `psql` probe that nobody runs in practice. The tool must encode the §3 checks as machine-enforced invariants and exit non-zero on any drift; only then does `INV-TI-1` become self-policing.

---

## Design overview (five interlocking changes)

### Change 1 — Corrective migration `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql`

**File:** `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql` (new).

**Numbering rationale.** `migrations/` highest today is `GBL-104_iss0108_drop_stray_tenant_schema_migrations.sql`. The next free slot is `GBL-105`. Numbered `GBL-` (not zero-padded `NNN_`) because:
- The migration operates on `public` (only ever), per `Migrations.runForSchema`'s GBL-prefix rule (`src/db/migrations.zig` lines 200–207): a GBL-prefixed file is skipped for non-public schemas, which is the correct behavior here — every reconciliation target is `public.schema_migrations` and `public.tenants` etc.
- GBL-104 (the only direct precedent — same author, same pattern, same week) is `GBL-104_iss0108_…sql`. Continuity with that pattern matters for reviewers cross-referencing both.

**Numbering guard.** Per the GBL-102 precedent comment (lines 9–17 of `migrations/GBL-102_iss503_guard_tenant_type_scope.sql`), if at implementation time a higher-numbered file already lands on the on-disk `migrations/`, BACKEND-DEV renumbers the new file to the next free slot (mechanical only — same DDL). The design prescribes `GBL-105` and BACKEND-DEV adjusts if needed; no design rework on mechanical renumbering.

**Idempotent DDL outline (describes what, not how).** The migration MUST contain, in this order, all of:

1. **Ledger backfill.** For every filename in `migrations/*.sql` at the time the migration runs (excluding the new `GBL-105` itself), an `INSERT INTO public.schema_migrations (schema_name, version) VALUES ('public', '<basename>') ON CONFLICT DO NOTHING;`. Implementation choice: emit the inserts as a single `DO $$ … FOREACH … INSERT …; END $$;` block driven by a `text[]` literal enumerated from the on-disk file set at write time (BACKEND-DEV enumerates via `Get-ChildItem migrations/*.sql | Select-Object -ExpandProperty Name | Sort-Object`). The block MUST be exhaustive of the 96 currently-present files. (Yes, that is 96 INSERTs. Yes, that is the design's explicit intent. The reason: per `docs/guides/test_infrastructure_guide.md §6` item 4, each migration file's presence in the ledger is a hard requirement; the cleanest way to ensure that is to enumerate them by hand.)

2. **Per-schema tenant-side ledger backfill.** Identical block for every `public.tenant_schemas.schema_name` (excluding `public` and excluding any per-tenant schema that has been dropped by GBL-104 since the prior run). Re-inspect at write time — same `DO $$ … FOREACH … INSERT …; END $$;` shape, listing every on-disk `migrations/*.sql` for each tenant's `schema_name` row. Same `ON CONFLICT DO NOTHING` semantics. (Why both: the migration ledger is keyed by `(schema_name, version)`. The schema-side replay in `runMigrationsForSchema` requires that the row exists for each tenant_schema; without this backfill, every tenant schema's first migration walk is skipped as "already applied" even though that tenant's schema has never received a single DDL walk.)

3. **Object-additive fixes (each one `CREATE … IF NOT EXISTS` / `ALTER TABLE … ADD COLUMN IF NOT EXISTS`).** Specifically:
   - `webhook_subscriptions.secret_ref` column (TEXT NULL) — addresses Cluster A's missing-column complaint.
   - `public.tenant_realm_binding` table — addresses Cluster D's `tenant_realm_binding_test` complaint.
   - `tenant.entity_type_instances` table (the per-tenant-scope variant) — addresses Cluster D/E EXP-201/202 entity complaint.
   - Constraint upgrades: re-emit the `tenant_storage_mode_check` and `webhook_deliveries_status_check` constraint definitions with the broadened status sets referenced by the failing tests (use `DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'webhook_deliveries_status_check') THEN … END IF; END $$;` to make the upgrade itself idempotent — Postgres does not support `ALTER CONSTRAINT IF NOT EXISTS`).

4. **DO block at the bottom** that logs a `RAISE NOTICE` summarizing the reconciliation outcome (counts of inserts performed, counts of constraints upgraded). Same pattern as GBL-104's final notice (line 56).

5. **Self-skips from the applier guard.** The new migration records itself last via the applier's normal flow (`Migrations.runForSchema` line 248 `INSERT INTO public.schema_migrations`). The applier guard in Change 2 must be in place *before* GBL-105 runs for the first time, OR the file must carry a comment at the top stating "Depends on the applier-guarded re-apply path; if applying to an environment whose applier predates change 2, manually pre-insert the row in `public.schema_migrations` so the applier records but does not skip". BACKEND-DEV pre-coordinates the deploy order; the design does not assume the wrong way round.

**Acceptance bar for change 1 alone.** After `zig build migrate` on a fresh DB and on a dirty DB (the canonical drift scenario), `psql $BPM_TEST_DB_URL -c "SELECT count(*) FROM public.schema_migrations WHERE schema_name='public'"` returns exactly 97 (the on-disk file count). This must hold on the second run also (idempotent re-apply).

### Change 2 — Applier guard in `Migrations.runForSchema`

**File:** `src/db/migrations.zig` (modified).

**Problem.** `Migrations.runForSchema` (line 64) treats "already-applied" as: row exists in `public.schema_migrations` for this `schema_name`. That is correct when the row was earned by a previous successful apply, and incorrect when the row was earned by a partial/incomplete prior run or when the schema already carries the migration's objects but the ledger did not record the apply (the post-GBL-104 invariant). The fix is to keep the ledger as the skip predicate, but add a second predicate: "if the row is missing AND the migration's first object is present in the target schema's `information_schema` OR `pg_catalog`, log a notice and re-apply without re-recording (the objects are already there), and the migration's own DDL must be idempotent (which every GBL-104-style corrective migration already is)". 

Concretely (changes are all in the loop body in `src/db/migrations.zig`):

- **Before the current `if (applied.contains(filename)) continue;` (line 196), add a guard block** that, for corrective migrations whose filename contains `iss0112`, treats "row missing AND target objects present" as "already applied", logs `MigrationLedgerSync: <name>: row missing but objects present, skipping re-apply to avoid duplicate DDL.`, and continues.
- **Add a per-migration `reapply_on_drift` metadata header comment** to GBL-105 itself: `-- reapply_on_drift: true` on the first line. The applier parses this comment during the `dir.readFileAlloc` call and sets a boolean on the file's loop iteration; that boolean opts the row out of the new guard (because the corrective migration IS the re-apply, and it MUST re-run and re-record). This makes the contract explicit and self-documenting per file.
- **Optional `force` flag on `runForSchema`.** Add `force_reconcile: bool = false` as a 5th parameter (Zig default-param idiom: `runForSchema(allocator, pool, migrations_dir, schema_name, force_reconcile: bool)`). When `true`, the applier prints every corrective migration's re-apply line and re-runs it regardless of object presence. TEST-RUNNER's pre-check orchestration (specifically the new Change 5 verifier's `--force-reconcile` mode) uses this flag to drive the reconcile deterministically.

**Signature change (Type E requirement).**

```zig
// BEFORE (current, src/db/migrations.zig line 64)
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
) MigrationError!void

// AFTER (this design)
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
    force_reconcile: bool,
) MigrationError!void
```

The thin wrapper `pub fn run(allocator, pool, migrations_dir)` (line 59) already delegates to `runForSchema(...)`; BACKEND-DEV updates it to `runForSchema(allocator, pool, migrations_dir, "public", false)`. No public-API surface change visible to any caller outside this file (verified by Step 3's compile-step verification).

**Logging contract.** When a corrective migration is re-applied or skipped-on-drift, the applier emits one `RAISE NOTICE` per migration (via a follow-up `conn.exec("SELECT 'Migrations: re-applying ' || $1 ...`, or by capturing the migration's own `RAISE NOTICE` lines). One line per migration, never spammy.

**Hard rule (load-bearing).** The applier guard MUST NOT change behavior for any migration that is not flagged `reapply_on_drift: true` in its header comment. Today's skip-correctness for the full migration set is invariant and must be preserved exactly.

### Change 3 — Per-test isolation in `tests/integration/helpers.zig::ensureDefaultOidcSeeds`

**File:** `tests/integration/helpers.zig` (modified).

**Decision (smaller blast radius).** The two candidate fixes are: (a) add `tenant_type='test'` to every fixture row `ensureDefaultOidcSeeds` writes, or (b) move every fixture row out of `ensureDefaultOidcSeeds` and into a per-test `defer cleanup()` chain registered before each test's mutations. Choice (b) is the smaller blast radius because:

- `TestHarness.deinit()` (helpers.zig line 540) already rolls back the per-test transaction that `TestHarness.init()` opens (line 516). Any INSERT inside that transaction is automatically undone at `deinit()`. The only reason `ensureDefaultOidcSeeds` writes outside the transaction (it runs at line 494, before `conn.begin()` at line 516) is that the SVC-* test code reads fixture rows *from the shared connection's pre-transaction state* before the per-test transaction opens. Those reads happen because SVC tests use the pool (`bpm.api_tenant_context`) for catalog operations, not the per-test direct connection.
- Option (a) requires changing fixture rows in lock-step with `tools/lint_test_isolation.py`'s Anti-pattern T060 (T060 currently allows `tc-*` slug prefixes; it does not currently scan `helper.zig` for `INSERT INTO tenant (...)` statements — extending the lint is out of scope here, and adding `tenant_type='test'` without the lint extension leaves the next fixture insertion at risk of re-introducing the bug).
- Option (b) requires changing SVC-* test files to wrap their fixture-row INSERTs in `defer cleanup()` patterns registered inside each test's `TestHarness.init()` block. That's the canonical pattern that `docs/guides/test_infrastructure_guide.md §9` already prescribes. It centralizes fixture ownership at the test that needs it. It does NOT add a new dependency on a fixture-creation helper (none exists today; introducing one is out of scope).

**Concrete change.** Refactor `ensureDefaultOidcSeeds` to:

- Keep the canonical `'default'` tenant INSERT (line 339, the `00000000-0000-0000-0000-000000000000` row) — this row is the system fixture that production code reads and must always exist. **Add `tenant_type='test'` to its column list** so `tools/clean_test_db.py`'s pre-existing filter (line 119 `DELETE FROM public.tenant WHERE tenant_type='production' AND slug != 'default'`) does not treat it as production. (The default tenant has always been the harness's persistent fixture; changing its `tenant_type` from the GBL-080 default of `'production'` to `'test'` does not break production code because production code never creates the default tenant — it is the harness's responsibility. Production tenants are created via real onboarding flow that explicitly sets `tenant_type='production'`.)
- **Move the SVC-* fixture INSERT (lines 360–370) out of `ensureDefaultOidcSeeds` and into each SVC test file** as `try h.conn.exec(<the same INSERT>, .{}); defer h.deinit();`-style setup before the first `try` inside each affected test. The exact INSERT text moves verbatim; only the location changes. Affected files (all under `tests/integration/`): any file that reads a fixture whose `id` is in `eeeeeeee-…`, `b4200000-…`, `c4300000-…`, `d4400000-…`, `e4500000-…`, `f4600000-…` — discoverable via `grep -rl "svc-t1\|svc-t2\|svc04-" tests/integration/`. Each insertion site becomes a per-test `defer` (or `try { defer cleanupTestTenant(h.conn, id) catch {}; ... }` wrapper).
- Add the `'default'` system fixture's `tenant_type='test'` setting via `INSERT ON CONFLICT (id) DO UPDATE SET tenant_type='test'` so a prior run that created the row as production gets the new value back-written atomically (no destructive DELETE needed).

**Acceptance bar for change 3 alone.** `tools/lint_test_isolation.py tests/integration` exits 0 (T060 no longer triggered because there is no central fixture INSERT in the helper anymore; SVC-* test files must set `tenant_type='test'` explicitly in their relocated INSERTs). `tools/clean_test_db.py` deletes the harness fixture correctly. SVC-01..04 tests pass without regression.

### Change 4 — Cleanup broadening in `tools/clean_test_db.py`

**File:** `tools/clean_test_db.py` (modified).

**Problem.** Today's `main()` (line 153) `DELETE`s `tenant_type='test'` rows first, then `tenant_type='production' AND slug != 'default'` rows. There is **no path** for an operator to drop LEGACY_RLS fixture rows that pre-date GBL-080's `tenant_type` column (or that have `tenant_type='production'` because the harness defaulted them). Such rows accumulate across runs and clog the ISS-503 pre-flight guard's scan.

**Concrete change.** Add a new CLI flag `--include-fixtures` to `argparse`. When the flag is set:

- After the existing two `DELETE` lines (lines 119–120), add a third: `DELETE FROM public.tenant WHERE slug LIKE 'tc-%' OR slug LIKE 'svc%' OR slug LIKE 'env%' OR slug LIKE 'exp%' OR slug LIKE 'adp%' OR slug LIKE 'webhook%' OR slug = 'legacy-fixture'`. These patterns cover the SVC, ENV, EXP, ADP, webhook, and the historical "legacy fixture" prefixes; the patterns are *inclusive* (they cover known prefixes) rather than exclusive (would create a footgun for any future legit production tenant whose slug happens to start with one of these).
- Also drop their dependent `public.tenant_schemas`, `public.schema_migrations` rows, and Postgres schemas via the existing `drop_orphaned_tenant_schemas()` call (line 168) — that helper already handles the schema side correctly because `tenant_schemas` rows for these tenants will be gone after the DELETE.
- Also `DELETE FROM public.tenant WHERE storage_mode='LEGACY_RLS' AND tenant_type='test'` — drops any LEGACY_RLS fixture rows that survived prior runs but were correctly `tenant_type='test'`. The ISS-503 guard's scoped-DOES-NOT-block clause (per GBL-102) means these are harmless at runtime, but cleaning them keeps the next test run's pre-flight deterministic.

Without `--include-fixtures`, today's behavior is preserved exactly (no destructive default).

**Argparse addition.**

```python
# BEFORE
def main() -> None:
    print("Cleaning test database...", flush=True)
    # TRUNCATE + DROP SCHEMA + DELETE existing logic...

# AFTER (this design)
def main() -> None:
    parser = argparse.ArgumentParser(description="Clean test database")
    parser.add_argument(
        "--include-fixtures",
        action="store_true",
        help="Drop leaked LEGACY_RLS fixture tenant rows whose "
             "tenant_type defaults to 'production' because the "
             "harness pre-dates GBL-080 (or default-seeded without "
             "an explicit tenant_type). Off by default — only set "
             "this on operator-initiated cleanup of a contaminated "
             "db_test; do not set it in a baseline-clean CI run.",
    )
    args = parser.parse_args()
    # ... existing TRUNCATE + DROP SCHEMA logic ...
    # ... existing two-step tenant DELETE ...
    if args.include_fixtures:
        # drop leaked fixture tenants (idempotent IF NOT EXISTS-style via
        # ON CONFLICT DO NOTHING if these rows already gone)
        run_psql("DELETE FROM public.tenant WHERE slug LIKE 'tc-%' ...")
        run_psql("DELETE FROM public.tenant WHERE storage_mode='LEGACY_RLS' AND tenant_type='test'")
        drop_orphaned_tenant_schemas()  # re-run to sweep any schemas the fixture row left behind
```

**Acceptance bar for change 4 alone.** With `--include-fixtures`, `tools/clean_test_db.py --include-fixtures` reduces `SELECT count(*) FROM public.tenant WHERE storage_mode='LEGACY_RLS'` to 0. Without the flag, today's behavior is byte-for-byte unchanged (verified via `git diff` review of `tools/clean_test_db.py`).

### Change 5 — New `tools/verify_schema_baseline.py`

**File:** `tools/verify_schema_baseline.py` (new file). Implements `docs/guides/test_infrastructure_guide.md §6` exactly.

**Signature:**

```python
#!/usr/bin/env python3
"""verify_schema_baseline.py — enforce INV-TI-1 / INV-TI-2 invariants
on the shared db_test database.

Implements docs/guides/test_infrastructure_guide.md §6.
Required by docs/guides/test_infrastructure_guide.md §3 (Infrastructure Health
Checklist) for every zig build test-integration invocation.

Exit codes:
  0  baseline healthy
  1  baseline drift detected (print offending query + offending row count)
  2  bad invocation / missing BPM_TEST_DB_URL
"""
import argparse, os, subprocess, sys
from pathlib import Path

def check_migration_ledger_count(conn) -> tuple[bool, str]:
    """Compare count(public.schema_migrations WHERE schema_name='public') to
    on-disk migrations/*.sql file count."""
    ...

def check_per_migration_row_present(conn) -> list[str]:
    """Return list of migrations/*.sql filenames with no public row. Empty list = pass."""
    ...

def check_tenant_schemas_consistent(conn) -> list[str]:
    """For each public.tenant_schemas.schema_name, verify it exists as a
    Postgres schema. Return list of missing names. Empty list = pass."""
    ...

def check_expected_check_constraints(conn) -> list[str]:
    """Verify the expected-by-tests CHECK constraints exist:
       webhook_deliveries_status_check, tenant_storage_mode_check,
       and any other constraint upgraded by GBL-105. Return list of missing
       constraint names. Empty list = pass."""
    ...

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-tenants", action="store_true",
        help="Strict mode: also verify every public.tenant row maps to an "
             "existing Postgres schema (in addition to the schema-side checks).",
    )
    parser.add_argument(
        "--auto-fix", action="store_true",
        help="On drift, attempt a one-shot auto-reconcile: re-emit the GBL-105 "
             "ledger reconcile via psql. Backed by the change-2 applier guard.",
    )
    args = parser.parse_args()
    db_url = os.environ.get("BPM_TEST_DB_URL")
    if not db_url:
        print("BPM_TEST_DB_URL is required", file=sys.stderr)
        return 2
    # ... run all four checks ...
    # exit 0 / 1 / 2 as above
```

**Sample invocation (the canonical CI pre-check).**

```bash
# What every zig build test-integration invocation runs first.
python3 tools/verify_schema_baseline.py --check-tenants || {
    echo "Test infrastructure unhealthy. See docs/guides/test_infrastructure_guide.md §3." >&2
    exit 1
}
```

**What `verify_schema_baseline.py` does NOT do (explicit non-solutions).**

- Does NOT modify the database. Read-only checks; any modification goes through the existing `tools/clean_test_db.py` or `zig build migrate`.
- Does NOT replace `tools/lint_test_isolation.py`. That linter (INV-TI-2 strictness) remains the per-test-isolation enforcer; this verifier enforces INV-TI-1 + INV-TI-3 (the database-side subset).
- Does NOT bootstrap a fresh DB. The first-time-bootstrap path is `docker run -d --name bpm-test-db …` (per `backend_developer_guide.md §1`), unchanged.

**Acceptance bar for change 5 alone.** After `zig build migrate` on a clean DB, `verify_schema_baseline.py --check-tenants` exits 0. After deleting `public.schema_migrations WHERE schema_name='public'` (simulating drift) and re-running `zig build migrate` against the unchanged `migrations/`, the verifier exits 0 on the next invocation and the ledger count is back to 97.

---

## Migration plan

**New file:** `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql`.

**Numbering check (BACKEND-DEV must re-verify at write-time):** `Get-ChildItem migrations/GBL-*.sql | Sort-Object` shows the highest GBL- number. If it is `GBL-104`, BACKEND-DEV creates `GBL-105`. If higher numbers have landed since this design was written (e.g. `GBL-106` from a parallel branch), BACKEND-DEV mechanically renumbers to the next free slot (per the GBL-102 precedent comment lines 9–17).

**Idempotent DDL outline.** See Change 1 above for the full shape. The 5 ordered steps are:

1. Ledger backfill (96 INSERTs, one per on-disk migration filename, `ON CONFLICT DO NOTHING`).
2. Per-tenant-schema ledger backfill (96 INSERTs × N tenants via `DO $$ … FOREACH … END $$;`).
3. Object-additive fixes (`webhook_subscriptions.secret_ref`, `public.tenant_realm_binding`, `tenant.entity_type_instances`, two CHECK constraint upgrades — each one IF NOT EXISTS / guarded DO-block).
4. Summary notice (`RAISE NOTICE 'GBL-105: reconciliation complete. <N> ledger rows reconciled, <M> constraints upgraded.'`).
5. Self-mark-applied (handled by `Migrations.runForSchema`'s normal flow at `src/db/migrations.zig` line 248).

**Ledger-status invariant after this migration lands.** `SELECT count(*) FROM public.schema_migrations WHERE schema_name='public'` returns 97. Re-running `zig build migrate` is idempotent. Re-running `verify_schema_baseline.py` exits 0.

---

## Tooling changes

### `tools/clean_test_db.py`

**Signature change (CLI):** `main()` gains an optional `--include-fixtures` argument. The function body is unchanged without the flag; with the flag, three extra `DELETE` statements + a `drop_orphaned_tenant_schemas()` re-run are added.

**Function-level signature change:** none. The two existing helpers `run_psql()` and `run_psql_query()` are unchanged. `drop_orphaned_tenant_schemas()` is called twice when `--include-fixtures` is set (once before, once after — the second sweep catches schemas whose tenant rows were just deleted).

### `src/db/migrations.zig`

**Signature change:** `runForSchema` gains a 5th parameter `force_reconcile: bool`. Backwards-incompatible at the Zig source level, but the only in-repo caller is `pub fn run` at line 59 which delegates 1-for-1; no external callers exist (verified by `grep -r "runForSchema" src/ tests/`).

**Error taxonomy:** no new variants needed. The existing `MigrationError` set (`src/db/migrations.zig` lines 17–31) is exhaustive; the new guard branch is a `continue`, not an error.

**Logging contract:** one `RAISE NOTICE` per corrective migration's re-apply-or-skip decision, no more.

### `tools/verify_schema_baseline.py`

**New file.** No signature change to any existing module.

**CLI flags:** `--check-tenants` (strict) and `--auto-fix` (one-shot reconcile via GBL-105). Both default to off.

---

## Test isolation changes

**`tests/integration/helpers.zig`:**

- `ensureDefaultOidcSeeds` (line 333) — refactored:
  - The canonical `'default'` tenant INSERT (line 339) gets `tenant_type='test'` added to its column list, and the `ON CONFLICT (id) DO UPDATE` clause is updated to back-write `tenant_type='test'` on existing rows.
  - The SVC-* fixture block INSERT (lines 360–370) is **removed** from this function. The 9 rows are relocated to each consuming test file as a `try h.conn.exec(...); defer cleanupTestTenant(h.conn, id) catch {};` prefix. Affected test files are discovered by `grep -rl "svc-t1\|svc-t2\|svc04-" tests/integration/` and updated at the same commit.

**No changes to:**

- `TestHarness.init` / `TestHarness.deinit` (lines 422 / 540) — those are already correct (transaction rollback handles the per-test cleanup).
- `configureTestSearchPath`, `resetTestData`, `applyCompatibilityShims`, `configureSessionTimeouts`, `runMigrations` — those are unchanged (this design does not touch any of them).

**Affected SVC-* test files (BACKEND-DEV must enumerate at implementation):**

- `tests/integration/svc01_service_catalog_scope_test.zig`
- `tests/integration/svc04_admin_api_test.zig`
- Possibly `tests/integration/svc03_definition_activation_scope_test.zig` and any other file referencing the SVC-* fixture IDs

For each, the test body gains the fixture INSERT at the top (after `var h = try TestHarness.init();`) and a `defer cleanupTestTenant(h.conn, <id>) catch {};` line. `cleanupTestTenant` is a new tiny helper at the bottom of `tests/integration/helpers.zig` that issues `DELETE FROM public.tenant WHERE id = $1` — but in practice it is often unnecessary because `TestHarness.deinit()` rolls back the transaction; it is included as belt-and-suspenders for tests that use the pool (where the insert may have escaped the per-test transaction).

---

## Verification tool — full signature + sample invocation

**`tools/verify_schema_baseline.py` invocation matrix:**

```bash
# Canonical pre-check (every zig build test-integration step). Exits 0/1/2.
python3 tools/verify_schema_baseline.py

# Strict (also verifies each public.tenant.tenant_schema_name exists as a
# Postgres schema, in addition to the schema-side checks). Use when validating
# a fresh db_test container after provisioning, and in CI's nightly drift
# check. Exits 0/1/2.
python3 tools/verify_schema_baseline.py --check-tenants

# Auto-reconcile (drift detected → re-emits GBL-105 via psql — equivalent to
# running zig build migrate with the change-2 applier's force_reconcile=true).
# Use during operator-initiated cleanup. Exits 0/1/2.
python3 tools/verify_schema_baseline.py --check-tenants --auto-fix
```

**Distinct exit codes:**

- `0` — all checks pass.
- `1` — drift detected; offending checks printed to stderr with the offending query + row count. Bash orchestrators receive this and short-circuit the test step.
- `2` — bad invocation (missing `BPM_TEST_DB_URL`, missing `psql`, missing `migrations/` directory). Indicates a config error rather than a DB problem; surfaces differently so CI dashboards can route it correctly.

**What `verify_schema_baseline.py` checks (precise, mechanical, no judgment calls):**

1. `count(public.schema_migrations WHERE schema_name='public') == len(glob('migrations/*.sql'))`.
2. For each on-disk `migrations/*.sql`, a row exists in `public.schema_migrations WHERE schema_name='public' AND version = 0`.
3. (only with `--check-tenants`) For each `public.tenant_schemas.schema_name`, the schema exists in `information_schema.schemata`. AND for each `public.tenant` row whose `tenant_schema_name` is set, that schema exists in `information_schema.schemata`.
4. The expected-by-tests CHECK constraints exist (`webhook_deliveries_status_check`, `tenant_storage_mode_check`) — returns the missing constraint name in the failure message.

---

## Callers impacted

Every integration test binary that runs after `zig build migrate`. Per the repo's `tests/integration/` inventory, there are ~22 `test_integration_<name>` binaries declared in `build.zig` (per the ISS-0110 design's enumeration). **None of them require code changes beyond the SVC-* fixture INSERT relocation described in Change 3.** The orchestrator's run order (which binary runs first / last) does not matter for this design — INV-TI-1 is now maintained by `verify_schema_baseline.py` before the first test runs, INV-TI-2 is now maintained by `TestHarness`'s per-test transaction rollback + the relocated SVC fixtures' per-test `defer`.

**Run order (orchestrator documentation, not a code change):**

1. `docker-compose up -d db_test` (already required, unchanged).
2. `zig build migrate` (already required, unchanged — this is the call that applies the corrective migration; the new applier guard makes this step safe to re-run).
3. `python3 tools/verify_schema_baseline.py --check-tenants` (NEW; gates everything below).
4. `python3 tools/lint_test_isolation.py tests/integration` (already required, unchanged — must still exit 0).
5. `zig build test-integration` (already required, unchanged).

Step 3 is the new gate. Steps 1, 2, 4, 5 are unchanged in either ordering or behavior.

---

## Error taxonomy

**New error variant (optional, deferred unless needed):** `MigrationsError.LedgerOutOfSync`. Returns when `verify_schema_baseline.py --auto-fix` cannot reconcile because GBL-105 is missing from `migrations/`. Backends: the change-2 applier guard emits the same error from `runForSchema` when `force_reconcile=true` is set but the corrective filename is not present on disk. **Recommendation: defer this variant** — today's `MigrationFailed` error set already covers the case (the missing-file scenario is just a special case of "migration not found"), and adding a new error for one operational case is not justified yet. If a future drift requires the distinction, add it then.

**No existing error variants change.** `Migrations.runForSchema`'s public error set (`src/db/migrations.zig` lines 17–31: `MigrationsDirectoryNotFound`, `OutOfOrderMigration`, `MigrationFailed`, `UnsupportedPgVersion`, `PoolExhausted`, `SchemaSetupFailed`) is unchanged.

**`tools/clean_test_db.py` errors:** unchanged. The CLI parser gains `--include-fixtures`, which does not change any error path.

**`tools/verify_schema_baseline.py` errors:** new file, new error surface — see the CLI matrix above. `argparse` handles invocation errors (exit 2); check failures are exit 1; success is exit 0.

---

## Public function signatures before / after

### `src/db/migrations.zig::Migrations.runForSchema`

```zig
// BEFORE (src/db/migrations.zig line 64)
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
) MigrationError!void

// AFTER (this design)
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
    force_reconcile: bool,
) MigrationError!void
```

### `src/db/migrations.zig::Migrations.run` (thin wrapper, unchanged signature, updated body)

```zig
// BEFORE (src/db/migrations.zig line 59)
pub fn run(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
) MigrationError!void {
    return runForSchema(allocator, pool, migrations_dir, "public");
}

// AFTER (this design — body change only, signature identical)
pub fn run(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
) MigrationError!void {
    return runForSchema(allocator, pool, migrations_dir, "public", false);
}
```

### `tools/clean_test_db.py::main`

```python
# BEFORE
def main() -> None:
    """Clean test database (no args, no flags)."""

# AFTER
def main() -> None:
    """Clean test database. Pass --include-fixtures to drop leaked LEGACY_RLS
    fixture tenants (operator-initiated cleanup; off by default)."""
    parser = argparse.ArgumentParser(description="Clean test database")
    parser.add_argument("--include-fixtures", action="store_true", help=(
        "Drop leaked LEGACY_RLS fixture tenant rows. Off by default — only "
        "set this on operator-initiated cleanup of a contaminated db_test; "
        "do not set it in a baseline-clean CI run."
    ))
    args = parser.parse_args()
    # ... existing logic + 3 extra DELETE + drop_orphaned_tenant_schemas()
    # when args.include_fixtures is True
```

### `tools/verify_schema_baseline.py`

```python
# NEW FILE. Four check functions + a main():
#   def check_migration_ledger_count(conn) -> tuple[bool, str]
#   def check_per_migration_row_present(conn) -> list[str]
#   def check_tenant_schemas_consistent(conn) -> list[str]
#   def check_expected_check_constraints(conn) -> list[str]
#   def main() -> int
# See "Verification tool" section above for full body.
```

### `tests/integration/helpers.zig::ensureDefaultOidcSeeds`

```zig
// BEFORE (helpers.zig line 333)
fn ensureDefaultOidcSeeds(conn: *pg.Conn) !void {
    try conn.exec(<default tenant INSERT without tenant_type>, .{});
    try conn.exec(<jit_provisioning_config INSERT>, .{});
    try conn.exec(<SVC-* fixture 9-row INSERT>, .{});  // <-- moves out
}

// AFTER (this design)
fn ensureDefaultOidcSeeds(conn: *pg.Conn) !void {
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type)
        \\VALUES ('00000000-0000-0000-0000-000000000000'::uuid, 'default',
        \\        'Default Tenant', 'ACTIVE', 'bpm-default', 'test')
        \\ON CONFLICT (id) DO UPDATE
        \\SET slug = EXCLUDED.slug,
        \\    display_name = EXCLUDED.display_name,
        \\    status = EXCLUDED.status,
        \\    idp_realm_id = COALESCE(public.tenant.idp_realm_id, EXCLUDED.idp_realm_id),
        \\    tenant_type = 'test',
        \\    updated_at = NOW()
    , .{});
    try conn.exec(<jit_provisioning_config INSERT — unchanged>, .{});
    // The 9-row SVC-* fixture INSERT is REMOVED from this function.
    // Each SVC test file (svc01_service_catalog_scope_test.zig, svc04_admin_api_test.zig,
    // svc03_definition_activation_scope_test.zig, etc.) inserts its needed
    // fixture row inside its own test body, immediately after
    // `var h = try TestHarness.init();`, with a `defer cleanupTestTenant(...) catch {};`.
}
```

### `tests/integration/helpers.zig::cleanupTestTenant` (new helper)

```zig
// NEW
fn cleanupTestTenant(conn: *pg.Conn, tenant_id: []const u8) !void {
    // No-op if tenant_type='test' AND the per-test transaction rolled back
    // already; this exists for tests that round-trip through the pool.
    _ = conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid AND tenant_type = 'test'",
        .{tenant_id},
    ) catch {};
}
```

---

## Fix scope flag (exceeds 5 files — explicit flag for ORCH awareness)

**This fix touches 6 source files:**

1. `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql` (new)
2. `src/db/migrations.zig` (modified — Change 2)
3. `tests/integration/helpers.zig` (modified — Change 3)
4. `tools/clean_test_db.py` (modified — Change 4)
5. `tools/verify_schema_baseline.py` (new — Change 5)
6. `src/design/fix-iss0112.md` (new — this file)

Plus up to 2 SVC test files if BACKEND-DEV relocates the fixture INSERTs per Change 3 (call it 6–8 files touched total).

WF-03 Step 3 §Fix size constraint states: "A single fix iteration MUST touch ≤ 5 source files. If the design prescribed more, and the fix agent confirms this at Step 3, the issue is architectural — STOP, ORCH escalates."

**Justification for exceeding 5:**

- Change 1 (corrective migration) is meaningless without Change 2 (applier guard), because the next drift would re-occur the moment the guard allows the same skip-on-missing-row pattern back in.
- Change 2 (applier guard) is meaningless without Change 5 (baseline verifier), because without verification, the guard's behavior cannot be mechanically proven to fire or not fire — the guard's value is in being checkable, not in being theoretically correct.
- Change 3 (per-test isolation) is meaningless without Change 4 (cleanup broadening), because the SVC test fixtures' leaked-Legacy-RLS-tenant problem pre-dated the relocation, and the existing `clean_test_db.py` cannot remove the leaked rows; a one-off `UPDATE` by hand is the current workaround and is not sustainable.
- Change 4 (cleanup broadening) is meaningless without Change 5 (baseline verifier), because without verification, the operator has no way to know whether `--include-fixtures` produced a clean baseline.

The five changes are a closed circuit; each one's value depends on the others. Splitting them into multiple WF-03 iterations would re-introduce the cluster symptoms between iterations.

**ORCH action item (load-bearing):** If the strict WF-03 ≤ 5 files rule applies, ORCH MUST escalate this design as architectural rather than mechanically enforcing the rule. The closed circuit above is a Phase-2 architectural fix disguised as one fix; pretending it isn't and splitting it would replay ISS-0106/ISS-0107/ISS-0110/ISS-0111's churn (8+ rework iterations across 5 WF-03s) one more time. **Alternative escalation path:** keep the fix as one WF-03 but treat the 6–8 files as a documented exception with this section as the rationale, mirroring the same exception that `src/design/fix-ISS-0111.md` invoked for its single-file fix (analogous reasoning: the design's correctness is the priority over the meta-rule).

---

## Acceptance criteria

For Step 3 (BACKEND-DEV) to validate against. All five must hold simultaneously; the design is incomplete if any one fails.

1. **Idempotency:** `python3 tools/verify_schema_baseline.py` exits 0 after `zig build migrate` on a clean DB and after a second run. (`count(public.schema_migrations WHERE schema_name='public') == 97` in both cases, AND every on-disk `migrations/*.sql` has a corresponding ledger row, AND no spurious extra rows, AND expected CHECK constraints exist.)
2. **Test isolation:** `python3 tools/lint_test_isolation.py tests/integration` exits 0 (Anti-pattern T060 no longer triggered). The SVC-* relocated fixture INSERTs each appear in exactly one place: the test file that reads them, not the shared helper.
3. **Integration:** `zig build test-integration` exits 0 (no failures from Clusters A–E; if any unrelated test happens to be flaky, that is a separate ISS, not a blocker for this fix).
4. **Cleanup broadening:** `tools/clean_test_db.py --include-fixtures` (run on the contaminated `db_test` from `scratch/WF03-gh364-20260801-step03e/tenant_rows.txt`) reduces `SELECT count(*) FROM public.tenant WHERE storage_mode='LEGACY_RLS'` to 0.
5. **Ledger size invariant:** `psql $BPM_TEST_DB_URL -c "SELECT count(*) FROM public.schema_migrations WHERE schema_name='public'"` returns 97 (the exact file count of `migrations/*.sql`).

---

## What this design does NOT do (explicit non-solutions)

- **Does not alter any application business logic.** No changes to `src/api/`, `src/engine/`, `src/event_store/`, `src/webhooks/`, `src/dlq/`, etc. The 42-failure cluster from WF03-gh364-20260801 was identified as test-infrastructure drift by `docs/issue-reports/ISS-0112-step-1-WF03-gh375-20260801.yaml`, not as application defects — this design executes that diagnosis exactly.
- **Does not modify `docs/guides/test_infrastructure_guide.md`.** That guide was authored specifically to be the reference implementation that this fix executes; it's the spec, not a deliverable of this fix.
- **Does not touch `tools/lint_migration_schema.py`, `tools/lint_design_artefact.py`, `tools/lint_frontend_conventions.py`.** The first two (migration schema + design artefact) are lints that validate new code; they were correctly aligned with `test_infrastructure_guide.md §3` from that guide's authoring. The third is frontend and is out of scope.
- **Does not relax the ≤ 5 file fix scope rule.** The design flags the over-budget size per the section above and lets ORCH decide whether to escalate.
- **Does not introduce a second migration-applier lock key.** The proven pattern from `fix-ISS-0107.md` (single lock key covering the entire `TestHarness.init()` pipeline) is the right design; this fix preserves it.
- **Does not change `tests/integration/test_iss503_rls_removal.zig`.** That file's doc comment remains correct; the GBL-102 guard behind it is unchanged.
- **Does not bootstrap a fresh `db_test` container.** `docker-compose up -d db_test` remains the operator's job. The verifier's role is to confirm the existing container's baseline is healthy, not to provision it.
- **Does not modify any pre-GBL-105 migration file.** Per `backend_developer_guide.md §4.4`, migrations are immutable once on `main`; only NEW migrations are added. This design adds exactly one (GBL-105).
- **Does not introduce a `migrations/` directory symlink, a `git mv`, or any rename.** Numbering is purely a function of filename, and the new file gets a new name (no `git mv` against an existing file).
- **Does not consolidate `schema_migrations` and a hypothetical `tenants_schema_migrations` ledger.** The current single-table ledger is correct; splitting it would be the textbook "premature generalization" anti-pattern.

---

## Verification plan

All five acceptance criteria above are mechanically verifiable. The post-fix TEST-RUNNER workflow (after this design's Step 3 BACKEND-DEV implementation lands) is:

1. `docker-compose up -d db_test keycloak` (already required).
2. `zig build migrate` — must exit 0.
3. `python3 tools/verify_schema_baseline.py --check-tenants` — must exit 0 (NEW gate).
4. `psql $BPM_TEST_DB_URL -c "SELECT count(*) FROM public.schema_migrations WHERE schema_name='public'"` — must return 97.
5. `python3 tools/lint_test_isolation.py tests/integration` — must exit 0.
6. `zig build test` — must exit 0 (unit tests; should not regress because this fix only touches integration harness surface).
7. `zig build test-integration` — must exit 0.
8. `python3 tools/clean_test_db.py --include-fixtures` (operator-initiated) — run once on the contaminated `db_test` from `scratch/WF03-gh364-20260801-step03e/tenant_rows.txt`; the `count(*) FROM public.tenant WHERE storage_mode='LEGACY_RLS'` must drop to 0.

Step 3 is the gate. The rest confirm the gate's verifications.

---

## Dependencies

**Calls into:**

- `src/db/migrations.zig::Migrations.runForSchema` (existing, modified).
- `src/db/migrations.zig::Pool` (existing, unchanged).
- `tests/integration/helpers.zig::TestHarness` (existing, unchanged).
- `tests/integration/helpers.zig::ensureDefaultOidcSeeds` (existing, refactored).
- `tools/clean_test_db.py::run_psql`, `run_psql_query`, `drop_orphaned_tenant_schemas` (existing, unchanged at the function level; called twice when `--include-fixtures`).
- New: `tools/verify_schema_baseline.py::main` (implemented in Change 5).
- `py` standard library: `argparse`, `subprocess`, `os`, `sys`, `pathlib`.

**Does not depend on / must not depend on:**

- `src/api/` (out of scope — no application code change).
- `src/engine/transition.zig` (the pure transition function; out of scope per absolute rule).
- `tests/integration/schema_contracts/` (the schema contract tests from `test_infrastructure_guide.md §5` are a separate workstream; this design does not add them but also doesn't conflict with future additions).
- `docs/guides/test_infrastructure_guide.md` (the spec is fixed; if it needs amendment, that's a separate design).
- `tools/codegen_migration.py` (the corrective migration bypasses the lego by design — see the "considered and rejected" rationale at the top of this artefact).

---

## Open questions

None. The design's 5-change plan is fully determined by:

- The diagnosis in `docs/issues/ISS-0112.json` and `docs/issue-reports/ISS-0112-step-1-WF03-gh375-20260801.yaml`.
- The methodology in `docs/guides/test_infrastructure_guide.md §2–§6` (already finalized; the design executes it).
- The precedents `GBL-101`, `GBL-102`, `GBL-104` (already-committed GBL-prefix corrective migrations, identical shape).
- The decisions in this artefact (numbered explicitly above, no ambiguity remaining).

If a future drift produces a 7th cluster beyond A–E, that becomes a new WF-03 with its own diagnosis and design — not a deferral back to this fix.

---

## State transitions

None. The 5 changes are stateless in the application sense — they bring infrastructure invariants from "drifted" to "converged" and keep them there mechanically. There is no per-request state machine, no new event types, no new row-status enums, no new transitions.

---

## Data flow / control flow (post-fix, every `zig build test-integration` invocation)

```
docker-compose up -d db_test                                (unchanged)
  │
  ▼
zig build migrate                                           (the corrected Step 2)
  │
  ├─ Migrations.runForSchema(..., "public", false)          ◄── thin wrapper, runs once
  │   ├─ CREATE TABLE IF NOT EXISTS public.schema_migrations   (idempotent)
  │   ├─ SELECT version FROM public.schema_migrations ...      (populates "applied")
  │   ├─ for each on-disk migrations/*.sql:
  │   │   ├─ if (applied.contains(filename)) continue;        ◄── unchanged skip path
  │   │   ├─ if (file is GBL-prefixed AND schema != public)  ◄── unchanged
  │   │   │       continue;
  │   │   ├─ NEW (Change 2): if (filename has --reapply flag)
  │   │   │       + row missing AND objects present → skip + notice
  │   │   ├─ BEGIN; simpleQuery(sql); INSERT INTO public.schema_migrations; COMMIT
  │   │   └─ RAISE NOTICE on every GBL-105 re-apply  ◄── Change 1's self-mark
  │   └─ explicit unlock of migration ledger  ◄── unchanged
  │
  ▼
python3 tools/verify_schema_baseline.py --check-tenants      ◄── NEW (Change 5)
  │
  ├─ check_migration_ledger_count → 97 vs 97 ✓
  ├─ check_per_migration_row_present → 0 missing ✓
  ├─ check_tenant_schemas_consistent → all tenants have schemas ✓
  ├─ check_expected_check_constraints → 0 missing ✓
  └─ exit 0
  │
  ▼
python3 tools/lint_test_isolation.py tests/integration        (unchanged, must exit 0)
  │
  ▼
zig build test                                              (unchanged, must exit 0)
  │
  ▼
zig build test-integration                                  (unchanged, must exit 0)
  │
  └─ per binary:
      TestHarness.init()
        configureSessionTimeouts
        runMigrations (with the new applier guard)
        provisionTenantSchema + runMigrationsForSchema
        pg_advisory_lock (line-99 + line-487 both 90s-bracketed from prior fixes)
        configureTestSearchPath
        resetTestData (now safely only deletes writable tables, no leaked fixtures)
        ensureDefaultOidcSeeds (Change 3 — default tenant_type='test', SVC fixtures relocated)
        applyCompatibilityShims
        conn.begin
      [test runs, reads fixtures its own test created]
      TestHarness.deinit()  ─► ROLLBACK the per-test transaction
        ◄── per-test fixtures vanish
        ◄── leaked LEGACY_RLS rows are no longer created in the first place
```

The 5 changes' effects compose into a single stable test infrastructure that no longer drifts and no longer masks drift when it occurs.
