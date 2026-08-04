# iss-0125-fk-cascade — Fix design artefact

> **WF-03 Step 2 fix design for ISS-0125 / GitHub tvolodi/R-Co#391.**
> This artefact is prose-only (Type E, cross-cutting). It contains the exact DDL
> stub for `migrations/GBL-106_instance_definition_snapshots_cascade.sql`, the
> concrete Zig-edit instructions for `tests/integration/helpers.zig`, the
> per-test hardening plan for the four affected test files, the schema contract
> test outline, and the rollout / rollback plan. **No implementation code is
> produced here** — only what BACKEND-DEV needs to implement and TEST-DESIGNER
> needs to verify.

---

## 1. Context

- **Issue:** `ISS-0125` — `process_definitions DELETE` blocked by orphan FK
  references in `instance_definition_snapshots`. Recorded as MAJOR
  (code-defect / cleanup-cascade-order) in `docs/issues/ISS-0125.json`.
- **GitHub:** tvolodi/R-Co#391 — surfaced from `zig build test-integration`
  Cluster N (43 C23503 diagnostics in
  `scratch/WF03-gh375-20260801/test-runner-step5c/zig_test_integration.log`).
  Surfacing test cases (per ISS-0125.notes):
  `TC-ISS-202-02/05`, `TC-ISS-203-03/04/05`, `TC-ISS-601-01..09`,
  `TC-EE-08-04`, `TC-EE-10-04/05/06`, `TC-EXP-202-01/02/03`, `TC-ES-03-01`.
- **Root-cause report:** `docs/issue-reports/ISS-0125-root-cause.md` (this run).
  Conclusion: `migrations/004_definitions.sql:50-57` declares
  `definition_id UUID NOT NULL REFERENCES process_definitions(id)` without
  `ON DELETE CASCADE`, so PostgreSQL applies `NO ACTION` and rejects a parent
  DELETE while any child snapshot row remains. The shared harness
  `resetTestData()` is already correctly ordered
  (`tests/integration/helpers.zig:310-325` — snapshots before
  `process_definitions`), so the fragile path is the **bespoke** per-test
  cleanup helpers in `iss202_merge_atomicity_test.zig:130-152` and
  `iss203_idempotency_keys_test.zig:130-149`: child and parent cleanup are
  separate best-effort helpers that swallow every SQL error, allowing an
  incomplete child delete to be followed by `DELETE FROM process_definitions`
  and emit C23503. `GBL-085_state_snapshots.sql` is unrelated.
- **Strategy (C from the root-cause report):** *both* schema-level
  enforcement (`ON DELETE CASCADE`) *and* cleanup-order hardening
  (child-before-parent, no swallowing of child-delete errors before parent
  DELETE). Cascade alone leaves contamination diagnostics weak; cleanup
  changes alone leave every future `process_definitions` DELETE dependent on
  manual ordering.

---

## 2. Module purpose

The "module" this artefact describes is the **invariant**: a parent
`process_definitions` row's deletion must never be blocked by a forgotten
child row in `instance_definition_snapshots`, and the test suite must never
silently continue past a failed child cleanup into a parent DELETE. The
design enforces the invariant in two layers:

1. **Database boundary (production-correctness):** an
   `ON DELETE CASCADE` foreign key makes the dependency explicit so any
   production caller that deletes a definition automatically removes its
   snapshots. This is the only safe semantics for this relationship:
   the snapshot is an immutable copy of the graph frozen at instance
   start, and the parent row's identity has no meaning without its
   children once the parent is gone.
2. **Test boundary (cleanup-correctness):** the shared harness
   `resetTestData()` retains its existing child-before-parent ordering,
   and the four bespoke test-cleanup helpers stop swallowing SQL errors
   before attempting a parent DELETE so a failed child surfaces as a
   visible failure rather than a downstream C23503.

---

## 3. Public interface

### 3.1 Database surface

- **Forward-only DDL** in `migrations/GBL-106_instance_definition_snapshots_cascade.sql`
  replacing the existing constraint on
  `public.instance_definition_snapshots.definition_id` with an equivalent
  FK that uses `ON DELETE CASCADE`. Constraint name is preserved
  (`instance_definition_snapshots_definition_id_fkey`) so
  `information_schema.table_constraints` lookups in any pre-existing test
  or external tool continue to find the same name.
- **Migration runner integration:** the file is GBL-prefixed, so
  `Migrations.runForSchema()` (src/db/migrations.zig) skips it for any
  non-public schema. The header `-- reapply_on_drift: true` makes the
  applier guard skip if the ledger row is missing but downstream rows
  exist. This is the same convention used by `GBL-105`. The DDL itself
  uses `DROP CONSTRAINT IF EXISTS` for idempotency.

### 3.2 Zig surface

- **`tests/integration/helpers.zig` — `resetTestData()`:** unchanged
  externally. Internally the existing `truncateTableBestEffort(...)` calls
  for `instance_definition_snapshots` and `process_definitions` already
  pass through `TRUNCATE ... RESTART IDENTITY CASCADE`, which cascades
  through the dependent FK. **No change to public signature or call
  order.** A new doc-comment block above `resetTestData()` documents the
  invariant for future maintainers and references ISS-0125.
- **No new error sets** anywhere in the production codebase. The fix is
  confined to a DDL file and to the shared test helper plus four test files.
- **No new public functions.** The four affected test files keep their
  existing `cleanupInstance` / `cleanupByName` / `cleanupSnapshots`
  helpers' signatures; only their internal error-handling changes.

---

## 4. Database change — `migrations/GBL-106_instance_definition_snapshots_cascade.sql`

### 4.1 Exact file header (BACKEND-DEV writes verbatim)

```sql
-- GBL-106: ISS-0125 — ON DELETE CASCADE for instance_definition_snapshots.definition_id
--
-- Root cause: migrations/004_definitions.sql:50-57 declared
--   definition_id UUID NOT NULL REFERENCES process_definitions(id)
-- with the default NO ACTION referential action. Any process_definitions
-- DELETE was therefore blocked while any referencing
-- instance_definition_snapshots row remained. The shared test harness
-- (tests/integration/helpers.zig resetTestData) was correctly ordered,
-- but bespoke per-test cleanup helpers that swallow SQL errors could
-- silently proceed to DELETE FROM process_definitions after a failed
-- child delete, producing C23503. See docs/issue-reports/ISS-0125-root-cause.md.
--
-- Fix: replace the FK with an equivalent FK that uses ON DELETE CASCADE.
-- The snapshot is an immutable copy of the graph at instance start, so
-- the parent row's identity has no meaning without its children once the
-- parent is gone. Keeping the FK name preserves information_schema
-- lookups in pre-existing tools and tests.
--
-- Wrap in BEGIN/COMMIT (NOT a DO block) so the schema_migrations ledger
-- insert inside Migrations.runForSchema() can record the file atomically
-- with the DDL — DO blocks do not commit to the outer transaction the
-- way simpleQuery() expects when the applier inserts the ledger row.
--
-- GBL-prefix: per the GBL-104 convention, GBL-prefixed files operate on
-- the public schema only. Migrations.runForSchema() blanket-skips these
-- files for schema_name != 'public'. tenant_default and other per-tenant
-- schemas therefore do NOT receive this constraint change. That is
-- correct: instance_definition_snapshots lives in public (see
-- migrations/004_definitions.sql:50 and migrations/GBL-085_state_snapshots.sql
-- which is also public-only); per-tenant schemas have no
-- instance_definition_snapshots table and no FK to alter.
--
-- reapply_on_drift: true
```

### 4.2 Exact DDL body (BACKEND-DEV writes verbatim)

```sql
BEGIN;

ALTER TABLE ONLY public.instance_definition_snapshots
    DROP CONSTRAINT IF EXISTS instance_definition_snapshots_definition_id_fkey;

ALTER TABLE ONLY public.instance_definition_snapshots
    ADD CONSTRAINT instance_definition_snapshots_definition_id_fkey
    FOREIGN KEY (definition_id)
    REFERENCES public.process_definitions(id)
    ON DELETE CASCADE;

COMMIT;
```

### 4.3 Why `ALTER TABLE ONLY` (not bare `ALTER TABLE`)

`ONLY` prevents the recursion rule from descending to descendant tables in
the inheritance hierarchy. The table is not currently inherited from, but
`ONLY` is the safe form for `ALTER CONSTRAINT` operations and matches the
implicit default when the table is created via `CREATE TABLE ONLY ...` in
the original `004_definitions.sql`. Belt-and-suspenders against future
partitioning refactors.

### 4.4 Why `DROP CONSTRAINT IF EXISTS` (not plain `DROP CONSTRAINT`)

Idempotency. The migration is re-applicable on a database where the
constraint was already replaced (e.g. when the applier guard's
`force_reconcile=true` runs). Combined with
`-- reapply_on_drift: true`, this lets the same file be re-applied without
failing on a stale state.

### 4.5 GBL-prefix skip rationale (explicitly documented)

`src/db/migrations.zig:166-176` shows that GBL-prefixed files are
blanket-skipped when `schema_name != "public"`. For this migration this
is correct because:

- `instance_definition_snapshots` lives in `public` (see
  `migrations/004_definitions.sql:50` — unqualified, but resolved through
  the harness's `SET search_path TO public` default during
  migration-time, and later resolved through `tenant_default,public`
  search path; the table's physical home is `public`).
- `migrations/GBL-085_state_snapshots.sql` (the closest sibling) is
  also public-only (`CREATE TABLE IF NOT EXISTS public.instance_state_snapshots`),
  and its comment explicitly says *"GBL-prefix: operates on public schema"*.
- No per-tenant schema ever carries `instance_definition_snapshots`,
  so there is no FK to alter in those schemas. Documenting this here so
  a future maintainer does not "fix" the blanket-skip and create a
  silent miss for non-public schemas.

### 4.6 Migration runner interaction

- The applier reads the first 1 KiB of the file
  (`src/db/migrations.zig:179-191`) and detects
  `-- reapply_on_drift: true`. When set, it skips the file on a clean
  re-run if any later migration has already been applied for the schema
  (the heuristic that the corrective's effects are already present).
  This is correct here because the DDL is fully idempotent (DROP IF
  EXISTS + ADD by name).
- The applier uses `conn.simpleQuery(sql_bytes)` for multi-statement DDL
  (`src/db/migrations.zig:240`) and wraps the whole file in its own
  outer `BEGIN`/`COMMIT`. The `BEGIN`/`COMMIT` inside this file therefore
  acts as **nested savepoints** in the same outer transaction. PostgreSQL
  accepts nested `BEGIN`/`COMMIT` and treats the inner ones as
  no-ops-with-warning-free behaviour inside an already-open transaction
  (they emit `WARNING: there is already a transaction in progress`,
  which the applier does not propagate). BACKEND-DEV validates
  `zig build migrate` exits 0 on a fresh `bpm_test` database — see §8
  Acceptance Criteria, AC-3.

---

## 5. Test-helpers change — `tests/integration/helpers.zig`

### 5.1 Existing state (no public-signature change)

`resetTestData()` at lines ~310-325 already truncates
`instance_definition_snapshots` *before* `process_definitions`, and uses
`TRUNCATE TABLE ... RESTART IDENTITY CASCADE`. CASCADE on TRUNCATE means
the order is effectively documentation-only; the FK is satisfied either
way. **BACKEND-DEV does not change the function body.**

### 5.2 Doc-comment addition (the only change)

Above the existing `fn resetTestData(conn: *pg.Conn) !void { ... }`
declaration, BACKEND-DEV inserts a documentation block:

```zig
// ISS-0125 / GitHub #391: resetTestData() intentionally truncates
// instance_definition_snapshots before process_definitions even though
// the FK uses ON DELETE CASCADE (see GBL-106). The order is preserved
// as defense in depth — TRUNCATE ... CASCADE is independent of the FK's
// referential action, but documenting the order makes the invariant
// visible and prevents future "harmless" reorderings from masking a
// regression. Per-test cleanup helpers in
// iss202_merge_atomicity_test.zig, iss203_idempotency_keys_test.zig,
// and iss601_state_snapshots_test.zig now follow the same
// child-before-parent order AND propagate (do not swallow) any SQL
// error from a child delete before attempting the parent delete.
```

### 5.3 Per-test hardening — `tests/integration/iss202_merge_atomicity_test.zig`

The current `cleanupInstance` (lines 130-152) and `cleanupByName`
(lines ~139-149) helpers each `catch {}` every error independently. Fix:

1. **Restructure as a single `cleanupAll(pool, instance_id_hex, name)` helper**
   that issues all DELETE statements in FK order inside one block, and
   returns the first SQL error to the caller (using a sentinel error set
   or `error.CleanupFailed`). The caller (`defer`) then propagates the
   error to the test framework.
2. **No more `catch {}` between child and parent.** If
   `DELETE FROM instance_definition_snapshots` fails, the parent
   `DELETE FROM process_definitions` MUST NOT run. The combined helper
   returns the first error and the test reports it.
3. **Delete in this order:**
   `instance_definition_snapshots → instance_projections → process_definitions`.
   Already the order in the current `cleanupInstance` + `cleanupByName`
   pair; the change is only in error handling.

### 5.4 Per-test hardening — `tests/integration/iss203_idempotency_keys_test.zig`

Same pattern as §5.3, applied to `cleanupInstance` (lines ~125-149) and
`cleanupByName` (lines ~150-159). Delete order:
`timers → tasks → events → instance_definition_snapshots → instance_projections → process_definitions`.

### 5.5 Per-test hardening — `tests/integration/iss601_state_snapshots_test.zig`

The existing `cleanupSnapshots` (line ~117) and the three additional
cleanup blocks (lines ~171-178, 617-624, 838-846, 990-997) delete
`instance_state_snapshots → events → instance_definition_snapshots → instance_projections`
in FK order but **do not delete `process_definitions`**. Fix:

1. **Add a `cleanupDefinitionByName(pool, name)` helper** that issues
   `DELETE FROM process_definitions WHERE name = $1` and returns any
   SQL error to the caller.
2. **Register the new helper via `defer` after the definition is created**
   so it runs before `cleanupInstance` (LIFO) — i.e. parent-cleanup
   `defer` registered *after* child-cleanup `defer` runs *first*.
3. **Replace the inline `c.exec(...) catch {}` blocks in the four cleanup
   sites** with calls to a single `cleanupInstanceAll(pool, inst_hex)`
   helper that returns the first SQL error.

### 5.6 `tests/unit/event_store_test.zig` — NOT a fix target

`tests/unit/event_store_test.zig` is `SkipZigTest`-only and has no DB
cleanup. It is NOT a fix target. The root-cause report confirms this.
The GitHub acceptance criteria will not include any test ID that maps to
this file (see §7 Acceptance Criteria).

---

## 6. Schema contract test (Type C, owned by TEST-DESIGNER)

A new file `tests/integration/schema_contracts/iss0125_definition_snapshot_cascade_test.zig`
verifies the cascade at runtime. **The file is a Type C test pair with the
migration; this design artefact sketches its structure for BACKEND-DEV and
TEST-DESIGNER consumption but does NOT write the file.**

Test cases:

| Test ID | GIVEN | WHEN | THEN |
|---|---|---|---|
| `TC-ISS-0125-01` | A `process_definitions` row exists, with two referencing `instance_definition_snapshots` rows (different `instance_id`s). | `DELETE FROM process_definitions WHERE id = $1` is executed. | Both `instance_definition_snapshots` rows are gone; no C23503 is raised; the DELETE returns one row affected. |
| `TC-ISS-0125-02` | The cascade contract is intact. | `information_schema.referential_constraints` is queried for the constraint named `instance_definition_snapshots_definition_id_fkey` on `public.instance_definition_snapshots`. | `delete_rule = 'CASCADE'` and `update_rule = 'NO ACTION'`. |
| `TC-ISS-0125-03` | The shared harness `resetTestData()` is invoked against a freshly-created process_definitions row + 3 instance_definition_snapshots rows. | `resetTestData()` completes. | All three child rows are gone; the parent row is gone; no FK error. |
| `TC-ISS-0125-04` | Three bespoke-cleanup test files (`iss202`, `iss203`, `iss601`) are executed in the same `zig build test-integration` invocation. | Each test's `defer` cleanup runs. | Zero `instance_definition_snapshots_definition_id_fkey` C23503 diagnostics appear in the zig_test_integration log. |

---

## 7. Acceptance criteria — concrete, GIVEN/WHEN/THEN

Each item is one verifiable assertion. The numbers `AC-N` correspond 1:1
to the GitHub issue #391 acceptance-criteria checklist.

- **AC-1** GIVEN the new migration `migrations/GBL-106_instance_definition_snapshots_cascade.sql`,
  WHEN `zig build migrate` is run against a fresh `bpm_test` database,
  THEN the file applies successfully, the ledger gains one row,
  and `information_schema.referential_constraints.delete_rule` for
  `instance_definition_snapshots_definition_id_fkey` returns
  `'CASCADE'`.
- **AC-2** GIVEN the schema contract test `TC-ISS-0125-01` from §6,
  WHEN `zig build test-integration` runs the contract test,
  THEN the assertion holds, the FK cascade deletes both child rows,
  and the log contains no `instance_definition_snapshots_definition_id_fkey`
  C23503 text.
- **AC-3** GIVEN the shared harness `resetTestData()` and the
  `TC-ISS-0125-03` contract test, WHEN the test runs,
  THEN the harness returns success and
  `SELECT count(*) FROM public.instance_definition_snapshots` returns 0,
  AND `SELECT count(*) FROM public.process_definitions` returns 0,
  AND no FK error is logged.
- **AC-4** GIVEN the four affected test files (`iss202`,
  `iss203`, `iss601`, plus the GBL-106 schema contract test) with
  their new error-propagating cleanup helpers, WHEN
  `zig build test-integration` is run repeatedly (≥3 times) against
  the shared `db_test` container,
  THEN the full log contains zero
  `instance_definition_snapshots_definition_id_fkey` C23503 diagnostics,
  AND the failure clusters TC-ISS-202-02/05, TC-ISS-203-03/04/05,
  TC-ISS-601-01..09, TC-EE-08-04, TC-EE-10-04/05/06,
  TC-EXP-202-01/02/03, TC-ES-03-01 all PASS.
- **AC-5** GIVEN `tests/unit/event_store_test.zig` exists with
  `SkipZigTest` stubs and no DB cleanup, WHEN this issue is closed,
  THEN no assertion in this fix targets that file (it is out of
  scope and explicitly documented as such in the design).

---

## 8. Error taxonomy

**No new error sets are introduced** in production code.

The cascade FK change cannot introduce a new error path in
production: PostgreSQL's `ON DELETE CASCADE` is the *removal* of an
error path (the old C23503 on parent DELETE), not the introduction of
one. The only callers that need updating are test-cleanup helpers, which
already have per-test error sets; those gain `error.CleanupFailed`
internally for propagated SQL errors but do not export it as a new public
error.

The `Migrations.runForSchema()` error set (`MigrationError`) is
unchanged: the migration uses the standard `BEGIN`/`COMMIT` and DDL
patterns already covered by `MigrationError.MigrationFailed`.

---

## 9. Dependencies

- **PostgreSQL 15+** (already an INV-TI-1 prerequisite).
- **`zig build migrate`** against the `bpm_test` database (INV-TI-3
  contract parity).
- **No new Python tools**, **no new GBL-prefixed migration runner
  changes**, **no new typespec files**.
- **No new package dependencies** (no `Cargo.toml`, `package.json`, or
  `build.zig.zon` changes).

---

## 10. Test coverage

The new test IDs this fix produces / verifies:

- `TC-ISS-0125-01` — FK cascade deletes both child rows.
- `TC-ISS-0125-02` — `information_schema.referential_constraints`
  reports `delete_rule = 'CASCADE'`.
- `TC-ISS-0125-03` — `resetTestData()` order documented and works
  against a populated fixture.
- `TC-ISS-0125-04` — full integration run of iss202 / iss203 / iss601
  produces zero C23503 diagnostics.

Existing test IDs whose pass rate this fix restores (per the
GitHub acceptance criteria):

- `TC-ISS-202-02`, `TC-ISS-202-05`
- `TC-ISS-203-03`, `TC-ISS-203-04`, `TC-ISS-203-05`
- `TC-ISS-601-01` through `TC-ISS-601-09`
- `TC-EE-08-04`
- `TC-EE-10-04`, `TC-EE-10-05`, `TC-EE-10-06`
- `TC-EXP-202-01`, `TC-EXP-202-02`, `TC-EXP-202-03`
- `TC-ES-03-01`

---

## 11. Rollout & rollback

### 11.1 Rollout

1. Create the feature branch `feature/WF03-gh391-20260801` (already
   exists — Step 00 created it).
2. Add `migrations/GBL-106_instance_definition_snapshots_cascade.sql`
   (Type E prose → BACKEND-DEV Type C implementation; BACKEND-DEV
   commits the file).
3. Run `zig build migrate` against `bpm_dev` for a smoke check; verify
   the constraint name persists and `delete_rule = 'CASCADE'`.
4. Apply the `tests/integration/helpers.zig` doc-comment + per-test
   hardening (BACKEND-DEV).
5. Add the schema contract test
   `tests/integration/schema_contracts/iss0125_definition_snapshot_cascade_test.zig`
   (TEST-DESIGNER; BACKEND-DEV may stub the file but the contract test
   design lives with TEST-DESIGNER per WF-03 step 4).
6. Run `zig build test-integration` (TEST-RUNNER) — expect
   zero `instance_definition_snapshots_definition_id_fkey` C23503
   diagnostics across ≥3 repetitions.
7. DOC-UPDATER updates CHANGELOG.md and stamps
   `docs/issues/ISS-0125.json.resolved_at` + `resolution`.
8. Step Final — `git push`, `gh pr create`, `gh pr merge --squash
   --delete-branch`.

### 11.2 Rollback

**Forward-only.** This migration is the *only* schema change in this
fix and is forward-compatible: dropping and re-adding the same FK with
a different referential action is always safe. The new FK is
semantically a strict superset of the old one (every successful old
DELETE remains a successful new DELETE; new DELETEs that previously
failed with C23503 now succeed and remove their children).

If an unforeseen downstream caller relied on the C23503 as a guard
(e.g. an audit log of attempted-but-blocked parent deletes), the
rollback procedure is:

1. `git revert <merge-commit>` on `main` (BACKEND-DEV).
2. The reverted migration adds a follow-up `GBL-107_*.sql` that
   re-creates the FK without `ON DELETE CASCADE` and records a
   `ROLLBACK-GBL-106` entry in the changelog. BACKEND-DEV writes
   GBL-107 as the forward-fix of any new findings from the reverted
   run.
3. Per-test hardening changes (helpers.zig + four test files) are
   **NOT** reverted — they are correctness improvements independent
   of the FK change. The C23503 cluster will resurface if the FK is
   reverted, but the per-test error propagation will now surface
   those failures visibly instead of swallowing them.

---

## 12. References

- **Migration owner:** `migrations/004_definitions.sql:50-57` — declares
  `instance_definition_snapshots.definition_id UUID NOT NULL REFERENCES
  process_definitions(id)` without `ON DELETE CASCADE`. The FK name
  `instance_definition_snapshots_definition_id_fkey` is
  PostgreSQL's default for an unnamed inline REFERENCES column
  constraint.
- **Unrelated (do NOT modify):** `migrations/GBL-085_state_snapshots.sql:1-31`
  — operates on `public.instance_state_snapshots`, not on
  `instance_definition_snapshots`. Confirmed by the root-cause report.
- **Applier convention:** `src/db/migrations.zig:166-176` (GBL-prefix skip
  for non-public schemas) and `src/db/migrations.zig:179-191`
  (`-- reapply_on_drift: true` header detection).
- **Migration runner precedent for the header convention:**
  `migrations/GBL-105_iss0112_schema_ledger_reconcile.sql` (line ~58
  has `-- reapply_on_drift: true`).
- **Shared test harness:** `tests/integration/helpers.zig:310-325` —
  `resetTestData()` already orders snapshots before definitions.
- **Bespoke-cleanup surface:**
  - `tests/integration/iss202_merge_atomicity_test.zig:130-152`
  - `tests/integration/iss203_idempotency_keys_test.zig:125-159`
  - `tests/integration/iss601_state_snapshots_test.zig:113-178,
    617-624, 838-846, 990-997`
- **Out of scope:** `tests/unit/event_store_test.zig` — `SkipZigTest`
  stubs only, no DB cleanup. Documented in
  `docs/issue-reports/ISS-0125-root-cause.md` §"affected_test_cleanup"
  (event_store_test.zig finding).
- **Test infrastructure invariants:** `docs/guides/test_infrastructure_guide.md`
  §2 (INV-TI-1 Deterministic Baseline, INV-TI-2 Strict Per-Test
  Isolation, INV-TI-3 Schema/Code Contract Parity).
- **GitHub issue:** https://github.com/tvolodi/R-Co/issues/391
- **Local issue file:** `docs/issues/ISS-0125.json`
- **Root-cause report:** `docs/issue-reports/ISS-0125-root-cause.md`

---

## 13. Open questions for REQ-ANALYST

None. The four acceptance-criteria bullets in the GitHub issue are
unambiguous; the strategy-C recommendation from the root-cause report is
the basis for this design. If a future REQ-ANALYST pass is required,
the questions would be:

1. Should the cascade be `ON DELETE CASCADE` (this design) or
   `ON DELETE SET NULL`? — Settled: `CASCADE`, because
   `definition_id` is `NOT NULL` (see 004_definitions.sql:52), so
   `SET NULL` would require dropping NOT NULL and is a larger blast
   radius.
2. Should `events` get the same treatment? — Out of scope for this
   issue. `events` already has its own cleanup story
   (see root-cause report §"prior_issue_matches" — ISS-0113 covered
   `events` separately). If a future ISS surfaces the same pattern for
   events, it gets its own GBL migration.
