# Module: ddl-03-phased-ddl-generation

**Requirement ID:** DDL-03
**Run ID:** WF02-obp-ddl-20260817 (Stage 16)
**Type:** Type E (phase generator) — no new schema objects. The generated phase statements
are recorded in the existing `plat_migration_plan` table (already part of MIG-01/DDL-01)
and the per-phase execution state in `plat_migration_state` (created by DDL-04's Type C
migration).
**Extends:** DDL-02 (`src/platform/ddl_validate.zig` — the ordering check this turns into
generated output), DDL-04 (`src/platform/backfill.zig` — the backfill loop that executes
the generated phase-2 statement), MIG-01 (the tenant fanout executing each phase), DDL-01
(the validator this generator feeds back into — every generated statement must itself pass
`validatePlatformDDL`).
**Authoritative process source:** `docs/processes/system/platform-ddl-safety.md`
(`sys-platform-ddl-safety`, PW-05) — the three-phase pattern, lock and statement timeout
requirements (DDL-03 AC6), phase ordering, and the `BackfillIncomplete` recovery path.
**See also (referenced, not implemented here):** DDL-04 (phase 2 — the backfill executor),
DDL-01 (the validator), DDL-02 (the ordering check), MIG-01 / MIG-02 / MIG-03 (the fanout
that executes each phase per tenant).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added by DDL-03. The generated phase statements are
   recorded in `plat_migration_plan` (existing table) and the per-phase execution state
   tracked in `plat_migration_state` (created by DDL-04's migration). DDL-03's generator
   produces SQL text; it does not create new tables.
2. **Type A?** No HTTP route.
3. **Type E — yes.** A pure, multi-step SQL generation pipeline over a structured
   column-addition descriptor, producing deterministic three-phase statement groups. This
   is exactly the "performance-sensitive" and "novel transformation logic" shape that
   lego-catalog.md reserves for Type E, and the same classification DDL-01 and DDL-02
   used for validation logic over the same descriptor type.

## Existing pattern found and followed

| Aspect | Precedent | DDL-03 (this design) |
|---|---|---|
| Pure generator with no I/O | `src/platform/ddl_validate.zig` `validatePlatformDDL` — pure function over `StatementDescriptor[]`, no allocator, no DB handle | Followed: `generatePhases` is pure (no allocator needed; returns a value type), testable without a DB, and deterministic given the same input |
| Constraint naming convention | `1164_obp04_plat_outbox_gate.sql` — column constraint names follow `<table>_<column>_<suffix>` pattern | Followed: the generated NOT NULL CHECK constraint is named `<column>_nn` within the table scope, using the format `<table>_<column>_nn` |
| Lock / statement timeout per phase | `src/platform/backfill.zig` (DDL-04) `BackfillConfig.lock_timeout_s = 3`, `statement_timeout_s = 60` | Followed verbatim: DDL-03 AC6 specifies the same values; the generated phase statements SET these timeouts as `SET LOCAL` commands prepended to each phase |
| `PhaseGenerationFailed` as a verdict, not a panic | `ddl_validate.zig` `ValidationVerdict` union — failures are normal return values, never panics or Zig `error{}` | Followed: `GenerationResult` is a tagged union (`accept` / `phase_generation_failed`) with no Zig error set — same purity contract as the validator |
| Phase-2 statement shape | `src/platform/backfill.zig` `GeneratedBackfill.sql` — the UPDATE statement consumed by `runBackfill` | Followed exactly: phase-2 output from `generatePhases` is a `GeneratedBackfill` struct, so the phase generator and the backfill executor share the same type without translation |

**Deliberately NOT re-derived:** the backfill loop (that is DDL-04), the validator (that is
DDL-01/DDL-02), and the fanout (that is MIG-01/02/03). The generator outputs SQL text and
phase descriptors; the fanout and executor consume them. The generator has no knowledge of
which tenants exist, how many rows need backfilling, or what the actual execution plan is.

## Module purpose

`src/platform/ddl_generate.zig` (new) is the pure three-phase generator. Given a
`ColumnAdditionSpec` — a structured description of a column addition carrying a NOT NULL
constraint — it produces:
- **Phase 1 (expand):** `ALTER TABLE t ADD COLUMN c <type> NULL` + `ALTER TABLE t ADD CONSTRAINT
  <t>_<c>_nn CHECK (c IS NOT NULL) NOT VALID` — both statements wrapped in `SET LOCAL
  lock_timeout = '3s'` / `SET LOCAL statement_timeout = '60s'` guards.
- **Phase 2 (backfill):** a `GeneratedBackfill` struct (from DDL-04's `src/platform/backfill.zig`)
  whose `sql` field is `UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (ARRAY(SELECT
  ctid FROM t WHERE c IS NULL LIMIT $1))`.
- **Phase 3 (constrain):** `ALTER TABLE t VALIDATE CONSTRAINT <t>_<c>_nn` + `ALTER TABLE t
  ALTER COLUMN c SET NOT NULL` — same `SET LOCAL` timeout guards.

A requested change that cannot be expressed in three phases causes `GenerationResult`
`.phase_generation_failed` to be returned; the caller MUST NOT execute any statement against
any tenant schema.

## Public interface

### `src/platform/ddl_generate.zig`

```zig
const std = @import("std");
const backfill = @import("backfill.zig");

/// The column addition this generator knows how to phase-split. Only the
/// NOT NULL constraint pattern (add column + enforce NOT NULL) is supported.
/// Future constraint types (UNIQUE, FOREIGN KEY) are out of scope and will
/// return PhaseGenerationFailed with reason UnsupportedConstraintType.
pub const ColumnConstraintKind = enum {
    not_null,   // ADD COLUMN ... NULL + ADD CONSTRAINT ... CHECK NOT VALID
                // + backfill + VALIDATE CONSTRAINT + SET NOT NULL
};

/// Describes the column being added. All fields are slice references into
/// the caller's migration plan buffer — no allocation inside generatePhases.
pub const ColumnAdditionSpec = struct {
    migration_id: []const u8,       // migration file identifier (for GeneratedBackfill.migration_id)
    table: []const u8,              // unqualified table name (schema set per-tenant by the fanout)
    column: []const u8,             // column name being added
    column_type: []const u8,        // SQL type string, e.g. "TIMESTAMPTZ", "TEXT"
    /// SQL expression for the backfill UPDATE's SET clause.
    /// Must produce a non-NULL value of `column_type` for every existing row.
    /// The generator validates that this is NOT the empty string (would produce
    /// a non-idempotent backfill that DDL-04 would reject).
    backfill_expr: []const u8,
    constraint: ColumnConstraintKind,
    /// 1-based position of the originating statement in its migration file
    /// (passed through to GeneratedBackfill.order for failure detail).
    order: u32,
};
```

```zig
/// Phase 1 (expand) statements, SET LOCAL-guarded. Always exactly two
/// statements: add column NULL + add constraint NOT VALID.
pub const Phase1Statements = struct {
    set_lock_timeout: []const u8,      // "SET LOCAL lock_timeout = '3s'"
    set_statement_timeout: []const u8, // "SET LOCAL statement_timeout = '60s'"
    add_column_null: []const u8,
    // e.g. "ALTER TABLE t ADD COLUMN c TIMESTAMPTZ NULL"
    add_constraint_not_valid: []const u8,
    // e.g. "ALTER TABLE t ADD CONSTRAINT t_c_nn CHECK (c IS NOT NULL) NOT VALID"
};

/// Phase 3 (constrain) statements, SET LOCAL-guarded.
pub const Phase3Statements = struct {
    set_lock_timeout: []const u8,      // "SET LOCAL lock_timeout = '3s'"
    set_statement_timeout: []const u8, // "SET LOCAL statement_timeout = '60s'"
    validate_constraint: []const u8,
    // e.g. "ALTER TABLE t VALIDATE CONSTRAINT t_c_nn"
    set_not_null: []const u8,
    // e.g. "ALTER TABLE t ALTER COLUMN c SET NOT NULL"
};

/// The three-phase output for one column addition.
pub const PhasedDDL = struct {
    /// Identifies the migration and column this was generated for (for
    /// logging and plat_migration_plan recording).
    migration_id: []const u8,
    table: []const u8,
    column: []const u8,
    constraint_name: []const u8, // deterministic: "<table>_<column>_nn"

    phase1: Phase1Statements,
    /// Phase 2 is a GeneratedBackfill, consumed directly by
    /// backfill.runBackfill (DDL-04). The `sql` field is the UPDATE
    /// statement; `order` is from ColumnAdditionSpec.order.
    phase2: backfill.GeneratedBackfill,
    phase3: Phase3Statements,
};
```

```zig
/// Reason a generation failed. Carried in PhaseGenerationFailed for
/// diagnostics and plat_migration_plan recording.
pub const FailureReason = enum {
    /// The backfill_expr field is empty — would produce a non-idempotent
    /// backfill (DDL-04 would reject it).
    empty_backfill_expr,
    /// The constraint kind is not supported by this generator.
    unsupported_constraint_type,
    /// The column or table name is empty or contains SQL-unsafe characters
    /// (e.g. whitespace, semicolons) — the generator refuses to embed raw
    /// identifiers in generated SQL without validation.
    unsafe_identifier,
    /// The column_type is empty.
    empty_column_type,
};

pub const PhaseGenerationFailed = struct {
    spec: ColumnAdditionSpec,
    reason: FailureReason,
};

/// The result of one generatePhases call. A tagged union — not a Zig error{}
/// — matching ddl_validate.zig's ValidationVerdict purity convention.
pub const GenerationResult = union(enum) {
    accept: PhasedDDL,
    phase_generation_failed: PhaseGenerationFailed,
};
```

```zig
/// Generate the three-phase DDL for one ColumnAdditionSpec. Pure: no
/// allocator, no DB handle, no clock, no env read. Returns:
///   .accept{PhasedDDL}           — three phases produced
///   .phase_generation_failed{…}  — change cannot be expressed; no statement
///                                   is emitted and no tenant schema is touched
///
/// The constraint name is deterministic: "<table>_<column>_nn". Phase 1 and
/// Phase 3 statement text is constructed by simple string formatting over the
/// spec fields (no SQL parser needed — the output shape is fixed). Phase 2 is
/// constructed as a GeneratedBackfill whose `sql` is the canonical UPDATE
/// template (DDL-04 body): "UPDATE <table> SET <column> = <backfill_expr>
/// WHERE <column> IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM <table>
/// WHERE <column> IS NULL LIMIT $1))".
///
/// Pure output means the caller (migration runner) is responsible for
/// recording the generated statements in plat_migration_plan before
/// dispatching phases to the fanout.
pub fn generatePhases(spec: ColumnAdditionSpec) GenerationResult;
```

```zig
/// Validate a ColumnAdditionSpec before generation: checks identifiers for
/// safety (no whitespace, semicolons, or SQL reserved words that would break
/// the fixed-template embedding) and checks that backfill_expr is non-empty.
/// Returns true if safe to generate, false otherwise (with reason populated).
/// `generatePhases` calls this internally; exposed here for pre-flight checks
/// in tests.
pub fn validateSpec(spec: ColumnAdditionSpec) ?FailureReason;
```

### Constraint name derivation (deterministic, no DB lookup needed)

The constraint name used in phase 1 and referenced in phase 3 is:

```
constraint_name = "<table>_<column>_nn"
```

The `generatePhases` function derives this from `spec.table` and `spec.column` by
concatenating with `_nn`. Phase 3's `VALIDATE CONSTRAINT` references the SAME computed
name — no lookup in `plat_migration_plan` or the DB is required.

### Migration runner call site (pseudocode — not a new export)

```zig
// migration runner pseudocode, per column-addition in a migration file:

const result = ddl_generate.generatePhases(spec);
switch (result) {
    .accept => |phased| {
        // Record all generated statements in plat_migration_plan:
        recordPhasedPlan(conn, phased);

        // Phase 1 (per tenant, DdlStep):
        fanout.runFanout(pool, tenants, phase1DdlStep(phased.phase1));

        // Phase 2 (per tenant, not DdlStep — owns its own transactions):
        for (tenants) |tenant| {
            backfill.runBackfill(pool, phased.phase2, backfill_config);
        }

        // Phase 3 (per tenant, DdlStep):
        fanout.runFanout(pool, tenants, phase3DdlStep(phased.phase3));
    },
    .phase_generation_failed => |fail| {
        recordGenerationFailure(conn, fail);
        return error.PhaseGenerationFailed;
        // No statement is executed against any tenant schema (DDL-03 AC4).
    },
}
```

### `BackfillIncomplete` and phase-3 retry (DDL-03 AC5)

When `VALIDATE CONSTRAINT` in phase 3 finds a violating row, the fanout records the tenant
as `FAILED` at phase 3 with reason `BackfillIncomplete`. The migration runner then:

1. Re-runs `backfill.runBackfill` for that tenant (phase 2 retry — idempotent per DDL-04 AC1).
2. Retries `VALIDATE CONSTRAINT` + `SET NOT NULL` for that tenant (phase 3 retry).

`BackfillIncomplete` is a verdict returned by the migration runner's per-tenant phase-3 step,
NOT a new error in `ddl_generate.zig` itself. The generator has already completed successfully
by the time phase 3 runs. The runner's retry logic is outside this module's scope.

## Data flow diagram

```
  ColumnAdditionSpec (from migration file parser)
            |
            | generatePhases(spec)
            ↓
  [ddl_generate.zig]
     validateSpec → FailureReason? → .phase_generation_failed
            |
            ↓ (safe)
     Phase1Statements (ALTER TABLE ... ADD COLUMN NULL
                       ALTER TABLE ... ADD CONSTRAINT ... NOT VALID)
     GeneratedBackfill (UPDATE ... WHERE c IS NULL AND ctid = ANY ...)
     Phase3Statements  (VALIDATE CONSTRAINT ..., ALTER COLUMN ... SET NOT NULL)
            |
            ↓
  .accept{PhasedDDL}
            |
            | (migration runner records in plat_migration_plan)
            ↓
  MIG-01 fanout executes per tenant:
     Phase 1 → DdlStep (lock_timeout 3s, statement_timeout 60s)
     Phase 2 → backfill.runBackfill (DDL-04, per-batch transactions)
     Phase 3 → DdlStep (lock_timeout 3s, statement_timeout 60s)
                  ↓ VALIDATE CONSTRAINT finds violating row?
               BackfillIncomplete → phase-2 re-run → phase-3 retry
```

## Error taxonomy

| Error | Origin | Handling |
|---|---|---|
| `GenerationResult.phase_generation_failed` | `generatePhases`: `unsafe_identifier`, `empty_backfill_expr`, `empty_column_type`, `unsupported_constraint_type` | Runner records the failure in `plat_migration_plan`; no statement executes against any tenant schema; migration plan exits with status 2 |
| `BackfillIncomplete` | Phase 3: `VALIDATE CONSTRAINT` finds violating row | Phase-2 re-run + phase-3 retry for the failing tenant; other tenants are unaffected |
| `LockTimeout` (from `backfill.BackfillError`) | Phase 1 or 3: `lock_timeout = 3s` exceeded | Tenant recorded FAILED at that phase; fanout continues to next tenant (DDL-03 AC6) |
| `StatementTimeout` (from `backfill.BackfillError`) | Phase 1 or 3: `statement_timeout = 60s` exceeded | Same as `LockTimeout` above |

## State transitions

State (in `plat_migration_state` — DDL-04's Type C schema) per `(migration_id, tenant, phase)`:

```
Phase 1 per tenant:
  (not started) → phase_generation_failed (terminal, no DB touched)
  (not started) → phase1 RUNNING → APPLIED | FAILED

Phase 2 per tenant:
  phase1 APPLIED → phase2 RUNNING (batches) → APPLIED | STALLED

Phase 3 per tenant:
  phase2 APPLIED → phase3 RUNNING → APPLIED | FAILED(BackfillIncomplete)
  FAILED(BackfillIncomplete) → phase2 re-run → phase3 RUNNING → APPLIED
```

## Dependencies

`src/platform/ddl_generate.zig` calls:
- `backfill.GeneratedBackfill` — the phase-2 descriptor type (shared type; no function calls)

`src/platform/ddl_generate.zig` must NOT depend on:
- `src/db/pool.zig` (no DB connection)
- `std.time` (no clock read)
- `std.process.getEnvVarOwned` (no env read)
- `ddl_validate.zig` — the generator does NOT re-validate its own output; the caller
  (migration runner) may call `validatePlatformDDL` on the generated statements if desired,
  but this is a caller concern, not a generator responsibility

## Test stub expectations

Unit tests (pure — no DB):

1. **TC-DDL-03-AC1:** `generatePhases` with a NOT NULL column addition returns exactly three
   phase groups; `phase3.validate_constraint` references the same constraint name as
   `phase1.add_constraint_not_valid`.
2. **TC-DDL-03-AC2:** The constraint name in `phase1.add_constraint_not_valid` uses the
   `ADD CONSTRAINT ... NOT VALID` form (not `CHECK ... NOT VALID` without the `NOT VALID`
   modifier), verifying that phase 3's `VALIDATE CONSTRAINT` will hold `SHARE UPDATE
   EXCLUSIVE` and not `ACCESS EXCLUSIVE`.
3. **TC-DDL-03-AC3:** Given `validate_constraint` is run after a backfill that sets all
   rows, `generatePhases` output phase 3 includes `ALTER COLUMN ... SET NOT NULL` — which
   PostgreSQL satisfies from the validated constraint with no full table scan (verified by
   inspecting the generated SQL, not by executing it).
4. **TC-DDL-03-AC4:** `generatePhases` with an empty `backfill_expr` returns
   `.phase_generation_failed{reason: .empty_backfill_expr}`.
5. **TC-DDL-03-AC4b:** `generatePhases` with an unsafe identifier (containing a semicolon)
   returns `.phase_generation_failed{reason: .unsafe_identifier}`.
6. **TC-DDL-03-AC6:** The generated phase-1 and phase-3 statement strings contain
   `SET LOCAL lock_timeout = '3s'` and `SET LOCAL statement_timeout = '60s'`.

Integration test (requires DB, exercises phase-3 `BackfillIncomplete`):

7. **TC-DDL-03-AC5:** Given a table with an existing row where the column is NULL (i.e.
   backfill was incomplete), when phase 3 runs, `VALIDATE CONSTRAINT` fails; the fanout
   records `BackfillIncomplete` for that tenant; after phase-2 re-run and phase-3 retry,
   the tenant is APPLIED.

## Open questions

1. **Statement text safety for identifiers:** `generatePhases` constructs statement text by
   embedding `spec.table`, `spec.column`, and `spec.backfill_expr` into fixed SQL templates.
   This is safe ONLY if the identifiers are validated first (no whitespace, no semicolons,
   no SQL injection vectors). `validateSpec` enforces this with the `unsafe_identifier`
   check, but the exact allow-list of characters must be confirmed by BACKEND-DEV in
   consultation with REQ-ANALYST. The safest rule: identifiers consist of `[a-z0-9_]` only
   (lower-case, digits, underscore) — the same constraint the DDL-05 `plat_` namespace check
   already imposes on platform-owned names.
2. **`backfill_expr` safety:** The `backfill_expr` field is embedded verbatim as the SET
   clause of the generated UPDATE. If `backfill_expr` contains SQL injection characters, the
   generated statement is malformed. The current design validates only that the field is
   non-empty; a more restrictive validation rule (e.g. must match `[a-z0-9_(), :'$]+`) may
   be needed. REQ-ANALYST should confirm whether callers can supply arbitrary expressions or
   only constant literals.
3. **Multi-column additions in one migration file:** DDL-03 generates phases for ONE column
   addition. If a migration file declares multiple column additions, the runner must call
   `generatePhases` once per addition and sequence the phase groups. The ordering rule (all
   phase-1s before any phase-2, etc.) is a runner concern outside this module; the design
   does not prescribe it. REQ-ANALYST should confirm whether this ordering is required.

## Resolved Open Questions

1. **Identifier allow-list** — The allow-list for `spec.table` and `spec.column` is
   `[a-z0-9_]` (lower-case letters, digits, underscore only). This matches the `plat_`
   namespace convention enforced by DDL-05 and is the minimal safe rule for embedding
   identifiers in fixed SQL templates without a SQL parser. `validateSpec` MUST reject any
   identifier that contains characters outside this set, returning
   `FailureReason.unsafe_identifier`.
   **Decision: closed — allow-list is `[a-z0-9_]`; BACKEND-DEV implements this in
   `validateSpec` without further REQ-ANALYST input.**

2. **`backfill_expr` safety** — Callers of `generatePhases` are trusted internal components
   (the migration plan layer, not external user input). A more restrictive character check
   on `backfill_expr` is therefore **out of scope for this batch**; the non-empty check
   is sufficient. If future callers accept user-supplied expressions, a separate design
   review is required.
   **Decision: out of scope — non-empty check only for `backfill_expr` at this stage.**

3. **Multi-column additions ordering** — Phase group sequencing (all phase-1s before any
   phase-2, etc.) is the runner's responsibility. `ddl_generate.zig` generates one
   `PhasedDDL` per `generatePhases` call; the runner sequences them. This is documented
   as a runner concern and requires no change to this module.
   **Decision: closed — sequencing is runner responsibility; no module interface change.**
