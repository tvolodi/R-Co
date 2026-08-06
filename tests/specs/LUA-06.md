# Test Spec: LUA-06 — Capability Check at Call Site

**Requirement:** LUA-06 — Every host function MUST check the script's declared capabilities before executing. A missing capability MUST raise a Lua error with structured details (function name, capability required, capabilities granted).

**Priority:** MUST
**Test layer:** unit (real, statically linked LuaJIT — no mocks, no stubs)
**Issue:** ISS-0169 / GH #495, tranche 1
**Design:** `src/design/lua-capability-enforcement.md` §3, §4

---

## 1. Revision note — what changed and why

**Revised 2026-08-06 (ISS-0169 tranche 1).** The May 2026 version of this spec described
sixteen cases (TC-LUA-06-01..16) against an enforcement layer that **did not exist**. The
ISS-0169 diagnosis proved it empirically: with a completely empty `CapabilitySet`, all
seven capability-requiring `platform.*` calls **succeeded** (evidence E9). A
`lua_CFunction` receives only `*lua_State`, and with zero upvalues and nothing in the
registry the `CapabilitySet` was not in scope at call time — there was no channel through
which a check could read it.

Three consequences for this spec:

1. **Positive-path cases are re-scoped.** The old TC-LUA-06-02/04/06/08/10/12 asserted on
   *effects* — "returns the variable value", "the write is staged", "the log entry is
   appended", "instance state is returned as a Lua table". Those effects belong to LUA-11,
   LUA-12 and LUA-13 (tranches 2–3) and are **explicitly out of scope** for this tranche
   (design §9). A test asserting them today would fail against correct code. The positive
   path here asserts exactly the claim this tranche makes: **with the grant present the
   call is not refused**.
2. **The old cases were too weak to be evidence.** Each denial case granted one unrelated
   capability and checked one function. That cannot distinguish "this gate checks the right
   capability" from "this gate refuses everything", and it cannot detect a gate that reads
   the context but ignores it. The revised cases use a full cross-product and a fail-closed
   probe.
3. **Capability spellings are canonical.** `src/lua/capabilities.zig` `StandardCapabilities`
   is normative: `service:call:<svc_id>`, `variable:read`, `variable:write`, `audit:log`,
   `event:emit`, `instance:read`. The old `tests/unit/lua_test.zig` spellings
   (`variable:read:*`, `event:emit:*`, `log:write`) exist nowhere in the source and were
   corrected, not accommodated (design §3.5).

---

## 2. Acceptance criteria mapping

| Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test cases |
|---|---|
| A capability denial test exists for every host function listed in Architecture §5.2 | TC-LUA-06-D01..D06 (the six gated functions), plus TC-LUA-05-S05 in `LUA-05.md` for the two ungated ones |
| *(statement)* the error carries function name, capability required, and capabilities granted | TC-LUA-06-D01..D06, D08, D09, D10, D11 — every denial assertion checks all three fields |

---

## 3. The error contract under test (design §4.2)

A denial produces exactly one message shape:

```
capability denied: platform.<fn> requires '<required>'; granted: <summary>
```

An argument error produces a deliberately **distinct** shape, so a test cannot confuse the
two:

```
invalid argument: platform.<fn> argument <n> must be <type>
```

`<summary>` renders `(none)` for an empty grant set and a comma-separated list otherwise.
This is the field that makes a denial diagnosable rather than merely fatal.

**Why the assertions check the message *prefix*, not just substrings.** Before ISS-0169,
`lua_error` was called with nothing pushed at every call site in `src/lua/host_api/`, so it
raised whatever happened to sit on the Lua stack top. The diagnosis observed
`platform.read_variable()` reporting `'1.0954944061662e-311'` (uninitialised stack memory)
and `platform.log('only-one-arg')` reporting `'only-one-arg'` (the caller's own argument).
A substring assertion could be satisfied by accident; asserting the message **starts with**
`capability denied: platform.` cannot be, and is the regression guard for invariant ERR-1
("no `lua_error` without a message pushed immediately before").

A denial surfaces to the caller of `executeScript` as a **failed `ScriptResult`** whose
`error_message` carries the text — not as a Zig error (Zig errors cannot cross the C ABI)
and not as a `nil` return (which would be indistinguishable from a successful read of an
absent variable, exactly the ambiguity E9 hid behind).

---

## 4. Test cases

### TC-LUA-06-D01..D06: every gated function is denied while holding a WRONG capability

**Given:** For each of the six gated functions in turn, a capability set holding exactly one
capability — the one belonging to the **next** function in the matrix, so the grant is real
and non-empty but never the one required.
**When:** The function is called with fully valid arguments (so a failure can only be the gate).
**Then:** Execution fails; the message starts with `capability denied: platform.`; it contains
the function name, the exact required capability string, and the literal `granted:`; it
renders the wrongly-held grant; and it does **not** contain `(none)`.
**Layer:** unit
**Acceptance criterion mapped:** "A capability denial test exists for every host function listed in Architecture §5.2."

| # | Function | Capability required | Wrong capability held |
|---|---|---|---|
| D01 | `call_service` | `service:call:payment_svc` | `variable:read` |
| D02 | `read_variable` | `variable:read` | `variable:write` |
| D03 | `write_variable` | `variable:write` | `audit:log` |
| D04 | `log` | `audit:log` | `event:emit` |
| D05 | `emit_event` | `event:emit` | `instance:read` |
| D06 | `get_instance_state` | `instance:read` | `service:call:payment_svc` |

**Why a non-empty wrong grant rather than an empty set:** an empty set cannot distinguish a
gate that checks the right capability from a gate that refuses everything, and the
`(none)` exclusion proves the gate actually **read** the context it was handed rather than
falling through its fail-closed branch. The empty-set case is covered separately by
`execution_test.zig`'s aggregate test, which is the direct inverse of evidence E9.

### TC-LUA-06-D07: a single grant opens exactly one function and no other

**Given:** The 6×6 cross-product — for each of the six capabilities, granted alone, each of
the six gated functions is called.
**When:** All 36 combinations execute.
**Then:** The 6 diagonal combinations (function holding its own capability) **succeed**; all
30 off-diagonal combinations are **denied**, each naming its own required capability.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — this is what distinguishes a real
per-capability gate from a "context is present, so allow" check.
**Note on "succeed":** the function bodies remain unimplemented in this tranche (LUA-11/12/13,
design §9), so success means **the call was not refused**. That is precisely the claim this
tranche makes, and asserting more would assert something the code does not yet do.

### TC-LUA-06-D08: an ABSENT context denies every gated function (CAP-2)

**Given:** A real sandboxed state built by `createSandboxedState` with a **full** grant set
(all six capabilities), whose `LUA_REGISTRYINDEX` entry under `"bpm.execution_context"` is
then set to `nil` from Zig — simulating an `installContext` that silently did not land.
**When:** Each of the six gated functions is called through `lua_pcall`.
**Then:** `contextFromState` returns null; every call **fails**; each message starts with
`capability denied: platform.`, names the function and its required capability, and renders
the granted set as `(none)`.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — fail-closed rule CAP-2, "a gate that
cannot determine the answer denies".
**Why the grant set is full:** if the call is refused, it can only be because the context was
unreadable — never because a capability was missing. This isolates the fail-closed path.
**Why tamper from Zig, not from Lua:** the registry is deliberately not script-reachable
(design §2.2 — no `debug` library, no way to name a pseudo-index). The realistic failure
mode is not a malicious script but a plumbing bug, so the test breaks the channel through
the same C API a plumbing bug would.

### TC-LUA-06-D09: a WRONG-TYPE registry entry denies too, it does not allow

**Given:** The same setup as D08, but the registry key is set to a **number** rather than
being removed — simulating the registry slot being reused or overwritten.
**When:** `platform.read_variable('k')` is called.
**Then:** `contextFromState` returns null (it requires a light userdata), the call fails, and
the message is the same `(none)` denial shape.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — CAP-2 covers "absent **or not a light
userdata**", and the second half needs its own case.

### TC-LUA-06-D10: a script can pcall its own denial without gaining the capability

**Given:** A capability set holding `variable:read` only.
**When:** The script wraps `platform.write_variable('k','v')` in `pcall` twice, then calls the
permitted `platform.read_variable('k')`, and returns the first caught error.
**Then:** Both `pcall`s report failure (catching a denial does not open the gate); the
subsequent permitted call still works (the state is not poisoned); and the returned error
text names `write_variable`, `variable:write`, and the held `variable:read` grant.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — LUA-06's semantics are "raises a Lua
error", and an error a script cannot observe is indistinguishable from a hard abort. This
is why design §5.2 keeps `pcall` in the sandbox.

### TC-LUA-06-D11: call_service is gated per service id, exactly and without wildcards

**Given:** A capability set holding `service:call:payment_svc` only.
**When / Then:** Four sub-cases:

| Sub-case | Call | Expected |
|---|---|---|
| (a) exact match allowed | `call_service('payment_svc',…)` | succeeds |
| (b) different service denied | `call_service('shipping_svc',…)` | denied, naming `service:call:shipping_svc` **and** the bare `shipping_svc` |
| (c) wildcard grant is literal | grant `service:call:*`, call `payment_svc` | **denied** — `has()` is exact string containment; `service:call:*` matches only a service literally named `*` |
| (d) prefix grant does not match | grant `service:call:payment`, call `payment_svc` | **denied** — prefix matching here would be privilege escalation |
| (e) bad `svc_id` is an ARGUMENT error | `call_service(42,…)` | message starts `invalid argument: platform.` and does **not** contain `capability denied` |

**Layer:** unit
**Acceptance criterion mapped:** "A capability denial test exists for every host function" —
`call_service` is the one function whose required capability is computed from an argument
(design §3.3), so it needs cases the other five do not.
**Note on (c):** ADP-08 supports wildcards for SERVICE_TASK elsewhere in the platform.
Reconciling the two capability models is deliberately **out of scope** for this tranche and
is recorded as design §11 follow-up 1. Asserting the current exact-match behaviour prevents
a future wildcard change from landing silently.
**Note on (e):** the `svc_id` must be read and type-validated **before** the capability check
— it *is* the capability. This is the only permitted exception to CAP-1's "check before
touching arguments", it touches only argument 1, and it must remain distinguishable from a
denial.

### TC-LUA-06-D12: an over-long service id is rejected, never truncated into a match

**Given:** A grant for a short service id (`service:call:aaaaaaaa`) and a call whose `svc_id`
is `MAX_SVC_ID_BYTES + 1` bytes of `a`.
**When:** The script executes.
**Then:** The call fails with an **argument** error naming `call_service` — never succeeds, and
never reports a denial of a truncated capability. Additionally, at unit level,
`serviceCallCapability` returns `null` for the over-long id and a non-null slice for an id
of exactly `MAX_SVC_ID_BYTES`.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — truncating a capability string used
for comparison could make a long id match a shorter grant. That is privilege escalation,
not a diagnostic inconvenience (design §3.3).

---

## 5. Coverage of the Architecture §5.2 surface

The acceptance criterion is "a capability denial test exists for **every** host function
listed in Architecture §5.2". All eight are accounted for:

| `platform.*` | Denial case | Positive case |
|---|---|---|
| `call_service` | D01, D07, D11(b)(c)(d) | D07, D11(a) |
| `read_variable` | D02, D07, D09 | D07, D10 |
| `write_variable` | D03, D07, D10 | D07 |
| `log` | D04, D07 | D07 |
| `emit_event` | D05, D07 | D07 |
| `get_instance_state` | D06, D07 | D07 |
| `now` | **n/a — ungated by design** | `LUA-05.md` TC-LUA-05-S05 |
| `fail` | **n/a — ungated by design** | `LUA-05.md` TC-LUA-05-S05 |

`now` and `fail` are exempt by positive design statement (design §3.2), not by omission.
They are listed here so the coverage claim is auditable from one place, and their
ungated-ness is asserted in `LUA-05.md` so that a future blanket-gate change fails a test
rather than silently over-restricting.

---

## 6. Fixtures and isolation

Each test block constructs its own `CapabilitySet`, `ExecutionContext` and `lua_State`;
nothing is shared, so no test can observe another's state and test order cannot change any
outcome. `std.testing.allocator` fails any test that leaks.

Invariant CTX-1 (context outlives the state) holds structurally: the context is a stack
value in the test frame and `executeScript` closes its state before returning.

**No credentials appear in any test in this spec.** No Keycloak, no database, no network.

---

## 7. Case count and implementation

**Specified cases: 12** — TC-LUA-06-D01, D02, D03, D04, D05, D06, D07, D08, D09, D10, D11, D12.

**Implemented: 12**, in `src/lua/capability_enforcement_test.zig` as 7 Zig `test` blocks.
D01..D06 are one table-driven block iterating the six-row `GATED` matrix (six cases, one
block) — the count is of *cases executed*, not of `test` keywords, and each row asserts
independently with its own function name and capability string. D07, D08, D09, D10, D11 and
D12 are one block each.

Additional aggregate coverage lives in `src/lua/execution_test.zig` (empty-set denial across
all six, granted-path across all six, the unrelated-grant case, and the argument-error
cases). Those are retained and not counted here.

**No `error.SkipZigTest` appears on any case in this spec.**

---

## 8. Verification that these tests are load-bearing (ISS-0172 / GH #500)

A green `zig build test-lua` does not by itself prove a file compiles — `src/lua_test_root.zig`
pins several files with bare type references that force neither field-type resolution nor
function-body analysis, which is how both limiters carried hard compile errors through a
green target. Every case above therefore **calls** real functions against a real
`lua_State`.

Confirmed by deliberate mutation on the WF03-ISS-0169-20260806 branch:

| Mutation | Result |
|---|---|
| `requireCapability` returns instead of raising when the context is absent (fail-**open**) | TC-LUA-06-D08 and D09 go red; **no pre-existing test catches it** |
| `write_variable` gates on `variable:read` instead of `variable:write` | TC-LUA-06-D01..D06, D07, D08, D10 go red (plus 4 pre-existing) |
| SBX-1 inverted in `stdlib.zig` (prune before open) | `LUA-05.md` TC-LUA-05-S03 and S04 go red (plus 3 pre-existing) |

The first row is the reason D08/D09 exist: the fail-closed path had no coverage at all
before this spec.

---

## 9. Traceability

- LUA-06 acceptance: TC-LUA-06-D01 through D12.
- LUA-05 (host functions registered, ungated pair): `tests/specs/LUA-05.md`.
- LUA-07 (manifest validated at load): `tests/specs/LUA-07.md` — the manifest supplies the
  `CapabilitySet` these gates consult.
- LUA-11 / LUA-12 / LUA-13 (host function bodies): out of scope. These cases assert a denied
  call **cannot reach** the body; what the body then does is those requirements'.
- WASM-06: the equivalent capability check for Wasm modules. Same pattern, separate spec.
