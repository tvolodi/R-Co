# Module: pin-05-explicit-instance-pin-rebind

**Requirement ID:** PIN-05
**Run ID:** WF02-batch-5-20260812 (Stage 16)
**Covers:** PIN-05
**Extends:** none (PIN-05 has no `Extends:` line in its body)
**See (from PIN-05's own body):** PIN-02 (the pin set this design mutates — RELEASED), PIN-03
(execution-time enforcement — this batch's sibling design, reads the SAME effective pin set this
design's rebind writes into), PIN-04 (replay/read side — this batch's sibling design; PIN-04's
`mergeEffectivePins()` is defined against THIS design's `INSTANCE_PINS_REBOUND` payload shape),
PRM-08 (promotion rollback by version pointer move — DRAFT, unrelated write path explicitly
distinguished in Dependencies below), ADP-11 (replay-safe retention policy — RELEASED)

**Process document (read in full for this design):** `docs/processes/system/instance-version-
pinning.md` — steps 16–17 are this design's scope.

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No new table. `INSTANCE_PINS_REBOUND` is a new EVENT TYPE (a payload shape
   registered in `event_type_registry`, the same mechanism PIN-02 used to widen
   `INSTANCE_STARTED`'s schema — see `pin-02-pin-set-in-instance-started.md`'s own Classification
   rationale for why a registry-row content change is not `templates/specs/migration.template.yaml`'s
   target shape), not a table DDL change. Rule 1 does not match.
2. **Type A?** `POST /api/v1/instances/{id}/rebind-pins` is a new HTTP route, and it is tempting to
   read it as Type A (one POST, one store-ish write). It is disqualified by the catalog's own
   carve-out ("Skip if the handler needs custom business logic mid-flight — that is Type E"): the
   handler must (a) validate the instance is not terminal (409), (b) validate every named ref
   exists in the CURRENT effective pin set — which itself requires PIN-04's merge logic, not a
   single-table lookup — before applying ANYTHING (all-or-nothing, AC2), (c) validate a mandatory
   `reason` field is present (AC4), and (d) compute `prior_version`/`new_version` pairs per changed
   entry for the event payload — four independent validation/computation steps coordinated before
   a single write, not a 1-to-1 store-method mapping. Rule 2 does not match.
3. **Type D / Type B?** No React Flow node, no admin page. Neither matches.
4. **Type E — yes.** A new state-mutating operation on the engine kernel's event log with an
   all-or-nothing multi-entry validation gate and a terminal-state guard — the same class of
   engine-kernel change `templates/lego-catalog.md`'s "What stays in Type E" list already covers.
   Per the catalog: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing

**PIN-05 does NOT hit the ISS-0672/GH-306 wall for any of its five AC bullets.** Verified by
reading PIN-05's own AC text in full: none of its ACs require resolving a NEW `service_catalog`
version or a NEW `module_ref` — they require accepting an EXPLICIT, caller-supplied `{kind, ref,
version}` triple and recording it, the same shape PIN-01 AC4's `pin_overrides` already accepts and
validates (`applyPinOverrides()` in `src/engine/pin_resolver.zig`, read in full — it already
implements exactly this validate-and-replace pattern for `catalog_entry`/`variable_schema`, only at
instance-START time rather than on a running instance).

- **AC1** (valid rebind appends `INSTANCE_PINS_REBOUND` with `prior_version`/`new_version`/actor/
  reason per changed entry) is fully implementable: this is a NEW event append, structurally
  identical in shape to PIN-02's `INSTANCE_STARTED` append (same `INSERT INTO events` pattern
  `src/engine/instance.zig` already uses repeatedly — e.g. `SUBPROCESS_STARTED`,
  `SUBPROCESS_COMPLETED` at the call sites read in full above). No new resolution mechanism, only a
  new event type and a new HTTP route.
- **AC2** (`UnknownPinRef` -> 422, none applied) reuses PIN-01 AC4's EXACT validation shape
  (`applyPinOverrides()`'s "any override target not found -> abort entirely, no partial pin set"
  pattern) against the CURRENT effective pin set (PIN-04's merge) instead of the AT-START resolved
  set. Same all-or-nothing guarantee, different point in the instance lifecycle.
- **AC3** (`InstanceNotRebindable` on `COMPLETED`/`CANCELLED`/`FAILED`) is fully implementable: the
  instance's terminal-status check already exists as a pattern (`CompleteTaskError.InstanceNotActive`,
  read in full at `src/engine/instance.zig`'s `CompleteTaskError` set — "Parent instance is not
  ACTIVE... enforced inside the transaction via `SELECT FOR UPDATE`") — this design reuses that same
  locked-read-then-check pattern, only with PIN-05's own terminal-set (`COMPLETED`, `CANCELLED`,
  `FAILED` — note this is NOT identical to `CompleteTaskError`'s ACTIVE-only gate; PIN-05's gate is
  specifically the three PIN-05-named terminal statuses, see Error taxonomy).
- **AC4** (no `reason` field -> 422) is a synchronous request-body validation, no different in kind
  from any other required-field check already throughout `src/api/routes/*.zig`.
- **AC5** ("no scheduled job, catalog publication or definition promotion changes the pin set of a
  running instance") is a NEGATIVE, cross-cutting assertion — satisfied by this design specifying
  `rebind-pins` as the ONLY write path to `pinned_versions`'s effective value (no other code in
  this design, or in PIN-01/02/03/04's designs, writes `INSTANCE_PINS_REBOUND` or mutates
  `pinned_versions[]` after `INSTANCE_STARTED`) — primarily a TEST-DESIGNER/code-review obligation
  to confirm no OTHER call site does so, same shape as PIN-03 AC5/PIN-04 AC5.

**No AC of PIN-05 is flagged as an open question for missing infrastructure.** All five are
implementable against what PIN-01/PIN-02/PIN-04 (this batch's sibling design) already provide.

## Module purpose

A new state-mutating operation, `POST /api/v1/instances/{id}/rebind-pins`, that is the SOLE way an
instance's effective pin set changes after `INSTANCE_STARTED`. Takes explicit `{kind, ref,
version}` entries and a mandatory `reason`; validates every named ref exists in the instance's
CURRENT effective pin set (PIN-04's merge of `INSTANCE_STARTED` + prior `INSTANCE_PINS_REBOUND`
rows) and that the instance is not terminal; on success, appends `INSTANCE_PINS_REBOUND` carrying
`{ref, prior_version, new_version, actor, reason}` per changed entry, atomically and
all-or-nothing. No side table: like `INSTANCE_STARTED`, `INSTANCE_PINS_REBOUND` is a plain event
row, and PIN-04's reconstruction/merge logic (this batch's sibling design) is what makes its effect
visible to later reads and to PIN-03's execution-time enforcement.

## Data flow diagram

```
POST /api/v1/instances/{id}/rebind-pins  (NEW route)
        |
        v
Step 1 (PIN-05, NEW): validate request body -- entries[] non-empty, each
        |   {kind, ref, version} well-formed, reason non-empty (AC4)
        |   invalid -> 422 (generic problemUnprocessable, no new error variant
        |     needed -- this is ordinary request validation, not a named
        |     domain error per PIN-05's own AC text, which only names
        |     UnknownPinRef and InstanceNotRebindable as DOMAIN errors)
        v
Step 2 (PIN-05, NEW): acquire connection, BEGIN transaction, SELECT ... FOR
        |   UPDATE on instance_projections (reuses the SAME locked-read
        |   pattern CompleteTaskError's InstanceNotActive check already uses)
        |   status IN (COMPLETED, CANCELLED, FAILED) -> InstanceNotRebindable,
        |     ROLLBACK, 409 (AC3)
        v
Step 3 (PIN-05, NEW, depends on PIN-04's mergeEffectivePins()): compute the
        |   CURRENT effective pin set by replaying this instance's event log
        |   through PIN-04's merge logic (same function PIN-04's GET .../pins
        |   route and PIN-03's execution-time guard both call -- one merge
        |   implementation, three callers)
        v
Step 4 (PIN-05, NEW): for each requested entry, look up {kind, ref} in the
        |   effective set from Step 3
        |     not found -> UnknownPinRef, ROLLBACK, 422, none of the
        |       request's entries are applied (AC2, all-or-nothing)
        |     found -> record {ref, prior_version: effective.version,
        |       new_version: requested.version}
        v
Step 5 (PIN-05, NEW): append INSTANCE_PINS_REBOUND carrying every changed
        |   entry's {kind, ref, prior_version, new_version, actor, reason},
        |   IN THE SAME transaction as Step 2's row lock (AC1) -- COMMIT
        v
returned to caller: 200 with the new event's id and the changed entries;
PIN-04's reconstruction/merge (sibling design) picks up this NEW
INSTANCE_PINS_REBOUND row on the next read, exactly as it already does for
any other event type
```

## Public interface

```zig
pub const RebindError = error{
    /// A requested entry's {kind, ref} has no match in the instance's current
    /// effective pin set (PIN-05 AC2). HTTP 422. No entries from the request
    /// are applied.
    UnknownPinRef,
    /// Instance status is COMPLETED, CANCELLED or FAILED (PIN-05 AC3). HTTP 409.
    InstanceNotRebindable,
    /// instance_id not found at all. HTTP 404.
    InstanceNotFound,
    /// Request body fails validation: empty entries[], malformed entry, or
    /// missing/empty reason (PIN-05 AC4). HTTP 422.
    InvalidInput,
    /// SELECT FOR UPDATE NOWAIT blocked by a concurrent transaction, same
    /// convention as CompleteTaskError.ConcurrentModification. HTTP 409.
    ConcurrentModification,
    PoolExhausted,
    TransactionFailed,
};

pub const RebindEntry = struct {
    kind: pin_resolver_mod.PinKind,
    ref: []const u8,
    version: []const u8, // the NEW version requested
};

pub const RebindInput = struct {
    instance_id: Uuid,
    entries: []const RebindEntry,
    reason: []const u8,
    actor_id: []const u8,
};
```

```zig
/// One changed entry as recorded in INSTANCE_PINS_REBOUND -- this is the
/// exact per-entry shape PIN-04's RebindEventRow (its Public interface,
/// mergeEffectivePins()'s parameter type) reads back out of this event's
/// payload. The two designs' shapes MUST stay in lockstep -- this design is
/// the shape's source of truth since PIN-05 is the writer of the event.
pub const RebindChange = struct {
    kind: pin_resolver_mod.PinKind,
    ref: []const u8,
    prior_version: []const u8,
    new_version: []const u8,
};

/// Runs the full pipeline (Data flow Steps 1-5). Returns the changed entries
/// on success. Any RebindError means NO INSTANCE_PINS_REBOUND row is written
/// (AC2's "applies none of the entries" extends to every error variant here,
/// same all-or-nothing convention PIN-01's resolve() already established for
/// its own four error variants).
pub fn rebindPins(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    input: RebindInput,
) RebindError![]RebindChange;
```

### Terminal-status gate (Step 2) — reuses the existing locked-read pattern

```zig
// SELECT status FROM instance_projections WHERE instance_id = $1::uuid FOR
// UPDATE NOWAIT -- mirrors CompleteTaskError's own InstanceNotActive /
// ConcurrentModification handling (SQLSTATE 55P03 -> ConcurrentModification)
// read in full in instance.zig's existing CompleteTaskError-returning
// functions. status IN ('COMPLETED','CANCELLED','FAILED') -> InstanceNotRebindable.
// Note PIN-05's terminal set is NOT the same test as CompleteTaskError's
// InstanceNotActive (which rejects anything != ACTIVE, including a
// hypothetical PAUSED-like status if one existed) -- PIN-05 AC3 names exactly
// three statuses, so this design's gate checks those three explicitly rather
// than reusing an "is ACTIVE" boolean that might reject a status PIN-05's own
// AC text does not name as terminal.
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `UnknownPinRef` | A rebind entry's `{kind, ref}` is absent from the instance's current effective pin set (PIN-05 AC2) | New `problemUnknownPinRef(detail)` constructor in `src/api/errors.zig`, `type: .../problems/unknown-pin-ref`, HTTP 422, following the SAME pattern as PIN-01's four `problem*` constructors; `detail` names the ref |
| `InstanceNotRebindable` | Instance status is `COMPLETED`, `CANCELLED` or `FAILED` (PIN-05 AC3) | New `problemInstanceNotRebindable(detail)`, `.../problems/instance-not-rebindable`, HTTP 409 |
| `InvalidInput` (missing `reason`, malformed entries) | Request body fails validation (PIN-05 AC4) | Existing `problemUnprocessable(detail)` — generic request-shape validation, no new named error needed since PIN-05's own AC4 text does not name a distinct error code for this case (only "HTTP 422", unlike AC2/AC3 which both name specific codes) |
| `InstanceNotFound` | `instance_id` path parameter names no instance | Existing `problemNotFound(detail)`, HTTP 404 |
| `ConcurrentModification` | `FOR UPDATE NOWAIT` blocked by a concurrent transaction on the same instance | Existing pattern (matches `CompleteTaskError.ConcurrentModification`), HTTP 409 |

## Dependencies

- Depends on: PIN-01 (`PinnedVersion`/`PinKind` types, and `applyPinOverrides()`'s
  validate-and-replace pattern as the structural precedent this design's Step 4 mirrors — RELEASED
  scoped to AC3/AC4/AC5), PIN-02 (`INSTANCE_STARTED`'s `pinned_versions[]`, the base set PIN-04's
  merge starts from — RELEASED), PIN-04 (this batch's sibling design — `rebindPins()`'s Step 3
  cannot be implemented before `mergeEffectivePins()` exists; the two designs are produced
  together in this batch specifically so BACKEND-DEV can implement them in the correct order — see
  PIN-04's own design for the merge function's signature), the EXISTING terminal-status /
  `FOR UPDATE NOWAIT` locking pattern in `src/engine/instance.zig`'s `CompleteTaskError`-returning
  functions.
- Must NOT depend on: PRM-08 (promotion rollback by version pointer move — a DIFFERENT write path
  that moves a TENANT-WIDE active-version pointer, never touches any individual instance's pin set;
  the process document's own Business Rule "Rebind is explicit... no automatic upgrade of a running
  instance" is precisely the boundary PRM-08 must not cross, and this design does not wire any
  promotion-triggered call into `rebindPins()`), PLC-01 (a rebind entry naming `kind: module` is
  handled by the SAME `UnknownPinRef` path as any other kind — under this batch's scope, a `module`
  ref is never present in ANY instance's effective pin set in the first place, since PIN-01's
  module branch never resolves one, so a `module`-kind rebind request always hits `UnknownPinRef`
  today; this is a consequence of PIN-01's existing scope, not a new gap this design introduces).

## Open questions

1. **Whether `rebindPins()` acquires its own connection/transaction or is expected to compose with
   a caller-held one.** Unlike PIN-01's `resolve()` (which deliberately takes an already-open
   `*db.Conn` because it runs INSIDE `InstanceStore.create()`'s larger transaction, per PIN-01's own
   Open questions §3), `rebindPins()` is the top-level operation for its own HTTP request — no
   larger transaction already exists around it. This design's `Public interface` therefore has
   `rebindPins()` acquire and manage its own connection/transaction internally (Data flow Step 2's
   `BEGIN`/Step 5's `COMMIT`), matching the shape of other top-level engine operations like
   `CancelInstanceError`'s functions rather than PIN-01's callee-composed shape. Flagged only so
   BACKEND-DEV does not default to PIN-01's shared-connection pattern by copy-paste habit — the two
   operations sit at different points in the call graph.
2. **Idempotency of a repeated identical rebind request.** PIN-05's AC text does not mention
   idempotency (no idempotency-key input, unlike `InstanceStore.create()`'s existing
   `idem_key_hex`/`idempotency_key` column pattern). This design does not add one: a second
   identical `rebind-pins` call with the SAME `{kind, ref, version}` entries would compute
   `prior_version == new_version` for each (since the first call already moved the effective
   version) and append a SECOND `INSTANCE_PINS_REBOUND` row recording a no-op change with a
   duplicate reason — harmless (the effective set is unchanged) but produces a slightly noisy audit
   trail (two rebind events for one logical action) if a caller retries after a network timeout
   without an idempotency key. Not blocking (PIN-05's own AC text does not require one), but worth
   REQ-ANALYST awareness if PRM-08-style idempotency-key conventions are expected to extend here
   later.
