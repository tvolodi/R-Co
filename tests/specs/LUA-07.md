# Test Spec: LUA-07 — Capability Manifest Validation

**Requirement:** LUA-07 — On script load, the platform MUST validate the script's manifest against the script artifact. Manifest hash MUST be recorded with each execution.

**Priority:** MUST
**Test layer:** unit (real, statically linked LuaJIT — no mocks, no stubs)
**Issue:** ISS-0169 / GH #495, tranche 1
**Design:** `src/design/lua-capability-enforcement.md` §6

---

## 1. Revision note — what changed and why

**Revised 2026-08-06 (ISS-0169 tranche 1).** The May 2026 version of this spec described
sixteen cases against a `validateManifest` that existed, compiled, and was **called by
nothing** (evidence E12 — its only reference was a type pin in `src/lua_test_root.zig`).
There was no load-time entry point at all: `executeScript` took raw source text and ran it,
and neither `ExecutionContext` nor `ScriptResult` carried a manifest hash. **Both LUA-07
acceptance criteria were unimplementable as the code stood.**

The old spec also encoded three defects as if they were the specification:

1. **Its hash did not cover the script.** The old `computeManifestHash` factory (and the
   implementation) hashed only limits and capability strings. A hash that ignores the
   artifact cannot detect a manifest paired with a *different* script — which is precisely
   what acceptance criterion 1 asks for. The canonical form now ends with the SHA-256
   digest of the script source.
2. **Its hash was order-dependent and separator-free.** Capabilities were hashed in
   declaration order with no delimiter, so `["ab","c"]` and `["a","bc"]` collided and
   reordering changed the hash — contradicting its own TC-LUA-07-13, which requires
   logically identical manifests to hash identically. The canonical form now sorts the
   strings and separates each with `0x00`.
3. **Its "Script with capabilities in manifest" factory read a `__manifest__` table from
   inside the script.** That is rejected outright (design §6.2): a manifest embedded in the
   artifact and read from the artifact is self-asserted — a script would be grading its own
   homework. The manifest is **caller-supplied**, in the serialised JSON form the script
   repository stores. An embedded `__manifest__` table, if any script carries one, is
   advisory only and is never the source of a grant.

Cases TC-LUA-07-01..16 from the old spec are **retained** where they map onto real
behaviour (they are covered by the in-file unit tests in `src/lua/manifest.zig`) and are
cross-referenced in §5. The cases below are the additions that make the two acceptance
criteria genuinely checkable through the load-time entry point.

---

## 2. Acceptance criteria mapping

| Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test cases |
|---|---|
| A modified manifest without re-registration is rejected at load time | TC-LUA-07-M02 (three tamper vectors + a control), TC-LUA-07-M03 (rejection precedes execution), TC-LUA-07-M05 (the hash properties that make detection possible) |
| The manifest hash appears in the execution audit record | TC-LUA-07-M01, TC-LUA-07-M04 — **partially**; see §6 |

---

## 3. What "load time" means here (design §6.4)

`executeScriptWithManifest` is the load-time entry point. Its ordering is the specification,
and every early exit is a **rejection**:

1. **Reject bytecode** — must stay first, so a bytecode artifact can never be validated into
   acceptance.
2. **Verify the manifest hash** against the script source and the hash the repository
   recorded at registration → mismatch rejects **before any Lua state is created**.
3. **Validate the manifest** against the granted capability set and the `Limits` bounds →
   any `ManifestError` rejects, still before state creation.
4. Only then create the sandboxed state and run.
5. Return a `ScriptResult` carrying the verified `manifest_hash`.

`executeScript` is retained unchanged for callers that do not have a manifest (LUA-04's
tests depend on it). It performs **no** manifest verification and honestly reports
`manifest_hash = null` rather than a hash it never checked. It keeps the sandbox, the
context installation and every capability gate — it must never become a way to bypass one.

**Limits are validated, NOT enforced, in this tranche (design §6.5).** `max_instructions`,
`max_memory_bytes` and `timeout_seconds` are checked against `Limits` bounds and carried;
no limiter is installed. Tranche 2 (LUA-08/09/10) installs them. **No test in this spec
asserts that a limit is enforced** — validating a bound and enforcing it are different
claims, and conflating them is how this subsystem reached RELEASED while executing nothing.

---

## 4. Test cases

### TC-LUA-07-M01: the registered pairing executes and records the verified hash

**Given:** A granted set `{variable:read}`, a script `platform.read_variable('amount') return 'ran'`, and a manifest declaring `["variable:read"]` with limits 100 000 / 8 388 608 / 30, registered via `validateManifest` against that exact script.
**When:** `executeScriptWithManifest(ctx, script, &m, m.manifest_hash)` runs.
**Then:** Execution succeeds and returns `"ran"` (so the script really ran, gates and all), and `result.manifest_hash` equals the registered hash byte for byte.
**Layer:** unit
**Acceptance criterion mapped:** "The manifest hash appears in the execution audit record" — the `src/lua/` half; see §6.

### TC-LUA-07-M02: a manifest modified after registration is rejected at load time

**Given:** A granted set `{variable:read, audit:log}` and a manifest registered against `return 'unchanged'` declaring `["variable:read"]`, yielding hash `H`.
**When / Then:** Four sub-cases:

| Sub-case | Tamper | Expected |
|---|---|---|
| (a) capability added | manifest re-declares `["variable:read","audit:log"]`, same script, verified against `H` | `ManifestHashMismatch` |
| (b) limit raised | `max_instructions` 100 000 → 200 000, verified against `H` | `ManifestHashMismatch` |
| (c) script substituted | original manifest, script `return 'substituted'`, verified against `H` | `ManifestHashMismatch` |
| (d) **control** — untampered | original manifest, original script, `H` | **succeeds** |

**Layer:** unit
**Acceptance criterion mapped:** "A modified manifest without re-registration is rejected at load time."
**Why (a) is the important one:** `audit:log` is legitimately held in the granted set, so
`validateManifest` would happily accept the widened manifest. **Only the hash binding
catches it.** That is the entire point of LUA-07 — without it, a script's declared
capability list could be widened after registration to anything within the deployment's
grant, undetected.
**Why (d) is not optional:** without a passing control, (a)–(c) would also pass against an
implementation that rejects everything.

### TC-LUA-07-M03: rejection happens BEFORE any script instruction runs

**Given:** A manifest registered against `return 'clean'`, and a substituted script
`platform.write_variable('leaked','yes') return 'RAN'` which — with no `variable:write`
granted — would raise a capability denial **if it executed**.
**When:** `executeScriptWithManifest` is called with the substituted script.
**Then:** It returns the Zig error `ManifestHashMismatch`, **not** a failed `ScriptResult`.
**Layer:** unit
**Acceptance criterion mapped:** "…rejected at load time" — the *load-time* half.
**Why the error type is the assertion:** a capability denial raised during execution surfaces
as a **failed `ScriptResult`**, never as a Zig error. Receiving `ManifestHashMismatch`
therefore proves execution never began, rather than assuming it from code reading. This
checks the design §6.4 ordering claim instead of trusting it.
**And:** the same case confirms bytecode is rejected **first** (step 1, before any manifest
work) — a bytecode artifact under a valid manifest reports the bytecode message as a failed
`ScriptResult`, not a hash mismatch, so a bytecode artifact can never be validated into
acceptance.

### TC-LUA-07-M04: parseManifest feeds the load-time path end to end

**Given:** A granted set `{variable:read, audit:log}` and the repository's serialised JSON form:
`{"capabilities":["audit:log","variable:read"],"max_instructions":100000,"max_memory_bytes":8388608,"timeout_seconds":30}`.
**When:** The manifest is parsed, its hash computed against the script `platform.log('info','audited') return 'done'`, and `executeScriptWithManifest` is called with that hash.
**Then:** Parsing succeeds; the parsed `manifest_hash` is all-zero (a hash is only meaningful
against a specific artifact, which parsing does not have); execution succeeds returning
`"done"`; and `result.manifest_hash` equals the computed hash.
**And:** A manifest declaring `["audit:log","variable:read","variable:write"]` — a **superset**
of the deployment's grant — is rejected with `UnauthorizedCapability` even when its own
hash is computed consistently.
**Layer:** unit
**Acceptance criterion mapped:** Both criteria — this is the path the script repository
actually uses (design §6.2 trust direction: caller-supplied JSON, never scraped from the
script text).

### TC-LUA-07-M05: canonical hashing — order-independent, separator-safe, script-bound

**Given / When / Then:** Five properties of `computeManifestHash`, each asserted directly:

| # | Property | Assertion |
|---|---|---|
| (1) | **Declaration order does not change the hash** | `["audit:log","event:emit","variable:read"]` and its reverse hash **identically**; and neither caller slice is mutated as a side effect |
| (2) | **The `0x00` separator removes concatenation ambiguity** | `["ab","c"]` and `["a","bc"]` hash **differently** — without the separator both render `abc` and two different capability sets would share one registration hash |
| (3) | **The hash binds to the artifact** | same manifest over `return 1` vs `return 2` hashes differently; and a **one-byte** difference (`return 1` vs `return 1 `) suffices |
| (4) | **Every limit participates** | changing `max_instructions`, `max_memory_bytes` or `timeout_seconds` by one each changes the hash |
| (5) | **Deterministic** | identical input yields identical output |

**Layer:** unit
**Acceptance criterion mapped:** "A modified manifest without re-registration is rejected" —
these are the properties without which detection is impossible. (1) is the old
TC-LUA-07-13; (2) and (3) are the two defects the old spec's own factory encoded.
**On constant-time comparison:** `verifyManifestHash` compares digests by accumulating
differences rather than short-circuiting. This is a tamper-detection value, so a
timing-variable comparison is a defect even where exploitation is impractical. The property
is design-enforced and reviewed rather than timing-tested — a timing assertion in a unit
test would be flaky and would prove nothing on a JIT-warmed, GC-scheduled host.

---

## 5. Retained cases from the May 2026 spec

These map onto real behaviour and are implemented as in-file unit tests in
`src/lua/manifest.zig`. They are listed so the mapping is auditable and so nothing is
silently dropped.

| Old case | Behaviour | Where implemented |
|---|---|---|
| TC-LUA-07-01 | valid manifest passes validation | `manifest.zig` — "parseManifest accepts a well-formed manifest…", and TC-LUA-07-M01 |
| TC-LUA-07-02, -14 | manifest declaring an ungranted / superset capability → `UnauthorizedCapability` | `manifest.zig` — "a manifest declaring an ungranted capability is rejected"; TC-LUA-07-M04 |
| TC-LUA-07-03, -04 | instruction limit below / above bounds | `manifest.zig` — "limit bounds are validated (but not enforced in this tranche)" |
| TC-LUA-07-05, -10 | limits at inclusive boundaries pass | same block (100 000 / 8 388 608 / 30 used throughout as in-bounds values) |
| TC-LUA-07-06, -07 | memory limit below / above bounds | same block |
| TC-LUA-07-08, -09 | timeout below / above bounds | same block |
| TC-LUA-07-11 | hash computed and recorded with the execution | **superseded** by TC-LUA-07-M01 — the old case asserted a hash "of the manifest"; it is now of the manifest **and** the artifact |
| TC-LUA-07-12 | hash mismatch detected | `manifest.zig` — "verifyManifestHash rejects a tampered manifest"; strengthened by TC-LUA-07-M02 |
| TC-LUA-07-13 | identical content → identical hash | `manifest.zig` — "capability declaration order does not change the hash"; TC-LUA-07-M05(1) |
| TC-LUA-07-15 | empty capabilities manifest is valid | `manifest.zig` — the `none` slice used across the limit-bounds block |
| TC-LUA-07-16 | malformed manifest → `MalformedManifest` | `manifest.zig` — seven malformed inputs: non-JSON, non-object, missing `capabilities`, `capabilities` not an array, non-string element, negative integer, non-integer type |

Additionally, `manifest.zig` covers **`ScriptManifest.deinit` ownership** — it previously
freed only the outer slice, leaking every duped capability string (design §6.1 defect 3).
`std.testing.allocator` fails on leak, so that test *is* the check.

---

## 6. Honest scope note on acceptance criterion 2

Criterion 2 reads "the manifest hash appears in the execution **audit record**".

This tranche commits `src/lua/` to **producing** the value: `ExecutionContext` and
`ScriptResult` both carry `manifest_hash: ?[32]u8`, and `executeScriptWithManifest` sets
both from the verified hash. TC-LUA-07-M01 and M04 assert exactly that.

**Writing that value into the persisted audit row is the engine's job, not the executor's.**
`src/lua/executor.zig` performs no I/O, consistent with the `transition.zig` purity
precedent. The engine-side write belongs to the engine-integration run and is recorded as
design §11 follow-up 2.

**Consequence, stated plainly: LUA-07 acceptance criterion 2 is only end-to-end satisfied
when that engine-side write lands.** It is not satisfied by this tranche alone, and this
spec does not claim otherwise. Marking LUA-07 fully RELEASED on the strength of these tests
would repeat the ISS-0153 pattern this issue exists to correct.

---

## 7. Fixtures and isolation

Each test block builds its own `CapabilitySet`, `ExecutionContext`, `ScriptManifest` and
`lua_State`; nothing is shared. `std.testing.allocator` fails any test that leaks, which is
what makes the `deinit` ownership test meaningful. Every manifest fixture is deinitialised
by its own `defer` in the same block that created it.

**No credentials appear in any test in this spec.** No Keycloak, no database, no network.

---

## 8. Case count and implementation

**Specified cases: 5** — TC-LUA-07-M01, M02, M03, M04, M05.
**Implemented: 5**, one Zig `test` block each, in `src/lua/capability_enforcement_test.zig`.

Plus the retained coverage of §5: **8 `test` blocks** in `src/lua/manifest.zig` covering old
cases TC-LUA-07-01..16, and **2 blocks** in `src/lua/execution_test.zig`
(`executeScriptWithManifest` rejects a manifest bound to a different script; the plain
`executeScript` path records no hash).

**No `error.SkipZigTest` appears on any case in this spec.**

---

## 9. Traceability

- LUA-07 acceptance criterion 1: TC-LUA-07-M02, M03, M05.
- LUA-07 acceptance criterion 2: TC-LUA-07-M01, M04 — **partial**, see §6.
- LUA-06 (capability checks): `tests/specs/LUA-06.md` — the manifest determines which
  capabilities those gates find in the set.
- LUA-05 (host functions registered): `tests/specs/LUA-05.md`.
- LUA-04 (bytecode rejection): TC-LUA-07-M03 asserts bytecode rejection stays **first** in
  the load-time order.
- LUA-08 / LUA-09 / LUA-10 (resource limits): the manifest **carries** these limits and this
  tranche validates their bounds. **No limiter is installed and no test here asserts
  enforcement** (design §6.5). Tranche 2 owns that.
- REPO-05 through REPO-07 (artifact repository): supplies the serialised manifest and the
  registered hash. TC-LUA-07-M04 exercises that form.
