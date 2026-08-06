# Test Spec: LUA-05 — Host API Registration and Capability Enforcement

**Requirement:** LUA-05 — The platform MUST register exactly the `platform.*` functions defined in Architecture §5.2 and no others. Each function MUST check the caller's capability grant before executing.

**Priority:** MUST
**Test layer:** unit (real, statically linked LuaJIT — no mocks, no stubs)
**Issue:** ISS-0169 / GH #495, tranche 1
**Design:** `src/design/lua-capability-enforcement.md`

---

## 1. Why this spec exists separately from LUA-01-05.md

`tests/specs/LUA-01-05.md` is the historical combined spec for LUA-01..05 and remains the
owner of LUA-01 (binary linkage), LUA-02 (state isolation), LUA-03 (stdlib restriction)
and LUA-04 (bytecode rejection). It was written in May 2026, before any Lua could run, and
its LUA-05 section (TC-LUA-05-01..12) describes an API surface that was registered but
gated by nothing.

The ISS-0169 diagnosis measured the consequence: with a **completely empty**
`CapabilitySet`, all seven capability-requiring `platform.*` calls **succeeded**
(evidence E9). LUA-05's second clause — "each function MUST check the caller's capability
grant before executing" — was not an untested control; it was an **absent** one, because a
`lua_CFunction` receives only `*lua_State` and the `CapabilitySet` was not in scope at call
time.

This file specifies LUA-05 against the enforcement that now exists. It supersedes the
LUA-05 section of `LUA-01-05.md`; that file's LUA-01..04 sections are unchanged and
authoritative.

---

## 2. Acceptance criteria mapping

| Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test cases |
|---|---|
| Calling `platform.call_service("X")` without the `service:call:X` capability grant returns a structured error | TC-LUA-05-S07, and LUA-06's TC-LUA-06-D11 |
| No undeclared function is accessible from a Lua script | TC-LUA-05-S01, TC-LUA-05-S02, TC-LUA-05-S03, TC-LUA-05-S04 |
| *(statement)* each function checks the caller's capability grant before executing | TC-LUA-05-S05, TC-LUA-05-S06, and the whole of `LUA-06.md` |

---

## 3. The normative surface (design §3.2)

Exactly eight functions, no more and no fewer. Adding a ninth without updating this table
and the design's §3.2 matrix is a defect.

| `platform.*` | Capability required | Gated? |
|---|---|---|
| `call_service(svc_id, …)` | `service:call:<svc_id>` (computed per call) | yes |
| `read_variable(key)` | `variable:read` | yes |
| `write_variable(key, value)` | `variable:write` | yes |
| `log(level, message)` | `audit:log` | yes |
| `emit_event(type, payload)` | `event:emit` | yes |
| `get_instance_state()` | `instance:read` | yes |
| `now()` | **none** | **no — ungated by design** |
| `fail(reason, …)` | **none** | **no — ungated by design** |

`now` and `fail` being ungated is a **positive design statement**, not an omission:
`now()` is a pure time read with no state reach (LUA-14), and a script may always terminate
itself (LUA-15). A test that expects a gate on either is reading the matrix wrong, which is
why TC-LUA-05-S05 asserts their ungated-ness explicitly rather than leaving it unstated.

---

## 4. Test cases

### TC-LUA-05-S01: the platform table holds exactly the designed functions and nothing else

**Given:** A sandboxed state built by `executor.createSandboxedState` with an empty capability set.
**When:** A script enumerates `platform` with `pairs()` and compares the key set against the eight names in §3.
**Then:** Every one of the eight is present and is of Lua type `function`; the table contains no other key; the script returns `"OK"`.
**Layer:** unit
**Acceptance criterion mapped:** "No undeclared function is accessible from a Lua script."
**Note:** The expected-name list is generated in the test from the same `GATED`/`UNGATED` tables that drive the denial cases, so the surface assertion cannot drift from the capability matrix.

### TC-LUA-05-S02: an undeclared platform function is nil and calling it raises

**Given:** A sandboxed state with an empty capability set.
**When:** The script probes `platform.undeclared_function`, `platform.exec` and `platform.read_file`, then calls `platform.undeclared_function()`.
**Then:** All three probes are `nil` (script returns `"ABSENT"`), and the call fails with a runtime error rather than silently returning.
**Layer:** unit
**Acceptance criterion mapped:** "No undeclared function is accessible from a Lua script." Absent must mean absent — a silent no-op could be mistaken by a caller for a successful privileged operation.

### TC-LUA-05-S03: base is opened AND pruned — safe globals present, loaders gone (SBX-1)

**Given:** A sandboxed state built by the single constructor (invariant SBX-2).
**When:** A script checks (a) that base-library members `pairs`, `ipairs`, `next`, `type`, `tostring`, `tonumber`, `pcall`, `xpcall`, `error`, `assert`, `select`, `unpack`, `rawequal`, `rawget`, `rawset`, `setmetatable`, `getmetatable`, `_G`, `_VERSION` are all present, and (b) that `load`, `loadstring`, `loadfile`, `dofile`, `require`, `getfenv`, `setfenv`, `collectgarbage`, `print`, `newproxy`, `module`, `ffi`, `io`, `os`, `package`, `debug`, `jit`, `bit`, `coroutine` and `string.dump` are all `nil`.
**Then:** The script returns `"OK"`. A failure returns `BASE_NOT_OPENED:<name>` or `NOT_PRUNED:<name>`, naming which half of the invariant broke.
**Layer:** unit
**Acceptance criterion mapped:** "No undeclared function is accessible" — the base-library escape hatches are the largest undeclared surface.
**Why both halves in one test:** This is the **ordering** invariant SBX-1 ("prune strictly after open"), not merely an absence check. Asserting the dangerous names are absent proves nothing on its own — before ISS-0169 they were absent because `luaopen_base` was never called, so the removal code guarded a door that was not open. Asserting the *safe* members are present **in the same state** is what rules that out: if the prune ran before the open, base would have reinstalled the dangerous names; if base were never opened, the safe names would be missing. Only "safe present AND dangerous absent" is consistent with the correct order.

### TC-LUA-05-S04: a pruned loader cannot be reached through any surviving alias

**Given:** A sandboxed state with an empty capability set.
**When:** The script attempts to reach `load`/`loadstring` via `_G['load']`, `rawget(_G, 'load')`, and a metatable on `_G`; then calls `loadstring('return 1')()` under `pcall`.
**Then:** All routes yield `nil`, `_G` has no metatable, the `pcall` fails, and the script returns `"OK"`.
**Layer:** unit
**Acceptance criterion mapped:** "No undeclared function is accessible" — a global set to `nil` must not remain reachable by a second route.

### TC-LUA-05-S05: now and fail are ungated by design and raise no capability error

**Given:** An **empty** capability set.
**When:** The script calls `platform.now()`, and separately `platform.fail('policy rejected the request')`.
**Then:** `now()` succeeds and returns a 24-character ISO 8601 UTC string ending in `Z`. `fail()` fails with a message containing the script's own reason and **not** containing `"capability denied"`.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — the matrix's two deliberate exemptions are asserted as design, so a future "add a gate everywhere" change fails here rather than silently over-restricting.

### TC-LUA-05-S06: a denied call reports the DENIAL even when its arguments are invalid (CAP-1)

**Given:** A capability set holding `variable:read` but **not** `variable:write`, and a call `platform.write_variable(12345, 1)` whose first argument is a number (invalid — the key must be a real string).
**When:** The script executes.
**Then:** The result is a **capability denial** naming `write_variable` and `variable:write`, and the message does **not** contain `"invalid argument"`.
**And when:** The same call is repeated with `variable:write` granted.
**Then:** It now reports the **argument** error (`invalid argument: platform.write_variable argument 1 must be a string`) and does **not** contain `"capability denied"`.
**Layer:** unit
**Acceptance criterion mapped:** *(statement clause)* — ordering rule CAP-1, "the capability check precedes every side effect and every state read".
**Why the second half matters:** Asserting only the denial would pass even if argument validation had been deleted. Running the same call with the grant present proves the argument check still exists (it closes evidence E11's `lua_isstring` number-coercion hole, where `platform.write_variable(123, 1)` silently succeeded) **and** proves the gate genuinely runs first.

### TC-LUA-05-S07: call_service without the service capability returns a structured error

**Given:** A capability set holding `variable:read` but no `service:call:*` grant.
**When:** The script calls `platform.call_service('payment_svc', 'POST', '/pay')`.
**Then:** The execution fails with a structured message of the form `capability denied: platform.call_service requires 'service:call:payment_svc'; granted: variable:read`.
**Layer:** unit
**Acceptance criterion mapped:** "Calling `platform.call_service(\"X\")` without the `service:call:X` capability grant returns a structured error."
**Implemented by:** the `call_service` row of TC-LUA-06-D01..D06 and by TC-LUA-06-D11(a) in `LUA-06.md`, which covers this criterion together with the per-service exactness cases. Not duplicated as a standalone test block.

---

## 5. Fixtures and isolation

Every test builds its own `CapabilitySet`, its own `ExecutionContext`, and its own
`lua_State`; nothing is shared between test blocks. This is the Zig analogue of the
per-test-UUID rule for database fixtures: no test can observe another's state, and test
order cannot change any outcome.

`std.testing.allocator` fails any test that leaks, so lifetime defects in the code under
test surface as test failures rather than as silent growth.

Invariant CTX-1 (the `ExecutionContext` must outlive the `lua_State`) is satisfied
structurally: the context is a stack value in the test frame, and `executeScript` closes
its state before returning.

**No credentials of any kind appear in these tests.** Nothing here touches Keycloak, the
database, or the network.

---

## 6. Coverage summary

| Test case | Covers |
|---|---|
| TC-LUA-05-S01 | Exactly-eight surface, enumerated from Lua |
| TC-LUA-05-S02 | Undeclared functions absent and non-callable |
| TC-LUA-05-S03 | SBX-1 ordering: base opened, then dangerous globals pruned |
| TC-LUA-05-S04 | No alias route to a pruned loader |
| TC-LUA-05-S05 | `now`/`fail` ungated by design |
| TC-LUA-05-S06 | CAP-1 gate-before-arguments ordering, both directions |
| TC-LUA-05-S07 | Structured error for an ungranted `call_service` (via LUA-06 cases) |

**Implemented case count: 6 test blocks** in `src/lua/capability_enforcement_test.zig`
(TC-LUA-05-S01, S02, S03, S04, S05, S06). TC-LUA-05-S07 is satisfied by
`LUA-06.md`'s TC-LUA-06-D01..D06 and TC-LUA-06-D11 rather than by a separate block, and is
marked as such in §4 — it is a cross-reference, not an unimplemented case.

---

## 7. Implementation

- `src/lua/capability_enforcement_test.zig` — TC-LUA-05-S01..S06 (this spec's cases).
- `src/lua/execution_test.zig` — LUA-01..04 cases from `LUA-01-05.md`, plus the aggregate
  LUA-05/06 assertions.
- Wired into `zig build test-lua` (and therefore `zig build test`) via
  `src/lua_test_root.zig`, which imports the file and `refAllDecls`es it.

**ISS-0172 / GH #500 caveat, honoured deliberately.** A green `zig build test-lua` does not
by itself prove a file compiles: `src/lua_test_root.zig` pins several files with bare type
references (`_ = Module.TypeName;`), which force neither field-type resolution nor
function-body analysis — both limiters carried hard compile errors through a green target
for exactly that reason. Every case in this spec therefore **calls** real functions against
a real `lua_State` and asserts on observed output. Verified by deliberate mutation:
inverting SBX-1 in `stdlib.zig` (prune before open, with the after-block removed) turns
TC-LUA-05-S03 and S04 red; re-pointing `write_variable`'s gate at `variable:read` turns
TC-LUA-05-S06 red.

---

## 8. Traceability

- LUA-05 acceptance: TC-LUA-05-S01..S07.
- LUA-06 (capability check at call site): `tests/specs/LUA-06.md` — the per-function denial
  matrix that satisfies LUA-05's "each function checks the grant" statement.
- LUA-07 (manifest validation): `tests/specs/LUA-07.md` — the manifest supplies the
  `CapabilitySet` these gates consult.
- LUA-03 (stdlib restriction): `tests/specs/LUA-01-05.md` §4 — TC-LUA-05-S03/S04 strengthen
  its TC-LUA-03-08..12 with the ordering evidence those cases could not provide.
- LUA-11 / LUA-12 / LUA-13 (host function bodies): out of scope for this tranche. These
  cases assert that a denied call **cannot reach** the body, not what the body does.
