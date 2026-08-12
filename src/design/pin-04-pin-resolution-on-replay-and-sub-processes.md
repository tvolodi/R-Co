# Module: pin-04-pin-resolution-on-replay-and-sub-processes

**Requirement ID:** PIN-04
**Run ID:** WF02-batch-5-20260812 (Stage 16)
**Covers:** PIN-04
**Extends:** none (PIN-04 has no `Extends:` line in its body)
**See (from PIN-04's own body):** PIN-02 (writes `pinned_versions[]` into `INSTANCE_STARTED` —
RELEASED, this design's read source), PIN-03 (execution-time enforcement — this batch's sibling
design, reads the same effective-pin-set concept this design defines), PIN-05 (rebind — this
batch's sibling design, writes `INSTANCE_PINS_REBOUND`, the SECOND event this design's replay/read
logic must consult), IR-07 (archived partitions remain queryable — RELEASED), XC-05 (deterministic
replay — RELEASED, the existing guarantee this design extends to cover pins), PLC-01 (module
catalog — PENDING, referenced only because a `module` pin's inheritance follows the same shape as
`catalog_entry`'s, not because this design needs PLC-01 itself)

**Process document (read in full for this design):** `docs/processes/system/instance-version-
pinning.md` — step 8 (child inheritance, cross-referenced from PIN-01's step 3-7 flow), step 14
(reconstruction reads pins from the event log), step 15 (`GET .../pins`) are this design's scope.

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No new table. The "effective pin set" is derived by reading two existing event
   types' payloads (`INSTANCE_STARTED.pinned_versions[]`, PIN-02; `INSTANCE_PINS_REBOUND`, PIN-05's
   sibling design in this same batch) — no side table, per the process document's own Business
   Rule ("Pins live in the event log... not a side table"). Rule 1 does not match.
2. **Type A?** `GET /api/v1/instances/{id}/pins` is a new HTTP route, and ON ITS OWN it might look
   like a Type A candidate (a single GET mapping onto a read). It is disqualified from Type A by
   the catalog's own carve-out ("Skip if the handler needs custom business logic mid-flight — that
   is Type E"): serving this route requires (a) reconstructing the effective pin set by walking TWO
   event types in the right precedence order (latest `INSTANCE_PINS_REBOUND` entry per ref, falling
   back to `INSTANCE_STARTED` for any ref never rebound), not a single-table SELECT, and (b)
   attaching the SOURCE EVENT ID per entry (AC4's exact text), which requires carrying event
   provenance through the merge — genuine mid-flight business logic, not a store-method passthrough.
   Rule 2 does not match; this stays with the Type E logic below, but the HTTP route itself is a
   thin wrapper this design specifies in the Public interface.
3. **Type D / Type B?** No React Flow node, no admin page. Neither matches.
4. **Type E — yes.** Multi-event-type merge logic with source-provenance tracking, plus a change to
   the engine kernel's reconstruction path (`src/engine/reconstruction.zig`, explicitly named in
   `templates/lego-catalog.md`'s "What stays in Type E" list under "deterministic replay") and to
   sub-process child instantiation (`startSubProcessesForPendingEventsInTx` in
   `src/engine/instance.zig`). Per the catalog: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing

**PIN-04 does NOT hit the ISS-0672/GH-306 wall.** Verified by reading PIN-04's own AC text in full
against what exists: none of its five AC bullets mention `service_catalog` version/status
resolution or PLC-01 module-catalog resolution AT ALL — every AC bullet is about **reading back**
already-resolved, already-persisted data (`INSTANCE_STARTED.pinned_versions[]`, which PIN-02
shipped RELEASED) rather than resolving anything new. This is confirmed by reading
`src/engine/reconstruction.zig`'s `reconstructInstance()` in full: it already replays the full
ordered event log through the pure `transition()` function and already fetches
`instance_definition_snapshots` (PD-08) as its one external read — extending it to also surface
`pinned_versions[]` out of the SAME already-fetched `INSTANCE_STARTED` event row requires no new
catalog/module infrastructure, only a new field carried through the existing replay.

- **AC1** ("reconstructed dependency versions equal `INSTANCE_STARTED`'s recorded versions") is
  fully implementable: `reconstructInstance()` already reads every event row for the instance in
  order; `INSTANCE_STARTED`'s payload (which PIN-02 already embeds `pinned_versions[]` into) is
  ALREADY one of those rows. No new query.
- **AC2/AC3** (child inheritance, conflict recording) require new logic in
  `startSubProcessesForPendingEventsInTx()` (confirmed by reading it in full — it currently writes
  `subprocess_links` and a `SUBPROCESS_STARTED` event, but has no pin-inheritance step at all) —
  genuinely new work, but work that reads/writes ONLY `catalog_entry`/`variable_schema` pin kinds
  the SAME way PIN-01/PIN-02 already do; nothing about "inherit the parent's `PinnedVersion` slice
  into the child's own `INSTANCE_STARTED` payload" requires resolving a NEW reference kind.
  `module`-kind inheritance follows the identical code path but will always find zero `module` pins
  to inherit under this batch's scope (PIN-01's module branch never resolves — see PIN-01's design)
  — this does not block AC2/AC3's own text, since a child with no parent `module` pins to inherit
  still satisfies "adds pins only for refs the parent's set does not carry" trivially (there is
  nothing to conflict with).
- **AC4** (`GET .../pins` returns source event ID per entry) is fully implementable: both
  `INSTANCE_STARTED` and `INSTANCE_PINS_REBOUND` rows already have a primary-key event identity in
  the `events` table (confirmed via `src/engine/instance.zig`'s existing `INSERT INTO events...
  RETURNING`-style patterns used throughout) — attaching that id to each merged pin entry is a
  bookkeeping change to the merge step, not a new resolution.
- **AC5** ("reconstruction issues no read against the service catalog or module registry") is a
  NEGATIVE assertion about AC1's implementation (same shape as PIN-03 AC5) — satisfied by AC1's
  design as specified, since `reconstructInstance()` never calls `PinResolver.resolve()` at all
  (only the ORIGINAL instance-start path does, per PIN-01) — this is a TEST-DESIGNER obligation
  (assert absence of any `service_catalog`/`process_module_catalog` query during a reconstruction
  call) as much as a design one.

**No AC of PIN-04 is flagged as an open question for missing infrastructure.** All five are
implementable against what PIN-01/PIN-02/PD-08/`reconstruction.zig` already provide. The Open
questions section below covers genuine implementation-shape ambiguities in PIN-04's own text, not
infrastructure gaps.

## Module purpose

Two extensions to existing machinery, both reading exclusively from the event log:

1. **Reconstruction** (`src/engine/reconstruction.zig`): surface `pinned_versions[]` (merged with
   any `INSTANCE_PINS_REBOUND` overrides, latest-wins per ref) as part of `reconstructInstance()`'s
   output, so any caller reconstructing state — including replay-triggered re-execution — has the
   SAME effective pin set the original execution had, with no live catalog read.
2. **Sub-process child pin inheritance** (`src/engine/instance.zig`,
   `startSubProcessesForPendingEventsInTx()`): when a child instance starts via `parent_instance_id`
   (already-existing sub-process machinery, `subprocess_links`), the child's `PinResolver.resolve()`
   call (PIN-01, already wired at `InstanceStore.create()`'s Step d.5) is followed by an inheritance
   merge — for every ref the PARENT's pin set carries, the child's own resolved entry (if any) is
   REPLACED by the parent's, with `source = inherited`; if the child's independently-resolved
   version for that ref differs from the parent's, the conflict is recorded in the child's own
   `INSTANCE_STARTED` payload (AC3) rather than silently overwritten with no record.

A third, thinner piece: `GET /api/v1/instances/{id}/pins`, a new read-only endpoint returning the
merged effective set with source event IDs (AC4) — specified in Public interface below, backed
entirely by the reconstruction/merge logic above (it does not duplicate the merge).

## Data flow diagram

```
Reconstruction path (src/engine/reconstruction.zig, EXISTING reconstructInstance() — extended)
        |
        v
Step 1 (EXISTING, unmodified): fetch instance_definition_snapshots (PD-08)
        |
        v
Step 2 (EXISTING, unmodified): query the full ordered event log for instance_id
        |
        v
Step 3 (PIN-04, NEW): as the replay loop already walks each event row in order
        |   (it must, to feed transition() -- EXISTING), ALSO:
        |     - on an INSTANCE_STARTED row: capture its pinned_versions[] as the
        |       base effective set, tagged with THIS row's event id
        |     - on an INSTANCE_PINS_REBOUND row (PIN-05's sibling design --
        |       written by this batch): for each changed entry, replace the
        |       base set's matching {kind,ref} entry's version/resolved_id,
        |       tagged with THIS REBOUND row's event id (last INSTANCE_PINS_REBOUND
        |       per ref wins -- there is at most one "current" version per ref)
        |   no NEW query is added -- both event types are already rows in the
        |   SAME event-log SELECT reconstructInstance() already runs (AC5)
        v
Step 4 (PIN-04, NEW): reconstructInstance() returns the merged effective pin set
        |   alongside the existing InstanceState -- exact return-shape wiring is
        |   Open questions §1
        v
Consumers: PIN-03 (execution-time PinMissing guard, this batch's sibling design,
        reads the merged set) and GET /api/v1/instances/{id}/pins (NEW route,
        thin read of the SAME merged set, AC4)
```

```
Sub-process child inheritance (src/engine/instance.zig, EXISTING
startSubProcessesForPendingEventsInTx() -- extended)
        |
        v
Step 1 (EXISTING, unmodified): child instance created via the normal
        |   InstanceStore.create() path, parent_instance_id threaded through
        |   (subprocess_links row written, per EXISTING code read in full)
        v
Step 2 (EXISTING, unmodified, PIN-01 already wired): child's OWN
        |   PinResolver.resolve() runs against the child's OWN definition graph,
        |   producing the child's independently-resolved pin set
        v
Step 3 (PIN-04, NEW): merge parent's effective pin set (Step 3 above, read via
        |   parent_instance_id) into the child's resolved set:
        |     - ref present in parent's set -> child's entry (if any) is
        |       REPLACED with the parent's {resolved_id, version}, source =
        |       inherited (AC2)
        |     - child's independently-resolved version for that ref differed
        |       from the parent's -> conflict recorded in the child's OWN
        |       INSTANCE_STARTED payload (a new field alongside pinned_versions[],
        |       see Open questions §2) (AC3)
        |     - ref absent from parent's set -> child's own resolution stands,
        |       source = resolved (unchanged from PIN-01's existing behavior)
        v
Step 4 (EXISTING, unmodified): child's INSTANCE_STARTED is appended carrying
        the MERGED pinned_versions[] (PIN-02's existing serialisePinnedVersions()
        call site, fed the merged slice instead of the raw resolved one)
```

## Public interface

```zig
/// A pin entry merged with its source event id -- the shape GET .../pins
/// (AC4) and PIN-03's execution-time lookup both consume. Extends
/// pin_resolver_mod.PinnedVersion (PIN-01, unchanged) with provenance.
pub const EffectivePin = struct {
    pin: pin_resolver_mod.PinnedVersion,
    /// The events.id (or equivalent stable identifier) of the INSTANCE_STARTED
    /// or INSTANCE_PINS_REBOUND row this entry's CURRENT version came from.
    source_event_id: []const u8,
};

/// Merges an INSTANCE_STARTED base set with zero or more INSTANCE_PINS_REBOUND
/// overlays (in event order), producing the effective set with per-entry
/// provenance. Pure function -- no I/O; reconstructInstance() feeds it rows
/// already fetched by its existing event-log query (Data flow Step 3).
pub fn mergeEffectivePins(
    allocator: std.mem.Allocator,
    started_pins: []const pin_resolver_mod.PinnedVersion,
    started_event_id: []const u8,
    rebind_events: []const RebindEventRow, // ordered oldest -> newest; PIN-05's sibling design defines RebindEventRow's shape
) error{OutOfMemory}![]EffectivePin;
```

```zig
/// GET /api/v1/instances/{id}/pins handler shape (AC4). Thin: calls
/// reconstructInstance() (extended per Data flow Step 4) and serialises its
/// EffectivePin slice. No independent query -- the merge logic lives in
/// mergeEffectivePins() above, reused by both this route and PIN-03's
/// execution-time lookup, so the two never disagree on "what is the
/// effective pin set right now."
pub fn handleGetInstancePins(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    instance_id: []const u8,
) HandlerResult; // 200 with []EffectivePin, or 404 if instance_id not found
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `InstanceNotFound` | `GET .../pins` names an `instance_id` with no event log at all | Reuses `reconstruction.zig`'s EXISTING `ReconstructionError.InstanceNotFound`, HTTP 404 — no new error variant |

PIN-04 introduces no NEW error variant of its own: reconstruction failures (`PoolExhausted`,
`QueryFailed`, `ReplayFailed`) are all already members of `reconstruction.zig`'s existing
`ReconstructionError` set and apply unchanged to the extended reconstruction path. Sub-process
inheritance conflicts (AC3) are explicitly NOT an error — the process document's step 8 and PIN-04
AC3 both specify the inherited pin wins and the conflict is RECORDED, not rejected; there is no
`PinInheritanceConflict`-shaped error to raise.

## Dependencies

- Depends on: PIN-01 (`PinnedVersion`/`PinKind` types and the child's own `resolve()` call, RELEASED
  scoped to AC3/AC4/AC5), PIN-02 (`pinned_versions[]` inside `INSTANCE_STARTED`, RELEASED), PIN-05
  (this batch's sibling design — `INSTANCE_PINS_REBOUND`'s exact payload shape, which
  `mergeEffectivePins()`'s `RebindEventRow` parameter is defined against; PIN-04's merge logic
  cannot be implemented before PIN-05's event shape is fixed, though the two are designed together
  in this same batch so this is a design-time ordering note, not a scope gap), the EXISTING
  `reconstruction.zig`/`startSubProcessesForPendingEventsInTx()` machinery this design extends.
- Must NOT depend on: PLC-01 (see Scoping note — `module`-kind inheritance is structurally
  identical to `catalog_entry`'s and needs no PLC-01 infrastructure to be CORRECT, only to ever
  have a non-empty `module` pin to inherit, which is PIN-01's own limitation, not PIN-04's), live
  `service_catalog`/`process_module_catalog` reads during reconstruction (AC5's explicit negative
  requirement — this design's Data flow diagram confirms no such read is introduced).

## Open questions

1. **Return-shape wiring: does `reconstructInstance()` grow a new return field, or does the merge
   live in a separate function callers opt into?** `reconstruction.zig`'s `InstanceState` return
   type (from `transition_mod`) has no `pinned_versions`/`effective_pins` field today. Two options:
   (a) widen `reconstructInstance()`'s return type or add an out-parameter carrying
   `[]EffectivePin` (touches every existing caller of `reconstructInstance()`, a wider blast
   radius, but keeps "reconstruct state" and "know the pins" atomic — no risk of the two drifting
   apart across two separate calls against a event log that could theoretically advance between
   them), or (b) a new sibling function (`reconstructEffectivePins()`) that repeats ONLY the
   event-log walk needed for the merge, called independently by `GET .../pins` and by PIN-03's
   execution-time guard (simpler per-call-site diff, but two callers reading the same event log
   twice for related purposes, and a narrow window where the two could observe different states
   under concurrent `INSTANCE_PINS_REBOUND` appends). This design specifies the MERGE LOGIC
   (`mergeEffectivePins()`) either wiring reuses identically — BACKEND-DEV should pick based on
   `reconstructInstance()`'s actual call-site fan-out (not read in full for this design, since
   PIN-04's own AC text does not require one wiring over the other).
2. **Where the child's inheritance-conflict record lives inside `INSTANCE_STARTED`'s payload.**
   PIN-04 AC3 says "the conflict is recorded in the child's `INSTANCE_STARTED` payload" but does
   not specify a field name or shape. This design proposes a sibling array,
   `"pin_inheritance_conflicts": [{kind, ref, child_resolved_version, parent_version}]`, appended
   alongside the EXISTING `pinned_versions` field (PIN-02) in the same `start_payload_json`
   construction — empty array when no conflicts occurred, so existing consumers of
   `INSTANCE_STARTED`'s payload that do not know about this field are unaffected (an empty array is
   backward-compatible with any consumer that ignores unknown fields, which every current
   JSON-based consumer in this codebase already does per the pattern PIN-02 itself established).
   REQ-ANALYST confirmation is not strictly blocking (this is an implementation-shape choice within
   AC3's stated behavior, not a missing capability), but the field name itself is worth confirming
   before BACKEND-DEV commits to it, since `INSTANCE_STARTED`'s payload shape, once shipped, is
   effectively permanent (event-sourced platforms cannot rewrite historical event payloads).
3. **`PLC-01`'s eventual `module`-kind pin shape is not designed here.** This design's inheritance
   merge (Data flow, sub-process diagram Step 3) treats `catalog_entry`/`variable_schema`/`module`
   uniformly by `{kind, ref}` matching — nothing PLC-01-specific is assumed. When PLC-01 ships and
   PIN-01's module branch starts producing real `module` pins, this design's merge logic requires
   NO change; flagged here only so a future reader does not mistake PIN-04's silence on PLC-01 for
   an oversight rather than a deliberate kind-agnostic design.
