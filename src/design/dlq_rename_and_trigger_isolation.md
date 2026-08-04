# DLQ rename and trigger isolation — design artefact

**Issue:** ISS-0123 (Workforce Fusion Platform / R-Co)
**GitHub:** https://github.com/tvolodi/R-Co/issues/389
**Diagnosis:** `docs/issue-reports/ISS-0123-root-cause.yaml`
**Run:** WF03-gh389-20260802 (WF-03 Step 2)
**Type:** E (novel / cross-cutting — schema drift + test isolation)
**Scope:** Production DLQ storage layer + engine task failure path + alert/observability paths + quota middleware + integration tests covering those paths.

## Module purpose

This design fixes two intertwined defects observed in the
`test-runner-step5c` integration log under run WF03-gh375-20260801:

- **Cluster A (P0001 audit-guard leak).** `tests/integration/obs05_dlq_test.zig`
  deliberately installs `bpm_test_fail_audit_insert()` /
  `trg_bpm_test_fail_audit_insert` on `audit_entries` to verify that
  `handleDiscard()` returns HTTP 500 when the audit append fails. The cleanup
  `defer` in that test only fires on the happy path; on the error path the
  trigger persists in `db_test` and leaks into the next test processes
  (`adp09_tamper_evident_audit_chain_test`, `oidc16_26_agent_lifecycle_foundations_test`),
  where it raises `P0001 audit_entries is immutable` via
  `bpm_audit_immutable_guard()` (migration `020_obs03_audit_entries.sql:48`) and
  `bpm_audit_on_mutation()` (line 43) on every legitimate mutation.
- **Cluster B (C42703 source_ref undefined_column).** `src/dlq/store.zig`,
  `src/engine/instance.zig`, `src/obs/alerts.zig`, `src/api/middleware/quota_enforcement.zig`,
  and the DLQ integration tests (`obs05_dlq_test.zig`, `obs06_alerts_test.zig`,
  `iss207_error_retry_test.zig`, `ext01_service_task_test.zig`,
  `ext03_plugin_integration_test.zig`, `exp601_tier_quota_test.zig`) all
  reference the legacy table name `dead_letter_queue`. Migration
  `072_tnt01_rename_legacy_tables.sql` already renamed the canonical table to
  `dead_letter_items` inside every tenant schema with `ALTER TABLE … RENAME …`
  (idempotent, IF EXISTS-guarded). Where the search_path resolves to a
  `dead_letter_queue` that still has the pre-021 column set — either a stale
  `public.dead_letter_queue` left behind when `GBL-073` was skipped because
  `onboarding_registry.migration_window_active = TRUE`, or a tenant schema
  where `021_obs05_dead_letter_context.sql` was never applied — PostgreSQL
  returns `42703 column "source_ref" of relation "dead_letter_queue" does not
  exist` (`column "item_type" of relation "dead_letter_queue" does not exist`)
  on every INSERT and the column-bearing SELECT.

The fix is internal: bring every Zig source reference into agreement with the
post-072 canonical name, wrap the deliberate audit-failure trigger setup in a
savepoint with unconditional cleanup, and add a regression lint so the
mismatch cannot recur.

## Public interface

All public function signatures in `src/dlq/store.zig` are **unchanged**. The
rename is purely a SQL table-reference change inside the bodies of the
existing functions. The same is true for `src/obs/alerts.zig`,
`src/api/middleware/quota_enforcement.zig`, and `src/engine/instance.zig`. The
existing public API surface is reproduced below for signature-stability
verification; no Zig code in any of these modules gains or loses a function.

### `src/dlq/store.zig` (unchanged signatures)

The six public store functions and their public helpers are listed below.
**No signature changes** — the rename is purely a SQL literal swap inside
each function body.

```zig
// Public types (structurally unchanged)
pub const DlqItemType = enum { SERVICE_TASK, WEBHOOK, TIMER };
pub const DlqStoreError = error{ PoolExhausted, PersistenceFailed,
    InvalidCursor, CursorExpired, InvalidFilter, ItemNotFound,
    InstanceCancelled, OutOfMemory };
pub const DlqRetryError = error{ ItemNotFound, InstanceNotFound,
    InstanceNotInError, RetryWithoutChange, InvalidInput, PoolExhausted,
    PersistenceFailed, OutOfMemory };

// Public functions
pub fn moveToDlq(alloc, pool, input) DlqStoreError!void;
pub fn list(alloc, pool, filters) DlqStoreError!ListResult;
pub fn retry(alloc, pool, actor_id, dlq_id) DlqStoreError!RetryResult;
pub fn discard(alloc, pool, actor_id, dlq_id, reason) DlqStoreError!DiscardResult;
pub fn retryConvergent(alloc, pool, actor_id, dlq_id) DlqRetryError!RetryConvergentResult;
pub fn retryWithInput(alloc, pool, actor_id, dlq_id, corrected_payload_json) DlqRetryError!RetryConvergentResult;
pub fn itemTypeToString(item_type: DlqItemType) []const u8;
pub fn itemTypeFromString(raw: []const u8) ?DlqItemType;
```

`MoveToDlqInput`, `DlqItem`, `ListFilters`, `ListResult`, `RetryResult`,
`RetryConvergentResult`, `DiscardResult` are also unchanged structurally.

### `src/obs/alerts.zig` (unchanged signatures)

```zig
pub fn readDlqDepth(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) AlertError!u64;

pub fn persistThresholdState(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    trigger_key: []const u8,
    is_armed: bool,
    last_sample_value: u64,
) AlertError!void;
```

The `readDlqDepth` body must change one SQL literal (see §Changes).

### `src/api/middleware/quota_enforcement.zig` (file-private helpers)

`maxColumn`, `countRowsWhereRecent`, `readUsageForDimension` are file-private.
The two `dead_letter_queue` literals inside them become `dead_letter_items`.
The string-table-name switch in `readUsageForDimension` (lines 156-157) must
also be updated so the quota dimension maps to the post-rename name.

### `src/engine/instance.zig`

The DLQ-writer fragment at line 3414 (inside the service-task completion path)
inserts into `dead_letter_queue` on retry exhaustion. The literal becomes
`dead_letter_items`. No function signature changes.

### Test integration surface

Test helper signatures in `tests/integration/obs05_dlq_test.zig`,
`tests/integration/obs06_alerts_test.zig`, `tests/integration/iss207_error_retry_test.zig`,
`tests/integration/ext01_service_task_test.zig`,
`tests/integration/ext03_plugin_integration_test.zig`,
`tests/integration/exp601_tier_quota_test.zig` are unchanged. The
`insertDlqRow` helpers take a `Conn` and execute prepared SQL — only the
literal `dead_letter_queue` inside the helper body changes.

## Error taxonomy

**No new error variants are introduced.** The fix is a literal-for-literal
table-name swap. Existing error sets are unchanged:

- `src/dlq/store.zig` — `DlqStoreError`, `DlqRetryError` unchanged.
- `src/obs/alerts.zig` — `AlertError` unchanged.
- `src/api/middleware/quota_enforcement.zig` — `QuotaMiddlewareError` unchanged.
- `src/engine/instance.zig` — `CompleteTaskError` unchanged.

The Cluster A P0001 raise is **expected** in TC-OBS-05-INT-03 (the test
deliberately installs the failing trigger to verify the 500 path). The fix
ensures the trigger is cleaned up before the next test process acquires a
pool connection, so the raise stops being a leak.

## Data flow

Renames only, no new data movement. Three producer paths converge on the
canonical tenant-schema table; two reader paths consume from it; the test
isolation path uses a savepoint so the `audit_entries` failure trigger cannot
leak across test processes.

**Writers (Cluster B):**

- `src/engine/instance.zig:3414` — service-task retry-exhausted path INSERTs.
- `src/dlq/store.zig:148` — `moveToDlq` INSERT (with `ON CONFLICT (item_type, source_ref, last_failed_at) DO NOTHING`).
- `src/dlq/store.zig:262, 361, 408, 416, 428, 461, 511, 625, 691, 746` — `list`, `retry`, `discard`, `retryConvergent`, `retryWithInput` SELECT/UPDATE/DELETE statements.

All writers target the tenant-schema `dead_letter_items` table after the rename.

**Reader / quota:**

- `src/obs/alerts.zig:188` — `readDlqDepth` SELECT COUNT(*) for `dlq_depth_threshold` alerts.
- `src/api/middleware/quota_enforcement.zig:156, 157, 216, 217, 277, 286` — `maxColumn` / `countRowsWhereRecent` arms for `agent_retry_per_job` / `agent_retry_per_day` quota dimensions.

**Test isolation (Cluster A):**

TC-OBS-05-INT-03 (`obs05_dlq_test.zig:427-449`) wraps the
`bpm_test_fail_audit_insert` trigger install inside a SAVEPOINT named
`s_audit_failure`. The `errdefer` block rolls back the savepoint on any
early return, ensuring the trigger is gone before the next test process
acquires a pool connection. The next test (`adp09`, `oidc22`) is then
guaranteed to see a clean `audit_entries` with no `trg_bpm_test_fail_audit_insert`.

## Files to change

### Production code

| File | Lines | Change |
|---|---|---|
| `src/dlq/store.zig` | 148 | `INSERT INTO dead_letter_queue` → `INSERT INTO dead_letter_items` (in `moveToDlq`). |
| `src/dlq/store.zig` | 262 | `FROM dead_letter_queue` → `FROM dead_letter_items` (`list` SELECT). |
| `src/dlq/store.zig` | 361 | `FROM dead_letter_queue` → `FROM dead_letter_items` (`retry` lock SELECT). |
| `src/dlq/store.zig` | 408, 416, 428 | `DELETE FROM dead_letter_queue` → `DELETE FROM dead_letter_items` (`retry` discard branch). |
| `src/dlq/store.zig` | 461 | `UPDATE dead_letter_queue` → `UPDATE dead_letter_items` (`retry` retrying branch). |
| `src/dlq/store.zig` | 511 | `DELETE FROM dead_letter_queue` → `DELETE FROM dead_letter_items` (`discard` returning id). |
| `src/dlq/store.zig` | 625 | `FROM dead_letter_queue` → `FROM dead_letter_items` (`retryConvergent` lock SELECT). |
| `src/dlq/store.zig` | 691 | `UPDATE dead_letter_queue` → `UPDATE dead_letter_items` (`retryConvergent` retrying branch). |
| `src/dlq/store.zig` | 746 | `FROM dead_letter_queue` → `FROM dead_letter_items` (`retryWithInput` lock SELECT). |
| `src/obs/alerts.zig` | 188 | `SELECT COUNT(*)::text FROM dead_letter_queue WHERE status IN ('pending','retrying')` → same with `dead_letter_items`. |
| `src/api/middleware/quota_enforcement.zig` | 156, 157 | String literals passed to `maxColumn` / `countRowsWhereRecent`: `"dead_letter_queue"` → `"dead_letter_items"`. |
| `src/api/middleware/quota_enforcement.zig` | 216, 217 | Branch selector `eql(u8, table_name, "dead_letter_queue")` and the embedded SQL literal: both reference `dead_letter_items`. |
| `src/api/middleware/quota_enforcement.zig` | 277, 286 | Branch selector `eql(u8, table_name, "dead_letter_queue")` and the embedded SQL literal: both reference `dead_letter_items`. |
| `src/engine/instance.zig` | 3414 | `INSERT INTO dead_letter_queue` → `INSERT INTO dead_letter_items` (service-task retry-exhausted path). |

### Test code

| File | Lines | Change |
|---|---|---|
| `tests/integration/obs05_dlq_test.zig` | 33, 37 | `cleanupDlqBySourceRef` and `cleanupInstance` helper bodies: `DELETE FROM dead_letter_queue` → `DELETE FROM dead_letter_items`. |
| `tests/integration/obs05_dlq_test.zig` | 73 | `insertDlqRow` helper body: `INSERT INTO dead_letter_queue` → `INSERT INTO dead_letter_items`. |
| `tests/integration/obs05_dlq_test.zig` | 234, 344, 357, 459 | Inline `SELECT`/`DELETE` against `dead_letter_queue` → `dead_letter_items`. |
| `tests/integration/obs05_dlq_test.zig` | 427–449 (TC-OBS-05-INT-03) | Wrap `bpm_test_fail_audit_insert` install/uninstall in a savepoint. See §Test design below. |
| `tests/integration/obs06_alerts_test.zig` | 32, 56 | `cleanupDlqBySourceRef` and `insertDlqRow` helpers: `dead_letter_queue` → `dead_letter_items`. |
| `tests/integration/iss207_error_retry_test.zig` | 11, 92, 175, 213, 268, 297 | All references to `dead_letter_queue` → `dead_letter_items`. |
| `tests/integration/ext01_service_task_test.zig` | 109, 852 | `dead_letter_queue` → `dead_letter_items`. |
| `tests/integration/ext03_plugin_integration_test.zig` | 139 | `dead_letter_queue` → `dead_letter_items`. |
| `tests/integration/exp601_tier_quota_test.zig` | 172 | `dead_letter_queue` → `dead_letter_items`. |

### Migration / schema reconciliation

**No migration is added.** The rename already exists
(`migrations/072_tnt01_rename_legacy_tables.sql`) and is idempotent:

```sql
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'dead_letter_queue'
    ) THEN
        ALTER TABLE dead_letter_queue RENAME TO dead_letter_items;
    END IF;
    -- (form_schema_registry → repository_form_schemas is in the same file)
END $$;
```

The companion cleanup `migrations/GBL-073_tnt01_drop_legacy_public_business_tables.sql`
drops the legacy `public.dead_letter_queue` (and `public.dead_letter_items`)
provided `public.onboarding_registry.migration_window_active` is `FALSE`. If
`migration_window_active` is `TRUE`, GBL-073 emits a NOTICE and skips the
DROP (lines 39-41), leaving a stale `public.dead_letter_queue` with the
pre-021 column set that causes C42703 in the active DB.

**Reconciliation policy (test environments):** if
`migrations/GBL-073_tnt01_drop_legacy_public_business_tables.sql` was skipped,
the operator must set `public.onboarding_registry.migration_window_active = FALSE`
and re-run `zig build migrate`. In dev/CI, the flag is already `FALSE`, so the
drops proceed. Once the public schema is clean, every remaining `dead_letter_queue`
literal resolves to a `dead_letter_items` table in the tenant schema.

**No backfill is needed.** The post-021 column set on `dead_letter_items` is
the canonical set; the only reason C42703 fires is that the code is hitting
the pre-021 shadow. After the rename + drop, no shadow exists.

### Lint / prevention

Add a new linter at `tools/lint_sql_table_refs.py` (or extend an existing
script) that walks `src/**/*.zig` and `tests/integration/**/*.zig` and fails
the build if any of the legacy table names appear in non-migration, non-design
content:

- `dead_letter_queue`
- `form_schema_registry`
- `audit_log`

The lint must allow these names in `migrations/**/*.sql` and
`src/design/**/*.md` (the design artefact that documents the rename is the
one canonical place these names should appear). The reporter must emit a
file:line and the literal found.

Hook the lint into `build.zig` as a pre-test step so `zig build test`
fails fast before the DB is touched.

## Migration reconciliation summary

| Migration | Effect on `dead_letter_queue` | Idempotent? |
|---|---|---|
| `021_obs05_dead_letter_context.sql` | Adds `item_type`, `retry_limit`, `original_payload`, `error_chain`, `processor_metadata`, `first_failed_at`, `last_failed_at`, `source_ref` to `dead_letter_queue` (later renamed to `dead_letter_items`). Backfills `UPDATE … SET item_type = CASE entry_type …` for existing rows. | Yes (`ADD COLUMN IF NOT EXISTS`, `UPDATE WHERE … IS NULL`). |
| `072_tnt01_rename_legacy_tables.sql` | `ALTER TABLE dead_letter_queue RENAME TO dead_letter_items` inside the tenant schema. | Yes (`IF EXISTS` guard). |
| `GBL-073_tnt01_drop_legacy_public_business_tables.sql` | `DROP TABLE IF EXISTS public.dead_letter_queue CASCADE` and `public.dead_letter_items CASCADE`. Skipped if `migration_window_active = TRUE`. | Yes (`DROP TABLE IF EXISTS`). |

The canonical name in every schema after a clean migration run is
`dead_letter_items`. No stub view, no synonym, no alias is left behind.

## Test design

### Cluster B — verify the rename

The fix is verified by the existing integration tests once the table
references match the canonical name. The following TCs must pass:

| Test ID | File | What it verifies |
|---|---|---|
| TC-OBS-05-INT-01 | `tests/integration/obs05_dlq_test.zig` (lines 187-275) | `moveToDlq` INSERT (3×) into `dead_letter_items` succeeds; `handleList` returns 200 with correct pagination/filter semantics; worker role is forbidden; operator role reads both pages. |
| TC-OBS-05-INT-02 | `tests/integration/obs05_dlq_test.zig` (lines 277-368) | `INSERT INTO dead_letter_items` from `insertDlqRow` succeeds; `handleRetry` returns 409 for cancelled instance, 202 for active; retry audit appended to `audit_entries`; row deleted from `dead_letter_items`. |
| TC-OBS-05-INT-03 | `tests/integration/obs05_dlq_test.zig` (lines 370-471) | `handleDiscard` returns 200 happy path; audit appended; deliberate audit-failure trigger raises P0001; `handleDiscard` returns 500; DLQ row remains in `dead_letter_items` (rollback). |
| TC-OBS-06-INT-05 | `tests/integration/obs06_alerts_test.zig` (lines 588-621 in the per-test file) | `INSERT INTO dead_letter_items` from `insertDlqRow` succeeds; `readDlqDepth` returns baseline + 2 (pending + retrying, not discarded); `persistThresholdState` writes `obs_alert_trigger_state` correctly. |

The other DLQ-related tests must also pass after the rename:

| Test ID | File | Notes |
|---|---|---|
| TC-ISS-207 | `tests/integration/iss207_error_retry_test.zig` (lines 11, 92, 175, 213, 268, 297) | Tests the convergent retry path against `dead_letter_items`. |
| TC-EXT-01 | `tests/integration/ext01_service_task_test.zig` (lines 109, 852) | Service-task failure fields named against `dead_letter_items`. |
| TC-EXT-03 | `tests/integration/ext03_plugin_integration_test.zig` (line 139) | Plugin integration references `dead_letter_items`. |
| TC-EXP-601 | `tests/integration/exp601_tier_quota_test.zig` (line 172) | Tier quota fixtures reference `dead_letter_items`. |

### Cluster A — verify the trigger isolation

The `obs05_dlq_test.zig` TC-OBS-05-INT-03 trigger install at lines 427-449
must be converted to a savepoint with unconditional cleanup. The proposal:

```zig
// Before line 427 (or right after dlq_ids are inserted and `defer cleanupDlqBySourceRef` is wired):
conn.exec("SAVEPOINT s_audit_failure", &.{}) catch return error.PersistenceFailed;
errdefer conn.exec("ROLLBACK TO SAVEPOINT s_audit_failure", &.{}) catch {};

// ... existing trigger install at lines 427-449 ...

conn.exec("RELEASE SAVEPOINT s_audit_failure", &.{}) catch return error.PersistenceFailed;
```

The `errdefer` ensures the trigger is rolled back even if the test returns
early. The existing happy-path `defer` at lines 448-449 is removed (its job
is now done by the savepoint rollback) so that the trigger cannot leak
into the next test process even if the test exits via the `fail_result`
branch.

Verification steps (executed in CI after the design is implemented):

1. `tests/integration/obs05_dlq_test.zig` TC-OBS-05-INT-03 passes.
2. `tests/integration/adp09_tamper_evident_audit_chain_test.zig` TC-ADP-09-01
   passes — its INSERT into `audit_entries` no longer raises P0001 because
   `trg_bpm_test_fail_audit_insert` is rolled back at the end of the
   preceding test.
3. `tests/integration/oidc16_26_agent_lifecycle_foundations_test.zig`
   TC-OIDC-22-01 passes for the same reason.

### New regression tests (mandatory)

Two new regression tests are added to harden the fix:

1. **Regression test for Cluster B** under
   `tests/integration/obs05_dlq_regression_table_name_test.zig` (new file):

   ```zig
   test "regression: ISS-0123 — production DLQ code targets dead_letter_items" {
       // Source-level assertion: every src/**/*.zig reference to dead_letter_queue
       // has been removed. Catch the drift if the rename is undone.
       const allocator = testing.allocator;
       var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
       defer dir.close();
       var walker = try dir.walk(allocator);
       defer walker.deinit();
       var buf: [4096]u8 = undefined;
       while (try walker.next()) |entry| {
           if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
           const contents = try entry.dir.readFile(entry.basename, &buf);
           if (std.mem.indexOf(u8, contents, "dead_letter_queue") != null) {
               std.debug.print("src/legacy reference: {s}\n", .{entry.path});
               return error.TestUnexpectedResult;
           }
       }
   }
   ```

   (The walker call above is illustrative — the actual test may use
   `std.fs.cwd().walk` or a one-shot `readFile` of the targeted files.
   The structural intent is: a source-assertion regression test that fails
   if the legacy literal returns.)

2. **Regression test for Cluster A** appended to
   `tests/integration/obs05_dlq_test.zig` after TC-OBS-05-INT-03:

   ```zig
   test "regression: ISS-0123 — audit-failure trigger is rolled back on test exit" {
       // TestHarness order: run after TC-OBS-05-INT-03.
       // Acquire a fresh pool connection, INSERT INTO audit_entries.
       // If the trigger leaked, this raises P0001 'forced audit insert failure
       // for test'. With the savepoint wrapper, the trigger is gone and the
       // INSERT succeeds.
       const alloc = testing.allocator;
       const url = try testDbUrl(alloc);
       defer alloc.free(url);
       var pool = try makePool(alloc, url);
       defer pool.deinit();
       const conn = try pool.acquire();
       defer pool.release(conn);
       try conn.exec(
           "INSERT INTO audit_entries (actor_id, action, resource_type, resource_id, before_state, after_state) "
           "VALUES ('00000000-0000-0000-0000-000000000001'::uuid, 'regression.iss0123', 'dlq', NULL, NULL, NULL)",
           &.{},
       );
   }
   ```

Both tests are non-DEFERRED (must run, not skip when `BPM_TEST_DB_URL` is set).

### Pipeline-level sanity

The DLQ test path is a sequentially-dependent journey (insert → list →
retry → discard → audit-trigger fail → rollback). There is no Playwright
pipeline test that exercises this directly; the integration tests are the
canonical coverage. The new `regression: ISS-0123` tests can be added to
the existing `tests/specs/` listing or as a new `tests/specs/ISS-0123.md`.

## Dependencies and risks

### Modules that call into the changed code

- `src/api/dlq_routes.zig` — calls `dlq_store.moveToDlq`, `dlq_store.list`,
  `dlq_store.retry`, `dlq_store.discard`, `dlq_store.retryConvergent`,
  `dlq_store.retryWithInput`. Public API unchanged; no signature drift.
- `src/obs/alerts.zig` — calls `db.Pool` directly from `readDlqDepth` /
  `persistThresholdState`. Internal SQL change only.
- `src/api/middleware/quota_enforcement.zig` — calls `maxColumn` /
  `countRowsWhereRecent` with table name as a string parameter. The string
  is updated alongside the SQL literals.
- `src/engine/instance.zig` — service-task retry-exhausted write path.
  Internal SQL change only.

### Test paths that exercise the changed code

Beyond the tests listed in the diagnosis (`obs05_dlq_test.zig`,
`obs06_alerts_test.zig`), the following tests also reference
`dead_letter_queue` and must be updated for consistency:

- `tests/integration/iss207_error_retry_test.zig` (6 sites)
- `tests/integration/ext01_service_task_test.zig` (2 sites)
- `tests/integration/ext03_plugin_integration_test.zig` (1 site)
- `tests/integration/exp601_tier_quota_test.zig` (1 site)

These tests will fail with C42703 in the same way unless the rename is
applied uniformly. The fix design applies the rename to all of them.

### Risks

1. **search_path drift.** If a tenant schema still has `dead_letter_queue`
   (because `021_obs05_dead_letter_context.sql` was applied AFTER
   `072_tnt01_rename_legacy_tables.sql` on a fresh schema and the IF EXISTS
   guard in 072 found nothing to rename), the production code path
   (post-rename) will fail with `relation "dead_letter_items" does not exist`.
   Mitigation: `021_obs05_dead_letter_context.sql` must come BEFORE
   `072_tnt01_rename_legacy_tables.sql` in the migration order. The
   `migrations/` numbering already enforces this (021 < 072). Verify via
   `SELECT migration_number FROM public.schema_migrations ORDER BY
   migration_number` during the test infrastructure health check.
2. **Stale `public.dead_letter_queue`.** If `GBL-073` was skipped because
   `migration_window_active = TRUE`, the legacy public copy remains with
   the pre-021 column set. The tenant schema's `dead_letter_items` is
   unaffected, but any test or middleware that resolves the table through
   `public` first will see C42703. Mitigation: ensure
   `migration_window_active = FALSE` in test environments (CI does this
   by default) and re-run `zig build migrate` to apply GBL-073.
3. **Audit trigger still leaks if savepoint is wrong.** If the savepoint
   implementation uses `BEGIN` instead of `SAVEPOINT`, the rollback only
   fires on the test process's exit, not at the end of the test logical
   block. Mitigation: the regression test (`regression: ISS-0123 — audit-
   failure trigger is rolled back on test exit`) catches this by attempting
   a clean INSERT INTO `audit_entries` after TC-OBS-05-INT-03 returns.
4. **Cascade on a stale public.dead_letter_queue.** `GBL-073` drops
   `public.dead_letter_queue CASCADE` and `public.dead_letter_items CASCADE`
   in the same `DO` block. If any live application held a prepared
   statement on the public copy, the drop will drop-and-recreate the
   prepared statement on next use. Acceptable in test environments.

### Migration backfill / data reconciliation

**None required.** The canonical data lives in `dead_letter_items` after
the 072 rename. The pre-072 `dead_letter_queue` was the same table with a
different name; the rename preserved all rows and column data. The only
data at risk is in the stale `public.dead_letter_queue` (pre-021 columns),
which is dropped by GBL-073 in test environments. No replication, no
backfill, no compensating write.

## Acceptance criteria

These mirror `docs/issue-reports/ISS-0123-root-cause.yaml` §acceptance_criteria
with the design-side additions (regression tests + lint hook).

1. `src/dlq/store.zig` contains zero references to `dead_letter_queue` after
   the rename (verified by `rg -n dead_letter_queue src/dlq/store.zig`
   returning no hits).
2. `src/obs/alerts.zig`, `src/api/middleware/quota_enforcement.zig`,
   `src/engine/instance.zig` contain zero references to `dead_letter_queue`.
3. `tests/integration/obs05_dlq_test.zig`, `tests/integration/obs06_alerts_test.zig`,
   `tests/integration/iss207_error_retry_test.zig`,
   `tests/integration/ext01_service_task_test.zig`,
   `tests/integration/ext03_plugin_integration_test.zig`,
   `tests/integration/exp601_tier_quota_test.zig` contain zero references to
   `dead_letter_queue`.
4. Tests TC-OBS-05-INT-01, TC-OBS-05-INT-02, TC-OBS-05-INT-03, TC-OBS-06-INT-05
   pass with `BPM_TEST_DB_URL` set. No C42703 `column "source_ref" does not
   exist` is observed in `tests/reports/`.
5. `tests/integration/obs05_dlq_test.zig` TC-OBS-05-INT-03 installs the
   `trg_bpm_test_fail_audit_insert` trigger inside a SAVEPOINT and releases
   the savepoint (or rolls back on early return). The existing happy-path
   `defer` is replaced by the savepoint `errdefer` so cleanup is
   unconditional.
6. `tests/integration/adp09_tamper_evident_audit_chain_test.zig` TC-ADP-09-01
   passes (no P0001 leak from the obs05 trigger).
7. `tests/integration/oidc16_26_agent_lifecycle_foundations_test.zig`
   TC-OIDC-22-01 passes (no P0001 leak from the obs05 trigger).
8. New regression test `regression: ISS-0123 — production DLQ code targets
   dead_letter_items` (source-assertion) passes.
9. New regression test `regression: ISS-0123 — audit-failure trigger is
   rolled back on test exit` passes.
10. `tools/lint_sql_table_refs.py` (or extended existing linter) fails the
    build if any of `dead_letter_queue`, `form_schema_registry`, `audit_log`
    appear in `src/**/*.zig` or `tests/integration/**/*.zig` outside
    `migrations/` and `src/design/`.
11. `python tools/lint_design_artefact.py src/design/dlq_rename_and_trigger_isolation.md`
    exits 0 with no BLOCKER/MAJOR.
12. `zig build` exits 0; `zig build test` exits 0; `zig build
    test-integration-tm` exits 0 with BPM_TEST_DB_URL set.
13. `docs/issue-reports/ISS-0123-root-cause.yaml` is referenced in the
    CHANGELOG entry written by DOC-UPDATER (no edit here, design states
    the handoff dependency).

## Open questions

None. The diagnosis is unambiguous: a literal-for-literal rename with a
trigger-isolation fix. If the savepoint pattern is rejected by the
`db.Pool` API (e.g. nested transactions not supported), the fallback is
to drop the trigger via a `defer` registered at the very top of the test
function (before any code that can panic or return early). BACKEND-DEV
must verify the pool API supports `SAVEPOINT` / `RELEASE SAVEPOINT` /
`ROLLBACK TO SAVEPOINT` before choosing the savepoint path; if not, the
defer-from-top pattern is the documented fallback.
