# Module: pin-03-no-fallback-to-latest-version

**Requirement ID:** PIN-03
**Run ID:** WF02-batch-5-20260812 (Stage 16)
**Covers:** PIN-03
**Extends:** none (PIN-03 has no `Extends:` line in its body)
**See (from PIN-03's own body):** PIN-01 (produces the pin set this design enforces at
execution — RELEASED, scoped to AC3/AC4/AC5), PIN-02 (records the pin set into
`INSTANCE_STARTED` — RELEASED), PIN-05 (rebind — this batch's sibling design, not a dependency of
PIN-03's own enforcement logic), REPO-07 (service catalog), PLC-01 (module catalog — PENDING),
EE-05 (exclusive gateway — RELEASED, unrelated to this design's own node-execution path beyond
being a fellow EE-* engine module)

**Process document (read in full for this design):** `docs/processes/system/instance-version-
pinning.md` — steps 11–13 are this design's scope (step 14 is PIN-04, steps 15–17 are PIN-05).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No new table. `PinMissing` is a typed in-process error, not a persisted row; the
   dead-letter queue table (`dead_letter_queue`, per `dlq_store_mod` referenced in
   `src/engine/instance.zig`) already exists and already stores a reference name in its payload
   for other failure kinds (`SERVICE_TASK_FAILURE`) — PIN-03 AC4 ("lands in the dead-letter queue
   with the reference name in the payload") reuses that existing sink, adding no column. Rule 1
   does not match.
2. **Type A?** No new HTTP route. Rule 2 does not match.
3. **Type D / Type B?** No React Flow node, no admin page. Neither matches.
4. **Type E — yes.** This is a change to node-EXECUTION-time dependency lookup inside the engine
   kernel's existing retry/dead-letter machinery (`src/engine/instance.zig`'s `SERVICE_TASK`
   handling and its `error_type` taxonomy) — `templates/lego-catalog.md`'s own "What stays in Type
   E" list names "Engine kernel, transition logic, deterministic replay" explicitly. Per the
   catalog: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing

**PIN-03 is INDEPENDENTLY IMPLEMENTABLE for four of its five AC bullets against what PIN-01/PIN-02
already produce today.** Verified by reading the actual execution path, not assumed:

`src/engine/instance.zig`'s `SERVICE_TASK` handling (the loop starting at line ~3010, invoked from
inside the transition/completion machinery) resolves a node's service endpoint by calling
`service_task_mod.parseConfigFromNodeAttributes()` (`src/engine/service_task.zig`), which reads
`node.attributes` — the **raw snapshot node config**, pulled straight from `snapshot.nodes[]`
(the PD-08-pinned graph) — and, for a catalog-backed `service_id`, calls `resolveCatalogEndpoint()`
against a `service_catalog` object **embedded in the node's own attributes JSON**, not against the
live `service_catalog` table and NOT against PIN-01/PIN-02's `pinned_versions[]` array at all. This
confirms the exact gap PIN-03 exists to close: **today, nothing at execution time consults the
pin set.** The pin set is written (PIN-02, RELEASED) but never read back. This is a genuine,
independently-scoped implementation gap — not the ISS-0672 kind (it has nothing to do with
`service_catalog` lacking version columns; it is about missing READ-SIDE wiring against data that
already exists in full).

- **AC1** ("no pin entry -> `PinMissing`, no catalog lookup for the latest version occurs") is
  fully implementable: read `pinned_versions[]` from the reconstructed/current `InstanceState`
  (sourced from `INSTANCE_STARTED`, PIN-02) before calling `parseConfigFromNodeAttributes()`; a
  `SERVICE_TASK`/`SUB_PROCESS` node whose `service_id`/`module_ref` has no matching pin entry
  raises `PinMissing` and the existing catalog-lookup call is never reached — a straightforward
  guard inserted ahead of the existing call, not a new resolution mechanism.
- **AC2** ("a newer catalog entry version is published while in flight... it invokes the pinned
  version") is implementable **under this batch's inherited AC3/AC4/AC5-only scope of PIN-01**:
  because PIN-01's `resolveServiceCatalogRef()` already binds a specific `resolved_id`/`version`
  pair per pin (today, the degenerate `updated_at`-derived stopgap value — see PIN-01's Open
  questions §1), "invoking the pinned version" means resolving the endpoint using the CATALOG ROW
  identified by the pin's `resolved_id`, not a fresh unconditional re-lookup by `service_id` alone.
  This is testable today with the real `service_catalog` table (no version history needed to prove
  the ENGINE reads through the pin rather than re-resolving) — see Open questions §1 for the exact
  degenerate-scope caveat on what "newer... version" can mean without real version history.
- **AC4** ("retry budget exhausted -> dead-letter queue with the reference name in the payload") is
  implementable: `PinMissing` is a new member of `instance.zig`'s existing execution-error
  taxonomy (`ErrorType` enum, alongside `SERVICE_TASK_FAILURE`) and follows the SAME retry-then-
  dead-letter path every other execution error already takes (`dlq_store_mod`, referenced at
  `src/engine/instance.zig:3608`) — no new retry/DLQ mechanism, only a new named cause feeding the
  existing one.
- **AC5** ("no code path substitutes the current active version for a missing or unresolvable pin
  entry") is a NEGATIVE, cross-cutting assertion about AC1/AC2's implementation, not a separate
  resolution branch — it is satisfied by AC1/AC2's design as specified (the guard in front of
  `parseConfigFromNodeAttributes()` is unconditional; there is no fallback branch to omit) and is
  primarily a TEST-DESIGNER obligation (an integration test asserting the absence of a fallback
  path) rather than an independent design surface.
- **AC3** ("pinned catalog entry version is set to DEPRECATED after the instance started ->
  execution proceeds on the pinned version") **hits the ISS-0672/GH-306 wall directly.**
  `service_catalog` has no `status`/`version` column (confirmed again here by re-reading
  `migrations/049_repository_service_catalog.sql` — unchanged since PIN-01's design read it) — there
  is no `DEPRECATED` value to set on a catalog row, so this AC cannot be meaningfully tested or
  even literally coded against real schema today. **Flagged in Open questions §1 as a BLOCKING
  gap**, same as PIN-01 AC1. It is NOT silently skipped: Open questions §1 states the scoped
  substitute this design specifies instead (proving "the engine reads through the pin, not through
  a live re-lookup" using the two kinds that DO exist — `catalog_entry`'s degenerate stopgap and
  `variable_schema`'s content hash — as a structural stand-in for "retirement doesn't affect
  in-flight instances," without a literal DEPRECATED status to flip).

## Module purpose

At each node-execution step inside the existing `SERVICE_TASK`/`SUB_PROCESS` completion loop
(`src/engine/instance.zig`), before calling the existing catalog/module resolution helpers, look
up the node's reference (`service_id` for `SERVICE_TASK`, `module_ref` for `SUB_PROCESS`) against
the CURRENT instance's effective pin set (PIN-02's `pinned_versions[]`, later PIN-04's inherited-
and-rebound-aware effective set). A reference with no matching pin entry raises `PinMissing`
instead of proceeding to catalog/module lookup at all; a reference WITH a pin entry resolves
through the pinned `resolved_id`, never through a fresh unconstrained lookup. This closes the loop
PIN-01/PIN-02 opened: pins are now consulted, not merely recorded.

## Data flow diagram

```
SERVICE_TASK completion loop (src/engine/instance.zig, EXISTING — loop near line 3010)
        |
        v
Step 1 (PIN-03, NEW): before parseConfigFromNodeAttributes(), look up this node's
        |   reference (service_id / module_ref) in the CURRENT InstanceState's
        |   effective pin set (sourced from INSTANCE_STARTED.pinned_versions[],
        |   PIN-02 — and, once PIN-04 ships, the latest INSTANCE_PINS_REBOUND)
        |
        |-- no matching pin entry -> PinMissing (NEW ErrorType variant,
        |     alongside SERVICE_TASK_FAILURE), reference name in the error
        |     detail; enters the EXISTING retry-then-dead-letter path
        |     UNCHANGED (AC1, AC4) -- catalog lookup below is NEVER reached
        |
        |-- pin entry found -> proceed
        v
Step 2 (EXISTING, modified call site only): parseConfigFromNodeAttributes() /
        |   resolveCatalogEndpoint() resolve the endpoint using the PIN's
        |   resolved_id as the binding key, not a fresh service_id-only lookup
        |   (AC2 -- "invokes the pinned version"; AC3's literal DEPRECATED-flip
        |   scenario is BLOCKED, see Open questions §1)
        v
Step 3 (EXISTING, unmodified): HTTP call proceeds exactly as today
```

## Public interface

```zig
/// NEW member of instance.zig's execution ErrorType taxonomy (alongside the
/// existing SERVICE_TASK_FAILURE and friends) — see Error taxonomy below.
/// PinMissing carries the node id and the missing reference (service_id or
/// module_ref) in its error_detail, matching the existing
/// buildExecutionErrorPayload() convention every other execution error uses.
pub const ErrorType = enum {
    // ...existing variants unchanged...
    PIN_MISSING, // NEW
};

/// Looks up `ref` (a service_id or module_ref string) in `pins`, the current
/// instance's effective pin set. Returns the matching PinnedVersion or null.
/// Pure function — no I/O, no allocation beyond what pins/ref already own.
/// Called from the SERVICE_TASK/SUB_PROCESS completion loop immediately
/// before the existing parseConfigFromNodeAttributes()/module-resolution call.
fn findPinForRef(
    pins: []const pin_resolver_mod.PinnedVersion,
    kind: pin_resolver_mod.PinKind,
    ref: []const u8,
) ?pin_resolver_mod.PinnedVersion;
```

Reuses `pin_resolver_mod.PinnedVersion`/`PinKind` (PIN-01, unchanged) as the pin-set element type
— this design introduces no new pin representation, only a new READ of the existing one. The
"current instance's effective pin set" the loop reads from is, for this batch, PIN-02's
`pinned_versions[]` as parsed back out of the reconstructed `InstanceState` at the point node
execution runs (see Dependencies — the exact plumbing of "make `pinned_versions[]` available
inside the completion loop's InstanceState" is BACKEND-DEV's wiring choice: either carried as a
new `InstanceState` field populated during reconstruction, or re-queried directly from
`INSTANCE_STARTED`'s payload at the point the loop starts; this design does not mandate one over
the other, since both satisfy the AC text — see Open questions §2).

### `PinMissing` retry-then-dead-letter routing (AC4) — reuses the existing pattern

```zig
// Mirrors the EXISTING SERVICE_TASK_FAILURE handling in instance.zig (the
// buildExecutionErrorPayload()/error_type dispatch already there): PIN_MISSING
// is added as a new match arm in whatever switch/if-chain currently
// enumerates SERVICE_TASK_FAILURE and its siblings for retry-budget and
// dead-letter routing (dlq_store_mod.itemTypeToString() family). No new retry
// or DLQ mechanism -- PIN_MISSING is a new CAUSE feeding the SAME existing
// EFFECT.
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `PinMissing` | A `SERVICE_TASK`/`SUB_PROCESS` node's reference has no entry in the instance's effective pin set (PIN-03 AC1) | New `PIN_MISSING` `ErrorType` variant in `src/engine/instance.zig`'s existing execution-error taxonomy, feeding the existing retry-then-dead-letter path unchanged; reference name and node id in the error detail (AC1, AC4) |

No new HTTP-facing `problem*` constructor is required for PIN-03 itself: `PinMissing` is an
async/execution-time engine error (like `SERVICE_TASK_FAILURE`), not a synchronous request-handler
rejection — it surfaces on the instance's error/DLQ views, which already have a rendering path for
`error_type`/`affected_node`/`reason`, not through `src/api/errors.zig`'s `ProblemDetails` family
(that family is reserved for synchronous HTTP-response-time errors, per PIN-01's and PIN-02's own
use of it for their 422s — `PinMissing` has no HTTP request in flight when it is raised, since node
execution happens inside async instance advancement, not inside the original `POST
/api/v1/instances` request/response cycle).

## Dependencies

- Depends on: PIN-01 (`PinnedVersion`/`PinKind` types, RELEASED scoped to AC3/AC4/AC5), PIN-02
  (the `pinned_versions[]` payload this design reads, RELEASED), the EXISTING `SERVICE_TASK`
  completion loop and its `ErrorType`/DLQ routing in `src/engine/instance.zig` (this design adds a
  guard and a new `ErrorType` member to that existing machinery, it does not replace it).
- Must NOT depend on: PLC-01 (module catalog — AC2/AC3's `SUB_PROCESS`/`module_ref` analogue is
  structurally identical to the `SERVICE_TASK` case but has no catalog to resolve against yet,
  matching PIN-01's own module-branch scoping — a `module_ref` node with a pin entry present would
  still resolve via PIN-01's `UnresolvedModuleRef` path today, since PIN-01's module branch always
  fails under this batch's scope; this design's `PinMissing` guard only changes what happens when
  NO pin entry exists at all, it does not unblock module resolution itself), ISS-0672's
  `service_catalog` version/status gap for AC3's literal DEPRECATED scenario (see Scoping note).

## Open questions

1. **BLOCKING (same wall as PIN-01 AC1): PIN-03 AC3's literal DEPRECATED-status scenario cannot
   be coded or tested against real schema.** `service_catalog` has no `status` column (see Scoping
   note). This design's Data flow diagram Step 2 specifies "resolve through the pin's resolved_id,
   not a fresh lookup" as the STRUCTURAL guarantee AC2/AC3 both actually need ("execution proceeds
   on the pinned version" regardless of what happens to the catalog row afterward) — this
   guarantee is fully testable today using the `variable_schema`/`catalog_entry` (degenerate)
   kinds PIN-01 already resolves, by mutating the underlying row after instance start and asserting
   the ALREADY-PINNED instance still resolves the OLD `resolved_id`. What is NOT testable today is
   the specific trigger condition "set to DEPRECATED" as literal AC3 text describes it, because
   there is no DEPRECATED value anywhere in the schema. **Needs the same REQ-ANALYST/ORCH decision
   PIN-01 Open questions §1 already asked for** (add version/status columns vs. accept the
   degenerate single-version reading) — this design does not duplicate that open question, it
   inherits it, and notes that PIN-03 AC3 is the SECOND acceptance criterion (after PIN-01 AC1)
   blocked on the same missing schema concept.
2. **How the completion loop obtains the "current effective pin set."** This design specifies WHAT
   must be checked (`findPinForRef` against a `[]PinnedVersion`) but not HOW that slice reaches the
   `SERVICE_TASK`/`SUB_PROCESS` completion loop's call site — two wiring options exist: (a) extend
   `transition_mod.InstanceState` with a `pinned_versions: []PinnedVersion` field populated once at
   reconstruction/load time (touches `transition.zig`'s state shape, used by every transition call
   site, a wider blast radius), or (b) have the completion loop's caller (already holding the
   instance_id) query `INSTANCE_STARTED`'s stored payload directly at the point the loop starts (a
   narrower, more local change, but a redundant read on every node-execution step if the loop is
   invoked once per node rather than once per instance-advancement batch). BACKEND-DEV should
   confirm which against the completion loop's real call frequency; this design does not mandate
   one over the other since PIN-03's AC text is silent on the internal plumbing, only on the
   observable behavior (AC1/AC2/AC4/AC5), which either wiring satisfies identically.
3. **Whether `PinMissing` should also gate at instance-ADVANCEMENT entry (not just inside the
   `SERVICE_TASK`/`SUB_PROCESS` loop).** PIN-03's AC text is written in terms of "a node whose
   reference has no entry... WHEN the node executes" — this design scopes the guard to the two
   node types that currently carry versioned references (`SERVICE_TASK`, `SUB_PROCESS`), matching
   PIN-01's own enumeration scope (Step 2 of PIN-01's design). If a future node type gains a
   versioned reference kind, this guard's placement (immediately before the type-specific resolve
   call, not in a single central dispatcher) means each new node type must add its own
   `findPinForRef` call site — flagged here so BACKEND-DEV does not read this design as "the guard
   automatically covers new node types."
