# Module: Lua Capability Enforcement and Manifest Binding

**Stage:** 8 — Lua Script Execution
**Requirements:** LUA-05, LUA-06, LUA-07
**Issue:** ISS-0169 / GH #495 — tranche 1 of 4
**Run:** WF03-ISS-0169-20260806
**Type:** E (novel / cross-cutting security plumbing) per `templates/lego-catalog.md`

---

## 0. Scope and non-scope

### 0.1 In scope (this design, this run)

| Req | What this design must deliver |
|---|---|
| **LUA-05** | Exactly the eight `platform.*` functions of Architecture §5.2 are registered, no others; each one **checks the caller's capability grant before executing**. |
| **LUA-06** | Every gated host function consults the `CapabilitySet` at **call time**. A missing capability raises a Lua error naming the function, the capability required, and the capabilities granted. |
| **LUA-07** | A **load-time entry point** exists that parses a manifest, validates it against the script artifact, binds the resulting `CapabilitySet` to the execution, and records the manifest hash on the execution result. |

Plus two prerequisites without which none of the above is testable:

- **P1 — context plumbing.** `ExecutionContext` must be reachable from inside a `lua_CFunction`. Today it is not (see §1).
- **P2 — base-library policy.** `luaopen_base` is never called, so a script has no `pairs`/`pcall`/`error`/`type`/`setmetatable`/`_G`. No realistic script — and no capability-denial test that wants `pcall` to observe the raised error — can run. See §5.

### 0.2 Explicitly NOT in scope (separate queued runs)

| Req | Reason |
|---|---|
| LUA-08, LUA-09, LUA-10 | Resource limiters. `instruction_limiter.zig` and `memory_limiter.zig` do not compile (ISS-0169 diagnosis E3/E4); LUA-10 needs a watchdog design (D4). Tranche 2. |
| LUA-11, LUA-12, LUA-13 | Stateful host API — variable staging, real service dispatch, structured logging. Tranche 3. |
| LUA-14, LUA-15, LUA-16 | Time source, structured failure, runtime error capture and event emission. Tranche 4. |
| ISS-0172 / GH #500 | Test-root pin blind spot. Its own run. |

**Consequence for this design:** the four state-touching host functions (`read_variable`, `write_variable`, `log`, `emit_event`) and `get_instance_state`/`call_service` keep their present *post-check* bodies in this tranche. This design changes **what happens before** they touch state, not what they do with state. That boundary is deliberate and is restated in §9.

This design carries three fields on the manifest — `max_instructions`, `max_memory_bytes`, `timeout_seconds` — through parsing and validation **without installing any limiter**. Tranche 2 consumes them. See §6.5 for the honesty rule that keeps this from becoming another silently-inert control.

---

## 1. Module purpose

`src/lua/` today registers eight host functions that are reachable from any script and gated by nothing. The ISS-0169 diagnosis proved this empirically: with a **completely empty** `CapabilitySet`, all seven capability-requiring `platform.*` calls succeeded (evidence E9). The root cause is structural, not a missing `if`:

```
every host_api/*.zig register():
    _ = context;                                  // context discarded
    lua_pushcclosure(L, platformXxx, 0);          // ZERO upvalues
```

A `lua_CFunction` receives only `*lua_State`. With zero upvalues and nothing in the registry, the `CapabilitySet` is **not in scope at call time**. There is no channel through which a check could read it. LUA-06 is therefore not "implemented but untested" — it is an absent security control.

This module's purpose is to create that channel, use it, and anchor it to a validated manifest:

1. Establish a single, script-unreachable binding from a live `lua_State` to its `*const ExecutionContext` (§2).
2. Give every gated host function a uniform, mandatory capability gate that fails closed (§3, §4).
3. Introduce the load-time path that turns a manifest into the `CapabilitySet` those gates consult, and records its hash on the execution result (§6).
4. Fix the sandbox so the base library exists and product and test build the **same** state (§5).

---

## 2. Context plumbing (P1, blocks LUA-05 and LUA-06)

### 2.1 The three candidate mechanisms

| Option | Mechanism | Assessment |
|---|---|---|
| **(a) upvalue** | `lua_pushlightuserdata(L, ctx)` then `lua_pushcclosure(L, fn, 1)`; read via `lua_upvalueindex(1)`. | Works, but requires touching **every** registration site and every function body identically; a new host function that forgets the upvalue silently reads stack garbage rather than failing. `lua_upvalueindex` is also not currently declared in `luajit_bindings.zig`. Per-closure repetition is exactly the kind of "one site forgot" defect that produced this issue. |
| **(b) registry** | Store the pointer in `LUA_REGISTRYINDEX` under one private key at state-setup time; any C function reads it with two calls. | One write, one shared read helper, no per-closure ceremony. The registry is a real Lua table but is **not addressable from script code** — a script has no `debug` library (blocked, LUA-03/LUA-14) and no `LUA_REGISTRYINDEX` pseudo-index, so it cannot read, replace, or nil the entry. |
| **(c) global `_G`** | `lua_setglobal(L, "__context__")`. | **FORBIDDEN.** Script-writable. This is precisely the defect already present in `fail.zig` (`__failure_reason__`, `__explicit_failure__`) and `instruction_limiter.zig` (`__limiter__`): a script can forge or nil the value that is meant to constrain it. |

### 2.2 Decision — option (b), the registry

**The `*const ExecutionContext` is stored in `LUA_REGISTRYINDEX` under the private string key `"bpm.execution_context"`, as a light userdata.**

Justification:

1. **Single point of failure, and it fails loudly.** One `installContext` call at state setup, before any registration. If it is missing, *every* gated function denies (§3.4 fail-closed rule), so the failure is total and immediately visible in tests — not a per-function gap that one forgotten registration reintroduces.
2. **Not script-reachable.** Unlike `_G`, and unlike a value only nominally private. `debug` is not opened, `package` is not opened, and Lua source syntax has no way to name a pseudo-index.
3. **Uniform read path.** A single `contextFromState` helper serves all eight functions and every future one. Option (a) would require every new host function to remember to pass `1` instead of `0` to `lua_pushcclosure` — an invitation to repeat this bug.
4. **No new bindings needed.** `lua_pushlightuserdata`, `lua_touserdata`, `lua_getfield`, `lua_setfield`, and `LUA_REGISTRYINDEX` are all already declared in `luajit_bindings.zig`. Option (a) would require adding `lua_upvalueindex`.

The registration signatures keep their `context` parameter (so the `_ = context;` lines disappear rather than being formalised), but they no longer need to *carry* it — `registerAll` installs it once, before the eight `register` calls.

### 2.3 Lifetime and ownership of the pointer — the load-bearing constraint

A light userdata is a **raw, non-owning, non-traced pointer**. Lua neither copies the pointee nor keeps it alive nor knows when it dies. Getting this wrong is a use-after-free inside a C callback. The contract:

- **Owner:** the caller of `executeScript`. The `ExecutionContext` is a stack value or caller-owned allocation in the calling Zig frame.
- **Lifetime rule (invariant CTX-1):** the `*const ExecutionContext` handed to `executeScript` MUST outlive the `lua_State`. `executeScript` guarantees this structurally: it creates the state, and its `defer lua_close(L)` runs before it returns, so the state is destroyed strictly inside the caller's frame where `context` is still live. **No `ExecutionContext` may be heap-allocated and freed, nor moved, between `installContext` and `lua_close`.**
- **Aliasing rule (invariant CTX-2):** the pointer installed is the *same* pointer the caller passed. `executeScript` must not install the address of a local copy, because a copy's `capabilities` field could later diverge from the caller's, and because the copy dies at a different time.
- **Constness (invariant CTX-3):** the pointee is `const` through the whole Lua call path. Host functions read capabilities; they never mutate the context. Tranche 3 will need mutable staging state — when it does, that is a **separate, explicitly-mutable field reached through the const context**, not a relaxation of CTX-3.
- **One state, one context (invariant CTX-4):** a `lua_State` is created per invocation (LUA-02) and receives exactly one context. Contexts are never swapped mid-execution.
- **No `lua_State` escape:** the state is never stored anywhere that outlives `executeScript`, so no callback can fire after `lua_close`.

`installContext` is called **after** `lua_newstate` and **before** `registerAll`, so no closure can ever be reachable from Lua before its context exists.

### 2.4 Read path and the fail-closed rule

`contextFromState(L)` performs: push the registry field by key → check it is a light userdata → `lua_touserdata` → pop → return `?*const ExecutionContext`.

It returns an **optional**. It returns `null` when — and only when — the key is absent or is not a light userdata. Every caller treats `null` as **deny**, never as **allow** (§3.4). Nothing in the design permits an "allow if no context" path.

---

## 3. Capability enforcement (LUA-05 second clause, LUA-06)

### 3.1 The gate

Every gated host function begins with the same three steps, in this order, before touching any argument beyond what the capability string needs:

1. Resolve the context via `contextFromState(L)`. `null` → deny.
2. Determine the required capability string (constant for seven of the eight; computed from argument 1 for `call_service`, §3.3).
3. `context.capabilities.has(required)` → false → deny.

Only after all three pass does the function proceed to argument validation and its body.

**Ordering rule (CAP-1):** the capability check precedes every side effect and every state read. A denied call must be indistinguishable from a call that never touched state, other than by the error it raises.

### 3.2 Capability matrix — Architecture §5.2, all eight functions

| `platform.*` | Capability required | Source of the string | Notes |
|---|---|---|---|
| `call_service(svc_id, …)` | `service:call:<svc_id>` | computed per call (§3.3) | LUA-06 TC-01/02 |
| `read_variable(key)` | `variable:read` | `StandardCapabilities.VARIABLE_READ` | LUA-06 TC-03/04 |
| `write_variable(key, value)` | `variable:write` | `StandardCapabilities.VARIABLE_WRITE` | LUA-06 TC-05/06 |
| `log(level, message)` | `audit:log` | `StandardCapabilities.AUDIT_LOG` | LUA-06 TC-07 |
| `emit_event(type, payload)` | `event:emit` | `StandardCapabilities.EVENT_EMIT` | LUA-05 TC-05-11 |
| `get_instance_state()` | `instance:read` | `StandardCapabilities.INSTANCE_READ` | LUA-05 TC-05-12 |
| `now()` | **none** | — | Ungated by design; `platform.now()` is a pure time read with no state reach. LUA-14. |
| `fail(reason, …)` | **none** | — | Ungated by design; a script may always terminate itself. LUA-15. |

`now` and `fail` being ungated is a **positive design statement**, not an omission. A design-validator or test that expects a gate on them is reading the table wrong. Both are still listed here so LUA-05's "exactly these functions and no others" is auditable from one place.

**LUA-05 first clause** (exactly these eight, no others) is already satisfied by `host_api/mod.zig` and was verified in the diagnosis (`platform.undeclared_function` is nil). This design does not add, remove, or rename any function. The table above is the normative registry: adding a ninth function without adding a row is a defect.

### 3.3 The `call_service` per-call capability

`call_service` is the one function whose required capability depends on an argument: `service:call:` + the `svc_id` passed by the script. This forces a departure from the other seven:

- The `svc_id` argument must be **read and type-validated before** the capability check, because it *is* the capability. This is the only permitted exception to CAP-1's "check before touching arguments" and it touches only argument 1.
- A non-string or missing `svc_id` is an **argument error**, not a capability denial. It raises `InvalidArgument` (§4.2), which is a different, distinguishable error from `CapabilityDenied`. A test must be able to tell them apart.
- The concatenated string must be built without allocating from a Zig allocator inside a `lua_CFunction` whose error path longjmps (§4.4). A fixed stack buffer with a documented maximum `svc_id` length is used; an `svc_id` longer than the buffer is an `InvalidArgument`, **never** a silent truncation that could match a shorter granted capability. Truncation here would be a privilege-escalation bug.
- **No wildcard matching in this tranche.** `has()` is exact string containment. `service:call:*` is not honoured. ADP-08 uses wildcards elsewhere in the platform; reconciling the two is out of scope here and is noted in §11 as a follow-up.

### 3.4 Fail-closed rule (CAP-2)

Absence of information is denial. Specifically, **deny** when:

- the registry holds no context (`contextFromState` returned `null`);
- the context's `capabilities` set is empty;
- the required capability string could not be constructed.

There is no code path in this design in which a gated function executes its body without an affirmative `has() == true`. **A gate that cannot determine the answer denies.** This is the direct antidote to E9, where an empty `CapabilitySet` permitted everything.

### 3.5 The canonical capability strings (diagnosis D7)

The strings in `capabilities.zig` `StandardCapabilities` are **canonical**:

```
service:call:<svc_id>   variable:read   variable:write
audit:log               event:emit      instance:read
```

The diagnosis flagged a conflict. Resolution, verified against the specs during this design:

- `tests/specs/LUA-06.md` and `tests/specs/LUA-01-05.md` already use the canonical spelling throughout (`variable:read`, `variable:write`, `audit:log`, `event:emit`, `instance:read`, `service:call:<svc>`). **The specs agree with the source.**
- The sole outlier is `tests/unit/lua_test.zig`, which uses `variable:read:*`, `event:emit:*`, and `log:write`. That file is **wrong** and must be corrected to the canonical strings in Step 3, not accommodated.

**Decision:** `capabilities.zig` is normative; `tests/unit/lua_test.zig` is amended. No string in `capabilities.zig` changes. Recording this here prevents a test suite from being written against three different spellings of the same grant — which is how a capability test can pass while enforcing nothing.

---

## 4. Error taxonomy and the denial path

### 4.1 What a denied call does, and how it reaches the caller

The requirement text for LUA-06 is explicit: a missing capability **raises a Lua error** carrying structured details. It is not a `nil` return and not a `(false, msg)` tuple, because a `nil` return is indistinguishable from a successful read of an absent variable — which is exactly the ambiguity E9 hid behind.

The denial path, end to end:

1. The gate determines denial.
2. It **formats a message and pushes it onto the Lua stack**, then raises. (§4.3 — this is the step whose absence produced garbage errors like `'upval'` and `'1.0954944061662e-311'` in evidence E6/E11.)
3. LuaJIT unwinds to the nearest protected boundary. Since `executeScript` runs the chunk under `lua_pcall`, and a script may itself use `pcall` (available once base is opened, §5), that boundary is either the script's own `pcall` or `executeScript`'s.
4. If the script did not catch it, `lua_pcall` returns non-zero and leaves the message on the stack.
5. `executeScript` reads the message and returns `ScriptResult{ .success = false, .error_message = <duped message>, .value = null }` — the shape it already returns for other runtime errors. **No change to `ScriptResult`'s existing failure contract.**

So a capability denial surfaces to the caller of `executeScript` as a failed `ScriptResult` whose `error_message` contains the function name, the required capability, and the granted set. The LUA-06 spec asserts on exactly this string content (TC-LUA-06-01 requires `"service:call:payment_svc"`, `"payment_svc"`, and the granted list).

A script that wraps the call in `pcall` catches the denial itself; the platform does not prevent this, and the script still never gains the capability. This is correct and is why §5 makes `pcall` available.

### 4.2 Error message format

One format, produced by one helper, for every denial:

```
capability denied: platform.<fn> requires '<required>'; granted: <summary>
```

- `<fn>` — the `platform.*` name as a script author would write it.
- `<required>` — the exact canonical capability string (for `call_service`, the fully-qualified `service:call:<svc_id>`, which also satisfies the spec's requirement that the message contain the bare `svc_id`).
- `<summary>` — `CapabilitySet.summary()`, which already renders `"(none)"` for an empty set and a comma-separated list otherwise. This is the field that makes a denial diagnosable rather than merely fatal.

Argument errors use a parallel, clearly distinct format so that a test cannot confuse the two:

```
invalid argument: platform.<fn> argument <n> must be <type>
```

### 4.3 Pushing before raising — mandatory (invariant ERR-1)

`lua_error` raises **whatever is currently on the stack top**. Every existing call site in `src/lua/host_api/*.zig` calls it with nothing pushed, which is why the diagnosis observed `platform.read_variable()` reporting `'1.0954944061662e-311'` (uninitialised stack memory) and `platform.log('only-one-arg')` reporting `'only-one-arg'` (the caller's own argument).

**Rule ERR-1: no call to `lua_error` anywhere in `src/lua/` may occur without a message value having been pushed immediately before it.** The shared raise helpers (§7.2) are the only sanctioned way to raise from a host function; a direct bare `lua_error(L)` in a host function is a defect. Fixing this for the six gated functions is in scope for this tranche because the LUA-06 message assertions are unsatisfiable without it.

### 4.4 Allocation discipline inside `lua_CFunction` (invariant ERR-2)

`lua_error` performs a `longjmp` (LuaJIT compiled as C) — Zig `defer` and `errdefer` in the raising frame **do not run**. Therefore:

- **No Zig allocator may hold an outstanding allocation across a raise.** Anything allocated in a host function must be freed before the raise, or never allocated.
- Message formatting uses a **fixed stack buffer** (a documented, generous size) and `lua_pushlstring`, which copies into Lua's own heap. Nothing is leaked because nothing was heap-allocated.
- `CapabilitySet.summary()` **allocates**, so it may not be called and then abandoned across the raise. The denial helper must render the summary into the same stack buffer (walking the grant set directly) rather than calling `summary()` and leaking its result. If the rendered summary would exceed the buffer, it is truncated **with a trailing ellipsis marker** — truncating a diagnostic message is safe; truncating a capability string used for comparison (§3.3) is not.
- `lua_pushstring` takes `[*:0]const u8`. Passing `@ptrCast` of a non-NUL-terminated slice pointer reads past the end — the latent bug already present in `fail.zig`. **Use `lua_pushlstring` with an explicit length** for any Zig slice.

### 4.5 Module error sets

Two error sets. Denials that occur inside Lua are raised as Lua errors, not returned as Zig errors — Zig errors cannot cross the C ABI boundary — so the Zig sets cover the **host-side** paths: state setup and load-time manifest handling.

`src/lua/errors.zig` — `LuaError` (existing set; already contains `CapabilityDenied`, `InvalidArgument`, `RuntimeError`, `TypeError`, and `statusCodeFromError` already maps `CapabilityDenied` → 403). **Two additions:**

| Variant | Meaning | HTTP |
|---|---|---|
| `ContextInstallFailed` | the execution context could not be installed into the registry at state setup | 500 |
| `ManifestRequired` | a load-time execution was requested with no manifest, and the deployment policy requires one | 422 |

Both must be added to `statusCodeFromError` and `errorDescription` — those switches are exhaustive, so omitting either is a compile error, which is the desired behaviour.

`src/lua/manifest.zig` — `ManifestError` (existing set: `UnauthorizedCapability`, `InstructionLimitTooLow/TooHigh`, `MemoryLimitTooLow/TooHigh`, `TimeoutTooLow/TooHigh`, `ManifestHashMismatch`, `MalformedManifest`). **No new variants needed** — LUA-07's spec cases map onto the existing nine. `MalformedManifest` covers structurally invalid input (TC-LUA-07-16); `ManifestHashMismatch` covers tamper detection (TC-LUA-07-12); `UnauthorizedCapability` covers the superset case (TC-LUA-07-02/14).

**Public error-set surface rule:** every function signature in §7 declares an explicit error set or a `!T` whose inferred set is checkable by `zig build`. The backend-dev error-set validation step (`zig build 2>&1 | grep -i "error set"`) must produce no output.

---

## 5. Base library policy (P2) — LUA-05 usability, LUA-03 regression risk

### 5.1 The problem

`loadSafeStdlib` opens `math`, `string`, and `table`, and never calls `luaopen_base`. The diagnosis enumerated the survivors (E8): `print`, `pairs`, `ipairs`, `pcall`, `error`, `type`, `setmetatable`, and `_G` are **all absent**.

Two consequences, both blocking:

1. **No realistic script can run.** Without `pairs`/`type`/`pcall`, ordinary business logic is unwritable. This is over-restriction, not security.
2. **The LUA-03 removals are currently no-ops on the product path.** `stdlib.zig` removes `load`, `loadstring`, `loadfile`, `dofile` — but `luaopen_base` never installed them, so those calls remove nothing. The ISS-0161 `loadfile` fix is correct code guarding a door that is not open **on this path**.
3. **Product and test build different states.** `execution_test.zig`'s `sandboxedState()` calls `luaopen_base(L)` explicitly and then `loadSafeStdlib`. `executeScript` does not. The currently-green LUA-03 tests therefore assert against a **more permissive state than the product ever constructs**. Its own doc comment claims it builds the state "exactly as executeScript builds it" — that comment is false today. This is a real test/implementation divergence (diagnosis R4), and it means the LUA-03 evidence proves nothing about the product.

### 5.2 Decision — open base, then prune

**`loadSafeStdlib` opens `luaopen_base` FIRST, then removes the dangerous entries it installs.** This is what `stdlib.zig`'s existing `removeGlobalIfExists` calls were plainly written for.

Ordering is load-bearing: **prune strictly after open**. Pruning before opening removes nothing and then `luaopen_base` reinstalls everything — an ordering inversion that would silently reopen the sandbox. This ordering is an invariant (SBX-1), not a stylistic preference.

**Kept** (required for a usable sandbox, none reach the filesystem, the process, or the code loader):

`pairs`, `ipairs`, `next`, `type`, `tostring`, `tonumber`, `pcall`, `xpcall`, `error`, `assert`, `select`, `unpack`, `rawequal`, `rawget`, `rawset`, `rawlen`, `setmetatable`, `getmetatable`, `_G`, `_VERSION`

Notes on the debatable members:
- `pcall`/`xpcall`/`error` are **required** — LUA-06's denial semantics are "raises a Lua error", and a script must be able to observe one. They also let scripts handle their own failures rather than aborting the instance.
- `rawget`/`rawset`/`rawequal`/`setmetatable`/`getmetatable` are kept. They bypass metamethods within the script's own tables; they grant no reach outside the sandbox. Metatable-based protection of platform tables is not part of this design's threat model — the capability gate is enforced in C, not by Lua-side table hiding, and is therefore unaffected by anything a script does with metatables.
- `_G` is kept. Its presence does not weaken the design precisely **because** §2.2 rejected storing the context in `_G`.

**Removed after opening** (each is a sandbox escape or a policy violation):

| Global | Why removed |
|---|---|
| `load`, `loadstring`, `loadfile`, `dofile` | Build or load executable code — defeats LUA-03 and LUA-04's bytecode gate. `loadfile`/`dofile` additionally reach the filesystem. |
| `require` | Module loading; `package` is not opened but `require` may still be present. |
| `getfenv`, `setfenv` | Environment manipulation; `setfenv` can rebind a function's globals table. |
| `collectgarbage` | Lets a script manipulate GC behaviour, which will interact with the tranche-2 memory limiter. Removed now so tranche 2 does not inherit a hole. |
| `print` | Writes to the host's stdout, bypassing structured logging (OBS-01). Scripts log via `platform.log`, which is capability-gated. |
| `newproxy` | LuaJIT/5.1 userdata-creation extension; no legitimate script use, and userdata interacts with the registry mechanism of §2. |
| `module` | Lua 5.1 global-namespace-mutating module declaration. |

**Not opened at all** (unchanged from today, LUA-03/LUA-14): `io`, `os`, `package`, `debug`, `jit`, `ffi`, `bit`, `coroutine`.

`ffi` deserves an explicit line: LuaJIT's FFI library is a **complete sandbox escape** — arbitrary memory access and arbitrary C calls. It must never be opened, and if it is reachable as a global after `luaopen_base` in this LuaJIT build, it is removed by name in the prune list above. Verification of its absence is an acceptance criterion (§10).

Removal uses the existing `removeGlobalIfExists` helper, which is already idempotent and silent on absence.

### 5.3 Unifying product and test state (fixes R4)

`execution_test.zig`'s `sandboxedState()` must **stop constructing the state itself**. Both the product and the tests must obtain their state from one function, so that the sandbox the tests assert on is the sandbox the product builds.

A new `createSandboxedState` (§7.1) becomes the single constructor: allocate the state, open and prune the stdlib, install the context, register the host API. `executeScript` calls it. `sandboxedState()` in the test file calls it too, and its stray `luaopen_base(L)` line is deleted.

**Invariant SBX-2: there is exactly one function in the repository that constructs a sandboxed `lua_State`.** Any test helper that opens a library directly is a divergence defect. This is what makes the LUA-03 evidence mean something.

### 5.4 Expected movement in existing tests

Opening base changes observable behaviour, so existing tests will move. Each movement is anticipated and is a *correction*, not a regression:

- `TC-LUA-03-01/02/03` uses `ipairs` — currently passes only because `sandboxedState()` opened base behind the product's back. After unification it passes for a legitimate reason.
- `TC-LUA-03-08..12` asserts `load`/`loadstring`/`dofile`/`loadfile`/`string.dump` are nil. These become **meaningful for the first time**: previously the globals were absent because base was never opened; now they are absent because they were deliberately pruned. Same assertion, real evidence.
- `TC-LUA-03` "calling a removed global raises" now exercises a genuine post-prune nil.
- `TC-LUA-04-02` (`return 1 + 1` through `executeScript`) is unaffected.

Any test that implicitly depended on base being **absent** must be identified and corrected in Step 3 rather than worked around.

---

## 6. Manifest binding (LUA-07)

### 6.1 What is missing

`manifest.zig::validateManifest` exists, compiles, and is **called by nothing** (evidence E12) — its only reference is a type pin in `src/lua_test_root.zig`. There is no load-time entry point at all: `executeScript` takes raw source text and runs it. `ExecutionContext` carries no manifest and no hash. Both LUA-07 acceptance criteria are therefore unimplementable as the code stands.

Three further defects in the existing validator, all of which this design corrects:

1. **The hash does not cover the script.** It hashes only the limits and capability strings. The requirement is to validate the manifest *against the script artifact*; a hash that ignores the script cannot detect a manifest paired with a different script.
2. **The hash is order-dependent and separator-free.** Capabilities are hashed in declaration order with no delimiter, so `["ab","c"]` and `["a","bc"]` collide, and reordering changes the hash. TC-LUA-07-13 requires logically identical manifests to hash identically.
3. **`ScriptManifest.deinit` leaks.** It frees the outer `capabilities` slice but not the individual strings `validateManifest` duped into it.

### 6.2 Manifest source and parsing

**Decision: the manifest is supplied by the caller as a parsed struct, not scraped from the script text.**

The LUA-07 spec sketches a `__manifest__` table inside the script. This design **rejects** that as the trust source: a manifest embedded in the artifact and read from the artifact is self-asserted — a script could declare any capabilities it liked and the "validation" would be a script grading its own homework. The trust chain must run the other way.

- The **caller** (engine / script repository, per REPO-05..07) holds the registered manifest and the granted `CapabilitySet` for the artifact.
- `parseManifest` accepts the manifest in its **serialised JSON form** (the form the repository stores) and produces a `ScriptManifest`. Structurally invalid input, missing required fields, or wrong field types → `MalformedManifest` (TC-LUA-07-16).
- `validateManifest` then checks declared capabilities against the granted set and the limits against `Limits` bounds — its existing behaviour, retained.
- An embedded `__manifest__` table in the script, if present, is **advisory only**; it is never the source of a grant. This is stated so no later tranche mistakes it for one.

### 6.3 Manifest hash — canonical form (fixes 6.1's defects 1 and 2)

`computeManifestHash` produces a SHA-256 over a **canonical serialisation**, defined here so that two implementations cannot disagree:

1. Capability strings **sorted lexicographically ascending** (byte order), each followed by a `0x00` separator. Sorting satisfies TC-LUA-07-13 (declaration order must not change the hash); the separator eliminates the concatenation ambiguity of defect 2.
2. A `0x00` field separator.
3. `max_instructions`, `max_memory_bytes`, `timeout_seconds` as decimal ASCII, each followed by `0x00`.
4. A `0x00` field separator.
5. **The SHA-256 digest of the script source bytes.** This is the addition that binds manifest to artifact and makes "a modified manifest without re-registration is rejected" checkable at all.

`verifyManifestHash(manifest, script_source, expected)` recomputes over the canonical form and compares against the hash the repository recorded at registration. Mismatch → `ManifestHashMismatch` (TC-LUA-07-12).

**Constant-time comparison** is used for the digest comparison. The hash is a tamper-detection value; a timing-variable comparison on a tamper check is a defect even where exploitation is impractical.

### 6.4 Load-time entry point and hash recording

A new `executeScriptWithManifest` is the load-time path. Order of operations, and every early exit is a rejection:

1. Reject bytecode (existing `isBytecode` check — must remain **first**, before any manifest work, so a bytecode artifact can never be validated into acceptance).
2. `verifyManifestHash` against the registered hash → mismatch rejects **before any state is created**. Nothing is executed on a failed integrity check.
3. `validateManifest` against the granted capability set and the `Limits` bounds → any `ManifestError` rejects, still before state creation.
4. Create the sandboxed state (§7.1), with a context whose `capabilities` is the validated set and whose `manifest_hash` is the verified hash.
5. Compile and run, as `executeScript` does today.
6. Return a `ScriptResult` carrying `manifest_hash`.

`executeScript` is **retained** with its current signature (LUA-04's tests and other callers depend on it) and is defined as `executeScriptWithManifest` with no manifest: no hash verification, `manifest_hash` is null on the result, and the capability set is whatever the context carries. It keeps the sandbox, the context installation, and every capability gate — the *only* thing it lacks is manifest verification. It must never become a way to bypass a gate.

**Recording the hash (second LUA-07 acceptance criterion).** `ScriptResult` gains an optional `manifest_hash: ?[32]u8`, and `ExecutionContext` gains `manifest_hash: ?[32]u8`. `executeScriptWithManifest` sets both. Rendering that hash into the persisted audit record is the **caller's** responsibility — `src/lua/` returns the value, the engine writes the row. This keeps `src/lua/executor.zig` free of I/O, consistent with the `transition.zig` purity precedent, and matches the diagnosis's D5 recommendation for the event boundary. **The corresponding audit-record write is in scope for whichever run owns the engine-side integration; this design commits `src/lua/` to producing the value and to nothing else.** §11 records this so it is not mistaken for done.

### 6.5 Limits carried, not enforced — the honesty rule

`ScriptManifest` carries `max_instructions`, `max_memory_bytes`, and `timeout_seconds`, and this tranche **validates them against the `Limits` bounds but installs no limiter**. Tranche 2 (LUA-08/09/10) installs them.

To ensure this does not become another silently-inert control of the ISS-0155 kind:

- **No code, comment, doc, or log line in this tranche may state or imply that a limit is enforced.** The fields are documented in the source as *"validated and carried for LUA-08/09/10; not enforced in this tranche — see ISS-0169 tranche 2"*.
- No test written in this tranche may assert that a limit is enforced.
- Tranche 2's acceptance is that these fields reach a real installed limiter.

Validating a bound and enforcing it are different claims. Conflating them is how this subsystem reached RELEASED while executing nothing.

### 6.6 `ScriptManifest.deinit` (fixes 6.1's defect 3)

`deinit` must free **each duped capability string and then the outer slice**. Ownership is stated on the struct: `ScriptManifest` owns its `capabilities` strings, allocated with its `allocator`; the caller owns the `ScriptManifest` and must call `deinit`. `validateManifest`'s allocation loop needs an `errdefer` that unwinds partial allocation if a later `dupe` fails.

---

## 7. Public interface

Signatures only. No bodies — implementation is BACKEND-DEV's (Step 3).

### 7.1 `src/lua/executor.zig`

```zig
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    capabilities: *const capabilities.CapabilitySet,
    instance_id: []const u8,
    actor_id: []const u8,
    manifest_hash: ?[32]u8 = null,   // NEW (LUA-07)
};

pub const ScriptResult = struct {
    success: bool,
    value: ?ScriptValue,
    error_message: ?[]const u8,
    manifest_hash: ?[32]u8 = null,   // NEW (LUA-07)

    pub fn deinit(self: *ScriptResult, allocator: std.mem.Allocator) void;
};

/// Single constructor for a sandboxed state (invariant SBX-2).
/// Opens+prunes stdlib, installs context, registers host API.
/// Caller owns the state and must lua_close it.
pub fn createSandboxedState(
    context: *const ExecutionContext,
) (errors.LuaError || stdlib.LibraryError)!*bindings.LuaState;

/// Existing entry point, signature UNCHANGED. No manifest verification.
pub fn executeScript(
    context: *const ExecutionContext,
    script_source: []const u8,
) !ScriptResult;

/// NEW — load-time entry point (LUA-07).
/// Verifies the manifest hash against script_source and the registered hash,
/// validates the manifest, then executes. Rejects before creating any state.
pub fn executeScriptWithManifest(
    context: *const ExecutionContext,
    script_source: []const u8,
    script_manifest: *const manifest.ScriptManifest,
    registered_hash: [32]u8,
) (errors.LuaError || manifest.ManifestError || error{OutOfMemory})!ScriptResult;
```

### 7.2 `src/lua/host_context.zig` — NEW module

The registry channel of §2 and the shared gate of §3, in one place.

```zig
/// Private registry key. Not reachable from script code.
pub const REGISTRY_KEY: [*:0]const u8 = "bpm.execution_context";

/// Install the context pointer into LUA_REGISTRYINDEX.
/// Call AFTER lua_newstate, BEFORE registerAll. Invariants CTX-1..CTX-4 (§2.3).
pub fn installContext(
    L: *bindings.LuaState,
    context: *const executor.ExecutionContext,
) errors.LuaError!void;

/// Read the context back inside a lua_CFunction.
/// Returns null if absent or not a light userdata. Callers MUST treat
/// null as DENY (invariant CAP-2, §3.4).
pub fn contextFromState(L: *bindings.LuaState) ?*const executor.ExecutionContext;

/// The capability gate. Returns true if the call may proceed.
/// On false it has ALREADY pushed the denial message and raised —
/// control does not return to the caller in that case (longjmp).
pub fn requireCapability(
    L: *bindings.LuaState,
    function_name: []const u8,
    required: []const u8,
) bool;

```

Raise helpers — the only sanctioned way to raise from a host function (ERR-1):

```zig
/// Push a formatted capability-denial message and raise (never returns).
/// Fixed stack buffer only — no allocator (invariant ERR-2, §4.4).
pub fn raiseCapabilityDenied(
    L: *bindings.LuaState,
    function_name: []const u8,
    required: []const u8,
    granted: *const capabilities.CapabilitySet,
) noreturn;

/// Push a formatted argument-error message and raise (never returns).
pub fn raiseInvalidArgument(
    L: *bindings.LuaState,
    function_name: []const u8,
    arg_index: c_int,
    expected_type: []const u8,
) noreturn;

```

Argument and capability-string helpers:

```zig
/// True string check. lua_isstring accepts numbers in Lua 5.1 (coercion),
/// which is why platform.write_variable(123, 1) silently succeeded (E11).
/// This is lua_type(L, idx) == LUA_TSTRING.
pub fn isRealString(L: *bindings.LuaState, idx: c_int) bool;

/// Build "service:call:<svc_id>" into a caller-provided fixed buffer.
/// Returns null if svc_id exceeds the buffer — caller raises InvalidArgument.
/// MUST NOT truncate (§3.3).
pub fn serviceCallCapability(
    buffer: []u8,
    svc_id: []const u8,
) ?[]const u8;
```

`raiseCapabilityDenied` and `raiseInvalidArgument` are typed `noreturn`, which makes ERR-1 structural: a host function cannot fall through past a raise, and cannot raise without going through a helper that pushes first.

### 7.3 `src/lua/host_api/*.zig` — changed signatures

Each of the eight keeps its `register` signature; the difference is that `_ = context;` disappears and the C function body opens with the gate.

```zig
// Unchanged shape, six of eight now gated:
pub fn register(L: *bindings.LuaState, context: *const executor.ExecutionContext) !void;
```

`registerAll` gains the context installation:

```zig
/// Installs the execution context into the registry, creates the platform
/// table, registers exactly the eight Architecture §5.2 functions (§3.2),
/// and assigns it to the global `platform`.
pub fn registerAll(
    L: *bindings.LuaState,
    context: *const executor.ExecutionContext,
) !void;
```

### 7.4 `src/lua/manifest.zig` — changed and new

```zig
pub const ScriptManifest = struct {
    capabilities: []const []const u8,   // OWNED — deinit frees each + the slice
    max_instructions: u64,              // validated, NOT enforced this tranche (§6.5)
    max_memory_bytes: u64,              // validated, NOT enforced this tranche
    timeout_seconds: u32,               // validated, NOT enforced this tranche
    manifest_hash: [32]u8,
    allocator: std.mem.Allocator,

    /// FIXED: frees each duped capability string, then the slice (§6.6).
    pub fn deinit(self: *ScriptManifest) void;
};

```

Parsing and hashing:

```zig
/// NEW — parse the repository's serialised manifest form (§6.2).
pub fn parseManifest(
    allocator: std.mem.Allocator,
    manifest_json: []const u8,
) (ManifestError || error{OutOfMemory})!ScriptManifest;

/// NEW — canonical SHA-256 over sorted+separated capabilities, limits,
/// and the script source digest (§6.3).
pub fn computeManifestHash(
    allocator: std.mem.Allocator,
    manifest_caps: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    script_source: []const u8,
) (ManifestError || error{OutOfMemory})![32]u8;

/// NEW — recompute and compare in constant time (§6.3).
pub fn verifyManifestHash(
    allocator: std.mem.Allocator,
    script_manifest: *const ScriptManifest,
    script_source: []const u8,
    expected_hash: [32]u8,
) ManifestError!void;

```

Validation:

```zig
/// CHANGED — now takes script_source so the hash it stores binds the
/// manifest to the artifact. Behaviour otherwise unchanged.
pub fn validateManifest(
    manifest_caps: []const []const u8,
    granted_capabilities: *const capabilities.CapabilitySet,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    script_source: []const u8,          // NEW parameter
    allocator: std.mem.Allocator,
) (ManifestError || error{OutOfMemory})!ScriptManifest;
```

### 7.5 `src/lua/stdlib.zig` — changed

```zig
pub const LibraryError = error{ FailedToLoadLibrary };

/// Opens base FIRST, then math/string/table, then prunes every dangerous
/// global (§5.2). Ordering is invariant SBX-1: prune strictly after open.
pub fn loadSafeStdlib(L: *bindings.LuaState) LibraryError!void;
```

### 7.6 `src/lua/errors.zig` — changed

```zig
pub const LuaError = error{
    LuaAllocFailed, BytecodeNotAllowed, CompileError, RuntimeError,
    CapabilityDenied, TypeError, InvalidArgument, DatabaseError,
    UnknownEventType,
    ContextInstallFailed,   // NEW (§4.5)
    ManifestRequired,       // NEW (§4.5)
};

pub fn statusCodeFromError(err: LuaError) u16;   // exhaustive — add both arms
pub fn errorDescription(err: LuaError) []const u8; // exhaustive — add both arms
```

### 7.7 `src/lua/capabilities.zig` — unchanged

`CapabilitySet` (`init`/`deinit`/`add`/`has`/`summary`) and `StandardCapabilities` are correct and normative (§3.5). **No changes.** `tests/unit/lua_test.zig` is amended to match, not the reverse.

### 7.8 `src/lua/mod.zig` — changed

Re-export the new `host_context` module so `src/lua_test_root.zig` and tests can reach it.

---

## 8. Dependencies

### 8.1 Depends on

| Dependency | Use |
|---|---|
| `src/lua/luajit_bindings.zig` | `lua_pushlightuserdata`, `lua_touserdata`, `lua_getfield`, `lua_setfield`, `LUA_REGISTRYINDEX`, `LUA_TLIGHTUSERDATA`, `lua_pushlstring`, `lua_error`, `luaopen_base`. **All already declared** — no new extern declarations are required by this design. |
| Vendored LuaJIT 2.1 (`vendor/luajit/`, ISS-0161) | Real interpreter. Without it nothing here is testable. |
| `src/lua/capabilities.zig` | `has()` and the canonical strings. |
| `std.crypto.hash.sha2.Sha256` | Manifest and script hashing. |
| `std.crypto.timing_safe` (or equivalent) | Constant-time hash comparison (§6.3). |

### 8.2 Depended on by

| Consumer | Relationship |
|---|---|
| Tranche 2 (LUA-08/09/10) | Consumes the validated limits from `ScriptManifest` and the registry channel — a limiter must live in the registry, not `_G` (diagnosis E6). §2 establishes that pattern. |
| Tranche 3 (LUA-11/12/13) | Every stateful host function reaches its store **through** the context this design installs. Blocked on §2. |
| Tranche 4 (LUA-15/16) | Event emission needs capability state at failure — `CapabilitySet.summary()` reached through the context. |
| Engine / script repository | Supplies manifest + registered hash; persists `manifest_hash` into the audit record (§6.4). |

### 8.3 Files affected

| File | Change |
|---|---|
| `src/lua/host_context.zig` | **NEW** — registry channel, gate, raise helpers. |
| `src/lua/executor.zig` | `createSandboxedState`; `executeScriptWithManifest`; `manifest_hash` on context and result. |
| `src/lua/host_api/mod.zig` | `registerAll` installs the context first. |
| `src/lua/host_api/call_service.zig` | Gate with computed `service:call:<svc_id>`; real string check; push-before-raise. |
| `src/lua/host_api/read_variable.zig` | Gate on `variable:read`; real string check; push-before-raise. |
| `src/lua/host_api/write_variable.zig` | Gate on `variable:write`; real string check (fixes the numeric-key hole, E11); push-before-raise. |
| `src/lua/host_api/log.zig` | Gate on `audit:log`; push-before-raise. |
| `src/lua/host_api/emit_event.zig` | Gate on `event:emit`; push-before-raise. |
| `src/lua/host_api/get_instance_state.zig` | Gate on `instance:read`. |
| `src/lua/host_api/now.zig` | Ungated by design (§3.2); drop `_ = context;`, no gate added. |
| `src/lua/host_api/fail.zig` | Ungated by design; `lua_pushlstring` instead of `lua_pushstring` on a non-NUL slice (§4.4). Globals stay until tranche 4. |
| `src/lua/stdlib.zig` | Open base first, then prune (§5.2). |
| `src/lua/manifest.zig` | `parseManifest`, `computeManifestHash`, `verifyManifestHash`; `validateManifest` takes `script_source`; `deinit` leak fix. |
| `src/lua/errors.zig` | Two new variants + both exhaustive switches. |
| `src/lua/mod.zig` | Re-export `host_context`. |
| `src/lua/execution_test.zig` | `sandboxedState()` delegates to `createSandboxedState`; delete its `luaopen_base` line (§5.3). |
| `tests/unit/lua_test.zig` | Correct `variable:read:*` / `event:emit:*` / `log:write` to canonical strings (§3.5). |
| `src/lua_test_root.zig` | Pin `host_context.zig`. **Type-only pins do not prove compilation** (ISS-0172) — pin so bodies are analysed. |

---

## 9. Behaviour explicitly NOT changed in this tranche

Stated so no reviewer mistakes a deliberate boundary for an oversight, and so no implementer quietly widens scope:

- `read_variable` still returns `nil` after the gate passes. It is now *gated*, not *implemented*. LUA-11.
- `write_variable` still stages nothing after the gate passes. LUA-11.
- `log` still writes no structured entry after the gate passes. LUA-13.
- `emit_event` still appends no event after the gate passes. Tranche 4.
- `get_instance_state` still returns an empty table after the gate passes. LUA-11.
- `call_service` keeps its simulation path and its hardcoded `{}` non-simulation branch; it does not consult `service_catalog.zig` and still returns `(string, number)` rather than a table. LUA-12.
- No instruction, memory, or wall-clock limit is installed. LUA-08/09/10.
- No `SCRIPT_ERROR` / `SCRIPT_FAILED` event is emitted; `lua_pcall` still passes `errfunc = 0` (no traceback handler). LUA-15/16.

**The claim this tranche makes is exactly this:** a script without a capability **cannot reach** the function body, and the manifest that grants capabilities is verified against the artifact before execution. Nothing more.

---

## 10. Acceptance criteria mapping

| Requirement | Acceptance criterion (verbatim) | Design element |
|---|---|---|
| LUA-05 | `platform.call_service("X")` without `service:call:X` returns a structured error | §3.3 computed capability; §4.2 message format; §4.1 surfacing as a failed `ScriptResult` |
| LUA-05 | No undeclared function is accessible from a Lua script | §3.2 normative eight-function table; `registerAll` unchanged in membership; §5.2 pruning removes base-library escape hatches |
| LUA-05 | *(statement)* each function checks the caller's capability grant | §3.1 gate, §3.2 matrix (incl. the deliberate `now`/`fail` exemptions) |
| LUA-06 | A capability denial test exists for every host function in Architecture §5.2 | §3.2 matrix makes the six gated functions enumerable; §2 makes a denial reachable at all; §5.2 keeps `pcall` so a test can observe the raise |
| LUA-06 | *(statement)* error carries function name, capability required, capabilities granted | §4.2 format; §4.3 push-before-raise (without which the message is stack garbage) |
| LUA-07 | A modified manifest without re-registration is rejected at load time | §6.3 canonical hash **including the script digest**; §6.4 step 2 verifies before any state is created |
| LUA-07 | The manifest hash appears in the execution audit record | §6.4 `manifest_hash` on `ExecutionContext` and `ScriptResult`; engine persists (§11 records the boundary) |

**Additional verification points BACKEND-DEV must satisfy in Step 3:**

- With an **empty** `CapabilitySet`, all six gated functions raise — the direct inverse of diagnosis E9, which is the empirical proof that the control now exists.
- `platform.write_variable(123, 1)` raises `InvalidArgument` rather than succeeding (E11's coercion hole, fixed by `isRealString`).
- `platform.read_variable()` with no arguments produces the §4.2 argument-error message, not stack garbage.
- `ffi`, `io`, `os`, `package`, `debug`, `jit`, `load`, `loadstring`, `loadfile`, `dofile`, `require`, `getfenv`, `setfenv`, `collectgarbage`, `print`, `newproxy`, `module` all evaluate to `nil` through `executeScript`.
- `pairs`, `ipairs`, `pcall`, `error`, `type`, `tostring`, `setmetatable` are all present through `executeScript`.
- `src/lua/execution_test.zig` contains no `luaopen_base` call (SBX-2).
- No `lua_error` call in `src/lua/` lacks a preceding push (ERR-1).
- `zig build 2>&1 | grep -i "error set"` produces no output.

---

## 11. Follow-ups deliberately left open

Recorded so they are visible rather than lost. Per CLAUDE.md these are **filed and forwarded** if newly discovered during implementation — not fixed on this branch.

1. **Wildcard capabilities.** `has()` is exact-match; `service:call:*` is not honoured here, while ADP-08 supports wildcards for SERVICE_TASK. Reconciling the two capability models is a cross-cutting decision beyond this tranche.
2. **Audit-record persistence of `manifest_hash`.** This design commits `src/lua/` to *producing* the hash on `ScriptResult`. The engine-side write into the audit row belongs to the engine-integration run; LUA-07's second criterion is only end-to-end satisfied when that lands.
3. **`fail.zig`'s script-writable globals** (`__failure_reason__`, `__failure_details__`, `__explicit_failure__`) are forgeable and are never read back. This design fixes only the `lua_pushstring` read-past-end bug. The globals move to the registry in tranche 4 (LUA-15), following the §2 pattern.
4. **ISS-0172 / GH #500.** Until it is fixed, `zig build test-lua` going green does **not** prove a file compiles — type-only pins skip function bodies. Step 3 must verify `host_context.zig` and the changed host functions with a target that genuinely calls them.
