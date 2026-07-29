> **Extends:** DDL-01, adding a cross-statement ordering check to the same validation pass.

> `ValidatePlatformDDL` SHALL walk each migration file set in declaration order and reject any file set that constrains a column before that column exists and has been backfilled. A `SET NOT NULL`, an `ADD CONSTRAINT` written without `NOT VALID`, or an `ADD COLUMN ... NOT NULL` without a constant default appearing ahead of its expand and backfill statements SHALL be rejected with `ConstrainBeforeExpand`, naming both the constraining statement and the statement it depends on.

**Acceptance Criteria:**
- GIVEN a file set running `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL`, WHEN validated, THEN `ConstrainBeforeExpand` is returned, because the column carries no constant default and no backfill precedes the constraint.
- GIVEN a file set running `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL` followed immediately by `ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL` with no backfill statement between them, WHEN validated, THEN `ConstrainBeforeExpand` is returned naming both statements.
- GIVEN a file set that adds the column nullable, adds `CHECK (first_event_at IS NOT NULL) NOT VALID`, backfills, then runs `VALIDATE CONSTRAINT`, WHEN validated, THEN the verdict is ACCEPT.
- GIVEN an `ADD CONSTRAINT ... FOREIGN KEY` written without `NOT VALID`, WHEN validated, THEN `ConstrainBeforeExpand` is returned; a foreign key added without `NOT VALID` scans the whole table under a lock that blocks writes on both referencing and referenced tables.
- The rejection message names the file and the byte offset of both the constraining statement and the statement it depends on.

**See:** DDL-01 (the validator this extends), DDL-03 (the three-phase form that satisfies this rule), DDL-04 (the backfill that must sit between expand and constrain)
