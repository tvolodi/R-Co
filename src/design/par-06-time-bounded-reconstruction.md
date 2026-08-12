# Module: par-06-time-bounded-reconstruction

**Requirement ID:** PAR-06
**Run ID:** WF02-batch-4-20260811 (Stage 16)
**Covers:** PAR-06
**Extends:** none (PAR-06 has no `Extends:` line in its body)
**See (from PAR-06's own body):** PAR-01 (the partitioned `events` shape this bounds queries
against), PAR-03 (archived partitions this query must also reach), XC-05 (deterministic replay
depends on reconstruction returning the same events), IR-07 (archived partitions remain
queryable), ES-07 (the retention/archival requirement IR-07 interprets)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** PAR-06 does add two columns (`instance_projections.first_event_at`,
   `instance_projections.last_event_at`) — a genuine schema change. Per selection rule 1 ("Type C
   if the requirement adds, alters, or removes a database table/column"), the column-addition
   PART of this requirement is Type C-shaped. However, `templates/specs/migration.template.yaml`'s
   flat column-list schema has no way to express the load-bearing invariant this requirement
   actually specifies: `last_event_at` must be updated **in the same transaction as every
   append** (AC4), and the bounded reconstruction query itself is a hand-shaped `SELECT` with a
   two-parent `UNION`-across-archive read path (AC2) plus a self-healing repair-on-NULL branch
   (AC3) — none of which a migration YAML's schema covers. Only the column-addition slice is
   genuinely Type C; the query/maintenance logic is not.
2. **Type A / Type D / Type B?** No new HTTP route is introduced by PAR-06's own AC text (the
   existing `Store.read()`/`readHistory()` call sites are what gets bounded — see Module purpose),
   no React Flow node, no admin page.
3. **Type E for the bulk of the requirement, decomposed with one Type C migration slice.** Per
   `templates/lego-catalog.md`'s own guidance ("A requirement may decompose into mixed types —
   list every parameter file and prose artefact under `artifacts_out`"), this design produces:
   - **Type C**: `templates/specs/par06-instance-projections-event-window.migration.yaml` — the
     two-column addition (`first_event_at`, `last_event_at`) plus their maintenance trigger-free
     update-in-transaction requirement documented as a CUSTOM block (schema decisions the
     template's flat column list cannot express go in the design prose below, per
     `docs/anti-patterns.md`'s "Do NOT make database schema decisions outside a Type C migration
     YAML" — read, as PAR-01's design already established, as "outside a design artefact
     BACKEND-DEV implements from"; this document supplies that decision, the YAML supplies the
     literal column DDL codegen can emit).
   - **Type E**: this document — the bounded reconstruction query shape, the
     `ReconstructionWindowMissing` repair-and-retry path, the append-time column maintenance
     requirement, and the archived-partition merge logic, none of which fit any A–D template.

No fenced code block below exceeds the linter's 40-line cap.

## Module purpose

Bound every instance-reconstruction query by a `created_at` time window derived from two new
`instance_projections` columns (`first_event_at`, `last_event_at`), maintained in the same
transaction as every event append, so that partition pruning — driven by `created_at` — actually
applies to reconstruction queries that otherwise identify work only by `instance_id` (which
carries no partition-pruning information on its own). Without this bound, PAR-01's partitioning
buys nothing for the read path: every reconstruction would force PostgreSQL to scan every
attached partition looking for the instance's rows (per-partition index fan-out), exactly the
cost partitioning is meant to avoid. This design also specifies how a bounded query reaches into
`events_archive` once part of an instance's lifetime has aged out under PAR-03, so the two-store
split stays invisible to callers.

## Data flow diagram

```
Store.append() (src/event_store/store.zig) — existing transaction, PAR-01/DB-03 shape
        |
        |-- INSERT INTO events (...) VALUES (...)             [unchanged, PAR-01 shape]
        |-- INSERT INTO plat_event_idempotency (...)           [unchanged, PAR-01 shape]
        |-- UPDATE instance_projections                        [existing Step 5, EXTENDED]
        |     SET last_event_seq = $1, updated_at = NOW(),
        |         first_event_at = COALESCE(first_event_at, <this event's created_at>),
        |         last_event_at  = <this event's created_at> + INTERVAL '1 microsecond'
        |     WHERE instance_id = $2
        v
COMMIT  (event row + idempotency row + window-column update, all-or-nothing — PAR-06 AC4)
```

```
Store.readHistory() / a new Store.reconstructBounded() (src/event_store/store.zig)
        |
        |-- SELECT first_event_at, last_event_at FROM instance_projections
        |     WHERE instance_id = $1
        |
        |-- either column NULL? --> ReconstructionWindowMissing:
        |       repair: SELECT MIN(created_at), MAX(created_at) FROM events
        |               WHERE instance_id = $1  (one full scan, ONE TIME, to backfill
        |               the two columns for this previously-unrepaired instance)
        |       UPDATE instance_projections SET first_event_at = ..., last_event_at =
        |               ... + INTERVAL '1 microsecond' WHERE instance_id = $1
        |       retry the bounded query below with the now-populated window
        |
        v
        SELECT * FROM events
        WHERE instance_id = $1 AND created_at >= $2 AND created_at < $3
        ORDER BY sequence_num
        -- PostgreSQL partition pruning: only partitions overlapping [$2, $3) are
        -- scanned; every other calendar-month partition is pruned before
        -- execution (PAR-06 AC1)
        v
        instance's created_at range crosses into an archived month (PAR-03 DETACH/
        ATTACH already moved that partition under events_archive)?
        |
        |-- YES: apply the SAME bounded predicate to events_archive, UNION ALL the
        |         two result sets, merge by sequence_num (PAR-06 AC2) — same
        |         two-table read shape Store.readHistory() already uses today,
        |         now ALSO bounded by the time window rather than unbounded
        v
caller receives events in sequence_num order, byte-identical to reconstruction
performed before any partition aged out (PAR-06 AC2 / XC-05 determinism)
```

## Public interface

### Migration (Type C slice): `instance_projections` window columns

`templates/specs/par06-instance-projections-event-window.migration.yaml` — next free migration
number **`1150`** (current max is `1149_par03_retention_class.sql`, confirmed via `ls migrations/
| sort` at design time):

```sql
ALTER TABLE instance_projections
    ADD COLUMN IF NOT EXISTS first_event_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_event_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_instance_projections_event_window
    ON instance_projections (instance_id, first_event_at, last_event_at);
```

Both columns are nullable (no `NOT NULL`, no `DEFAULT`) — deliberately, matching AC3's own
premise: an instance created before this migration ran (or one whose maintenance transaction
failed to set them for any reason) has NULL columns, and PAR-06 AC3 defines that condition as an
explicit, self-healing, non-error path (`ReconstructionWindowMissing` triggers a one-time repair
scan, NOT a hard failure). A `NOT NULL` constraint would make every pre-migration instance
un-queryable until an out-of-band backfill ran; the nullable-plus-repair design instead spreads
that backfill cost across normal reconstruction traffic, one instance at a time, on first access.

### `Store.append()` extension — window maintenance (PAR-06 AC4)

`src/event_store/store.zig`'s existing Step 5 (`UPDATE instance_projections SET
last_event_seq = $1, updated_at = NOW() WHERE instance_id = $2`, already inside the append
transaction) gains two more assignments in the SAME statement — no new round trip, no new
transaction boundary:

```sql
UPDATE instance_projections
SET last_event_seq  = $1,
    updated_at       = NOW(),
    first_event_at   = COALESCE(first_event_at, $3::timestamptz),
    last_event_at    = $3::timestamptz + INTERVAL '1 microsecond'
WHERE instance_id = $2
```

`$3` is the SAME `created_at` value the just-inserted `events`/`events_ephemeral` row received
(available from that INSERT's own `RETURNING created_at_us`, already read into
`inserted_created_at_us_text` a few lines earlier in `append()` — see the "Existing code paths"
section below). `first_event_at` uses `COALESCE` so it is set exactly once, on the instance's
first append, and never moves afterward (PAR-06's body only asks for a stable lower bound, not a
sliding one). `last_event_at` is unconditionally overwritten on every append, always advanced
forward, and always carries the `+ INTERVAL '1 microsecond'` upper-bound adjustment AT WRITE TIME
— not deferred to read time — so the query in the next section can use a plain exclusive `<`
comparison without every caller needing to remember the microsecond adjustment itself (PAR-06's
final bullet: "The upper bound is `last_event_at` plus one microsecond, so the exclusive `<`
comparison still includes the final event"). Because `append()` already computes
`sequence_number` under a per-instance lock (Step 2, `instance_sequence FOR UPDATE`-equivalent),
and because `last_event_at` only ever advances (never regresses — appends are ordered by that
same per-instance sequence), a concurrent second append cannot race this UPDATE into leaving
`last_event_at` stale: PAR-06 AC4's guarantee ("the window can never exclude a committed event")
holds because the write happens in the identical transaction as the event insert, not as a
best-effort follow-up.

### Bounded reconstruction query (PAR-06 AC1, AC5, AC6)

```sql
SELECT event_id, instance_id, event_type, payload, actor_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
       sequence_number, idempotency_key, metadata, global_seq
FROM events
WHERE instance_id = $1
  AND created_at >= $2   -- instance_projections.first_event_at
  AND created_at <  $3   -- instance_projections.last_event_at (already +1us)
ORDER BY sequence_number ASC
```

`$1` bound as a parameter (no string interpolation, matching every existing `store.zig` query
convention). `$2`/`$3` are the two `instance_projections` columns read moments earlier in the
same call — never omitted, never defaulted to an open range: PAR-06 AC5 makes an unbounded
reconstruction request a refused query form, not merely a slow one (see Error taxonomy).

### Archived-instance merge (PAR-06 AC2) — reuses the existing `readHistory()` shape

`Store.readHistory()` (`src/event_store/store.zig`, lines ~890–1029) already issues a
`UNION ALL` between `events` and `events_archive` with the SAME set of filter predicates applied
to both halves — this design does not invent a new merge mechanism, it adds the `created_at >=
$first_event_at AND created_at < $last_event_at` predicate as one more `AND` clause in BOTH
halves of that existing `UNION ALL`, exactly the way `readHistory()`'s existing `from`/`to`
optional filters are already applied to both `events` and `events_archive` identically. The
bounded reconstruction path (whether exposed as a new `Store.reconstructBounded()` function or as
a required, non-optional pair of `HistoryReadOpts.from`/`.to` values on the existing
`readHistory()` — see Open questions §1) therefore does not need its own archive-merge logic;
it needs only to always populate the `from`/`to` parameters `readHistory()` already accepts, from
the two window columns, rather than leaving them `null`.

### `ReconstructionWindowMissing` repair path (PAR-06 AC3)

```sql
-- Triggered when instance_projections.first_event_at OR .last_event_at is NULL.
-- One-time repair scan — the ONLY place this design permits a
-- reconstruction-triggered full-table scan of events for a single instance,
-- and only ever once per instance (after which the columns are non-NULL and
-- every subsequent reconstruction uses the bounded query above).
SELECT MIN(created_at), MAX(created_at) FROM events WHERE instance_id = $1;

UPDATE instance_projections
SET first_event_at = $2::timestamptz,
    last_event_at   = $3::timestamptz + INTERVAL '1 microsecond'
WHERE instance_id = $1
  AND first_event_at IS NULL;  -- idempotent: a concurrent repair for the
                                -- same instance_id does not overwrite a
                                -- window a racing caller already repaired
```

After the `UPDATE`, the caller re-reads `instance_projections` (or reuses the just-computed
`MIN`/`MAX` values directly — equivalent, since the `WHERE first_event_at IS NULL` guard means
either this caller's own UPDATE won or a concurrent one already supplied the same or a
subsequently-advanced value) and retries the bounded query from the previous section. The `WHERE
... IS NULL` guard on the UPDATE, not a `SELECT ... FOR UPDATE` lock, is the concurrency-safety
mechanism here — deliberately cheap (no lock held across the repair scan) since a
`ReconstructionWindowMissing` repair racing itself twice is harmless (both computations read the
same underlying `events` rows and would compute the same `MIN`/`MAX`), unlike `append()`'s window
maintenance, which genuinely needs the per-append transactional guarantee AC4 specifies.

## Existing `src/event_store/store.zig` code paths assessed

Read `Store.append()`/`Store.read()`/`Store.readGlobal()`/`Store.readHistory()` in full (already
read for the mandatory reading step) plus `src/scheduler/partition_maintenance.zig`'s month-
arithmetic helpers. Concrete changes required, by call site:

- **`Store.append()` Step 5** (the existing `UPDATE instance_projections SET last_event_seq =
  $1, updated_at = NOW() WHERE instance_id = $2`): extended in place per Public interface above.
  `inserted_created_at_us_text` (already computed a few lines earlier in `append()`, from the
  events/events_ephemeral INSERT's own `RETURNING created_at_us`) is the value to bind as this
  UPDATE's new `$3` — no new query needed to obtain it, the value already exists in scope.
- **`Store.readHistory()`**: gains the two additional `AND` predicates on both halves of its
  existing `UNION ALL`, as described above. The function's existing `HistoryReadOpts.from`/`.to`
  fields (currently optional, `null` = unbounded) are the natural carriers for
  `first_event_at`/`last_event_at` — see Open questions §1 for whether that reuse is direct or
  whether a new opts struct is cleaner.
- **`Store.read()`**: this function's three branches (`up_to_sequence`, `up_to_timestamp`, no
  filter) query `events` ONLY (no `events_archive` half), and PAR-01's own design already flagged
  its no-filter branch as unable to prune partitions. PAR-06 AC5's refusal rule ("a reconstruction
  submitted without a time predicate... is refused rather than executed") applies to
  reconstruction call sites specifically — `Store.read()`'s existing three call shapes are a
  narrower general-purpose read API also used by non-reconstruction callers (see Open questions
  §2 for exactly which callers), so this design does not blanket-forbid `Store.read()`'s existing
  unbounded form; it specifies that whichever function is/becomes THE reconstruction entry point
  (see Open questions §1) must always supply a bound, never accept a caller that omits one.
- **`src/engine/reconstruction.zig`**: not read in full for this design (out of the handoff's
  named mandatory-reading list), but is very likely the actual caller PAR-06 AC5's refusal rule
  targets, since its name is the closest match to "instance reconstruction" in this codebase.
  Flagged as Open questions §1 for BACKEND-DEV to confirm which function(s) there call into
  `Store.read()`/`Store.readHistory()` and update those call sites to always supply the window
  bound, rather than this design guessing at that file's internals without having read it.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `ReconstructionWindowMissing` | `instance_projections.first_event_at` or `.last_event_at` is NULL when reconstruction is requested (PAR-06 AC3) | New `StoreError` variant. NOT a terminal failure — the caller (or `Store` internally, see Open questions §4 for which layer owns the retry) performs the one-time repair scan described above, then retries the bounded query. If the repair scan itself fails (pool exhaustion, connection loss), that surfaces as the ordinary `PoolExhausted`/`TransactionFailed` `StoreError` variants, not a second `ReconstructionWindowMissing` |
| Reconstruction request with no time predicate (PAR-06 AC5) | A caller invokes the bounded reconstruction entry point without a resolvable `first_event_at`/`last_event_at` pair (distinct from AC3's NULL-columns-in-the-DB case — this is a caller that bypasses the window lookup step entirely, e.g. a new call site added later that forgets to look the columns up first) | Refused before any query executes — new `StoreError` variant (name not fixed by PAR-06's body; this design recommends `UnboundedReconstructionRefused` for symmetry with `ReconstructionWindowMissing`, see Open questions §5) rather than silently falling back to an unbounded scan |
| Partition pruning does not occur for a bounded query (i.e. the `EXPLAIN` plan scans more than the expected partition) | Not a runtime error — a correctness property PAR-06 AC1 requires be TRUE of the query plan, verified by `EXPLAIN`-based integration test assertion, not by a typed error path. Documented here because a regression here is silent (query still returns correct rows, only slower) unless specifically tested | No `StoreError` — TEST-DESIGNER must write a plan-inspection assertion (`EXPLAIN (FORMAT JSON)` parsed for partition count), not merely a row-equality assertion, to catch a pruning regression |

## Dependencies

- Depends on: PAR-01 (the partitioned `events`/`events_archive` shape this design's pruning
  claim (AC1) depends on — a bounded query against an UNpartitioned `events` gains nothing from
  this design beyond a smaller result set), PAR-03 (`events_archive`'s DETACH/ATTACH-populated
  partitions, which AC2's merge logic reads from), PAR-04 (indirectly — the partitions PAR-01/
  PAR-02/PAR-03 attach must already carry correct range CHECKs for pruning to be sound, but this
  design does not itself call `partition_attach.zig`), XC-05/IR-07/ES-07 (the determinism and
  archive-queryability guarantees AC2 explicitly must not violate — this design's merge logic is
  required to be a strict refinement of `readHistory()`'s existing unbounded merge, never a
  narrower one that could exclude an event XC-05 replay depends on).
- Must NOT depend on: PAR-05 (the online-conversion path — PAR-06's bounded query works
  identically whether `events` reached its partitioned shape via PAR-01's from-scratch build or
  PAR-05's online conversion; this design makes no assumption about which path produced the
  partitions it prunes against). Does NOT depend on ISS-0670/GH-711 (the platform-event-emission
  gap) — confirmed by reading PAR-06's body and `See:` list in full: neither names PAR-02 nor any
  `EXECUTION_*` event, and none of PAR-06's six acceptance criteria involve appending an event of
  any kind (the two window columns are ordinary projection-table state maintained by `append()`'s
  existing transaction, not a new event type).

## Open questions

1. **Which function is THE reconstruction entry point PAR-06 AC5's refusal rule binds?**
   `src/engine/reconstruction.zig` was not read in full for this design (not in the handoff's
   named mandatory-reading list: `src/event_store/store.zig`,
   `src/scheduler/partition_maintenance.zig`, `src/scheduler/partition_retention.zig`,
   `src/db/partition_attach.zig`). This design specifies the bounded-query SHAPE and the
   window-column maintenance in `store.zig`, and recommends reusing `readHistory()`'s existing
   `HistoryReadOpts.from`/`.to` fields as the bound carriers — but whether the actual
   caller-facing reconstruction API is `Store.readHistory()` itself, a new
   `Store.reconstructBounded()` wrapper, or a function inside `reconstruction.zig` that itself
   calls one of those, needs BACKEND-DEV to confirm against that file's actual current contents
   before implementing. Flagged rather than guessed.
2. **Which existing callers of `Store.read()`'s unbounded (no-filter) branch are reconstruction
   call sites vs. genuinely general-purpose reads?** This design does not forbid `Store.read()`'s
   existing unbounded form outright (see Error taxonomy) because some callers may legitimately
   want "all events for this instance" for a non-reconstruction purpose (e.g. an admin/debug
   listing) where AC5's refusal rule was not intended to apply. BACKEND-DEV should grep call
   sites of `Store.read()` and classify each before deciding whether any need to move to the
   bounded path.
3. Not applicable — the analogous "where should shared helpers live" question from PAR-05's
   design does not arise here (this design does not need `partition_maintenance.zig`'s month-
   arithmetic helpers; it operates on a per-instance timestamp pair, not a calendar-month grid).
4. **Repair-and-retry orchestration — inside `Store` itself, or pushed to the caller?** This
   design's data flow diagram shows the repair happening transparently before the bounded query
   retries, but does not mandate whether `Store`'s own function performs that retry internally
   (returning only the final, successful result to the caller) or whether it returns
   `ReconstructionWindowMissing` and expects the caller (`reconstruction.zig`, per Open questions
   §1) to perform the repair and re-invoke. The former is more convenient for callers and matches
   this codebase's general preference for `Store` absorbing retry-shaped internal mechanics (c.f.
   PAR-01's duplicate-detection fallback inside `append()` itself, not pushed to callers) — this
   design recommends that shape but leaves the final call to BACKEND-DEV since it is an
   implementation-structure choice, not a behavioural one (either shape satisfies PAR-06 AC3's
   text).
5. **Exact name of the "unbounded reconstruction request" error (AC5).** PAR-06's body states the
   BEHAVIOUR ("it is refused rather than executed") but, unlike AC3's `ReconstructionWindowMissing`,
   does not name a specific error identifier. This design recommends
   `UnboundedReconstructionRefused` for naming symmetry with the sibling error and with PAR-01's
   own `PartitionMissingForWrite` naming convention (a descriptive, past-tense-adjacent
   PascalCase name of what happened) — CODE-DESIGN-VALIDATOR/BACKEND-DEV may adjust the literal
   string if a different name is preferred; PAR-06's AC is satisfied by the refusal behaviour, not
   by this design's suggested name for it.

## Resolution (GH-716)

Open question §1 above was left genuinely undecided at design time, and BACKEND-DEV's original
implementation (commit 9ac7c2eb) resolved it by building both candidates instead of choosing one:
`Store.reconstructBounded()` (plus its private helpers) in `store.zig`, and an independently
written duplicate window-lookup-and-repair path in `src/engine/reconstruction.zig`
(`eventWindowForInstanceInTx()` / `reconstructInstance()`). This left `Store.reconstructBounded()`
as unreferenced dead code — never called from `src/` or `tests/` — while `reconstruction.zig`'s
path was the one actually wired up and exercised by the test suite. The two also diverged
behaviourally (tenant-scoping predicate present only in the dead code; empty-window handling
differed, with the dead code returning `ReconstructionWindowMissing` on a zero-row repair scan
where the live path correctly falls back to an unbounded-in-effect window for fully-archived
instances), making the dead code a maintenance hazard rather than a harmless duplicate.

ISS-0675/GH-716 tracked this as a code-quality defect. WF03-GH716-20260812 resolved open question
§1 retroactively: `Store.reconstructBounded()`, its private helpers
(`lookupOrRepairEventWindowInternal`, `mergeEventRowsBySequence`, `rowSequenceNumber`), the
now-fully-unreachable `StoreError.ReconstructionWindowMissing` / `.UnboundedReconstructionRefused`
variants, and the now-unused `EventWindow` struct were deleted from `store.zig`.
`src/engine/reconstruction.zig` is confirmed as THE sole PAR-06 bounded-reconstruction entry point
going forward — no other call site should be introduced in `store.zig` for this purpose. See
ISS-0675 for the full verification trail (zero live callers, non-exhaustive `StoreError` switch
confirmed safe to shrink, behavioural divergence analysis).
