# Module: vld-04-validation-gate-authoring-promotion

**Requirement ID:** VLD-04
**Run ID:** WF02-batch-7-20260816 (Stage 16)
**Type:** Type E (gating orchestration) + Type C (`process_definitions` verdict columns
migration)
**Extends:** the Stage 16 semantic-validation family (`src/validation/mod.zig`,
`src/validation/env.zig`, `scope.zig`, `site.zig`, `pd06.zig`, `typecheck.zig`,
`finding.zig`, `wire.zig`, designed in `src/design/vld-01-03-stage-16-validation.md` and
shipped for VLD-01/02/03). That design explicitly reserved VLD-04 as "a separate handoff
— owns the gate at draft save / promotion submit, the `semantically_valid` verdict
storage, the 5-second budget, and the compiler-version invalidation; VLD-01/02/03 must
not depend on VLD-04's storage path." It also defined the two consumables this design
uses verbatim: `validateDefinition(allocator, input) -> ValidationFailure` and the
`COMPILER_VERSION` constant.
**Authoritative process source:** `docs/processes/system/definition-semantic-validation.md`
(`sys-definition-semantic-validation`, PW-02) — steps 1, 11, 12, 13 and the Business Rules
(Both gates are hard, Verdict is compiler-bound) plus the SLAs table (Compilation budget
5 s; `422 ValidationTimeout`) fully specify the gate. `docs/processes/system/
definition-promotion.md` (PW-01) step 2 locates the promotion gate "before the PRM-01
plan is computed."
**See also:** PRM-01 (`src/design/prm-01-promotion-plan-and-diff-report.md` — the plan
computation this gate precedes), PD-06 / PD-02 (the syntax/structure gates that run
before semantics), EE-05 (runtime evaluation — unaffected by this gate), VLD-02 (the
`422 ValidationTimeout` response shares the VLD-03 finding-wire shape).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C — yes, for the schema.** VLD-04 must "record[] a `semantically_valid` verdict
   on the definition version together with the CEL compiler version that produced it."
   `process_definitions` (migration 004) has no such columns today. One Type C migration
   YAML (`templates/specs/vld-04-definition-semantic-verdict.migration.yaml`) adds the
   verdict columns.
2. **Type E — yes, for the gate.** The gating orchestration (draft save, `/validate`,
   promotion submit), the 5-second budget enforcement, the compiler-version invalidation
   rule, and the verdict/event recording are genuinely novel cross-cutting logic —
   lego-catalog.md's "cross-module orchestration" bucket. The `/validate` endpoint was
   already reclassified away from Type A by the VLD-01/02/03 design ("handler needs
   multi-step orchestration ... does not fit a single `// CUSTOM:` block"); VLD-04's
   gate is the same reasoning applied to three call sites.

So this batch produces: **1 Type C migration YAML + 1 Type E design document** (this file).

## Existing pattern found and followed

Per the handoff's instruction to ground every design in a prior pattern:

| Aspect | Precedent | VLD-04 (this design) |
|---|---|---|
| Semantic validation pipeline | `src/validation/mod.zig::validateDefinition` (VLD-01/02/03) — pure function returning `ValidationFailure` with `findings` + `compiler_version` | Followed verbatim: this design is the gate **around** that pure function; it does not re-run type checking |
| Verdict versioning | `validation/mod.zig::COMPILER_VERSION` constant (bumped on every behaviour-affecting change) | Followed: stored verdicts compare against this constant; a mismatch forces re-verification (AC3) |
| Definition version persistence | `src/definition/store.zig` (`process_definitions` row, version/status fields) | Extended: the verdict columns live on the same row the version is stored on |
| Promotion gate | `src/definition/promotion.zig::promoteDefinition` and PRM-01's plan computation (process doc step 2) | Followed: the gate runs before the plan is computed; a failing gate returns 422 and creates no plan and no review row (AC2) |
| Compilation budget | `src/engine`'s existing timeout/budget discipline (bounded computation) | Followed: a deadline threaded through the site-compile loop; expiry returns `ValidationTimeout` naming compiled sites (AC4) |
| Event append | `event_type_registry` seed (migration 1152, `ON CONFLICT (name, schema_version) DO NOTHING`) + the `DEFINITION_*` event family | Followed: `DEFINITION_VALIDATED` / `DEFINITION_VALIDATION_FAILED` must be seeded in the registry (see Open questions §1) |

## Module purpose

`src/validation/gate.zig` (new) wraps VLD-01/02/03's pure `validateDefinition` into the
three hard gates VLD-04 names — definition draft save, `POST
/api/v1/definitions/{id}/validate`, and promotion submit before the PRM-01 plan is
computed — and owns the verdict lifecycle: a clean pass records `semantically_valid =
true` plus the `COMPILER_VERSION` that produced it on the definition version; any finding
leaves the version not semantically valid and (at the gating call sites) returns HTTP 422;
a stored verdict produced by a different compiler version is re-verified rather than
trusted; compilation is bounded at 5 seconds per definition. It also emits the two
verdict events: `DEFINITION_VALIDATED` on a clean pass and `DEFINITION_VALIDATION_FAILED`
carrying the finding count otherwise.

The module is deliberately a thin orchestration layer over `validateDefinition`: all
finding semantics (error kinds, ordering, message formats) remain in the VLD-01/02/03
modules this design does not modify.

## Public interface

### `src/validation/gate.zig` — the gate wrapper

```zig
/// Re-export of the VLD-01/02/03 constant this design's invalidation rule reads.
pub const COMPILER_VERSION: []const u8 = validation_mod.COMPILER_VERSION;

/// The verdict stored on the definition version (mirrors the Type C columns).
pub const SemanticVerdict = struct {
    semantically_valid: bool,
    compiler_version: ?[]const u8, // null when never validated (or verdict stale)
    validated_at: ?[]const u8,     // ISO-8601 UTC
    finding_count: u32,
};

/// Gate outcome returned to the calling handler. `findings` is borrowed from the
/// ValidationFailure when invalid; the caller owns the failure.
pub const GateResult = union(enum) {
    valid: SemanticVerdict,
    invalid: struct {
        verdict: SemanticVerdict,
        findings: []const finding.Finding, // VLD-03 error-kind list
        pd06_diagnostics: ?[]const pd06.Pd06Diagnostic,
    },
    timeout: struct {
        sites_compiled: u32, // AC4: sites compiled before expiry
        compiled_sites: [][]const u8, // node_id + expression_path of each
    },
};

pub const GateError = error{
    ValidationTimeout,    // AC4 — 5 s budget expired; caller maps to HTTP 422
    DefinitionNotFound,   // 404 at the gating call site
    VerdictWriteFailed,   // the verdict row update failed
    EventAppendFailed,    // DEFINITION_VALIDATED / DEFINITION_VALIDATION_FAILED append failed
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

The three gating call sites share one function; the promotion site differs only in that a
failure must also guarantee no plan and no `promotion_reviews` row (AC2 — guaranteed by
ordering the gate before plan computation, not by a rollback after).

```zig
/// Run the semantic gate for one definition version. Fetches the four env sources
/// (variable_schema, service catalog refs, module refs, form schemas — the same
/// fetch the VLD-01/02/03 handler performs), calls validateDefinition under a 5 s
/// deadline, records the verdict on the definition version, and appends the verdict
/// event. Used by draft save, /validate, and promotion submit.
pub fn runSemanticGate(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    definition_id: []const u8,
    budget_ms: u64 = 5_000,      // AC4 default; the process doc's Compilation budget
    check_stored_first: bool = true, // AC3: false to force re-verification
) GateError!GateResult;

/// AC3 — return true only when the stored verdict's compiler_version equals the
/// current COMPILER_VERSION (a match means the verdict is trustworthy and may be
/// used without re-running compilation). A different or null version means
/// re-verify. Called by runSemanticGate before deciding whether to recompile.
pub fn storedVerdictIsCurrent(
    allocator: std.mem.Allocator,
    conn: anytype,
    definition_id: []const u8,
) GateError!bool;

/// Write the SemanticVerdict onto the definition version row and append the verdict
/// event (DEFINITION_VALIDATED / DEFINITION_VALIDATION_FAILED with finding_count) in
/// the same transaction.
pub fn persistVerdict(
    allocator: std.mem.Allocator,
    conn: anytype,
    definition_id: []const u8,
    verdict: SemanticVerdict,
) GateError!void;
```

### The three gating call sites (contracts; the handlers already exist)

| Call site | Existing handler | Gate placement |
|---|---|---|
| Draft save | `PUT /api/v1/definitions/{id}` (definition store save path, `src/definition/store.zig`) | After the PD-02/PD-06 structural passes (process step 2), before the version is persisted as valid; any finding -> 422, version not marked `semantically_valid` (AC1) |
| Validate endpoint | `POST /api/v1/definitions/{id}/validate` | Directly returns the `GateResult` — 200 `semantically_valid` or 422 (VLD-03 body), `ValidationTimeout` -> 422 (AC4) |
| Promotion submit | `POST /api/v1/promotions` (PRM-01 plan computation, `src/definition/promotion.zig`) | **Before** the plan is computed (process doc step 13 / PW-01 step 2); any finding or stale verdict -> 422, no plan, no `promotion_reviews` row (AC2/AC3) |

### `process_definitions` verdict columns (Type C — see the migration YAML)

```zig
// process_definitions gains (all added IF NOT EXISTS, per schema pass):
//   semantically_valid       boolean NOT NULL DEFAULT false
//   compiler_version         text          NULL   -- null = never validated / stale
//   validated_at             timestamptz   NULL
//   validation_finding_count integer NOT NULL DEFAULT 0
```

## Data flow

```
Draft save / /validate / promotion submit
        |
        v
gate.runSemanticGate(definition_id, budget_ms=5000, check_stored_first)
  |
  |-- [AC3] storedVerdictIsCurrent(definition_id)?
  |      compiler_version == COMPILER_VERSION ?  yes -> reuse stored verdict
  |      (different/null)                      no  -> re-verify (AC3)
  |
  |-- fetch 4 env sources -> validateDefinition(...) under 5 s deadline
  |      |  budget expired -> GateResult.timeout{sites_compiled} -> 422 ValidationTimeout (AC4)
  |      v
  |   ValidationFailure { findings, pd06_diagnostics, compiler_version }
  |      |  any finding -> verdict{semantically_valid:false, finding_count}
  |      |                persistVerdict (1 txn: row + DEFINITION_VALIDATION_FAILED)
  |      |                -> 422 at all three call sites (AC1/AC2)
  |      |  clean       -> verdict{semantically_valid:true, compiler_version}
  |      |                persistVerdict (1 txn: row + DEFINITION_VALIDATED) (AC5)
  |      v
  +--> GateResult.valid  (draft save persists; /validate returns 200;
                          promotion proceeds to compute the PRM-01 plan)
```

## Error taxonomy

```zig
pub const GateError = error{
    ValidationTimeout,   // AC4 — 5 s budget expired; caller maps to 422 ValidationTimeout
    DefinitionNotFound,  // 404 at the gating call site
    VerdictWriteFailed,  // the verdict row update failed
    EventAppendFailed,   // the verdict event append failed
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

The VLD-01/02/03 error kinds (`UnknownVariable`, `TypeMismatch`, `OperandTypeError`,
`UnknownVariableType`, `UndeclaredResultSchema`, `ConflictingFieldType`,
`EmptyExpression`) are **not** GateError members — they flow through the `invalid`
branch of `GateResult` as the VLD-03 finding list, and the handler serialises them into
the same 422 body VLD-03 already produces. `ValidationTimeout` is the only new HTTP-facing
error this module introduces, and the requirement names it explicitly (AC4).

## State transitions

`process_definitions` verdict columns per version:

```
never validated      -> semantically_valid = false, compiler_version = NULL
clean pass           -> semantically_valid = true,  compiler_version = CURRENT
any finding          -> semantically_valid = false, compiler_version = CURRENT,
                        validation_finding_count = n
compiler release     -> compiler_version = OLD vs CURRENT mismatch => verdict
                        treated as NULL/stale; next gate re-verifies (AC3)
```

The verdict is **not** a status field on the definition lifecycle (DRAFT/ACTIVE/
DEPRECATED/ARCHIVED stay untouched); it is a parallel verdict column set. A definition
may be `semantically_valid = false` and still be saved as a DRAFT — the gate returns 422
at save so the *authoring request* fails (AC1), but the stored verdict reflects the last
validation result. On promotion submit the verdict is re-evaluated regardless of stored
state when the compiler version differs (AC3), and any finding blocks the promotion
regardless of stored verdict (AC2).

## Dependencies

- **Depends on:** `src/validation/mod.zig` and its submodules (the pure pipeline),
  `src/definition/store.zig` (the `process_definitions` verdict columns this batch's
  Type C migration adds), `src/definition/promotion.zig` (the promotion-submit call
  site, before plan computation), the event append surface used by the `DEFINITION_*`
  family (`event_type_registry` + the event-store append path),
  `src/db/pool.zig`, `src/obs/logger.zig`.
- **Must NOT depend on:** the engine (EE-05 runtime evaluation is deliberately not
  invoked — the gate is declaration-time only, matching the VLD-01/02/03 purity
  boundary); `src/definition/graph.zig`'s PD-06 internals (the gate consumes the
  VLD-01/02/03 `pd06_diagnostics` aggregate, not the raw check).
- **Compiler-version coupling:** `COMPILER_VERSION` is a `comptime` constant in
  `src/validation/mod.zig`. Any behaviour-affecting change to the validator must bump it
  — that is the mechanism AC3's invalidation rule runs on. This design does not
  introduce a second version source.

## Acceptance-criterion coverage (VLD-04)

| AC | Design location |
|---|---|
| AC1 (any finding at draft save -> HTTP 422, version not marked semantically_valid) | Draft-save call site: gate returns `invalid` -> 422; `persistVerdict` writes `semantically_valid = false`; the version is not persisted as valid |
| AC2 (any finding at promotion submit -> HTTP 422, no plan, no promotion_reviews row) | Promotion call site: gate runs **before** PRM-01 plan computation; a failing gate returns before any plan or review row exists (ordering, not rollback) |
| AC3 (stored verdict from earlier compiler version -> re-run, not trusted) | `storedVerdictIsCurrent` compares stored `compiler_version` to `COMPILER_VERSION`; mismatch forces re-verification |
| AC4 (compilation > 5 s -> HTTP 422 `ValidationTimeout` naming sites compiled before expiry) | `budget_ms = 5000` deadline threaded through the site-compile loop; `GateResult.timeout{sites_compiled, compiled_sites}` -> 422 `ValidationTimeout` |
| AC5 (clean pass -> `DEFINITION_VALIDATED`; failure -> `DEFINITION_VALIDATION_FAILED` with finding count) | `persistVerdict` appends the matching event in the same transaction as the verdict row, carrying `finding_count` on failure |

## Open questions

1. **`DEFINITION_VALIDATED` / `DEFINITION_VALIDATION_FAILED` are not in the event-type
   registry.** Migration 1152 seeds `EXECUTION_*` platform event types only; a grep of
   the seed for `DEFINITION_VALIDATED` returns nothing. The Type C migration in this
   batch adds the verdict columns, but the two event types must also be registered in
   `event_type_registry` (same `ON CONFLICT (name, schema_version) DO NOTHING` shape as
   1152, `retain_forever` per the protected-family rule) before `persistVerdict`'s append
   passes the ES-05 registry check. Flagged for BACKEND-DEV to add as a CUSTOM edit to
   the generated migration SQL (or a follow-up seed migration) — see the migration YAML's
   IMPLEMENTER NOTE.
2. **Exact promotion-submit call site.** The VLD-04 body and the process doc place the
   gate "before the PRM-01 plan is computed", but the concrete request handler that
   computes the plan (`src/definition/promotion.zig::promoteDefinition` is the ENV-03
   export/import path; PRM-01's plan computation is the `POST /api/v1/promotions`
   surface) is PRM-01's own concern, and PRM-01 is RELEASED in this codebase. BACKEND-DEV
   must confirm which handler PRM-01 exposes and place the gate at the top of it, before
   any plan or review-row write. Non-blocking — the ordering contract (gate before plan)
   is unambiguous.

None of these leave a VLD-04 acceptance criterion uncovered. Handoff `result.status` for
the VLD-04 portion is **PASS**.
