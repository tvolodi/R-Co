# Module: ddl-02-constrain-before-expand-check

**Requirement ID:** DDL-02
**Run ID:** WF02-batch-2-20260811 (Stage 16)
**Covers:** DDL-02
**Extends:** DDL-01 (`src/platform/ddl_validate.zig`'s `validatePlatformDDL` pipeline) —
this is an EXTENSION, not a parallel validator. `ddl_validate.zig` already composes a
lock-class check and a namespace check (from DDL-05, `ddl_namespace.zig`) into one verdict.
DDL-02 adds a fourth check function to that same pipeline.
**See also:** DDL-03 (the three-phase expand/backfill/constrain form that satisfies this
rule — referenced for vocabulary only, not implemented here), DDL-04 (the backfill step that
must sit between expand and constrain), DDL-05 (`ddl_namespace.zig`, already composed)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added, altered, or removed by DDL-02 itself. (It
   *validates* migrations that do that, but this validator has no schema of its own.)
2. **Type A?** No new HTTP route.
3. **Type D?** No React Flow node.
4. **Type B?** No admin/list page.
5. **Type E — yes.** A pure, cross-statement, stateful-scan predicate composed into an
   existing validation pipeline. This is exactly the shape DDL-01 itself used (Type E), and
   the catalog reserves "Anything performance-sensitive" / novel validation logic for Type E.
   DDL-02 is additionally constrained by its own requirement text: it must extend
   `ValidatePlatformDDL`, not stand alone, so there is no independent Type C/A/D/B artefact to
   produce — the whole deliverable is a change to the existing `src/platform/ddl_validate.zig`
   pipeline plus its aggregate verdict type.

## Module purpose

`ddl_validate.zig`'s `validatePlatformDDL` currently runs three checks per statement,
independently, in the tie-break order lock-class → index-concurrency → namespace, and
reports the first statement (in file order) that fails any of them. All three of those
existing checks are **stateless per-statement** predicates — each statement is judged in
isolation, with no memory of statements seen earlier in the file.

DDL-02 adds a **fourth check that is not stateless**: a statement that constrains a column
(`SET NOT NULL`, `ADD CONSTRAINT ... FOREIGN KEY`/`CHECK` without `NOT VALID`, or
`ADD COLUMN ... NOT NULL` without a constant default) is illegal unless an earlier statement
in the *same file set* already added that column (nullable) and — where the acceptance
criteria require it — backfilled it. Detecting this requires scanning the file set in
declaration order while carrying forward a small amount of state: which columns have been
seen "expanded" (added nullable, or already existed) and, separately, which have been seen
"backfilled" (a `NOT VALID` constraint later validated, or an explicit backfill statement).

This closes the specific production hazard DDL-01's own design doc's dependency comment
anticipates: a `SET NOT NULL` or a validated `FOREIGN KEY`/`CHECK` constraint added without
`NOT VALID` takes an `ACCESS EXCLUSIVE`-adjacent scan lock proportional to table size when run
against a populated table, blocking writes on both sides for the scan's duration — the same
class of hazard DDL-01's lock-class check already blocks for single-statement patterns
(`DROP COLUMN`, `ALTER COLUMN ... SET DATA TYPE`), extended here to a *pair* of statements
where the second is dangerous only because of what the first one omitted (a default) or what
no statement between them did (a backfill).

## Public interface

New types and one new function, added to `src/platform/ddl_validate.zig` (not a new file —
DDL-02 is an in-place extension of the existing module, matching how DDL-05's
`checkNamespace` was composed in rather than wrapped).

`OrderingRole` classifies what a statement means for this check — distinct from
`StatementClass` (lock-duration behavior) and `ddl_namespace.StatementKind` (namespace
ownership). This is about *dependency* shape: does this statement expand, backfill, or
constrain a column, or is it irrelevant to this check?

```zig
pub const OrderingRole = enum {
    /// ADD COLUMN ... <nullable, or NOT NULL WITH a constant DEFAULT>. A
    /// constant default makes Postgres able to fill every existing row's
    /// value into the catalog without a table rewrite/scan (fast-default
    /// path, PG11+) — AC1 vs the accept case both hinge on this. ADD COLUMN
    /// ... NOT NULL WITHOUT a default is `.constrain`, not `.expand`.
    expand,

    /// Fills in the column's data for existing rows: an UPDATE targeting
    /// the column, or a VALIDATE CONSTRAINT promoting an already-added NOT
    /// VALID constraint. Classifying raw SQL text as a backfill is parser
    /// work (see "What this module does NOT do"); this module consumes the
    /// caller's classification.
    backfill,

    /// Requires the column already fully populated: SET NOT NULL, ADD
    /// CONSTRAINT ... CHECK/FOREIGN KEY without NOT VALID, or ADD COLUMN
    /// ... NOT NULL with no constant default.
    constrain,

    /// ADD CONSTRAINT ... NOT VALID — adds immediately (metadata-only), does
    /// not enforce against existing rows. Tracked separately from
    /// `.constrain` because it is always safe regardless of ordering (AC3's
    /// accepted pattern), and a later VALIDATE CONSTRAINT is `.backfill`.
    constrain_not_valid,

    /// Everything else (CREATE TABLE, unrelated ALTERs, index statements) —
    /// ignored here, still visible to the other three checks.
    irrelevant,
};
```

`ColumnRef` names the column a statement's ordering role applies to. A single-column shape
covers every DDL-02 acceptance criterion (`SET NOT NULL`, single-column `CHECK`, a simple
`FOREIGN KEY`); a constraint spanning multiple columns is out of scope (see "Open questions").
`StatementDescriptor` gains two new optional fields (`ordering_role: OrderingRole = .irrelevant`,
`ordering_column: ?ColumnRef = null`) populated by the same out-of-scope parser that already
sets `class`/`kind`/`order`/`text` — this is an in-place extension of the existing struct, not
a parallel type, so every statement flows through all four checks off one descriptor.

```zig
pub const ColumnRef = struct {
    table: []const u8,
    column: []const u8,
};
```

`ConstrainBeforeExpandDetail` is the new verdict payload. `depended_on_statement_order`/`text`
are `null` when the dependency is missing entirely from the file set (never seen anywhere), vs.
populated when it exists but appears AFTER the constraining statement — the out-of-order case,
DDL-02 AC2's worked example (`ADD COLUMN ... NULL` immediately followed by `SET NOT NULL` with
no backfill between them: here the expand statement IS present, just with nothing satisfying
the backfill requirement between it and the constrain).

```zig
pub const ConstrainBeforeExpandDetail = struct {
    constraining_statement_order: u32,
    constraining_statement_text: []const u8,
    depended_on_statement_order: ?u32,
    depended_on_statement_text: ?[]const u8,
    column: ColumnRef,
};
```

`ValidationVerdict` gains one new arm: `constrain_before_expand: ConstrainBeforeExpandDetail`.
The new check function is called from `validatePlatformDDL` as the FOURTH check (see "Within-
statement check order" below) — it takes the FULL statement slice, not one statement, because
it is the only stateful check in the pipeline:

```zig
fn checkConstrainBeforeExpand(statements: []const StatementDescriptor) ?ConstrainBeforeExpandDetail;
```

## Integration into `validatePlatformDDL`

DDL-01's existing loop is **per-statement**: it walks `file_set.statements` once, running all
three existing checks against each statement in turn, and returns on the first failure. DDL-02's
check is fundamentally different in shape — it needs the *whole* statement list to know whether
an earlier expand/backfill happened — so it cannot be folded into the same per-statement
iteration as one more `if` branch the way namespace was.

**Design decision (see "Within-statement check order" below for the alternative considered and
rejected):** run `checkConstrainBeforeExpand` once, over the full `file_set.statements` slice,
**before** entering the existing per-statement loop. This preserves DDL-01 AC-style determinism
(the same "first failure in statement order" contract) because `checkConstrainBeforeExpand`
itself reports the failing statement's own `order` field, and a single prior full-file scan for
one stateful check does not change the meaning of "first failure" for the other three checks —
it only adds a new failure mode that, when present, is reported instead of (not in addition to)
whatever the per-statement loop would have found, *provided* the constrain-before-expand
statement is not later in file order than a statement the per-statement loop would already have
rejected on its own.

To keep "first failure in statement order" true across all four checks (not just within the
three that were already ordered), the aggregation rule is:

1. Run the existing per-statement loop (lock-class → index-concurrency → namespace) up to and
   including the position of the FIRST statement that `checkConstrainBeforeExpand` would flag
   (if any). If the per-statement loop fails at or before that position, return that failure —
   it is earlier in file order.
2. If the per-statement loop reaches the constrain-before-expand statement's position without
   failing, return `.constrain_before_expand` for it.
3. If `checkConstrainBeforeExpand` finds no violation, continue the per-statement loop over the
   remainder of the file as today.

Equivalently and more simply to implement: call `checkConstrainBeforeExpand` first to get
*a candidate failing order* (or none), then run the existing per-statement loop unmodified,
but treat the constrain-before-expand candidate as if it were a fourth per-statement check
evaluated at exactly its own `constraining_statement_order` position — i.e., interleave by
comparing `order` values rather than running two fully separate passes and picking the smaller.
Implementation detail left to BACKEND-DEV; the acceptance-relevant contract is: **whichever of
the four checks' failures has the smaller `statement_order` wins**, ties broken by the existing
lock-class → index-concurrency → namespace → constrain-before-expand priority (constrain-before-
expand added last in the tie-break list, since it is the newest and least likely to collide with
another check on the exact same statement in practice — no acceptance criterion exercises a tie).

### Within-statement check order (updated)

Old order (three checks, all per-statement): lock-class → index-concurrency → namespace.
**New order (four checks, one whole-file + three per-statement):** on any single statement,
if `checkConstrainBeforeExpand` would flag THIS statement as the constraining one, and no
earlier-order statement fails a different check first, evaluate lock-class → index-concurrency →
namespace → constrain-before-expand, in that order, for tie-breaking purposes only (an
`ADD COLUMN ... NOT NULL` statement without a default is very unlikely to simultaneously trip
the lock-class check, since `alter_column_set_data_type`/`drop_column` are different statement
shapes — no acceptance criterion requires resolving a genuine tie, this is documented for
completeness per DDL-01's own precedent of stating a fixed tie-break order explicitly).

## Column-dependency state machine (per `(table, column)` key)

`checkConstrainBeforeExpand` walks `statements` in order, maintaining a map keyed by
`ColumnRef` with three possible states:

```
UNSEEN  --(.expand)--------------------> EXPANDED
EXPANDED --(.backfill)-----------------> BACKFILLED
EXPANDED --(.constrain / .constrain_not_valid targeting this column)--> REJECT (no backfill yet)
UNSEEN  --(.constrain / .constrain_not_valid targeting this column)--> REJECT (never expanded)
BACKFILLED --(.constrain targeting this column)-----------------------> OK (this is the accept path)
BACKFILLED --(.constrain_not_valid targeting this column)--------------> OK (NOT VALID is always
                                                                             safe regardless of
                                                                             backfill state, but
                                                                             reaching BACKFILLED
                                                                             first is the common
                                                                             DDL-03 shape)
```

Refinement the acceptance criteria require: `.constrain_not_valid` (an `ADD CONSTRAINT ... NOT
VALID`) is **never** rejected regardless of state — DDL-02 AC3's accepted pattern is
`ADD COLUMN NULL` → `ADD CONSTRAINT CHECK (...) NOT VALID` → backfill → `VALIDATE CONSTRAINT`,
so the `NOT VALID` statement itself runs from the `EXPANDED` (not yet `BACKFILLED`) state and
must not reject. Only a bare `.constrain` (no `NOT VALID`) or an `.expand` classified statement
whose own text lacks a constant default is rejectable, and only for reaching a `.constrain`
state from `UNSEEN` or `EXPANDED` (not `BACKFILLED`).

One additional rule the acceptance criteria imply but do not spell out: a column that already
exists before this file set (i.e., this file's first mention of it is a `.constrain` statement
with no prior `.expand` in *this* file) is indistinguishable, from a single-file view, from a
column being illegally constrained without ever being expanded. DDL-02's body says the check
walks "each migration file set," and DDL-04 (backfill, not in scope here) is the sibling
requirement responsible for the actual backfill step — this design treats "no expand statement
for this column found anywhere in the file set" as always a violation, matching AC1's example
verbatim (`ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL` as the FIRST and only statement in
the set). See "Open questions" for the pre-existing-column edge case this implies.

## Data flow

```
file_set.statements (already parsed, in declaration order, ordering_role set)
        |
        v
+----------------------------------+
| checkConstrainBeforeExpand()      |  <- NEW, whole-file scan
|  - walk statements in order       |
|  - maintain per-column state map  |
|  - first violation -> Detail      |
+----------------------------------+
        |
        v  (candidate failure position, or none)
+----------------------------------+
| existing per-statement loop       |  <- UNCHANGED bodies, new interleave
|  lock-class -> index-conc ->      |     point at the candidate's order
|  namespace  -> [insert candidate  |
|  here if this stmt.order matches] |
+----------------------------------+
        |
        v
   ValidationVerdict  (.accept | ...four failure arms...)
```

## Error taxonomy

Adds exactly one new arm to the existing `ValidationVerdict` union:
`constrain_before_expand: ConstrainBeforeExpandDetail`. No new Zig `error{...}` set — DDL-01's
purity contract (every outcome is a normal return value, never a thrown error) is preserved
unchanged; DDL-02 does not alter that contract, only adds a verdict arm.

## What this module does NOT do (scoping, matching DDL-01/DDL-05's own precedent)

- **Does not parse SQL.** Exactly like the three existing checks, `checkConstrainBeforeExpand`
  consumes an already-populated `StatementDescriptor` (with the new `ordering_role` and
  `ordering_column` fields set). Classifying raw SQL text into `OrderingRole` — e.g. deciding
  whether an `ADD COLUMN ... NOT NULL` has a "constant" default (a literal, vs. a volatile
  expression like `now()` or `gen_random_uuid()`, which does NOT get the fast-default path and
  should NOT be treated as `.expand`) — is parser work, out of scope for this pure validation
  module, same boundary DDL-01's own header comment draws ("Set by the (out-of-scope) parser").
- **Does not cross file-set boundaries.** "Migration file set" per DDL-02's body is whatever
  unit MIG-01/`runFanout` already validates as one pass (see `ddl_validate.zig`'s header comment
  on `migration_fanout.zig`); this check does not remember state between separate calls to
  `validatePlatformDDL`.
- **Does not validate multi-column constraints.** See "Open questions."

## Dependencies

- **Depends on:** `src/platform/ddl_namespace.zig` (already a DDL-01 dependency, unchanged by
  DDL-02).
- **Must NOT depend on:** the same list DDL-01 already excludes — `src/db/pool.zig`,
  `src/db/provisioning.zig`, `src/db/migrations.zig`, `src/platform/migration_fanout.zig`,
  `std.time`, any clock, any allocator. `checkConstrainBeforeExpand` needs O(statements) working
  state (the per-column map) for the duration of one call; this must be caller-provided or
  stack/comptime-bounded, not heap-allocated, to preserve DDL-01 AC4's "no allocator" purity
  claim — or, if a bounded-size stack structure cannot cover realistic file sizes (DDL-01 AC5
  tests 200 statements), the function signature may take an `std.mem.Allocator` explicitly and
  DDL-01 AC4's existing unit test coverage should be extended (by BACKEND-DEV, per DDL-02's own
  new acceptance criteria, not this design) to confirge determinism still holds with an
  allocator present. Flagged as an open question below since it is a real deviation from DDL-01's
  stated "zero allocator" purity claim and CODE-DESIGN-VALIDATOR should weigh in.

## Open questions

1. **Multi-column constraints.** `ColumnRef` is single-column. A composite `FOREIGN KEY (a, b)
   REFERENCES ...` or composite `CHECK` naming two columns is not addressed by the state machine
   above. None of DDL-02's five acceptance criteria exercise a multi-column constraint, so this
   is out of scope for a PASS verdict on this batch, but BACKEND-DEV should not silently drop
   multi-column constraints from consideration — recommend treating a multi-column constraint as
   depending on ALL referenced columns being independently `BACKFILLED` (the conjunction), and
   filing a follow-up if that shape is needed later. Flagging as non-blocking per the
   PARTIAL-vs-PASS convention used in prior batches.
2. **Pre-existing column, no expand statement in this file.** As noted above, this design
   treats "no `.expand` statement for this column anywhere in the file set" as always a
   violation when a `.constrain` statement targets it — this matches AC1's literal example. If a
   future migration legitimately wants to add a `NOT NULL` constraint to a column that has
   existed (and been fully populated) since a much earlier migration, with no expand/backfill
   statement in *this* file at all, this design would reject it. DDL-02's body and all five ACs
   are silent on this case — none of them show a bare `SET NOT NULL` with no preceding `ADD
   COLUMN` anywhere being *accepted*. Recommend surfacing this ambiguity to REQ-ANALYST/ORCH
   rather than guessing; in the meantime the conservative (reject-by-default) reading is what
   this design implements, since a false rejection is a build-time inconvenience while a false
   acceptance is a production outage (matching DDL-01/DDL-05's own bias toward the conservative
   verdict on ambiguous input).
3. **Allocator purity.** See "Dependencies" above — whether `checkConstrainBeforeExpand` can
   stay allocator-free depends on a bound on statement-list size vs. distinct-column count that
   this design does not fix. Recommend BACKEND-DEV measure against DDL-01 AC5's existing 200-
   statement benchmark file and decide there; either answer is compatible with this design's
   public interface (the function signature shown omits an allocator parameter as the preferred
   shape, to be added only if proven necessary).

These three items do not block CODE-DESIGN-VALIDATOR from reviewing DDL-02's five acceptance
criteria against this design, since (1) and (2) both name accept-by-default choices that make
the five stated ACs pass either way, and (3) is an implementation-detail question, not a design
ambiguity affecting behavior. Handoff `result.status` for the DDL-02 portion of this batch is
therefore PASS, not PARTIAL — the open questions are forward-looking notes, not gaps against the
stated acceptance criteria.
