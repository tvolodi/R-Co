# Design: ISS-0641 / GH-637 — 14 dual-schema shadow tables (ISS-0185-class)

**Run:** WF03-GH637-20260809
**Precedent:** ISS-0185/GH-518 (original 45-table classification methodology),
ISS-0101/GH-359 (this session — GBL-140 + source-migration scope-header patch
pattern for `tenant`/`tenant_hostnames`, the fix shape this design follows
exactly).

## 1. Problem

`tools/lint_dual_schema_table_names.py` reports BLOCKER: 14 table names exist
in both `public` and `tenant_default` on the current warm, fully-migrated
`db_test` (120 migration files, `zig build migrate` confirms "No new
migrations to apply"):

```
api_token_audit, event_payload_store, group_roles,
instance_definition_snapshots, instance_waits, lua_script_execution_audit,
role_permissions, sessions, sla_records, subprocess_links,
tenant_artifact_activations, user_groups, variable_schemas,
webhook_deliveries
```

## 2. Root cause (verified, not just asserted)

For every one of the 10 source migrations that create these 14 tables,
`grep -n "^-- scope:"` returns **no match**:

| Table(s) | Source migration |
|---|---|
| `api_token_audit` | `019_idn04_api_token_management.sql` |
| `event_payload_store`, `variable_schemas` | `012_event_retention.sql` |
| `group_roles`, `role_permissions`, `sessions`, `user_groups` | `008_identity.sql` |
| `instance_definition_snapshots` | `004_definitions.sql` |
| `instance_waits` | `093_exp103_instance_waits.sql` |
| `lua_script_execution_audit` | `095_iss0176_lua_script_execution_audit.sql` |
| `sla_records` | `007_timers.sql` |
| `subprocess_links` | `026_ext05_subprocess_links.sql` |
| `tenant_artifact_activations` | `058_repo_artifacts_tenant_activation.sql` |
| `webhook_deliveries` | `010_dlq.sql` |

Per `src/db/migrations.zig::migrationScope`, a migration's scope is
`.public_only` only when the filename begins with `GBL-` OR the file body
carries `-- scope: public` in its first 1 KiB. None of the 10 files above
qualify, so the runner defaults each to `.all_schemas` and replays the
unqualified `CREATE TABLE` in every tenant-schema pass — the exact defect
already fixed for `tenant`/`tenant_hostnames` in ISS-0101/GBL-140 this
session, and for the original 45 tables in ISS-0185/GBL-134/135/136.

**Why this recurs despite GBL-134/135/136 already running:** those three
migrations only *dropped* the shadow copies that existed at the time; they
never patched the 10 source migrations above with a scope header. Any full
cold-start replay (fresh `tenant_<x>` schema provision, or a `db_test`
rebuild) re-runs the unqualified source migration in the new tenant schema
and recreates the shadow. This is the identical mechanism ISS-0101's GBL-140
header noted for `tenant`/`tenant_hostnames` ("GBL-139 already dropped these
shadows once, but ... resurrecting both shadows a second time"). Confirmed:
13 of these 14 table names are **already** listed in
`docs/issue-reports/ISS-0185-diagnosis.yaml`'s classification tables and 12
of them are **already** in GBL-135's own `v_tables` drop array — meaning
GBL-135 already dropped these exact shadows once, and they have since grown
back because the creation path (the unqualified source migration) was never
closed.

Only `lua_script_execution_audit` (migration 095, added post-ISS-0185) is
genuinely new — not present in the original 45-table classification.

## 3. Classification (verified per-table, not trusted from the issue body alone)

Method: FK-chain analysis (`information_schema.table_constraints` /
`constraint_column_usage` joined against `public`) + row-count inspection on
the live `db_test` + call-site grep, matching the
`docs/issue-reports/ISS-0185-diagnosis.yaml` methodology.

```sql
-- No FK dependents found on the public copy of any of the 14 tables
-- (query run against db_test; zero rows returned) — RESTRICT-mode drops
-- are safe for all 14.
```

| Table | Classification | Canonical schema | Evidence |
|---|---|---|---|
| `api_token_audit` | PER_TENANT | `tenant_default` | Already in ISS-0185 `per_tenant_public_is_stray`; `public` copy row count = 0 on db_test; GBL-135's `v_tables` already targeted it once. |
| `event_payload_store` | PER_TENANT | `tenant_default` | Same as above. |
| `group_roles` | PER_TENANT | `tenant_default` | Same as above. |
| `instance_definition_snapshots` | PER_TENANT | `tenant_default` | Same as above (keyed by `instance_id`, tenant-schema data). |
| `instance_waits` | PER_TENANT | `tenant_default` | Same as above. |
| `role_permissions` | PER_TENANT | `tenant_default` | Same as above. |
| `sessions` | PER_TENANT | `tenant_default` | Same as above. |
| `sla_records` | PER_TENANT | `tenant_default` | Same as above. |
| `subprocess_links` | PER_TENANT | `tenant_default` | Same as above. |
| `user_groups` | PER_TENANT | `tenant_default` | Same as above. |
| `variable_schemas` | PER_TENANT | `tenant_default` | Same as above. |
| `webhook_deliveries` | PER_TENANT | `tenant_default` | Same as above. |
| `lua_script_execution_audit` | PER_TENANT | `tenant_default` | New (not in ISS-0185). No `tenant_id` column; keyed by `instance_id` (tenant-schema process instance data — same shape as `instance_definition_snapshots`/`instance_waits`). `src/engine/lua_script_audit.zig::executeScriptForAudit` writes on the caller-supplied `conn`, same per-tenant-connection convention as `recordExecutionErrorEventInTx`. `public` copy row count = 0 on db_test. |
| `tenant_artifact_activations` | GLOBAL_REGISTRY | `public` | Already in ISS-0185 `global_registry_tenant_default_is_stray`; already targeted by GBL-134's and GBL-138's drop arrays. Has a `tenant_id` column (PK component) but is queried in `src/config/loader.zig:204-213` as `FROM tenant_artifact_activations taa ... WHERE taa.tenant_id = $1` — a single global table filtered by tenant_id (same shape as `service_catalog`), not per-tenant-schema data. **Row-count-verified on live db_test: `public` copy has 8 real rows; `tenant_default` copy has 0 rows** — confirms `public` is canonical, `tenant_default` is the stray shadow, consistent with the existing GBL-134/138 treatment. |

13 of 14 are PER_TENANT (canonical = `tenant_default`, `public` copy is the
stray shadow — all confirmed empty on live `db_test`). 1 of 14
(`tenant_artifact_activations`) is GLOBAL_REGISTRY (canonical = `public`,
`tenant_default` copy is the stray shadow — confirmed empty on live
`db_test` while `public` holds live data).

No ambiguous/deferred cases: all 14 have a clean, evidence-backed
classification and zero FK dependents blocking a RESTRICT drop. Nothing is
split off to a follow-up issue.

## 4. Fix (two parts per table, matching the ISS-0101/GBL-140 precedent exactly)

### 4a. Close the creation path (permanent fix — prevents recurrence)

`src/db/migrations.zig::migrationScope()` only exposes a binary primitive:
`.public_only` (via `GBL-` filename prefix or a `-- scope: public` header)
or the default `.all_schemas`. There is no `.tenant_only` primitive that
would suppress the `public`-pass copy while keeping the
`tenant_default`-pass copy. This matters because the 14 tables split into
two materially different cases:

- **GLOBAL_REGISTRY table** (`058_repo_artifacts_tenant_activation.sql`,
  `tenant_artifact_activations` only): initially attempted the
  `031_adp04b_tenant_realm_binding.sql`-style fix (file-level
  `-- scope: public` header + `public.`-qualify both statements in the
  file), but this file also creates `repository_artifacts` in the same
  statement block, and `repository_artifacts` is **HYBRID**, not
  GLOBAL_REGISTRY — confirmed by
  `tests/integration/iss0185_dual_schema_test.zig`'s
  `TC-ISS-0185-03`, which asserts `repository_artifacts` exists in BOTH
  `public` and `tenant_default` (it has legitimate tenant-side rows via
  `artifact_versions`' FK chain, itself confirmed HYBRID). A whole-file
  `-- scope: public` header would have silently broken this test by
  suppressing `tenant_default.repository_artifacts` creation — caught by
  running the full cold-start `test-integration` suite (§6) before this
  design was finalized, and reverted. Since `migrationScope()` has no
  per-table primitive, `tenant_artifact_activations` cannot be
  selectively public-scoped without also affecting
  `repository_artifacts` in the same file. This table is therefore
  handled the same way as the 13 PER_TENANT tables below: documentation
  comment only, shadow dropped by the GBL-141 corrective migration, no
  functional scope-header change to the source file.

- **PER_TENANT tables** (`004_definitions.sql`, `007_timers.sql`,
  `008_identity.sql`, `010_dlq.sql`, `012_event_retention.sql`,
  `019_idn04_api_token_management.sql`, `026_ext05_subprocess_links.sql`,
  `093_exp103_instance_waits.sql`,
  `095_iss0176_lua_script_execution_audit.sql`): these files are correctly
  `.all_schemas` already — they must keep running in every tenant schema,
  including `tenant_default`, to create the canonical copy there. The
  `public`-pass copy is the unwanted side effect and there is no existing
  primitive to suppress just that pass. Rather than invent one under this
  issue's time budget, this fix documents the intended scope explicitly in
  each source file header (`-- PER_TENANT: canonical home is
  tenant_default; see docs/issue-reports/ISS-0185-diagnosis.yaml. The
  public copy this file also creates is a known shadow, dropped by
  GBL-141 (idempotent) and expected to require GBL-141 to be re-applied
  after any full cold-start replay until migrations.zig gains a
  tenant-only scope primitive.`) and relies on the corrective migration
  (4b) plus `lint_dual_schema_table_names.py` (already run in CI/pre-flight
  per `docs/guides/test_infrastructure_guide.md`) to catch and clean any
  recurrence. This matches GBL-135's own precedent exactly — GBL-135 also
  only dropped the shadow and documented the classification, without
  attempting a `migrationScope()` change. A `.tenant_only` primitive is
  filed as a separate structural follow-up (§5 covers the pre-merge lint
  improvement; a `.tenant_only` scope primitive is a larger `migrations.zig`
  change and is noted as future work in the CHANGELOG entry, not built
  here).

### 4b. Drop the currently-existing shadows (immediate cleanup)

New migration `GBL-141_iss0641_drop_dual_schema_shadows.sql`:

- PER_TENANT means `tenant_default` is canonical, so the shadow to drop is
  `public.<name>` for the 13 PER_TENANT tables (`api_token_audit`,
  `event_payload_store`, `group_roles`, `instance_definition_snapshots`,
  `instance_waits`, `lua_script_execution_audit`, `role_permissions`,
  `sessions`, `sla_records`, `subprocess_links`, `user_groups`,
  `variable_schemas`, `webhook_deliveries`) — mirrors GBL-135's exact
  pattern and array (GBL-135's own 12 plus the 1 new
  `lua_script_execution_audit`).
- Drop `tenant_default.tenant_artifact_activations` for the 1
  GLOBAL_REGISTRY table — mirrors GBL-134/138's pattern (single-table,
  scoped to `tenant_default` since that's the only tenant schema confirmed
  affected on this environment, following the narrower-scope precedent set
  by GBL-140).
- Idempotent (existence-guarded), `RESTRICT` only, per-table
  `EXCEPTION WHEN dependent_objects_still_exist` guard (GBL-136/140 style)
  so an unexpected live FK dependent produces a logged `NOTICE`, not a
  failed migration or silent data loss.
- Safe to run on an already-clean database (all guards are existence
  checks).

## 5. Structural improvement (issue suggestion #3 — included, does not block 1-2)

`tools/lint_migration_schema.py` is extended with a new check: any
**non-`GBL-`-prefixed** migration file whose body contains an unqualified
`CREATE TABLE` (no `public.` / `tenant_default.` prefix) AND has no
`-- scope:` header anywhere in the file is flagged BLOCKER at lint time
(pre-merge), not just after-the-fact via the state-based
`lint_dual_schema_table_names.py`. This does not change `migrationScope()`
runtime behavior; it only prevents new unheadered files from merging so the
6→14 growth pattern this issue describes cannot recur for as-yet-unwritten
migrations.

## 6. Verification plan

1. `./.venv/Scripts/python.exe tools/lint_dual_schema_table_names.py` — 14 →
   0 BLOCKER after GBL-141 runs.
2. `zig build migrate` run twice — second run must report
   "No new migrations to apply", confirming GBL-141 is idempotent.
3. `zig build` / `zig build test` — no regressions.
4. `python3 tools/lint_sql_param_types.py src tests` — 0 BLOCKER/MAJOR
   (GBL-141 uses no user-data string interpolation; all identifiers come
   from a fixed literal array via `format(..., %I)`, same as GBL-135/136).
5. If time/safety permits: destructive cold-start reproduction on `db_test`
   ONLY (`docker-compose rm -f -s -v db_test` + `up -d` + full
   `zig build test-integration` replay), confirming the 14-table
   duplication does not reappear post-fix, then restore `db_test` to normal
   long-lived migrated state.
