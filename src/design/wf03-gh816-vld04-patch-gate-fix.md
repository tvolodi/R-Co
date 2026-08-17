# Fix Design: Wire runSemanticGate into handlePatch

**Module:** `src/api/routes/definitions.zig` — `handlePatch`
**ISS-ID:** ISS-0717
**GitHub Issue:** https://github.com/tvolodi/R-Co/issues/816
**Run ID:** WF03-GH816-20260817
**Design type:** Type E (novel call-site orchestration wire, cross-cutting bug fix)
**Artefact produced by:** CODE-DESIGNER (WF03-GH816-20260817 step 02)

---

## Module purpose

`handlePatch` is the live handler for `PATCH /api/v1/definitions/{id}` — the only registered
definition-update route in `src/main.zig` and the exclusive draft-save surface used by the
frontend (`web/src/api/definitions.ts` `client.patch`). VLD-04 AC1 requires that any finding at
draft save returns HTTP 422 and leaves the version `semantically_valid = false`. The validated
`src/design/vld-04-validation-gate-authoring-promotion.md` call-site table declared `PUT
/api/v1/definitions/{id}` as the draft-save site, but no PUT route for definitions was ever
registered in `main.zig`. `handlePut` (which does call `runSemanticGate`) is dead code.
`handlePatch` is the live surface and has no gate call. This design specifies the minimal fix:
insert the identical gate block from `handlePut` into `handlePatch` at the correct point.

---

## Call-site change specification

### File and function

`src/api/routes/definitions.zig` — `handlePatch` (function begins at line 458).

### Insertion point

After `store.update` returns successfully and `def` is bound (and `defer freeDefinition(allocator,
def)` is registered), **before** the final `serializeDefinition` / `return .{ .status_code = 200,
.body = resp_body }` two-liner that closes the function.

In structural terms: the current function has the shape

```
1. parse id_str → UUID
2. build UpdateParams from body fields
3. store.update(id, params)  [error branch returns early on every error variant]
4. defer freeDefinition(def)
5. serializeDefinition(def)  → HTTP 200
```

The gate block is inserted between step 4 and step 5:

```
1. parse id_str → UUID
2. build UpdateParams from body fields
3. store.update(id, params)  [error branch unchanged — all existing error arms stay]
4. defer freeDefinition(def)
5. [INSERT GATE BLOCK HERE]
6. serializeDefinition(def)  → HTTP 200  (reached only when gate returns .valid)
```

### Gate block shape (call-site table — no implementation code)

The block to insert is the exact gate block already present in `handlePut` (lines 412–444 of the
same file). It consists of three logical parts:

| Part | Interface used | Purpose |
|---|---|---|
| 1. Gate invocation | `validation_gate.runSemanticGate(allocator, store.pool, id_str, 5_000, false)` | Call the gate with `check_stored_first = false` — forces re-verification because the graph may have changed on this PATCH (mirrors the reasoning in `handlePut`) |
| 2. Gate error arm | `error.DefinitionNotFound → 404`, `error.PoolExhausted → 503`, `else → 500` | Matches the error mapping in `handlePut` verbatim |
| 3. Gate result switch | `.valid`, `.invalid`, `.timeout` arms — see HTTP contracts below | Matches `handlePut` verbatim |

**`check_stored_first = false` rationale:** Even when the PATCH body omits the `graph` field, a
stored verdict from a prior call may be stale if the environment changed (referenced service
catalog entries, variable schemas). The `handlePut` design made the same choice. Consistency and
safety both favour `false` here.

**`id_str` not `id`:** `runSemanticGate` accepts the raw string form of the definition id (not the
parsed UUID struct). `id_str` is the parameter name in scope at the insertion point.
`parseUuid(id_str)` has already succeeded and returned `id`, but the gate takes the string. This
mirrors `handlePut` exactly.

---

## HTTP return-value contracts

| Gate outcome | HTTP status | Body |
|---|---|---|
| `GateResult.valid` | 200 (existing path, unchanged) | JSON definition body from `serializeDefinition(def)` |
| `GateResult.invalid` | 422 | VLD-03 Problem Details JSON body serialised from `validation.serialiseValidationFailure(failure)`, where `failure = validation_gate.failureFromInvalid(inv)` — same shape as `handlePut`'s 422 response |
| `GateResult.timeout` | 422 | `{"error":"validation_timeout"}` — `errorResult(allocator, 422, "validation_timeout")` |
| `error.DefinitionNotFound` (gate error) | 404 | `{"error":"not_found"}` |
| `error.PoolExhausted` (gate error) | 503 | `{"error":"service_unavailable"}` |
| Other gate errors | 500 | `{"error":"internal_error"}` |

The existing non-gate error responses (404 from store.update, 409 not_draft, 422 violations, 503
pool exhausted) are **unchanged**. The gate block is inserted after `store.update` succeeds, so it
never fires on those error paths.

**Memory ownership note (design constraint for BACKEND-DEV):**
- On `.valid`: `validation_gate.freeValid(allocator, verdict)` must be called — `runSemanticGate`
  transfers ownership of the verdict's slice fields.
- On `.invalid`: after calling `serialiseValidationFailure` and returning, call
  `validation_gate.freeInvalid(allocator, inv)` — same ownership rule as `handlePut`.

---

## New test: TC-VLD-04-AC1-PATCH

**Test name:** `TC-VLD-04-AC1-PATCH: handlePatch returns HTTP 422 on a finding-producing body`

**Target file:** `tests/integration/vld04_gate_test.zig` (append after the existing AC1 test
`TC-VLD-04-AC1-draft-save-finding-invalid`, which covers the raw gate module; this new test
covers the live handler surface).

**Test layer:** integration (real `process_definitions` row + real gate call through `handlePatch`)

**Acceptance criterion mapped:** VLD-04 AC1, on the live PATCH draft-save surface (ISS-0717
acceptance criterion 1)

### Given / When / Then

| Phase | Description |
|---|---|
| **Given** | A DRAFT definition row in `process_definitions` seeded with a valid graph (use `seedDefinition(allocator, conn, valid_graph_json)` — the same helper already in the file). A `definition_store.Store` initialised from the same pool. A `PatchDefinitionBody` with `graph` set to `invalid_graph_json` (the existing constant — a graph with a guard referencing `amount` which is `UnknownVariable` under the empty env) and all other fields null. |
| **When** | `definitions.handlePatch(store, allocator, fx.definition_id, patch_body)` is called. |
| **Then** | The returned `HandlerResult.status_code` equals 422. The `HandlerResult.body` is non-empty. The `process_definitions` row's `semantically_valid` column is `false` (query via `conn` after the call). |

### What the test does NOT need to verify

- The exact structure of the 422 body (that is `serialiseValidationFailure`'s contract, already
  covered by VLD-03 tests).
- That `DEFINITION_VALIDATION_FAILED` was appended (that is AC5, already covered by
  `TC-VLD-04-AC5-failed-event`).

### Imports and helpers needed

- `definitions` (`@import("../../src/api/routes/definitions.zig")`) — the handler module.
- `definition_store` (`@import("../../src/definition/store.zig")`) — to initialise the Store
  from the pool.
- The existing helpers `requireTestDbUrl`, `makePool`, `seedDefinition`, `cleanup`,
  `freeVerdict`, `invalid_graph_json`, `valid_graph_json` are all reused unchanged.

### Store initialisation note

`handlePatch` takes a `*definition_store.Store`, not a raw pool. The test must construct a
`definition_store.Store` wrapping the same pool (using the store's `init(pool)` or equivalent
constructor) before calling `handlePatch`. The store is torn down after the test. This is the
same pattern a future handler-level test for `handlePut` would follow.

---

## Audit of other call sites in `definitions.zig`

The audit covers every write handler in the file. Read-only handlers and status-transition
handlers (`handleDeprecate`, `handleArchive`) are not draft-save surfaces; the VLD-04 design
does not place the gate on them.

| Handler | Line | Status | Gate needed? | Verdict |
|---|---|---|---|---|
| `handleCreate` | 309 | Creates a new DRAFT with an initial graph | **No — by design** | VLD-04's "draft save" gate is defined as the *update* path (saving changes to an existing draft). CREATE seeds a fresh row with whatever graph the caller supplies; the gate runs the next time the author calls PATCH or PUT to save changes. This matches the VLD-04 process doc (PW-02 step 1: "draft save" is the authoring loop step, not the initial creation step). No gap. |
| `handlePut` | 362 | Full replacement of a DRAFT definition | **Yes — already wired** | Calls `runSemanticGate` at line ~412 with `check_stored_first=false`. Gate block is correct and complete per the REWORK-2 implementation (`WF02-batch-7-20260816`). **CONFIRMED CORRECT. No change needed.** |
| `handlePatch` | 458 | Partial update of a DRAFT definition — the live frontend save path | **Yes — MISSING (this fix)** | `store.update` is called (line ~484) but `runSemanticGate` is never called. Returns HTTP 200 unconditionally on success. This is the defect. **FIX = insert gate block after `store.update` succeeds, before final HTTP 200.** |
| `handleDelete` | 507 | Status-dependent delete | No | Not a draft-save surface. No gate needed. |
| `handleActivate` | ~600 | DRAFT → ACTIVE transition | No (separate concern) | Activation is a lifecycle transition, not a draft save. PW-01/PRM-01 govern promotion gating; `handleActivate` is the direct activation shortcut. Not a VLD-04 gate site. |

**Summary:** One gap found (`handlePatch`). No other write handler requires a gate change.

---

## Dependencies

- **Depends on:** `validation_gate` module (`src/validation/gate.zig`, built as `validation_gate`
  named module in `build.zig`) — already imported in `definitions.zig` via the existing
  `const validation_gate = @import("validation_gate");` import at the top of the file.
  No new imports needed.
- `validation` module — already imported (`const validation = @import("validation");`) for
  `serialiseValidationFailure`. No new imports needed.
- **No changes to:** `src/main.zig`, `web/src/api/definitions.ts`, `src/validation/gate.zig`,
  any migration file, any other source file.

This fix is a single-file change to `src/api/routes/definitions.zig` only.

---

## Open questions

None. The call-site contract is unambiguous (mirror `handlePut`). The test approach is
consistent with the existing integration test pattern. No schema changes required.
