# Fix Design: ISS-0112 (GH-375) — entity_type_instances / entity_record_latest missing from tenant schemas

**Issue:** ISS-0112 (narrowed slice: entity subsystem)
**Severity:** MAJOR
**Run ID:** WF03-GH375-20260809
**Design Date:** 2026-08-09
**Author:** CODE-DESIGNER (WF-03 Step 2)

---

## 1. Problem Statement

### 1.1 Symptom

`zig build test-integration-exp` fails 5 of 13 tests in
`tests/integration/entity_subsystem_test.zig`, all in the `EXP-202` group
(create/update/delete/idempotency/pool-size-3 duplicate-append), each
crashing inside `getOrCreateEntityTypeInstance` (`src/entities/commands.zig`)
with a PostgreSQL error surfaced as `PoolError.QueryFailed` /
`PgError.ServerError`. Direct inspection of the live `bpm_test` database
confirms the underlying error is `42P01 relation
"tenant_default.entity_type_instances" does not exist` — the table exists
only in `public`.

### 1.2 Root Cause

`migrations/094_entity_subsystem.sql` declares `-- scope: all_schemas` (it
carries no `GBL-` prefix), so `src/db/migrations.zig`'s `runForSchema()`
walks it during the public pass AND every per-tenant pass
(`migrationScope()` returns `.all_schemas` for it). `runForSchema` prepares
each per-tenant pass with `SET search_path TO <schema>,public` and expects
migration bodies to reference tables **unqualified** so they resolve into
the target schema.

094's three `CREATE TABLE IF NOT EXISTS` statements
(`entity_definitions`, `entity_type_instances`, `entity_record_latest`) are
all explicitly `public.`-qualified. A `public.`-qualified statement ignores
`search_path` entirely — during the public pass it is a normal create;
during every tenant pass it is a silent no-op (`public.entity_type_instances`
already exists), so the tenant schema itself never receives the table. This
is the identical defect class already fixed for
`webhook_subscriptions.secret_ref` (ISS-0112/ISS-0635, migrations
1134/1138/1140) and documented in `src/design/fix-iss0112.md` and
`src/design/fix-iss0112-secret-ref.md`.

`GBL-137_iss0620_recreate_per_tenant_shadows.sql` already backfilled
`entity_type_instances`/`entity_record_latest`/`entity_definitions` (plus
`artifact_activation_groups`) into every tenant schema found in
`public.tenant` **at the time GBL-137 last ran** (2026-08-08). That backfill
is a one-time snapshot: it does not self-heal a tenant schema created or
reprovisioned afterward, because `provisionTenantSchema()` still only
invokes `runForSchema()`, and 094's qualified statements are still broken
for that path. This workspace's `bpm_test.tenant_default` was reprovisioned
after GBL-137 last ran and currently lacks both tables again — reproducing
exactly the "reprovisioning defeats a one-time backfill" pattern already
called out as the root cause of ISS-0112's earlier "REOPENED" status
(`docs/issues/ISS-0112.json`, 2026-08-08 occurrence, for the analogous
`secret_ref` column).

### 1.3 Affected Scope

- **Tables:** `entity_type_instances`, `entity_record_latest` (both
  referenced by `src/entities/commands.zig` with an explicit tenant-schema
  qualifier `{s}.entity_type_instances` / `{s}.entity_record_latest` —
  `getOrCreateEntityTypeInstance`, `ensureEntityInstanceProjection`,
  `createRecord`, `updateRecord`, `deleteRecord`, read paths).
- **Tests:** `tests/integration/entity_subsystem_test.zig` — 5 of 13
  `EXP-202` cases (create, update, delete, idempotency, pool-size-3
  duplicate-append). The other 8 cases (validation-only, no DB write
  through `getOrCreateEntityTypeInstance`) already pass.
- **Requirements:** EXP-201, EXP-202.
- **NOT in scope:** `entity_definitions`. `src/entities/definition.zig`
  queries it **unqualified**, so `search_path`'s trailing `,public` entry
  resolves it correctly regardless of which schema pass is active — it
  works today (by relying on the public fallback), and touching its storage
  location is a separate, non-blocking cleanup with no test currently
  failing because of it. Fixing it here would widen the diff without fixing
  any observed failure.

---

## 2. Solution Approach

### 2.1 Strategy

A new corrective migration, number **1140** (next free number after 1139),
NOT `GBL-`-prefixed and with no `-- scope:` header (defaults to
`all_schemas` per `migrationScope()`), re-declaring `entity_type_instances`
and `entity_record_latest` with **unqualified** `CREATE TABLE IF NOT
EXISTS` / `CREATE INDEX IF NOT EXISTS` statements. Because it is
`all_schemas`-scoped, `runForSchema()` walks it on the public pass (no-op —
both tables already exist in `public`) and on every tenant pass, present or
future, where `SET search_path` makes the unqualified names resolve into
that tenant schema and create whatever is missing. This is a durable fix
(every future `provisionTenantSchema()` call self-heals) rather than
another one-time backfill like GBL-137.

### 2.2 Why not edit 094 or GBL-137 directly?

Both have already been applied to the shared `bpm_test`/`bpm_dev`
databases (`public.schema_migrations` ledger rows exist for both) and
`zig build migrate` skips already-applied filenames — editing an applied
migration's body has no effect on a database that already ran it and
violates the project's immutable-migration convention (same reasoning
GBL-136/GBL-137 already documented for GBL-134).

### 2.3 Reference Patterns

- Table shape: `migrations/094_entity_subsystem.sql` (original) /
  `migrations/GBL-137_iss0620_recreate_per_tenant_shadows.sql` (identical
  shape, already proven correct for a one-time backfill).
- All-schemas corrective-migration idiom (no scope header, unqualified
  DDL, `CREATE TABLE IF NOT EXISTS`): `migrations/1138_iss0635_webhook_secret_ref_corrective.sql`.

---

## 3. Migration Structure

**File:** `migrations/1140_iss0112_entity_tables_tenant_scope_corrective.sql`

```sql
CREATE TABLE IF NOT EXISTS entity_type_instances (
    entity_type     TEXT        PRIMARY KEY,
    tenant_id       UUID        NOT NULL,
    instance_id     UUID        NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS entity_record_latest (
    tenant_id           UUID        NOT NULL,
    entity_type         TEXT        NOT NULL,
    record_id           UUID        NOT NULL,
    current_state       JSONB       NOT NULL DEFAULT '{}',
    version_seq         BIGINT      NOT NULL DEFAULT 0,
    entity_def_version  INTEGER     NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT pk_entity_record_latest PRIMARY KEY (entity_type, record_id)
);

CREATE INDEX IF NOT EXISTS idx_erl_tenant_type
    ON entity_record_latest (tenant_id, entity_type);
CREATE INDEX IF NOT EXISTS idx_erl_tenant_type_updated
    ON entity_record_latest (tenant_id, entity_type, updated_at DESC);
```

No dynamic SQL / tenant iteration needed — unlike GBL-prefixed correctives,
an `all_schemas`-scoped migration is invoked once per schema by the runner
itself, so plain unqualified DDL is sufficient and simpler.

### 3.1 Idempotency

- `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` — safe against
  schemas that already have these objects (public; any tenant GBL-137
  already backfilled) and schemas that don't (any tenant
  created/reprovisioned after GBL-137 ran, or created for the first time
  after this migration lands).
- No data mutation, no `ALTER`, no `DROP`.

### 3.2 No application code changes required

`src/entities/commands.zig` already queries `{s}.entity_type_instances` /
`{s}.entity_record_latest` correctly — the bug is purely in schema
provisioning, not in the Zig source.

---

## 4. Validation Steps

1. `zig build migrate` — exit 0, migration 1140 applied to `public` and
   `tenant_default` (and any other existing tenant schema).
2. Confirm via `docker exec ... psql -c "\d tenant_default.entity_type_instances"`
   and `\d tenant_default.entity_record_latest` that both tables now exist.
3. `zig build test-integration-exp` — all 13 EXP-201/EXP-202 tests pass (was
   8/13).
4. Re-run `zig build migrate` a second time — exits 0, no errors, ledger
   unchanged (idempotent second run per WF-03 acceptance criteria).

---

## 5. Dependencies

- `migrations/094_entity_subsystem.sql` (original table definitions, applied)
- `migrations/GBL-137_iss0620_recreate_per_tenant_shadows.sql` (prior
  one-time backfill, applied; this migration supersedes it going forward
  without modifying it)
- `src/db/migrations.zig` `runForSchema()` / `migrationScope()` (unchanged —
  this fix relies on existing, correct runner behavior)
- `src/entities/commands.zig` (unchanged — already queries correctly)

---

## 6. Design Classification

Per `templates/lego-catalog.md`:
- **Type:** C (Migration + test) / E hybrid — no new Zig source, only a
  corrective migration. Following the established convention for this
  issue family (`fix-iss0112.md`, `fix-iss0112-secret-ref.md`), documented
  here as a prose design (Type E) rather than a Type C parameter YAML,
  since it targets existing test coverage (`entity_subsystem_test.zig`)
  rather than authoring new test cases.
- **Output:** This prose design document; no Zig source changes; no new
  test file (existing `EXP-202` cases in `entity_subsystem_test.zig`
  already assert the correct behavior and currently fail for the reason
  diagnosed above).

---

## 7. Scope Note — relationship to the rest of GH-375

GH-375 (ISS-0112) originally reported 42 integration failures across
webhook dispatch (10, already fixed by GH-619/GH-618), ADP/OIDC migration
checks (~8), env03 (~5), EXP-201/202 entities (~3, addressed by this
design), service catalog (~6), env01/env02 (~2), and 8 other cases.

Re-running the full `test-integration-svc`/`test-integration-env` umbrella
(both build steps alias the same `tests/integration/main_test.zig`
aggregate) on current `main` shows 53 distinct failing tests across many
unrelated subsystems (effects/EXP-301, EXP-601 quotas, ISS-206 token
multisets, ADP-02/06/09/10, OIDC-09/12/15, XC-02/XC-06, OBS-03, IDN-03,
EE-09, and more) — this is the same broad, multi-root-cause cluster already
tracked comprehensively under **GH-482** ("test-integration-svc: 63 failing
blocks across 34 files, dominated by missing
`tenant_<uuid>.schema_migrations` ledger"), filed 2026-08-06 and still
open. GH-482's own dominant symptom (missing per-tenant `schema_migrations`
ledger) is a different, broader defect than the narrow entity-tables defect
fixed here. Rather than duplicate tracking, this run fixes only the
entity-subsystem slice (highest-confidence, single root cause, already
isolated by the narrow `test-integration-exp` build step) and leaves the
rest of GH-375's remaining scope to GH-482, which already names all the
affected files including `exp201_202_entities_test`, `env01_test`,
`env02_test`, `env03_test`, `svc01_service_catalog_scope_test`, and the
ADP/OIDC files GH-375 grouped as "ADP/OIDC migration checks".

---

**Design completed:** 2026-08-09
**Ready for:** CODE-DESIGN-VALIDATOR (Step 2b) → BACKEND-DEV (Step 3)
