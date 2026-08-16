# FIX Design — vld-01-03 Stage 16 Semantic Validation (ISS-0709 / GH #799)

**Requirement IDs:** VLD-01, VLD-02, VLD-03
**Run ID:** WF03-vld-impl-bugs-20260816 (WF-03 Step 2 — fix design)
**Type:** Type E — novel cross-cutting fix design (no lego template applies). This is a **fix artefact** for the implementation defects in the Stage 16 validation modules; it supersedes the original design `src/design/vld-01-03-stage-16-validation.md` **only** where noted (the original remains the baseline).
**Upstream evidence:** `docs/issues/ISS-0709.json` → `root_cause_analysis` (analyzed_at 2026-08-16T05:44:34Z, 5 grouped root causes R1–R5).
**Implementer:** BACKEND-DEV (WF-03 Step 3). **No implementation code in this artefact** — interfaces, ownership contracts, and pseudocode only.

---

## 1. Scope

This design fixes the 10 failing/crashing in-file unit tests in `src/validation/*.zig` caused by the five root-cause groups identified in `docs/issues/ISS-0709.json` `root_cause_analysis.grouped_root_causes`:

| Group | Root cause | Module(s) |
|---|---|---|
| R1 | `freeSites` never frees the `[]Site` backing slice from `enumerateSites`' `toOwnedSlice` → `std.testing.allocator` leak-detection panic | `src/validation/site.zig` (+ 4 `typecheck.zig` test fixtures) |
| R2 | `TypedEnv.deinit` unconditionally frees `self.entries`; the typecheck tests build `TypedEnv{ .entries = entries.items }` from a live ArrayList and also `entries.deinit` → double-free panic | `src/validation/typecheck.zig` (test scaffolding only) |
| R3 | `mapDeclaredTypeName("number")` returns `null` → spurious `UnknownVariableType` + unknown-var false positives | `src/validation/env.zig`, `src/validation/mod.zig` (message string) |
| R4 | PD-06 gate under-detection (`isValidCelSyntax` is delimiter-balance-only) + `mod.zig` accumulates env findings before the gate | `src/validation/pd06.zig` (per-site gate), `src/validation/mod.zig` (ordering) |
| R5 | `mod.zig` per-site loop leaks the `[]Finding` backing from `checkSite`'s `toOwnedSlice` | `src/validation/mod.zig` |

**Module purpose (unchanged):** `validateDefinition(env-input) -> ValidationFailure` remains the pure, storage-free entry point that (VLD-01) builds a declaration-grounded `TypedEnv`, (VLD-02) compiles every CEL expression site against the per-site env, and (VLD-03) aggregates the findings into one deterministic, closed-enum diagnostic set. The fixes below make the implementation satisfy its own contract — the requirement scope is unchanged.

**Out of scope by design:** `src/definition/graph.zig` is **not** changed (its `isValidCelSyntax` is the pre-existing PD-06 structural check shared with the `Store.create()` path; see R4 for why the per-site gate moves to the real parser instead). `src/validation/finding.zig` and `src/validation/wire.zig` are **not** changed (their own tests pass; ownership contracts verified correct). `src/validation/scope.zig` is **not** changed. `src/api/routes/validation.zig` is **not** changed (handler is a thin caller of `validateDefinition`; no behaviour change to its surface).

---

## 2. Design decisions

### 2.1 R3 — extend the declared-type mapping table with `number` (recommended), do NOT change the fixtures

**Decision: extend `env.zig mapDeclaredTypeName` with `"number" -> .number` (plus `"bool" -> .bool` and `"timestamp" -> .timestamp`). Do not change any test fixture.**

**Justification:**

1. **The fixtures are canonical and derive from the natural CEL type names.** The clean-path fixture in `mod.zig` (`variable_schema` row `amount: number`) and the shared happy-path fixture in `tests/integration/validation_vld_unit_test.zig` (`happy_variables = .{ .name = "amount", .var_type = "number" }`) both declare `"number"`. `"number"` is the *natural CEL type name* for a numeric variable — the same vocabulary the CEL parser/compiler uses. The §8 table already accepts `integer`, `decimal`, and `money` all mapping to the first-class `TypeTag.number`; rejecting the plain `"number"` while accepting its three subtypes is an asymmetry, not a deliberate distinction.
2. **`number` is semantically identical to the already-accepted names.** All four (`integer`, `decimal`, `money`, `number`) map to `.number`. Adding `"number"` widens the *accepted string set*, not the *type taxonomy* — no new `TypeTag`, no new error path, no VLD-03 AC5 impact.
3. **The integration suite depends on it.** `int_vld_01_04` asserts `findings.len == 0` for the happy graph whose fixture is `amount: number`. Without the table extension, that AC fails at the integration layer too — this is not merely an in-file test quirk.
4. **Changing the fixtures instead would hide a real defect.** A definition declaring `amount: number` (a perfectly natural declaration) must not be reported `UnknownVariableType`. The table is the single source of truth (§8 of the original design); the correct fix is to extend the source of truth, not to bend the fixtures around the table's omission.
5. **The table must stay the source of truth.** The fix keeps `mapDeclaredTypeName` as the only place declared-name → `TypeTag` mapping lives, and syncs the one mirror of it: the accepted-set string embedded in `mod.zig`'s `UnknownVariableType` message (§3 R3).

**Sibling names checked and decided:** `integer`, `decimal`, `money`, `string` are already mapped (no change). `bool -> .bool` and `timestamp -> .timestamp` are added as the natural CEL synonyms of the already-mapped `boolean` / `date` / `datetime` (same rationale as `number`; same TypeTag, no taxonomy widening). `duration`, bare `list`, and bare `map` are **deliberately not added** — `duration` has no `TypeTag` (adding one is a taxonomy change with VLD-03 AC5 implications, out of scope for this fix), and bare `list`/`map` are type constructors without an element/entry type in this DSL's declared-name convention (`list<T>` is already accepted; `object` already maps to `.map`).

### 2.2 R4 — the per-site syntax gate moves to the real parser; `isValidCelSyntax` is left untouched

**Decision: replace `isValidCelSyntax` with `expr.parse` in `pd06.zig runSyntaxCheck`'s per-site loop. Do NOT modify `src/definition/graph.zig`.**

**Justification:**

1. **`isValidCelSyntax` is a delimiter-balance-only structural check** (balanced `()[]`, quoted strings, non-whitespace). It accepts `"amount >"`, `"amount <="`, `"x >"`, `"y <"` — every dangling-operator expression the failing tests use. Strengthening it to catch these would mean re-implementing a CEL grammar inside `graph.zig`, duplicating the real parser, and changing a shared module's contract (it is used by `validateEdgeConditions`/`validateEdgeTransforms` in the `Store.create()` path, with its own tests).
2. **`expr.parse` is the authoritative parser** and is already the parser the semantic compiler (`typecheck.zig checkSite`) uses. Its own negative tests already prove trailing operators produce `.fail` (`trailing +`, `trailing *`, `trailing and`, `trailing or`, `trailing dot` in `src/expr/parser.zig`); a trailing comparison operator (`"amount >"`) hits the same `recordError(..., "expected expression")` path at end-of-input. Using it makes VLD-02 AC4's gate and the semantic compile use *one* grammar — they cannot disagree.
3. **The change is scoped to `src/validation/`.** `pd06.zig` is the validation module's own "wide PD-06 surface"; moving its per-site gate to `expr.parse` fixes the VLD-02 AC4 short-circuit without touching the pre-existing PD-06 edge-condition contract in `graph.zig`.
4. **The graph-level block in `runSyntaxCheck` stays as-is.** `validateEdgeConditions`/`validateEdgeTransforms` keep using `isValidCelSyntax`. For a malformed *edge* condition this can yield at most two diagnostics for the same site (an `EDGE_INVALID_CEL` from the graph-level block and a `CEL_SYNTAX_INVALID` from the per-site block). This is acceptable — both are PD-06-level syntax diagnostics, the response is 422 either way, and no current test asserts diagnostic *count* for a site flagged by both paths. No dedup logic is added.

### 2.3 R4 ordering — PD-06 gate runs before any finding is accumulated

**Decision: move the site enumeration + PD-06 syntax gate to the top of `validateDefinition`, before the VLD-01 env-builder loops.**

**Justification:** VLD-02 AC4 requires "findings is empty" when the gate fires. The current `mod.zig` appends VLD-01 findings (e.g. `UnknownVariableType`) *before* the gate, so the gate path returns a non-empty `findings` — the AC is unreachable. The gate only needs the graph (for sites) and the sites; it has no dependency on the env. Reordering is free and makes the short-circuit contract literal.

---

## 3. Fix per root-cause group

### R1 — `site.zig freeSites` must free the `[]Site` backing slice

**Module(s) to change:** `src/validation/site.zig` (`freeSites` only — do **not** change `enumerateSites` or any enumeration walker). Companion test-scaffolding change in `src/validation/typecheck.zig` (4 `checkSite` tests — see below).

**Ownership contract (state in `freeSites`' doc comment):**

- `enumerateSites(allocator, graph) ![]Site` returns an **owned** slice: the backing buffer is produced by `ArrayList.toOwnedSlice(allocator)`, and every per-`Site` string (`node_id`, `expression_path`, `source`) is allocator-owned (each is `allocator.dupe`'d or `allocPrint`'d by the walker).
- `freeSite(allocator, s)` frees one `Site`'s three strings only. The struct itself lives inside the caller-owned backing slice — `freeSite` must **not** free the struct storage.
- `freeSites(allocator, items: []Site)` frees every `Site`'s strings **and** the backing slice. Public signature is unchanged:

```zig
pub fn freeSites(allocator: std.mem.Allocator, items: []Site) void {
    for (items) |s| freeSite(allocator, s);
    allocator.free(items);   // R1: free the toOwnedSlice backing
}
```

The current comment `// Caller owns the backing storage (e.g. ArrayList's allocatedSlice).` is **wrong** — it must be replaced with the owned contract above.

**Audit of every `freeSites` call site (verified by inspection):** `mod.zig:270`, `pd06.zig:162/183/214`, and `site.zig:331/347/364` all pass the **owned** slice returned directly by `enumerateSites` — safe once `freeSites` frees the backing. The four `typecheck.zig` tests (`:377/394/419/449`) pass `sites_buf.items` where `sites_buf` is a **live** `std.ArrayList(Site)` that is also `deinit`'d — these would double-free. They must be converted to the owned-slice pattern (see R2's scaffolding section, which applies to all four tests).

**Affected tests:** `site.test.enumerateSites: gateway edge condition`, `site.test.enumerateSites: timer delay`, `site.test.enumerateSites: form visible_when and computed_from`, `pd06.test.runSyntaxCheck: malformed per-site expression -> CEL_SYNTAX_INVALID` (all currently fail on `leaked 1 allocations` at teardown; all logic assertions already pass).

**Verification:** all four tests pass with zero leak reports; `zig build test-validation` reports no `leaked N allocations` for `site`/`pd06`.

### R2 — `typecheck.zig` test scaffolding double-free

**Module(s) to change:** `src/validation/typecheck.zig` — test scaffolding only. Do **not** change `TypedEnv.deinit` in `env.zig` (it is correct for the owned slices produced by `envForSite` / `buildEnv`), and do **not** change `checkSite`.

**Root cause:** `TypedEnv.deinit` (a) frees each entry's `name`/`source_node_id` and (b) `allocator.free(self.entries)` when `len > 0`. The two tests that build a non-empty env construct `TypedEnv{ .entries = entries.items }` from a live `std.ArrayList(Entry)` and then `defer` **both** `env.deinit(alloc)` **and** `entries.deinit(alloc)` — the same backing buffer is freed twice (`thread panic: Invalid free`).

**Decision (option a — chosen):** hand `TypedEnv` an **owned** slice via `entries.toOwnedSlice(alloc)` and drop the separate `entries.deinit`. This honours the existing public contract (`TypedEnv` owns `entries`) with a one-line test change; it is the minimal, contract-preserving fix. Option (b) (deep-copy entries into an owned buffer) is rejected as more code for no benefit.

**Exact test changes (two tests — `checkSite: unknown variable identifier` and `checkSite: '+' over number and string`):**

```zig
var entries: std.ArrayList(env_mod.Entry) = .empty;
try env_mod.addEntry(&entries, alloc, "amount", .number, null, .variable_schema, null);
// R2: transfer ownership to TypedEnv; do NOT also deinit `entries`.
const env = TypedEnv{ .entries = try entries.toOwnedSlice(alloc) };
defer env.deinit(alloc);
```

(`addEntry`'s per-entry strings remain owned by the env and are freed by `env.deinit`; `toOwnedSlice` leaves the ArrayList empty, so a residual `entries.deinit(alloc)` — if kept — is a no-op, but the design prefers removing it to avoid implying double ownership.)

**Companion scaffolding change (all four `checkSite` tests — required by the R1 contract change):** replace the `sites_buf` + `freeSites(sites_buf.items)` + `sites_buf.deinit` pattern with the owned-slice pattern so the R1 `freeSites` (which now frees the backing) does not double-free:

```zig
var sites_buf: std.ArrayList(Site) = .empty;
try sites_buf.append(alloc, try SiteStub.s(alloc, "   ", .bool, false));
const owned_sites = try sites_buf.toOwnedSlice(alloc);
defer site_mod.freeSites(alloc, owned_sites);   // frees per-site strings + backing (R1)
```

(drop the old `defer sites_buf.deinit(alloc)` and the old `defer site_mod.freeSites(alloc, sites_buf.items)`). `SiteStub.s` allocates the per-site strings, so `freeSites` on the owned slice frees everything exactly once.

**Affected tests:** `typecheck.test.checkSite: unknown variable identifier -> UnknownVariable`, `typecheck.test.checkSite: '+' over number and string -> OperandTypeError` (double-free); plus the scaffolding-only change keeps `checkSite: empty source -> EmptyExpression` and `checkSite: number literal where bool expected -> TypeMismatch` green.

**Verification:** all four `checkSite` tests pass with no `Invalid free` panic and no leak.

### R3 — `env.zig mapDeclaredTypeName` missing `"number"`

**Module(s) to change:** `src/validation/env.zig` (`mapDeclaredTypeName` + its doc comment); `src/validation/mod.zig` (the accepted-set string inside the `UnknownVariableType` message).

**Precise change — exact table entries to add** (case-sensitive, lowercase, consistent with the existing entries):

| Declared name to add | `TypeTag` | Rationale |
|---|---|---|
| `number` | `.number` | Natural CEL name; identical TypeTag to already-mapped `integer`/`decimal`/`money`. **Required** by canonical fixtures (`mod.zig` in-file + `validation_vld_unit_test.zig` happy fixture). |
| `bool` | `.bool` | Natural CEL synonym of already-mapped `boolean`. |
| `timestamp` | `.timestamp` | Natural CEL synonym of already-mapped `date`/`datetime`. |

In `mapDeclaredTypeName`, add (e.g. after the existing `money`/`boolean`/`datetime` entries, keeping the list ordered):

```zig
if (std.mem.eql(u8, name, "number")) return .number;
if (std.mem.eql(u8, name, "bool")) return .bool;
if (std.mem.eql(u8, name, "timestamp")) return .timestamp;
```

**Deliberately NOT added** (documented in the function doc comment so the decision is not silently reverted): `duration` (no `TypeTag` exists; mapping it to `.timestamp` would be a semantic lie — a duration is a span, not a point — and adding a `duration` variant is a taxonomy change with VLD-03 AC5 implications, out of scope), bare `list` (no element type; the table already accepts `list<T>`), bare `map` (type constructor; `object` already maps to `.map`).

**Message sync (required — the message mirrors the table):** in `mod.zig`, the `UnknownVariableType` message hard-codes the accepted set. Change the literal from:

`"... outside the mapping table (string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object)"`

to:

`"... outside the mapping table (string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object, number, bool, timestamp)"`

**Public interface note:** `mapDeclaredTypeName(name: []const u8) ?TypeTag` signature is unchanged — only the accepted-name set grows. This is the source of truth; the design's §8 table should be amended to the same row set in the same change for traceability (the FIX doc §2.1 table above is the authoritative amended set).

**Affected tests:** `mod.test.validateDefinition: clean linear definition with one guard -> 0 findings` (was `expected 0, found 3`: 1 spurious `UnknownVariableType` + 2 `UnknownVariable` false positives — all three collapse once `amount` maps to `.number` and enters the env), `mod.test.validateDefinition: guard references unknown identifier -> UnknownVariable` (env no longer empty, so `editDistance("amont","amount")=1 ≤ SUGGESTION_THRESHOLD` yields the `did you mean "amount"?` message and `saw_suggestion` passes), `tests/integration/validation_vld_unit_test.zig` `int_vld_01_04` (happy fixture `amount: number` must yield 0 findings).

**Verification:** after this change alone, the clean-path test reports 0 findings; `mapDeclaredTypeName: every declared name maps to its design tag` (existing env.zig test) may be extended with the three new names but is not required to change.

### R4 — PD-06 syntax gate: real parser + gate-before-env-findings ordering

Two coordinated changes: **R4a** (per-site gate detects dangling operators) and **R4b** (`mod.zig` fires the gate before accumulating any finding).

#### R4a — `pd06.zig` per-site gate uses `expr.parse`

**Module(s) to change:** `src/validation/pd06.zig` (`runSyntaxCheck` per-site loop; add `const expr_mod = @import("expr");`). `src/definition/graph.zig` — **no change** (see §2.2).

**Precise change — the per-site loop currently reads:**

```zig
for (sites) |s| {
    if (graph_mod.isValidCelSyntax(s.source)) continue;
    if (site_mod.isEmptyOrWhitespace(s.source)) continue;
    // ... emit CEL_SYNTAX_INVALID diagnostic ...
}
```

**becomes** (the empty/whitespace guard moves first so VLD-02 AC5 sites are skipped before parsing; the existing `CEL_SYNTAX_INVALID` message block is unchanged):

```zig
for (sites) |s| {
    if (site_mod.isEmptyOrWhitespace(s.source)) continue; // VLD-02 AC5 owns empties
    const pr = expr_mod.parse(allocator, s.source) catch continue; // OOM -> skip site
    switch (pr) {
        .ok => |ast| ast.deinit(),          // syntactically valid
        .fail => |errs| {
            allocator.free(errs);
            // ... existing CEL_SYNTAX_INVALID emit block (message, node_id, expression_path) ...
        },
    }
}
```

This makes `"amount >"`, `"amount <="`, `"x >"`, `"y <"` all produce `CEL_SYNTAX_INVALID` (the parser's `recordError("expected expression")` at end-of-input after a binary operator), so VLD-02 AC4's short-circuit fires. Gate semantics, `Pd06Diagnostic` shape, and the graph-level block (`validateEdgeConditions`/`validateEdgeTransforms`) are unchanged.

**Affected tests:** `mod.test.validateDefinition: malformed CEL guard -> pd06_diagnostics populated, findings empty`, `mod.test.validateDefinition: findings are ordered by (node_id, expression_path)` (a PD-06 gate test in disguise — gate now fires → `pd06_diagnostics != null`, `findings` empty). Existing `pd06.test.runSyntaxCheck` tests remain green (`now( + 60000` still fails parse; empty source still skipped; clean graph still yields no diagnostics).

#### R4b — `mod.zig` runs the gate before env findings

**Module(s) to change:** `src/validation/mod.zig` (`validateDefinition` ordering).

**Precise change — reorder `validateDefinition` so the gate precedes all env-finding accumulation:**

1. `const sites = site_mod.enumerateSites(allocator, input.graph) catch return error.OutOfMemory;` then `defer site_mod.freeSites(allocator, sites);`
2. `var pd06_diags = pd06_mod.runSyntaxCheck(allocator, input.graph, sites) catch return error.OutOfMemory;` then `errdefer pd06_mod.freePd06Diagnostics(allocator, pd06_diags);`
3. `if (pd06_diags.len > 0)` → return `ValidationFailure{ .findings = &.{}, .pd06_diagnostics = pd06_diags, .validated_at = <dup "">, .compiler_version = <dup COMPILER_VERSION> }`. `findings` is **still empty by construction** here (this is the AC4 guarantee; the current code returns `findings.toOwnedSlice(...)` after the env loops, which is exactly the bug).
4. PD-06 clean → `pd06_mod.freePd06Diagnostics(allocator, pd06_diags); pd06_diags = &.{};`
5. **Then** the VLD-01 env-builder loops (variable_schema → service_results → module_outputs → form_fields), which may append `UnknownVariableType` / `UndeclaredResultSchema` / `ConflictingFieldType` findings.
6. Then reachability, the per-site semantic loop, sort, and return — unchanged.

The `sites` slice is used by both the gate (step 2) and the per-site semantic loop (step 6); its `defer` frees it once at function exit. The `errdefer` for `pd06_diags` fires only on a later error return; on the gate-path success return the diagnostics are transferred into the returned `ValidationFailure` (owned by `failure.deinit`).

**Affected tests:** `mod.test.validateDefinition: malformed CEL guard` (with R4a, the gate fires; with R4b, `findings` is empty even though the fixture also carries the `number`-typed variable — the ordering makes AC4 literal rather than dependent on R3), and `mod.test.validateDefinition: findings are ordered by ...` (same short-circuit).

**Verification:** `zig build test-validation` — both gate tests pass with `findings == 0` and `pd06_diagnostics != null`.

### R5 — `mod.zig` per-site findings backing leak

**Module(s) to change:** `src/validation/mod.zig` (per-site semantic loop).

**Precise change — the current loop:**

```zig
var site_findings = typecheck_mod.checkSite(allocator, site_env, site) catch continue;
const owned = site_findings;
site_findings = &.{};
try findings.appendSlice(allocator, owned);
```

**becomes** (the `site_findings = &.{}` dance was a no-op and is removed):

```zig
const owned = try typecheck_mod.checkSite(allocator, site_env, site) catch continue;
try findings.appendSlice(allocator, owned);
allocator.free(owned);   // R5: free the []Finding backing; strings adopted by `findings`
```

**Ownership clarification — this is a transfer, not a deep copy.** `checkSite` returns an owned `[]Finding` (its internal `ArrayList.toOwnedSlice`). `appendSlice(allocator, owned)` shallow-copies the `Finding` structs into the shared `findings` list; each `Finding`'s four strings (`node_id`, `expression_path`, `source`, `message`) were individually allocated by `checkSite`'s emitters and are **adopted by pointer** — the shared `findings` list (and its `errdefer`/`ValidationFailure.deinit` via `freeFindings`) owns them from here on. The only remaining obligation is to free the `owned` **backing buffer** itself. Do **not** call `finding_mod.freeFindings(allocator, owned)` here — that would free the adopted strings a second time (double-free). After `appendSlice`, `allocator.free(owned)` is safe because `owned` is a distinct allocation from `findings`'s internal buffer.

**Affected tests:** all `mod.test.validateDefinition` paths that reach the per-site semantic loop (clean-path, unknown-var, and — once the gate is not short-circuiting — any future semantic path). This does not fail a logic test by itself today (the logic assertions fire first), but it is one of the 11 leaked allocations in the diagnosis and will surface as a leak once R1–R4 are fixed; fix it in the same change to avoid a second rework cycle.

**Verification:** `zig build test-validation` reports no leak for the `mod` tests (DebugAllocator teardown clean).

---

## 6. Verification (how BACKEND-DEV verifies)

Fix order recommendation (each step independently verifiable, final state requires all five):

1. **R1** — `zig build test-validation` (or `zig build test` filtered to `site`) → the four `site`/`pd06` tests pass with **no** `leaked N allocations`.
2. **R2** — `zig build test-validation` → the four `typecheck.checkSite` tests pass with no `Invalid free` panic.
3. **R3** — `zig build test-validation` → `mod.validateDefinition: clean linear definition` reports `expected 0` (the 3 spurious findings collapse); `guard references unknown identifier` produces the `did you mean "amount"?` suggestion.
4. **R4** — `zig build test-validation` → `malformed CEL guard` and `findings are ordered by ...` pass (`pd06_diagnostics != null`, `findings.len == 0`).
5. **R5** — re-run `zig build test-validation` → zero leak reports across `mod`.

Final acceptance gate (matches ISS-0709 `acceptance_criteria`):

- `zig build` — compiles clean (no new errors).
- `zig build test-validation` — **38/38** pass, 0 fail, 0 crash, 0 leaked allocations.
- `zig build test-integration-vld-unit` — **14/14** pass (requires `BPM_TEST_DB_URL`; the 14 blocks in `tests/integration/validation_vld_unit_test.zig`).
- `zig build test-integration-vld-http` — **5/5** pass (requires `BPM_TEST_DB_URL`; the 5 blocks in `tests/integration/validation_vld_http_test.zig`).
- `zig build test` (full corpus) — **0 fail / 0 crash** (per ISS-0709 AC6).
- Regression check: no new `std.testing.allocator` leak/double-free reports in any touched module.

---

## 7. Out of scope

- **No behaviour change beyond the five fixes.** `validateDefinition`'s public surface, `ValidationFailure` shape, the 7-variant `ErrorKind` closed enum, wire serialisation (`wire.zig`), and `finding.zig` (`sortByLocation`, `editDistance`, `SUGGESTION_THRESHOLD`) are untouched.
- **`src/definition/graph.zig` is not modified.** `isValidCelSyntax` remains the pre-existing PD-06 structural check for the graph-level edge paths; the per-site VLD-02 gate moves to `expr.parse` instead (R4a).
- **`src/validation/env.zig`'s `TypedEnv.deinit` is not modified** (R2 fixes the test scaffolding, not the public contract).
- **`src/validation/site.zig`'s enumeration walkers are not modified** (R1 changes `freeSites` only).
- **No migration, no wire-format change, no requirement change.** The `"number"`/`"bool"`/`"timestamp"` table additions (R3) widen the accepted declared-name set only; they add no new error kind.
- **Not addressed here (tracked separately in ISS-0709 context):** the earlier `SPEC_DEVIATION` note (spec integration files absent at diagnosis time) is moot — `tests/integration/validation_vld_unit_test.zig` (14 blocks) and `validation_vld_http_test.zig` (5 blocks) now exist and are wired into `build.zig` (`test-integration-vld-unit`, `test-integration-vld-http`). They are exercised by the verification above, not changed by this fix.

**Open questions:** none blocking. The R3 sibling-name decisions (`duration`/bare `list`/bare `map` not added) and the R4a decision (per-site gate = `expr.parse`, `graph.zig` untouched) are recorded here as resolved; if REQ-ANALYST later wants `duration` in the declared-type set, that is a separate taxonomy change (new `TypeTag`) and must go through CODE-DESIGNER + VLD-03 AC5 review.
