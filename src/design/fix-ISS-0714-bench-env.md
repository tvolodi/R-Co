# Fix Design — ISS-0714 / GH #809: dev-DB default-tenant ledger reconciliation (bench env)

- **Run / step:** WF03-iss0714-bench-env-20260816 · WF-03 Step 2 (CODE-DESIGNER)
- **Issue:** ISS-0714 / GH #809 — "bench env: dev DB default-tenant schema provisioning fails (tenant_schemas.migrations_applied_at NULL) blocks WF-04"
- **Handoff:** `handoffs/WF03-iss0714-bench-env-20260816/step-2-code-designer.json`
- **Artifact:** this file — `src/design/fix-ISS-0714-bench-env.md`
- **Consumer:** BACKEND-DEV (Step 3 executes the reconciliation) → CODE-DESIGN-VALIDATOR

---

## 1. Purpose and scope

**Purpose.** Produce the exact, executable repair procedure for the dev/bench database
(`BPM_DB_URL` → `postgres://bpm:bpm@localhost:5442/bpm_dev`) whose default-tenant
provisioning is wedged: `public.tenant_schemas.migrations_applied_at` is NULL for the
default tenant (`00000000-0000-0000-0000-000000000000`, schema `tenant_default`) and
`public.schema_migrations` has zero rows for `schema_name = 'tenant_default'`, so
`provisionTenantSchema()` cannot take its Step-2 idempotency fast-path and re-runs the
whole migration chain from scratch, failing with SQLSTATE 42P16. The repair reconciles
the tenant-default migration ledger and stamps the registry so provisioning fast-paths,
`zig build migrate` exits 0, and `zig build bench` (WF-04) can start.

**Scope.** Dev-DB-only **data repair**. The reconciliation SQL/script below IS the fix.
No `src/*.zig` change and no `migrations/*.sql` change is required — the migration set is
proven correct by the healthy test DB (5434/bpm_test). This document does **not** execute
the repair; BACKEND-DEV runs it verbatim in Step 3. The alternative — `DROP SCHEMA
tenant_default CASCADE` + delete the `tenant_schemas` row and let provisioning rebuild —
is explicitly **rejected** as too invasive (destroys bench data) and is not part of this
design.

---

## 2. Root cause summary

Grounded in `docs/issues/ISS-0714.json` `root_cause_analysis` (analyzed 2026-08-16T10:57:18Z
by ISSUE-FIXER) and my own verification of `src/db/provisioning.zig`,
`src/db/migrations.zig`, `src/tools/migrate.zig`, and `migrations/`.

**Observed symptom.** `zig build bench` / `zig build migrate` against `BPM_DB_URL`
hard-exits 1 with `default tenant schema provisioning failed: error.MigrationFailed
(tenant_id=00000000-...)` then the ISS-0706/GH-791 leg-(d) post-condition
`post-condition: default tenant_schemas.migrations_applied_at is NULL after
provisionTenantSchema() returned -- aborting migrate`.

**Mechanism (state mismatch, not a migration defect).**

1. The dev DB's `tenant_default` schema is **already modern**: `events` is partitioned
   by `RANGE (created_at)` (created by `1147_par01_events_partitioning.sql`), plus
   `effects_outbox`, `plat_effect_completion`, `plat_partition_catalog`, the
   token-model `instance_projections` columns, partitions `events_2026_08/09/10`, etc.
   — 58 tables present.
2. Yet `public.schema_migrations` has **0 rows** for `schema_name='tenant_default'`
   (empty tenant migration ledger) and `public.tenant_schemas.migrations_applied_at`
   is **NULL** for the default tenant (row created 2026-08-15T05:45Z, never stamped).
3. `provisionTenantSchema()` Step 2 checks
   `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id=$1 AND migrations_applied_at IS NOT NULL`
   and only fast-paths when `count > 0`. With `migrations_applied_at` NULL it proceeds to
   Step 5 and calls `runForSchema('tenant_default')`, which replays the **entire**
   non-public-only chain from `001_event_store.sql` onward against the already-provisioned
   schema.
4. `001_event_store.sql` line 48 `CREATE UNIQUE INDEX IF NOT EXISTS uq_event_idempotency
   ON events(idempotency_key)` runs against the **already-partitioned** `events`; Postgres
   rejects any UNIQUE index that omits the partition key → SQLSTATE 42P16
   (`unique constraint on partitioned table must include all partitioning columns`).
   (Line 52 `uq_event_sequence` would fail identically.)
5. `runForSchema()` swallows the SQL error (`simpleQuery` catch → `ROLLBACK` →
   `MigrationFailed`, no per-migration logging) and `migrate.zig` logs only the enum name;
   the real error is only visible in the Postgres server log (`docker logs r-co-db-1`).
   The failure bubbles as `ProvisionError.MigrationFailed`, which trips the leg-(d)
   post-condition abort.

**Why this is not a migration-set defect.** The healthy test DB (`5434/bpm_test`) has the
identical partitioned `events` shape and migrates **147/147 public + 111 tenant_default**
with `migrations_applied_at IS NOT NULL`. On a fresh schema, `001`'s unique indexes are
created against a *regular* `events` table (`1147` converts it to partitioned later and
handles the index rebuild). The defect is purely the dev DB's empty tenant_default ledger
+ NULL `migrations_applied_at` coexisting with an already-modern schema.

**Ledger-content ground truth.** The tenant-default ledger must contain every migration
that runs in the per-tenant pass — i.e. everything that is **not** `public_only` per
`migrationScope()` (`GBL-` filename prefix, or `-- scope: public` header). Classification
on the current `migrations/` dir (replicated verbatim from `src/db/migrations.zig`):

| Scope | Count | Notes |
|---|---|---|
| `public_only` | 49 | 32 `GBL-*` + 17 numeric (`011,022,031,038,039,041,042,049,050,056,060,069,070,1134,1135,1144,1157`) |
| `all_schemas` | 89 | runs in public + every tenant pass |
| `tenant_only` | 9 | `026,093,095,096,1154,1156,1158,1159,1160` — tenant pass only |
| **tenant_default set** | **98** | `all_schemas` + `tenant_only` (89 + 9) |

The healthy test DB's tenant_default ledger has **111** rows. The 13-row delta is
ledger-history: files applied to tenant_default *before* ISS-0604 reclassified them to
`-- scope: public` (consistent with exactly `011,022,031,038,039,041,042,049,050,056,060,069,070`),
whose rows persist as an append-only record. Ledger rows are history — extra rows are
harmless. What matters is that the reconciled ledger is a **superset** of the 98 current
non-public-only files. The procedure in §3.4 both (a) copies the canonical 111 from the
test DB and (b) adds a completeness guard that guarantees all 98 current files are present.

---

## 3. Reconciliation procedure

### 3.1 Public interface — repair surface

| Object | Touch | Exact statement shape |
|---|---|---|
| `public.schema_migrations` | INSERT only (schema_name = `'tenant_default'`) | `(schema_name, version)`; `applied_at` defaults to `NOW()`; PK `(schema_name, version)`; `ON CONFLICT DO NOTHING` |
| `public.tenant_schemas` | UPDATE only (default tenant row) | `SET migrations_applied_at = NOW() WHERE tenant_id = '00000000-0000-0000-0000-000000000000'::uuid` |
| advisory lock | session-scoped, keyed by default tenant | `pg_advisory_lock(hashtext('bpm.provisioning.provisionTenantSchema:' \|\| '<tenant>')::bigint)` — the same key `provisionTenantSchema()` uses |

Schema of `public.schema_migrations` (exact, from `migrations.zig` / `migrate.zig`
`CREATE TABLE IF NOT EXISTS`, plus the `INSERT` used by the runner):

```sql
schema_name TEXT        NOT NULL DEFAULT 'public',
version     TEXT        NOT NULL,
applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
PRIMARY KEY (schema_name, version)
```

There is **no** checksum, description, or name column — the ledger is exactly
`(schema_name, version, applied_at)`, and the runner's write path is
`INSERT INTO public.schema_migrations (schema_name, version) VALUES ($1, $2)
ON CONFLICT (schema_name, version) DO NOTHING` (ISS-0162). The repair uses the same
statement shape so the reconciled ledger is byte-identical in shape to what
`runForSchema()` itself would have written.

### 3.2 Preconditions (BACKEND-DEV must confirm before executing)

1. Dev/bench DB reachable at `BPM_DB_URL` (`postgres://bpm:bpm@localhost:5442/bpm_dev`).
2. Test DB reachable at `BPM_TEST_DB_URL` (`postgres://bpm:bpm@localhost:5434/bpm_test`).
3. `psql` on `PATH`.
4. The dev DB `tenant_default` schema is confirmed modern **before** writing any ledger
   row (Step D-4 spot-checks re-confirm this afterwards). If the schema is NOT modern,
   STOP — do not reconcile (the ledger must not claim versions whose objects are absent).

### 3.3 Step A — serialize against concurrent provisioning (advisory lock)

The whole reconciliation runs in **one `psql` session** on the dev DB. The first statement
takes the **session-scoped** advisory lock on the default tenant — the exact key
`provisionTenantSchema()` uses (`src/db/provisioning.zig`
`advisoryLockKeyPrefix = "bpm.provisioning.provisionTenantSchema:"` +
`hashtext(...)::bigint`). A concurrent `provisionTenantSchema()` for the default tenant
queues behind this lock; the lock is released by the explicit unlock (or automatically
when the session ends). It is session-scoped (not `_xact_`) because it must survive the
transaction in §3.4–§3.5.

```sql
-- First statement in the single psql session against BPM_DB_URL:
SELECT pg_advisory_lock(hashtext(
    'bpm.provisioning.provisionTenantSchema:' || '00000000-0000-0000-0000-000000000000'
)::bigint);
```

### 3.4 Step B — populate the tenant_default migration ledger

**Canonical source: the healthy test DB's tenant_default ledger (5434/bpm_test) — 111
rows.** This is the ground truth of what a healthy DB's tenant_default ledger looks like
and is the source the task designates as canonical. The insert is idempotent
(`ON CONFLICT DO NOTHING`), so re-running is safe.

**B-1 — export the canonical ledger from the test DB** (PowerShell, one-shot):

```powershell
# Exactly 111 rows; abort if the count differs.
$ledger = psql "$env:BPM_TEST_DB_URL" -Atc `
  "SELECT version FROM public.schema_migrations WHERE schema_name = 'tenant_default' ORDER BY version"
if ($ledger.Count -ne 111) { throw "expected 111 canonical ledger rows, got $($ledger.Count)" }
```

**B-2 — materialize the exact INSERT statements** (one per row, same shape the runner
uses; migration filenames contain no `'`, so no escaping is needed):

```powershell
$inserts = $ledger | ForEach-Object {
  "INSERT INTO public.schema_migrations (schema_name, version) VALUES ('tenant_default', '$_') ON CONFLICT (schema_name, version) DO NOTHING;"
}
Set-Content -Path scratch/reconcile_iss0714.sql -Value $inserts -Encoding ascii
```

**B-3 — completeness guard (union with the current on-disk chain).** Guarantees the
reconciled ledger covers all **98** current non-public-only files even if the test DB
ledger is stale relative to `migrations/`. Replicates `migrationScope()` exactly
(`GBL-` prefix, `-- scope: all_schemas` / `-- scope: public` / `-- scope: tenant_only`
substring in the first 4 KiB, else `all_schemas`; skip `public_only` for the tenant pass).
On the current tree this adds nothing (the canonical 111 already contains all 98) — it is
a safety net, and its output must be exactly 98 files:

```python
# Generates INSERTs for any current non-public-only migration missing from the ledger
# (script body; run once, output appended to scratch/reconcile_iss0714.sql).
from pathlib import Path
for p in sorted(Path("migrations").glob("*.sql")):
    name = p.name
    hdr = p.read_bytes()[:4096].decode("utf-8", "replace")
    if name.startswith("GBL-"):              scope = "public_only"
    elif "-- scope: all_schemas" in hdr:     scope = "all_schemas"
    elif "-- scope: public" in hdr:          scope = "public_only"
    elif "-- scope: tenant_only" in hdr:     scope = "tenant_only"
    else:                                    scope = "all_schemas"
    if scope == "public_only":
        continue  # never recorded in a tenant schema ledger
    print(f"INSERT INTO public.schema_migrations (schema_name, version) "
          f"VALUES ('tenant_default', '{name}') ON CONFLICT (schema_name, version) DO NOTHING;")
```

Assert the guard produced **98** candidate filenames (89 `all_schemas` + 9 `tenant_only`).
After B-2 ∪ B-3, `scratch/reconcile_iss0714.sql` contains ≥ 111 unique statements and
covers every current non-public-only file.

### 3.5 Step C — stamp the default tenant as fully provisioned

Append to the same `scratch/reconcile_iss0714.sql` (inside the same transaction as Step B)
so Steps B + C commit atomically:

```sql
UPDATE public.tenant_schemas
   SET migrations_applied_at = NOW()
 WHERE tenant_id = '00000000-0000-0000-0000-000000000000'::uuid;
```

This is the exact statement `provisionTenantSchema()` Step 6 issues (minus the `$1`
placeholder); it is idempotent (re-stamps `NOW()`).

### 3.6 Execute + release the lock (atomic)

Assemble the full file in this order and run it against the dev DB in **one** session,
aborting on any error (`ON_ERROR_STOP=1`), so a mid-run failure rolls everything back
and leaves the dev DB untouched:

```text
1.  SELECT pg_advisory_lock(   ...   );          -- §3.3 Step A
2.  BEGIN;                                        -- one transaction for B + C
3.  INSERT ... ON CONFLICT DO NOTHING;            -- §3.4 Step B (111 + guard rows)
4.  UPDATE public.tenant_schemas ... NOW() ...;   -- §3.5 Step C
5.  COMMIT;
6.  SELECT pg_advisory_unlock( ... );             -- release Step A lock
```

```powershell
# Execute (BACKEND-DEV runs this — the design does not):
psql "$env:BPM_DB_URL" -v ON_ERROR_STOP=1 -f scratch/reconcile_iss0714.sql
if ($LASTEXITCODE -ne 0) { throw "reconciliation failed" }
```

### 3.7 Data flow and state transition

```mermaid
flowchart LR
    A[dev DB tenant_default<br/>schema modern, ledger empty,<br/>applied_at NULL] -->|Step A lock| B[Reconcile:<br/>INSERT 111+ ledger rows,<br/>ON CONFLICT DO NOTHING]
    B --> C[Step C:<br/>UPDATE tenant_schemas<br/>migrations_applied_at = NOW]
    C --> D[zig build migrate:<br/>provisionTenantSchema fast-paths,<br/>public backlog applies]
    D --> E[zig build bench<br/>WF-04 starts]
    E --> F[PASS: ledger covers 98 current<br/>non-public-only files, objects present]
```

State machine on `tenant_schemas.migrations_applied_at` (default tenant):
`NULL` (wedged; re-runs chain → 42P16) → **repair** → `NOW()` (fast-path; `runForSchema`
never re-runs, so no object churn).

---

## 4. Safety

- **Advisory lock.** The tenant-keyed session lock (§3.3) is the same key
  `provisionTenantSchema()` uses, so the repair cannot race a concurrent provisioning of
  the default tenant. Acquire/release on the same connection; release is explicit and also
  automatic on session close.
- **Idempotent.** Every ledger write uses `ON CONFLICT (schema_name, version) DO NOTHING`;
  the `tenant_schemas` UPDATE only re-stamps `NOW()`. Re-running the reconciliation is a
  no-op after the first success.
- **No destructive operations.** The repair only ever **INSERTs** ledger rows and
  **UPDATEs** one timestamp. No `DELETE`, `DROP`, `TRUNCATE`, or schema change. The
  rejected alternative (`DROP SCHEMA tenant_default CASCADE`) is explicitly out of scope.
- **Atomic.** Steps B + C run in one transaction with `ON_ERROR_STOP=1`; any failure
  rolls back and the dev DB is byte-identical to its pre-repair state.
- **Confinement.** Only two tables are touched — `public.schema_migrations` (rows for
  `schema_name='tenant_default'`) and `public.tenant_schemas` (default tenant row). No
  other tenant schema, no other ledger row, no code, no migration files.
- **Rollback on verification failure.** If any Step-D gate fails (exit code ≠ 0, count
  mismatch, or a spot-check object is absent), **do not** run `zig build bench`. Nothing
  destructive has occurred, so the DB is safe; investigate before retrying. A spot-check
  failure (object absent for a ledgered version) means the schema is **not** actually
  modern — STOP and escalate to ORCH (do not paper over it with a ledger row).
- **Public-backlog interaction.** After repair, `zig build migrate` applies the pending
  public backlog (`GBL-116..143` + `1134..1162` = 59 files). None of them deletes rows from
  `public.schema_migrations`: `GBL-132` only drops a physical shadow `schema_migrations`
  *table* inside tenant schemas (created by old unqualified DDL), never `public`
  rows; `GBL-133`'s public row is already applied; `GBL-138/139/140/141/142` only drop
  duplicate shadow *tables* in `tenant_default`. The reconciled tenant-default ledger is
  therefore not modified by the backlog.

---

## 5. Verification gates

Run in order; each gate must pass before the next. `zig` commands use
`BPM_DB_URL=postgres://bpm:bpm@localhost:5442/bpm_dev`.

| # | Gate | Command / assertion | Expected |
|---|---|---|---|
| D-1 | Ledger populated | `SELECT count(*) FROM public.schema_migrations WHERE schema_name='tenant_default'` | `>= 111` (report actual) |
| D-2 | Current chain covered | Every one of the 98 non-public-only `migrations/*.sql` files has a `tenant_default` ledger row (diff the B-3 list against `SELECT version ... WHERE schema_name='tenant_default'`) | 0 missing |
| D-3 | Registry stamped | `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id='00000000-0000-0000-0000-000000000000'::uuid AND migrations_applied_at IS NOT NULL` | `1` |
| D-4 | Objects match ledger (spot-check) | `SELECT relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='tenant_default' AND c.relname='events'` | `p` (partitioned) |
| D-4 | … partitioning version recorded | `SELECT count(*) FROM public.schema_migrations WHERE schema_name='tenant_default' AND version='1147_par01_events_partitioning.sql'` | `1` |
| D-4 | … schema breadth | `SELECT count(*) FROM information_schema.tables WHERE table_schema='tenant_default'` | `58` |
| D-5 | Migrate fast-paths | `zig build migrate` with `BPM_DB_URL` set | exit `0`; provisioning fast-paths; leg-(d) post-condition passes; public backlog applies |
| D-6 | Bench proceeds | `zig build bench` (WF-04 full NFR) | starts and runs to completion |
| D-7 | No test-DB regression | `zig build migrate` with `BPM_TEST_DB_URL=...5434/bpm_test` | exit `0`; still `147/147 public + 111 tenant_default` |

### 5.1 Error taxonomy — reconciliation failure modes

| Failure mode | Symptom | Handling |
|---|---|---|
| Wrong count at B-1 | canonical ledger ≠ 111 | STOP before writing anything; do not guess — investigate why the test DB differs (may be a stale test DB, not a dev-DB problem) |
| Connection failure (dev/test DB) | psql connect error / non-zero exit | re-check `BPM_DB_URL` / `BPM_TEST_DB_URL`; do not retry blind |
| Lock contention | `pg_advisory_lock` blocks | expected; a concurrent provisioning finishes, then the lock is granted |
| INSERT violates PK / any error mid-file | `ON_ERROR_STOP` aborts | `ROLLBACK` → dev DB unchanged; re-run is idempotent |
| D-1/D-2 fail | ledger count or coverage short | re-run reconciliation (idempotent) before touching anything else |
| D-4 object absent | spot-check returns `''`/`0` | **STOP** — schema is not actually modern; escalate (ledger must not claim absent objects) |
| D-5/D-6 fail after repair | migrate/bench non-zero | inspect migrate output + Postgres server log (`docker logs r-co-db-1`) for the real SQL error; escalate with evidence |

---

## 6. Notes and open questions

- **Re-running `zig build migrate` alone does NOT fix this.** Until the ledger is
  reconciled and `migrations_applied_at` is stamped, every migrate re-enters
  `runForSchema('tenant_default')` and `001_event_store.sql:48` keeps failing with 42P16
  against the already-partitioned `events`. The ledger reconciliation (§3) is a
  prerequisite, not an alternative, to running migrate.
- **Dev-DB-only.** No `src/*.zig` and no `migrations/*.sql` change is required. The
  migration set is proven correct by the healthy test DB.
- **111 vs 98 — expected, not an anomaly.** The healthy test DB's tenant_default ledger
  (111) is a superset of the current 98-file non-public-only chain; the 13 extra rows are
  ledger history from files reclassified to `-- scope: public` after having been applied
  to tenant_default. The reconciliation copies the 111 and adds the 98-coverage guard, so
  it is correct whether or not the test DB is itself fully current.
- **Why source from the test DB and not a hand-derived list.** `migrationScope()` uses a
  substring match on the first 4 KiB of each file, so prose mentions inside a file can
  classify it (`094`/`1140` mention `-- scope: all_schemas`; `1156` ends its header with a
  period: `-- scope: tenant_only.`). The test DB ledger is the ground truth of what the
  runner actually recorded, avoiding any divergence between the design's reading and the
  runner's.
- **Open question (flag for REQ-ANALYST / ORCH, non-blocking):** none blocking. The only
  residual unknown is *which* 13 rows are the historical extras on the test DB — the
  completeness guard makes this irrelevant to correctness, and D-2 records the actual
  superset diff at execution time.
- **Next action:** route this design to CODE-DESIGN-VALIDATOR (Step 2b hard gate), then
  BACKEND-DEV (Step 3) executes §3 exactly, then TEST-RUNNER/RELEASE-VALIDATOR re-runs
  `zig build bench`.
