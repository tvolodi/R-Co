# Test Spec: PAR-03 — Partition-scoped retention and archival

**Requirement:** PAR-03 — Extends ADP-11, giving the deletion prohibition a physical retention
mechanism. Retention SHALL be partition-scoped: an `events` partition older than
`archive_after_months` (default 13) SHALL be aged out by `DETACH PARTITION CONCURRENTLY` +
`ATTACH PARTITION` to `events_archive` (no row copy). Hard deletion by `DROP TABLE` SHALL be
confined to partitions of `events_ephemeral`, which holds only event types whose retention class
is `delete`. No `DELETE` statement SHALL run against `events` or `events_archive` at any point.
**Priority:** MUST
**Test layer:** unit (pure config/guard-SQL shape) + integration (real DETACH/ATTACH/DROP cycles
against PostgreSQL)

**Test-tier score (guide §2.1):** DB schema (2, `retention_class` column + 2 CHECK constraints +
`events_ephemeral` table) + tenant isolation (2, all PER_TENANT) + transactional boundary (1,
archival aging / ephemeral drop are DB-transaction-scoped operations) = **5 points → sandbox
tier** by the letter of the rubric; as with PAR-01/02, no Wasm surface exists for this
requirement, so unit + integration is the applicable ceiling. Recorded per guide §2.1.

## Acceptance Criteria Coverage

- AC1 — protected-family event types (`{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}`) configured
  for retention class `delete` are rejected with `RetentionClassForbidden`; never route to
  `events_ephemeral`.
- AC2 — a 14-month-old `events` partition ages out via DETACH/ATTACH with no row copy; rows
  remain readable through `events_archive`.
- AC3 — an `events_ephemeral` partition older than `ephemeral_drop_after_months` (default 3) is
  guarded before DROP: `SELECT count(*) ... WHERE split_part(event_type,'_',1) IN
  ('INSTANCE','TASK','GATEWAY','EXECUTION')` must return 0.
- AC4 — a non-zero guard count raises `Adp11GuardTripped` as BLOCKER; the partition stays
  attached, no drop occurs.
- AC5 — a detach that commits but whose archive-attach fails leaves the partition
  `ORPHAN_PARTITION`, queryable, retried on the next maintenance run.
- AC6 — detach and drop each append `EXECUTION_PARTITION_DETACHED` / `EXECUTION_PARTITION_DROPPED`
  to the event log.

## Test Cases

### TC-PAR-03-01: registerType rejects retention_class=delete for a protected-family name (NEW — closes a coverage gap, see Gap Closed note)
**Given:** `RegisterParams` for each of `INSTANCE_STARTED`, `TASK_COMPLETED`,
`GATEWAY_EVALUATED`, `EXECUTION_PARTITION_CREATED` (one representative per protected prefix), each
with `retention_class = "delete"`.
**When:** `registry.validateRegisterParams(params)` is called — the pure, DB-free function
`Registry.registerType()` calls before acquiring any connection.
**Then:** Each call returns `RegistryError.RetentionClassForbidden`.
**Layer:** unit
**Acceptance criterion mapped:** AC1 (app-level guard, the first line of defense named explicitly
by the AC text).
**Implemented by:** `tests/unit/event_store_test.zig` test
`"TC-PAR-03-01: registerType rejects retention_class=delete for a protected-family name"`.

### TC-PAR-03-02: registerType permits retention_class=delete for a non-protected name (NEW)
**Given:** `RegisterParams` for `WIDGET_CREATED` (does not match any protected prefix) with
`retention_class = "delete"`.
**When:** `registry.validateRegisterParams(params)` is called.
**Then:** No error — the permitted path `TC-ADP-11-02` (below) exercises end-to-end against a real
DB.
**Layer:** unit
**Acceptance criterion mapped:** AC1 (converse direction — the guard must not over-reject
non-protected names).
**Implemented by:** `tests/unit/event_store_test.zig` test
`"TC-PAR-03-02: registerType permits retention_class=delete for a non-protected name"`.

### TC-PAR-03-03: registerType permits protected-family names with non-delete retention_class (NEW)
**Given:** `INSTANCE_STARTED` with `retention_class` set to each of `retain_forever` and
`archive_queryable` (the two allowed modes for protected families).
**When:** `registry.validateRegisterParams(params)` is called.
**Then:** No error — the guard is specifically `retention_class=='delete' AND protected-family`,
not "protected-family names are always rejected."
**Layer:** unit
**Acceptance criterion mapped:** AC1 (precision of the guard condition).
**Implemented by:** `tests/unit/event_store_test.zig` test
`"TC-PAR-03-03: registerType permits protected-family names with non-delete retention_class"`.

### TC-PAR-03-04: DB-level CHECK independently rejects protected-family delete, bypassing the app guard
**Given:** A protected-family name (`INSTANCE_PAR03_<uuid>`) already registered with the default
`archive_queryable` class, via raw SQL (not `Registry.registerType()`, so the app-level guard is
not in the call path at all).
**When:** `UPDATE event_type_registry SET retention_class = 'delete' WHERE name = $1` is issued
directly.
**Then:** `chk_retention_class_protected_family` rejects it — the DB-level backstop independent of
the app-level guard (`TC-PAR-03-01` above), i.e. two independent layers, per SECURITY-REVIEWER's
CHECK 1 finding.
**Layer:** integration
**Acceptance criterion mapped:** AC1 (DB-level backstop).
**Implemented by:** `tests/integration/par03_retention_class_test.zig` test
`"par03_retention_class: protected_family_delete_rejected_by_db_check"`.

### TC-PAR-03-05: retention_class CHECK rejects an unrecognized value
**Given:** A registered event type.
**When:** `retention_class` is updated to `'BOGUS'`.
**Then:** Rejected by `chk_retention_class`.
**Layer:** integration
**Acceptance criterion mapped:** AC1 (schema contract underlying the whole retention-class
mechanism).
**Implemented by:** `tests/integration/par03_retention_class_test.zig` test
`"par03_retention_class: check_constraint_rejects_unknown_value"`.

### TC-PAR-03-06: new event types default to archive_queryable, never delete
**Given:** A newly registered event type with no explicit `retention_class`.
**When:** The row is read back.
**Then:** `retention_class = 'archive_queryable'` — the non-destructive default (never `'delete'`
by omission).
**Layer:** integration
**Acceptance criterion mapped:** AC1 (safe default — a caller that forgets to specify retention
class cannot accidentally create a delete-class type).
**Implemented by:** `tests/integration/par03_retention_class_test.zig` test
`"par03_retention_class: defaults_to_archive_queryable"`.

### TC-PAR-03-07: non-protected delete-class event routes to events_ephemeral end-to-end and is genuinely dropped
**Given:** `WIDGET_CREATED` registered with `retention_class = 'delete'` (permitted per
`TC-PAR-03-02`).
**When:** `Store.append()` is called for this type, then a synthetic aged `events_ephemeral`
partition holding the row is processed by `PartitionRetention.runEphemeralDrop()`.
**Then:** The row lands in `events_ephemeral` (not `events`); `runEphemeralDrop()` genuinely
`DROP TABLE`s the aged partition (`dropped >= 1`), with the ADP-11 guard never tripping
(`guard_tripped == 0`, correctly, since `WIDGET_CREATED` is not protected-family) — confirmed via
`to_regclass()` returning NULL post-drop (a real DROP, not a state-flag flip).
**Layer:** integration
**Acceptance criterion mapped:** AC2's converse (delete-class routing) + AC3 (guard passes cleanly
for genuinely non-protected rows) + the DROP-confined-to-events_ephemeral invariant SECURITY-
REVIEWER's CHECK 2 independently verified.
**Implemented by:** `tests/integration/event_store_integration_test.zig` test
`"TC-ADP-11-02: non-protected families retain hard-delete configurability"` (end-to-end append +
`runIsolatedEphemeralDropCycle` helper).

### TC-PAR-03-08: protected-family row ages out via DETACH/ATTACH and remains queryable in events_archive
**Given:** An isolated, dedicated aged `events` partition (synthetic 1999 month, not the shared
current-month partition) holding an `INSTANCE_STARTED` row.
**When:** `PartitionRetention.runArchivalAging()` runs.
**Then:** The row is gone from `events` (`live_count == 0`) and present in `events_archive`
(`archive_count == 1`); `plat_partition_catalog` reflects `parent_table='events_archive'`,
`state='ATTACHED'` — the replay-safety invariant ADP-11 exists to protect, delivered by
DETACH/ATTACH rather than DELETE+INSERT.
**Layer:** integration
**Acceptance criterion mapped:** AC2 (no-row-copy aging; queryability preserved).
**Implemented by:** `tests/integration/event_store_integration_test.zig` test
`"TC-ADP-11-03: protected keep_days policy archives and preserves queryability"`.

### TC-PAR-03-09: runArchivalAging reports the count of partitions moved and is idempotent
**Given:** Two isolated aged `events` partitions for two different past months.
**When:** `runArchivalAging()` runs twice in succession.
**Then:** The first call moves exactly 2 partitions (`detached_and_reattached`, the mechanism's
actual unit of work — not a row count, which has no meaning at whole-partition granularity); the
second call does not re-move the same two partitions (they no longer match
`parent_table='events' AND state='ATTACHED'`).
**Layer:** integration
**Acceptance criterion mapped:** AC2 (aging mechanism) + the general "partition creation/aging
SHALL be idempotent" principle this requirement shares with PAR-02 AC2.
**Implemented by:** `tests/integration/event_store_integration_test.zig` test
`"TC-ES-07-02: PartitionRetention.runArchivalAging reports partitions moved and is idempotent"`.

### TC-PAR-03-10: events_ephemeral composite PK behaves identically to events/events_archive
**Given:** A row inserted into `events_ephemeral` with a given `(event_id, created_at)` pair.
**When:** A second row with the identical pair is inserted.
**Then:** Rejected by the composite PK — confirms the hand-written `events_ephemeral` table
(migration 1149, codegen cannot express `PARTITION BY`/composite PK) carries the same PK shape
PAR-01 establishes for `events`/`events_archive`.
**Layer:** integration
**Acceptance criterion mapped:** AC2/AC3 (structural precondition for the whole partition-scoped
retention mechanism — ephemeral partitions must be genuine partitions of a genuinely partitioned
table).
**Implemented by:** `tests/integration/par03_retention_class_test.zig` test
`"par03_retention_class: events_ephemeral_accepts_row_with_composite_pk"`.

### TC-PAR-03-11 (unit, pure): PROTECTED_FAMILY_GUARD_SQL formats correctly against a candidate table
**Given:** A candidate partition name.
**When:** `PROTECTED_FAMILY_GUARD_SQL` (the format string `runEphemeralDrop()`'s pre-drop guard
uses) is formatted against it.
**Then:** The resulting SQL text contains the candidate table name and the `INSTANCE` prefix
literal — confirms the guard's format string itself is well-formed before any DB call.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (guard SQL shape).
**Implemented by:** `src/scheduler/partition_retention.zig` test
`"PROTECTED_FAMILY_GUARD_SQL: formats against a candidate table name"`.

### TC-PAR-03-12/13 (unit, pure): RetentionConfig / result-struct defaults
**Given:** Default-constructed `RetentionConfig{}`, `ArchivalAgingResult{}`, `EphemeralDropResult{}`.
**When:** Fields are read without any explicit initialization.
**Then:** `archive_after_months=13`, `ephemeral_drop_after_months=3` (matching AC2/AC3's stated
defaults verbatim); result structs zero-initialize their counters.
**Layer:** unit
**Acceptance criterion mapped:** AC2, AC3 (documented default values).
**Implemented by:** `src/scheduler/partition_retention.zig` tests
`"RetentionConfig: defaults match PAR-03's documented defaults"`,
`"ArchivalAgingResult: default-initializes to zero counts"`,
`"EphemeralDropResult: default-initializes to zero counts"`.

## ADP-11 re-verification (RELEASED, MUST — mandatory second look per this batch's task)

ADP-11's full body (`docs/requirements.yaml`) requires: event types in
`{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}` MUST have either "retain forever" or "archive and
remain queryable" retention; configuring hard deletion for these types MUST be rejected at
configuration time; AC: "Attempting to set hard deletion on `INSTANCE_STARTED` is rejected with a
structured error."

The existing `tests/specs/ADP-11.md` (unchanged by this batch — read in full) describes three test
cases, `TC-ADP-11-01/02/03`, against the ORIGINAL mechanism (`Store.archive()`'s row-level
DELETE+INSERT move and a `RetentionPolicyUpsertParams`/`hard_delete_days` policy API). BACKEND-DEV
rewrote `TC-ADP-11-02` and `TC-ADP-11-03` in this batch (`TC-ADP-11-01` is untouched). Read line by
line:

- **`TC-ADP-11-01`** (unchanged): still asserts `store.upsertRetentionPolicy()` rejects
  `hard_delete_days` for `INSTANCE_STARTED` with `StoreError.ProtectedFamilyHardDeleteForbidden`
  and the full structured-violation payload (`code`, `reason`, `event_family`, `requested_mode`,
  `allowed_modes`). This is ADP-11's ORIGINAL, still-live enforcement path
  (`RetentionPolicyUpsertParams`/`upsertRetentionPolicy`) — distinct from PAR-03's NEW
  `retention_class`/`registerType()` path. Both paths now coexist and both reject hard-deletion of
  protected families, independently. Confirmed still passing (28/28 in the full integration run,
  see Execution Notes).
- **`TC-ADP-11-02`** (REWRITTEN): the original test asserted a non-protected type's events were
  physically removed by `Store.archive()`'s row-level DELETE. The rewrite instead registers a
  non-protected delete-class type (`WIDGET_CREATED`), appends via the REAL `Store.append()` call,
  and asserts the row lands in `events_ephemeral` (not `events`) — i.e. that the type WAS
  configured for hard deletion and its events WERE routed to the table
  `PartitionRetention.runEphemeralDrop()` genuinely operates on, then drives a full
  `runEphemeralDrop()` cycle and confirms a real `DROP TABLE` occurred. This is a STRONGER
  end-to-end proof than the original (real routing decision, real drop mechanism, not merely "a
  DELETE statement ran") and it demonstrably proves the SAME AC clause the original test proved:
  "non-protected families retain [ES-07-inherited] hard-delete configurability." Not merely a
  name-preserving rename — traced the full body above; it genuinely exercises the equivalent
  real-world behavior through the new mechanism.
- **`TC-ADP-11-03`** (REWRITTEN): the original test asserted a protected type's events, after a
  `keep_days=0` archive policy, were moved from `events` to `events_archive` via
  `Store.archive()`'s row-level move and remained queryable there. The rewrite instead backs an
  `INSTANCE_STARTED` row into an isolated, already-aged `events` partition and drives a REAL
  `PartitionRetention.runArchivalAging()` call, asserting the row is gone from `events`
  (`live_count == 0`) and present in `events_archive` (`archive_count == 1`) afterward. This proves
  the identical AC clause — "protected families' archived rows stay queryable" — through the
  DETACH/ATTACH mechanism PAR-03 mandates in place of the row-level DELETE+INSERT ADP-11's
  original implementation used (and which PAR-03 AC explicitly forbids going forward: "No `DELETE`
  statement SHALL run against `events` or `events_archive` at any point").

**Verdict:** every one of ADP-11's original acceptance criteria — protected-family hard-delete
rejection (both the original `upsertRetentionPolicy` path AND the new `registerType` path, per
`TC-PAR-03-01` above), and the replay-safe archive/queryability invariant for protected families —
remains genuinely proven, not merely renamed. The rewrite is a mechanism substitution
(row-DELETE→DETACH/ATTACH, matching PAR-03's own explicit "No DELETE" rule) with equivalent or
stronger end-to-end assertions, confirmed by reading the full test bodies rather than trusting the
test names. ADP-11 remains fully satisfied. `tests/specs/ADP-11.md` itself is NOT updated in place
(it still accurately describes `TC-ADP-11-01`, which is unchanged, and its Execution Notes still
correctly point at `event_store_integration_test.zig`) — this section serves as the required
companion note documenting the mechanism change for `TC-ADP-11-02`/`03`, cross-referenced from
here per this batch's task instruction ("update it, or note in PAR-03.md").

## Observation B — event_payload_store's FK gap for large-payload delete-class events is genuinely out of scope for this batch

SECURITY-REVIEWER's MINOR observation: `event_payload_store`'s FK
(`FOREIGN KEY (event_id, created_at) REFERENCES events (event_id, created_at)`, migration 1147
line 181) does not cover `events_ephemeral`. A delete-class event with payload >4096 bytes
(`store.zig`'s large-payload threshold, `store.zig:82`) routed to `events_ephemeral` would have its
`event_payload_store` side-table INSERT rejected by this FK.

**Determination:** re-read all four PAR-01–04 ACs in full plus PAR-03's own body — none mentions
payload size, `event_payload_store`, or large-payload handling at all. This is a cross-cutting
mechanical consequence of PAR-03's append-time routing addition (REWORK 2) interacting with an
existing, pre-existing ES-01/NFR-05 side-table mechanism that predates this batch — not a scenario
any PAR-01–04 AC requires to work end-to-end. The failure mode itself is safe (confirmed by reading
`store.zig:645-658`: the INSERT failure is caught generically and mapped to
`StoreError.TransactionFailed`, rolling back the whole append — no partial write, no data
corruption, no cross-tenant exposure). No test in this batch exercises the >4096-byte delete-class
path, and per this determination, none needs to for PAR-01–04's own AC set to be considered fully
covered.

**Conclusion:** genuinely out of scope for this batch. Recommend a follow-up functional issue
(widen `event_payload_store`'s FK to also cover `events_ephemeral`, or duplicate the FK'd
side-table pattern per PAR-01's precedent for `events`/`events_archive`) rather than adding a test
or fix here — there is no AC this batch actually violates by leaving it as documented, fails-safe
behavior.

## Gap Closed

Prior to this handoff, `RegistryError.RetentionClassForbidden` — the exact error PAR-03 AC1 names
("configuration is rejected with `RetentionClassForbidden`") — was asserted by NO test anywhere in
the suite. The only integration coverage exercising this guard (`TC-ADP-11-02`) only exercises the
PERMITTED path (a non-protected name); `par03_retention_class_test.zig`'s
`protected_family_delete_rejected_by_db_check` bypasses `Registry.registerType()` entirely via a
raw SQL `UPDATE`, testing only the DB-level backstop, not the app-level guard the AC names first.
`registry.validateRegisterParams()` is a pure, DB-free function (confirmed: no `Pool`/`Conn`
parameter, no I/O) — the same pattern `TC-ES-05-03/05/06` already established for this exact
function — so this was closeable with a unit test, no new infrastructure required. Closed by
`TC-PAR-03-01/02/03` above (`tests/unit/event_store_test.zig`), confirmed passing (see Execution
Notes).

## Traceability Matrix

| PAR-03 acceptance area | Deterministic evidence |
|---|---|
| AC1 — RetentionClassForbidden (app-level guard) | TC-PAR-03-01, TC-PAR-03-02, TC-PAR-03-03 (NEW) |
| AC1 — RetentionClassForbidden (DB-level backstop) | TC-PAR-03-04, TC-PAR-03-05, TC-PAR-03-06 |
| AC2 — no-row-copy archival aging, queryability preserved | TC-PAR-03-08, TC-PAR-03-09 |
| AC2 — delete-class routing (converse of AC1) | TC-PAR-03-07 |
| AC3 — pre-drop guard structure | TC-PAR-03-07 (guard passes), TC-PAR-03-11 |
| AC4 — Adp11GuardTripped on non-zero guard | Job logic present (`partition_retention.zig:323-326`); no test drives a genuine guard trip (protected-family row physically present in an ephemeral partition) — see Gap note below |
| AC5 — ORPHAN_PARTITION on failed re-attach | Job logic present (`archiveOnePartition()`'s `markOrphan` calls, `retryOrphanedAttaches()`); no integration test forces a re-attach failure to observe the transition — see Gap note below |
| AC6 — EXECUTION_PARTITION_DETACHED/DROPPED events | Not directly asserted by any test in this batch — see Gap note below |
| ADP-11 continued satisfaction | Re-verified in full above — CONFIRMED |

## Gap note — AC4/AC5/AC6 have correct job logic but no test drives the specific failure/event-emission paths

- **AC4** (`Adp11GuardTripped`): the guard-trip branch itself
  (`partition_retention.zig:323-326`) is simple, reviewable pure logic (`if (protected_count > 0)
  return RetentionError.Adp11GuardTripped`), and is structurally unreachable in normal operation
  since AC1's two independent layers (app guard + DB CHECK) already prevent a protected-family row
  from ever being routed to `events_ephemeral` — the guard is defense-in-depth, not the primary
  mechanism. `TC-PAR-03-07`'s isolated cycle exercises the **non-tripping** path
  (`guard_tripped == 0`). No test forces the trip itself (would require bypassing both AC1 layers
  to insert a protected-family row directly into an `events_ephemeral` partition, then confirming
  the guard catches what both upstream layers already prevent). MINOR — recommend a follow-up test
  using the same isolated-partition technique `TC-PAR-03-07`/`TC-PAR-03-08` already establish,
  inserting an `INSTANCE_*`-prefixed row directly via raw SQL (bypassing the app+DB guards
  deliberately, the same technique `TC-PAR-03-04` uses) into an aged ephemeral partition and
  asserting `runEphemeralDrop()` returns `Adp11GuardTripped` with the partition still attached
  afterward.
- **AC5** (`ORPHAN_PARTITION` on failed re-attach): `archiveOnePartition()`'s `markOrphan()` calls
  and `retryOrphanedAttaches()`'s retry-on-next-cycle logic are implemented but not exercised by
  any test that deliberately induces an attach failure (e.g. a partition missing one of PAR-04's
  required CHECK constraints at the re-attach step). MINOR — recommend a follow-up test that
  crafts a standalone partition missing the tenant-id CHECK, drives `runArchivalAging()` against
  it, and confirms the `ORPHAN_PARTITION` state + successful recovery on a second call once the
  CHECK is added.
- **AC6** (`EXECUTION_PARTITION_DETACHED`/`EXECUTION_PARTITION_DROPPED` events): `grep -rn
  "EXECUTION_PARTITION_DETACHED\|EXECUTION_PARTITION_DROPPED"` across
  `src/scheduler/partition_retention.zig` returns no hits — the same class of gap as PAR-02 AC5's
  `EXECUTION_PARTITION_CREATED` (see `tests/specs/PAR-02.md`'s Gap note). MINOR, same disposition:
  file for BACKEND-DEV, do not block this handoff.

These three gaps are the same MINOR/follow-up character as PAR-02's AC3/AC5 gaps — implemented,
reviewable, low-risk surrounding logic missing a final assertion/emission step — and are distinct
from PAR-01 AC4's BLOCKER-severity gap (an entirely unimplemented error type). None of them affect
ADP-11's re-verified, continued satisfaction above.

## Execution Notes For TEST-RUNNER

- Unit targets: `zig build test-partition-retention` (partition_retention.zig's own pure tests, no
  DB); the new `TC-PAR-03-01/02/03` unit tests run as part of `zig build test`'s
  `event_store_tests` binary (no dedicated standalone step exists for
  `tests/unit/event_store_test.zig` — it is wired only into the aggregate `test` step).
- Integration targets: `zig build test-integration-par03`, `test-integration-event-store` (both
  require `BPM_TEST_DB_URL`).
- Confirmed this run: `test-partition-retention` 4/4, `test-integration-par03` 4/4,
  `test-integration-event-store` 28/28, all exit 0.
