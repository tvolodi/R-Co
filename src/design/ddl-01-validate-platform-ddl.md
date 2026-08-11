# Module: ddl-01-validate-platform-ddl

**Requirement ID:** DDL-01
**Run ID:** WF02-batch-1-20260811 (Stage 16)
**Covers:** DDL-01
**Extends:** MIG-01 (adds a pre-flight gate ahead of the tenant fanout), DDL-05 (composes
`checkNamespace` as one of its checks — see Scoping note)
**See also (not implemented here):** DDL-02 (ordering check — same validating pass, same
`ValidatePlatformDDL` entry point, but its own later requirement; this design leaves the
seam DDL-02 will fill, see Open questions), DDL-03 (the accepted three-phase rewrite for a
type change, referenced only as "the accepted route" in DDL-01 AC3), MIG-02/MIG-03 (the
fanout `ValidatePlatformDDL` gates ahead of)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added, altered, or removed by this piece. (DDL-01 AC6
   writes to `plat_migration_plan` and appends `EXECUTION_MIGRATION_VALIDATED` to the event
   log — both write to already-existing tables/mechanisms per the requirement text; no new
   schema object is introduced here. See Open questions §1 for the one thing that needs
   confirming before BACKEND-DEV writes that call.)
2. **Type A?** No HTTP route is added by this piece in isolation. `ValidatePlatformDDL` is a
   pure function called from the migration-plan CLI path (`zig build migrate` / the platform
   migration runner), not a request handler.
3. **Type D?** No React Flow node.
4. **Type B?** No admin/list page.
5. **Type E — yes.** A pure, multi-check aggregation pipeline over parsed statement
   descriptors — exactly the kind of validation logic `templates/lego-catalog.md` reserves for
   Type E, and the same classification batch-0 already gave DDL-05, the one check this module
   composes.

## Scoping note — read this before extending

DDL-01's body says `ValidatePlatformDDL` is "a pure function over parsed statement
descriptors" that rejects unbounded-exclusive-lock statement classes and non-`CONCURRENTLY`
index builds, and that DDL-05's namespace check "runs inside `ValidatePlatformDDL` in the same
pass as the lock-class and ordering checks." This design produces the aggregation entry point
itself — the pipeline that composes DDL-05's `checkNamespace` (already implemented,
`src/platform/ddl_namespace.zig`) alongside two NEW checks this batch adds (lock-class,
non-concurrent-index). It does **not** implement:

- **DDL-02's ordering check** (constrain-before-expand) — a separate, later requirement. This
  design defines the `Check` shape so DDL-02 can register a fourth check into the same
  pipeline without changing `ValidatePlatformDDL`'s signature (see Open questions §2).
- **DDL-03's three-phase rewrite generator** — referenced only as "the accepted route" DDL-01
  AC3's failure message points callers toward; this module never rewrites a statement, it only
  accepts or rejects it.
- **The statement parser** that turns raw SQL text into `StatementDescriptor` values — DDL-01's
  AC1 example (`ALTER TABLE events DROP COLUMN legacy_flag`) implies a parser exists somewhere
  upstream of this pipeline, but parsing free-form SQL into a structured descriptor is a
  distinct concern from validating an already-parsed descriptor. See Open questions §1.

This design MUST call `ddl_namespace.checkNamespace` rather than re-deriving the `plat_` prefix
rule — that is DDL-01 AC set item covered entirely by composition, per the batch-0 design's own
scoping note ("DDL-01's design MUST call into this module rather than re-deriving the prefix
check").

## Module purpose

`src/platform/ddl_validate.zig` decides, for an entire migration file's parsed statement list,
whether every statement is safe to run against a live tenant schema without holding an
`ACCESS EXCLUSIVE` lock for a duration proportional to table size, and whether every object
name in the file respects the `plat_` reserved-namespace rule. It is the single pre-flight gate
MIG-01's fanout (`runFanout` in `src/platform/migration_fanout.zig`) must pass through before
opening a connection to any tenant schema — DDL-01's body states validation "SHALL complete
before the fanout of MIG-01 opens a connection to any tenant schema, so a rejected file set
touches zero schemas."

The module has three responsibilities, run as three independent checks over the same statement
list, aggregated into one verdict:

- **Lock-class check (new in this batch):** reject statements whose lock class is
  `ACCESS EXCLUSIVE` held for a duration proportional to table size — `DROP COLUMN`, `CLUSTER`,
  `VACUUM FULL`, `REINDEX` without `CONCURRENTLY`, and `ALTER COLUMN ... SET DATA TYPE` — with
  verdict `UnboundedExclusiveLock`.
- **Concurrent-index check (new in this batch):** reject `CREATE INDEX`/`DROP INDEX` statements
  written without `CONCURRENTLY`, with verdict `NonConcurrentIndexBuild`.
- **Namespace check (composed from DDL-05):** delegate to `ddl_namespace.checkNamespace` for
  every `create`/`rename_to`/`alter` statement targeting a named object, folding its
  `NamespaceVerdict` into this module's own verdict type.

Per DDL-01's body and matching DDL-05's already-established purity constraint:
`ValidatePlatformDDL` holds no database handle, opens no connection, reads no clock, and reads
no environment variable. DDL-01 AC4 makes this an explicit, testable acceptance criterion: the
same verdict must be returned whether or not a database is reachable.

## Public interface

Statement shape. A superset of DDL-05's `StatementDescriptor` — DDL-05's own doc says "DDL-01's
future statement-descriptor type is expected to be a superset of this shape," so this type
embeds exactly what `ddl_namespace.zig` needs (`kind`, `object_name`, `previous_object_name`)
plus the additional fields the lock-class and index checks need:

```zig
const ddl_namespace = @import("ddl_namespace.zig");

/// Statement classification the lock-class check switches on. Distinct from
/// ddl_namespace.StatementKind (create/rename_to/alter), which is about
/// *namespace* ownership, not *lock* behavior — a single physical SQL
/// statement (e.g. an ALTER TABLE) maps to exactly one StatementKind for
/// namespace purposes but may need a separate, finer StatementClass to
/// decide its lock behavior (e.g. "is this ALTER a SET DATA TYPE, a DROP
/// COLUMN, or something else entirely"). Kept as a SEPARATE field on
/// StatementDescriptor rather than widening ddl_namespace.StatementKind, so
/// DDL-05's module and its already-shipped tests are untouched by this
/// batch — see Dependencies.
pub const StatementClass = enum {
    drop_column,
    cluster,
    vacuum_full,
    reindex_concurrent,
    reindex_non_concurrent,
    alter_column_set_data_type,
    create_index_concurrent,
    create_index_non_concurrent,
    drop_index_concurrent,
    drop_index_non_concurrent,
    other,
};
```

The full statement descriptor and the file-set wrapper `validatePlatformDDL` takes as input:

```zig
pub const StatementDescriptor = struct {
    /// Namespace-check shape, reused verbatim so checkNamespace can be
    /// called with zero field-by-field translation.
    kind: ddl_namespace.StatementKind,
    object_name: []const u8,
    previous_object_name: ?[]const u8 = null,

    /// Lock-class / index-concurrency shape, read only by this module's own
    /// checks, never by ddl_namespace.checkNamespace.
    class: StatementClass,

    /// 1-based position of this statement within its file's statement list —
    /// AC5's "first failure in statement order" needs a stable order key,
    /// and re-deriving order from array index alone would silently break if
    /// a caller ever passes a filtered/reordered slice. Explicit field, set
    /// by the (out-of-scope) parser.
    order: u32,

    /// Raw statement text, exactly as written, for the failure detail DDL-01
    /// AC6 persists to plat_migration_plan and DDL-01 AC1/AC2/AC3's "naming
    /// that statement" wording.
    text: []const u8,
};

pub const FileSet = struct {
    /// Statements across the whole file (or file set) being validated, in
    /// declaration order. This module does not itself sort by `order` — the
    /// caller (the future parser / migration-plan CLI) is expected to
    /// supply the slice already in file order, and `order` exists so the
    /// verdict can name a position independent of slice indexing games by
    /// an adversarial or buggy caller. See Dependencies.
    statements: []const StatementDescriptor,
    actor: ddl_namespace.Actor,
};
```

Verdict types — one verdict per file set, naming the single first-failing statement (AC5):

```zig
pub const UnboundedExclusiveLockDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    class: StatementClass,
};

pub const NonConcurrentIndexBuildDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
};

/// Re-exports of ddl_namespace's detail shapes plus the failing statement's
/// order/text, since ddl_namespace.NamespaceVerdict alone carries only
/// object_name (it has no concept of "position in a file" — that is a
/// DDL-01-level concern layered on top).
pub const ReservedNamespaceDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

pub const UnreservedPlatformObjectDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

pub const ValidationVerdict = union(enum) {
    accept,
    unbounded_exclusive_lock: UnboundedExclusiveLockDetail,
    non_concurrent_index_build: NonConcurrentIndexBuildDetail,
    reserved_namespace: ReservedNamespaceDetail,
    unreserved_platform_object: UnreservedPlatformObjectDetail,
};
```

Entry point — pure, no `error{...}` set, matching DDL-05's reasoning (a classifier that can
answer every input has no failure mode of its own; AC4 requires the same verdict with or
without a reachable database, which a fallible signature would muddy):

```zig
/// Validates every statement in `file_set.statements`, in `order`, against
/// three checks (lock-class, index-concurrency, namespace) and returns the
/// FIRST failing verdict in statement order (AC5), or .accept if every
/// statement passes every check. Pure: no allocator, no I/O, no clock, no
/// env var — DDL-01's stated purity constraint, and AC4's testable
/// consequence of it.
pub fn validatePlatformDDL(file_set: FileSet) ValidationVerdict;
```

No allocator parameter: every field the verdict types carry is a borrowed slice from the
caller-supplied `StatementDescriptor`s (`statement_text`, `object_name`), matching
`ddl_namespace.checkNamespace`'s existing convention of returning verdicts built entirely from
borrowed input slices with zero heap allocation.

## Data flow

```
                    Migration file set (already parsed upstream —
                    out of scope; see Open questions §1)
                                 │
                                 ▼
                  FileSet{ statements: []StatementDescriptor,
                            actor: Actor }
                                 │
                                 ▼
                  validatePlatformDDL(file_set)
                                 │
          for stmt in file_set.statements, ordered by stmt.order:
                                 │
              ┌──────────────────┼───────────────────┐
              ▼                  ▼                    ▼
     lock-class check   index-concurrency check   ddl_namespace.checkNamespace(
     (this module,        (this module,             file_set.actor,
      new)                  new)                     StatementDescriptor{
              │                  │                      kind: stmt.kind,
              │                  │                      object_name: stmt.object_name,
              │                  │                      previous_object_name:
              │                  │                        stmt.previous_object_name,
              │                  │                   })
              └──────────────────┴───────────────────┘
                                 │
                    first check to report a non-accept
                    verdict for this statement, in the
                    fixed order [lock-class, index-concurrency,
                    namespace] — see "Within-statement check
                    order" below
                                 │
                    ┌────────────┴─────────────┐
                    ▼                            ▼
              some statement fails         every statement's every
              a check                       check returns accept
                    │                            │
                    ▼                            ▼
       return that verdict IMMEDIATELY      return .accept
       (first failure in statement order,
        AC5) — no later statement is
        even inspected
```

**Within-statement check order.** DDL-01 AC5 only specifies ordering ACROSS statements ("the
first failure in statement order is reported"); it says nothing about which of the THREE checks
wins when a single statement fails more than one simultaneously (e.g. a tenant-authored
`CREATE INDEX plat_idx ON t (c)` without `CONCURRENTLY` is both `NonConcurrentIndexBuild` and,
if `plat_idx` under `Actor.tenant`, `ReservedNamespace`). This design picks a fixed,
deterministic order — **lock-class, then index-concurrency, then namespace** — so the same
input always produces the same verdict (required by AC4's determinism guarantee) even though
the requirement text does not state which check "wins" a same-statement tie. Documented here as
the authoritative tie-break rule rather than left as an implementation accident; flagged in Open
questions §3 for REQ-ANALYST to confirm no business reason favors a different order.

## Error taxonomy

`validatePlatformDDL` raises no Zig `error{...}` set — same reasoning as `ddl_namespace.zig`:
every outcome, including all four rejection cases, is a normal return value
(`ValidationVerdict`), never a thrown error. This is required by DDL-01 AC4 ("the call succeeds
and returns the same verdict... with no database reachable") — a fallible signature would let a
future caller conflate "the validator detected a problem" with "the validator itself failed,"
which are different concerns (the second would be a caller bug: an empty `FileSet.statements`
slice is not an error, it validates to `.accept` trivially).

| Verdict | When | Corresponds to |
|---|---|---|
| `.accept` | No statement in `file_set.statements` fails any of the three checks. | Implicit "no AC fires" baseline. |
| `.unbounded_exclusive_lock` | The first (in `order`) statement whose `class` is one of `drop_column`, `cluster`, `vacuum_full`, `reindex_non_concurrent`, `alter_column_set_data_type`. | DDL-01 AC1 (`DROP COLUMN`), AC3 (`ALTER COLUMN ... SET DATA TYPE`) |
| `.non_concurrent_index_build` | The first statement (that did not already fail the lock-class check) whose `class` is `create_index_non_concurrent` or `drop_index_non_concurrent`. | DDL-01 AC2 |
| `.reserved_namespace` | The first statement (that did not already fail lock-class or index-concurrency) for which `ddl_namespace.checkNamespace` returns `.reserved_namespace`. | DDL-05 AC1/AC2, composed |
| `.unreserved_platform_object` | The first statement (that did not already fail lock-class or index-concurrency) for which `ddl_namespace.checkNamespace` returns `.unreserved_platform_object`. | DDL-05 AC3, composed |

DDL-01 AC1's "the plan exits with status 2" and AC1/AC2's "the file set is REJECTED" describe
the CALLER's response to a non-accept verdict (the migration-plan CLI translating a verdict into
a process exit code), not this module's own behavior — same layering `ddl_namespace.zig`
already establishes for its own two rejection verdicts (no HTTP mapping lives in the pure
checker).

## State transitions

Not applicable — `validatePlatformDDL` is a single pure call with no persisted state, mirroring
`ddl_namespace.checkNamespace`. AC6's write to `plat_migration_plan` and the event log append
are the CALLER's responsibility (see Dependencies and Open questions §1) — this module returns
a verdict value and nothing more; it does not itself touch a database, matching its stated
purity constraint.

## Dependencies

**Calls into:**
- `src/platform/ddl_namespace.zig::checkNamespace` — the namespace check, composed exactly as
  DDL-05's design doc requires ("DDL-01's design MUST call into this module rather than
  re-deriving the prefix check"). This module builds a `ddl_namespace.StatementDescriptor` from
  the relevant subset of its own richer `StatementDescriptor` on every call (three fields:
  `kind`, `object_name`, `previous_object_name` — a simple field projection, not a
  transformation) rather than importing `ddl_namespace.RESERVED_PREFIX` or re-checking the
  prefix itself.
- Nothing else. Like `ddl_namespace.zig`, this is a leaf function with respect to the database —
  no `src/db/*` import, no allocator.

**Must NOT depend on:**
- `src/db/pool.zig`, `src/db/provisioning.zig`, `src/db/migrations.zig`, `src/platform/migration_fanout.zig`,
  or any connection-opening module — DDL-01's body: "Validation SHALL complete before the
  fanout of MIG-01 opens a connection to any tenant schema." A dependency in this direction
  (this module importing the fanout module) would also invert the intended call graph: MIG-01's
  future migration-plan CLI is expected to call `validatePlatformDDL` BEFORE ever calling
  `runFanout`, not the reverse; `migration_fanout.zig` does not import this module and this
  design does not change that (`runFanout`'s own `DdlStep` seam is where a caller wires
  validated DDL in — see `migration_fanout.zig`'s design doc's Open Question 1, still open).
- `std.time` or any clock — same reasoning as `ddl_namespace.zig`: AC4 requires determinism
  regardless of when the check runs.
- Any DDL-02/DDL-03 type that does not yet exist. This design deliberately leaves DDL-02's
  ordering check UNWIRED (see Scoping note and Open questions §2) rather than speculatively
  importing a module that has no design yet.
- `src/api/*` — this is not an HTTP-facing module; nothing here maps a verdict to a status code
  or Problem Details body. (Contrast with MIG-06, this batch's admin surface, which is
  HTTP-facing and does own that mapping for run/status/resume — but MIG-06 does not call this
  module directly either; MIG-06 gates on `runFanout`, which is gated ahead of time by whatever
  future migration-plan CLI calls `validatePlatformDDL` once, at plan time, not per-request.)

**Who resolves `Actor`:** out of scope for this module, matching `ddl_namespace.zig`'s existing
answer verbatim — `validatePlatformDDL` trusts `file_set.actor` exactly as `checkNamespace`
trusts its own `actor` parameter; this module does not inspect auth tokens, RBAC roles, or
session state.

**Who builds `FileSet.statements`:** out of scope for this batch (see Open questions §1) — a
SQL-statement parser producing `StatementDescriptor` values, including their `class` and
`order` fields, from raw migration file text. `validatePlatformDDL` assumes this input already
exists and is correctly classified; a parser bug that mis-classifies a statement's `class` is a
parser defect, not a `validatePlatformDDL` defect (same "trusts its caller" boundary the
Actor-resolution paragraph states for `ddl_namespace.zig`).

## Open questions

1. **Where does the statement parser and the `plat_migration_plan`/event-log write (AC6) live?**
   DDL-01's five acceptance criteria describe `ValidatePlatformDDL` as operating over "parsed
   statement descriptors" and its own examples are raw SQL text (`ALTER TABLE events DROP
   COLUMN legacy_flag`) — implying a SQL-to-`StatementDescriptor` parser exists somewhere, and
   that AC6's persistence ("written to `plat_migration_plan`," "`EXECUTION_MIGRATION_VALIDATED`
   appended to the event log") is done by whatever CALLS `validatePlatformDDL`, not by this pure
   function itself (a persistence side effect inside a function DDL-01's own body requires to be
   database-handle-free would be a contradiction). This design is fully specified either way —
   `validatePlatformDDL`'s contract does not change — but BACKEND-DEV needs a decision on
   whether the parser and the AC6 persistence call are (a) in scope for this same batch as a
   sibling module (e.g. `src/platform/ddl_parse.zig` + a caller in the migration-plan CLI), or
   (b) deferred to a follow-up once DDL-02/DDL-03 exist and there is a natural single call site
   that runs the full validating pass once. Recommend ORCH/REQ-ANALYST confirm scope for
   BACKEND-DEV's handoff. Not blocking this handoff's PASS status: DDL-01's own acceptance
   criteria (AC1–AC5) are about `ValidatePlatformDDL`'s verdict behavior, which this design fully
   specifies; AC6 is the one criterion whose *caller-side* wiring is left open.

2. **DDL-02's ordering check seam.** This design's `Check`-per-statement model (three checks run
   per statement, first non-accept wins) is written so a future DDL-02 ordering check — which is
   inherently CROSS-statement (it must compare a constraining statement against an earlier
   expand/backfill statement, not judge one statement in isolation) — can be added as a fourth
   pass over the same `FileSet.statements` without changing `validatePlatformDDL`'s signature.
   This design does not specify DDL-02's own check function, only notes the seam exists. Not
   blocking: DDL-02 is an explicitly separate, later requirement, and this open question is
   forward-looking, not a gap in DDL-01's own five ACs.

3. **Within-statement check tie-break order.** As stated in Data flow, this design picks
   lock-class → index-concurrency → namespace as the fixed order when a single statement fails
   more than one check simultaneously, since DDL-01's text specifies cross-statement order (AC5)
   but not within-statement check priority. This is a genuine but narrow ambiguity — the
   determinism requirement (AC4) forces SOME fixed order to exist, but the requirement text does
   not say which. Flagged for REQ-ANALYST/CODE-DESIGN-VALIDATOR to confirm no business reason
   (e.g. "always report the namespace violation first, since it is a security/ownership concern
   distinct from the performance concern the other two checks share") favors a different order
   before BACKEND-DEV implements. Not blocking this handoff's PASS status: every one of DDL-01's
   five worked-example ACs involves exactly one check failing per statement, so no AC's expected
   verdict depends on which tie-break order is chosen; this is prospective correctness for
   inputs the stated ACs do not exercise, not a gap in AC coverage itself.
