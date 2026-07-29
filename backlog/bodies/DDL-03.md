> **Extends:** DDL-02, turning the ordering rule into generated output.

> The platform SHOULD compile every column addition carrying a constraint into exactly three phases: an expand phase issuing `ALTER TABLE t ADD COLUMN c <type> NULL` together with `ALTER TABLE t ADD CONSTRAINT c_nn CHECK (c IS NOT NULL) NOT VALID`; a backfill phase (DDL-04); and a constrain phase issuing `ALTER TABLE t VALIDATE CONSTRAINT c_nn` followed by `ALTER TABLE t ALTER COLUMN c SET NOT NULL`. A change that cannot be expressed in three phases SHALL be rejected with `PhaseGenerationFailed` rather than emitting a statement that takes a wider lock.

**Acceptance Criteria:**
- GIVEN a declared column addition with a NOT NULL constraint, WHEN the generator runs, THEN it emits exactly three phase groups and the emitted phase 3 references the constraint name created in phase 1.
- GIVEN phase 3 executes, WHEN `VALIDATE CONSTRAINT` runs, THEN it holds `SHARE UPDATE EXCLUSIVE` and not `ACCESS EXCLUSIVE`, so concurrent reads and writes on the table continue.
- GIVEN `ALTER COLUMN c SET NOT NULL` runs after a validated `CHECK (c IS NOT NULL)`, WHEN it executes, THEN PostgreSQL derives the guarantee from the validated constraint and performs no full table scan.
- GIVEN a requested change the generator cannot express in three phases, WHEN generation runs, THEN `PhaseGenerationFailed` is returned and no statement is executed against any tenant schema.
- GIVEN `VALIDATE CONSTRAINT` finds a violating row, WHEN phase 3 runs, THEN it is rolled back with `BackfillIncomplete`, phase 2 re-runs for that tenant, and phase 3 is retried.
- Every phase statement runs with `lock_timeout = 3s` and `statement_timeout = 60s`; a tenant exceeding either is recorded FAILED at that phase and the fanout continues to the next tenant.

**See:** DDL-01, DDL-02, DDL-04 (phase 2), MIG-01 (the tenant fanout executing each phase)
