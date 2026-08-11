# Module: par-04-attach-scan-required-check

**Requirement ID:** PAR-04
**Run ID:** WF02-batch-3-20260811 (Stage 16)
**Covers:** PAR-04
**Extends:** PAR-01 (the partitioned tables this check attaches partitions to), PAR-02
(constraints declared at creation time — this module supplies the check PAR-02's creation loop
calls before every `ATTACH PARTITION`), PAR-03 (the archival attach depends on this same check),
DDL-01 (this module does NOT replace or compose `ValidatePlatformDDL` — see Scoping note)
**See also (not implemented here):** PAR-02 (proactive creation job — separate design, calls into
this module), PAR-03 (retention DETACH/ATTACH — separate design, calls into this module)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table is added by this piece in isolation (it reads/validates the shape of
   partitions PAR-01/PAR-02 already create; it does not itself issue `CREATE TABLE`).
2. **Type A / Type D / Type B?** No HTTP route, no React Flow node, no admin page.
3. **Type E — yes.** A pure verification predicate over a standalone table's declared
   constraints, plus the operational rule ("refuse the attach, don't let Postgres silently take
   the slow path") that PAR-02's and PAR-03's attach call sites must both honor before ever
   issuing `ATTACH PARTITION`. This is exactly the "small Type E piece" shape the handoff
   anticipated for PAR-04, matching the `ddl_namespace.zig`/`ddl_validate.zig` precedent
   (batch-0/batch-1) for a focused, single-purpose pure-predicate module.

## Scoping note — this is NOT DDL-01/DDL-02

`src/platform/ddl_validate.zig` (DDL-01) validates **migration file statement lists** ahead of
`MIG-01`'s tenant fanout — a static, pre-flight, file-linting concern that runs once per
migration file, before any connection opens. PAR-04's `AttachScanRequired` check is a
**live-schema, runtime** concern: given an already-existing standalone table (about to be
attached as a partition) and the range bounds the caller intends to attach it with, does that
table ALREADY carry both required CHECK constraints? This is answered by querying the `pg_constraint`
system catalog (joined to `pg_class`/`pg_namespace`, scoped to the target schema per
`docs/anti-patterns.md`'s schema-agnostic-catalog-query entry) against the live database at the
moment PAR-02's creation loop or PAR-03's archival-attach logic is about to run `ATTACH PARTITION` — it
has nothing to do with parsing or classifying SQL statement text, and it is not a check DDL-01's
`ValidatePlatformDDL` pipeline should absorb (that pipeline is pure/no-DB by DDL-01 AC4; this
check is inherently DB-bound, since "does this specific already-created table carry this
specific CHECK" cannot be answered without querying the catalog). Do not attempt to fold this
into `ddl_validate.zig` or `ddl_namespace.zig` — they solve a different problem at a different
stage of the pipeline.

## Module purpose

`src/db/partition_attach.zig` (new file) provides a single function,
`verifyAttachConstraints()`, that PAR-02's partition-creation loop and PAR-03's archival-attach
logic both call immediately before issuing `ALTER TABLE ... ATTACH PARTITION ...`. It queries the
standalone candidate table's declared CHECK constraints and confirms both required constraints
are present and, for the range CHECK, that its bounds exactly match the range the caller is about
to attach with. If either is missing, or the range CHECK's bounds do not match, the function
returns `AttachScanRequired` and the caller MUST NOT issue the `ATTACH PARTITION` statement —
PAR-04's body is explicit that attaching without both constraints causes PostgreSQL to scan the
partition under a stronger lock (`ACCESS EXCLUSIVE` instead of `SHARE UPDATE EXCLUSIVE`), which
this platform treats as an operational failure to prevent, not merely tolerate slowly.

The two required constraints, per PAR-04's body:

1. `CHECK (tenant_id IS NOT NULL)` — same literal constraint on every partition, tenant-scoping
   invariant enforced per-partition (PAR-04 AC4).
2. A range CHECK matching the `FOR VALUES FROM ... TO ...` bounds the attach will use exactly
   (PAR-04's final AC: "a mismatch is detected and rejected before the statement is issued").

## Data flow diagram

```
PAR-02 creation loop / PAR-03 archival-attach logic
        |
        |  (about to attach candidate_table for range [range_start, range_end))
        v
verifyAttachConstraints(conn, candidate_table, range_start, range_end)
        |
        |-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
        |     WHERE conrelid = candidate_table::regclass AND contype = 'c'
        v
        +-- tenant_id CHECK present?  -----no----> return .attach_scan_required
        |          | yes
        |          v
        +-- range CHECK present AND bounds == [range_start, range_end)? --no--> return .attach_scan_required
                   | yes
                   v
        return .ok
                   |
                   v
        caller issues ALTER TABLE ... ATTACH PARTITION ... FOR VALUES FROM (...) TO (...)
                   |
                   v
        caller measures wall-clock duration of the ATTACH statement (PAR-04 AC1/AC3)
                   |
                   v
        duration > 1s?  --yes--> caller ALSO reports AttachScanRequired retroactively
                   |                (PAR-04's third AC: an attach that takes >1s is itself
                   |  no             evidence of a missed/mismatched constraint, even if
                   v                 verifyAttachConstraints() said .ok — see Error taxonomy)
        attach accepted; EXECUTION_PARTITION_CREATED / EXECUTION_PARTITION_DETACHED appended
        (by PAR-02/PAR-03's own logic, not this module)
```

## Public interface

```zig
const std = @import("std");
const db = @import("pool");

/// A partition's intended range bounds, half-open [start, end).
pub const PartitionRange = struct {
    start: i64,   // UTC microseconds since epoch, matching store.zig's created_at_us convention
    end: i64,
};

pub const AttachVerdict = union(enum) {
    ok,
    attach_scan_required: AttachScanRequiredDetail,
};

pub const AttachScanRequiredDetail = struct {
    table_name: []const u8,
    missing_tenant_check: bool,
    missing_or_mismatched_range_check: bool,
    /// Present only when a range CHECK exists but does not match `range` —
    /// distinguishes "no range CHECK at all" from "range CHECK present but wrong bounds",
    /// both of which PAR-04's body treats as AttachScanRequired, but the caller's error
    /// message benefits from knowing which.
    found_range_check_def: ?[]const u8,
};

pub const PartitionAttachError = error{
    PoolExhausted,
    QueryFailed,
    /// candidate_table does not exist in the catalog at all.
    TableNotFound,
};
```

Functions (split into a second block to keep each fenced block under the 40-line design-sketch
cap — same file, same module, continued):

```zig
/// Query candidate_table's declared CHECK constraints and verify both PAR-04-required
/// constraints are present and correct BEFORE the caller issues ATTACH PARTITION.
/// Does not itself run ATTACH PARTITION — the caller does that only after receiving .ok.
pub fn verifyAttachConstraints(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    candidate_table: []const u8,
    range: PartitionRange,
) PartitionAttachError!AttachVerdict;

/// Wraps a single ATTACH PARTITION statement with a wall-clock timer and reinterprets
/// an over-budget duration as AttachScanRequired even when verifyAttachConstraints()
/// returned .ok immediately before — PAR-04's AC3 ("an attach exceeds 1 s ... reported
/// as AttachScanRequired, since only a missing matching constraint causes the scan").
/// Callers (PAR-02, PAR-03) MUST use this wrapper rather than issuing the raw ALTER TABLE
/// statement directly, so the 1s observation is applied uniformly rather than
/// reimplemented per call site.
pub fn attachPartitionTimed(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    parent_table: []const u8,
    partition_table: []const u8,
    range: PartitionRange,
) PartitionAttachError!AttachVerdict;
```

`attachPartitionTimed()` is the actual call site PAR-02/PAR-03 use; `verifyAttachConstraints()` is
exposed separately so a caller that wants to pre-validate a batch of candidate partitions before
attaching any of them (PAR-02's daily loop, which may create/attach several months at once on
first run) can do so without paying the ATTACH statement's own side effects for each check.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `attach_scan_required` (missing `tenant_id` CHECK) | Candidate table has no `CHECK (tenant_id IS NOT NULL)` | `AttachVerdict.attach_scan_required` with `missing_tenant_check = true`; caller refuses the attach (PAR-04 AC2) |
| `attach_scan_required` (missing or mismatched range CHECK) | Candidate table has no range CHECK, or one whose bounds differ from `range` | `AttachVerdict.attach_scan_required` with `missing_or_mismatched_range_check = true`, `found_range_check_def` populated if a CHECK existed but didn't match |
| `attach_scan_required` (retroactive, post-attach timing) | `attachPartitionTimed()` measures the actual `ATTACH PARTITION` statement taking longer than 1s even though `verifyAttachConstraints()` returned `.ok` | Same `AttachVerdict.attach_scan_required` variant, both `missing_*` fields false — this is the "matching constraints were declared but the observed duration still indicates a scan happened" case (PAR-04 AC3's literal wording: duration alone is sufficient evidence, independent of what the pre-check found) — see Open questions §1 for how a caller distinguishes this from the pre-check case in its own error message |
| `PartitionAttachError.TableNotFound` | `candidate_table` does not exist in the catalog | Caller (PAR-02/PAR-03) treats as its own precondition failure — this should not occur in practice since both callers create the candidate table themselves immediately before calling this function |
| `PartitionAttachError.QueryFailed` / `PoolExhausted` | Catalog query itself fails (connection issue, pool exhaustion) | Propagated to caller; PAR-02/PAR-03 treat identically to any other DB error in their own maintenance-job error handling |

## State transitions

Not applicable — this module is a pure verification predicate plus a thin timing wrapper around
a single DDL statement; it holds no state of its own between calls. (`plat_partition_catalog`,
the per-partition state tracker referenced by the process document
`docs/processes/system/event-log-partitioning.md`'s Outputs section, is PAR-02's concern — see
that design for `ORPHAN_PARTITION`/attached-state tracking.)

## Dependencies

- Depends on: `src/db/pool.zig` (`Conn`, `PoolExhausted`) — same connection-acquisition pattern
  every other store module in this codebase uses.
- Called by: PAR-02's `plat_partition_maintenance` creation loop (before every `ATTACH
  PARTITION` for a newly created future partition) and PAR-03's archival-attach logic (before
  the `ATTACH PARTITION ... TO events_archive` step of a DETACH/ATTACH retention cycle).
- Must NOT depend on: `src/platform/ddl_validate.zig` / `ddl_namespace.zig` (different pipeline
  stage, see Scoping note), `src/scheduler/scheduler.zig` (this module has no timer-polling
  concerns of its own — it is called synchronously from within PAR-02/PAR-03's own job logic).

## Open questions

1. **Distinguishing pre-check vs. post-attach-timing `AttachScanRequired` in caller-facing error
   messages.** `AttachScanRequiredDetail` carries `missing_tenant_check`/
   `missing_or_mismatched_range_check` booleans that are both `false` in the retroactive
   (post-timing) case — a caller inspecting only those two fields cannot tell "the constraints
   were fine but the attach was still slow" apart from "somehow got here with both false and no
   timing issue either" (which should be unreachable, but the type doesn't make it structurally
   impossible). Recommend BACKEND-DEV add a third field (e.g. `observed_duration_ms: ?u64`,
   populated only in the `attachPartitionTimed()` retroactive path) when implementing, so the two
   cases are distinguishable without relying on "both false" as an implicit sentinel. Left open
   rather than dictated here since it's a minor implementation-ergonomics choice, not a schema or
   behavior decision.
2. **1-second budget measurement clock.** PAR-04 AC1/AC3 require observing whether the `ATTACH
   PARTITION` statement itself took under/over budget. This codebase's existing wall-clock timer
   precedent (`src/platform/ddl_validate.zig`'s `testTimeNanos()`, used ONLY in that file's own
   tests, explicitly not in the module under test) shows Zig 0.16 removed `std.time.Timer` from
   the public API on this platform. `attachPartitionTimed()` needs its own equivalent — BACKEND-DEV
   should reuse whichever of the existing per-platform reimplementations
   (`src/api/routes/instances.zig`'s `currentMicrosecondTimestamp`, `src/expr/benchmark.zig`'s
   `getTimeNanos`, or `ddl_validate.zig`'s test-only `testTimeNanos`) is already exposed as an
   importable helper rather than writing a fourth copy — this design intentionally does not
   pick one, since that is a code-reuse judgment call for implementation, not a design decision.
