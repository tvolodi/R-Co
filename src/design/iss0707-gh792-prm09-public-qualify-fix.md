# Module: ISS-0707 / GH-792 — prm-09 public-schema qualification fix

Type E prose design — a surgical SQL-text qualification fix to an existing
Zig module and its integration test. No new module, no new public interface,
no migrations, no schema decisions. Covers the fix for ISS-0707 (GitHub #792):
the PRM-09 solution-pack three-way-diff planner and its integration test issue
unqualified DML/SELECT against `solution_pack_installs` and
`solution_pack_artefact_bases`, which resolve to the `tenant_default` shadow
(table created by migration 1158, SOL-02) instead of the intended `public`
tables (migration 1157, PRM-09) under the per-tenant `search_path`, producing
sqlstate 42703 on a fresh-migration database.

## Module purpose

`pack_update.computePackUpdatePlan` computes a three-way diff (base Vb /
tenant `theirs` / incoming Vn) for a solution-pack update, classifying each
artefact as `clean_update`, `local_only`, or `conflict` before any apply. Its
read set spans two schema families: **global infrastructure** tables in
`public` (`solution_pack_installs`, `solution_pack_artefact_bases`, both
created by migration 1157 with `-- scope: public.`) and a **per-tenant**
business table (`process_definitions`, tenant-side). Today both the SUT and
its integration test reference the global tables **unqualified**, relying on
`search_path` fallback. Under the pool's SCHEMA-mode routing the search path
is `tenant_default, public` — so the unqualified name resolves to
`tenant_default.solution_pack_installs` first. On a fresh migration replay
that table carries the 1158/SOL-02 column layout (`pack_id, pack_version,
schema_version, installed_by, installed_at` — no `tenant_id`/`installed_version`),
and every PRM-09 query against it raises 42703. The fix makes the SUT and the
test deterministic: always read the intended `public` tables via an explicit
`public.` prefix, while leaving the genuinely tenant-side
`process_definitions` unqualified. This is a design-only artefact; the code
change is Step 3 (BACKEND-DEV).

## Public interface

No signature, type, or error-set changes. The change is confined to SQL
string literals inside the bodies of existing functions.

```
pack_update.computePackUpdatePlan(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    pack_id: []const u8,
    incoming_version: []const u8,
    incoming_artefacts: []const IncomingArtefact,
) PackUpdateError!PackUpdatePlan        // unchanged
```

The module is re-exported at `src/bpm.zig:138` (`pub const pack_update =
@import("definition/pack_update.zig")`). No call-site changes anywhere.

## Exact changes (Step 1 fix spec)

### tests/integration/prm-09-pack-update.test.zig

| Line | Current literal | Change | Context |
|---|---|---|---|
| 98 | `INSERT INTO solution_pack_installs` | `INSERT INTO public.solution_pack_installs` | `insertPackInstall` helper — fixture install row for a (tenant, pack, version) triple; needs 1157 columns `tenant_id`/`installed_version` |
| 119 | `SELECT id::text FROM solution_pack_installs WHERE tenant_id = $1::uuid AND pack_id = $2 LIMIT 1` | `SELECT id::text FROM public.solution_pack_installs ...` | `insertPackArtefactBase` helper — resolves `install_id` from the public install record |
| 128 | `INSERT INTO solution_pack_artefact_bases (install_id, artefact_id, artefact_kind, base_content)` | `INSERT INTO public.solution_pack_artefact_bases (...)` | `insertPackArtefactBase` helper — inserts the base snapshot (1157 table) |
| 164 | `DELETE FROM solution_pack_installs WHERE tenant_id = $1::uuid` | `DELETE FROM public.solution_pack_installs WHERE tenant_id = $1::uuid` | `dropTenantFixtures` cleanup — must delete the public install record (cleanup `tenant_default` rows is not the fixture's concern) |

**Explicitly unchanged:** line 145 `INSERT INTO process_definitions` and line
160 `DELETE FROM process_definitions` — tenant-side table, must keep resolving
via the per-tenant search path (see "Why process_definitions stays
unqualified" below). Test-name strings mentioning the table (lines 248/296)
are prose only and stay as-is.

### src/definition/pack_update.zig (PRODUCTION)

| Line | Current literal | Change | Context |
|---|---|---|---|
| 117 | `FROM solution_pack_installs` | `FROM public.solution_pack_installs` | Step 1 — load installed version (Vb) by `(tenant_id, pack_id)`; 1157 columns `tenant_id`/`installed_version` are required |
| 179 | `FROM solution_pack_artefact_bases` | `FROM public.solution_pack_artefact_bases` | Step 2 — load base content per `install_id`; 1157 table is the only home of base snapshots |

**Explicitly unchanged:** line 235 `FROM process_definitions` — tenant-side
`theirs` lookup (Step 3). The doc comment at lines 102–105 (which currently
asserts the public tables are "found via search_path fallback") must be
updated in Step 3 to state that the public tables are now explicitly
`public.`-qualified and no longer rely on search-path fallback.

## Data flow — why unqualified names fail and what the fix changes

```mermaid
flowchart LR
    A[computePackUpdatePlan / test helper] --> Q{qualified?}
    Q -- yes, public.x --> P[(public.solution_pack_installs<br/>migration 1157, PRM-09,<br/>has tenant_id/installed_version)]
    Q -- no, bare name --> SP[search_path = tenant_default, public<br/>pool SCHEMA-mode routing]
    SP --> T[(tenant_default.solution_pack_installs<br/>migration 1158, SOL-02,<br/>pack_version/schema_version, no tenant_id)]
    P -. intended read set .-> R[42703 on fresh DB when bare]
    T -. wrong target .-> R
```

Resolution under SCHEMA mode: `pool.zig` `applyRequestStorageRouting` sets the
connection `search_path` to `<tenant_schema>, public` for the zero-UUID tenant
context the tests use. PostgreSQL resolves an unqualified name to the first
schema in the path that contains it — `tenant_default` wins. On a warm DB the
shadow happens to carry the 1157 layout (a legacy artifact of the original
1157 from commit `47d4c7c9`, whose `-- Scope:` capital-S header defaulted to
all-schema scope), so the tests pass 4/4 today (masked). On any clean
migration replay the shadow carries the 1158 layout and all four tests fail.

## Why the qualification is correct

- Migration `1157_prm09_solution_pack_update.sql` declares `-- scope: public.`
  and creates `public.solution_pack_installs` (tenant_id, pack_id,
  installed_version, installed_at, installed_by; UNIQUE on the
  tenant/pack/version triple) and `public.solution_pack_artefact_bases`
  (install_id, artefact_id, artefact_kind, base_content; UNIQUE on
  install/artefact). PRM-09's read set is this global infrastructure —
  install records are cross-tenant, referencing `public.tenant`.
- Migration `1158_sol02_solution_pack_installs.sql` declares
  `-- scope: tenant_only` and creates a **different** `solution_pack_installs`
  (pack_id, pack_version, schema_version, installed_by, installed_at) for the
  SOL-02 per-tenant install-metadata feature. It is a distinct table that
  shares the name; it is not a PRM-09 data source.
- Qualifying with `public.` pins every PRM-09 statement to the intended table
  regardless of `search_path` — the deterministic guarantee that unqualified
  resolution cannot provide in a multi-schema database. This matches the
  documented anti-pattern rule: when a test/SUT verifies a public-scoped
  migration's effect, explicitly qualify every reference instead of relying on
  the tenant-first search path (see `docs/anti-patterns.md` DB section).

## Why process_definitions stays unqualified

`process_definitions` is a per-tenant business table: its canonical home is
the active tenant schema (or `tenant_default` for the default tenant), reached
exactly through the per-tenant search path the pool applies in SCHEMA mode.
No migration creates a `public.process_definitions`; qualifying it with
`public.` would route the Step 3 `theirs` lookup to a non-existent relation
and break the `local_only`/`conflict` classification on every run. The
`theirs` lookup must see the tenant's own modified copy, so it must keep
resolving tenant-side. Same reasoning applies to the test's fixture inserts
and cleanup for `process_definitions` (lines 145/160).

## Blast radius of the production change

- **Callers of `computePackUpdatePlan`:** none in production today. The only
  reference to the function outside its own module is the re-export in
  `src/bpm.zig`; PRM-09 is a SHOULD-level read path whose apply routes through
  the PRM-01 promotion plan. The integration test file is the sole direct
  caller. The signature is unchanged, so no caller can break from the change.
- **Behavior on warm DBs:** the SUT now reads `public.solution_pack_installs`
  explicitly. On the current warm `bpm_test` (:5453) both the public table and
  the (legacy-layout) shadow expose identical columns, so observable
  classification results are unchanged. The change removes the search-path
  dependence rather than altering data semantics.
- **Schema family collision (must NOT change):** `src/solution/store.zig`
  (SOL-02 install path) issues `SELECT`/`INSERT` against unqualified
  `solution_pack_installs` at lines 324/347 with the 1158 column set
  (`pack_id`, `pack_version`, `schema_version`, `installed_by`). That code
  **intentionally** targets the tenant-side table and must remain unqualified.
  Likewise `tests/integration/sol02_install_test.zig` (lines 73/80/130) and
  `tests/integration/sol03_role_gate_test.zig` (lines 68/74) exercise the
  SOL-02 tenant-side install path and must stay unqualified. This fix touches
  exactly two files — the prm-09 test and `pack_update.zig` — and no others.
- **Regression surface:** the SOL-02 suite is unaffected (no shared file, no
  shared table access in this change). Re-running `sol02_install_test` and
  `sol03_role_gate_test` in Step 3 confirms no collateral damage.

## Error taxonomy

| Condition | Pre-fix (fresh DB) | Post-fix |
|---|---|---|
| Direct test DML/SELECT on `solution_pack_installs` / `solution_pack_artefact_bases` | sqlstate 42703 `column does not exist` raised at `conn.exec`/`queryRow` — all 4 TC-PRM-09 fail | Resolves to `public` tables; no error |
| SUT `computePackUpdatePlan` Step 1/Step 2 queryRow on the shadow | 42703 mapped by the existing `catch` to `PackUpdateError.OutOfMemory` (non-`ExhaustedPool` branch) — a misleading symptom that confirms the SUT itself was broken on fresh DBs | Resolves to `public` tables; normal classification |
| Pack not installed (no public row) | n/a (blocked by 42703 on a fresh DB) | `PackUpdateError.PackNotInstalled` — TC-PRM-09-02 asserts this |
| Exhausted pool | `PackUpdateError.PoolExhausted` | unchanged |
| Allocation failure | `PackUpdateError.OutOfMemory` | unchanged |

No new error modes are introduced; the change only removes a spurious error
source.

## Dependencies

- **DB (read):** `public.solution_pack_installs`, `public.solution_pack_artefact_bases` (migration 1157, `-- scope: public.`), `process_definitions` (tenant-side, via per-tenant search path).
- **Runtime:** pool SCHEME-mode routing (`pool.zig` `applyRequestStorageRouting`, search_path `tenant_default, public` for the zero-UUID context).
- **Must NOT depend on / must NOT be affected by:** `tenant_default.solution_pack_installs` (migration 1158, SOL-02) and its consumers (`src/solution/store.zig`, `sol02_install_test.zig`, `sol03_role_gate_test.zig`).
- **Env var:** `BPM_TEST_DB_URL` (integration harness requirement; unset fails fast with `error.MissingTestDatabaseUrl`).

## Verification plan

1. **Static qualification check (deterministic):** after Step 3, grep both
   files — every `solution_pack_installs` / `solution_pack_artefact_bases`
   DML/SELECT must be `public.`-qualified; every `process_definitions`
   reference must remain unqualified. This is the authoritative proof because
   the warm DB masks the runtime symptom.
2. **Build/run (necessary, not sufficient):**
   `BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build test-integration-prm09`
   — build.zig:3164 defines the target; the issue-cited name
   `test-integration-prm-09` does **not** exist. Expect 4/4 PASS. Note: the
   warm `bpm_test` currently carries the 1157-layout shadow, so this pass does
   NOT by itself prove the fix — the same command also passes pre-fix today.
3. **Fresh-migration replay (authoritative runtime proof):** run
   `test-integration-prm09` against a database whose `tenant_default`
   `solution_pack_installs` has the true 1158 layout (a clean schema reset or
   CI provisioning). Pre-fix this fails 4/4 with 42703; post-fix it must pass
   4/4. If a fresh DB is not available in Step 3, record the static
   qualification check as the proof and flag the fresh-replay as a
   TEST-RUNNER confirmation task.
4. **No collateral damage:** confirm `sol02_install_test` and
   `sol03_role_gate_test` still pass (SOL-02 tenant-side path untouched).

## State transitions

Not applicable at the module level — `computePackUpdatePlan` is a
read-only classifier with no state machine. The only observable change is
which schema its SELECTs resolve against; classification semantics are
unchanged.

## Open questions

- **Dual-schema shadow remediation (out of scope):** `tenant_default` and
  `public` each contain a `solution_pack_installs` with different shapes —
  the documented "silent shadow" anti-pattern. This fix qualifies the PRM-09
  call sites but does not remove the duplication. The systemic cure (dual-schema
  classification + drop pipeline, ISS-0185) is tracked separately; GH-792 does
  not change it.
- **Warm-DB legacy state:** the current `bpm_test` shadow carries the 1157
  layout (legacy artifact of the original 1157). No schema reset is part of
  this fix; the warm database will continue to mask the bug for CI-less local
  runs until reset. Confirmed as accepted for this issue.
- **Apply path:** PRM-09's apply routes through PRM-01; no apply-path code
  references these tables unqualified today (verified by grep). If a future
  apply step adds unqualified references, it must follow the same
  `public.`-qualification rule.
- **Comment accuracy:** the doc comment at `pack_update.zig:102–105` currently
  describes search-path fallback as the resolution mechanism; Step 3 must
  update it to reflect explicit `public.` qualification (flagged to
  BACKEND-DEV, no design ambiguity).
