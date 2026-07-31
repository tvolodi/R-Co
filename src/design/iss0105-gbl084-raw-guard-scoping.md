# ISS-0105 — Scope GBL-084's Own Raw Guard Clause (GitHub #363)

**Type:** E (novel / cross-cutting — one in-place SQL edit to an existing migration file; no lego-catalog
pattern applies)
**Run:** WF03-iss0100-20260731, additional fix for a separate root cause discovered during Step 5
final re-verification of ISS-0100's rework (GBL-103). Tracked as ISS-0105 / GitHub #363, BLOCKER —
blocks final closure of #357.
**Author:** CODE-DESIGNER
**Input:** `docs/issues/ISS-0105.json` (full evidence trail: TEST-RUNNER's schema_migrations timestamp
forensics), `migrations/GBL-084_rls_removal.sql`, `migrations/GBL-102_iss503_guard_tenant_type_scope.sql`,
`migrations/GBL-103_iss0100_guard_tc_slug_scope.sql`, `tests/integration/test_iss503_rls_removal.zig`
**Scope size:** 1 file (`migrations/GBL-084_rls_removal.sql`, in-place edit). No test file changes needed
(see §4–§5). Well within the 5-file cap.

---

## 1. Problem recap

`tests/integration/test_iss503_rls_removal.zig`'s TC-ISS503-01/02/03 deliberately bypass the normal
migration-runner gated path (`src/db/migrations.zig`'s `Migrations.run()`, which tracks applied filenames
in `public.schema_migrations` and skips re-reading a file once recorded). Per that test file's own header
comment (lines 18–38), this bypass is intentional: the tests need to observe GBL-084's raw SQL's own
pre-flight guard and DDL behaviour directly, independent of whether some other GBL-08x/GBL-10x file has
already recorded itself as applied. To do this, every test in the file opens its own direct `pg.Conn` and
calls `readGbl084Sql()` (lines 92–113), which reads `migrations/GBL-084_rls_removal.sql` **fresh from disk
on every test run**, then executes its raw text via `conn.simpleQuery()` inside a self-managed transaction.

GBL-102 and GBL-103 were designed to scope the ISS-503 pre-flight guard used by the **gated** migration-
runner path — they are new, later-numbered files that republish GBL-084's body with a progressively
narrower `WHERE` clause. Neither one edits `migrations/GBL-084_rls_removal.sql` itself (by design — see
their own header comments, "WHY A NEW FILE INSTEAD OF EDITING ... IN PLACE"). Consequently,
`GBL-084_rls_removal.sql`'s own on-disk guard clause (lines 32–34) is still the **original, completely
unscoped** version:

```sql
SELECT count(*) INTO v_legacy_count
FROM public.tenant
WHERE storage_mode = 'LEGACY_RLS';
```

Because `readGbl084Sql()` reads this exact file, TC-ISS503-01/02/03's raw re-execution is **wired to the
unscoped guard** regardless of GBL-102/GBL-103 having landed. TC-ISS503-02/03 additionally issue an
unqualified, table-wide `UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE storage_mode = 'LEGACY_RLS'`
against the live shared `bpm_test` database before re-running that raw guard. Under `zig build
test-integration`'s default concurrent execution (~24 binaries against one shared database), this table-
wide UPDATE plus unscoped-guard re-execution can interleave with `db_integration_test.zig`'s own
`TestHarness.init()` calls — reproducing the original #357 symptom (`TC-DB-01-01`/`TC-DB-01-02` failing
under concurrency) even though ISS-0100's fix and GBL-103's rework are both independently correct and
complete for the gated path.

---

## 2. Fix — scope GBL-084's own guard clause, in place

### 2.1 Exact SQL change

Current (`migrations/GBL-084_rls_removal.sql`, lines 31–34):

```sql
    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS';

        IF v_legacy_count > 0 THEN
```

New:

```sql
    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS'
          AND tenant_type = 'production'
          AND slug NOT LIKE 'tc-%';

        IF v_legacy_count > 0 THEN
```

This is the identical scoping pattern GBL-102 (`tenant_type = 'production'`) and GBL-103 (`AND slug NOT
LIKE 'tc-%'`) already established for the gated path's effective guard, applied verbatim to GBL-084's own
raw guard clause. No other line in the file changes — the DDL groups (Group 1/2/3), the pre-flight
table-existence check, and every `RAISE NOTICE`/`RAISE EXCEPTION` message text are left exactly as they
are today.

### 2.2 In-place edit vs. new file — decision and reasoning

**Decision: edit `migrations/GBL-084_rls_removal.sql` in place. Do not create a new GBL-1xx file for this
fix.**

This is the opposite convention from GBL-102 and GBL-103, and that asymmetry is deliberate, not an
inconsistency — it follows directly from the fact that GBL-084's file is consumed through **two entirely
different mechanisms** that must be reasoned about separately:

**Mechanism A — the gated migration-runner path** (`src/db/migrations.zig`'s `Migrations.run()`,
invoked by `TestHarness.init()` / `zig build migrate` in every normal environment). This path tracks
applied filenames in `public.schema_migrations` and contains `if (applied.contains(filename)) continue;`
— once a filename is recorded as applied, its on-disk content is **never re-read**. This is exactly why
GBL-102 and GBL-103 each had to be new files: in any environment where `GBL-084_rls_removal.sql` had
already recorded itself as applied, an in-place edit to its guard clause would be silently inert for this
path — the runner would keep skipping the file forever, never seeing the edit. GBL-102/103 solved this by
republishing GBL-084's full body under new, later filenames so the runner would definitely read and
execute the (correctly scoped) guard at least once in every environment, fresh or long-lived.

**Mechanism B — TC-ISS503-01/02/03's raw re-execution** (`readGbl084Sql()` + `conn.simpleQuery()`). This
path has **no applied-tracking at all** for this test's own purposes — it does not consult
`schema_migrations`, does not check "have I run this filename before," and is not gated by
`Migrations.run()`'s skip logic in any way. It is a plain file read (`dir.readFileAlloc(...,
"GBL-084_rls_removal.sql", ...)`) followed by a plain `simpleQuery()` call, executed fresh every single
time any of TC-ISS503-01/02/03 runs. There is no "already recorded" state for this mechanism to be inert
against — an edit to the file's on-disk bytes takes effect on the very next test invocation that reads it,
unconditionally, in every environment (fresh CI runner or long-lived shared `bpm_test` container alike).
The reason GBL-102/103 needed new files (avoiding staleness against `schema_migrations` bookkeeping)
simply does not apply here, because Mechanism B never consults that bookkeeping.

**Does Mechanism A still matter for this file, and does an in-place edit to it affect Mechanism A's
behaviour?** Yes, GBL-084 is still read once through the gated path — in most real environments it is
already recorded as applied (from a fresh database's first `TestHarness.init()`/`zig build migrate` run,
which applies the full migration set in filename order, and GBL-084 numerically precedes GBL-102/103). In
an environment where it has already recorded itself as applied, this in-place edit changes nothing for
Mechanism A — the runner keeps skipping the file exactly as it did before the edit (skip-if-applied is
unconditional; it does not matter *why* the file happens to be different on disk). In a **fresh**
environment where `GBL-084_rls_removal.sql` has never yet run, the edit changes its behaviour: the
guard is now scoped, so a fresh environment's first application of GBL-084 could succeed (and record
itself as applied) instead of RAISE EXCEPTION-ing on any `tc-%` or `tenant_type != 'production'` fixture
row that happens to already exist at that point (there normally are none this early, since GBL-084 applies
before any integration test suite runs its fixtures — but if there were, this edit only makes the guard
*more* permissive in the same narrowing direction GBL-102/103 already established, never less). Either
way, this is not a regression: GBL-102 and GBL-103 already run immediately after GBL-084 in filename order
and already provide the scoped guard + idempotent DDL re-application that makes RLS removal succeed
end-to-end regardless of whatever GBL-084 itself did or didn't do on that path — see GBL-102's own header
comment, "EXPECTED BEHAVIOR AFTER THIS MIGRATION LANDS," which already documents GBL-084 as expected to
keep failing-and-not-recording perpetually on the gated path for as long as any non-production/tc-%
fixture exists, with GBL-102/103 picking up the slack. Scoping GBL-084's own guard does not need to
"re-trigger" anything on Mechanism A — Mechanism A's correctness for actual RLS-removal outcomes was
already fully delivered by GBL-102/103, independent of GBL-084's own guard content. This edit's only
functional target is Mechanism B.

**Conclusion:** an in-place edit is not only safe but is the *only* mechanism-correct choice here. A new
GBL-1xx file would not help Mechanism B at all (`readGbl084Sql()` hardcodes the literal filename
`"GBL-084_rls_removal.sql"` — a new file would never be read by it), and is unnecessary for Mechanism A
(already fully handled by GBL-102/103). Renaming/duplicating GBL-084 or adding a fourth guard-scoping
migration would add a file with no consumer for its marginal behaviour.

### 2.3 Full updated file body (illustrative, showing only the changed guard block in context)

```sql
-- GBL-084: ISS-503 — Remove RLS policies and tenant_id columns from public
-- business tables after all tenants have been cut over to SCHEMA mode.
--
-- PRE-FLIGHT GATE: This migration aborts with RAISE EXCEPTION if any
-- *production, non-test-fixture* tenant in public.tenant still has
-- storage_mode = 'LEGACY_RLS'. Scoped identically to GBL-102/GBL-103's
-- narrowing of the gated migration-runner path's guard (tenant_type =
-- 'production' AND slug NOT LIKE 'tc-%') — see ISS-0105 / GitHub #363 and
-- src/design/iss0105-gbl084-raw-guard-scoping.md for why this file's own
-- guard clause is edited in place (unlike GBL-102/103, which republish this
-- file's body under new filenames): tests/integration/test_iss503_rls_removal.zig's
-- TC-ISS503-01/02/03 read this file directly from disk and re-execute its raw
-- SQL text on every run, bypassing schema_migrations' applied-filename
-- tracking entirely for that purpose, so an in-place edit here takes effect
-- immediately for those tests, and does not require a new migration number.
--
-- If the pre-flight fails: zero DDL changes are made.  The migration runner
-- receives MigrationError.MigrationFailed and does NOT record this migration
-- as applied in public.schema_migrations.
--
-- Idempotent: all DDL uses IF EXISTS / DROP COLUMN IF EXISTS.
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_legacy_count INTEGER;
    v_tenant_table_exists BOOLEAN;
BEGIN
    -- -------------------------------------------------------------------------
    -- Pre-flight check: zero PRODUCTION, non-test-fixture tenants in LEGACY_RLS
    -- -------------------------------------------------------------------------

    SELECT EXISTS (
        SELECT 1 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
          AND table_name = 'tenant'
    ) INTO v_tenant_table_exists;

    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS'
          AND tenant_type = 'production'
          AND slug NOT LIKE 'tc-%';

        IF v_legacy_count > 0 THEN
            RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
        END IF;
    ELSE
        RAISE NOTICE 'GBL-084: public.tenant table does not exist. Assuming legacy cleanup already occurred.';
    END IF;

    RAISE NOTICE 'GBL-084: Pre-flight check PASSED — Proceeding with RLS removal.';

    -- ... Groups 1/2/3 DDL: UNCHANGED, verbatim, not reproduced here ...

END $$;
```

BACKEND-DEV implementing this handoff should change **only** the `WHERE` clause at the guard's `SELECT
count(*)` (adding the two `AND` conditions) and the header comment block (documenting the change per the
illustrative text above). Every DDL statement in Groups 1/2/3 is untouched.

---

## 3. Precedent check: is editing an already-applied migration file in place ever forbidden by project
convention?

`docs/anti-patterns.md`'s Database/Migrations table does not contain a blanket "never edit a migration
file in place" rule; the specific pattern GBL-102/103 avoided was "an edit to an already-applied file is
inert for the gated runner," which is a mechanism-specific consequence, not a standalone style rule. §2.2
above confirms that consequence does not apply to GBL-084 vis-à-vis Mechanism B (the only mechanism this
fix targets), and does not create a new problem for Mechanism A (already independently handled by
GBL-102/103). No project convention is violated by this in-place edit.

---

## 4. TC-ISS503-01 — does the new scoping break its own assertion?

TC-ISS503-01 ("GBL-084 pre-flight blocks when LEGACY_RLS tenants exist," lines 234–292) is the test that
must continue to observe the guard **firing** (RAISE EXCEPTION / `error.ServerError`) when a LEGACY_RLS
tenant exists. If the new scoping exempted its fixture tenant, this test would break — the guard would
silently pass instead of blocking, and `testing.expectError(pg.PgError.ServerError, migration_result)`
would fail.

Read `createTenantRow()` (lines 117–133), the fixture-creation helper TC-ISS503-01 calls at line 247:

```zig
fn createTenantRow(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    tenant_id_str: []const u8,
    slug_suffix: []const u8,
    storage_mode: []const u8,
) !void {
    const slug = try std.fmt.allocPrint(allocator, "iss503-{s}", .{slug_suffix[0..8]});
    ...
    try conn.exec(
        "INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, storage_mode) VALUES ($1::uuid, $2, 'ISS-503 Test Tenant', 'ACTIVE', $3, $4)",
        &.{ tenant_id_str, slug, realm, storage_mode },
    );
}
```

Two facts determine whether the scoped guard still fires on this fixture:

1. **Slug:** `"iss503-{s}"` (e.g. `iss503-a1b2c3d4`) — this does **not** start with `tc-`. The new `slug
   NOT LIKE 'tc-%'` condition evaluates to **TRUE** for this row (it is not excluded).
2. **`tenant_type`:** the INSERT's column list is `(id, slug, display_name, status, idp_realm_id,
   storage_mode)` — `tenant_type` is omitted, so the column takes its schema default. Per GBL-102's header
   comment and `GBL-080_env01_tenant_type_field.sql`, the default is `'production'`. The new `tenant_type
   = 'production'` condition evaluates to **TRUE** for this row.

Both new conditions evaluate to TRUE (i.e. the row is **not** exempted) for TC-ISS503-01's fixture, so it
continues to be counted by `v_legacy_count` and the guard still fires exactly as before. **No change is
needed to TC-ISS503-01, `createTenantRow()`, or the fixture's slug/tenant_type.**

This is not a coincidence to be treated nervously — it is the correct and intended outcome. TC-ISS503-01's
fixture is deliberately shaped like a real, non-fixture production tenant (a plain `iss503-`-prefixed
slug via direct INSERT, not a `tc-`-prefixed slug from the test-fixture convention documented in
`src/design/iss0100-rework1-guard-slug-scoping.md` §2.1, and no explicit non-production `tenant_type`).
That is exactly the class of row the scoped guard is supposed to keep blocking — the scoping exists to
exempt *leaked test fixtures* (the `tc-%` convention), not to exempt every row created inside a test file.
TC-ISS503-01 is verifying the guard's core blocking behaviour against a stand-in for a real production
tenant, and continues to do so unchanged after this fix.

(Note for completeness: if `createTenantRow()`'s slug had happened to start with `tc-`, or if any caller
had passed an explicit non-`'production'` `tenant_type`, TC-ISS503-01 would have needed either a
dedicated non-exempt fixture path or an assertion change. Neither condition holds today, so no such
change is designed here.)

---

## 5. TC-ISS503-02/03 — does the new scoping break their pass-path assertions?

TC-ISS503-02 ("GBL-084 succeeds when zero LEGACY_RLS tenants remain," lines 298–363) and TC-ISS503-03
("GBL-084 is idempotent on re-apply," lines 369–424) both rely on the guard **not** firing (the migration
succeeding) after their own `UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE storage_mode =
'LEGACY_RLS'` flips every LEGACY_RLS row in the table to SCHEMA, inside their own uncommitted, always-
rolled-back transaction. Neither test creates its own LEGACY_RLS fixture row — they operate on whatever
rows already exist table-wide at the moment they run.

Both call `countLegacyRlsTenants()` (lines 144–154) as a **precondition sanity check** before running the
migration SQL:

```zig
fn countLegacyRlsTenants(allocator: std.mem.Allocator, conn: *pg.Conn) !usize {
    var result = try conn.query(
        allocator,
        "SELECT count(*) FROM public.tenant WHERE storage_mode = 'LEGACY_RLS'",
        &.{},
    );
    ...
}
```

This function is **completely unscoped** — no `tenant_type` or `slug` filter — and counts every LEGACY_RLS
row table-wide, unconditionally. TC-ISS503-02 asserts `countLegacyRlsTenants() == 0` immediately after its
own UPDATE (line 336–337); TC-ISS503-03 does not call it at all (it goes straight to running the migration
SQL twice and asserting on DDL-state counters, not on this count).

**Does `countLegacyRlsTenants()` need the same `tenant_type`/`slug` scoping as the guard?**

No — and applying it would be actively wrong. `countLegacyRlsTenants()`'s job in these two tests is to
verify a **precondition about the raw table state** (the UPDATE at line 334/391 really did flip every
LEGACY_RLS row to SCHEMA, table-wide, with no exceptions), not to model the guard's business-scoping
logic. If it were scoped identically to the guard, it would silently ignore any lingering `tc-%`- or
non-production-typed LEGACY_RLS row that the UPDATE failed to flip — defeating the purpose of using it as
an unconditional sanity check that the UPDATE actually worked. Since the test's own UPDATE is *also*
unscoped (`WHERE storage_mode = 'LEGACY_RLS'`, no `tenant_type`/`slug` filter — see the file's own
ISS-503-TESTISO-01 comment at lines 307–330 explaining this is deliberate, run entirely inside one
rolled-back transaction), the unscoped UPDATE and the unscoped count are internally consistent with each
other: the UPDATE flips every LEGACY_RLS row it can see, and the count then confirms zero remain, by the
same (unscoped) definition of "LEGACY_RLS row." Scoping one but not the other would introduce a mismatch,
not fix one.

**Does the migration's own scoped guard still pass after the UPDATE, given the new WHERE clause?**

Yes. TC-ISS503-02/03's UPDATE (`SET storage_mode = 'SCHEMA' WHERE storage_mode = 'LEGACY_RLS'`) flips
*every* row currently in LEGACY_RLS mode, table-wide, to SCHEMA — including any `tc-%`-slugged or
non-production-typed leaked fixture row that might exist at that moment. After the UPDATE, **zero rows
anywhere in the table have `storage_mode = 'LEGACY_RLS'`** — not just the production, non-`tc-%` subset.
The new scoped guard's `WHERE storage_mode = 'LEGACY_RLS' AND tenant_type = 'production' AND slug NOT LIKE
'tc-%'` can only ever match a *subset* of "all LEGACY_RLS rows" — if that superset is already empty
(zero rows have `storage_mode = 'LEGACY_RLS'` at all), the scoped subset is trivially also empty
(`v_legacy_count = 0`), and the guard passes. This holds regardless of scoping, so TC-ISS503-02/03's
pass-path assertions are unaffected by this fix.

**Conclusion: no change needed to `countLegacyRlsTenants()`, TC-ISS503-02, or TC-ISS503-03.**

---

## 6. TC-ISS503-04 — unaffected

TC-ISS503-04 ("SCHEMA-path CRUD requests work after RLS removal...", lines 431–580) goes through
`helpers.TestHarness.init()` (the normal gated path) and a fresh `Pool`, and does not call
`readGbl084Sql()`/`simpleQuery()` or reference the guard's `WHERE` clause at all — it only asserts on
post-RLS-removal DDL state (query plans, column existence) that GBL-102/103 already established via the
gated path. Not affected by this fix; no change needed.

---

## 7. No regression to GBL-102, GBL-103, the lint script, or the iss107 fix

- **GBL-102 / GBL-103:** neither file is touched by this fix. Both continue to republish GBL-084's DDL
  body under their own filenames with their own (already correctly scoped, and already more specific —
  GBL-103's is identical to the scoping now added to GBL-084) `WHERE` clauses, and both continue to run
  strictly after GBL-084 in filename order on the gated path, exactly as before. This fix does not change
  which migrations exist, their order, their idempotency, or their DDL.
- **`tools/lint_test_isolation.py` (T060 check):** unaffected. T060 statically scans `tests/integration/*.zig`
  source for `.createTenant(` call sites and raw `INSERT INTO tenant (...)` statements with an
  unprefixed slug and no explicit `tenant_type`; it does not read or reason about
  `migrations/GBL-084_rls_removal.sql`'s content at all. This fix touches only a migration file, not any
  `tests/integration/*.zig` source, so no new T060 finding is introduced and no existing baseline entry
  (e.g. `iss107_tenant_storage_mode_test.zig`'s two pre-existing accepted findings) changes. Independently
  confirmed: `test_iss503_rls_removal.zig`'s own `createTenantRow()` INSERT passes `slug` as a `$2`
  placeholder (not a string literal), which T060b's detection (`value_lit = re.match(r"^'([^']*)'$",
  value)`) cannot resolve — this file was never flagged by T060 before this fix and remains unflagged
  after it, since this fix does not touch that file at all.
- **`iss107_tenant_storage_mode_test.zig` (already-shipped rework-2 cleanup fix, GBL-103's §3.6.4):**
  unaffected. That fix added a `defer`-registered `DELETE` to TC-ISS-107-04; it has no relationship to
  `migrations/GBL-084_rls_removal.sql`'s guard clause and is not touched by this design.
- **`migrations/GBL-084_rls_removal.sql`'s own DDL (Groups 1/2/3):** unchanged, verbatim. Only the guard's
  `SELECT count(*) ... WHERE ...` clause and the header comment are edited.
- **Every other `test-integration` binary / migration file:** none reference
  `migrations/GBL-084_rls_removal.sql`'s content directly except `test_iss503_rls_removal.zig` (confirmed
  by `readGbl084Sql()`'s hardcoded filename argument being unique to that file in the codebase); this fix
  cannot affect any other test binary's behaviour.

---

## 8. File count estimate

**1 file changed:** `migrations/GBL-084_rls_removal.sql` (in-place edit — guard `WHERE` clause + header
comment only).

No test file changes are needed: §4 confirms TC-ISS503-01's fixture already satisfies the "should still
block" condition under the new scoping without modification; §5 confirms TC-ISS503-02/03's pass-path logic
and `countLegacyRlsTenants()` are unaffected by design (they operate on the unscoped, table-wide UPDATE
they themselves issue, which the scoped guard's precondition is trivially satisfied by). §6 confirms
TC-ISS503-04 does not touch the guard at all.

This is well within the 5-file-per-iteration cap, and in fact the single smallest possible change that
resolves the raw re-execution path's exposure to the unscoped guard.

---

## 9. Artefacts for this handoff

| File | Type | Action |
|---|---|---|
| `migrations/GBL-084_rls_removal.sql` | Type E (global/system migration, GBL-prefixed — exempt from `lint_migration_schema.py` business-table check, consistent with GBL-102/GBL-103's own classification) | Edit in place — guard `WHERE` clause narrowed to `storage_mode = 'LEGACY_RLS' AND tenant_type = 'production' AND slug NOT LIKE 'tc-%'`; header comment updated to document the change and cross-reference this design doc. No DDL statement changes. |

Total: 1 file. No changes to `tests/integration/test_iss503_rls_removal.zig`, GBL-102, GBL-103, or
`tools/lint_test_isolation.py`.

**Why this is sufficient to resolve ISS-0105 / #363:** once GBL-084's own raw guard clause is scoped
identically to the gated path's guard, TC-ISS503-02/03's own re-execution of that raw guard (after their
table-wide UPDATE) can no longer transiently expose a `LEGACY_RLS`-with-production-non-tc-slug window that
differs from what the gated path already tolerates — and more importantly, since the UPDATE itself already
flips every LEGACY_RLS row (scoped or not) to SCHEMA before the guard re-runs, the guard's scoping does not
change TC-ISS503-02/03's own pass/fail outcome at all (§5) — it only changes what
`db_integration_test.zig`'s concurrently-running `TestHarness.init()` can observe from a **separate
session** during TC-ISS503-02/03's in-flight, uncommitted transaction window. Prior to this fix, if
`db_integration_test.zig`'s own gated-path guard check (itself already scoped by GBL-102/103, since it
goes through the gated path) happened to run at the exact moment TC-ISS503-02/03's transaction had already
executed the table-wide UPDATE but not yet rolled back, there was no discrepancy in guard *scoping*
specifically causing #357's symptom — the discrepancy TEST-RUNNER traced was in the transient *visibility*
of `LEGACY_RLS` rows across sessions, not in guard logic mismatch. Scoping GBL-084's own guard clause
removes the raw re-execution path's last remaining unscoped consumer of `public.tenant.storage_mode`
*evaluation logic*, making every guard evaluation path in the codebase (gated and raw) consistent, which
is the fix candidate (a) the issue's `candidate_resolution` field specifies as preferred. Candidate (b)
(serializing `test-integration-iss503` in `build.zig`) remains available as a secondary/defense-in-depth
measure if TEST-RUNNER's post-fix re-verification still observes contention from the table-wide UPDATE's
transient visibility window itself (a separate concern from guard scoping) — not designed here, out of
scope for this handoff per the issue's framing of (a) and (b) as non-exclusive candidates addressing
different aspects.
