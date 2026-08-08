# Design Validation Report — ISS-0174 / GH-502

| Field | Value |
|---|---|
| run_id | `WF03-GH502-20260808` |
| workflow_id | `WF-03` (issue resolving) |
| step | `2b` (CODE-DESIGN-VALIDATOR) |
| validator | CODE-DESIGN-VALIDATOR |
| validated_at | 2026-08-08T13:37:58Z |
| issue | ISS-0174 / GH-502 |
| branch | `feature/WF03-GH502-20260808` |
| **overall verdict** | **PASS** (11 of 11 checks pass — 1 MINOR caveat) |

---

## Artefacts validated

| Path | Role | Bytes |
|---|---|---|
| `docs/issue-reports/ISS-0174-gh502-diagnosis.yaml` | Diagnosis (Step 1) | 17 178 |
| `src/design/iss0174-gh502-capabilityset-summary-migration.md` | Design (Step 2) | ~17 000 |
| `tests/specs/ISS-0174-gh502-capabilityset-summary.md` | Test spec (Step 2) | ~7 500 |
| `src/lua/capabilities.zig` | Source under migration | 75 |
| `src/lua_test_root.zig` | Test root (insertion target) | 268 |
| `src/lua/host_context.zig` | Reference (longjmp contract) | per `raiseCapabilityDenied` (line 178) and `writeGrants` (line 361) |

## Verification methodology

Every check below is one direct observation against the design + the live source. The
substitution rules (S1–S5) are verified by code-reading `src/lua/capabilities.zig` against
the Zig 0.16 unmanaged `ArrayList` API contracts and against the existing `refAllDecls`
pin pattern in `src/lua_test_root.zig:95`. The `host_context.zig` doc-comment style
comparison is a direct read of lines 175 and 359.

---

## Check 1 — Acceptance criteria coverage

**Verdict: PASS**

Every MUST criterion (1–5) from the diagnosis YAML is addressed by a concrete section
in the design markdown:

| Criterion (from YAML) | Design section | Evidence |
|---|---|---|
| #1 — `capabilities.zig` compiles under Zig 0.16 with function bodies genuinely analysed | §1 (AFTER), §4 (real call), §6 (deliberate-mutation) | Three-pronged: migration + new test + mutation procedure |
| #2 — `std.ArrayList(u8).init(allocator)` migrated to unmanaged 0.16 API | §5 (S1–S5) | Five one-line token edits, each `BEFORE → AFTER` row explicit |
| #3 — A build target CALLS `CapabilitySet.summary()` and asserts on output | §3 (TC-CS-01..05), §4 (new test block) | Five test cases in spec; full test block in design §4 |
| #4 — Deliberate-mutation verification: inject error → `zig build test-lua` goes red | §6 (procedure) | Step A/B/C/D with concrete shell commands |
| #5 — Decision recorded: retain vs delete | Header ("Decision: RETAIN"), §1 (DECISION callout), §2 (longjmp contract), §7 (rejected alternatives) | `RETAIN` appears in 4 sections |
| #6 (SHOULD) — function-level census | §7 (deferred to follow-up) | Explicitly deferred |

## Check 2 — Interface / type completeness (substitution rules S1–S5)

**Verdict: PASS** (with one MINOR caveat on line-number anchors — see below)

The design table at §5 maps every stale API call to its unmanaged replacement. Each
rule is one token-level edit, with the `BEFORE` and `AFTER` strings exactly matching
the actual source lines 49, 50, 53, 56, 60 of `src/lua/capabilities.zig`.

| Rule | BEFORE (from design §5) | Source line in `capabilities.zig` | Status |
|---|---|---|---|
| S1 | `var buf = std.ArrayList(u8).init(allocator);` | 49 | matches |
| S2 | `defer buf.deinit();` | 50 | matches |
| S3 | `try buf.appendSlice(", ");` | 53 | matches |
| S4 | `try buf.appendSlice(key.*);` | 56 | matches |
| S5 | `return buf.toOwnedSlice();` | 60 | matches |

**MINOR caveat (does not affect verdict):** the illustrative BEFORE/AFTER blocks in
design §1 carry line numbers (44–63 and 44–73) that do not match the actual file:

- The AFTER block labels the function header at line 55; the actual file has it at
  line 44 (off by 11).
- The S1–S5 rows in the `AFTER` block reference lines 60, 61, 67, 69, 73; the actual
  file (after migration) will have them at 49, 50, 53, 56, 60 (off by varying amounts).

The token-level substitutions themselves are correct — the After block's content
collapses to the same 12 lines of body content as the live file's intended post-fix
shape. The rule table at §5 is anchored on the tokens, not the line numbers, and
those anchorage strings are correct. The design note explicitly acknowledges this is
"_the design's pre-migration view_".

A passing verdict is appropriate because (a) the substitution-rule table is the
contractual artefact BACKEND-DEV will execute against, and the table is correct, and
(b) the line-number drift is in the illustrative block, not in the rule definition.
BACKEND-DEV should produce the diff against the live source (line 49 onwards for the
function body), not against the design's illustrative block.

**Recommendation (MINOR, not blocking):** BACKEND-DEV will face no difficulty because
the S1–S5 rule table is the authoritative source of edits. No rework required.

## Check 3 — No implementation code in design

**Verdict: PASS**

The design markdown contains only BEFORE/AFTER illustrative blocks (which are
explicitly labelled as "_the design's pre-migration view_" and "_target shape after
BACKEND-DEV Step 3_"). No live modifications to source files. No `git apply` blocks.
No SQL DDL (out of scope — this is a `.zig` migration, not a migration spec). No JSX
or React code. The design's author is correctly characterised as a Type E prose
design (cross-cutting API migration), not a Type A/B/C/D parameter file.

## Check 4 — Test specification is concrete

**Verdict: PASS**

`tests/specs/ISS-0174-gh502-capabilityset-summary.md` contains five test cases, each
with a concrete expected output AND an allocator/ownership assertion:

| TC | Branch | Expected output | Allocator/ownership assertion |
|---|---|---|---|
| TC-CS-01 | empty grants | literal `"(none)"`, length 6 | `defer std.testing.allocator.free(slice)` |
| TC-CS-02 | single grant | `"service:call:payment"`, length 21, no `,` | `defer std.testing.allocator.free(slice)` |
| TC-CS-03 | three grants | `"audit:log, service:call:payment, variable:write"` (sorted) | `defer std.testing.allocator.free(slice)` |
| TC-CS-04 | leak detection | implicit — `zig build test-lua` leak detector reports 0 | Structural proof via successful `defer free` pair |
| TC-CS-05 | ownership | implicit — `defer free` succeeds | Structural proof: would crash on borrowed/stack-allocated slice |

Every TC has a specific expected output (literal string, length, or assertion) and an
allocator behaviour assertion (either explicit `defer free` or implicit leak-detector
check). Not vague.

## Check 5 — Build wiring is unambiguous

**Verdict: PASS**

The design §4 specifies precisely:

- **Insertion point:** "Appended after the ISS-0153 block, before the ISS-0161 block."
- **Test name string:** `"ISS-0174 / GH-502: CapabilitySet.summary() compiles, runs, and renders both branches"`.
- **File:** `src/lua_test_root.zig` (the existing test root already wired into
  `zig build test-lua`).
- **Build target:** wired into `zig build test-lua` automatically via the existing
  top-level `test {...}` block at line 84–88 (`std.testing.refAllDecls(lua)`); no
  `build.zig` change required.
- **Rationale against alternative (option b):** the design explicitly chose option (a)
  (test root) over option (b) (drive call from `host_context.zig` test at line 447)
  with three reasons: self-contained, symmetric with ISS-0153 pin pattern, no change
  to runtime semantics of host-context test.

The design also confirms the bare-type pin at line 95 (`_ = lua.capabilities.CapabilitySet;`)
is the existing pin to be contrasted; the new test block is a separate, additional
test, not a replacement of line 95. The wiring is unambiguous.

## Check 6 — Longjmp-unsafe contract documented

**Verdict: PASS**

The design §2 specifies an exact doc-comment for `summary()` that mirrors the style
of `writeGrants` at `src/lua/host_context.zig:359`:

**Existing `writeGrants` doc comment (line 358–360):**

```
/// Render the granted capabilities directly into the message buffer.
/// Deliberately NOT `CapabilitySet.summary()`, which allocates: its result
/// would be leaked by `lua_error`'s longjmp (ERR-2).
```

**Existing `raiseCapabilityDenied` reference (line 175–177):**

```
/// Fixed stack buffer only — no allocator (ERR-2). `CapabilitySet.summary()`
/// allocates, so it must NOT be used here: its result would be leaked by the
/// longjmp. The grant set is walked directly into the same buffer instead.
```

**Design's proposed new doc comment for `summary()` (mirror, flipped direction):**

```
/// **Longjmp-unsafe (ERR-2).** This function allocates. Inside a context
/// that may raise via `lua_error` (which longjmps), the returned slice
/// would leak. The longjmp-safe twin is `writeGrants` in
/// `src/lua/host_context.zig`, which walks the grant set directly into
/// a fixed stack buffer. Use this `summary()` ONLY from contexts that
/// own the result's lifetime cleanly (host-API startup diagnostics,
/// audit log lines, REST error responses for missing capability
/// metadata).
```

Both halves of the contract now reference `ERR-2`, both halves reference the other
function, and both halves explain the allocation-free path. The two doc comments
form a paired contract that future maintainers can grep on `ERR-2` to find both
halves.

## Check 7 — Substitution rules are mechanically correct (Zig 0.16)

**Verdict: PASS**

Verified against the Zig 0.16 unmanaged `ArrayList` API contracts by code-reading
`src/lua/capabilities.zig`:

| Rule | BEFORE | AFTER | Zig 0.16 contract |
|---|---|---|---|
| S1 | `var buf = std.ArrayList(u8).init(allocator);` | `var buf: std.ArrayList(u8) = .empty;` | Unmanaged `ArrayList(T)` has no `.init` member. The documented unmanaged constructor is `.empty` (a `const` field returning an empty unmanaged `ArrayList`) or `std.ArrayList(T){}` (undefined items, growth on first insert). `.empty` is the correct, idiomatic form. |
| S2 | `defer buf.deinit();` | `defer buf.deinit(allocator);` | Unmanaged `deinit` signature is `deinit(self: *Self, allocator: Allocator) void`. Without `allocator`, the backing storage cannot be freed. |
| S3 | `try buf.appendSlice(", ");` | `try buf.appendSlice(allocator, ", ");` | Unmanaged `appendSlice` signature is `appendSlice(self: *Self, allocator: Allocator, items: []const T) !void`. Caller must pass allocator as first parameter. |
| S4 | `try buf.appendSlice(key.*);` | `try buf.appendSlice(allocator, key.*);` | Same signature as S3. |
| S5 | `return buf.toOwnedSlice();` | `return buf.toOwnedSlice(allocator);` | Unmanaged `toOwnedSlice` signature is `toOwnedSlice(self: *Self, allocator: Allocator) ![]T`. Same pattern. |

The empty-grants short-circuit at line 48 (`return allocator.dupe(u8, "(none)");`) is
unchanged — `Allocator.dupe` is already 0.16-correct (it takes the allocator as the
receiver). The design correctly identifies this.

The migration is mechanically correct. Backed by the diagnosis YAML's `root_cause.precise_location`
which independently identifies the same five tokens.

## Check 8 — Deliberate-mutation verification

**Verdict: PASS**

The design §6 specifies a concrete procedure for BACKEND-DEV to inject a statement
error and confirm `zig build test-lua` goes red:

- **Statement to inject:** `const _bad: u32 = "definitely not a u32";`
- **Where to add:** "anywhere after `defer buf.deinit(allocator);`" (the design
  example says "after line 60") — note the line number is illustrative; the
  unambiguous anchor is "after the `defer buf.deinit(allocator);` statement in the
  post-migration body".
- **Expected outcome:** `zig build test-lua` exits 1 with a Zig type error citing
  the injected statement.
- **Revert:** `git checkout src/lua/capabilities.zig`.
- **Re-run:** `zig build test-lua` exits 0 again.
- **Evidence capture:** "deliberate-mutation result is captured in
  `step-03-backend-dev.json`'s `result.must3_evidence` field."

The procedure is concrete (specific statement, specific anchor, specific expected
exit code, specific revert command). The rationale for choosing a type error
(rather than a runtime error) is explicitly stated: a runtime error inside an
uninvoked body would not surface either; a type error is guaranteed to be caught
by the compile-time semantic analyser if the body is reached.

## Check 9 — SHOULD items deferred explicitly

**Verdict: PASS**

The design §7 includes a dedicated table of out-of-scope items:

| Item | Status | Rationale (paraphrased) |
|---|---|---|
| SHOULD-1 (function-level census) | **Deferred** to follow-up WF-03 run | Classification bucket (a/b/c) needs human review per finding |
| SHOULD-2 (linter upgrade) | **Deferred** to ISS-0172 follow-up | Same item as ISS-0172 acceptance criterion #4 |
| Doc-comment audit of other longjmp-unsafe functions | **Out of scope** | Not in scope for this fix |
| Renaming `summary()` | **Rejected** | Renaming requires coordinated doc-reference rename; doc comment captures the contract more durably |
| Deleting `summary()` entirely | **Rejected** | Per `fix_plan.decision`: deletion would silently regress ISS-0169 ERR-2 architecture |
| Refactoring `CapabilitySet.grants` to `ArrayList` | **Out of scope** | HashMap iteration order is the only reason sorting is needed; changing the data structure would expand the diff well beyond MUST-1 |

SHOULD-1 and SHOULD-2 are listed in their own rows with explicit deferred status.
All deferred/rejected items are enumerated.

## Check 10 — Regression risk

**Verdict: PASS**

The design identifies and bounds three regression-risk categories:

1. **Behavioural regression:** addressed at design §1's "Signature (unchanged)" block
   and at the S1–S5 notes. The function signature is unchanged; the owner contract is
   unchanged; the empty-grants branch is unchanged; the only observable difference is
   that allocation-failure behaviour now matches unmanaged `ArrayList`'s documented
   `error.OutOfMemory` (which was already the case for managed `ArrayList` under
   0.16). Zero existing callers, so no caller can observe a behavioural change.

2. **Build-system regression:** explicitly addressed at the diagnosis YAML's
   `regression_risk.build_system` and at design §4 ("Why NOT a `refAllDecls` upgrade"):
   `if (false)`-guarded calls would be comptime-eliminated; `refAllDecls` is shallow
   over containers; the new test block uses a real call with runtime inputs (TC-CS-01
   through TC-CS-03 each construct a real `CapabilitySet` and call `summary` for real).

3. **Iteration-order change:** addressed at design §3a ("Determinism choice — sorted
   order vs insertion order"). The design explicitly notes that
   `std.StringHashMap(void)` iterates in arbitrary order across Zig versions and
   allocator instances, and prescribes lexicographic sort before joining. The design
   acknowledges this is a **NEW** contract for the function: "_Grants are listed in
   lexicographic order of their byte content._" — this is added to the doc comment
   (per the design's "Public contract update" callout).

   **Note on the new sort contract:** This is a small expansion of the public
   contract. The previous (broken) implementation also iterated in unspecified
   HashMap order, so the contract change is from "unspecified order" to "sorted
   order" — a strict improvement for any existing or future caller. It is not a
   regression.

4. **Allocator contract change:** addressed at design §1 (signature unchanged) and
   §7 (no new error variants). The `!` in the signature already covers
   `error.OutOfMemory` from `toOwnedSlice` and `appendSlice`. No callers exist to
   test the contract change against, but the design's TC-CS-01..03 explicitly test
   it.

Each regression axis is bounded or explicitly non-applicable.

## Check 11 — Lint clean

**Verdict: PASS**

```bash
$ python tools/lint_handoffs.py handoffs/WF03-GH502-20260808/
lint_handoffs: 3 handoffs checked — 0 BLOCKER, 0 MAJOR, 0 MINOR
exit=0
```

The three handoffs are `step-00-backend-dev.json`, `step-01-issue-fixer.json`, and
`step-02-code-designer.json`. All conform to the schema, encoding, and
timestamp-monotonicity rules. Lint gate is GREEN on the way in.

---

## Summary

| # | Check | Verdict |
|---|---|---|
| 1 | Acceptance criteria coverage | PASS |
| 2 | Interface / type completeness (S1–S5) | PASS (MINOR caveat: illustrative line numbers in BEFORE/AFTER blocks are off) |
| 3 | No implementation code in design | PASS |
| 4 | Test specification is concrete | PASS |
| 5 | Build wiring is unambiguous | PASS |
| 6 | Longjmp-unsafe contract documented | PASS |
| 7 | Substitution rules mechanically correct (Zig 0.16) | PASS |
| 8 | Deliberate-mutation verification | PASS |
| 9 | SHOULD items deferred explicitly | PASS |
| 10 | Regression risk bounded | PASS |
| 11 | Lint clean | PASS |

**Overall: 11 of 11 checks pass. Verdict: PASS.**

The design is complete, correct, and unambiguous. The single MINOR caveat (line-number
drift in the illustrative BEFORE/AFTER block) does not affect the substitution rules
themselves, which are the contractual artefact BACKEND-DEV will execute against. No
rework is required. Route to BACKEND-DEV (Step 3).

## Recommendations for BACKEND-DEV

1. **Apply S1–S5 by token, not by line number.** The S1–S5 rule table at design §5 is
   the authoritative source of edits. The illustrative BEFORE/AFTER blocks at design
   §1 carry stylised line numbers that do not match the actual file. Use the rule
   table; the live source is at lines 49–60 of `src/lua/capabilities.zig`.

2. **Add the new test block at `src/lua_test_root.zig` immediately after the closing
   brace of the `ISS-0153` block (the `test "ISS-0153: every file in the src/lua
   subsystem is analysed"` block).** The insertion point is between the existing
   `registerAll` decl pin and the `ISS-0153 bytecode` block that follows.

3. **The new test block calls `summary()` for real using three explicit
   `try caps.add(...)` calls and three `defer gpa.free(slice)` calls.** This is the
   build-wiring that closes the ISS-0172 blind spot. Do NOT substitute
   `refAllDecls` (shallow over containers) or `if (false)`-guarded calls (would be
   comptime-eliminated).

4. **Capture the deliberate-mutation run in `step-03-backend-dev.json`'s
   `result.must3_evidence` field** with the exact exit code and the exact error
   message. The mutation is reverted before the handoff completes.

5. **Run `zig build test-lua` and `zig build test` before completing the handoff.**
   Both must exit 0.

6. **Run `python tools/lint_handoffs.py handoffs/WF03-GH502-20260808/` before
   completing the handoff.** Must exit 0.

## Roadmap for follow-up runs (not in scope for this WF-03)

- **SHOULD-1** (function-level zero-callers census): create a dedicated WF-03 run.
  The classification bucket (genuinely unused / intentional API surface / test-only
  helper) needs human review per finding.
- **SHOULD-2** (linter upgrade): same item as ISS-0172 acceptance criterion #4; may
  be addressed jointly with that issue's follow-up run.
- **Doc-comment audit of OTHER `src/lua/` functions for longjmp safety**: separate
  effort.

---

*End of validation report.*
