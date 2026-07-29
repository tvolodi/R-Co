# Process: Tenant Migration Fanout and Resume

| Field | Value |
|-------|-------|
| Process ID | `sys-tenant-migration-fanout` |
| Owner | Platform Admin |
| Scope | System-wide (every tenant schema) |
| Platform Workflow | PW-04 |
| Requirements | MIG-01, MIG-02, MIG-03, MIG-04, MIG-05, MIG-06 |
| Source | `docs/workflows.yaml` (PW-04) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.4 |

## Summary

Applies one platform migration across every tenant schema with per-tenant state
held in a single cross-tenant control table, `platform.platform_migrations`.
A failure in tenant N is recorded and the fanout continues with tenant N+1.
The run is resumable for exactly the tenants that are `pending` or `failed`, and
re-running a completed migration is a no-op for tenants already `done`. This
replaces the single-sweep startup advisory lock in `src/db/provisioning.zig`,
whose per-schema `schema_migrations` table carries no cross-tenant state, no
partial-failure tolerance, no resume and no status surface.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Platform Admin | System operator | Starts a fanout, reads status, triggers resume |
| BPM Platform | System | Iterates tenants, applies DDL, records per-tenant state |
| PostgreSQL | Database | Executes DDL and the control-row upsert inside one transaction per tenant |
| Tenant Onboarding | System | Applies the full migration set to a tenant created after a fanout snapshot |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `migration_id` | string | Numbered migration identifier present in `migrations/`; immutable once applied anywhere |
| `tenant_id` | UUID (optional) | Present for a single-tenant run; omitted for a full fanout |
| `run_id` | UUID | Generated per fanout invocation; carried on every control-row write |
| Enabled tenant list | UUID[] | Snapshot of tenants with `status = active`, ordered by `tenant_id` |
| DDL steps | SQL[] | The statements of `migration_id`, applied in file order |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Platform Admin | `POST /api/v1/admin/migrations/run` with `migration_id`, `tenant_id` omitted | Caller holds the platform-operator role? | -> 403 Forbidden if not | MIG-06 |
| 2 | Platform | Resolve `migration_id` against the files in `migrations/` | Identifier is unknown? | -> 404 `UnknownMigration`; no control rows are written | MIG-06 |
| 3 | Platform | Take `pg_try_advisory_lock(hashtext(migration_id))` on the platform database | Lock already held? | -> 409 `MigrationAlreadyRunning`; one fanout per `migration_id` at a time | MIG-03 |
| 4 | Platform | Snapshot the enabled tenant list, ordered by `tenant_id` | List is empty? | -> 200 with zero counts; the lock is released | MIG-03 |
| 5 | Platform | Seed `platform.platform_migrations` with one row per `(migration_id, tenant_id)` at `status = 'pending'`, using `ON CONFLICT (migration_id, tenant_id) DO UPDATE ... WHERE status != 'done'` | A row is already `done`? | The conflict clause leaves it untouched; that tenant is skipped by the loop | MIG-01, MIG-05 |
| 6 | Platform | For the next tenant in the snapshot, open one transaction against that tenant schema | Tenant row is already `done`? | Skip to the next tenant without opening a transaction | MIG-05 |
| 7 | PostgreSQL | Apply the DDL steps of `migration_id` in file order inside that transaction | A statement raises? | The transaction rolls back; no partial DDL survives in this schema | MIG-02 |
| 8 | PostgreSQL | Upsert the control row to `status = 'done'`, `completed_at = now()`, `error_msg = NULL` inside the same transaction as the DDL | -- | DDL and control row commit together or roll back together | MIG-02 |
| 9 | Platform | Record the per-tenant failure in its own transaction after the rollback: `status = 'failed'`, `error_msg` set to the SQLSTATE and message | Failure occurred? | Continue with tenant N+1; a failure never aborts the fanout | MIG-03 |
| 10 | Platform | Repeat steps 6 to 9 until the snapshot is exhausted | -- | Every tenant in the snapshot holds a `done` or `failed` row | MIG-03 |
| 11 | Platform | Release the advisory lock and return aggregate counts | -- | -> 200 with `{run_id, done, failed, pending}` | MIG-03, MIG-06 |
| 12 | Platform Admin | `GET /api/v1/admin/migrations/{migration_id}/status` | -- | -> 200 with `pending`, `done`, `failed` counts and a per-tenant list carrying `error_msg` and `completed_at` | MIG-06 |
| 13 | Platform Admin | `POST /api/v1/admin/migrations/{migration_id}/resume` | Caller holds the platform-operator role? | -> 403 Forbidden if not | MIG-06 |
| 14 | Platform | Read the resume set through the partial index `platform_migrations_resume_idx ON (migration_id, status) WHERE status IN ('pending','failed')` | Resume set is empty? | -> 200 with zero counts; the migration is complete across all tenants | MIG-01, MIG-04 |
| 15 | Platform | Apply steps 6 to 9 for exactly the tenants in the resume set | A tenant is `done`? | It is absent from the partial index and is never re-applied | MIG-04, MIG-05 |
| 16 | Platform | Re-run of an already complete migration | Every row is `done`? | The conflict clause makes the run a no-op; the counts show `done` unchanged | MIG-05 |
| 17 | Tenant Onboarding | Provision a tenant created after step 4's snapshot | -- | The onboarding path applies the full migration set and inserts `done` rows for every `migration_id`, so the new tenant is never left behind by a concurrent fanout | MIG-03 |
| 18 | Platform Admin | Correct a defective migration | DDL was already applied to some tenants? | Author a new `migration_id` that fixes forward, then run its own fanout. No reverse DDL is issued across schemas | MIG-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| One control table | `platform.platform_migrations` holds one row per `(migration_id, tenant_id)` with `status` in `pending`, `done`, `failed`, plus `error_msg`, `completed_at`, `run_id`. `UNIQUE (migration_id, tenant_id)` is the upsert anchor |
| Resume index | Partial index on `(migration_id, status) WHERE status IN ('pending','failed')` covers the resume query, so resume cost scales with the outstanding set rather than the tenant count |
| Atomic per tenant | The control-row upsert commits in the same transaction as that tenant's DDL. A `done` row therefore proves the DDL committed |
| Failure recorded separately | The `failed` row is written after the tenant transaction has rolled back, in its own transaction, so the rollback does not discard the failure record |
| Continue on failure | Tenant N failing never blocks tenants N+1 through M. The fanout completes the snapshot in every case |
| Idempotent | `ON CONFLICT (migration_id, tenant_id) DO UPDATE ... WHERE status != 'done'` makes a repeat run a no-op for completed tenants |
| Resume scope | Resume acts only on `pending` and `failed` rows. It never re-applies DDL to a `done` tenant |
| One run per migration | The advisory lock is keyed on `migration_id`, so two fanouts of the same migration cannot interleave. Different migrations may run concurrently |
| Fix forward | A defective migration is corrected by a new `migration_id`. Compensating DDL across tenant schemas is prohibited, because a partial compensation leaves schemas in divergent states |
| Migration files immutable | Once any tenant holds a `done` row for `migration_id`, the file contents are frozen. A change requires a new identifier |
| Ordered iteration | Tenants are processed in `tenant_id` order, so a failure list is reproducible between a run and its resume |

---

## Outputs

| Output | Description |
|--------|-------------|
| `platform.platform_migrations` rows | One per `(migration_id, tenant_id)` with `status`, `error_msg`, `completed_at`, `run_id` |
| Run result | `{run_id, done, failed, pending}` returned by run and resume |
| Status document | Per-tenant list from `GET /api/v1/admin/migrations/{migration_id}/status` |
| Applied schema change | DDL committed in each `done` tenant schema |
| Operator log entries | One line per tenant carrying `migration_id`, `tenant_id`, outcome, and duration |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Per-tenant statement budget | `statement_timeout` is set for the migration session; a statement exceeding it aborts that tenant's transaction and the tenant is recorded `failed` |
| Fanout duration | Bounded by tenant count times per-tenant duration. The run is asynchronous to the caller: the run endpoint returns `run_id` and the status endpoint reports progress |
| Advisory lock held | Held for the whole fanout on the platform database only. It never blocks tenant runtime traffic |
| Failed tenants outstanding | `GET .../status` reporting a non-zero `failed` count is the escalation signal; the operator reads `error_msg` per tenant and resumes after correcting the cause |
| Startup behaviour | Application startup no longer sweeps every schema; it verifies that no migration has outstanding `pending` rows and refuses to serve if any exist |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 Forbidden | Caller lacks the platform-operator role | Authenticate with platform-operator credentials |
| 404 `UnknownMigration` | `migration_id` matches no file in `migrations/` | Supply an identifier present in the migration set |
| 409 `MigrationAlreadyRunning` | Advisory lock for this `migration_id` is held | Read `GET .../status` and wait for the running fanout to finish |
| Per-tenant DDL failure | A statement raised inside the tenant transaction | Row set to `failed` with `error_msg`; correct the cause and call resume |
| `statement_timeout` | A statement exceeded the session timeout | Row set to `failed`; split the migration into smaller steps and resume |
| Control-row write failure | The `failed`-recording transaction itself failed | The row remains `pending`; resume picks it up because the partial index covers `pending` |
| Tenant schema absent | A tenant was deleted between snapshot and iteration | Row set to `failed` with `error_msg = 'schema absent'`; the row is closed manually once the tenant deletion is confirmed |
| Connection pool exhausted | No connection free for the next tenant | The fanout records `failed` for that tenant and continues; resume re-applies it |
| Partial fanout after process restart | The fanout process died mid-snapshot | The advisory lock is released with the session; outstanding tenants stay `pending` and resume completes them |
| Divergent schema found | A tenant schema already carries the change without a `done` row | The DDL fails, the tenant is recorded `failed`; the operator reconciles by writing the `done` row through a corrective migration rather than by hand-editing the control table |
