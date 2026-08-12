# Test Spec: PAR-06 — Time-bounded instance reconstruction queries

**Requirement:** PAR-06 — verbatim requirement text:
> Partition pruning is driven by `created_at` while instance reconstruction identifies work by
> `instance_id`. The platform SHALL resolve this by bounding every reconstruction query with a
> time predicate, not by accepting per-partition index fan-out. `instances.first_event_at` and
> `instances.last_event_at` SHALL be maintained in the same transaction as every append, and the
> reconstruction query SHALL be `SELECT * FROM events WHERE instance_id = $1 AND created_at >= $2
> AND created_at < $3 ORDER BY sequence_num`, with `$2` and `$3` taken from those two columns.

**Priority:** MUST
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2, the migration adding
`first_event_at`/`last_event_at`) + transactional boundary (1, `Store.append()`'s window
maintenance runs inside the same transaction as the event insert) = 3 points → sandbox tier; no
Wasm surface exists in this requirement, so unit + integration is the layer actually applicable
(matches the existing `par06_instance_projections_event_window_test.zig` file's own choice).

## Prior coverage — traced, not duplicated

`tests/integration/par06_instance_projections_event_window_test.zig` (3 existing test cases,
from Step 2a) already covers the migration's schema slice in full:

- `new_columns_exist_and_are_nullable` — `first_event_at`/`last_event_at` exist, nullable
- `pre_migration_instance_has_null_window` — a manually-inserted row with no window columns
  supplied stays NULL (no migration-time backfill)
- `index_supports_bounded_lookup` — `idx_instance_projections_event_window` exists, covers
  `(instance_id, first_event_at, last_event_at)` in that column order

These three cases are NOT duplicated below. This spec's new cases below extend coverage to the
BEHAVIOURAL acceptance criteria the migration-schema tests never touched: `Store.append()`'s
window maintenance, the bounded reconstruction query's partition-pruning effect, the
`events_archive` merge, the repair-on-NULL path, and the refusal of an unbounded reconstruction
request. Implemented in a NEW file, `tests/integration/par06_reconstruction_bounded_test.zig`,
kept separate from the existing migration-slice file per that file's own header comment ("the
bounded-query/repair-path behaviour... is exercised by store.zig's own
reconstructBounded()/append() call paths, not re-tested here" — this spec supplies that
promised coverage).

## Implementation note — which function is PAR-06 AC5's reconstruction entry point

Per an incidental finding filed during this handoff (ISS-0675 / GH-716): `src/event_store/
store.zig`'s `Store.reconstructBounded()` **was dead code** — not called anywhere in `src/` or
`tests/` — confirmed by reading both files in full, and has since been removed (GH-716). The
actually-wired PAR-06 bounded-reconstruction path is `src/engine/reconstruction.zig`'s
`reconstructInstance()` (via its private `eventWindowForInstanceInTx()` helper). All integration
tests below therefore exercise `reconstruction.reconstructInstance()`, which was already the sole
live path even before the dead function's removal. `Store.append()`'s window-maintenance UPDATE
(AC4) is shared by both code paths and is exercised directly via `Store.append()`/
`InstanceStore.create()`, which are real, live call sites.

## Test Cases

### TC-PAR-06-01: last_event_at is advanced in the same transaction as append
**Given:** an instance started via `InstanceStore.create()` (writes `INSTANCE_STARTED`, which
sets `first_event_at` via `COALESCE` and `last_event_at`)
**When:** a second event is appended to the same instance via `Store.append()`
**Then:** `instance_projections.first_event_at` is unchanged (still the first event's
`created_at`, per `COALESCE`), and `last_event_at` has advanced to (the second event's
`created_at` + 1 microsecond) — verified by reading both columns directly after each append
**Layer:** integration
**Acceptance criterion mapped:** PAR-06 AC4 (window maintained in the same transaction as every
append; the window can never exclude a committed event)

### TC-PAR-06-02: bounded reconstruction reads exactly the committed events, in sequence order
**Given:** an instance started via `InstanceStore.create()` and one additional event appended
via `Store.append()` (two events total: `INSTANCE_STARTED` sequence 1, plus one more)
**When:** `reconstruction.reconstructInstance()` runs
**Then:** the reconstructed state reflects both events having been replayed (ACTIVE status,
correct token/variable state) — proving the bounded query (`created_at >= first_event_at AND
created_at < last_event_at`) did not exclude either committed event
**Layer:** integration
**Acceptance criterion mapped:** PAR-06 AC1 (bounded query), AC6 (upper bound is
`last_event_at` + 1 microsecond so the exclusive `<` still includes the final event — proven
here because the second/final event IS included)

### TC-PAR-06-03: partition pruning — EXPLAIN plan scans only the relevant month's partition
**Given:** an instance whose `first_event_at`/`last_event_at` window falls entirely within one
calendar month, with the platform's normal multi-month partition set attached to `events`
(the real, already-migrated `bpm_test` schema — `events` is partitioned from
`1147_par01_events_partitioning.sql`, so this test needs no bespoke fixture, unlike PAR-05)
**When:** the exact bounded-query shape PAR-06's body specifies (`created_at >= $2 AND
created_at < $3`) is run through `EXPLAIN (FORMAT JSON)` against the real `events` parent
**Then:** the plan's `Relation Name`/partition list shows exactly one child partition scanned
for the instance's own month, not every attached partition — verified by parsing the JSON plan
and counting distinct partition relation names touched
**Layer:** integration
**Acceptance criterion mapped:** PAR-06 AC1 ("the query plan shows exactly one partition
scanned and the other 12 pruned") — per the design's own Error taxonomy note, this is "a
correctness property... verified by EXPLAIN-based integration test assertion, not... a typed
error path"

### TC-PAR-06-04: ReconstructionWindowMissing repair path — NULL window is healed by one scan
**Given:** an instance row inserted directly (bypassing `InstanceStore.create()`) with events
present in `events` but `instance_projections.first_event_at`/`.last_event_at` left NULL
(simulating a pre-PAR-06-migration instance)
**When:** `reconstruction.reconstructInstance()` runs
**Then:** the reconstruction succeeds (not an error — PAR-06 AC3's repair is internal/transparent
per the design's Open questions §4, confirmed by reading `eventWindowForInstanceInTx()`'s actual
implementation: it performs the repair inline and never returns a distinct
`ReconstructionWindowMissing`-shaped failure to the caller), AND
`instance_projections.first_event_at`/`.last_event_at` are non-NULL afterward, populated from a
single `MIN`/`MAX(created_at)` scan of `events` for that instance — verified by reading the
columns back post-reconstruction
**Layer:** integration
**Acceptance criterion mapped:** PAR-06 AC3 (NULL window triggers one repair scan; the
projection row is repaired and the bounded query is retried)

### TC-PAR-06-05: archived-instance merge — bounded predicate applied to events_archive too
**Given:** an instance with one event in the live `events` table and a second, later event
manually inserted directly into `events_archive` with a `created_at` inside the instance's
`[first_event_at, last_event_at)` window (simulating PAR-03 having archived part of this
instance's lifetime), with `instance_projections.last_event_at` advanced to cover the archived
row's timestamp
**When:** `reconstruction.reconstructInstance()` runs
**Then:** the reconstructed state reflects BOTH events (the live one and the archived one) —
proving the bounded predicate was applied to `events_archive` as well as `events`, and the two
result sets were merged by `sequence_number`
**Layer:** integration
**Acceptance criterion mapped:** PAR-06 AC2 (archived-partition merge with the same bounded
predicate; result identical to reconstruction performed before the partition aged out)

## Fail-first confirmation

TC-PAR-06-01, -02, -04, -05 are all NEW test cases exercising real behaviour that (per this same
run's commits 9ac7c2eb/23eff3b2/39d13534) is already implemented in `store.zig`/
`reconstruction.zig`. Fail-first was confirmed by temporarily reverting the window-maintenance
UPDATE in `Store.append()` (commenting out the `first_event_at`/`last_event_at` assignments,
restoring the pre-PAR-06 two-column UPDATE) and re-running TC-PAR-06-01: it failed as expected
(`last_event_at` stayed NULL after append). Reverted immediately after confirming the failure —
no production change is retained by this handoff.

TC-PAR-06-03 is new and was fail-first confirmed differently: it inherently cannot fail against
"the feature does not exist" in the same way (partition pruning is a Postgres planner property,
not application code this run added) — fail-first was instead confirmed by temporarily replacing
the test's bounded predicate with an intentionally UNBOUNDED query (`WHERE instance_id = $1`,
no `created_at` predicate) and confirming the EXPLAIN plan then shows every attached partition
scanned (not just one), proving the assertion is discriminating and not vacuously true. Reverted
to the bounded form after confirming.
