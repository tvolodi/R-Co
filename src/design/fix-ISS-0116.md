# Module: fix-ISS-0116 — remove stale `::uuid` cast on `audit_entries.resource_id` comparisons in TC-OBS-05-INT-02/03

## Summary

GitHub #379 / ISS-0116 (MAJOR). The issue as filed claimed a broad DLQ
persistence/retry/discard/alert-state failure across four tests:
`TC-OBS-05-INT-01`, `TC-OBS-05-INT-02`, `TC-OBS-05-INT-03` (in
`tests/integration/obs05_dlq_test.zig`) and `TC-OBS-06-INT-05` (in
`tests/integration/obs06_alerts_test.zig`), with root cause left as "TBD".

**Diagnosis (this run) narrows this substantially.** Neither test file was
wired into `build.zig` as a narrow target (only reachable via the ~40-binary
`test-integration` umbrella through `main_test.zig`'s aggregate import), so no
one had re-run them in isolation with real Postgres error text since the
issue was filed. Two new narrow build steps
(`zig build test-integration-obs05` / `-obs06`) were added this run
(mirroring the `-ext02`/`-adp02` pattern from ISS-0637/ISS-0638) specifically
to get fast, isolated, real-error evidence.

Findings against current `main` (already includes ISS-0637/ISS-0638's fixes
and every other queue-drain commit through `db68a6e`):

- **`TC-OBS-06-INT-05` already passes.** All 5 tests in
  `obs06_alerts_test.zig` pass cleanly (`zig build test-integration-obs06`
  exits 0, 5/5). Whatever combination of fixes has landed on `main` since
  the issue was filed on 2026-08-01 (over a dozen WF-03 runs, several
  touching `obs_alert_trigger_state`/DLQ schema/audit chain) already resolved
  this test's failure. No further action needed for OBS-06.
- **`TC-OBS-05-INT-01` already passes.** Confirmed via
  `zig build test-integration-obs05 -Dlog-pg-errors=true`: 1 pass, 2 fail —
  the 1 pass is INT-01.
- **`TC-OBS-05-INT-02` and `TC-OBS-05-INT-03` still fail**, both with the
  identical, unambiguous error surfaced only once `-Dlog-pg-errors=true` is
  set (the vendored `pg.zig` client swallows PostgreSQL `ErrorResponse` wire
  payloads by default per ISS-0607/GH-542):

  ```
  POSTGRES ERROR: SERROR VERROR C42883 Moperator does not exist: text = uuid
  HNo operator matches the given name and argument types. You might need to
  add explicit type casts. P86 Fparse_oper.c L647 Rop_error
  ```

  Both failures trace to the exact same test-file line pattern already
  diagnosed and fixed twice before on this codebase — `src/design/fix-
  ISS-0637.md` (GH-619, `ext02_webhook_dispatch_test.zig`) and its sibling
  ISS-0638 (GH-621, `adp02_tenant_scope_test.zig`):

  `migrations/GBL-120_iss103_audit_resource_id_text.sql` (ISS-103) altered
  `audit_entries.resource_id` from `UUID` to `TEXT` in every schema. Both
  `obs05_dlq_test.zig` queries still compare it against a `$N::uuid`-cast
  parameter:

  - `tests/integration/obs05_dlq_test.zig:395` (inside
    `TC-OBS-05-INT-02`): `resource_id = $1::uuid AND action = 'dlq.retry'
    AND actor_id = $2::uuid`
  - `tests/integration/obs05_dlq_test.zig:462` (inside
    `TC-OBS-05-INT-03`): `resource_id = $1::uuid AND action =
    'dlq.discard'`

  PostgreSQL has no implicit `text = uuid` comparison operator, so both
  queries fail unconditionally with C42883 — independent of DLQ schema,
  retry/discard transition logic, or alert-state projection. This is
  **CATEGORY E (test code error)**: the production DLQ repository code
  (`src/dlq/store.zig`) and routes (`src/api/routes/dlq.zig`) are correct —
  neither queries `audit_entries.resource_id` with a `::uuid` cast, and the
  `dlq.retry`/`dlq.discard` state transitions themselves (via
  `set_config('bpm.actor_id', ...)` / `set_config('bpm.audit_action', ...)`
  read by the `bpm_audit_on_mutation()` trigger) are unaffected — only the
  *test's own assertion query* has a stale type expectation left over from
  before ISS-103 changed the column type.

  Note `actor_id = $2::uuid` on line 395 is correct and untouched:
  `audit_entries.actor_id` is genuinely `UUID` (migration
  `020_obs03_audit_entries.sql:11`), unlike `resource_id`.

## Acceptance criteria mapping

| Acceptance criterion (from GH-379) | Status after diagnosis | Covered by this fix? |
|---|---|---|
| Failed work is persisted and queryable through the canonical DLQ schema | Already true — `TC-OBS-05-INT-01` (persistence + GET /dlq filters/pagination) already passes on `main`; no schema/repository defect found | No code change needed; verified by existing passing test |
| Retry and discard transitions are explicit, atomic, and reflected in subsequent reads | Already true in `src/dlq/store.zig` (`retry`/`discard` use `conn.begin()`/`conn.commit()`/`conn.rollback()` transactionally); the *test's own audit-count assertion* cannot execute past the C42883 error, which is what makes the transitions look unverified | Yes — removing the stale cast lets the existing correct assertions actually run |
| Alert state accurately reflects actionable dead-letter items | Already true — `TC-OBS-06-INT-05` already passes cleanly (`readDlqDepth`/`persistThresholdState` against `dead_letter_items`/`obs_alert_trigger_state`) | No code change needed; verified by existing passing test |
| All four affected integration cases pass against real PostgreSQL | 2 of 4 already pass (INT-01, OBS-06 INT-05); 2 of 4 (INT-02, INT-03) blocked solely by the stale `::uuid` cast | Yes — this fix is suffient to bring all 4 to green |

## Fix scope confirmation (revised after running the fixed test)

Removing the `::uuid` cast alone (Fix A, below) was NOT sufficient — after
applying it, `TC-OBS-05-INT-02`/`-03` moved from a hard PostgreSQL C42883
error to a genuine logic failure: `retry_audit_count >= 1` /
`audit_count >= 1` both evaluated false (audit row count was 0). This
surfaced a second, real defect underneath the test-only bug, found by
inspecting `bpm_audit_on_mutation()` and querying the live `bpm_test`
database's installed function definitions directly (`pg_get_functiondef`
via `docker exec ... psql`):

- `tenant_default.bpm_audit_resource_info(text,jsonb,jsonb)` was confirmed
  live to still be the OLD `024_webhook_subscription_audit.sql`-installed
  shape (`OUT resource_id UUID`, only a `'dead_letter_queue'` branch) —
  **not** the `TEXT`-returning, dual-branch shape `GBL-121` installs.
  `public.bpm_audit_resource_info` DOES have the GBL-121 shape. Two
  different function bodies live side by side in the same database because
  `GBL-`-prefixed migrations only ever run against `public`
  (`src/db/migrations.zig`'s `Migrations.run() == runForSchema(...,
  "public", ...)`), while `audit_entries`/`dead_letter_items` are
  `PER_TENANT` tables that only exist in `tenant_default`. `GBL-121`'s fix
  never reached the schema where it was needed.
- The trigger `trg_bpm_audit_dead_letter_queue` survived the `072` table
  rename (Postgres binds triggers by relation OID, not name) and still
  fires with `TG_TABLE_NAME = 'dead_letter_items'`. In `tenant_default`,
  `bpm_audit_resource_info('dead_letter_items', ...)` falls through every
  `IF` branch to `resource_type := table_name; resource_id := NULL;`
  because that copy of the function has no `'dead_letter_items'` branch.
  `bpm_audit_on_mutation()`'s `IF r_id IS NULL THEN RETURN; END IF;` then
  silently skips the `INSERT INTO audit_entries` — the `dlq.retry`/
  `dlq.discard` transitions in `dead_letter_items` happen correctly and
  atomically, but leave zero audit trail. This is exactly the symptom the
  two tests assert against.
- `bpm_audit_action_for_change` has the identical gap and was never patched
  by anything, anywhere: only `020_obs03_audit_entries.sql` and
  `024_webhook_subscription_audit.sql` (both plain numeric, both
  `'dead_letter_queue'`-only) ever define it; no `GBL-121`-style follow-up
  exists for this function. It does not block the INSERT by itself
  (`bpm.audit_action` is set explicitly by `src/dlq/store.zig` before every
  mutating statement, bypassing the fallback), but its catch-all
  `RETURN lower(table_name) || '.' || lower(op);` would otherwise mislabel
  the action for any DLQ mutation that does NOT go through `store.zig`'s
  explicit `set_config` calls, so it is fixed in the same migration.

2 files:

- `tests/integration/obs05_dlq_test.zig` — **Fix A**: remove the `::uuid`
  cast on the `resource_id = $1` comparison in both `TC-OBS-05-INT-02`
  (line 395) and `TC-OBS-05-INT-03` (line 462). The bound parameter
  (`active_dlq_id` / `dlq_id_ok`, both `[]const u8`) is already formatted
  as a canonical UUID string; comparing it against a `TEXT` column with no
  cast on either side is correct, matching the established pattern from
  `fix-ISS-0637.md`.
- `migrations/1139_iss0116_audit_dlq_rename_tenant_functions.sql`
  (NEW) — **Fix B**: a plain numeric migration (not `GBL-`-prefixed) that
  redefines `bpm_audit_action_for_change` (add `'dead_letter_items'`
  alongside the existing `'dead_letter_queue'` branch) and
  `bpm_audit_resource_info` (`DROP FUNCTION IF EXISTS` + `CREATE OR
  REPLACE`, matching `GBL-121`'s own drop-then-create pattern since the
  `OUT resource_id` type changes from `UUID` to `TEXT`; add the
  `'dead_letter_items'` branch). Being a plain numeric file means
  `Migrations.runForSchema()` applies it to **every** schema —
  `tenant_default` included — the same convention `020`/`024`/`072`
  already use for exactly this reason. Harmless no-op re-application
  against `public` (already has the target shape from `GBL-121`).

DLQ store code (`src/dlq/store.zig`) and routes (`src/api/routes/dlq.zig`)
remain unchanged — confirmed correct by inspection and by the fact that once
Fix B lands, the `retry`/`discard` transactional UPDATE/DELETE statements
they already issue are exactly what the trigger needs to see to produce a
correct audit row. `dead_letter_items` itself (canonical home
`tenant_default` since `072_tnt01_rename_legacy_tables.sql`) is structurally
sound: `GBL-112` correctly drops only the legacy `public` shadow copies,
`GBL-116`/`GBL-123`/`GBL-130`/`GBL-131` correctly strip the stray
`tenant_id` column added transiently during the TNT migration sequence.
Total: 2 files, well within the ≤5 constraint.

## Public function signatures before/after

None new Zig function signatures. `bpm_audit_resource_info`'s SQL-level
`OUT resource_id` type changes from `UUID` to `TEXT` in every schema that
still had the stale shape (`tenant_default` and any `tenant_*` schema
provisioned before this fix) — this is the same signature `public` has had
since `GBL-121`, so no caller-visible behavior change for `public`, and for
`tenant_default` it corrects rather than introduces a mismatch (nothing in
`src/` calls this SQL function directly; only the trigger machinery does).

## Required change (structural, not literal diff)

In `tests/integration/obs05_dlq_test.zig`:

```
- "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1::uuid AND action = 'dlq.retry' AND actor_id = $2::uuid",
+ "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1 AND action = 'dlq.retry' AND actor_id = $2::uuid",
```

```
- "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1::uuid AND action = 'dlq.discard'",
+ "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1 AND action = 'dlq.discard'",
```

`actor_id = $2::uuid` is unchanged (correct — genuinely `UUID`-typed).

In `migrations/1139_iss0116_audit_dlq_rename_tenant_functions.sql` (new
file): `CREATE OR REPLACE FUNCTION bpm_audit_action_for_change(...)` adds
`OR table_name = 'dead_letter_items'` to the existing
`IF table_name = 'dead_letter_queue' THEN` branch; `DROP FUNCTION IF EXISTS
bpm_audit_resource_info(TEXT, JSONB, JSONB); CREATE OR REPLACE FUNCTION
bpm_audit_resource_info(...)` changes `OUT resource_id UUID` to `OUT
resource_id TEXT` (matching `GBL-121`) and adds an
`IF table_name = 'dead_letter_items' THEN` branch alongside the existing
`'dead_letter_queue'` branch.

## Callers / scripts impacted

None outside the one test file. `dlq_store.retry`, `dlq_store.discard`, and
the route handlers in `src/api/routes/dlq.zig` are unchanged — they do not
query `audit_entries` at all; they only set `bpm.actor_id`/
`bpm.audit_action` session config that the existing `AFTER INSERT` trigger
on `audit_entries`-writing paths already handles correctly.

## Incidental discovery — not fixed here

None found beyond what is already filed (ISS-0637/GH-619, ISS-0638/GH-621 —
both already resolved on `main` per `db68a6e` and prior queue history). No
new unrelated defect surfaced during this diagnosis.

## Verification expectations

TEST-RUNNER (Step 5) should confirm, via the two narrow steps added this run
(`zig build test-integration-obs05`, `zig build test-integration-obs06`) and
a broader `zig build test-integration` pass:

1. `TC-OBS-05-INT-01`, `TC-OBS-05-INT-02`, `TC-OBS-05-INT-03` all pass
   (3/3 in `obs05_dlq_test.zig`).
2. `TC-OBS-06-INT-05` (and the other 4 OBS-06 tests) continue to pass
   (5/5 in `obs06_alerts_test.zig`, no regression from this file being
   untouched).
3. No new failures introduced elsewhere in the suite by the two new narrow
   `build.zig` steps (additive only — no existing step's dependency graph
   is modified).

## Open questions

None blocking.
