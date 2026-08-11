# Module: mig-02-mig-03-platform-migration-fanout

**Requirement IDs:** MIG-02, MIG-03
**Run ID:** WF02-batch-0-20260811 (Stage 16)
**Covers:** MIG-02, MIG-03
**Depends on artefact:** `templates/specs/mig-01-platform-migrations-control-table.migration.yaml`
(MIG-01 — `platform.platform_migrations`, must land first; BACKEND-DEV should apply MIG-01's
migration before implementing this module)
**See also (not implemented here):** MIG-04 (resume endpoint), MIG-05 (idempotent re-run via
`ON CONFLICT ... DO UPDATE`), MIG-06 (admin HTTP surface), DDL-01 (pre-flight validation gate
ahead of the fanout) — all separate, later requirements. This design assumes a plain,
unvalidated DDL step per tenant; wiring DDL-01's `ValidatePlatformDDL` in front of the fanout
loop is a later batch's job and this module's call site for "apply DDL to a tenant" is the
seam where that gate will later be inserted (see Open questions).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No — this requirement adds no table/column beyond what MIG-01's own Type C
   artefact already covers. The behavior here is entirely control flow: transaction
   boundaries, an advisory lock, a snapshot-then-loop, and continue-on-failure accounting.
2. **Type A?** No single CRUD-shaped HTTP route maps 1:1 onto a store method — MIG-03's "run a
   migration across tenants" is a saga-shaped operation with per-tenant sub-transactions and
   aggregated failure handling, explicitly called out in `templates/lego-catalog.md`'s "What
   stays in Type E" list ("Cross-module orchestration sagas (e.g. tenant onboarding)").
3. **Type D?** No React Flow node.
4. **Type B?** No admin list page (MIG-06's admin surface, which WOULD plausibly want a list
   page over `platform_migrations`, is a separate later requirement).
5. **Type E — yes.** Novel, cross-cutting orchestration logic: advisory locking, per-tenant
   transaction boundaries with commit-with-DDL semantics, and continue-on-failure fanout
   accounting. No Lego template fits; this is exactly the kind of logic
   `templates/lego-catalog.md` reserves for a full prose design.

## Module purpose

`src/platform/migration_fanout.zig` applies one platform migration across every enabled
tenant, tracking per-tenant outcome in `platform.platform_migrations` (MIG-01). It has two
tightly coupled responsibilities that this design treats as one module because MIG-02's
transaction-boundary rule is not separable from MIG-03's loop — the loop's per-iteration body
*is* MIG-02's transaction protocol, called once per tenant in the snapshot:

- **MIG-02 (commit-with-DDL):** a tenant's control row moves to `done` in the exact same
  transaction as that tenant's DDL, so a `done` row is proof the DDL committed. A failure is
  recorded as `failed` in a separate transaction opened only after the DDL transaction has
  rolled back — never inside it, since the row write needs to survive the DDL's own rollback.
- **MIG-03 (fanout with continue-on-failure):** the loop runs over a snapshot of enabled
  tenants ordered by `tenant_id`, taken once at the start of the run; a single
  `pg_try_advisory_lock(hashtext(migration_id))` on the platform database serializes concurrent
  runs of the *same* `migration_id` (different migration IDs may run concurrently, since the
  lock key is derived from `migration_id`); and a per-tenant failure never stops the loop —
  every tenant in the snapshot gets a `done` or `failed` row by the time the run returns.

Building on SPT-01: this module reuses `src/db/pool.zig::Pool` for connection acquisition,
`src/db/provisioning.zig::schemaNameForTenant`-equivalent schema resolution (via
`pool_mod.schemaNameForTenant`, already public), and the same "acquire a connection, `SET
search_path`, run DDL" shape `src/db/migrations.zig::Migrations.runForSchema` already
establishes for the single-migration-file case — this module is that same protocol, generalized
to "one caller-supplied DDL step per tenant, called from a fanout loop with its own lock and
accounting," not a competing implementation of schema resolution or connection handling.

## Public interface

Request/response shape for a fanout run — MIG-03 AC5's `{run_id, done, failed, pending}`
counts, plus the inputs a caller needs to start one:

```zig
pub const FanoutRequest = struct {
    /// Identifies the migration being applied. Also the advisory-lock key
    /// input: pg_try_advisory_lock(hashtext(migration_id)).
    migration_id: []const u8,
    /// Caller-supplied correlation ID for this run, stored on every control
    /// row this run writes (platform.platform_migrations.run_id).
    run_id: []const u8,
};

pub const FanoutResult = struct {
    run_id: []const u8,
    done: u32,
    failed: u32,
    /// Always 0 at a normal return in this design (every snapshot tenant
    /// gets a done or failed row — MIG-03 AC1). Present because MIG-01's
    /// control table has a `pending` status and MIG-04's future resume path
    /// reads rows left pending by a crash mid-run; a clean run never leaves any.
    pending: u32,
};
```

Errors and the per-tenant DDL step callers supply — `DdlStep` is how a caller hands this
module the migration's actual work without the fanout logic needing to know what kind of DDL
it is running:

```zig
pub const FanoutError = error{
    /// MIG-03 AC2: another run already holds the advisory lock for this
    /// migration_id. Caller maps this to HTTP 409 MigrationAlreadyRunning.
    MigrationAlreadyRunning,
    PoolExhausted,
    /// Reading the enabled-tenant snapshot itself failed (distinct from a
    /// per-tenant DDL failure, which is caught and recorded, never raised).
    SnapshotQueryFailed,
};

/// One tenant's unit of DDL work, supplied by the caller. Runs inside the
/// per-tenant transaction this module opens; must not open or commit its
/// own transaction (see Dependencies — "must NOT depend on").
pub const DdlStep = *const fn (conn: *pool_mod.Conn, schema_name: []const u8) anyerror!void;

pub fn runFanout(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    request: FanoutRequest,
    step: DdlStep,
) FanoutError!FanoutResult;
```

Internal per-tenant helper — this is where MIG-02's transaction-boundary rule actually lives;
`runFanout`'s loop body is a thin wrapper that calls this once per snapshot row and folds the
outcome into the running `done`/`failed` counters:

```zig
const TenantOutcome = enum { done, failed };

/// Applies `step` for exactly one tenant under MIG-02's transaction
/// protocol. Never returns an error for a DDL failure — that is recorded as
/// TenantOutcome.failed, not raised. Only a failure to even attempt the
/// recording (both the primary commit path AND the separate failure-path
/// transaction failing) surfaces as a logged-but-swallowed condition, per
/// MIG-02 AC4 (see State transitions).
fn applyToTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    request: FanoutRequest,
    tenant_id: []const u8,
    step: DdlStep,
) TenantOutcome;
```

## Data flow

```
                        runFanout(request, step)
                                 │
                                 ▼
             pg_try_advisory_lock(hashtext(migration_id))
                     on a dedicated held connection
                                 │
                    lock NOT acquired ──────────► return error.MigrationAlreadyRunning
                                 │                        (caller → HTTP 409)
                    lock acquired
                                 ▼
        snapshot: SELECT tenant_id FROM public.tenant
                  WHERE status = 'ACTIVE' ORDER BY tenant_id
                  (taken ONCE — see State transitions for why a tenant
                   created after this point is deliberately NOT in it)
                                 │
                                 ▼
        seed control rows: one 'pending' row per snapshot tenant,
        UPSERT on (migration_id, tenant_id), run_id = request.run_id
                                 │
                                 ▼
              for tenant_id in snapshot (ascending order):
                                 │
                                 ▼
                    applyToTenant(tenant_id) ── MIG-02 protocol, below
                                 │
                    ┌────────────┴────────────┐
                    ▼                          ▼
                 done++                    failed++
                    │                          │
                    └────────────┬─────────────┘
                                 ▼
                    (loop continues regardless — MIG-03 AC1:
                     tenant N failing never stops N+1..M)
                                 │
                                 ▼
              pg_advisory_unlock (deferred; released even on early
              return, so a SnapshotQueryFailed still frees the lock)
                                 │
                                 ▼
              return FanoutResult{run_id, done, failed, pending: 0}
```

`applyToTenant` — the MIG-02 transaction protocol, expanded (this is the mechanism the ASCII
box above labels "MIG-02 protocol"):

```
        acquire a fresh connection for this tenant from the pool
                                 │
                                 ▼
                            BEGIN
                                 │
                     SET LOCAL search_path TO <tenant_schema>,public
                                 │
                                 ▼
                       step(conn, schema_name)   ◄── caller's DDL
                                 │
                 ┌────────── raises? ──────────┐
                 │ no                            │ yes
                 ▼                                ▼
   UPDATE platform.platform_migrations       ROLLBACK
   SET status='done', completed_at=now()          │
   WHERE (migration_id, tenant_id) = (…)           ▼
                 │                     (separate connection/transaction)
                 ▼                     BEGIN
              COMMIT                   UPDATE platform.platform_migrations
                 │                     SET status='failed', error_msg=<sqlstate+text>
                 ▼                     WHERE (migration_id, tenant_id) = (…)
          release connection           COMMIT
          return .done                      │
                                             ▼
                                      release connection(s)
                                      return .failed
```

## Error taxonomy

| Error / outcome | Raised by | Meaning |
|---|---|---|
| `error.MigrationAlreadyRunning` | `runFanout` | `pg_try_advisory_lock` returned false — another run holds this `migration_id`'s lock. Caller (MIG-06's future admin route) maps this to HTTP 409. MIG-03 AC2. |
| `error.PoolExhausted` | `runFanout`, `applyToTenant` | No connection available for the lock-holding connection, the snapshot query, or a per-tenant transaction. Propagates from `pool.zig::PoolError.ExhaustedPool`. |
| `error.SnapshotQueryFailed` | `runFanout` | The enabled-tenant `SELECT` itself failed. Distinct from any per-tenant outcome — nothing has been attempted yet, so nothing is recorded as `failed`; the advisory lock is still released via the deferred unlock before this propagates. |
| `TenantOutcome.done` | `applyToTenant` | `step` returned without error; the `done` UPDATE committed in the same transaction as `step`'s DDL (MIG-02 AC1). |
| `TenantOutcome.failed` | `applyToTenant` | `step` raised any error. The DDL transaction rolled back (MIG-02 AC2: "neither partial DDL nor a done row survives"), and the failure was recorded in a separate transaction (MIG-02 AC3). This is a **normal loop outcome**, not a Zig error — `runFanout` never propagates a single tenant's DDL failure as its own return error, precisely so the loop can continue (MIG-03 AC1). |
| *(swallowed, logged only)* | `applyToTenant`'s failure-recording step | MIG-02 AC4: if the separate failure-recording transaction ITSELF fails (e.g. the platform DB is briefly unreachable right after the tenant DDL rollback), the control row is left at whatever it already was — `pending`, from the seed step — and MIG-04's future resume query covers it. This module must not retry the failure-recording transaction in a loop and must not escalate this into a `runFanout`-level error, since doing so would abort the whole fanout over one tenant's bookkeeping hiccup, defeating MIG-03's continue-on-failure guarantee. It logs (`src/obs/logger.zig`) and moves on; the tenant is counted toward neither `done` nor `failed` in the returned `FanoutResult` for this run (it is implicitly `pending`, consistent with `FanoutResult.pending` existing for exactly this case). |

No error path in this table calls `catch unreachable` on a realistic failure — every DB
interaction either propagates a typed error (snapshot/lock/pool failures) or is deliberately
absorbed into the `TenantOutcome`/logged-and-continue design (per-tenant DDL and
failure-recording failures), per `docs/guides/backend_developer_guide.md §3.2`.

## State transitions

`platform.platform_migrations.status` (MIG-01's CHECK constraint: exactly `pending`, `done`,
`failed`):

```
                    (seed step, once per snapshot tenant)
                                 │
                                 ▼
                            [pending] ──────────────┐
                                 │                    │
                    step() succeeds,                  │ step() raises,
                    same-transaction commit            │ rollback, THEN a
                    (MIG-02 AC1)                        │ separate transaction
                                 │                       │ (MIG-02 AC3)
                                 ▼                        ▼
                            [done]                   [failed]
                          (terminal —                (NOT terminal: MIG-04's
                           MIG-05's future             future resume path
                           idempotent re-run            re-attempts a failed
                           never re-applies             row — out of scope
                           a done row)                  for this batch, but
                                                          this module's job is
                                                          only to make sure a
                                                          failed row is
                                                          correctly labelled
                                                          for that later path
                                                          to find via
                                                          platform_migrations_
                                                          resume_idx)
```

`[pending]` is also the row's state if the failure-recording transaction itself fails (see
Error taxonomy's swallowed case) — the row simply never leaves `pending`, which is why MIG-01's
partial index covers both `pending` and `failed`: MIG-04's future resume query needs to find
both "never attempted this run" and "attempted and failed" rows through the same index.

**Why the snapshot is taken once, and why that is correct, not a bug (MIG-03 AC4):** a tenant
created after `runFanout`'s snapshot `SELECT` has no `pending` row seeded for this
`migration_id` and is never visited by this run's loop. MIG-03 AC4 requires that such a tenant
still end up with a `done` row — but explicitly through "the tenant onboarding path," not
through this module reaching back into an already-executing fanout run. This module's
responsibility ends at "do not miss a tenant that already existed when the snapshot was taken
and do not attempt to chase tenants that show up mid-run" — see Dependencies for the seam
`src/db/provisioning.zig::provisionTenantSchema` needs to grow (in the same design's scope; see
Open questions) so newly onboarded tenants apply the full migration set for themselves.

## Dependencies

**Calls into:**
- `src/db/pool.zig::Pool.acquire`/`release` — connection lifecycle, exactly as SPT-01 already
  established. This module does not open its own raw connections.
- `pool_mod.schemaNameForTenant` (already `pub` in `src/db/pool.zig`) — schema-name derivation,
  reused rather than reimplemented, per this batch's explicit instruction to build on SPT-01
  rather than re-deriving tenant-schema-enumeration conventions.
- `platform.platform_migrations` (MIG-01) — read (snapshot seeding, idempotency) and written
  (status transitions) exclusively through this module's own SQL, always fully qualified as
  `platform.platform_migrations` (see the Type C YAML's implementer note: `platform` is never
  in any tenant's `search_path`, so an unqualified reference would be wrong here specifically,
  unlike the rest of the codebase's unqualified-table convention for `search_path`-resolved
  tables).
- `public.tenant` — the enabled-tenant snapshot source, filtered `WHERE status = 'ACTIVE'`,
  the same column `src/db/pool.zig`'s `applyRequestStorageRouting` already treats as
  authoritative tenant state (see `pool.zig:190` `SELECT storage_mode FROM public.tenant`).
- `src/obs/logger.zig` — structured logging for the swallowed failure-recording-transaction
  case in Error taxonomy.

**Must NOT depend on:**
- `src/engine/transition.zig` or anything in `src/engine/` — unrelated pure-computation
  boundary; no reason for a cross-import.
- Any HTTP/route layer (`src/api/routes/*`) — this module returns `FanoutError`/`FanoutResult`
  values; mapping `MigrationAlreadyRunning` to HTTP 409 and wiring an actual
  `POST /api/v1/admin/migrations/run` route is MIG-06's job (separate, later requirement). This
  module must stay callable from a future MIG-06 route handler, a script, or a test without
  ever importing `src/api/*` itself — the same layering `backend_developer_guide.md §5`
  enforces for route handlers not containing direct SQL, applied in the opposite direction
  here (a domain module not depending on the route layer).
- `DdlStep` implementations must NOT call `BEGIN`/`COMMIT`/`ROLLBACK` themselves — `runFanout`
  owns the transaction boundary (MIG-02's whole point is that the control-row write and the
  DDL share one transaction the fanout module opens and closes, not one the DDL step manages).
  This is a documented calling-convention constraint on `DdlStep`, not merely a comment: DDL-01,
  when it lands, must supply a `DdlStep` implementation that honors it.
- `src/db/migrations.zig::Migrations.runForSchema` is NOT called by this module. It is a
  superficially similar shape (acquire connection, `SET search_path`, run SQL, record a ledger
  row) but its ledger table (`public.schema_migrations`) and per-file-transaction model are the
  wrong grain for this requirement: MIG-01 explicitly "replaces reliance on the per-schema
  `schema_migrations` table as the only record of migration state" for the platform-migration
  use case. Reusing `runForSchema` here would reintroduce the two-trackers-disagreeing class of
  bug already documented in `docs/anti-patterns.md` ("Two subsystems each independently
  tracking the same 'has this already been applied?' state").

## Open questions

1. **Where does a `DdlStep` implementation come from before DDL-01 lands?** This batch defines
   the fanout mechanics and the `DdlStep` calling convention, but not a concrete `DdlStep` that
   runs real migration SQL — that requires either DDL-01's validating pass (out of scope) or an
   interim direct SQL-execution step. Recommend REQ-ANALYST/ORCH clarify whether stage 16
   expects a trivial pass-through `DdlStep` (execute a caller-supplied SQL string verbatim, no
   validation) as an interim measure, or whether `runFanout` should remain uncallable end-to-end
   until DDL-01 ships. This does not block MIG-02/MIG-03's own design — `runFanout`'s contract
   is fully specified either way — but it affects what BACKEND-DEV can wire up end-to-end in
   this batch versus stub for a follow-up.
2. **The onboarding-path amendment MIG-03 AC4 requires** ("a tenant created after the snapshot
   … the tenant onboarding path applies the full migration set and inserts done rows") is a
   change to `src/db/provisioning.zig::provisionTenantSchema` (or a sibling called from the
   onboarding saga) to also seed/complete `platform.platform_migrations` rows for every
   currently-known `migration_id`, not only run `runForSchema`'s file-based migrations. This
   design does not specify that change's shape in detail, since it lives in a different file
   with its own existing contract (SPT-01's `ProvisionError` set, its own advisory-lock
   protocol) — BACKEND-DEV implementing MIG-03 should treat "extend `provisionTenantSchema` to
   also backfill `done` rows in `platform.platform_migrations` for the tenant it just
   provisioned" as an explicit, separate sub-task of this same requirement, not an
   afterthought, since MIG-03 AC4 does not pass without it. Not marked as blocking this
   handoff's PASS status because the acceptance criterion is about the onboarding path's
   eventual behavior, which is squarely BACKEND-DEV implementation work following this design's
   `runFanout`/state-transition contract — no further design ambiguity remains.
