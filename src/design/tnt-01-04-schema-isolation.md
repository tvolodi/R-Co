# Module: tnt-01-04-schema-isolation

**Covers:** TNT-01, TNT-02, TNT-03, TNT-04
**Stage:** 12 — Schema-per-tenant isolation enforcement
**Run ID:** WF02-tnt-batch1-20260609
**Files modified:**
- `src/db/pool.zig`
- `src/db/migrations.zig`
- `src/db/provisioning.zig` (minor — already correct; no change needed)
- `src/main.zig` (add startup audit call)

**New files:**
- `src/bootstrap/audit.zig` (TNT-04 public schema audit)
- `tools/lint_migration_schema.py` (TNT-02 CI linter)
- `migrations/071_tnt04_public_schema_audit_flag.sql` (migration-window flag support)

---

## Module purpose

Stage 12 delivers the **enforcement layer** for schema-per-tenant isolation. The
provisioning infrastructure (schema creation, `runForSchema`, `search_path` on
checkout) already exists from SPT-01. TNT-01 through TNT-04 specify the contract
that must hold from this stage forward:

- **TNT-01** — All 21 business tables live exclusively in tenant schemas; none in
  `public`.
- **TNT-02** — The migration runner sets `search_path` on the connection before
  executing any SQL, so migration files need no `public.` qualifiers; and a CI
  linter blocks any future migration that adds one.
- **TNT-03** — The connection pool sets `search_path` on every checkout and resets
  it on return, including after reconnect.
- **TNT-04** — Platform startup audits the `public` schema and logs at ERROR level
  for any table outside the permitted list.

The SPT-01 design artefact (`src/design/spt-01-schema-per-tenant-provisioning.md`)
covers the provisioning foundation. This document covers the **enforcement
additions** that TNT-01 through TNT-04 require on top of that foundation.

---

## Classification

All four requirements are **Type E — novel / cross-cutting**. They touch the
migration runner, the connection pool, the startup sequence, and introduce a new
CI tool. No single standard Lego template applies.

---

## Public interface

### 1. `src/db/pool.zig` — additions and modifications

The `schemaNameForTenant` helper and `applyRequestTenantContext` already exist
from SPT-01. TNT-03 tightens the contract on these two functions and adds a
`resetConnectionSearchPath` step on return.

Schema-name helper (unchanged from SPT-01):

```zig
/// Derive the PostgreSQL schema name for a given tenant ID string.
/// - Empty string or all-zeros UUID → "tenant_default"
/// - Any other UUID string          → "tenant_" + UUID with hyphens stripped
/// Result is written into buf (at least 80 bytes). Allocation-free.
pub fn schemaNameForTenant(tenant_id: []const u8, buf: *[80]u8) []const u8;
```

Connection lifecycle functions modified or added for TNT-03:

```zig
/// Set search_path and bpm.* session variables on a checked-out connection.
/// Called unconditionally by Pool.acquire() after selecting the connection.
///
/// Branches on whether a tenant is present:
///
///   tenant_id non-empty (resolved tenant request):
///     SET search_path TO <schema_name>,public
///     SELECT set_config('bpm.tenant_id', $1, false)
///     SELECT set_config('bpm.pipeline_run_id', $1, false)
///
///   tenant_id empty/absent (bootstrap token, platform-admin system call,
///   or no resolved tenant):
///     SET search_path TO public
///     (no set_config calls — no tenant context to propagate)
///
/// The tenant_id is read from tenant_context_mod.get() at call time.
/// schemaNameForTenant is NOT called in the empty-tenant branch; the
/// search_path is set to "public" directly without deriving a schema name.
///
/// Returns PoolError.QueryFailed if any SET fails.
/// Returns PoolError.StaleConnection if the connection is not valid.
/// Modified from SPT-01: search_path SET is issued FIRST; no-tenant branch added.
fn applyRequestTenantContext(conn: *Conn) PoolError!void;

/// Reset search_path to public on a connection being returned to the idle pool.
/// NEW — TNT-03. Called by Pool.release() before marking the connection idle.
/// On failure: marks connection invalid and discards it (cross-tenant guard).
fn resetConnectionSearchPath(conn: *Conn) void;
```

Acquire/release signatures (unchanged; behaviour extended):

```zig
/// Pool.acquire — modified by TNT-03: re-applies applyRequestTenantContext
/// after reconnect so the fresh connection has the correct search_path.
pub fn acquire(self: *Pool) PoolError!*Conn;

/// Pool.release — modified by TNT-03: calls resetConnectionSearchPath(conn)
/// before returning conn to idle_indices. If reset fails, connection is
/// discarded instead of returned.
pub fn release(self: *Pool, conn: *Conn) void;
```

### 2. `src/db/migrations.zig` — no interface changes needed

`Migrations.runForSchema` already sets `search_path` before executing any
migration SQL (SPT-01). TNT-02 adds a documentation contract to this existing
behaviour and requires a comment that makes the protocol explicit:

```zig
/// Apply pending migrations inside a specific PostgreSQL schema.
///
/// TNT-02 PROTOCOL (must be preserved):
///   1. Acquire a single connection from the pool.
///   2. Issue: SET search_path TO <schema_name>,public
///      as the FIRST statement on that connection, before any migration SQL.
///   3. Execute each pending migration file via conn.simpleQuery().
///      Because search_path is set, unqualified table names resolve to
///      <schema_name>; the migration files need no public. qualifiers.
///   4. Track completion in public.schema_migrations using the composite
///      key (schema_name, version) — always fully qualified to public.
///   5. Release the connection.
///
/// schema_name is UUID-derived (never user-supplied) — see §5 Safety Note
/// in src/design/spt-01-schema-per-tenant-provisioning.md.
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
) MigrationError!void;
```

`MigrationError` gains one new variant:

```zig
pub const MigrationError = error{
    MigrationsDirectoryNotFound,
    OutOfOrderMigration,
    MigrationFailed,
    UnsupportedPgVersion,
    PoolExhausted,
    /// SET search_path failed for the target schema.
    /// (Already present in actual code from SPT-01 — documented here.)
    SchemaSetupFailed,
};
```

No other changes to `migrations.zig` are required for TNT-02; the mechanism
already works correctly.

### 3. `src/bootstrap/audit.zig` — new module (TNT-04)

```zig
/// TNT-04: Query information_schema.tables for public-schema tables and
/// compare against the permitted list. Log ERROR for unexpected tables,
/// INFO for a clean result. Does NOT hard-stop the server.
///
/// Designed to be called once during startup, after Pool.init() and
/// Migrations.run() complete but before accepting HTTP requests.
///
/// pool — the already-initialised main connection pool.
/// allocator — arena or general allocator for the query result.
pub fn auditPublicSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
) AuditError!void;

pub const AuditError = error{
    PoolExhausted,
    QueryFailed,
};

/// The set of table names permitted in public.
/// Defined as a compile-time constant array — do not make this configurable.
pub const PERMITTED_PUBLIC_TABLES: []const []const u8 = &.{
    "tenant",
    "tenant_schemas",
    "tenant_hostnames",
    "tenant_realm_binding",
    "schema_migrations",
    "onboarding_registry",
    "service_catalog",
    "repository_artifacts",
    "repository_activations",
    "alerting_state",
};
```

### 4. `tools/lint_migration_schema.py` — new CI tool (TNT-02)

```python
def lint_file(path: str) -> list[Issue]: ...

def lint_directory(migrations_dir: str) -> list[Issue]: ...

# Exit 0: no violations.
# Exit 1: one or more BLOCKER violations found.
```

No Zig public interface — this is a pure Python CI tool.

### 5. `migrations/071_tnt04_public_schema_audit_flag.sql` — new migration (TNT-04)

Adds a `migration_window_active` flag to `onboarding_registry` so that the
startup audit can emit WARNING instead of ERROR during the TNT-05 backfill
window. This migration creates no business table in `public`.

---

## Error taxonomy

### `PoolError` additions (TNT-03)

No new variants needed. Existing variants cover all failure modes:

| Error | Trigger | Behaviour |
|---|---|---|
| `PoolError.QueryFailed` | `SET search_path` fails on checkout | `acquire()` returns error; connection discarded |
| `PoolError.StaleConnection` | connection is invalid when `acquire()` is called | replaced with single reconnect attempt; `applyRequestTenantContext` re-issued on fresh connection |
| `PoolError.ConnectionFailed` | reconnect after stale fails | `acquire()` returns error |
| *(return path — not error)* | `resetConnectionSearchPath` fails on `release()` | connection is discarded (not returned to pool), no error propagated to caller |

The last row is a design choice: `release()` is `void` and must not propagate
errors back to a caller that has already finished its work. Discarding prevents
cross-tenant contamination.

### `AuditError` (TNT-04)

| Error | Trigger | Behaviour |
|---|---|---|
| `AuditError.PoolExhausted` | no connection available at startup audit | logged at WARN, audit skipped; server continues |
| `AuditError.QueryFailed` | `information_schema.tables` query fails | logged at WARN, audit skipped; server continues |

The audit is non-fatal by requirement (TNT-04: "continues, no hard stop, to
allow zero-downtime migration windows").

### CI linter issues (`lint_migration_schema.py`)

| Code | Severity | Trigger |
|---|---|---|
| `M001` | BLOCKER | `public.<business_table>` reference found in a non-GBL migration file |
| `M002` | MINOR | reference to a permitted public table (`public.tenant`, `public.schema_migrations`, etc.) — allowed, not an error |

---

## Migration runner search_path protocol (TNT-02)

### Which SQL statement

```sql
SET search_path TO <schema_name>,public
```

This is the PostgreSQL simple-form `SET` statement (not `SET LOCAL`, not
`SET search_path = ...`, not `SELECT set_config(...)`). The `TO` keyword form is
used for clarity and portability.

### When

The `SET` is issued as the **first statement** on the connection acquired for a
`runForSchema` call, before:
- checking `public.schema_migrations` for already-applied versions,
- executing any migration SQL,
- recording `INSERT INTO public.schema_migrations`.

The `public.schema_migrations` DML is always written with the explicit `public.`
qualifier so it lands in the correct table regardless of `search_path`. This is
the only permitted use of a schema-qualified name inside migration runner code.

### On which connection

The `runForSchema` function acquires **one connection** from the pool and holds
it for the entire migration run for that schema. The `SET search_path` applies
to that session for the lifetime of that connection acquisition. All subsequent
`BEGIN`/migration SQL/`INSERT INTO public.schema_migrations`/`COMMIT` calls use
the same connection, so all are under the same `search_path`.

### Why interpolation is safe

`schema_name` is UUID-derived (via `schemaNameForTenant`), never user-supplied.
It contains only `[a-z0-9_]` characters. It is safe to interpolate into
`SET search_path TO ...` because:

1. The value space is restricted to `tenant_[0-9a-f]{32}` and `tenant_default`.
2. None of these strings contain SQL metacharacters.
3. The check in `schemaNameForTenant` strips hyphens and produces a fixed-length
   (at most 39-char) identifier.

This is the §5 Safety Note documented in
`src/design/spt-01-schema-per-tenant-provisioning.md`.

---

## Connection pool checkout/return search_path lifecycle (TNT-03)

### Checkout sequence (`Pool.acquire`)

1. Lock pool mutex.
2. Pop idle connection index; unlock mutex.
3. If `!conn._is_valid`: close `_pg`, open new `pg.Conn` (reconnect).
4. Call `applyRequestTenantContext(conn)`:
   - Read `tenant_id` from `tenant_context_mod.get()`.
   - If `tenant_id` is non-empty (resolved tenant):
     - Issue `SET search_path TO <schema_name>,public` where `schema_name`
       is derived via `schemaNameForTenant(tenant_id, &buf)`.
     - Issue `SELECT set_config('bpm.tenant_id', $1, false)`.
     - Issue `SELECT set_config('bpm.pipeline_run_id', $1, false)`.
   - If `tenant_id` is empty (no resolved tenant):
     - Issue `SET search_path TO public` (only public; no tenant schema).
     - Skip `set_config` calls.
   - On any failure: return error, connection is NOT returned to idle.
5. Return `*Conn` to caller.

The `search_path` SET is issued before `set_config` calls (changed from
original SPT-01 wiring where order was reversed). The `set_config` calls are
retained for backward compatibility with RLS policies still reading
`bpm.tenant_id` during the Stage 12 transition period.

### No-tenant case

When `tenant_context_mod.get()` returns an empty string (bootstrap token,
platform-admin system call, or no resolved tenant), `applyRequestTenantContext`
takes the no-tenant branch and issues:

```
SET search_path TO public
```

Only `public` is set — no tenant schema is prepended. `schemaNameForTenant` is
NOT called in this branch. The `set_config` calls for `bpm.tenant_id` and
`bpm.pipeline_run_id` are also skipped, as there is no tenant context to propagate.

This satisfies the TNT-03 acceptance criterion: "GIVEN a request with no
resolved tenant (bootstrap token, platform-admin system call), WHEN a connection
is acquired, THEN search_path = public is set and NO tenant schema is prepended."

`schemaNameForTenant` continues to return `"tenant_default"` for the empty-string
input, but this helper is used only in the provisioning / schema-creation path
(e.g. `provisionTenantSchema`), never in the pool checkout path for no-tenant
requests.

### Return sequence (`Pool.release`)

1. Call `resetConnectionSearchPath(conn)`:
   - If `!conn._is_valid`: skip (connection will be replaced on next acquire).
   - Issue `SET search_path TO public` via `conn._pg.exec`.
   - On failure: set `conn._is_valid = false`; do NOT push to idle stack.
   - On success: proceed.
2. Lock pool mutex; push `conn._pool_idx` onto `idle_indices`; increment
   `idle_count`; unlock mutex.

### Reconnect path

When `acquire()` reconnects a stale connection (step 3 above), it calls
`applyRequestTenantContext` on the fresh connection before returning it. This
satisfies the TNT-03 requirement: "search_path MUST be re-applied after
reconnect."

### Transaction-scoped checkout

A connection checked out inside a transaction must not have its `search_path`
reset mid-transaction. `resetConnectionSearchPath` is only called from
`Pool.release()`, which callers invoke after `tx.commit()` or `tx.rollback()`.
No transaction management code calls `release()` mid-transaction.

### Nested pool acquisitions

If a request acquires two connections (e.g. sub-query pattern), each
`Pool.acquire()` call independently sets `search_path` for its connection using
the same tenant context. Both connections receive the same tenant schema in their
`search_path`. Each `Pool.release()` independently resets its connection.

---

## Startup audit query and permitted table list (TNT-04)

### Audit query

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type IN ('BASE TABLE', 'VIEW')
ORDER BY table_name
```

- `table_schema = 'public'`: restricts to the target schema (anti-pattern §DB:
  always filter by schema to avoid false positives).
- `table_type IN ('BASE TABLE', 'VIEW')`: excludes sequences, functions, and
  foreign table proxies per TNT-04 edge case ("Functions and sequences in
  public: not checked by the audit; only BASE TABLE and VIEW types are
  validated").
- Parameter binding: `table_schema` is hardcoded `'public'`; no user input;
  parameterised form not required but used for consistency.

### Permitted table list

The compile-time constant `PERMITTED_PUBLIC_TABLES` in `src/bootstrap/audit.zig`
contains exactly these ten names:

```
tenant
tenant_schemas
tenant_hostnames
tenant_realm_binding
schema_migrations
onboarding_registry
service_catalog
repository_artifacts
repository_activations
alerting_state
```

This list is the canonical source of truth. TNT-04 states: "A migration that
would create a new table in public MUST require that the table name is added to
the permitted list in this requirement's definition before the migration is
merged." For implementation, "this requirement's definition" maps to the
`PERMITTED_PUBLIC_TABLES` constant in `src/bootstrap/audit.zig` and the list in
`docs/requirements/TNT-04.md`. Both must be kept in sync by code review.

### Audit verdict logic

```
for each table_name returned by the query:
    if table_name NOT IN PERMITTED_PUBLIC_TABLES:
        check migration_window_active flag in onboarding_registry
        if migration_window_active:
            log WARN "public schema audit: unexpected table '<name>' (migration window active)"
        else:
            log ERROR "public schema audit: unexpected table '<name>'"

if no unexpected tables found:
    log INFO "public schema audit: CLEAN"
```

### Migration window flag

`migrations/071_tnt04_public_schema_audit_flag.sql` adds:

```sql
ALTER TABLE onboarding_registry
    ADD COLUMN IF NOT EXISTS migration_window_active BOOLEAN NOT NULL DEFAULT FALSE;
```

During the TNT-05 backfill run, the operator sets this flag to `TRUE`. The
startup audit reads it and downgrades ERROR to WARN. After TNT-05 completes and
business tables are removed from `public`, the operator resets it to `FALSE`.

The audit checks this flag in a single query before iterating unexpected tables,
not per-table, to minimise DB round trips.

### Call site in `src/main.zig`

`auditPublicSchema` is called inside `runApiServer`, after:
1. `Pool.init` (pool is ready)
2. `Migrations.run` (global migrations applied)
3. `provisionTenantSchema` (default tenant schema exists)

And before the HTTP `server.listen` / `server.accept` loop. The result is
logged; errors are caught and logged at WARN; the server proceeds regardless.

---

## CI linter patterns — `tools/lint_migration_schema.py` (TNT-02)

### Business tables that trigger a BLOCKER

The linter rejects any non-GBL migration file that contains a string matching:

```
public\.(events|events_archive|process_definitions|instance_projections|tasks|tokens|timers|audit_entries|audit_log|users|groups|group_members|roles|user_roles|api_tokens|webhook_subscriptions|dead_letter_items|event_type_registry|event_retention_policies|repository_form_schemas)
```

This is a Python `re` pattern applied line-by-line (and also to string literals
inside `DO $$ ... $$` blocks per TNT-02 edge case).

The full business table list (21 tables):

| Table name |
|---|
| `events` |
| `events_archive` |
| `process_definitions` |
| `instance_projections` |
| `tasks` |
| `tokens` |
| `timers` |
| `audit_entries` |
| `audit_log` |
| `users` |
| `groups` |
| `group_members` |
| `roles` |
| `user_roles` |
| `api_tokens` |
| `webhook_subscriptions` |
| `dead_letter_items` |
| `event_type_registry` |
| `event_retention_policies` |
| `repository_form_schemas` |
| `instance_sequence` |

Note: `instance_sequence` tracks per-instance sequence counters (created in
`001_event_store.sql`) and is a business-layer table — it must be in the tenant
schema, not `public`.

### Permitted public references (not rejected)

References to the following tables with `public.` qualifier are explicitly
allowed (MINOR note, not BLOCKER):

```
public.tenant
public.tenant_schemas
public.tenant_hostnames
public.tenant_realm_binding
public.schema_migrations
public.onboarding_registry
public.service_catalog
public.repository_artifacts
public.repository_activations
public.alerting_state
```

These are the platform-routing tables. Migration runner code that uses
`public.schema_migrations` explicitly is correct and expected.

### GBL migration files

Files whose basename begins with `GBL-` operate on the global `public` schema
and are exempt from business-table rejection. The linter skips business-table
checks on GBL files entirely.

### DO $$ block handling

For lines inside a `DO $$ BEGIN ... END $$` block, the linter scans string
literals using a simplified regex:

```
'(public\.<business_table>)'
```

Matches inside single-quoted SQL strings within the DO block are also flagged.
This covers the edge case in TNT-02: "Migration file that uses a DO block with
dynamic SQL: the linter checks string literals within the block."

### Invocation

```bash
python3 tools/lint_migration_schema.py migrations/
# exits 0 if clean, 1 if any BLOCKER found
```

CI integration: add to the existing pre-commit or GitHub Actions pipeline that
runs `python3 tools/lint_design_artefact.py`.

---

## Key invariants

1. **search_path is always explicitly set on checkout.** Every connection
   returned by `Pool.acquire()` has `search_path` explicitly set:
   - Resolved-tenant request: `search_path = <tenant_schema>,public`
   - No-tenant request (bootstrap/platform-admin): `search_path = public`
   No caller may issue an unqualified query and accidentally resolve to an
   unexpected schema.

2. **search_path is always reset on return.** Every `Pool.release()` call
   resets `search_path = public`. A connection that fails to reset is discarded.

3. **Migration runner never leaves search_path ambiguous.** `runForSchema` sets
   `search_path` as the first statement on its connection. Migration SQL files
   contain no `public.` qualifiers for business tables.

4. **Startup audit is non-fatal.** An unexpected table in `public` logs at ERROR
   level but does not stop the server. This permits zero-downtime migration
   windows (TNT-04 acceptance criterion).

5. **Permitted list is a compile-time constant.** `PERMITTED_PUBLIC_TABLES`
   cannot be overridden at runtime. New entries require a code change and
   PR review.

6. **CI linter blocks regressions.** No new migration file may introduce a
   `public.<business_table>` reference. Existing migrations are grandfathered;
   the linter operates only on new files (or can be run on the full
   `migrations/` directory as a one-time retroactive check).

7. **`bpm.tenant_id` session variable is retained for backward compatibility.**
   RLS policies installed by migrations 027–028 still read `bpm_effective_tenant_id()`
   which reads `bpm.tenant_id`. The `set_config` call in `applyRequestTenantContext`
   must remain until TNT-05 removes those RLS policies.

---

## Dependencies on existing modules

| Module | Dependency type | Notes |
|---|---|---|
| `src/db/pool.zig` | Modified | Add `resetConnectionSearchPath`; call from `release()`; re-apply `applyRequestTenantContext` after reconnect |
| `src/db/migrations.zig` | Documentation only | `runForSchema` already correct; add TNT-02 protocol comment |
| `src/db/provisioning.zig` | No change | Already calls `runForSchema`; already correct |
| `src/main.zig` | Modified | Add `auditPublicSchema` call after migrations, before server accept loop |
| `src/bootstrap/audit.zig` | New file | TNT-04 audit logic |
| `tools/lint_migration_schema.py` | New file | TNT-02 CI linter |
| `migrations/071_tnt04_public_schema_audit_flag.sql` | New migration | Adds `migration_window_active` flag to `onboarding_registry` |
| `tenant_context` module | Read-only | `Pool.acquire` reads `tenant_context_mod.get()` to derive schema name |
| `pipeline_context` module | Read-only | `applyRequestTenantContext` reads pipeline run ID for `set_config` |
| `obs/logger.zig` | Read-only | `auditPublicSchema` emits structured log entries |

---

## Open questions

None. All design decisions are resolved from the requirement files and the
existing SPT-01 implementation.

---

*Traceability:*
- TNT-01 — business table placement enforced by `runForSchema` search_path +
  pool checkout search_path; verified by integration tests that inspect
  `information_schema.tables` per tenant schema.
- TNT-02 — `runForSchema` search_path protocol; `lint_migration_schema.py` CI
  linter; `public.schema_migrations` always written with explicit qualifier.
- TNT-03 — `applyRequestTenantContext` on checkout (branches on empty/non-empty
  tenant_id: no-tenant → `SET search_path TO public` only; resolved-tenant →
  `SET search_path TO <schema>,public`); `resetConnectionSearchPath` on return;
  re-apply after reconnect.
- TNT-04 — `auditPublicSchema` in startup; `PERMITTED_PUBLIC_TABLES` constant;
  `migration_window_active` flag for zero-downtime window.
