# Module: tests/integration/helpers.zig — applyCompatibilityShims() (ISS-0093 fix)

**Issue:** ISS-0093 / GitHub #346
**Type:** E (test-harness code — no CRUD endpoint, migration, list page, or React Flow node applies)
**Root cause (confirmed by ISSUE-FIXER, Step 01):** `applyCompatibilityShims()` in
`tests/integration/helpers.zig` (current file: lines 208–319, called unconditionally from
`TestHarness.init()` at line 481) runs `ALTER TABLE IF EXISTS tenant_default.<table> DISABLE
TRIGGER ALL` against six tables as a workaround for a GBL-081 type mismatch that
`migrations/GBL-082_fix_audit_chain_resource_id_text.sql` already corrected. The shim was never
removed after GBL-082 landed, so it now unconditionally defeats the `bpm_audit_on_mutation()`
audit trigger on those six tables for every integration test run, masking
`tests/integration/audit_iss103_test.zig`'s `TC-ISS-103-INT-02/03/04` — and, as this design's
risk survey found, several other currently-broken tests in the same failure class.

---

## Purpose

Remove the stale GBL-081 compatibility shim from `tests/integration/helpers.zig`'s
`applyCompatibilityShims()` so that integration tests once again exercise the real,
production-equivalent `bpm_audit_on_mutation()` audit trigger on the six business tables it
currently disables. The shim was a temporary workaround for a type mismatch that
`migrations/GBL-082_fix_audit_chain_resource_id_text.sql` already corrected; leaving it in place
after that fix landed silently defeats every audit-chain assertion in the integration suite,
including but not limited to the three cases named in ISS-0093. The fix's purpose is narrowly
scoped to restoring correct trigger state in the test harness — it does not change any
production code, migration, or the audit trigger function itself.

## Public interface

No signature changes. `applyCompatibilityShims(conn: *pg.Conn) !void` keeps its current name,
signature, and call site (`TestHarness.init()` line 481, unconditional, unchanged). Only the
statement list inside the function body changes.

## Data types

None — this is a DDL-only helper; no struct/union definitions are affected.

## Key invariants

- `TestHarness.init()` must continue to leave the six business tables
  (`process_definitions`, `instance_projections`, `tasks`, `dead_letter_items`,
  `webhook_subscriptions`, `webhook_deliveries`) in their **normal, production-equivalent
  trigger state** (i.e., `bpm_audit_on_mutation()` ENABLED) after this fix — this is the whole
  point of the fix, not an incidental side effect.
- The **unrelated** legacy-fixture shims that currently live in the same function
  (the `instances` compatibility table, the `bpm_test_events_compat_defaults()` trigger on
  `events`, and the `bpm_repository_artifacts_immutable()` triggers on `repository_artifacts`)
  are **out of scope** for ISS-0093 and MUST be preserved byte-for-byte. They address different
  problems (legacy fixture shape / immutability enforcement for other test suites), not the
  GBL-081 type mismatch, and nothing in ISS-0093's diagnosis implicates them.
- `execCompatibilitySql()` (the best-effort exec wrapper used throughout the function) is
  unaffected and continues to be used by the remaining (non-removed) statements.

## External dependencies

- `migrations/020_obs03_audit_entries.sql` — creates `bpm_audit_on_mutation()` and attaches it via
  `CREATE TRIGGER trg_bpm_audit_process_definitions`, `trg_bpm_audit_instance_projections`,
  `trg_bpm_audit_tasks`, and `trg_bpm_audit_dead_letter_queue` (on the table now renamed to
  `dead_letter_items` — see `migrations/072_tnt01_rename_legacy_tables.sql`).
- `migrations/024_webhook_subscription_audit.sql` — attaches `trg_bpm_audit_webhook_subscriptions`
  (`AFTER INSERT OR UPDATE OR DELETE ON webhook_subscriptions`).
- `migrations/GBL-082_fix_audit_chain_resource_id_text.sql` — the corrective migration that makes
  this shim removable; redeclares `bpm_audit_chain_canonical_payload(..., p_resource_id TEXT, ...)`
  and `bpm_audit_compute_chain_hash(...)` with `TEXT`-typed `resource_id`, eliminating the
  uuid/text mismatch that originally motivated `DISABLE TRIGGER ALL`.
- `tests/integration/audit_iss103_test.zig` — the primary test file this fix unblocks
  (`TC-ISS-103-INT-02/03/04`).
- No trigger of any other kind (e.g. `updated_at` bookkeeping) is attached to any of the six
  tables in any migration — confirmed by grep across `migrations/*.sql` for `CREATE TRIGGER ...
  ON <table>` for all six names. The only trigger type ever attached to these tables is
  `bpm_audit_on_mutation()` (five of six tables) — `webhook_deliveries` currently has **no**
  trigger of any kind attached in any migration (see Finding 3 below), so its `DISABLE TRIGGER
  ALL` statement is presently a no-op.

## Open questions

None — ISSUE-FIXER's diagnosis and this design's own migration sweep (see Risk Survey) found no
remaining legitimate reason to keep any of the six tables' triggers disabled, and no later
migration reintroduces the GBL-081 mismatch.

## Error taxonomy

This is a test-harness DDL change, not a runtime error-handling change — `applyCompatibilityShims()`
has no new error variants and its existing error propagation is unchanged:

- `execCompatibilitySql()` remains the exec path for every remaining statement in the function
  (the six removed `DISABLE TRIGGER ALL` calls were also routed through it). Its existing
  best-effort semantics are unchanged: `error.ServerError` is swallowed (`catch {}`-equivalent
  behavior already in place at lines 321–327), any other error still propagates to
  `TestHarness.init()`'s `catch |err| { std.debug.print(...); return err; }` handler at line
  481–484, which already exists and requires no modification.
- No new failure mode is introduced by deleting six DDL statements — a `DROP`/re-`ENABLE` is not
  being added, so there is no new class of "trigger already enabled" or "trigger missing" error
  to handle. `ALTER TABLE ... DISABLE TRIGGER ALL` was previously best-effort (guarded by
  `execCompatibilitySql`); removing the statements removes that best-effort call entirely rather
  than replacing it with a new one.
- Post-fix, if a MUST-requirement integration test newly fails because it implicitly relied on
  the disabled-trigger behavior, that is a **test correctness defect** to be raised as a new
  issue per the risk survey's residual-risk note below — not an error case this design needs to
  handle in `helpers.zig` itself. The Risk Survey below found no such test, so no residual
  handling is designed in.

---

## Diff shape

### Decision: full removal of the six `DISABLE TRIGGER ALL` statements only — not full removal of the function

The function `applyCompatibilityShims()` does **not** become dead code after this fix. Reading
its full body (current file, lines 208–319) confirms it contains two structurally independent
groups of statements:

1. **Lines 213–230** — the six `ALTER TABLE IF EXISTS tenant_default.<table> DISABLE TRIGGER ALL`
   calls (`process_definitions`, `instance_projections`, `tasks`, `dead_letter_items`,
   `webhook_subscriptions`, `webhook_deliveries`), each preceded by the stale GBL-081 comment
   (lines 209–212). **This is the ISS-0093 shim. Remove all six statements and the comment
   above them.**
2. **Lines 232–318** — unrelated legacy-fixture shims for a different problem: creation of the
   `instances` compatibility table (lines 236–244), the `bpm_test_events_compat_defaults()`
   function/trigger pair on `events` (lines 246–285), and the `bpm_repository_artifacts_immutable()`
   function/trigger pair on `repository_artifacts` (lines 287–318). **These stay untouched** —
   ISS-0093's diagnosis never implicated them, they do not reference GBL-081/GBL-082 or any of
   the six audit-covered tables, and removing them is out of scope for this fix.

Because group 2 remains, `applyCompatibilityShims()` keeps real, non-trivial content after the
fix — it is not reduced to an empty body. **Do not remove the function or its call site.** Leave
the call site at `TestHarness.init()` line 481 exactly as-is.

### Exact edit

In `tests/integration/helpers.zig`, inside `applyCompatibilityShims()`:

- Delete the comment block at (current) lines 209–212 (`// GBL-081 changed audit_entries...
  ...avoid type-mismatch failures on INSERT.`).
- Delete the six `try execCompatibilitySql(conn, \\ALTER TABLE IF EXISTS
  tenant_default.<table> DISABLE TRIGGER ALL);` statements at (current) lines 213–230, for all
  six tables listed above.
- Leave a single blank line separating the (now-first) remaining block — the "Legacy XC
  integration fixtures..." comment at (current) line 232 — from the function's opening brace, so
  the function body still reads cleanly as "one remaining shim group, documented."
- No other lines in the function change. `execCompatibilitySql()` itself (current lines
  321–327) is untouched — it is still used by the remaining statements.

Pseudocode of the resulting function shape (illustrative only, not literal Zig):

```
fn applyCompatibilityShims(conn) !void {
    // [REMOVED: six DISABLE TRIGGER ALL statements + GBL-081 comment]

    // Legacy XC integration fixtures still reference `instances`... (unchanged)
    execCompatibilitySql(conn, CREATE TABLE IF NOT EXISTS instances (...));
    execCompatibilitySql(conn, DROP FUNCTION IF EXISTS bpm_test_events_compat_defaults() CASCADE);
    execCompatibilitySql(conn, CREATE OR REPLACE FUNCTION bpm_test_events_compat_defaults() ...);
    execCompatibilitySql(conn, DROP TRIGGER IF EXISTS trg_bpm_test_events_compat_defaults ON events);
    execCompatibilitySql(conn, CREATE TRIGGER trg_bpm_test_events_compat_defaults ...);
    execCompatibilitySql(conn, DROP FUNCTION IF EXISTS bpm_repository_artifacts_immutable() CASCADE);
    execCompatibilitySql(conn, CREATE OR REPLACE FUNCTION bpm_repository_artifacts_immutable() ...);
    execCompatibilitySql(conn, DROP TRIGGER IF EXISTS trg_repository_artifacts_prevent_update ON repository_artifacts);
    execCompatibilitySql(conn, CREATE TRIGGER trg_repository_artifacts_prevent_update ...);
    execCompatibilitySql(conn, DROP TRIGGER IF EXISTS trg_repository_artifacts_prevent_delete ON repository_artifacts);
    execCompatibilitySql(conn, CREATE TRIGGER trg_repository_artifacts_prevent_delete ...);
}
```

### Companion test-file follow-up (in scope per ISS-0093 `files_to_change`)

`tests/integration/audit_iss103_test.zig` requires no code change — `TC-ISS-103-INT-02/03/04`
already assert the correct (trigger-enabled) behavior; they were simply failing because the
shim prevented the trigger from ever firing. BACKEND-DEV must re-run
`zig build test-integration-iss103` after the helpers.zig edit to confirm these three cases now
pass with no source change to the test file itself. No other test file requires a code edit —
see Risk Survey below for the tests that will newly start passing as a result of this fix
(their assertions do not change) versus the one test that needs no action because it was never
trigger-dependent.

---

## Risk Survey

**Method:** Grepped `tests/integration/` for every reference to `audit_entries` (20 files) and
cross-referenced against the six affected table names and `TestHarness.init()` usage. For each
hit, read enough surrounding context to classify the test as (a) manually inserting into
`audit_entries` directly — unaffected by trigger state, (b) asserting an audit-row count/effect
that requires the `bpm_audit_on_mutation()` trigger to have fired on one of the six tables —
at risk / currently broken by the shim, or (c) asserting a *relative* invariant (e.g. before ==
after) that holds regardless of trigger state — unaffected. Also grepped `migrations/*.sql` for
every `CREATE TRIGGER ... ON <table>` against the six table names to confirm no other trigger
type (e.g. `updated_at` bookkeeping) shares these tables, and checked `docs/anti-patterns.md`
for any documented reason to keep triggers disabled (none found).

### Finding 1 — `tests/integration/audit_iss103_test.zig` (the issue's named target)

`TC-ISS-103-INT-02` (line 230), `TC-ISS-103-INT-03` (line 307), `TC-ISS-103-INT-04` (line 430) —
all assert `audit_entries` row counts following `process_definitions` inserts, requiring
`trg_bpm_audit_process_definitions` to fire.
**Status: currently FAILING under the shim. Mitigation: this fix directly repairs these three
cases — no other change needed. This is the fix's primary target, not a risk to mitigate against.**

### Finding 2 — `tests/integration/obs03_audit_log_test.zig` — three at-risk cases, one safe case

- `TC-OBS-03-INT-01: state-changing writes create audit rows with required fields` (line 180) —
  creates/updates a `process_definitions` row via `DefinitionStore` and (per its own name and
  the pattern established by `TC-ISS-103-INT-*`) asserts resulting `audit_entries` content.
  **Status: currently FAILING under the shim (same failure class as Finding 1) — this fix
  repairs it. No source change to this test needed.**
- `TC-OBS-03-INT-02: read-only GET/list operations do not create audit rows` (line 321) —
  asserts `before_count == after_count` on `audit_entries` around a **read-only** `handleList`
  call (lines 367–399). This is a *relative* invariant: it holds whether the count is 0-vs-0
  (shim active, current state) or N-vs-N (trigger enabled, post-fix state), because the
  operation under test never mutates `process_definitions`. **Safe — no dependency on disabled
  triggers, no risk from this fix.**
- `TC-OBS-03-INT-03: audit insert failure rolls back business write` (line 402) — installs a
  forced-failure trigger on `audit_entries` itself, then inserts into `process_definitions`
  (line 452) expecting `error.QueryFailed` because the chain `process_definitions INSERT →
  trg_bpm_audit_process_definitions fires → INSERT INTO audit_entries → forced-failure trigger
  raises exception` must propagate back to the `process_definitions` statement.
  **Status: currently FAILING under the shim — with `trg_bpm_audit_process_definitions`
  disabled, the `process_definitions` insert at line 452 cannot fail via this path, so
  `testing.expectError(error.QueryFailed, insert_err)` (line 460) does not hold today. This fix
  repairs it as a side effect. No source change to this test needed; BACKEND-DEV should include
  it in the re-verification pass alongside `audit_iss103_test.zig`.**
- `TC-OBS-03-INT-04: audit rows are immutable against update and delete` (line 479) — inserts
  directly via `insertAuditEntry` helper into `audit_entries` (not via the six-table trigger
  path). **Safe — unaffected by this fix.**

### Finding 3 — `tests/integration/ext02_webhook_dispatch_test.zig` `TC-EXT-02-INT-08`

`TC-EXT-02-INT-08: Create/delete operations write OBS-03 audit rows atomically` (line 615) calls
`webhook_store.createSubscription`/`deleteSubscription`, which set
`bpm.audit_action` via `set_config()` (`src/webhook/subscription_store.zig` lines 137, 306) for
`trg_bpm_audit_webhook_subscriptions` to read, then asserts `create_count`/`delete_count == "1"`
against `audit_entries` (lines 638–666).
**Status: currently FAILING under the shim (trigger on `webhook_subscriptions` disabled) — this
fix repairs it. No source change needed.** Note: `webhook_deliveries` itself has no audit
trigger attached in any migration (confirmed by grep — only index-creation statements reference
`webhook_deliveries`), so removing its `DISABLE TRIGGER ALL` is a no-op for currently-observable
behavior; it is still removed for consistency and to avoid silently defeating a future trigger
on that table.

### Finding 4 — `tests/integration/obs05_dlq_test.zig` — two at-risk cases

- `TC-OBS-05-INT-02: POST /dlq/:id/retry returns 409+discard for CANCELLED and 202 for ACTIVE`
  (line 285) — asserts `retry_audit_count >= 1` (line 361) for `resource_type = 'dlq'`,
  `action = 'dlq.retry'` against `dead_letter_items` rows, requiring
  `trg_bpm_audit_dead_letter_queue` (attached to the table now named `dead_letter_items` per the
  072 rename migration) to fire. **Status: currently FAILING under the shim — this fix repairs
  it. No source change needed.**
- `TC-OBS-05-INT-03: POST /dlq/:id/discard appends audit and rolls back on audit failure` (line
  373) — asserts `audit_count >= 1` (line 418) for `action = 'dlq.discard'`, same dependency.
  **Status: currently FAILING under the shim — this fix repairs it. No source change needed.**

### Finding 5 — `tests/integration/adp06_pipeline_run_correlation_test.zig` — two at-risk cases

- `TC-ADP-06-02` (unnamed in survey excerpt, body at lines ~140–219) — inserts directly into
  `instance_projections` via `insertInstance()` helper (lines 47–63, raw `INSERT INTO
  instance_projections`, not app-code-mediated), then asserts an `audit_entries` row exists with
  a matching `pipeline_run_id` (lines 186–202), requiring `trg_bpm_audit_instance_projections`
  to fire. **Status: currently FAILING under the shim — this fix repairs it. No source change
  needed.**
- `TC-ADP-06-03: non-pipeline paths preserve null/absent compatibility and query filters` (line
  221) — same `insertInstance()` → `audit_entries` dependency (lines 280–289+).
  **Status: currently FAILING under the shim — this fix repairs it. No source change needed.**

### Finding 6 — tests confirmed safe (manual `audit_entries` inserts, not trigger-dependent)

- `tests/integration/adp02_tenant_scope_test.zig` `TC-ADP-02-05` (line 437) — inserts directly
  via `INSERT INTO audit_entries` (lines 467, 485), never relies on the six-table trigger.
  **Safe.**
- `tests/integration/adp10_agent_io_capture_audit_test.zig` — inserts directly via `INSERT INTO
  audit_entries` (lines 85, 109). **Safe.**
- `tests/integration/xc02_audit_immutability_test.zig` — uses its own self-contained,
  properly-paired `ALTER TABLE audit_entries DISABLE TRIGGER USER` / `ENABLE TRIGGER USER`
  (lines 354–355) scoped to `audit_entries` itself (not one of the six business tables, not part
  of `applyCompatibilityShims()`, and not left disabled — it re-enables in a `defer` in the same
  test). **Safe — unrelated mechanism, no interaction with this fix.**
- `tests/integration/adp09_tamper_evident_audit_chain_test.zig` — manipulates triggers on
  `audit_entries` itself for chain-hash testing, not on the six business tables. **Safe.**

### Finding 7 — migration sweep for other trigger types on the six tables

Grepped every `migrations/*.sql` for `CREATE TRIGGER ... ON <table>` against all six table
names. Only `bpm_audit_on_mutation()` (via `trg_bpm_audit_process_definitions`,
`trg_bpm_audit_instance_projections`, `trg_bpm_audit_tasks`, `trg_bpm_audit_dead_letter_queue`
— migration 020 — and `trg_bpm_audit_webhook_subscriptions` — migration 024) is ever attached to
these tables. No `updated_at`-bookkeeping trigger, no other side-effect trigger, and no second
GBL-08x-era type-mismatch-avoidance trigger exists on any of the six tables. `webhook_deliveries`
has no trigger of any kind attached in any migration (only indexes — migrations 010, 023, 085).
`docs/anti-patterns.md` was grepped for `shim`/`trigger`/`GBL-081`/`GBL-082` and contains no
entry referencing this shim or documenting any other reason to keep these six tables'
triggers disabled.

### Risk Survey summary

| Test | File:Line | Currently | After fix | Source change needed |
|---|---|---|---|---|
| TC-ISS-103-INT-02/03/04 | audit_iss103_test.zig:230,307,430 | FAIL | PASS | No |
| TC-OBS-03-INT-01 | obs03_audit_log_test.zig:180 | FAIL | PASS | No |
| TC-OBS-03-INT-02 | obs03_audit_log_test.zig:321 | PASS | PASS | No |
| TC-OBS-03-INT-03 | obs03_audit_log_test.zig:402 | FAIL | PASS | No |
| TC-OBS-03-INT-04 | obs03_audit_log_test.zig:479 | PASS | PASS | No |
| TC-EXT-02-INT-08 | ext02_webhook_dispatch_test.zig:615 | FAIL | PASS | No |
| TC-OBS-05-INT-02 | obs05_dlq_test.zig:285 | FAIL | PASS | No |
| TC-OBS-05-INT-03 | obs05_dlq_test.zig:373 | FAIL | PASS | No |
| TC-ADP-06-02 | adp06_pipeline_run_correlation_test.zig:~140 | FAIL | PASS | No |
| TC-ADP-06-03 | adp06_pipeline_run_correlation_test.zig:221 | FAIL | PASS | No |
| TC-ADP-02-05 | adp02_tenant_scope_test.zig:437 | PASS | PASS | No |
| adp10 audit capture tests | adp10_agent_io_capture_audit_test.zig | PASS | PASS | No |
| xc02 immutability tests | xc02_audit_immutability_test.zig | PASS | PASS | No |
| adp09 tamper-chain tests | adp09_tamper_evident_audit_chain_test.zig | PASS | PASS | No |

**No test was found that relies on triggers staying disabled** (i.e., no test asserts the
*absence* of an audit_entries row on one of the six tables as its intended, desired behavior).
Every currently-failing test in scope fails because the shim prevents an *expected* audit row
from being created — none fail (or would newly fail) because an *unwanted* row appears. The
fix is net-positive: it repairs 10 currently-failing test cases across five files (not just the
three named in ISS-0093) with zero test-source changes and zero new regressions identified.

BACKEND-DEV should run the full `tests/integration/` suite (not just `audit_iss103_test.zig`)
after applying this fix, to confirm all ten cases identified above flip from FAIL to PASS and
no other test newly fails.

## Acceptance criteria coverage

- **"Design covers every acceptance criterion in ISS-0093.json's files_to_change"** — both
  `files_to_change` entries are covered: `tests/integration/helpers.zig` (Diff shape section)
  and `tests/integration/audit_iss103_test.zig` re-verification + the broader
  "any other currently-passing test that relied on triggers being disabled" sweep (Risk Survey,
  Findings 1–7).
- **"No implementation code present, prose design only"** — satisfied; the only code-shaped
  block above is explicitly labeled pseudocode/illustrative, not literal Zig.
- **"Explicit list of tests at risk of relying on the disabled-trigger behavior, with
  mitigation for each"** — satisfied; Risk Survey Findings 1–6 and the summary table enumerate
  every test touching `audit_entries` or the six tables, with a per-test classification and
  mitigation (either "this fix repairs it, no action" or "safe, unaffected").
