# Module: engine-merge

**Covers:** ISS-202 (Two-phase all-or-nothing variable merge)  
**Epic:** EPIC-2 · Event-sourcing integrity  
**Depends on:** ISS-201 (transition() now returns TransitionResult{state, emitted_events})  
**Files:** `src/engine/merge.zig`, updates to `src/engine/instance.zig`  
**Test plan:** Unit test asserting that mixed valid/invalid variables result in no overwrites, instance ERROR status, and unchanged variables. Integration test verifying pre-merge state remains intact on failure.

---

## 1. Overview

The current variable merge implementation (in `InstanceStore.mergeVariables()`) validates and applies output variables one-by-one in a single pass. When a schema violation or collision occurs, earlier keys have already been overwritten, leaving the instance in a half-merged state that violates the "all-or-nothing" principle.

ISS-202 introduces **two-phase variable merge** to ensure atomicity:

- **Phase 1 (Validation):** Validate ALL output variables (schema checks, collision detection) with **no state change** and **no events emitted**. Only the merged result and violation information are computed.
- **Phase 2 (Application):** Apply all validated keys to the instance and emit `VARIABLE_OVERWRITTEN` events **only if Phase 1 succeeds**. On any failure, emit only `EXECUTION_ERROR` and leave the instance variables untouched.

This change is orthogonal to ISS-201 (which changed the `transition()` signature to return emitted events) but leverages that new structure: Phase 1 builds the final `emitted_events` list; Phase 2 commits the variables if validation passed.

---

## 2. Affected Code Paths

Merging occurs at three points:

1. **Task completion** (`InstanceStore.completeTask()` Step g): After a task produces output variables, they are merged before `transition()` is called.
2. **Service task completion** (`InstanceStore.completeServiceTask()`): Similar merge before transition.
3. **Sub-process completion** (`InstanceStore.completeSubProcess()`): Merge child instance result variables into parent.

All three paths call `InstanceStore.mergeVariables()`. ISS-202 refactors that function to implement two-phase logic.

---

## 3. Architecture — Two-Phase Merge

### 3.1 Phase 1: Validation (Pure Computation)

**Purpose:** Determine whether the merge would succeed, without modifying any state.

**Inputs:**
- `current_vars: std.json.ObjectMap` — the instance's current variable map
- `output_variables: std.json.ObjectMap` — the variables to merge
- `definition_id: Uuid` — to look up variable schemas from `variable_schemas` table

**Computation Steps:**

1. **Per-variable validation loop** — for each key in `output_variables`:
   - Retrieve the variable schema from the database (if present).
   - Validate the new value against the schema using `json_schema.validate()`.
   - If invalid: record the violation and return failure immediately (no further checks).
   - If valid (or no schema): continue to next variable.

2. **Collision detection** — for each key in `output_variables`:
   - Check whether the key already exists in `current_vars`.
   - If present: record it as an overwrite (to be emitted in Phase 2).
   - If absent: record it as a new variable.

3. **Return value:**
   - On success: a `MergeValidationResult` containing the full merged map (the result state) and a list of `VariableOverwrittenPayload` events ready to emit.
   - On failure: a `SchemaViolationDetail` indicating which variable failed and why, **without** modifying any state.

**Key invariant:** Phase 1 performs **zero I/O** (reads are cached at the start), **zero state changes**, and **zero side effects**. It is a pure function equivalent.

### 3.2 Phase 2: Application (Conditional Commit)

**Purpose:** Apply the merge result only if Phase 1 succeeded.

**Inputs:**
- The result of Phase 1 (either `MergeValidationResult` or `SchemaViolationDetail`).
- The instance's current state and variables.

**Logic:**

- **If Phase 1 succeeded:** Atomically update the instance's variables to the merged map and emit all recorded `VARIABLE_OVERWRITTEN` events. The new event list becomes part of the `TransitionResult` returned to the caller.
- **If Phase 1 failed:** Emit only a single `EXECUTION_ERROR` event (with the violation detail as payload), leave variables untouched, and set the instance status to `ERROR`. Retry from this state will see the pre-merge variables.

---

## 4. Function Signatures

### 4.1 Phase 1: Validation

```zig
pub const MergeValidationResult = struct {
    /// The complete merged variable map (all current vars + all output vars).
    /// Owned by the caller; caller is responsible for freeing.
    merged: std.json.ObjectMap,
    /// Events to emit if Phase 2 succeeds.
    /// Ordered by merge order (overwrites in input order).
    overwritten_events: []VariableOverwrittenPayload,
};

pub const MergeValidationError = error{
    SchemaViolation,   // a variable failed schema validation
    PersistenceFailed, // database error fetching schemas
    OutOfMemory,
};

pub fn validateMerge(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    definition_id: Uuid,
    instance_id: Uuid,
    task_id: ?Uuid,
    current_vars: std.json.ObjectMap,
    output_variables: std.json.ObjectMap,
    /// OUT: If validateMerge returns error.SchemaViolation,
    /// the caller MUST read violation_out.*.
    /// The SchemaViolationDetail is owned by allocator
    /// and the caller must free it.
    violation_out: *?SchemaViolationDetail,
) MergeValidationError!MergeValidationResult
```

**Preconditions:**
- `conn` is a valid database connection (may be inside or outside a transaction — Phase 1 only reads).
- `allocator` is provided by the caller and remains valid for the lifetime of the result.
- `definition_id`, `instance_id` are valid UUIDs.

**Postconditions (on success):**
- `violation_out.*` is `null`.
- Returned `merged` is an `ObjectMap` containing all keys from `current_vars` plus all keys from `output_variables`. For keys present in both, the value is from `output_variables`.
- Returned `overwritten_events` lists all keys that were overwritten (present in both maps), in iteration order of `output_variables`.

**Postconditions (on `error.SchemaViolation`):**
- `violation_out.*` points to a `SchemaViolationDetail` with `affected_field`, `reason`, and `variable_state` (stringified snapshot of `current_vars`).
- The `SchemaViolationDetail` is allocated from `allocator`.
- Returned `merged` is undefined (may be partially populated); caller must not use it.

### 4.2 Phase 2: Application / Commit

Phase 2 is integrated into the calling code in `completeTask()`, `completeServiceTask()`, etc.

**Algorithm (high-level):**
1. Call `validateMerge()` with output variables and current state.
2. If Phase 1 fails (schema violation): emit `EXECUTION_ERROR`, set instance to `ERROR` status, leave variables untouched, return.
3. If Phase 1 succeeds: update instance variables to the merged map; emit one `VARIABLE_OVERWRITTEN` event per overwritten key; call `transition()` with merged state and collect its events; return.

**See backend_developer_guide.md §8** for detailed control flow and memory management (defer blocks, cleanup ordering).

---

## 5. Error Handling

### 5.1 Schema Violation Path

When `validateMerge()` returns `error.SchemaViolation`:

1. **Populate `violation_out.*`** with the field name, validation error reason, and a stringified snapshot of the **pre-merge** variables.
2. **Do not update** the instance variables (Phase 2 is skipped).
3. **Set instance status to `ERROR`** via `setInstanceError()`.
4. **Emit `EXECUTION_ERROR`** with the `SchemaViolationDetail` as payload.
5. **Return failure** from `completeTask()` (or the calling function).

On **retry** (calling `completeTask()` again with the same task):
- The instance is in `ERROR` status.
- The instance variables are **exactly as they were before** the failing merge.
- If the output variables are corrected, the retry merge operation will see the pre-merge state.

### 5.2 Database / Transactional Errors

If `validateMerge()` returns `error.PersistenceFailed` (schema fetch failed):
- The transaction is rolled back (caller's responsibility).
- The instance is left untouched.
- Caller returns a `CompleteTaskError.PersistenceFailed` or equivalent.

---

## 6. Variable Schema Lookup

Variable schemas are stored in the `variable_schemas` table, created during process definition loading (existing mechanism, not part of ISS-202).

```sql
SELECT variable_key, json_schema
FROM variable_schemas
WHERE definition_id = $1::uuid
```

**Security:** Parameter binding via `$1` (no string interpolation).

**Caching strategy (Phase 1 optimization):** All schemas for a definition are fetched in a single query at the start of `validateMerge()` and cached in a `StringHashMap([]const u8)` for the duration of the merge. This amortizes the database cost across all variables.

---

## 7. Event Emission

### 7.1 VARIABLE_OVERWRITTEN Event

Emitted once per overwritten variable (only if Phase 1 succeeds and Phase 2 proceeds):

```zig
pub const VariableOverwrittenPayload = struct {
    event_type: []const u8,        // "VARIABLE_OVERWRITTEN"
    instance_id: Uuid,
    task_id: ?Uuid,                // nullable; null if coming from service task or sub-process
    key: []const u8,               // variable key
    old_value: []const u8,         // JSON string of old value
    new_value: []const u8,         // JSON string of new value
};
```

The `VariableOverwrittenPayload` is produced by Phase 1 and queued by Phase 2. The serialization (old_value, new_value) happens in Phase 1, minimizing the work during Phase 2.

### 7.2 EXECUTION_ERROR Event

Emitted if Phase 1 fails (schema violation):

```zig
pub const SchemaViolationDetail = struct {
    affected_field: []const u8,    // variable key that failed
    reason: []const u8,            // validation error message
    variable_state: []const u8,    // JSON string of pre-merge variables
};
```

This is attached to the `EXECUTION_ERROR` event payload, already defined in `src/engine/instance.zig` (EE-09 §7).

---

## 8. State Guarantees

### 8.1 All-or-Nothing Merge

- **Success case:** All output variables are merged; instance variables are updated atomically; one `VARIABLE_OVERWRITTEN` event is emitted per overwritten key (zero events if no overwrites).
- **Failure case:** Zero variables are updated; only one `EXECUTION_ERROR` event is emitted; instance enters `ERROR` status with the pre-merge variables intact.

### 8.2 Retry Semantics

A failed merge can be retried (by resubmitting the task output):

1. **Before retry:** Instance is in `ERROR` status; variables are unchanged from pre-merge.
2. **During retry:** `validateMerge()` is called again with the same `output_variables`. It sees the same pre-merge state.
3. **After retry success:** Variables are updated atomically; status returns to `ACTIVE` (if no other errors).

---

## 9. Public API (Module Boundary)

`src/engine/merge.zig` is a new module that encapsulates two-phase merge logic. It is internal to the engine and not exposed at the HTTP API boundary.

**Exported symbols:**
- `MergeValidationResult` struct
- `MergeValidationError` error set
- `validateMerge()` function
- `VariableOverwrittenPayload` struct
- `SchemaViolationDetail` struct

**Imported by:**
- `src/engine/instance.zig` (via `validateMerge()` call in `completeTask()`, `completeServiceTask()`, `completeSubProcess()`)

---

## 10. Dependency on ISS-201

ISS-201 changed the signature of `transition()` to return `TransitionResult{state, emitted_events}`. This allows ISS-202 to:

1. **Build the emitted_events list incrementally:** Phase 1 produces `VARIABLE_OVERWRITTEN` events; Phase 2 conditionally adds them; `transition()` may produce additional events (e.g., gateway results), all collected in a single list.
2. **Preserve the pure-function contract:** `transition()` has zero I/O and does not append trigger events. The orchestrator appends trigger + `emitted_events` atomically (ISS-201 Step h).

Without ISS-201, there would be no way to collect and order the `VARIABLE_OVERWRITTEN` events without performing I/O during the merge.

---

## 11. Error Taxonomy

| Error | Severity | Path | Recovery |
|---|---|---|---|
| Schema violation | EXECUTION_ERROR | Phase 1 → Phase 2 skipped | Correct output variables and retry |
| Null/missing schema | Silent (no constraint) | Phase 1 continues | N/A |
| Collision (overwrite) | Info event (VARIABLE_OVERWRITTEN) | Phase 1 → Phase 2 emits event | Normal; event is recorded |
| Database error | PERSISTENCE_ERROR | Phase 1 fails | Retry after DB recovery |
| Out of memory | OUT_OF_MEMORY | Phase 1 fails | Retry after memory available |

---

## 12. Key Invariants

1. **Phase 1 is pure:** No I/O side effects beyond reading schemas; no instance state is modified; always deterministic for the same inputs.
2. **Phase 1 completes before Phase 2 starts:** No interleaving; either Phase 1 succeeds and Phase 2 proceeds, or Phase 1 fails and Phase 2 is skipped.
3. **Violation detail contains pre-merge state:** `SchemaViolationDetail.variable_state` is a snapshot of `current_vars` **before** any merge, allowing the instance to be rolled back completely.
4. **Overwrites are ordered:** `overwritten_events` preserves the iteration order of `output_variables`, ensuring deterministic event ordering even if hash maps are involved.
5. **All or nothing:** Either all output variables are applied (and all overwrites are recorded), or none are applied.
6. **Retry idempotence:** Retrying a failed merge against a corrected input produces the same merged state as the initial attempt would have, assuming the corrected output and pre-merge variables are the same.

---

## 13. Testing Strategy

### 13.1 Unit Tests

- **Success case:** Merge two disjoint variable sets (no overwrites). Verify merged map contains all keys; overwritten_events is empty.
- **Overwrite case:** Merge with one key present in current_vars. Verify merged map is updated; one event in overwritten_events.
- **Schema violation case:** Merge with one variable failing schema validation. Verify error.SchemaViolation returned; violation_out is populated; merged is not used.
- **Mixed valid/invalid:** Multiple variables, one fails. Verify Phase 1 stops at first violation; earlier variables are not applied.

### 13.2 Integration Tests

- **All-or-nothing atomicity:** Complete a task with mixed valid/invalid output. Verify instance status is ERROR; variables are unchanged; only EXECUTION_ERROR is recorded (no VARIABLE_OVERWRITTEN).
- **Retry on corrected input:** Fail a merge, correct the output, retry. Verify the retry succeeds and sees the pre-merge state.
- **Collision event ordering:** Complete a task with multiple overwrites. Verify VARIABLE_OVERWRITTEN events are recorded in the same order as the output variables.

---

## 14. Future Extensions

1. **Batch validation:** If multiple merges are needed in sequence (e.g., multiple task outputs in one transition), the validation cost could be amortized by pre-loading all schemas once.
2. **Custom validators:** If variable validation goes beyond JSON schema (e.g., cross-field constraints), the `validateMerge()` signature allows adding a `custom_validator` callback parameter.
3. **Merge conflict resolution policies:** The current all-or-nothing approach could be generalized to support conditional acceptance (e.g., "ignore overwrites," "keep newest," "merge as array") via a policy parameter.

---

## 15. Open Questions

1. **Collision handling:** Is a collision (overwrite) always acceptable? Or should some variables be marked as "immutable" (raising an error if a merge attempts to overwrite them)? The requirement does not specify; current design treats all overwrites as valid and emits an info event.
2. **Nested variable validation:** Can variable schemas contain nested objects with further constraints? JSON schema supports this; the current design delegates all validation to `json_schema.validate()`, which should handle arbitrary depth. Confirm during implementation.
3. **Null values:** Can `output_variables` contain null values? Current design treats null as a valid value (phase through JSON schema validation). If nulls should clear variables, that would require additional logic.
