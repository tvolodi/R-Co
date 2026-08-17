# Test Spec: DDL-03 — Phased DDL generation

**Requirement:** DDL-03 — The platform SHOULD compile every column addition carrying a constraint
into exactly three phases: an expand phase issuing `ALTER TABLE t ADD COLUMN c <type> NULL`
together with `ALTER TABLE t ADD CONSTRAINT c_nn CHECK (c IS NOT NULL) NOT VALID`; a backfill
phase (DDL-04); and a constrain phase issuing `ALTER TABLE t VALIDATE CONSTRAINT c_nn` followed
by `ALTER TABLE t ALTER COLUMN c SET NOT NULL`. A change that cannot be expressed in three phases
SHALL be rejected with `PhaseGenerationFailed` rather than emitting a statement that takes a
wider lock.

**Priority:** SHOULD
**Test layer:** unit only (`generatePhases` is pure — no DB, no allocator, no clock). Integration
is not required because the generator produces SQL text; execution is the fanout's responsibility
(DDL-04 / MIG-01), not this generator's. The unit tests run deterministically against fixed
`ColumnAdditionSpec` inputs.
**Test-tier score (test_developer_guide.md §2.1):** 0 dimensions touched (pure function, no
schema change, no tenant isolation, no transaction, no Wasm) = **0 points → unit only.**
**Design:** `src/design/ddl-03-phased-ddl-generation.md`
**Implementation:** `src/platform/ddl_generate.zig` (`generatePhases`, `validateSpec`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a declared column addition with a NOT NULL constraint, WHEN the generator runs, THEN it emits exactly three phase groups and the emitted phase 3 references the constraint name created in phase 1. | `ddl03: TC-DDL-03-AC1 — generates three phases with consistent constraint name` (unit in `ddl_generate.zig`) |
| AC2 | GIVEN phase 3 executes, WHEN `VALIDATE CONSTRAINT` runs, THEN it holds `SHARE UPDATE EXCLUSIVE` and not `ACCESS EXCLUSIVE`, so concurrent reads and writes on the table continue. | `ddl03: TC-DDL-03-AC2 — phase1 uses NOT VALID form` (unit — verifies `NOT VALID` in phase 1 constraint, enabling the share-lock-only validate in phase 3) |
| AC3 | GIVEN `ALTER COLUMN c SET NOT NULL` runs after a validated `CHECK (c IS NOT NULL)`, WHEN it executes, THEN PostgreSQL derives the guarantee from the validated constraint and performs no full table scan. | `ddl03: TC-DDL-03-AC3 — phase3 includes SET NOT NULL` (unit — verifies `SET NOT NULL` statement present in phase 3, after validate) |
| AC4 | GIVEN a requested change the generator cannot express in three phases, WHEN generation runs, THEN `PhaseGenerationFailed` is returned and no statement is executed against any tenant schema. | `ddl03: TC-DDL-03-AC4 — empty backfill_expr returns phase_generation_failed` + `ddl03: TC-DDL-03-AC4b — unsafe identifier` + `ddl03: TC-DDL-03-AC4c — empty column_type` (unit) |
| AC5 | GIVEN `VALIDATE CONSTRAINT` finds a violating row, WHEN phase 3 runs, THEN it is rolled back with `BackfillIncomplete`, phase 2 re-runs for that tenant, and phase 3 is retried. | `TC-DDL-03-AC5-backfill-incomplete-recovery` (unit — verifies the generator still produces a valid phase 2 `GeneratedBackfill` struct whose SQL is the canonical IS NULL predicate; actual BackfillIncomplete recovery is DDL-04's responsibility) |
| AC6 | Every phase statement runs with `lock_timeout = 3s` and `statement_timeout = 60s`; a tenant exceeding either is recorded FAILED at that phase and the fanout continues to the next tenant. | `TC-DDL-03-AC6-lock-and-statement-timeouts` (unit — verifies SET LOCAL timeout literals in phase 1 and phase 3) |

---

## Test cases

### TC-DDL-03-AC1-three-phases-consistent-constraint: generates three phases with matching constraint name
**Given:** A `ColumnAdditionSpec` with `table = "tenant_data"`, `column = "updated_by"`,
`column_type = "TEXT"`, `backfill_expr = "'system'"`, `constraint = .not_null`, `order = 1`.
**When:** `generatePhases(spec)` is called.
**Then:** The result tag is `.accept`. `phased.constraint_name == "tenant_data_updated_by_nn"`.
`phase1.add_constraint_not_valid` contains `"tenant_data_updated_by_nn"`.
`phase3.validate_constraint` contains `"tenant_data_updated_by_nn"`.
**Layer:** unit
**Acceptance criterion mapped:** AC1
**Zig test:** `ddl03: TC-DDL-03-AC1 — generates three phases with consistent constraint name` (`src/platform/ddl_generate.zig`)

### TC-DDL-03-AC2-not-valid-form: phase 1 constraint uses NOT VALID
**Given:** A valid `ColumnAdditionSpec` (e.g. `table = "orders"`, `column = "processed_at"`,
`column_type = "TIMESTAMPTZ"`, `backfill_expr = "now()"`).
**When:** `generatePhases(spec)` is called.
**Then:** `phase1.add_constraint_not_valid` ends with `"NOT VALID"`. This ensures phase 3's
`VALIDATE CONSTRAINT` takes a `SHARE UPDATE EXCLUSIVE` lock (not `ACCESS EXCLUSIVE`), allowing
concurrent reads/writes.
**Layer:** unit
**Acceptance criterion mapped:** AC2
**Zig test:** `ddl03: TC-DDL-03-AC2 — phase1 uses NOT VALID form` (`src/platform/ddl_generate.zig`)

### TC-DDL-03-AC3-set-not-null: phase 3 includes SET NOT NULL after VALIDATE CONSTRAINT
**Given:** A valid `ColumnAdditionSpec` (e.g. `table = "items"`, `column = "slug"`,
`column_type = "TEXT"`, `backfill_expr = "'default'"`).
**When:** `generatePhases(spec)` is called.
**Then:** `phase3.validate_constraint` contains `"VALIDATE CONSTRAINT"`.
`phase3.set_not_null` contains `"SET NOT NULL"`.
The validate statement appears before the set_not_null statement (by field ordering), so
PostgreSQL can derive the NOT NULL guarantee from the validated constraint.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `ddl03: TC-DDL-03-AC3 — phase3 includes SET NOT NULL` (`src/platform/ddl_generate.zig`)

### TC-DDL-03-AC4-generation-failed-on-unsupported: unsupported/unsafe specs return PhaseGenerationFailed
**Given:** Three distinct invalid `ColumnAdditionSpec` values: (a) `backfill_expr = ""`,
(b) `table = "it;ems"` (SQL-unsafe identifier), (c) `column_type = ""`.
**When:** `generatePhases(spec)` is called for each.
**Then:** Each result tag is `.phase_generation_failed`. Reasons are
`.empty_backfill_expr`, `.unsafe_identifier`, and `.empty_column_type` respectively.
No statement text is produced for any of the three calls.
**Layer:** unit
**Acceptance criterion mapped:** AC4
**Zig test:** `ddl03: TC-DDL-03-AC4 — empty backfill_expr returns phase_generation_failed` + `ddl03: TC-DDL-03-AC4b — unsafe identifier (semicolon) returns phase_generation_failed` + `ddl03: TC-DDL-03-AC4c — empty column_type returns phase_generation_failed` (`src/platform/ddl_generate.zig`)

### TC-DDL-03-AC5-backfill-incomplete-recovery: phase 2 produces a canonical IS NULL predicate
**Given:** A valid `ColumnAdditionSpec`.
**When:** `generatePhases(spec)` is called.
**Then:** `phase2.sql` contains `"WHERE"`, `"IS NULL"`, and `"LIMIT $1"` (the canonical `ctid`
predicate the DDL-04 backfill loop requires for idempotent resume). If `VALIDATE CONSTRAINT`
finds a violating row (BackfillIncomplete), re-running phase 2 against the same predicate
leaves already-backfilled rows unchanged — the IS NULL predicate is the idempotency guard.
**Layer:** unit
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-DDL-03-AC5-phase2-is-null-predicate` (`src/platform/ddl_generate.zig`)

### TC-DDL-03-AC6-lock-and-statement-timeouts: phase 1 and phase 3 carry SET LOCAL timeout guards
**Given:** A valid `ColumnAdditionSpec`.
**When:** `generatePhases(spec)` is called.
**Then:** `phase1.set_lock_timeout == "SET LOCAL lock_timeout = '3s'"`.
`phase1.set_statement_timeout == "SET LOCAL statement_timeout = '60s'"`.
`phase3.set_lock_timeout == "SET LOCAL lock_timeout = '3s'"`.
`phase3.set_statement_timeout == "SET LOCAL statement_timeout = '60s'"`.
These are the only timeout values; the fanout applies them as `SET LOCAL` before each phase
statement so a tenant exceeding either threshold rolls back that phase only.
**Layer:** unit
**Acceptance criterion mapped:** AC6
**Zig test:** `TC-DDL-03-AC6-lock-and-statement-timeouts` (`src/platform/ddl_generate.zig`)
