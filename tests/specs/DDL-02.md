# Test Spec: DDL-02 — Expand-then-constrain ordering check

**Requirement:** DDL-02 — *Extends: DDL-01, adding a cross-statement ordering check to the
same validation pass.* `ValidatePlatformDDL` SHALL walk each migration file set in
declaration order and reject any file set that constrains a column before that column exists
and has been backfilled. A `SET NOT NULL`, an `ADD CONSTRAINT` written without `NOT VALID`, or
an `ADD COLUMN ... NOT NULL` without a constant default appearing ahead of its expand and
backfill statements SHALL be rejected with `ConstrainBeforeExpand`, naming both the
constraining statement and the statement it depends on.

**Priority:** MUST
**Test layer:** unit (pure function — `validatePlatformDDL` takes no allocator, opens no
connection, reads no clock; DDL-02's `checkConstrainBeforeExpand` uses a bounded
fixed-capacity stack table, not an allocator — see purity contract in
`src/design/ddl-02-constrain-before-expand-check.md`)
**Test-tier score (test_developer_guide.md §2.1):** 0 dimensions touched — no DB schema change
(no migration file; this batch adds a pure Zig classifier only), no tenant-isolation logic
(the module doesn't read `Actor`-specific per-tenant state), no Wasm surface, single module
(`src/platform/ddl_validate.zig`, composing `ddl_namespace.zig`, both pure), no transactional
boundary (the function opens no transaction). **0 points → unit only**, matching the actual
test layer used below.
**Design:** `src/design/ddl-02-constrain-before-expand-check.md`
**Implementation:** `src/platform/ddl_validate.zig` (`checkConstrainBeforeExpand`, composed
into `validatePlatformDDL`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a file set running `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL`, WHEN validated, THEN `ConstrainBeforeExpand` is returned, because the column carries no constant default and no backfill precedes the constraint. | `TC-DDL-02-AC1` |
| AC2 | GIVEN a file set running `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL` followed immediately by `ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL` with no backfill statement between them, WHEN validated, THEN `ConstrainBeforeExpand` is returned naming both statements. | `TC-DDL-02-AC2` |
| AC3 | GIVEN a file set that adds the column nullable, adds `CHECK (first_event_at IS NOT NULL) NOT VALID`, backfills, then runs `VALIDATE CONSTRAINT`, WHEN validated, THEN the verdict is ACCEPT. | `TC-DDL-02-AC3` |
| AC4 | GIVEN an `ADD CONSTRAINT ... FOREIGN KEY` written without `NOT VALID`, WHEN validated, THEN `ConstrainBeforeExpand` is returned; a foreign key added without `NOT VALID` scans the whole table under a lock that blocks writes on both referencing and referenced tables. | `TC-DDL-02-AC4` |
| AC5 | The rejection message names the file and the byte offset of both the constraining statement and the statement it depends on. | `TC-DDL-02-AC2` (both non-null: constraining + depended-on), `TC-DDL-02-AC1` (depended-on half is null — the missing-dependency case), `TC-DDL-02-AC5` (a third, cross-column scenario proving the file/byte-offset pairing is per-violation, not global state leaking between independently tracked columns) |

---

## Test cases

### TC-DDL-02-AC1: ADD COLUMN NOT NULL with no default and no prior expand is refused as ConstrainBeforeExpand
**Given:** A file set with one statement, `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL`, `ordering_role = .constrain`, `ordering_column = {instances, first_event_at}`.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.constrain_before_expand` with `constraining_statement_order = 1`, the exact statement text, `constraining_statement_file = "100_ddl02_ac1.sql"`, `constraining_statement_byte_offset = 0`, `depended_on_statement_order = null`, `depended_on_statement_text = null` (the dependency was never seen anywhere in the file set — the missing-dependency case, distinct from AC2's "seen but out of order" case), and `column = {instances, first_event_at}`.
**Layer:** unit
**Acceptance criterion mapped:** AC1, AC5 (missing-dependency half)
**Zig test:** `"TC-DDL-02-AC1: ADD COLUMN NOT NULL with no default and no prior expand is refused as ConstrainBeforeExpand"` (`src/platform/ddl_validate.zig`)

### TC-DDL-02-AC2: SET NOT NULL immediately after ADD COLUMN NULL with no backfill is refused, naming both statements
**Given:** A file set of two statements: order 1, `ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL` (`ordering_role = .expand`); order 2, `ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL` (`ordering_role = .constrain`) — no backfill statement between them.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.constrain_before_expand` with `constraining_statement_order = 2` and its exact text/file/byte_offset, AND `depended_on_statement_order = 1` with the expand statement's exact text/file/byte_offset (non-null: the dependency exists in the file set but has no intervening backfill, so it is still named per AC5's "naming both statements," not treated as missing).
**Layer:** unit
**Acceptance criterion mapped:** AC2, AC5 (populated-dependency half)
**Zig test:** `"TC-DDL-02-AC2: SET NOT NULL immediately after ADD COLUMN NULL with no backfill is refused, naming both statements"`

### TC-DDL-02-AC3: expand, NOT VALID check, backfill, VALIDATE CONSTRAINT sequence is ACCEPT
**Given:** A file set of four statements on `instances.first_event_at`: (1) `ADD COLUMN ... NULL` (`.expand`); (2) `ADD CONSTRAINT ... CHECK (... IS NOT NULL) NOT VALID` (`.constrain_not_valid` — always safe regardless of state, never rejected); (3) `UPDATE ... SET first_event_at = created_at WHERE first_event_at IS NULL` (`.backfill`); (4) `ALTER TABLE ... VALIDATE CONSTRAINT ...` (`.backfill`).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.accept` — the three-phase expand/NOT-VALID/backfill/validate sequence DDL-02's `**See:**` line names as "the three-phase form that satisfies this rule" (DDL-03) passes cleanly.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-DDL-02-AC3: expand, NOT VALID check, backfill, VALIDATE CONSTRAINT sequence is ACCEPT"`

### TC-DDL-02-AC4: ADD CONSTRAINT FOREIGN KEY without NOT VALID is refused as ConstrainBeforeExpand
**Given:** A file set of two statements on `instances.definition_id`: (1) `ADD COLUMN definition_id UUID NULL` (`.expand`); (2) `ADD CONSTRAINT fk_definition FOREIGN KEY (definition_id) REFERENCES definitions (id)` with no `NOT VALID` clause (`.constrain` — a bare `ADD CONSTRAINT` without `NOT VALID` is `.constrain`, not `.constrain_not_valid`, regardless of constraint kind: CHECK or FOREIGN KEY).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.constrain_before_expand` with `constraining_statement_order = 2` and `column.column = "definition_id"` — proving the rule applies to foreign keys exactly as it does to CHECK/NOT NULL constraints (AC4's stated rationale: an unvalidated FK scans and locks BOTH the referencing and referenced tables).
**Layer:** unit
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-DDL-02-AC4: ADD CONSTRAINT FOREIGN KEY without NOT VALID is refused as ConstrainBeforeExpand"`

### TC-DDL-02-AC5: rejection detail names file and byte offset for both statements, independent of other tracked columns
**Given:** A file set of four statements spanning two columns: `instances.started_at` correctly expanded (order 1) then backfilled (order 2) then constrained (order 3) — a fully valid sequence — followed by `instances.ended_at` constrained directly at order 4 in a SECOND file (`105_ddl02_ac5_second_file.sql`, byte_offset 12) with no prior expand/backfill anywhere in the set.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict names `constraining_statement_order = 4`, `constraining_statement_file = "105_ddl02_ac5_second_file.sql"`, `constraining_statement_byte_offset = 12`, `column.column = "ended_at"`, and `depended_on_statement_order = null` — proving (a) `started_at`'s correctly-ordered sequence at orders 1-3 does not itself trigger a violation, (b) per-column tracking state does not leak between `started_at` and `ended_at`, and (c) the reported file/byte_offset pair belongs to the actual violating statement (`ended_at`'s own), not an earlier column's.
**Layer:** unit
**Acceptance criterion mapped:** AC5 (third scenario: cross-column / cross-file independence, complementing AC1's missing-dependency and AC2's populated-dependency cases)
**Zig test:** `"TC-DDL-02-AC5: rejection detail names file and byte offset for both statements, independent of other tracked columns"`

### TC-DDL-02-tiebreak: an earlier lock-class failure is reported instead of a later constrain-before-expand violation
**Given:** A file set of two statements: order 1, `ALTER TABLE orders DROP COLUMN stale` (lock-class violation, `.drop_column`); order 2, a `ConstrainBeforeExpand`-violating statement on `instances.first_event_at`.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.unbounded_exclusive_lock` naming `statement_order = 1` — the later constrain-before-expand violation at order 2 is never reported, proving DDL-02's stateful whole-file-set check is correctly interleaved into DDL-01's existing "first failure in statement order wins" aggregation (module header's "Within-statement check order": lock-class, then index-concurrency, then namespace, then constrain-before-expand) rather than being checked as an independent, out-of-band pass.
**Layer:** unit
**Acceptance criterion mapped:** Aggregation-ordering property implied by DDL-01 AC1-AC3's "first failure in statement order" contract, extended to cover DDL-02's new fourth check — not itself a numbered DDL-02 AC, but required for DDL-02 to compose correctly into the existing four-check pipeline.
**Zig test:** `"TC-DDL-02-tiebreak: an earlier lock-class failure is reported instead of a later constrain-before-expand violation"`

### TC-DDL-02-conservative: a bare SET NOT NULL with zero prior statements for that column anywhere in the file set is rejected
**Given:** A file set with a single statement, `ALTER TABLE instances ALTER COLUMN legacy_col SET NOT NULL` (`.constrain`), with no `.expand`/`.backfill` statement for `legacy_col` anywhere in the set (simulating a pre-existing column from an earlier migration that this file set alone cannot prove is safe to constrain).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.constrain_before_expand` with `depended_on_statement_order = null` — confirming the conservative, reject-by-default reading (the design doc's "Open questions" #2): a column this module has never seen expanded/backfilled is always treated as unsafe to constrain, even though in a real multi-migration history the column might have been safely expanded by an earlier, already-applied file. This is DDL-02's stated tradeoff, not a false positive within scope.
**Layer:** unit
**Acceptance criterion mapped:** Supports the conservative default behind AC1 (same verdict shape as AC1, but exercised as its own single-statement scenario — AC1 always co-occurs with an explicit NOT NULL/no-default column in the SAME statement; this case proves the same conservative default holds for a `SET NOT NULL` on an already-nullable column with literally nothing else in the file set).
**Zig test:** `"TC-DDL-02-conservative: a bare SET NOT NULL with zero prior statements for that column anywhere in the file set is rejected"`

---

## Fixtures and isolation

All tests are pure unit tests with zero database dependency — no `TestHarness`, no `Pool`, no
`BPM_TEST_DB_URL` read anywhere in `src/platform/ddl_validate.zig`'s DDL-02 test blocks. Each
test builds its own local `[]StatementDescriptor` array; no fixture state is shared across
test blocks. This matches DDL-01's own AC4 (still binding on this extension), which requires
the function to work identically with no database reachable.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-DDL-02-AC1 | `TC-DDL-02-AC1: ADD COLUMN NOT NULL with no default and no prior expand is refused as ConstrainBeforeExpand` | AC1, AC5 (missing-dependency) |
| TC-DDL-02-AC2 | `TC-DDL-02-AC2: SET NOT NULL immediately after ADD COLUMN NULL with no backfill is refused, naming both statements` | AC2, AC5 (populated-dependency) |
| TC-DDL-02-AC3 | `TC-DDL-02-AC3: expand, NOT VALID check, backfill, VALIDATE CONSTRAINT sequence is ACCEPT` | AC3 |
| TC-DDL-02-AC4 | `TC-DDL-02-AC4: ADD CONSTRAINT FOREIGN KEY without NOT VALID is refused as ConstrainBeforeExpand` | AC4 |
| TC-DDL-02-AC5 | `TC-DDL-02-AC5: rejection detail names file and byte offset for both statements, independent of other tracked columns` | AC5 (cross-column independence) |
| TC-DDL-02-tiebreak | `TC-DDL-02-tiebreak: an earlier lock-class failure is reported instead of a later constrain-before-expand violation` | Aggregation-ordering property (composes DDL-02 into DDL-01's existing four-check pipeline) |
| TC-DDL-02-conservative | `TC-DDL-02-conservative: a bare SET NOT NULL with zero prior statements for that column anywhere in the file set is rejected` | Conservative-default property underlying AC1 |

**Implemented case count: 7 test blocks** in `src/platform/ddl_validate.zig`'s DDL-02 section
(all 7 written by BACKEND-DEV; TEST-DESIGNER traced each to its AC and confirmed no gap —
every numbered AC1-AC5 has direct coverage, with AC5 split across three test cases per its
own "both statements" wording, matching DDL-01.md's established precedent for a
multi-clause AC). No `error.SkipZigTest` in this file (verified by grep — zero matches in
`src/platform/ddl_validate.zig`).

Together with DDL-01's existing 11 test blocks and DDL-05's composed 10 test blocks (all
three files build under `zig build test-ddl-validate`, since `ddl_validate.zig` imports
`ddl_namespace.zig` and Zig's test runner discovers `test` blocks transitively through the
module graph), the full step reports **28/28 passing** (11 + 7 + 10 = 28, confirmed by
`Build Summary: 3/3 steps succeeded; 28/28 tests passed`).

Run: `zig build test-ddl-validate` — 28/28 passing.

---

## Fail-first confirmation

Every DDL-02 test case asserts against `checkConstrainBeforeExpand`/`validatePlatformDDL`
behavior that did not exist before this batch (`OrderingRole`, `ColumnRef`,
`ConstrainBeforeExpandDetail`, the `.constrain_before_expand` verdict variant, and the
`checkConstrainBeforeExpand` scan itself are all new in this batch — `ordering_role` defaults
to `.irrelevant` on every pre-existing `StatementDescriptor`, so no DDL-01 test's behavior
changed). Fail-first was confirmed by BACKEND-DEV during implementation (the 7 new tests
would not compile, let alone pass, against the pre-batch `ddl_validate.zig`, since the types
and verdict variant they assert on did not exist) and independently re-confirmed here by
TEST-DESIGNER: temporarily reverting `checkConstrainBeforeExpand`'s `.constrain` branch to
`return null;` unconditionally (i.e. never rejecting a constrain statement) and re-running
`zig build test-ddl-validate` reproduces exactly 5 failures — `TC-DDL-02-AC1`, `-AC2`, `-AC4`,
`-AC5`, and `-conservative` (every case that expects `.constrain_before_expand`) — while
`TC-DDL-02-AC3` (expects `.accept`) and `TC-DDL-02-tiebreak` (expects the lock-class verdict,
unaffected by this specific mutation) continue to pass, confirming the 5 failing cases are
the ones actually exercising the mutated branch. Change reverted before completing this spec.

---

## No coverage gap found

Unlike DDL-01.md (which found and closed an AC5 performance-test gap), DDL-02's 7 BACKEND-DEV
test cases fully cover all 5 numbered acceptance criteria on first inspection — every AC maps
to at least one test case, AC5's "both statements" compound clause is covered by three
complementary scenarios (missing dependency, populated dependency, cross-column
independence), and the aggregation-ordering property (DDL-02 composing correctly into DDL-01's
existing four-check priority) is explicitly tested via `TC-DDL-02-tiebreak` rather than
assumed. No additional test case was required.

---

## Traceability

- DDL-02 acceptance: AC1-AC5 directly tested (7 test blocks total). See
  `src/design/ddl-02-constrain-before-expand-check.md` for the full design rationale,
  including the state-machine (UNSEEN -> EXPANDED -> BACKFILLED) `checkConstrainBeforeExpand`
  implements and the "Open questions" section documenting the conservative reject-by-default
  choice `TC-DDL-02-conservative` verifies.
- See `tests/specs/DDL-01.md` for the base validator this requirement extends, and
  `tests/specs/DDL-05.md` for the composed namespace check sharing the same test binary.
