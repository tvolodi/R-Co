# ISS-0206: rowToDefinition Allocation-Failure Errdefer Guards — Design Artefact

**Issue:** ISS-0206 / GH #526
**Related:** ISS-0132 / GH #427 (proven parseGraphJson errdefer pattern, in-file at store.zig:1318-1421)
**Type:** E (novel in-file leak fix in a non-CRUD function — no CRUD boilerplate, no migration, no API change)
**Status:** DESIGN (Step 2 — CODE-DESIGNER)
**Run:** WF03-GH526-20260807
**Generated:** 2026-08-07 (UTC) by r-co-1-loop
**Source issue:** docs/issues/ISS-0206.json (filed 2026-08-07T04:40:47Z, OPEN)
**Source diagnosis:** docs/issue-reports/ISS-0206-diagnosis.yaml (Step 1, 2026-08-07T18:49:40Z)

---

## 1. Module Purpose

This artefact specifies the fix for `src/definition/store.zig`'s `rowToDefinition` (store.zig:1433-1502), which performs **five sequential fallible allocations and zero `errdefer` guards**:

| # | Line  | Operation                                  | Currently guarded by errdefer? |
|---|-------|--------------------------------------------|--------------------------------|
| 1 | 1451  | `allocator.dupe(u8, ...)` for `name`         | NO                             |
| 2 | 1452  | `allocator.dupe(u8, ...)` for `version`      | NO                             |
| 3 | 1457  | `allocator.dupe(u8, ...)` for `description`  | NO                             |
| 4 | 1471  | `parseGraphJson(allocator, ...)` for `graph` | NO                             |
| 5 | 1481  | `allocator.dupe(u8, ...)` for `stage`        | NO                             |

Failure modes the design MUST close:

- **`version`'s dupe fails** → `name` leaks.
- **`description`'s dupe fails** → `name`, `version` leak.
- **`parseGraphJson` fails and the `catch fallback.graph` branch is NOT taken** (the only paths that don't take the catch are the success branch — but inside the success branch, parseGraphJson itself can fail and the `catch` mask is currently the *only* safeguard, and it leaks whatever it allocated internally). Additionally, when the JSON is empty, `fallback.graph` is consumed by-value (no leak); when the JSON is non-empty and parseGraphJson succeeds, the returned `DefinitionGraph` is owned by the row and must be freed by the eventual `Definition.deinit` — but if a *later* dupe fails, the `DefinitionGraph` is never wrapped in a `Definition` so its `deinit` is never called.
- **`stage`'s dupe fails** → `name`, `version`, `description` AND `graph` all leak.

The fix reuses the proven pattern from the same file's `parseGraphJson` (ISS-0132 / GH #427, lines 1318-1421): **each fallible result lands in a local guarded by its own `errdefer` BEFORE the next fallible statement runs; the struct literal is assembled LAST.** The single structural difference is that rowToDefinition builds a heterogeneous struct (not a list), so the guards are sequential rather than loop-relative. The design must also **make the function reachable by `std.testing.checkAllAllocationFailures`** — currently impossible because rowToDefinition takes a `row: []?[]u8` (a live `pg.zig` result row). The fix introduces a parallel fixture-driven signature; the DB-row variant becomes a one-line wrapper around it.

---

## 2. Root Cause (cross-reference)

Restated from `docs/issue-reports/ISS-0206-diagnosis.yaml §problem_location` (Step 1 evidence; commit `2752b725`):

- `rowToDefinition` at `src/definition/store.zig:1437-1502` performs 5 fallible allocations in sequence.
- The struct literal at the end (`return Definition{...}`) is the only reference to the dupes; nothing else owns them. On any error path, no `errdefer` releases what was already duped.
- `parseGraphJson` at lines 1318-1421 already demonstrates the correct pattern: every dupe lands in a local guarded by `errdefer` before the next fallible statement; the struct literal is built last; a single counter tracks incremental construction for nested loops.

## 3. Blast Radius (unchanged by fix)

Restated from `docs/issue-reports/ISS-0206-diagnosis.yaml §blast_radius`:

| Call site                | Path                                                        | Caller visible?       |
|--------------------------|-------------------------------------------------------------|-----------------------|
| store.zig:294            | `create` (PD-01) — INSERT … RETURNING                       | `catch` → `TransactionFailed` (leak invisible at boundary) |
| store.zig:347            | `getById` (PD-01)                                           | `catch` → `TransactionFailed` |
| store.zig:688            | `update` PUT/PATCH                                          | `catch` → `TransactionFailed` |
| store.zig:775            | `activate` (PD-03)                                          | `catch` → `TransactionFailed` |
| store.zig:862            | `deprecate` / `archive`                                     | `catch` → `TransactionFailed` |
| store.zig:1067           | `list` (PD-06)                                              | `catch` → `TransactionFailed` |
| store.zig:1205           | `search` (PD-10)                                            | `catch` → `TransactionFailed` |
| store.zig:1511           | `rowsToDefinitions` (list aggregator)                       | `catch` → `TransactionFailed` |
| store.zig:1542           | `rowsToSearchResults` (search aggregator)                    | `catch` → `TransactionFailed` |

The fix is **purely a body refactor of `rowToDefinition`**; **no caller signature changes**, **no behaviour change on the success path**, **no new error variants introduced**. The body shape becomes:

```
rowToDefinition(allocator, row, fallback) — thin wrapper that fills a RowFields struct from
the row and calls rowToDefinitionFromFields(allocator, fields, fallback).

rowToDefinitionFromFields(allocator, fields, fallback) — the actual fallible mapping,
testable by checkAllAllocationFailures.
```

---

## 4. Public Interface

### 4.1 No signature changes

All existing callers continue to call:

```
pub fn rowToDefinition(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    fallback: CreateParams,
) error{OutOfMemory}!Definition
```

The DB-row variant `rowToDefinition` remains; it becomes a thin wrapper. Its error set is unchanged. Its parameter order is unchanged.

### 4.2 New internal signature — fixture-driven

Add to `src/definition/store.zig` (private — no `pub`):

```
fn rowToDefinitionFromFields(
    allocator: std.mem.Allocator,
    fields: *const RowFields,
    fallback: CreateParams,
) error{OutOfMemory}!Definition
```

where `RowFields` is a new private struct that mirrors what `rowToDefinition` extracts from a row, **without** taking the `[]?[]u8` parameter. This is what `std.testing.checkAllAllocationFailures` can drive.

### 4.3 New private struct — `RowFields`

Add to `src/definition/store.zig`:

```
const RowFields = struct {
    /// Column 0 — UUID text.
    id: []const u8,
    /// Column 1 — name (TEXT).
    name: []const u8,
    /// Column 2 — version (TEXT).
    version: []const u8,
    /// Column 3 — description (TEXT or NULL).
    description: ?[]const u8,
    /// Column 4 — status (TEXT).
    status: []const u8,
    /// Column 5 — graph (JSONB text).
    graph_json: []const u8,
    /// Column 6 — created_by UUID text.
    created_by: []const u8,
    /// Column 7 — created_at (µs).
    created_at_text: []const u8,
    /// Column 8 — updated_at (µs).
    updated_at_text: []const u8,
    /// Column 9 — archived_at (µs) or NULL.
    archived_at_text: ?[]const u8,
    /// Column 10 — stage (TEXT or NULL).
    stage: ?[]const u8,
};
```

Notes:

- `RowFields` is **plain pointer-of-bytes** — no nested allocations, no `[]?[]u8` of unknown lifetime. This is what makes `checkAllAllocationFailures` able to drive it directly.
- All `[]const u8` fields must point into memory the test owns (a fixed `[]const u8` array of fixture strings) so the test does not need an allocator to construct `RowFields`.

### 4.4 Refactored `rowToDefinition` (signature unchanged)

```
fn rowToDefinition(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    fallback: CreateParams,
) error{OutOfMemory}!Definition {
    // Extract row fields via the existing local `col.get` / `col.getOpt` helpers
    // (store.zig:1439-1447); build a RowFields on the stack, then delegate.
    var fields: RowFields = ...;
    return rowToDefinitionFromFields(allocator, &fields, fallback);
}
```

Body length: roughly the same as today's pre-body code (8–10 lines). The `col.get` helpers stay where they are.

### 4.5 Refactored `rowToDefinitionFromFields` (the fix)

The function body MUST follow the **proven pattern at parseGraphJson (store.zig:1318-1421)**, adapted for a single struct literal instead of two loops. The body is split into two blocks below — Block A registers every `errdefer` immediately after its corresponding `try`; Block B returns the assembled struct literal LAST. Each block is below the 40-line fence cap so the lint check (`tools/lint_design_artefact.py` rule E050) passes.

#### 4.5.1 Block A — locals and errdefers (registers cleanups in order)

```zig
const id = parseUuid(fields.id) catch std.mem.zeroes(Uuid);
const status = parseDefinitionStatus(fields.status) catch .DRAFT;
const created_by = parseUuid(fields.created_by) catch fallback.created_by;
const created_at = std.fmt.parseInt(i64, fields.created_at_text, 10) catch 0;
const updated_at = std.fmt.parseInt(i64, fields.updated_at_text, 10) catch 0;

const name = try allocator.dupe(u8, if (fields.name.len > 0) fields.name else fallback.name);
errdefer allocator.free(name);

const version = try allocator.dupe(u8, if (fields.version.len > 0) fields.version else fallback.version);
errdefer allocator.free(version);

const description: ?[]const u8 = if (fields.description) |d| try allocator.dupe(u8, d) else null;
errdefer if (description) |d| allocator.free(d);

const graph = if (fields.graph_json.len > 0) try parseGraphJson(allocator, fields.graph_json) else fallback.graph;
errdefer graph.deinit(allocator);

const archived_at: ?i64 = if (fields.archived_at_text) |s| std.fmt.parseInt(i64, s, 10) catch null else null;

const stage: ?[]const u8 = if (fields.stage) |s| try allocator.dupe(u8, s) else null;
errdefer if (stage) |s| allocator.free(s);
```

#### 4.5.2 Block B — assemble the struct literal LAST (no fallible calls)

```zig
return Definition{
    .id = id,
    .name = name,
    .version = version,
    .description = description,
    .status = status,
    .graph = graph,
    .created_by = created_by,
    .created_at = created_at,
    .updated_at = updated_at,
    .archived_at = archived_at,
    .stage = stage,
};
```

#### 4.5.3 Mandatory properties (verified by the test in §7)

1. **Each fallible result is assigned to a local guarded by its own `errdefer` BEFORE the next fallible statement runs.**
2. **The struct literal is assembled last** — no intermediate struct construction.
3. **The `graph` errdefer runs `deinit` whether the graph came from `parseGraphJson` (allocating) or from the empty-JSON branch (`fallback.graph`, which is an empty `DefinitionGraph` whose `deinit` is a no-op).**
4. **No new error variants** — return type is `error{OutOfMemory}!Definition`, identical to today's.
5. **No allocator parameter changes** — same `std.mem.Allocator` argument.
6. **The `col.get` / `col.getOpt` row helpers remain in `rowToDefinition` only** — they are not used in `rowToDefinitionFromFields`, which receives already-decoded `[]const u8` slices.
7. **Errdefer registration order matches the order in which their corresponding `try` runs**, so on error they fire in reverse-registration order — i.e. the `graph.deinit` runs after the four text-dup frees. This is the order parseGraphJson uses (lines 1318-1421); it keeps the bookkeeping mechanical and easy to audit.

---

## 5. Data Flow

```
                      rowToDefinition (DB-row wrapper, signature unchanged)
                                │
                                │  extracts 11 column strings via col.get/col.getOpt
                                ▼
                          RowFields (private struct, plain slices)
                                │
                                │  pass by const pointer
                                ▼
                rowToDefinitionFromFields (the fix; checkAllAllocationFailures-driveable)
                                │
                                │  parses, dupes, guards each in order
                                │  builds Definition struct literal LAST
                                ▼
                          Definition (returned to caller)

  Allocation sites:
  ┌───────────────────────────────────────────────────────────────┐
  │ id        : infallible parse                                  │
  │ name      : allocator.dupe  ── errdefer free(name)            │
  │ version   : allocator.dupe  ── errdefer free(version)         │
  │ desc      : allocator.dupe? ── errdefer free(desc)            │
  │ status    : infallible parse                                  │
  │ graph     : parseGraphJson OR fallback.graph                  │
  │                          ── errdefer graph.deinit(allocator)  │
  │ created_by: infallible parse                                  │
  │ created_at: infallible parse                                  │
  │ updated_at: infallible parse                                  │
  │ archived_at: infallible optional parse                        │
  │ stage     : allocator.dupe? ── errdefer free(stage)            │
  │                              ── return Definition {...}      │
  └───────────────────────────────────────────────────────────────┘
```

If any `try` propagates, **every errdefer registered up to and including that point runs in reverse registration order**, releasing all earlier dupes and the graph.

---

## 6. Error Taxonomy

The fix does NOT add new error variants. `rowToDefinition` and `rowToDefinitionFromFields` keep the existing public error set:

```
error{OutOfMemory}!Definition
```

Mapping (unchanged from current code):

| Error variant      | Source                                                  | Existing handling at call sites              |
|--------------------|---------------------------------------------------------|-----------------------------------------------|
| `OutOfMemory`      | Any `try allocator.dupe(...)` or `try parseGraphJson(...)` | `catch` → `DefinitionError.TransactionFailed` (most call sites) or surfaced as-is |

The design MUST NOT introduce:

- A new `DefinitionError` variant — `rowToDefinition`'s catch into `DefinitionError.TransactionFailed` is correct and must stay unchanged.
- A `catch unreachable` on any realistic failure path — forbidden by `docs/anti-patterns.md`.
- Any change to `DefinitionError` — the existing set is preserved.

`parseDefinitionStatus`'s `error.InvalidStatus` is still swallowed (current behaviour: `.DRAFT`); this matches the existing code path and is unaffected by the fix.

`parseUuid`'s failure is still swallowed (current behaviour: zero UUID); unaffected.

---

## 7. Test Plan

### 7.1 New unit test file

`tests/unit/iss0206_rowtodefinition_errdefer_test.zig` — wire it into `build.zig` as a new standalone `addTest` target following the **proven pattern at `src/definition_store_test_root.zig`** (the shim that exposes store.zig to `addTest`).

**Why a new file rather than putting it in store.zig itself:** the diagnosis explicitly recommends extracting the pure row-to-struct mapping behind a fixture-driven signature precisely so the test can live in `tests/unit/` and reach `store.zig` as a named module — mirroring the existing `definition_store_test_root.zig` approach. The harness imports `store.zig` and calls `rowToDefinitionFromFields` with a stack-allocated `RowFields` referencing fixed `[]const u8` slices in the test file.

### 7.2 Required test cases

The test file MUST include at minimum:

| Test name                                       | What it asserts                                                                                                                                                            |
|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `TC-ISS-0206-01: rowToDefinitionFromFields leaks nothing on any allocation failure (all fields populated)` | `std.testing.checkAllAllocationFailures` succeeds on `rowToDefinitionFromFields` with all 11 fields populated — exercises every dupe index plus `parseGraphJson`. |
| `TC-ISS-0206-02: rowToDefinitionFromFields leaks nothing on any allocation failure (optional fields absent)` | Same harness, with `description`, `stage`, and `graph_json` empty — exercises the `else null` and fallback-graph branches.                                                |
| `TC-ISS-0206-03: regression — fails on the unfixed function` | Document in a comment at the top of the test file: the unfixed `rowToDefinition` body is the test's negative control; the test passes only after the fix lands. Verified by running the test against a temporary revert. |

### 7.3 Failure-mode regression assertion

The test MUST call `rowToDefinitionFromFields` (NOT `rowToDefinition`) so the harness can drive the function without a `pg.zig` row. The DB-row wrapper is verified separately by the existing integration tests for `create`, `getById`, `activate`, `list`, `search`, etc. — those continue to call the unchanged `rowToDefinition` signature.

### 7.4 Wire-up requirements (mandatory)

- Add a new `addTest` target in `build.zig` for `tests/unit/iss0206_rowtodefinition_errdefer_test.zig` with imports for `store` (named module reaching `src/definition/store.zig`). Follow the same import shape as `src/definition_store_test_root.zig`.
- Attach the new test target to `zig build test` (the aggregate step) — **NOT** only to a narrow step like `test-iss0206-rowtodefinition`. The narrow-step-only attachment is the exact defect (ISS-0150 / GH #466) that `tools/lint_test_wiring.py` guards, and the same inert-test class ISS-0132 / GH #427 exists to end.
- Register the new target in `docs/agents/AGENT_SYSTEM.md` if its testing scope is non-trivial (check current convention with the validator before completion).
- After implementation, `zig build test` MUST exit 0 with no DebugAllocator leak output.

### 7.5 Anti-pattern self-check (mandatory before completion)

The implementation MUST NOT:

- Mock, stub, or fake the allocator — `std.testing.checkAllAllocationFailures` exercises the real allocator.
- Mock, stub, or fake `parseGraphJson` — `rowToDefinitionFromFields` calls the real one.
- Replace `parseGraphJson` with a function-pointer injection point — that would mask the bug class the test is here to detect.
- Use `error.SkipZigTest` on any MUST test.
- Hardcode credentials in the test source — read everything from env.

---

## 8. Dependencies and Boundaries

### 8.1 What this module MUST continue to call

- `std.fmt.parseInt` (infallible here — fail-soft via `catch 0` / `catch null`).
- `parseUuid` (infallible here — fail-soft via `catch std.mem.zeroes(Uuid)` / `catch fallback.created_by`).
- `parseDefinitionStatus` (infallible here — fail-soft via `catch .DRAFT`).
- `parseGraphJson` (fallible — properly errdefer-guarded as of ISS-0132 / GH #427).
- `Definition.deinit` (called via the new `errdefer graph.deinit(allocator)` line).
- `std.mem.Allocator` (same parameter and usage as today).

### 8.2 What this module MUST NOT depend on (unchanged boundary)

- No HTTP-layer dependency.
- No DB-pool dependency inside `rowToDefinitionFromFields` — the wrapper keeps that.
- No `pg.zig` dependency inside `rowToDefinitionFromFields` — only the wrapper takes `[]?[]u8`.
- No new module imports; this is purely an in-file refactor of `store.zig`.

### 8.3 Caller compatibility (hard requirement)

Every existing caller of `rowToDefinition` continues to compile and run unchanged:

- `src/definition/store.zig:294` (create)
- `src/definition/store.zig:347` (getById)
- `src/definition/store.zig:688` (update)
- `src/definition/store.zig:775` (activate)
- `src/definition/store.zig:862` (deprecate / archive)
- `src/definition/store.zig:1067` (list)
- `src/definition/store.zig:1205` (search)
- `src/definition/store.zig:1511` (rowsToDefinitions)
- `src/definition/store.zig:1542` (rowsToSearchResults)

These callers are NOT to be modified. Their `catch` arms (`DefinitionError.TransactionFailed` mostly) remain in place — the only thing that changes is that the body no longer leaks on the failure path.

---

## 9. Open Questions

None for the BACKEND-DEV phase. The classification, fix pattern, test approach, and call-site boundary are all settled by the diagnosis (`docs/issue-reports/ISS-0206-diagnosis.yaml`). The TEST-DESIGNER step may add further tests (e.g. a targeted test that proves a single forced failure index frees exactly the dupes already constructed at that index — possible via `DebugAllocator` snapshots but deferred until TEST-DESIGNER).

---

## 10. Acceptance Criteria

The implementation is complete when ALL of the following hold (verified by TEST-RUNNER + RELEASE-VALIDATOR in their respective steps):

1. `rowToDefinitionFromFields` guards every one of its 4 dupes (name, version, description, stage) **plus** the graph obtained from `parseGraphJson` with an `errdefer`, so no partially-constructed `Definition` can leak. **Source: §4.5.**
2. An allocation-failure test exercises the row-to-struct mapping via `rowToDefinitionFromFields`, driven by `std.testing.checkAllAllocationFailures`. **Source: §7.1, §7.2.**
3. The test fails against the unfixed function (verified manually once by reverting the body) and passes after the fix. **Source: §7.3.**
4. `zig build test` exits 0 with no `DebugAllocator` leak output. **Source: §7.4.**
5. No caller signatures change. **Source: §8.3.**
6. No new error variants introduced. **Source: §6.**
7. No mocks, stubs, or allocator fakes. **Source: §7.5.**

---

## 11. Self-Lint

`tools/lint_design_artefact.py src/design/iss0206-rowtodefinition-errdefer.md` MUST exit 0 (no BLOCKER, no MAJOR). Sections covered:

- `Module purpose` (§1)
- `Public interface` (§4) — covers signature, new internal signature, new private struct
- `Error taxonomy` (§6) — confirms no new variants, lists what stays
- Code blocks: every fenced block in the file is under the 40-line cap enforced by the linter. The body sketch in §4.5 is split into two blocks (Block A: locals + errdefers; Block B: struct literal return) precisely so each block lands under the cap.
- Errdefer registration order: each `errdefer` is registered immediately after its corresponding `try`, in source order. On error they fire in reverse order — `graph.deinit` runs after the four text-dup frees. That order is identical to the proven parseGraphJson pattern at store.zig:1318-1421, which makes the bookkeeping mechanical and easy to audit.

---

## 12. References

- **Source issue file:** `docs/issues/ISS-0206.json` (registered 2026-08-07T04:40:47Z, severity MAJOR, status OPEN).
- **Source diagnosis:** `docs/issue-reports/ISS-0206-diagnosis.yaml` (Step 1, 2026-08-07T18:49:40Z).
- **Source step handoff:** `handoffs/WF03-GH526-20260807/step-1-issue-fixer.json`.
- **Proven fix pattern (parseGraphJson):** `src/definition/store.zig:1318-1421`, introduced in commit `7938bc65` "fix(definition): parseGraphJson errdefer counters — ISS-0132 partial (GH #427) (#527)", coverage landed in commit `8039b77c` "fix(WF03-ISS-0132): allocation-failure coverage ends an 18-run leak signature (GH #427) (#529)".
- **Proven test wiring pattern:** `src/definition_store_test_root.zig` (the shim that exposes `store.zig` to `addTest`), wired into `build.zig` per the search results showing `run_definition_store_tests` and the aggregate `test_step.dependOn(&run_definition_store_tests.step)` attachment.
- **Lint constraints:** `tools/lint_design_artefact.py` (E001 empty, E010 missing section, E020 TODO heading, E030 schema-qualified name, E040 SQL interpolation, E050 fenced block > 40 lines, E060 requirement-id format).
- **Design guide:** `docs/guides/backend_developer_guide.md` (in-file test discovery and `addTest` wiring rules).
- **Anti-patterns:** `docs/anti-patterns.md` (no `catch unreachable` on realistic failure paths; no string interpolation of SQL — neither relevant here, both guarded against).

---

**END OF DESIGN ARTEFACT.**