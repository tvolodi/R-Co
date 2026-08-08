# Module: ISS-0174 / GH-502 — `CapabilitySet.summary()` Zig 0.16 unmanaged `ArrayList` migration

**Issue:** [GitHub #502 — `src/lua/capabilities.zig` carries a stale `std.ArrayList(u8).init(allocator)` call that is invisible to `zig build test-lua` because `src/lua_test_root.zig` pins the file with a bare type reference](https://github.com/tvolodi/R-Co/issues/502)
**Severity:** MAJOR (production source does not compile under Zig 0.16; test target reports green; latent regression class)
**Component:** `src/lua/capabilities.zig` (function `CapabilitySet.summary`, lines 44–63) + `src/lua_test_root.zig` (pin upgrade at line 95) + new `tests/specs/ISS-0174-gh502-capabilityset-summary.md`
**Branch:** `feature/WF03-GH502-20260808` (at `origin/main` @ `17930725`)
**Decision:** **RETAIN** `summary()`. Migrate to Zig 0.16 unmanaged `ArrayList` API. Add a real call from `zig build test-lua`. Lock in the longjmp-unsafe contract on the function's doc comment.
**Related issues:**
- ISS-0169 / GH-495 — original ERR-2 longjmp-safety rationale for keeping `writeGrants` separate from `summary()`.
- ISS-0172 / GH-500 — pin-form blind spot (sister issue). The procedure that surfaced this issue.
- ISS-0173 / GH-501 — zero-callers census. SHOULD-1 extends that census to `pub fn` granularity under `src/lua/`.

---

## 1. Interface / Type changes

The migration is purely an API-surface migration of `pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8`. **The function signature is unchanged.** The body is rewritten to call the unmanaged form of every `std.ArrayList(u8)` method. The owner contract (caller owns the returned slice) and the empty-grants contract (return the literal `"(none)"`) are preserved verbatim.

### BEFORE — `src/lua/capabilities.zig` lines 44–63 (current source, as of `17930725`)

```zig
44:     /// Get a summary string of granted capabilities for error messages.
45:     /// Caller owns the returned memory.
46:     pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8 {
47:         if (self.grants.count() == 0) {
48:             return allocator.dupe(u8, "(none)");
49:         }
50:
51:         var buf = std.ArrayList(u8).init(allocator);
52:         defer buf.deinit();
53:
54:         var iter = self.grants.keyIterator();
55:         var first = true;
56:         while (iter.next()) |key| {
57:             if (!first) {
58:                 try buf.appendSlice(", ");
59:             }
60:             try buf.appendSlice(key.*);
61:             first = false;
62:         }
63:
64:         return buf.toOwnedSlice();
65:     }
```

> Note: in the actual file, lines 49–60 are the lines that hold the stale API calls. Line numbers 44–63 above are the design's pre-migration view; the diagnosis YAML's line range covers the same body.

### AFTER — `src/lua/capabilities.zig` lines 44–63 (target shape after BACKEND-DEV Step 3)

```zig
44:     /// Get a summary string of granted capabilities for error messages.
45:     /// Caller owns the returned memory.
46:     ///
47:     /// **Longjmp-unsafe (ERR-2).** This function allocates. Inside a context
48:     /// that may raise via `lua_error` (which longjmps), the returned slice
49:     /// would leak. The longjmp-safe twin is `writeGrants` in
50:     /// `src/lua/host_context.zig`, which walks the grant set directly into
51:     /// a fixed stack buffer. Use this `summary()` ONLY from contexts that
52:     /// own the result's lifetime cleanly (host-API startup diagnostics,
53:     /// audit log lines, REST error responses for missing capability
54:     /// metadata).
55:     pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8 {
56:         if (self.grants.count() == 0) {
57:             return allocator.dupe(u8, "(none)");
58:         }
59:
60:         var buf: std.ArrayList(u8) = .empty;
61:         defer buf.deinit(allocator);
62:
63:         var iter = self.grants.keyIterator();
64:         var first = true;
65:         while (iter.next()) |key| {
66:             if (!first) {
67:                 try buf.appendSlice(allocator, ", ");
68:             }
69:             try buf.appendSlice(allocator, key.*);
70:             first = false;
71:         }
72:
73:         return buf.toOwnedSlice(allocator);
74:     }
```

The five line-level edits are itemised in §5.

### Signature (unchanged)

```zig
pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8
```

- **Parameter 1:** `self: *const CapabilitySet` — the set to render.
- **Parameter 2:** `allocator: std.mem.Allocator` — the unmanaged `ArrayList`'s allocator argument is passed per call (was bound at construction time under the managed API).
- **Returns:** `![]const u8` — an owned, heap-allocated slice. On success, the caller MUST `allocator.free(slice)` when done. On failure, the function returns `error.OutOfMemory` (was already the case under managed `ArrayList` in Zig 0.16).

### Other public API of `CapabilitySet` (unchanged by this migration)

| Function | Signature | Effect of this migration |
|---|---|---|
| `init(allocator)` | `CapabilitySet` | unchanged |
| `deinit(self)` | `void` | unchanged |
| `add(self, cap)` | `!void` | unchanged |
| `has(self, cap)` | `bool` | unchanged |
| `summary(self, allocator)` | `![]const u8` | **rewritten** (managed → unmanaged `ArrayList`) |

`writeGrants` in `src/lua/host_context.zig` is **not** part of this migration. It is allocator-free by design (writes into a fixed stack buffer via `Writer`) and remains the longjmp-safe path. Both functions continue to exist in parallel: `summary()` for non-longjmp callers, `writeGrants` for the Lua error frame.

---

## 2. Longjmp-safety contract (doc comment on `summary`)

The new doc comment is shown in §1 lines 46–54 above. The contract is restated here in plain text so the rationale is searchable from `docs/anti-patterns.md` and from any future code-search:

```
**Longjmp-unsafe (ERR-2).** This function allocates. Inside a context that
may raise via `lua_error` (which longjmps), the returned slice would leak.
The longjmp-safe twin is `writeGrants` in `src/lua/host_context.zig`, which
walks the grant set directly into a fixed stack buffer. Use this
`summary()` ONLY from contexts that own the result's lifetime cleanly
(host-API startup diagnostics, audit log lines, REST error responses for
missing capability metadata).
```

This mirrors the existing comment style of `writeGrants` (which says: _"Deliberately NOT `CapabilitySet.summary()`, which allocates: its result would be leaked by `lua_error`'s longjmp (ERR-2)"_). The two doc comments form a paired contract that future maintainers can grep on `ERR-2` to find both halves.

---

## 3. New test specification

The test specification lives at **`tests/specs/ISS-0174-gh502-capabilityset-summary.md`** (written in this step, alongside this design). Five test cases:

| Test case | Branch | Asserts on |
|---|---|---|
| **TC-CS-01** | Empty grants | `summary(std.testing.allocator)` returns the literal `"(none)"`; length 6; free is a no-op |
| **TC-CS-02** | Single grant | `summary` returns the grant string verbatim; length matches input |
| **TC-CS-03** | Multiple grants | Comma-separated, deterministic order (sorted by `std.mem.lessThan` on the byte content — see §3a for the determinism choice) |
| **TC-CS-04** | Allocator honoured | `std.testing.allocator` is invoked; leak detector returns 0 |
| **TC-CS-05** | Ownership | Returned slice is owned by the caller — caller MUST `free`; double-free is detectable by `std.testing.allocator` |

### §3a Determinism choice — sorted order vs insertion order

**Choice:** sort the grant keys lexicographically before joining.

- **Why:** `std.StringHashMap(void)` iterates in **arbitrary** order across Zig versions and allocator instances. The empty case is order-independent. The multi-grant case must be deterministic for test assertions and for stable audit log output, so `summary` MUST sort the keys before joining. The cost is `O(n log n)` per call (with `n` = grant count), which is bounded — capability sets carry on the order of 1–10 grants in practice.
- **Implementation note for BACKEND-DEV:** collect the keys into a `std.ArrayList([]const u8)` first, `std.mem.sort` them by `std.mem.lessThan(u8, ...)` with a temporary buffer, then iterate the sorted list to produce the joined string. The sorting must happen after the empty-check (`(none)` short-circuit) and before the join. If BACKEND-DEV prefers a different determinism strategy (e.g. sort on insertion and never re-sort), the design permits it provided TC-CS-03's assertion `mem.contains(sorted, ",")` and `mem.contains(sorted, "service:call:")` are met — but the simplest correct form is sort-then-join and that is the recommended path.
- **Public contract update:** the doc comment gains one extra line: _"Grants are listed in lexicographic order of their byte content."_

### §3b `tests/specs/ISS-0174-gh502-capabilityset-summary.md` (full content written in this step)

See the sibling file at `tests/specs/ISS-0174-gh502-capabilityset-summary.md` for the full TC-CS-01..05 specification. It is wired into the build by §4 below.

---

## 4. Build wiring — where the real call lives

The new test root is `src/lua_test_root.zig` (the file that already wires the entire `src/lua/` subsystem into `zig build test-lua`). The bare-type pin at `src/lua_test_root.zig:95` (`_ = lua.capabilities.CapabilitySet;`) is **upgraded to a real call** by replacing it with a new dedicated test block.

### Location: new `test` block appended after the existing `test "ISS-0153: every file in the src/lua subsystem is analysed"` block

The new test block is added immediately after the closing brace of the `ISS-0153` block (which is the file that already pins every Lua subsystem file with a real `refAllDecls` / `@sizeOf` / direct call — see §Rot of that file's doc comment for the seven categories of stale API it previously caught).

```zig
// Appended after the ISS-0153 block, before the ISS-0161 block.
test "ISS-0174 / GH-502: CapabilitySet.summary() compiles, runs, and renders both branches" {
    var gpa = std.testing.allocator;

    // TC-CS-01: empty set -> "(none)"
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();
        const slice = try caps.summary(gpa);
        defer gpa.free(slice);
        try std.testing.expectEqualStrings("(none)", slice);
    }

    // TC-CS-02: single grant -> grant verbatim
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();
        try caps.add("service:call:payment");
        const slice = try caps.summary(gpa);
        defer gpa.free(slice);
        try std.testing.expectEqualStrings("service:call:payment", slice);
    }

    // TC-CS-03: multiple grants -> sorted, comma-separated
    {
        var caps = lua.capabilities.CapabilitySet.init(gpa);
        defer caps.deinit();
        try caps.add("variable:write");
        try caps.add("service:call:payment");
        try caps.add("audit:log");
        const slice = try caps.summary(gpa);
        defer gpa.free(slice);
        try std.testing.expectEqualStrings("audit:log, service:call:payment, variable:write", slice);
    }

    // TC-CS-04: allocator is honoured. The mere presence of three `gpa.free`
    // calls above — all of which only succeed if `gpa` actually owns the
    // returned slices — proves the allocator is invoked. The leak detector
    // on `zig build test-lua` would report a leak if `summary` were dropping
    // the slice or returning a stack-allocated buffer.

    // TC-CS-05: ownership is on the caller. The `defer gpa.free(slice)` lines
    // above demonstrate the contract; a `try caps.summary(gpa); ... ; gpa.free(slice);`
    // pair that did NOT free would surface as a leak under the `gpa`'s leak
    // detector.
}
```

### Why `src/lua_test_root.zig` and not `src/lua/host_context.zig`

The diagnosis YAML's MUST-2 considered two options. **Option (a) — a new `test` block in `src/lua_test_root.zig` — is chosen** because:

1. **Self-contained.** The test does not need any other `src/lua/` subsystem (no `LuaState`, no `ExecutionContext`, no host function). It tests a pure utility on the `CapabilitySet` data structure. Keeping it in the test root keeps the dependency surface minimal.
2. **Symmetric with the ISS-0153 / ISS-0169 pin pattern.** The existing `ISS-0153` block already pins every `src/lua/` file with a real decl reference (or `@sizeOf`, or a real call). Adding the new test block next to it preserves the "every file has a reachable test target" invariant without restructuring.
3. **No change to runtime semantics.** The `ISS-0169: the context round-trips through the registry` test in `src/lua/host_context.zig:447`+ would also work, but changing that path to add a `summary()` call inside the host-context test would couple the new regression lock to the host-context test's lifetime, allocator, and capability seeding. Option (a) decouples it.

### Why NOT a `refAllDecls` upgrade

`std.testing.refAllDecls(lua)` is documented as shallow over containers; it does NOT force analysis of every `pub fn` body. The existing `test "ISS-0153: every file in the src/lua subsystem is analysed"` block works around this with explicit pins (`_ = host_api.call_service.register;`). The new `ISS-0174` block follows the same pattern with explicit calls, not `refAllDecls`.

---

## 5. Substitution rules (BEFORE → AFTER mapping)

The five line-level edits in `src/lua/capabilities.zig` (the body of `CapabilitySet.summary`). Each rule is one token-level edit.

| # | BEFORE (Zig 0.15 managed API) | AFTER (Zig 0.16 unmanaged API) |
|---|---|---|
| S1 | `var buf = std.ArrayList(u8).init(allocator);` | `var buf: std.ArrayList(u8) = .empty;` |
| S2 | `defer buf.deinit();` | `defer buf.deinit(allocator);` |
| S3 | `try buf.appendSlice(", ");` | `try buf.appendSlice(allocator, ", ");` |
| S4 | `try buf.appendSlice(key.*);` | `try buf.appendSlice(allocator, key.*);` |
| S5 | `return buf.toOwnedSlice();` | `return buf.toOwnedSlice(allocator);` |

### Notes

- **S1** — `std.ArrayList(u8).init` no longer exists under Zig 0.16. The unmanaged constructor is `std.ArrayList(u8){}` (undefined items) or the documented idiom `std.ArrayList(u8).empty`. The design uses `.empty` for clarity.
- **S2** — the unmanaged `deinit` requires the allocator to free the backing storage. Without `allocator`, `deinit` cannot free.
- **S3, S4** — the unmanaged `appendSlice` signature is `appendSlice(self: *Self, allocator: Allocator, items: []const T) !void`. The first parameter is now the allocator.
- **S5** — the unmanaged `toOwnedSlice` signature is `toOwnedSlice(self: *Self, allocator: Allocator) ![]T`. The first parameter is now the allocator.
- **The empty-grants short-circuit (`return allocator.dupe(u8, "(none)");`) is unchanged.** The `dupe` call is allocator-argument-by-construction and is already 0.16-correct. No edit needed at lines 47–48.

### Edits NOT made

- The function signature (`pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8`) is unchanged. The owner contract is unchanged.
- The empty-grants branch is unchanged.
- No new error variants are added (the `!` in the signature already covers `error.OutOfMemory`, which is what `toOwnedSlice` and `appendSlice` return on failure).
- `CapabilitySet.init` and `CapabilitySet.deinit` are not touched (they have callers, they compile, they are not in scope for this migration).

---

## 6. Deliberate-mutation verification

After MUST-1 and MUST-2 land, BACKEND-DEV runs the **ISS-0172 procedure**: inject a deliberate type error into `summary()`'s body, run `zig build test-lua`, confirm the target goes red, revert the mutation, confirm green.

### Procedure (BACKEND-DEV executes in Step 3, after migration lands)

```powershell
# Pre-condition: the test from §4 passes; zig build test-lua is green.

# Step A — mutate (anywhere after `defer buf.deinit(allocator);`)
# Insert this line, for example after line 60:
#     const _bad: u32 = "definitely not a u32";
# (Type error: assigning a []const u8 string literal to a u32.)

# Step B — run, expect red
zig build test-lua
# Capture exit code; expected: 1.
# Capture the error line; expected: a Zig "expected u32, found *const [n:0]u8" diagnostic.

# Step C — revert
git checkout src/lua/capabilities.zig

# Step D — run, expect green
zig build test-lua
# Expected: exit 0, 73/73 tests passed (was 71/71; +2 from the new test block's
# three sub-cases if Zig counts sub-tests; or +1 if it counts only the outer
# `test` block).
```

### What proves MUST-3 is satisfied

- **Pre-mutation:** `zig build test-lua` exits 0.
- **Post-mutation:** `zig build test-lua` exits 1 with a Zig type error citing the injected statement. This proves Zig's semantic analyser now reaches the body of `summary()` — which it did NOT do before the migration, because no caller invoked it.
- **Post-revert:** `zig build test-lua` returns to exit 0.

If any of these three steps fails, MUST-3 is NOT satisfied and the BACKEND-DEV handoff (Step 3) reports it as a BLOCKER. The deliberate-mutation result is captured in `step-03-backend-dev.json`'s `result.must3_evidence` field.

### Why a type error, not a runtime error

A runtime error (e.g. divide by zero, dereference null) inside a body that is never invoked would not surface in the build either. The point of the mutation is to put a statement in the body that Zig's compile-time type-checker MUST analyse, and that the type-checker MUST reject. The literal `"definitely not a u32"` bound to `const _bad: u32` produces exactly that: a deterministic type error that has nothing to do with runtime behaviour.

---

## 7. Out-of-scope

The following items are **explicitly deferred** to other runs (or rejected as not in scope for this fix):

| Item | Status | Rationale |
|---|---|---|
| **SHOULD-1** — Extend the ISS-0173 / GH-501 zero-callers census to `pub fn` granularity under `src/lua/` (and optionally the whole repo). | **Deferred** to a follow-up WF-03 run. | The classification bucket (a/b/c) needs human review per finding. This run delivers the data point for `CapabilitySet.summary` and the procedure; the broader census is its own run. |
| **SHOULD-2** — Strengthen `tools/lint_test_wiring.py` to flag type-only pins. | **Deferred** to ISS-0172 / GH-500 follow-up (same item, restated here for visibility). | Same item as ISS-0172 acceptance criterion #4. May be addressed jointly with that issue. |
| **Doc-comment audit for OTHER longjmp-unsafe functions.** | **Out of scope** for this run. | `writeGrants`'s existing doc comment already covers the contract on the longjmp-safe side; `summary`'s new comment covers the longjmp-unsafe side. Auditing every other `src/lua/` function for similar missing comments is a separate effort. |
| **Renaming `summary()` to a different name** (e.g. `summaryAllocating` to flag the contract). | **Rejected.** | The function is public; renaming would force a coordinated rename of every (currently-zero) caller-side doc reference. The new doc comment captures the contract more durably than a rename. |
| **Deleting `summary()` entirely.** | **Rejected.** | Per `fix_plan.decision` in the diagnosis YAML and the §1 "decision: RETAIN" header of this design. Deletion would silently regress ISS-0169 ERR-2 architecture: `summary()` is the legitimate utility for any non-longjmp caller (host-API startup diagnostics, audit log lines, REST error responses for missing capability metadata), and `writeGrants` is the allocator-free twin specifically for the Lua error frame. Both exist for a reason. |
| **Refactoring `CapabilitySet.grants` to `std.ArrayList([]const u8)`** instead of `std.StringHashMap(void)`. | **Out of scope.** | HashMap iteration order is the only reason `summary()` needs to sort. Changing the data structure would touch every caller (`add`, `has`, `deinit`, the iteration in `writeGrants`), is unrelated to the 0.16 compile-error fix, and would expand the diff well beyond what MUST-1 needs. |

---

## Acceptance criteria reproduced (from the diagnosis YAML)

| # | Criterion | Classification | Addressed by |
|---|---|---|---|
| 1 | `src/lua/capabilities.zig` compiles under Zig 0.16 with function bodies genuinely analysed | MUST | §1 (after), §4 (real call), §6 (deliberate-mutation) |
| 2 | `std.ArrayList(u8).init(allocator)` migrated to unmanaged 0.16 API (`.empty` + allocator-passing `appendSlice`/`toOwnedSlice`/`deinit`) | MUST | §5 (S1–S5) |
| 3 | A build target CALLS `CapabilitySet.summary()` and asserts on its output (empty + multi-grant) | MUST | §4 (new test block), §3 (TC-CS-01..05) |
| 4 | Deliberate-mutation verification: inject statement error → `zig build test-lua` goes red | MUST | §6 (procedure) |
| 5 | Decision recorded on whether `summary()` should exist at all (retain for non-longjmp callers or delete) | MUST | Header (decision: RETAIN); §1 ("Decision" callout); §2 (longjmp contract); §7 (rejected alternatives) |
| 6 | Census from #501 extended to public functions with zero callers | SHOULD | §7 (deferred to follow-up run; this run delivers the `summary` data point + the procedure) |

---

## Acceptance criteria for this design step (CODE-DESIGNER exit gate)

This design artefact is COMPLETED when:

- [x] All four files exist at the paths listed in §3, §4, and the design header.
- [x] The five substitution rules in §5 are each one-line token edits, not multi-line rewrites.
- [x] §6 captures the deliberate-mutation procedure with concrete shell commands.
- [x] §7 enumerates every SHOULD-1 / SHOULD-2 / out-of-scope item explicitly so BACKEND-DEV cannot accidentally expand the scope.
- [x] The handoff (`step-02-code-designer.json`) routes to CODE-DESIGN-VALIDATOR (Step 2b next) with `next_action` set.
- [x] `python tools/lint_handoffs.py handoffs/WF03-GH502-20260808/` exits 0.
