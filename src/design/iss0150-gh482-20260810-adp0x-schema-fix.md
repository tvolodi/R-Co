# ISS-0150 / GH-482 (2026-08-10 pass) — adp02/04a/05/06/09/10 `public` vs `tenant_default` schema-literal fix

## 1. Purpose and scope

This Type E design covers a small, well-bounded test-fixture correction found while
executing the close-out re-measurement mandated by
`src/design/iss0150-gh482-test-integration-svc-closeout.md` (written 2026-08-08,
blocked on ISS-0630/GH-605 until that issue merged 2026-08-09 via PR #608).

Six `tests/integration/adp0*_test.zig` files assert against
`information_schema.columns` / `pg_indexes` / `pg_policies` rows using the literal
`table_schema = 'public'` (or `schemaname = 'public'`) for tables that are actually
provisioned only in `tenant_default` (and per-tenant schemas) — `process_definitions`,
`instance_projections`, `tasks`, `tokens`, `audit_entries`, `audit_log`, `users`. These
tables were moved out of `public` by `migrations/GBL-112_tnt01_drop_legacy_public_business_tables.sql`
(TNT-01 legacy-public-table cleanup) at some point before this pass; the six adp0x test
files were never updated to match and so always queried the wrong schema, silently
returning zero rows on **any** database, not just a specific broken one.

No production code changes. No migration changes. Test-fixture query literals only.

## 2. Classification

**Type E** — the change is confined to `WHERE` clause literals inside existing
`tests/integration/*.zig` files; it is not a Type C migration+test parameter file (no
migration is added or changed) and does not fit any Type A/B/D shape.

## 3. Root cause

`information_schema.columns`, `pg_indexes`, and `pg_policies` are catalog views scoped
by `table_schema`/`schemaname`. The six affected tests hardcode `'public'` for tables
that only exist under `tenant_default`. Verified directly against a freshly migrated,
workspace-owned database (`bpm_gh482_fresh20260810`, later `bpm_gh482_verify1/2/3`,
all dropped after use):

```
SELECT table_schema, table_name FROM information_schema.tables
WHERE table_name IN ('process_definitions','instance_projections','tasks','tokens',
                      'audit_entries','audit_log');
-- all 6 rows: table_schema = tenant_default, none in public
```

and the corresponding index/policy names for `idx_users_external_identity_unique`,
`idx_audit_entries_tenant_pipeline_time`, `idx_audit_entries_tenant_chain_lookup`,
`idx_audit_entries_payload_full_gin`, `uq_definition_tenant_version`, etc. — all
confirmed under `tenant_default`, none under `public`.

This confirms the original GH-482 filing's premise (a missing per-tenant
`schema_migrations` ledger) remains disproven exactly as established 2026-08-07/09 —
the 42P01/`schema_migrations does not exist` and C23505/`process_definitions_pkey`
signatures do not appear anywhere in either of this pass's full fresh-database
`zig build test-integration` logs. This fix is unrelated to that premise; it is a
separate, ordinary stale-schema-literal test bug uncovered by finally running the
mandated fresh-database re-measurement now that ISS-0630 no longer blocks it.

## 4. Fix

Change the six affected `WHERE table_schema = 'public'` / `WHERE schemaname = 'public'`
occurrences to `'tenant_default'` in:

- `tests/integration/adp02_tenant_scope_test.zig` (3 occurrences: columns, pg_indexes, pg_policies)
- `tests/integration/adp04a_external_identity_linkage_test.zig` (1: pg_indexes)
- `tests/integration/adp05_instance_artifact_hash_test.zig` (1: columns)
- `tests/integration/adp06_pipeline_run_correlation_test.zig` (2: columns, pg_indexes)
- `tests/integration/adp09_tamper_evident_audit_chain_test.zig` (2: columns, pg_indexes — TC-ADP-09-01's column check only; see §5 for the *other*, unfixed failure in this same file)
- `tests/integration/adp10_agent_io_capture_audit_test.zig` (2: columns, pg_indexes)

`adp09`'s `pg_proc` function-existence query (unqualified by schema, matching
`bpm_audit_compute_chain_hash`/`bpm_audit_apply_chain_hash`/`bpm_audit_validate_chain`
by name only) is untouched by this fix — see §5, it has a separate root cause.

## 5. Explicitly NOT fixed in this pass — forwarded as ISS-0645 / GH-TBD

Re-running the full `zig build test-integration` suite twice against independently
fresh, workspace-owned databases after the above fix confirmed:

- **adp02, adp04a, adp05, adp06 are fully fixed** — zero failures in either post-fix run.
- **adp09 and adp10 still fail, deterministically, in both post-fix runs**, but with a
  *different*, previously-hidden root cause each — not the schema-literal bug this
  design fixes:
  - `adp09` TC-ADP-09-01's `pg_proc` query is unqualified by schema and matches every
    tenant schema's own copy of the three chain-hash functions (each per-tenant schema
    gets its own copy via ordinary, non-`GBL-` migrations). On a database carrying N
    provisioned tenant schemas the query returns up to 3*N+public rows instead of 3,
    so the test's `expectEqual(3, funcs.rows.len)` is inherently sensitive to how many
    other integration tests provisioned tenant schemas before it ran in the same
    suite/process. Confirmed by direct catalog query showing 24 matching
    `(schema, proname)` pairs across `public`, `tenant_default`, and 8 distinct
    `tenant_<uuid>` schemas on one verification database.
  - `adp10` TC-ADP-10-02 depends on transaction-local `set_config(..., true)` GUCs
    (`bpm.actor_username`, `bpm.pipeline_run_id`, `bpm.audit_payload_full`) being read
    by an insert trigger; the observed failure (`expected 'f' found 't'`) is consistent
    with either connection/pool reuse crossing GUC state between test bodies or a
    stale row from a prior run's fixture, not the schema-literal issue.
  - A 28-file **consistent core** (failing identically in both post-fix fresh-database
    runs) includes `adp09`, `adp10`, `db_integration_test`, `env01/02/03_test`,
    `event_store_integration_test`, `exp201_202_entities_test`,
    `exp601_tier_quota_test`, `gh512_t010_regression_test`, `idn03_role_access_test`,
    `iss0125_cascade_test`, `iss0185_dual_schema_test`,
    `iss0602_cross_process_isolation_test`, `iss0605_orphan_self_heal_test`,
    `iss107_tenant_storage_mode_test`, `iss202_merge_atomicity_test`,
    `iss206_token_multiset_test`, `iss601_state_snapshots_test`,
    `obs03_audit_log_test`, `onboarding_realm_guard_test`,
    `sim01_04_simulation_mode_test`, `spt01_iss0068_onboarding_schema_test`,
    `svc04_admin_api_test`, `xc02_audit_immutability_test`,
    `xc06_backwards_compatibility_test` — each with its own distinct assertion
    failure, spanning many unrelated subsystems (timers, entities, RBAC, webhook
    outbox, OIDC onboarding, event store, EXP-601 quota, audit chain). These are NOT
    one root cause and are NOT part of GH-482's originally filed symptom.
  - A further ~6-7 files flicker between the two post-fix runs
    (`audit_iss103_test`, `iss0129_migration_run_advisory_lock_test`,
    `iss101_timers_failed_status_test`, `iss502_spt_cutover_test`,
    `sch02_timer_polling_test`, `xc04_kernel_determinism_test`,
    `audit_chain_utf8_test`, `exp103_instance_waits_test`,
    `exp401_exp402_comp_restore_test`, `iss203_idempotency_keys_test`,
    `iss205_webhook_outbox_test`, `sch303_timer_dlq_test`,
    `tnt_schema_isolation_test`), consistent with connection-pool/timer-timing
    pressure from running ~40 integration binaries concurrently against one
    PostgreSQL instance — the same class of noise already documented for
    `TC-DB-02-04` (§6).

These residual failures are forwarded as **ISS-0645**, filed as its own GitHub issue and
queued, rather than fixed in this pass, per the same batch-cap/dependency-order
discipline already used for GH-495→ISS-0624/0625 and GH-482's own ISS-0630 split.
Attempting to diagnose 28+ scattered, unrelated failures inside one WF-03 run would
violate the batch cap and mix multiple unrelated root causes into a single PR.

## 6. TC-DB-02-04 flakiness

Re-confirmed **absent** in both of this pass's fresh-database full-suite runs (0
occurrences of `TC-DB-02-04` failing in either `scratch/gh482-verify1-full.log` or
`scratch/gh482-verify3-full.log`) — consistent with the documented ~1-in-3 intermittent
rate. ISS-0631/GH-606 already tracks this (filed 2026-08-09); no new issue needed. Not
reproduced or newly diagnosed in this pass.

## 7. Dependencies

- `migrations/GBL-112_tnt01_drop_legacy_public_business_tables.sql` (established that
  these tables no longer live in `public`).
- `tests/integration/helpers.zig` `TestHarness` (sets `search_path` to
  `tenant_default,public` — the reason application code paths still work correctly even
  though these six tests' *assertions* queried the wrong catalog schema).
- Close-out design `src/design/iss0150-gh482-test-integration-svc-closeout.md` (defines
  the fresh-database re-measurement procedure this pass followed).

## 8. Verification performed

- `zig build` exit 0.
- `zig build 2>&1 | grep -i "error set"` — no output.
- `./.venv/Scripts/python.exe tools/lint_sql_param_types.py src tests` — 0 BLOCKER/MAJOR/MINOR.
- `./.venv/Scripts/python.exe tools/lint_test_isolation.py tests/integration` — OK, 135 files, no issues.
- `zig build test` (unit suite) exit 0.
- `zig build test-integration-svc` exit 0 (both fresh and shared `bpm_test` databases).
- `zig build test-integration-adp02` exit 0 against shared `bpm_test`.
- Full `zig build test-integration` run twice against two independently fresh,
  workspace-owned databases post-fix: adp02/adp04a/adp05/adp06 show zero failures in
  either run; adp09/adp10 remain failing in both (different, unfixed root cause,
  forwarded per §5).
