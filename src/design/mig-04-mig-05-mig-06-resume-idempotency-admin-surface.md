# Module: mig-04-mig-05-mig-06-resume-idempotency-admin-surface

**Requirement IDs:** MIG-04, MIG-05, MIG-06
**Run ID:** WF02-batch-1-20260811 (Stage 16)
**Covers:** MIG-04, MIG-05, MIG-06
**Extends:** `src/platform/migration_fanout.zig` (MIG-01/02/03's `runFanout`, `FanoutRequest`,
`FanoutResult`, `FanoutError` — see `src/design/mig-02-mig-03-platform-migration-fanout.md`),
`platform.platform_migrations` (MIG-01, `migrations/1144_platform_migrations_control_table.sql`)
**See also (not implemented here):** DDL-01 (the pre-flight validation gate a real `DdlStep`
must eventually pass through — same open seam MIG-02/03's design already left; unchanged by
this batch)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order, for the group as a whole and
noting where MIG-06 diverges:

1. **Type C?** No. MIG-05's body names `ON CONFLICT (migration_id, tenant_id) DO UPDATE ...
   WHERE status != 'done'` — this reads like a migration-adjacent change, but MIG-01's table
   (`migrations/1144_platform_migrations_control_table.sql`) already carries the exact
   `UNIQUE (migration_id, tenant_id)` constraint this upsert needs as its `ON CONFLICT` target;
   no column, index, or constraint is missing. The only thing that changes is the SQL text
   `seedPendingRow` in `migration_fanout.zig` issues (`INSERT ... ON CONFLICT ... DO NOTHING`
   becomes `INSERT ... ON CONFLICT ... DO UPDATE ... WHERE status != 'done'`) — a logic change
   to an existing Zig function, not a schema change. No new migration file is produced by this
   design.
2. **Type A?** Considered for MIG-06's three routes (`POST run`, `GET status`, `POST resume`).
   Rejected per `templates/lego-catalog.md` rule 2's own carve-out: "Skip if the handler needs
   custom business logic mid-flight — that is Type E." All three handlers do: `run` and `resume`
   call into `runFanout`/a new `resumeFanout` (a saga-shaped, per-tenant-transaction operation,
   the same "What stays in Type E" carve-out ("Cross-module orchestration sagas") batch-0's
   design already invoked for MIG-02/03); `status` aggregates counts and a per-tenant list from
   `platform.platform_migrations`, not a 1:1 store-method CRUD read. MIG-06 AC5's boot-time
   refusal check is not a per-request handler at all — it runs once, at process startup, before
   the HTTP server accepts any connection, which has no Type A/B shape whatsoever.
3. **Type D?** No React Flow node.
4. **Type B?** No admin *list page* (that is UI/React — MIG-06 is a pure HTTP/JSON admin
   surface with no `web/src` component in this requirement's text).
5. **Type E — yes**, for all three requirements together. MIG-04 (resume logic) and MIG-05
   (idempotent re-run) both directly extend `runFanout`'s existing control-flow, matching
   MIG-02/03's own classification rationale verbatim ("Novel, cross-cutting orchestration
   logic... No Lego template fits"). MIG-06 layers HTTP routes and a boot-time gate on top of
   that same extended module; both are novel/cross-cutting per the catalog's "What stays in Type
   E" list (cross-module orchestration sagas; anything a plain CRUD template would mask).

This design combines MIG-04, MIG-05, and MIG-06 into ONE artefact, following the precedent
`src/design/mig-02-mig-03-platform-migration-fanout.md` already set for MIG-02+MIG-03: none of
the three is separable from `migration_fanout.zig`'s existing transaction-boundary and fanout
contract, and MIG-06's routes are thin wrappers whose entire behavior is defined by MIG-04/05's
extended fanout functions underneath them.

## Module purpose

This batch extends `src/platform/migration_fanout.zig` (unchanged file, new functions/edits) and
adds a new `src/api/routes/platform_migrations.zig` (MIG-06's HTTP surface) plus a new boot-time
gate in `src/operations/` (MIG-06 AC5). Three responsibilities:

- **MIG-04 (resume):** `resumeFanout` applies a migration only to tenants whose control row is
  `pending` or `failed`, read through `platform_migrations_resume_idx` — never touching `done`
  rows. This is `runFanout`'s snapshot-then-loop shape (`src/design/mig-02-mig-03-platform-migration-fanout.md`'s
  Data flow section), but with the snapshot query changed from "every ACTIVE tenant" to "every
  tenant with a pending-or-failed row for this `migration_id`," and the seed step skipped
  entirely (resume never seeds a fresh `pending` row — every row it processes already exists).
- **MIG-05 (idempotency):** the existing `seedPendingRow` upsert (currently `ON CONFLICT ... DO
  NOTHING`, which leaves ANY existing row — done, pending, or failed — untouched) is replaced
  with `ON CONFLICT (migration_id, tenant_id) DO UPDATE ... WHERE status != 'done'`. This
  changes behavior for `failed` rows (they are now reset to `pending` with a fresh `run_id` on
  re-run, so the fanout loop re-attempts them) while preserving `runFanout`'s existing correct
  behavior for `done` rows (still untouched — a `WHERE status != 'done'` conflict clause simply
  never matches a `done` row, same practical effect as `DO NOTHING` did for that one case, but
  now expressed as the SAME clause that also handles `failed`). The fanout LOOP also gains a
  should-I-skip-this-tenant guard so a `done` tenant is never even given a transaction, per
  MIG-05 AC4 ("skipped without opening a transaction").
- **MIG-06 (admin surface):** three HTTP routes wrapping `runFanout`/`resumeFanout`/a new
  `queryMigrationStatus` read, all gated on `actor.role == .PLATFORM_ADMIN` (see Dependencies —
  "RBAC convention"), plus a boot-time check that refuses to start the server if any migration
  has outstanding `pending` rows.

## Public interface

### MIG-04 — resume

New request/result types, deliberately shaped to match `FanoutRequest`/`FanoutResult` field for
field so callers (MIG-06's resume route) can treat `runFanout` and `resumeFanout` uniformly:

```zig
pub const ResumeRequest = struct {
    migration_id: []const u8,
    run_id: []const u8,
};

pub const ResumeResult = struct {
    run_id: []const u8,
    done: u32,
    failed: u32,
    /// Count of rows that were pending/failed at resume start but were
    /// still pending because the tenant's own connection acquisition never
    /// even completed (mirrors FanoutResult.pending's meaning — "neither
    /// done nor failed was recorded this run" — never a normal outcome for
    /// a tenant that DID get a transaction opened for it).
    pending: u32,
};
```

```zig
pub const ResumeError = error{
    /// Same advisory-lock contention as MIG-03 AC2 — a resume run and a
    /// fresh run() (or another resume()) of the SAME migration_id must not
    /// interleave; both acquire the identical pg_try_advisory_lock(hashtext(migration_id))
    /// key runFanout already uses, so a resume() cannot race a run() for
    /// the same migration_id either.
    MigrationAlreadyRunning,
    PoolExhausted,
    /// The pending/failed-tenant snapshot query itself failed (distinct
    /// from a per-tenant DDL failure).
    SnapshotQueryFailed,
};

/// Applies `step` only to tenants whose platform.platform_migrations row
/// for `request.migration_id` is 'pending' or 'failed', read through
/// platform_migrations_resume_idx. A 'done' row is never re-applied (MIG-04
/// body). Reuses runFanout's applyToTenant (unexported today — see
/// Dependencies for the required visibility change) for the per-tenant
/// MIG-02 transaction protocol, so resume and a fresh run share the exact
/// same commit-with-DDL semantics (MIG-04 AC5: "Resume applies the MIG-02
/// rule").
pub fn resumeFanout(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    request: ResumeRequest,
    step: DdlStep,
) ResumeError!ResumeResult;
```

`resumeFanout`'s snapshot query (replaces `runFanout`'s existing enabled-tenant snapshot query,
unchanged in this batch, which selects active tenant IDs from the tenant registry table ordered
by id):

```sql
SELECT tenant_id::text
FROM platform.platform_migrations
WHERE migration_id = $1 AND status IN ('pending', 'failed')
ORDER BY tenant_id
```

This is exactly the shape `platform_migrations_resume_idx` (`ON (migration_id, status) WHERE
status IN ('pending', 'failed')`, `migrations/1144_platform_migrations_control_table.sql`) was
built to serve — MIG-04 AC3 requires the query plan to read through this index, which a
`migration_id = $1 AND status IN ('pending','failed')` predicate does verbatim (the same
predicate shape MIG-01's own Type C YAML's `resume_index_used_by_pending_or_failed_query` test
case already exercises via `EXPLAIN`). `ORDER BY tenant_id` satisfies MIG-04 AC4's
reproducibility requirement, matching `runFanout`'s existing `ORDER BY id` ordering discipline.

`resumeFanout` does NOT call `seedPendingRow` — every row it will touch already exists (it read
the row to find the tenant in the first place); seeding is `runFanout`'s job for a fresh run
only.

### MIG-05 — idempotent re-run

Two edits to existing `migration_fanout.zig` code, no new public types:

**1. `seedPendingRow`'s SQL** (currently `ON CONFLICT (migration_id, tenant_id) DO NOTHING`):

```sql
INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
VALUES ($1, $2::uuid, 'pending', $3)
ON CONFLICT (migration_id, tenant_id) DO UPDATE
SET status = 'pending', run_id = EXCLUDED.run_id
WHERE platform.platform_migrations.status != 'done'
```

The `WHERE status != 'done'` conflict-action guard is Postgres's per-row predicate on whether
the `DO UPDATE` fires at all: for a `done` row, the predicate is false, so Postgres silently
keeps the existing row completely unmodified (MIG-05 AC1: "no DDL executes... `completed_at` is
unchanged" — and neither does `status` or `error_msg`, satisfying AC3's stronger claim that ALL
THREE fields are left untouched, not merely `completed_at`). For a `failed` row, the predicate
is true, so the row resets to `pending` with a fresh `run_id`, which is what lets the fanout
loop (below) pick it back up (MIG-05 AC2).

**2. The fanout loop gains a per-tenant status check before calling `applyToTenant`** (MIG-05
AC4: a `done` tenant must be "skipped without opening a transaction against that tenant
schema" — the current loop unconditionally calls `applyToTenant`, which always opens a
connection and a transaction regardless of the row's post-seed status):

```zig
// After seedPendingRow, before the fanout loop's applyToTenant call:
for (tenant_ids) |tenant_id| {
    if (try isAlreadyDone(lock_conn, request.migration_id, tenant_id)) {
        done_count += 1; // counted as done without re-running step()
        continue;         // MIG-05 AC4: no connection acquired for this tenant
    }
    const outcome = applyToTenant(allocator, pool, request, tenant_id, step);
    // ... existing accounting
}
```

```zig
/// Cheap pre-check reusing the lock connection already held for the whole
/// run (no extra pool.acquire() call). Returns true only for a row that is
/// GENUINELY 'done' after seeding — the seed step above has already run by
/// the time this is called, so a row that WAS failed and just got reset to
/// pending by the ON CONFLICT DO UPDATE correctly returns false here and
/// falls through to applyToTenant.
fn isAlreadyDone(conn: *pool_mod.Conn, migration_id: []const u8, tenant_id: []const u8) PoolError!bool;
```

**3. Migration-file immutability (MIG-05 AC5):** "GIVEN any tenant holds a `done` row for
`migration_id`, WHEN the migration file content changes, THEN the change is rejected and a new
`migration_id` is required." This is a property of how `migration_id` values are minted and
compared, not of `runFanout`/`resumeFanout`'s runtime behavior — see Open questions §1 for the
one genuinely open design question in this whole batch.

### MIG-06 — admin surface

Three route handlers in a new `src/api/routes/platform_migrations.zig`, following the exact
shape `onboarding.zig`/`webhooks.zig`/`identity.zig` already establish (role check first line,
`errorResult(allocator, status, code)` helper, `HandlerResult{ status_code, body }` return —
see Dependencies, "RBAC convention," for the specific existing routes this pattern is drawn
from):

```zig
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// POST /api/v1/admin/migrations/run
/// Body: {"migration_id": "..."}
/// 403 if actor is not PLATFORM_ADMIN (MIG-06 AC1).
/// 404 UnknownMigration if migration_id names no file in the migration set,
/// writing no control rows (MIG-06 AC2) — see Open questions §2 for where
/// "the migration set" is enumerated from.
/// 409 if runFanout returns MigrationAlreadyRunning (MIG-03 AC2, unchanged).
/// 200 {"run_id","done","failed","pending"} on a completed fanout — MIG-03's
/// existing FanoutResult shape, serialised.
pub fn handleRunMigration(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult;
```

```zig
/// GET /api/v1/admin/migrations/{migration_id}/status
/// 403 if actor is not PLATFORM_ADMIN.
/// 200 {"migration_id","pending","done","failed","tenants":[{"tenant_id","status","error_msg","completed_at"}, ...]}
/// — MIG-06 AC3: "the three counts and a per-tenant list with error_msg and
/// completed_at." Read-only: a single SELECT over
/// platform.platform_migrations WHERE migration_id = $1, aggregated
/// in-process into counts (no COUNT/GROUP BY roundtrip needed — the
/// per-tenant list is already the full row set).
pub fn handleMigrationStatus(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    migration_id: []const u8,
) HandlerResult;
```

```zig
/// POST /api/v1/admin/migrations/{migration_id}/resume
/// 403 if actor is not PLATFORM_ADMIN.
/// 409 if resumeFanout returns MigrationAlreadyRunning.
/// 200 {"run_id","done","failed","pending"} — resumeFanout's ResumeResult,
/// serialised in the same shape handleRunMigration uses for FanoutResult.
pub fn handleResumeMigration(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    migration_id: []const u8,
) HandlerResult;
```

Fix-forward policy (MIG-06 body, "a defective migration is corrected by authoring a new
`migration_id`... issuing compensating DDL... is prohibited") is a PROCESS constraint on how
platform operators author migrations, not a runtime check any of these three handlers perform —
no code path in this module accepts or executes arbitrary/reverse DDL; the only DDL any handler
runs is whatever `DdlStep` the caller already wired to `runFanout`/`resumeFanout` (unchanged
from MIG-02/03's existing seam). MIG-06 AC4 is satisfied structurally: there is no "compensate"
or "rollback" endpoint in this surface, only `run`/`status`/`resume`, so issuing a NEW
`migration_id`'s own `run` IS the only correction path the API exposes.

### MIG-06 AC5 — boot-time refusal check

New function in `src/operations/`, following `startup_assertions.zig`'s established shape
exactly (see Dependencies — "Boot-time gate convention"):

```zig
pub const PendingMigrationError = error{
    OutstandingPendingMigrations,
    QueryFailed,
};

/// Query platform.platform_migrations for any row still 'pending'. If one
/// or more exist, emit a FATAL log line naming the migration_id(s) and
/// return error.OutstandingPendingMigrations — the caller (main.zig) exits
/// with EX_CONFIG (78), the same code startup_assertions.zig's existing
/// database-configuration gate already uses, before the HTTP server ever
/// starts accepting connections (MIG-06 AC5: "it refuses to serve traffic
/// and names the migration").
pub fn assertNoOutstandingMigrations(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
) PendingMigrationError!void;
```

Query:

```sql
SELECT DISTINCT migration_id FROM platform.platform_migrations WHERE status = 'pending'
```

If the result has any row, log `FATAL startup.platform_migrations OUTSTANDING_PENDING_MIGRATIONS
migration_ids=<comma-joined list>` (matching `startup_assertions.zig`'s existing `FATAL
<component> <CODE> key=value` log-line convention exactly, so the same alert-routing regex that
already matches `PG_VERSION_MISMATCH`/`PG_EXTENSION_MISSING`/`PUBLIC_SCHEMA_POLLUTION` also
matches this new gate) and return the error; `main.zig`'s `runApiServer` calls this immediately
after `startup_assertions.assertDatabaseConfiguration` (same call site style, added as a second
gate in the existing fail-fast sequence — see Dependencies).

## Data flow

### MIG-04/05 combined: seed → skip-done → resume-or-run

```
                    seedPendingRow (MIG-05: now DO UPDATE ... WHERE status != 'done')
                                 │
              ┌──────────────────┴───────────────────┐
              ▼                                        ▼
     row was 'done'                          row was 'failed' or absent
     → DO UPDATE predicate false              → DO UPDATE fires (existing failed
       → row COMPLETELY unchanged               row) or INSERT fires (absent row)
       (status/completed_at/error_msg           → row is now 'pending', fresh run_id
        all untouched — MIG-05 AC3)
              │                                        │
              ▼                                        ▼
     fanout loop: isAlreadyDone() check         fanout loop: isAlreadyDone() false
     returns true                                        │
              │                                          ▼
              ▼                                applyToTenant() — MIG-02 protocol,
     done_count += 1, continue                  unchanged from migration_fanout.zig
     (MIG-05 AC4: no pool.acquire(),
      no transaction opened for this
      tenant)
```

### MIG-04: resume — a separate entry point, no seed step

```
                    resumeFanout (MIG-04, a SEPARATE entry point from
                    runFanout — does not call seedPendingRow at all)
                                 │
                                 ▼
        snapshot: SELECT tenant_id FROM platform.platform_migrations
                  WHERE migration_id = $1 AND status IN ('pending','failed')
                  ORDER BY tenant_id
                  (served by platform_migrations_resume_idx — MIG-04 AC3)
                                 │
                                 ▼
              for tenant_id in snapshot (ascending order, MIG-04 AC4):
                                 │
                                 ▼
                    applyToTenant(tenant_id) — SAME MIG-02 protocol
                    migration_fanout.zig already implements, reused
                    verbatim (MIG-04 AC5)
                                 │
                    ┌────────────┴────────────┐
                    ▼                          ▼
                 done++                    failed++
                    │                          │
                    └────────────┬─────────────┘
                                 ▼
                    return ResumeResult{run_id, done, failed, pending: 0}
```

### MIG-06: request → role gate → domain call → response

```
   HTTP request                                    Process startup (once,
   POST/GET .../admin/migrations/...                before HTTP server binds)
        │                                                    │
        ▼                                                    ▼
  actor.role == .PLATFORM_ADMIN?                  Pool.init() completes
        │                                                    │
       no ──────► 403 (MIG-06 AC1)                            ▼
        │ yes                                    assertDatabaseConfiguration()
        ▼                                        (existing PI-09 gate, unchanged)
  route-specific domain call:                                 │
   run    → runFanout (existing,                               ▼
             MIG-02/03 unchanged) or                assertNoOutstandingMigrations()
             404 UnknownMigration                    (NEW, this batch)
             (MIG-06 AC2) if migration_id                     │
             is not in the known set                ┌──────────┴──────────┐
   status → single SELECT + in-process               ▼                     ▼
             aggregation (MIG-06 AC3)          any 'pending' row     zero 'pending' rows
   resume → resumeFanout (MIG-04, new)                │                     │
        │                                              ▼                     ▼
        ▼                                     FATAL log line,        proceed to
  200 / 404 / 409 response,                    std.process.exit(78)   provisionTenantSchema
  serialised per handler's shape                (MIG-06 AC5: "refuses  → server accept loop
                                                  to serve traffic and  (existing, unchanged)
                                                  names the migration")
```

## Error taxonomy

| Error / outcome | Raised by | Meaning |
|---|---|---|
| `error.MigrationAlreadyRunning` | `resumeFanout` | Same advisory-lock contention as `runFanout`'s existing MIG-03 AC2 case — reuses the identical `pg_try_advisory_lock(hashtext(migration_id))` key, so a `resume` cannot race a `run`/another `resume` of the same `migration_id`. Caller (`handleResumeMigration`) maps to HTTP 409. |
| `error.PoolExhausted` | `resumeFanout` | No connection available. Same meaning as `runFanout`'s existing case. |
| `error.SnapshotQueryFailed` | `resumeFanout` | The pending/failed-tenant snapshot query itself failed. Same meaning as `runFanout`'s existing case, different query text. |
| `error.OutstandingPendingMigrations` | `assertNoOutstandingMigrations` | One or more `pending` rows exist at boot. `main.zig` exits `EX_CONFIG` (78) before the server accepts traffic — MIG-06 AC5. |
| `error.QueryFailed` | `assertNoOutstandingMigrations` | The pending-row query itself failed (distinct from finding pending rows) — same two-tier error shape `startup_assertions.zig`'s existing checks already use (a query failure is not the same condition as a check failing). |
| HTTP 403 | `handleRunMigration`/`handleMigrationStatus`/`handleResumeMigration` | `actor.role != .PLATFORM_ADMIN` — MIG-06 AC1, the same inline role-check convention as `onboarding.zig`/`webhooks.zig`/`identity.zig` (see Dependencies). |
| HTTP 404 `UnknownMigration` | `handleRunMigration` | `migration_id` names no file in the migration set — MIG-06 AC2, writes no control rows (checked BEFORE any call into `runFanout`, which would otherwise seed rows for an unknown id). |
| HTTP 409 | `handleRunMigration`/`handleResumeMigration` | `MigrationAlreadyRunning` from the underlying `runFanout`/`resumeFanout` call. |
| `TenantOutcome.done`/`.failed` | `applyToTenant` (unchanged) | Same meaning as `migration_fanout.zig`'s existing documentation — reused verbatim by both the MIG-05-modified loop and `resumeFanout`. |

No error path introduced by this batch calls `catch unreachable` on a realistic failure,
matching `backend_developer_guide.md §3.2` and the precedent `migration_fanout.zig` already
set.

## State transitions

`platform.platform_migrations.status`, extended from `migration_fanout.zig`'s existing diagram
with the MIG-05 re-run edge and the MIG-04 resume edge (both re-enter the SAME `applyToTenant`
transition the existing diagram already documents — neither adds a new terminal state):

```
                    (seed step: now DO UPDATE ... WHERE status != 'done')
                                 │
                    row absent ──┼── row 'failed' ──────┐
                        │                                 │
                        ▼                                 ▼
                    [pending] ◄─────────── MIG-05 re-run resets
                        │                   a 'failed' row here
          ┌─────────────┴──────────────┐    (fresh run_id, AC2)
          │                             │
  step() succeeds (applyToTenant,   step() raises (applyToTenant,
  same as migration_fanout.zig's   same as migration_fanout.zig's
  existing MIG-02 protocol)        existing MIG-02 protocol)
          │                             │
          ▼                             ▼
       [done] ◄── MIG-05 AC1/AC3:   [failed]
       terminal.    seed step's        │
       Never         DO UPDATE         │ MIG-04 resume:
       re-entered    predicate is      │ picked up by
       by seed        false for a      │ resumeFanout's
       (skipped,       done row —       │ snapshot query
       AC4) or         it is left       │ (status IN
       resume           byte-for-byte    │ ('pending','failed'))
       (resume's        unchanged        │
       snapshot         (all three       └──────► re-enters
       query never      fields:                    applyToTenant,
       selects          status,                     same as the
       'done' rows)     completed_at,                MIG-05 re-run
                        error_msg)                    edge above
```

The one behavioral change to the diagram `migration_fanout.zig`'s design doc already drew: a
`failed` row is no longer permanently stuck (that design doc's own annotation said "NOT
terminal: MIG-04's future resume path re-attempts a failed row — out of scope for this batch");
this batch is exactly that future path landing, for both the explicit resume endpoint (MIG-04)
and an ordinary re-run of `run` (MIG-05 AC2, via the same seed-step upsert).

## Dependencies

**Calls into:**
- `src/platform/migration_fanout.zig::applyToTenant` — MIG-04's `resumeFanout` and MIG-05's
  modified loop both reuse this function verbatim for the per-tenant MIG-02 transaction
  protocol. **Required visibility change:** `applyToTenant` is currently a private (`fn`, no
  `pub`) file-local helper. This batch requires it become `pub fn` (or a package-internal
  visibility if this codebase's Zig version supports one) so `resumeFanout` — implemented in the
  SAME file, `migration_fanout.zig`, per this design's "extend, don't create a new module"
  approach — can call it. Since `resumeFanout` lives in the same file, no cross-module
  visibility widening is actually needed if BACKEND-DEV adds `resumeFanout` directly to
  `migration_fanout.zig` (the natural placement, matching this design's file-organization
  choice below) — flagging this explicitly so BACKEND-DEV does not reflexively export
  `applyToTenant` to the whole package when file-local `fn` visibility already suffices.
- `src/platform/migration_fanout.zig::acquireMigrationLock`/`releaseMigrationLock` — reused
  identically by `resumeFanout` for the same advisory-lock protocol `runFanout` already uses,
  same reasoning as MIG-04's `ResumeError.MigrationAlreadyRunning`.
- `src/db/pool.zig::Pool`/`Conn`/`schemaNameForTenant` — unchanged reuse, same as
  `migration_fanout.zig`'s existing dependencies.
- `src/obs/logger.zig` — reused by `assertNoOutstandingMigrations` for its FATAL log line,
  matching `startup_assertions.zig`'s existing usage, and by the fanout module's existing
  `logSwallowedFailure` convention (unchanged).
- `src/api/middleware/auth.zig::AuthContext`, specifically `actor.role` — MIG-06's three
  handlers read `actor.role` exactly as `onboarding.zig`/`webhooks.zig`/`identity.zig` already
  do; see "RBAC convention" below.
- `src/api/errors.zig` — MIG-06's 403/404/409 responses use the existing `ProblemDetails`
  builder helpers (`problemNotFound`, a new-but-trivial 409 case matching `problemConflict`'s
  existing shape) rather than hand-rolling JSON error bodies, aligning with `identity.zig`'s use
  of `errors.zig` alongside the simpler `errorResult()` helper `onboarding.zig`/`webhooks.zig`
  use for the plain-403 case.

**RBAC convention — cited existing route:** `src/api/routes/onboarding.zig`, e.g.
`handleOnboarding` (line 54) and `handleGetOnboarding` (line 290): `if (actor.role !=
.PLATFORM_ADMIN) { return errorResult(allocator, 403, "forbidden"); }` — the FIRST check inside
the handler body, before any request parsing. The identical one-line pattern also appears in
`src/api/routes/webhooks.zig` (5 call sites) and `src/api/routes/identity.zig` (line 532).
`src/api/routes/services.zig` shows the one variant this codebase has (`actor.role !=
.PLATFORM_ADMIN and !actor.is_bootstrap`, allowing a bootstrap-token caller through too) — MIG-06
does NOT need that variant, since the requirement text names only "the platform-operator role,"
with no bootstrap-token carve-out described in any of MIG-06's five ACs. There is currently no
`Role` enum value named `PLATFORM_OPERATOR` — the codebase's existing single administrative role
is `Role.PLATFORM_ADMIN` (`src/api/middleware/auth.zig:82`). This design uses the EXISTING
`.PLATFORM_ADMIN` role for MIG-06's "platform-operator role" gate rather than inventing a new
role value, since introducing a second admin-tier role with no stated distinction from
`PLATFORM_ADMIN` would be scope the requirement text does not ask for (MIG-06's body says "the
platform-operator role" descriptively, not as a literal enum-value name) — see Open questions §3
for the one place this reading should be confirmed. No separate `rbac.zig` middleware file
exists in this codebase (`src/api/middleware/` has no `rbac.zig`; the guide's `§2` project-tree
listing that mentions one is aspirational/stale relative to the actual routes, which all inline
the check) — this design follows the actual, working convention, not the guide's stale tree.

**Boot-time gate convention — cited existing code:** `src/operations/startup_assertions.zig`'s
`assertDatabaseConfiguration`, called from `src/main.zig::runApiServer` (line 148) immediately
after `Pool.init`, before `db_provisioning.provisionTenantSchema`. On failure: a `FATAL
<component> <CODE> key=value...` log line via `obs_logger.log(..., .ERROR, ...)`, then
`std.process.exit(EX_CONFIG)` where `EX_CONFIG = 78` (line 153). This design's
`assertNoOutstandingMigrations` follows the identical shape — own typed `error{...}` set
(`PendingMigrationError`, mirroring `StartupAssertionError`'s two-tier
query-failure-vs-check-failure split), same FATAL log-line format, called from the same
`runApiServer` fail-fast sequence as a second gate immediately after
`assertDatabaseConfiguration` returns successfully (both gates must pass before
`provisionTenantSchema` runs).

**File organization:** `resumeFanout`, the MIG-05 seed-step/loop edits, and `isAlreadyDone` all
live in the EXISTING `src/platform/migration_fanout.zig` (extend, not duplicate — matching the
handoff's explicit instruction). `assertNoOutstandingMigrations` is a NEW file in
`src/operations/` (sibling to `startup_assertions.zig`, e.g.
`src/operations/pending_migration_gate.zig`) rather than added to `startup_assertions.zig`
itself, since that file's own doc comment scopes it to "database configuration," a different
concern from "application-level migration completeness" — BACKEND-DEV may fold them into one
file if `main.zig`'s call-site sequencing is easier that way; this design does not mandate
separate files, only that the CHECK's logic and log format match `startup_assertions.zig`'s
established shape. MIG-06's three handlers live in a NEW
`src/api/routes/platform_migrations.zig`, matching the one-route-group-per-file convention every
existing file in `src/api/routes/` already follows.

**Must NOT depend on:**
- `src/engine/*` — unrelated pure-computation boundary, unchanged from MIG-02/03's own answer.
- `src/design/ddl-01-validate-platform-ddl.md`'s `validatePlatformDDL` — this batch does not
  wire DDL-01's validator into `runFanout`/`resumeFanout`'s `DdlStep` seam; that remains the
  same open seam MIG-02/03's design already left (its Open Question 1), unchanged by this batch.
  MIG-06's `run`/`resume` handlers pass through whatever `DdlStep` their caller supplies, exactly
  as `runFanout` already does.
- `DdlStep` implementations still must not call `BEGIN`/`COMMIT`/`ROLLBACK` — unchanged
  constraint from `migration_fanout.zig`'s existing design, binding on any `DdlStep` `resumeFanout`
  is given too, since it reuses the exact same `applyToTenant` transaction owner.

## Open questions

1. **Migration-file immutability enforcement mechanism (MIG-05 AC5).** "GIVEN any tenant holds
   a `done` row for `migration_id`, WHEN the migration file content changes, THEN the change is
   rejected and a new `migration_id` is required." This is the one genuinely open design
   question in this batch: nothing in `migration_fanout.zig`'s existing contract, nor MIG-01's
   table, currently ties a `migration_id` to a content hash of the file that produced it — the
   control table stores only the `migration_id` string, `tenant_id`, and status/bookkeeping
   columns, with no `content_hash` or `file_checksum` column. Two candidate designs, neither
   selected here because the choice affects whether MIG-01's table needs a NEW column (a Type C
   change this design would then need to specify) or not:
   (a) Compute a content hash of the migration file at the CALL SITE (the migration-plan CLI,
       the same not-yet-built caller DDL-01's Open Question 1 also names) and REJECT before ever
       calling `runFanout`/`resumeFanout` if a `done` row exists for `migration_id` but the
       file's hash does not match a previously recorded hash for that same `migration_id` — this
       would need a new column (e.g. `platform.platform_migrations.content_hash` or a separate
       one-row-per-migration_id registry table) to compare against, making this option a Type C
       change on top of this batch's Type E logic.
   (b) Treat this as a PURELY PROCESS/tooling constraint enforced outside the running
       application entirely (a pre-commit or CI check on migration file diffs, comparing against
       already-shipped `migration_id`s), with NO runtime code in `migration_fanout.zig` at all —
       consistent with MIG-01's `migration_id` field being caller-supplied free text with no
       uniqueness constraint of its own beyond the `(migration_id, tenant_id)` pair, implying
       `migration_id` uniqueness-of-CONTENT was always meant to be a human/tooling discipline,
       not a database-enforced one.
   This design does not choose between (a) and (b) — recommend REQ-ANALYST/ORCH clarify before
   BACKEND-DEV implements MIG-05 AC5 specifically (AC1–AC4 are fully specified above and do not
   depend on this answer). Flagged PARTIAL-adjacent for this one AC; not blocking the batch's
   overall PASS status since MIG-04's and MIG-06's full AC sets, and MIG-05's other four ACs, are
   unambiguous.

2. **Where is "the migration set" MIG-06 AC2 checks `migration_id` against enumerated?** ("GIVEN
   a `migration_id` matching no file in the migration set, WHEN run is called, THEN... HTTP 404
   `UnknownMigration`.") This batch does not have a concrete on-disk "migration set" to check
   against beyond the numbered files under `migrations/` (which are a DIFFERENT migration
   system — the existing `schema_migrations` file-based runner, not
   `platform.platform_migrations`'s per-`migration_id` fanout). Likely answer: `migration_id`
   values for the platform-fanout system are matched against a caller-supplied registry/directory
   the DDL-01 parser (also not yet built, per DDL-01's Open Question 1) would enumerate — but
   this design does not have that enumeration to call. Recommend `handleRunMigration`'s
   `UnknownMigration` check be implemented against whatever registry DDL-01/MIG-01's eventual
   migration-plan CLI defines, and treated as a follow-up wiring task if that registry does not
   exist yet by the time BACKEND-DEV implements this batch — not a reason to leave AC2 unhandled
   entirely (a placeholder registry, e.g. a caller-supplied `known_migration_ids: []const []const u8`
   parameter to `handleRunMigration`, would satisfy AC2's observable behavior without waiting on
   DDL-01). Not blocking this handoff's PASS status: the HANDLER-side contract (checked-before-any-
   control-row-write, 404 with body `UnknownMigration`) is fully specified; only the registry's
   own data source is open.

3. **Is MIG-06's "platform-operator role" meant to be the existing `Role.PLATFORM_ADMIN`, or a
   new, narrower role?** This design assumes the former (see Dependencies, RBAC convention) since
   introducing a second role is unrequested scope and no other requirement in this batch or
   batch-0 mentions a role split. If REQ-ANALYST intended a genuinely separate
   "platform-operator" tier (e.g. narrower than full `PLATFORM_ADMIN`, perhaps excluding
   onboarding/webhook-secret admin powers), that would require a `Role` enum change in
   `src/api/middleware/auth.zig` — out of scope for this design to decide unilaterally, since it
   affects every other `PLATFORM_ADMIN`-gated route in the codebase, not only this batch's three.
   Not blocking: the requirement text's own wording ("requiring the platform-operator role")
   reads as a descriptive reference to the platform's one existing admin role, and every other
   MUST requirement in this batch is unambiguous either way this question resolves.
