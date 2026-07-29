# Process: Platform DDL Safety and Namespace Reservation

| Field | Value |
|-------|-------|
| Process ID | `sys-platform-ddl-safety` |
| Platform Workflow | PW-05 |
| Requirements | DDL-01, DDL-02, DDL-03, DDL-04, DDL-05 |
| Owner | Platform Admin |
| Scope | System-wide (every tenant schema, plus the `platform` schema) |
| Source | `docs/workflows.yaml` (PW-05) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.5, 2.6 |

## Summary

Gates every migration statement before the tenant fanout of PW-04 opens its first
connection. `ValidatePlatformDDL` is a pure function over parsed statement
descriptors -- it holds no database handle, performs no I/O, and returns the same
verdict for the same input on every host. It rejects the statement classes that
take an unbounded `ACCESS EXCLUSIVE` lock, rejects any file set that constrains a
column before expanding it, and rejects tenant-authored DDL that names an object
inside the reserved `plat_` prefix. Statements that pass are rewritten by the
phased DDL generator into exactly three statements -- expand, backfill, constrain
-- so that no single statement holds a lock for longer than one catalog update.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Platform Admin | Human operator | Submits the migration file set; receives the plan verdict |
| Migration Runner | System (`zig build migrate`) | Parses, validates, generates phases, executes per tenant schema |
| DDL Validator | System (pure function) | Returns ACCEPT or a typed rejection; touches nothing |
| Tenant Admin | Human or automation | Submits tenant-authored DDL through the entity API |
| PostgreSQL | Database | Grants and releases the locks the validator reasons about |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `migration_files` | path[] | Ordered by numeric prefix; every file parses as SQL |
| `statements` | descriptor[] | One descriptor per statement: verb, target object, columns, clauses |
| `target_schemas` | string[] | Resolved by PW-04; the validator never reads this list |
| `backfill_batch_size` | integer | Default 5000 rows; upper bound 50000 |
| `reserved_prefix` | string | Fixed value `plat_`; not operator-configurable |
| `origin` | enum | `platform_migration` or `tenant_authored`; selects the rejection surface |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Platform Admin | Submit the migration file set to the planner | Caller holds platform-admin privilege? | -> `Forbidden`; plan exits 2 | DDL-01 |
| 2 | Migration Runner | Parse each file into statement descriptors | Every statement parses? | -> `UnparsableStatement` naming file and offset; plan exits 2 | DDL-01 |
| 3 | DDL Validator | Match each descriptor against the rejected lock classes: `DROP COLUMN`, `CLUSTER`, `VACUUM FULL`, `REINDEX` without `CONCURRENTLY`, `ALTER COLUMN ... SET DATA TYPE` | Any match? | -> `UnboundedExclusiveLock` naming the statement; zero tenant schemas opened | DDL-01 |
| 4 | DDL Validator | Match index builds | `CREATE INDEX` without `CONCURRENTLY`, or `DROP INDEX` without `CONCURRENTLY`? | -> `NonConcurrentIndexBuild`; file set REJECTED | DDL-01 |
| 5 | DDL Validator | Walk the file set in order and check expand-then-constrain | A `SET NOT NULL`, `ADD CONSTRAINT` without `NOT VALID`, or `ADD COLUMN ... NOT NULL` without a constant default appears before the column exists and is backfilled? | -> `ConstrainBeforeExpand` naming both statements; file set REJECTED | DDL-02 |
| 6 | DDL Validator | Check every created or renamed object name against `plat_` | `origin = tenant_authored` and the name starts with `plat_`? | -> `ReservedNamespace`; API returns 422 | DDL-05 |
| 7 | DDL Validator | Check every created or renamed object name against `plat_` | `origin = platform_migration` and the name does not start with `plat_` for a platform-schema object? | -> `UnreservedPlatformObject`; file set REJECTED | DDL-05 |
| 8 | DDL Validator | Return the verdict | Verdict is ACCEPT? | -> Plan proceeds; verdict recorded in `plat_migration_plan` | DDL-01 |
| 9 | Migration Runner | Generate phase 1 (expand): `ALTER TABLE t ADD COLUMN c <type> NULL;` and `ALTER TABLE t ADD CONSTRAINT c_nn CHECK (c IS NOT NULL) NOT VALID;` | Generator emits exactly one expand statement group? | -> `PhaseGenerationFailed`; file set REJECTED | DDL-03 |
| 10 | Migration Runner | Generate phase 2 (backfill): `UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM t WHERE c IS NULL LIMIT $1));` | Backfill predicate is `c IS NULL`? | -> `NonIdempotentBackfill`; file set REJECTED | DDL-04 |
| 11 | Migration Runner | Generate phase 3 (constrain): `ALTER TABLE t VALIDATE CONSTRAINT c_nn;` then `ALTER TABLE t ALTER COLUMN c SET NOT NULL;` | Phase 3 references a constraint created in phase 1? | -> `PhaseGenerationFailed`; file set REJECTED | DDL-03 |
| 12 | Migration Runner | Execute phase 1 in each tenant schema through the PW-04 fanout | `ACCESS EXCLUSIVE` acquired within `lock_timeout = 3s`? | -> Statement aborts; that tenant recorded FAILED; fanout continues to the next tenant | DDL-03 |
| 13 | Migration Runner | Execute phase 2 as a loop, one transaction per batch, until an iteration reports 0 updated rows | Loop interrupted or the process restarts? | -> Re-run resumes from the same predicate; rows already backfilled are skipped | DDL-04 |
| 14 | Migration Runner | Execute phase 3 under `SHARE UPDATE EXCLUSIVE` | `VALIDATE CONSTRAINT` finds a violating row? | -> `BackfillIncomplete`; phase 3 rolled back; phase 2 re-run for that tenant | DDL-03 |
| 15 | Migration Runner | Write the per-tenant phase state and the plan verdict | All tenants at phase 3 complete? | -> Migration state `APPLIED`; otherwise `PARTIAL`, resumable by PW-04 | DDL-01 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Validation precedes connection | `ValidatePlatformDDL` runs before the fanout opens a connection to any tenant schema. A rejected file set touches zero schemas. |
| The validator is pure | No database handle, no clock, no filesystem, no environment read. Input is the descriptor list; output is ACCEPT or one typed rejection. Same input, same verdict, every host. |
| Rejected lock classes | `DROP COLUMN`, `CLUSTER`, `VACUUM FULL`, `REINDEX` without `CONCURRENTLY`, `ALTER COLUMN ... SET DATA TYPE`. Each holds `ACCESS EXCLUSIVE` for a duration proportional to table size, multiplied by the tenant count. |
| Column removal path | A column is retired by dropping its constraints and ceasing to write it. Physical `DROP COLUMN` is executed only during a table rewrite scheduled outside the fanout. |
| Type change path | A type change is an `ADD COLUMN` of the new type, a phase-2 backfill, a phase-3 constrain, then a rename swap. `SET DATA TYPE` is never generated. |
| Expand before constrain | Within one file set, a column must exist and be backfilled before any statement constrains it. A constraint is added `NOT VALID` first and validated in phase 3. |
| Three statements, no more | Every column addition that carries a constraint compiles to exactly three phases. A generator that cannot express a change in three phases rejects it rather than emitting a wider lock. |
| Backfill idempotence | The backfill predicate is always `WHERE <col> IS NULL`, bounded by `LIMIT $1` on `ctid`. Re-running from the start produces the same end state. |
| Backfill transaction scope | One transaction per batch. No batch loop runs inside an outer transaction. |
| Reserved namespace | Objects named `plat_*` are owned by the platform. Tenant-authored DDL that creates, renames, or alters an object with that prefix is refused with 422 before parse results are committed. |
| Platform objects are prefixed | Every object the platform creates in a tenant schema carries the `plat_` prefix, so the reservation is checkable by name alone. |
| Lock timeout | Every phase statement runs with `lock_timeout = 3s` and `statement_timeout = 60s`. A phase that cannot take its lock fails that tenant and does not stall the fanout. |
| Per-tenant failure isolation | A tenant that fails any phase is recorded FAILED and skipped. Later tenants continue. Resume is per tenant, per phase. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Plan verdict | ACCEPT or one typed rejection, written to `plat_migration_plan` with the offending statement text |
| Phase script | The three generated statement groups, stored verbatim for audit and replay |
| `plat_migration_state` | One row per (migration, tenant schema, phase) with status and attempt count |
| Backfill progress | Rows updated per batch and the count of remaining `IS NULL` rows per tenant |
| Migration state | `APPLIED`, `PARTIAL`, or `REJECTED` |
| Audit event | `EXECUTION_MIGRATION_VALIDATED` appended to the event log with the verdict |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Validation duration | `ValidatePlatformDDL` runs in-process with no I/O; the plan verdict is returned in under 100 ms for a file set of up to 200 statements |
| `lock_timeout` | 3 s per phase statement. Exceeded -> that tenant is FAILED, the fanout continues |
| `statement_timeout` | 60 s per phase statement. Exceeded -> that tenant is FAILED at that phase |
| Backfill batch duration | A batch exceeding 5 s halves `backfill_batch_size` for the next batch, floor 500 rows |
| Backfill stall | No batch progress for 10 consecutive iterations -> escalate to Platform Admin with the remaining `IS NULL` count per tenant |
| Rejection | Immediate and terminal. There is no retry of a rejected file set; the file set is edited and resubmitted |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| `Forbidden` | Caller lacks platform-admin privilege | Authenticate with platform-admin credentials |
| `UnparsableStatement` | A statement does not parse into a descriptor | Fix the SQL at the reported file and offset, resubmit |
| `UnboundedExclusiveLock` | Statement is in the rejected lock class | Rewrite as an expand-backfill-constrain sequence and resubmit |
| `NonConcurrentIndexBuild` | `CREATE INDEX` or `DROP INDEX` without `CONCURRENTLY` | Add `CONCURRENTLY`; move the statement out of any explicit transaction block |
| `ConstrainBeforeExpand` | A constraint precedes the column it constrains, or a `NOT NULL` precedes its backfill | Reorder the file set into expand, backfill, constrain; resubmit |
| `ReservedNamespace` | Tenant-authored DDL names an object `plat_*` | Rename the object outside the reserved prefix; API returns 422 with the offending name |
| `UnreservedPlatformObject` | A platform migration creates a platform-schema object without the `plat_` prefix | Rename the object to carry the prefix; resubmit |
| `PhaseGenerationFailed` | The change cannot be expressed as three phases | Split the change across two migrations, each expressible in three phases |
| `NonIdempotentBackfill` | Generated backfill predicate is not `IS NULL`-bounded | Fix the generator template; the file set is not executed |
| `BackfillIncomplete` | `VALIDATE CONSTRAINT` finds a row violating the constraint | Phase 3 rolls back; phase 2 re-runs for that tenant; phase 3 retried |
| `LockTimeout` | Phase statement could not acquire its lock within 3 s | Tenant recorded FAILED at that phase; resume that tenant after the blocking session ends |
| `StatementTimeout` | Phase statement exceeded 60 s | Tenant recorded FAILED at that phase; reduce batch size and resume |
