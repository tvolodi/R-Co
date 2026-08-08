# ISS-0620 / GH-573 — Forward-fix for GBL-134's 4 misclassified PER_TENANT tables

**Run ID:** WF03-GH573-20260808
**Issue:** GH-573 / ISS-0620 (BLOCKER)
**Severity:** BLOCKER
**Author:** ISSUE-FIXER (design done in-line per CLAUDE.md ISSUE-FIXER guidance — see §6
for why a separate CODE-DESIGNER pass was not used)
**Status:** DESIGN

## 1. Purpose / Problem

`migrations/GBL-134_iss0185_drop_global_registry_shadows.sql`'s `v_tables` allow-list
(lines 45-70) wrongly included 4 table names —
`artifact_activation_groups`, `entity_definitions`, `entity_record_latest`,
`entity_type_instances` — that `docs/issue-reports/ISS-0185-diagnosis.yaml`'s own
`classification_table.per_tenant_public_is_stray` list classifies as **PER_TENANT**
(canonical home = `tenant_default`; `public` is the stray shadow) — the opposite of what
GBL-134 assumed (GLOBAL_REGISTRY, canonical home = `public`). GBL-134 unconditionally ran
`DROP TABLE %I.%I RESTRICT` against every tenant schema's copy of these 4 names, with no
row-count check, no backup, no guard beyond "does this name also exist in `public`."

GBL-134 has already executed against the shared `bpm_test` database and workspace
`r-co-2`'s `bpm_dev` database (both confirmed via `schema_migrations`, `applied_at
2026-08-08 05:44:11+00` in both). It is treated as immutable per this migration
lineage's established convention (see GBL-136 §"Root cause": *"GBL-134 already ran
against multiple databases and is immutable"*). This design covers only the forward-fix:
recreating `tenant_default.<table>` for the 4 names, going forward, so future tenant
provisioning (and this workspace's own already-broken `tenant_default`) is not silently
missing these tables.

## 2. Scope confirmation (read-only investigation, done before this design)

Both `bpm_test` and `bpm_dev` confirm `GBL-134`/`GBL-135`/`GBL-136` all applied. Current
state as of this investigation (2026-08-08):

- **`bpm_dev` (workspace r-co-2's local dev DB):** `tenant_default.entity_definitions`,
  `.entity_record_latest`, `.entity_type_instances`, `.artifact_activation_groups` **do
  not exist** — `\dt` returns "Did not find any relation" for all 4. This is GBL-134's
  direct, still-visible effect: dropped 2026-08-08 05:44:11 UTC, never recreated since
  (094's `tenant_default` application in this DB was 2026-08-06 07:27:27, i.e. only
  once, before GBL-134 ran).
- **`bpm_test` (shared test DB):** all 4 tables currently **exist** in `tenant_default`,
  but as empty shells (0 rows) with the correct schema shape. Tracing
  `schema_migrations`: `tenant_default` in `bpm_test` was entirely dropped and
  reprovisioned from scratch at 2026-08-08 08:19:53–08:19:55 UTC (75 tenant-schema
  migrations replayed in ~2.5 seconds, `001_event_store.sql` through
  `1137_iss0156_entity_instance_projection_backfill.sql`) — well after GBL-134 (05:44),
  GBL-135 (05:44:16), and GBL-136 (07:15:57) all ran. That reprovisioning event replayed
  migration `094_entity_subsystem.sql` against `tenant_default` and recreated the 4
  tables as empty tables. (Why `094` — which now carries a `-- scope: public` header
  added in the same commit `a2a8c68` that created GBL-134/135/136 — was not skipped by
  that replay is unresolved; the header is confirmed present at byte offset 987 of the
  file, well inside the runner's 4096-byte scope-header read window, so the replay was
  most likely run by a migrate binary built from a checkout that predates `a2a8c68`,
  e.g. the sibling `r-co` workspace acting against the same shared `bpm_test` container.
  This is a separate, non-blocking observation, not part of this fix's scope.)
- **Public copies in both databases:** `entity_definitions`, `entity_record_latest`,
  `entity_type_instances`, `artifact_activation_groups` all show **0 rows** in both
  `bpm_test` and `bpm_dev`. Zero rows does not prove nothing was lost — it only proves
  the current remaining copies are empty. There is no pre-drop row-count record, no WAL
  archiving (`archive_mode = off` confirmed via `SHOW archive_mode` on `bpm_test`), and
  no backup file found in this repository or workspace. **No obvious recovery path found
  in this environment.**
- **Non-local/production exposure:** no evidence found. `.github/workflows/ci.yml` and
  `docker-compose*.yml` contain no production database URL, no deployment target, and no
  reference to any environment beyond the local/CI ephemeral Postgres containers this
  repository already uses for `bpm_test`/`bpm_dev`. The only other locally-running
  Postgres containers on this host belong to unrelated projects (`ai-dala-next`,
  `aiqadam-*`, `forge_postgres`) — not R-Co. Both known-affected databases (`bpm_test`,
  `bpm_dev`) are local development infrastructure only.

## 3. FK dependency analysis

Searched `src/**/*.zig` and `migrations/**/*.sql` for
`REFERENCES entity_definitions`, `REFERENCES entity_type_instances`,
`REFERENCES entity_record_latest`, `REFERENCES artifact_activation_groups` — **zero
matches**. None of the 4 tables has any FK dependent anywhere in the schema (unlike
GBL-136's `artifact_versions`, which has three live tenant-side FK dependents and
required a per-table exception handler). This forward-fix is a plain `CREATE TABLE IF
NOT EXISTS` with no FK-ordering or RESTRICT-failure concerns.

## 4. Source-of-truth schema shapes

Read directly from the migrations that originally created each table (all unqualified,
i.e. they ran in both `public` and `tenant_default` under the pre-ISS-0185 all-schemas
default):

- `entity_definitions`, `entity_type_instances`, `entity_record_latest` —
  `migrations/094_entity_subsystem.sql` (2026-06-12). Columns, constraints, and indexes
  copied verbatim from that file's `CREATE TABLE` statements.
- `artifact_activation_groups` — `migrations/046_repository_activations.sql`. Columns,
  constraints (none beyond PK), and indexes copied verbatim.

The `public` copies in both `bpm_test` and `bpm_dev` were inspected directly (`\d
public.entity_definitions` etc.) and match these source migrations exactly — confirming
no drift has occurred and the forward-fix can safely recreate an identical shape in
`tenant_default`.

## 5. Forward-fix migration design

New file `migrations/GBL-137_iss0620_recreate_per_tenant_shadows.sql`, following the
`GBL-134`/`GBL-135`/`GBL-136` lineage pattern:

- `GBL-` prefix → `migrationScope()` classifies it `.public_only` automatically (no
  header needed), but the migration's own `DO $$` loop iterates `public.tenant` and
  computes each tenant's schema name itself (same technique as GBL-134/136), so it
  reaches every tenant schema despite running only in the public pass.
- For each tenant schema, for each of the 4 table names: `CREATE TABLE IF NOT EXISTS
  <schema>.<table> (...)` with the exact shape from §4, plus matching indexes.
  `IF NOT EXISTS` makes it a safe no-op for `bpm_test`'s `tenant_default` (already
  recreated by the reprovisioning event) and additive for `bpm_dev`'s `tenant_default`
  (currently missing).
- No data migration, no `INSERT`, no `DROP` — purely additive DDL.
- Idempotent and safe to run against any tenant schema in any state (matches GBL-134's
  "Safety properties" #3).

## 6. Linter interaction (`tools/lint_dual_schema_table_names.py`)

Checked whether this linter encodes the same 4-table misclassification per ISS-0620's
own acceptance criteria — it does not; it only carries a `HYBRID` `ALLOW_LIST` of 9
names (`artifact_activation_history`, `artifact_activations`, `artifact_versions`,
`event_type_registry_producers`, `oidc_migration_item`, `oidc_migration_job`,
`repository_artifacts`, `tenant`, `tenant_hostnames`), none of which are the 4 tables in
this issue.

However, once this forward-fix recreates `tenant_default.<table>` for the 4 names, the
linter's `information_schema.tables` INTERSECT query will find all 4 names present in
BOTH `public` and `tenant_default` again — because GBL-135 never dropped the `public`
copies (they were never in its `v_tables` array either; GBL-135 only ever targeted the
14 names in its own list, none of which overlap this issue's 4). Dropping the now-stray
`public` copies would fix that cleanly, but is itself a **destructive DROP** and is
explicitly out of scope for this run's safety constraint (recovery/removal of existing
data structures needs separate review, not bundled into a forward-fix). This design
therefore adds the 4 names to the linter's `ALLOW_LIST`, with a comment explaining they
are a **known, intentional, temporary duplicate** pending a future (separately reviewed)
migration that drops the stray `public` copies. This is the same "additive-fix-now,
destructive-cleanup-later" split GBL-136 used for `artifact_versions`'s expected
RESTRICT failures — the correct action is documented and deferred, not silently
worked around.

## 7. GBL-134 header correction

Add a corrective note to `GBL-134`'s header comment (do not delete or rewrite the
migration body — it already executed and is immutable, matching GBL-136's treatment of
GBL-134), referencing ISS-0620/GH-573 and explaining that 4 of the 24 names in its
`v_tables` array were misclassified (should have been PER_TENANT, not GLOBAL_REGISTRY),
with a pointer to `GBL-137` as the forward-fix.

## 8. Acceptance criteria

- [x] Scope confirmed precisely for both known-affected databases (§2).
- [x] Non-local/production exposure explicitly checked and refuted (§2).
- [x] No destructive/recovery action executed; "no obvious recovery path found" is
      reported, not acted on (§2).
- [x] `GBL-137_iss0620_recreate_per_tenant_shadows.sql` created, additive-only, FK-free,
      schema-verified against the original creating migrations (§3-§5). Applied and
      verified idempotent against both `bpm_dev` (genuine creation, tables were missing)
      and `bpm_test` (clean no-op, tables already existed from an unrelated
      reprovisioning event — see ISS-0623/GH-580) via both raw `psql` and the real
      `zig build migrate` runner.
- [x] `GBL-134`'s header corrected with a note, migration body untouched (§7).
- [x] `tools/lint_dual_schema_table_names.py`'s `ALLOW_LIST` updated with the 4 names and
      an explanatory comment (§6). Verified: linter no longer flags these 4 names against
      either database.
- [ ] Routed to CODE-DESIGN-VALIDATOR for review before this migration is treated as
      final.

## 9. Out of scope

- Dropping the now-stray `public` copies of the 4 tables (destructive; needs its own
  reviewed migration and its own issue).
- Any data-recovery action for rows that may have existed in `tenant_default` before
  GBL-134's drop (no recovery path was found; see §2).
- Diagnosing why `bpm_test`'s `tenant_default` schema was fully dropped and reprovisioned
  at 08:19:53 UTC on 2026-08-08, or why migration 094's `-- scope: public` header did not
  prevent that replay from re-applying it (noted in §2 as a separate, non-blocking
  observation — most likely a stale migrate binary from a sibling workspace acting
  against the shared `bpm_test` container).
