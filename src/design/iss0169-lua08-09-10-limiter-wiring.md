# Module: Lua Resource Limiter Wiring (LUA-08, LUA-09, LUA-10)

**Issue:** ISS-0169 tranche 2 / GH #495 (narrowed scope, 2026-08-08)
**Requirements in scope:** LUA-08 (instruction limit), LUA-09 (memory limit), LUA-10 (wall-clock timeout)
**Out of scope:** LUA-11, LUA-12, LUA-13, LUA-15, LUA-16 — see §8

## Module purpose

`src/lua/instruction_limiter.zig`, `src/lua/memory_limiter.zig`, and
`src/lua/timeout.zig` each compile and each one's core logic is correct in
isolation, but none of the three is reachable from `src/lua/executor.zig`.
`createSandboxedState` builds every Lua state with `defaultAlloc` (unbounded)
and installs no hook, so a script can run forever, allocate without bound, and
never observe a timeout. This design wires all three into the one function
that constructs every sandboxed state, replacing the existing
script-writable-global storage pattern with the registry-based pattern
`host_context.zig` already established for `ExecutionContext`.

This is a wiring design, not a rewrite: `InstructionLimiter`, `MemoryLimiter`,
and `TimeoutContext` keep their current field layouts and core algorithms.
The only structural change inside `instruction_limiter.zig` is how the
limiter pointer reaches the hook callback, and that the hook callback now
also carries the timeout check. `memory_limiter.zig` is unchanged internally;
only its caller (`executor.zig`) changes. `timeout.zig` is unchanged
internally; it gains one new caller.

---

## 1. Registry-based limiter storage (replaces the `__limiter__` global)

### 1.1 The defect being closed

`instruction_limiter.zig`'s current `installHook` does:

```
bindings.lua_pushlightuserdata(L, limiter);
bindings.lua_setglobal(L, "__limiter__");
```

`lua_setglobal` writes into `_G`, which sandboxed script code can read,
overwrite, or nil out (`_G.__limiter__ = nil`, or `__limiter__ = <bogus
userdata>`). `hookCallback` then trusts whatever `lua_touserdata` returns
without any provenance check. A script that clears the global before
entering its runaway loop defeats LUA-08 entirely; a script that
overwrites it with an unrelated light userdata value turns
`@ptrCast(@alignCast(ud))` into a type-confused read of arbitrary memory
interpreted as an `InstructionLimiter`. This is exactly the forgery class
`host_context.zig`'s header comment (lines 24-27) documents `__limiter__`
as a *pre-existing example of the bug it fixes for capabilities* — it was
never itself fixed.

### 1.2 The fix: reuse `host_context.zig`'s exact registry pattern

`host_context.zig` already solves this for `ExecutionContext` using
`LUA_REGISTRYINDEX` under a private string key (`REGISTRY_KEY =
"bpm.execution_context"`, `lua_setfield`/`lua_getfield`, never `_G`). The
registry is not reachable from script code: `debug` is not opened by
`stdlib.loadSafeStdlib`, `package` is not opened, and Lua source syntax has
no way to name a pseudo-index directly. The same channel now carries the
limiter state.

A single combined limiter context replaces the separate global lookup,
because LUA-08 and LUA-10 share one hook callback (§2) and both need to be
reachable from that one callback:

```
// src/lua/instruction_limiter.zig (extended)

pub const RunLimiter = struct {
    instruction: InstructionLimiter,
    timeout: ?timeout_ctx.TimeoutContext,   // null = no wall-clock check installed
};

pub const REGISTRY_KEY: [*:0]const u8 = "bpm.run_limiter";

pub fn installLimiter(L: *bindings.LuaState, limiter: *RunLimiter) void {
    bindings.lua_pushlightuserdata(L, limiter);
    bindings.lua_setfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);
    _ = bindings.lua_sethook(L, hookCallback, bindings.LUA_MASKCOUNT, HOOK_INSTRUCTION_INTERVAL);
}

fn limiterFromState(L: *bindings.LuaState) ?*RunLimiter {
    bindings.lua_getfield(L, bindings.LUA_REGISTRYINDEX, REGISTRY_KEY);
    defer bindings.lua_pop(L, 1);
    if (bindings.lua_type(L, -1) != bindings.LUA_TLIGHTUSERDATA) return null;
    const raw = bindings.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(raw));
}
```

This mirrors `host_context.zig` field-for-field: `lua_pushlightuserdata` +
`lua_setfield(L, LUA_REGISTRYINDEX, KEY)` to install, `lua_getfield` +
`lua_type` guard + `lua_touserdata` + `lua_pop(L, 1)` to read back, `null`
on any absent-or-wrong-type key. `installContext`'s round-trip verification
(`if (contextFromState(L) == null) return errors.LuaError.ContextInstallFailed;`)
is not needed here because `installLimiter` cannot itself fail — there is no
allocation and no external call between the push and the field write — but
the read-back helper is written the same fail-closed way (`null` on any
doubt, never a partial/garbage read) so a future refactor cannot
accidentally diverge from the established pattern.

**Lifetime.** `RunLimiter` is stack-allocated in `executeSource` (§3) and
lives for the same scope as the `lua_State` it is installed into — same
invariant as `ExecutionContext` (`CTX-1` in `host_context.zig`): the pointer
must outlive the state, and `executeSource`'s existing `defer
bindings.lua_close(L)` structurally guarantees this, because `RunLimiter`
is declared in the same function, above the `createSandboxedState` call,
and nothing frees or moves it before `lua_close` runs.

---

## 2. Combined instruction-count + elapsed-time hook

### 2.1 Why one hook, not two

`lua_sethook` accepts exactly one callback per `lua_State`; a second call
to `lua_sethook` replaces the first rather than adding a second listener.
LUA-08 and LUA-10 must therefore share the same `LUA_MASKCOUNT` callback.
This also directly answers the honest gap the current
`src/design/lua-integration.md` §15 recorded: a signal-handler or
separate-monitor-thread approach can preempt a *host* function's blocking
call, but it cannot interrupt Lua bytecode executing in a tight loop
without cooperation from something Lua itself calls back into — and the
count hook is exactly that cooperation point. Folding the elapsed-time
check into the existing per-N-instruction callback is the only mechanism
in this codebase that can actually interrupt `while true do end`, because
that loop contains no host call and no allocation for a separate watchdog
to intercept.

### 2.2 Callback design

```
fn hookCallback(L: *bindings.LuaState, ar: ?*bindings.lua_Debug) callconv(.c) void {
    _ = ar;
    const limiter = limiterFromState(L) orelse return; // fail-open is wrong;
        // see note below — in practice this is unreachable once installLimiter
        // has run, because the hook is registered in the same call that sets
        // the registry key.

    limiter.instruction.instructions_executed += HOOK_INSTRUCTION_INTERVAL;
    if (limiter.instruction.instructions_executed >= limiter.instruction.max_instructions) {
        raiseLimit(L, "instruction limit exceeded");
    }

    if (limiter.timeout) |*t| {
        t.checkTimeout() catch {
            raiseLimit(L, "wall-clock timeout exceeded");
        };
    }
}

fn raiseLimit(L: *bindings.LuaState, message: [:0]const u8) noreturn {
    bindings.lua_pushstring(L, message.ptr);
    _ = bindings.lua_error(L);
    unreachable; // lua_error longjmps; see host_context.zig raiseMessage precedent
}
```

**Why `limiterFromState(L) orelse return` is not a fail-open security
hole, unlike `host_context.requireCapability`'s fail-closed-on-`null`
rule.** The capability gate's `null` case means "no context was ever
installed for this call," which could happen if a future code path forgot
to call `installContext` — a real possibility the fail-closed design
defends against. The limiter hook's `null` case cannot occur in the wired
design: `installLimiter` sets the registry key and registers the hook in
the same function call, so by the time LuaJIT ever invokes `hookCallback`
the key is already present. The `orelse return` is defensive-only (matches
the existing `if (ud == null) return;` shape in the current
`instruction_limiter.zig`) and is retained so a malformed future refactor
fails safe (loop runs to Lua's own crash/OOM rather than the host
segfaulting on a null deref) rather than fails silent. This is documented
inline rather than treated as equivalent to the capability gate's
security-critical fail-closed rule, because unlike capability checks, an
absent limiter here is a programmer error, not an attacker-reachable
state — no script action can cause `limiterFromState` to return null once
installed.

### 2.3 Distinguishing the two trip conditions

**Decision: the two conditions are NOT distinguished in the raised Lua
error, but ARE distinguished in the host-side `ScriptResult`.**

Rationale: `lua_error` raises a plain string that becomes
`ScriptResult.error_message` via `executeSource`'s existing
`lua_pcall`-failure path (`bindings.lua_tostring(L, -1)`). The two
messages above ("instruction limit exceeded" vs "wall-clock timeout
exceeded") are already textually distinguishable for a human reading
`error_message`, and a caller that needs to branch on which one fired can
match the message text — that is sufficient for LUA-08/LUA-10's
acceptance criteria, which only require that each condition can be
demonstrated to have fired, not that the API expose a typed
discriminator. Do not add a new field to `ScriptResult` for this
distinction in this tranche: LUA-08 and LUA-10 do not ask for a structured
error taxonomy addition, and inventing one now would exceed this run's
scope (§8). If a future requirement needs a machine-readable
discriminator, `RunLimiter.timeout.?.timed_out` (already a `bool` field on
`TimeoutContext`) is inspectable by the host immediately after
`lua_pcall` returns non-zero and before `RunLimiter` goes out of scope —
so the data needed for a future structured error already exists without
any wiring change; only `executeSource` would need to read it.

### 2.4 Hook interval

`HOOK_INSTRUCTION_INTERVAL = 100` (unchanged from the current file — every
100 instructions). This bounds the worst-case timeout overrun: a hook that
fires every 100 instructions cannot detect an elapsed-time breach any
later than the wall-clock time for ~100 Lua instructions plus one
`checkTimeout()` call, which is negligible relative to `timeout_seconds`
(minimum 1 second per `manifest.Limits.MIN_TIMEOUT_SECONDS`). No change to
this constant is required by this design.

---

## 3. Wiring into `createSandboxedState` / `executeSource`

### 3.1 Limit source selection

`createSandboxedState(context: *const ExecutionContext)` has no limits
parameter today. It gains one:

```
pub const RunLimits = struct {
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
};

pub fn createSandboxedState(
    context: *const ExecutionContext,
    limits: RunLimits,
    limiter_storage: *instruction_limiter.RunLimiter,
    memory_limiter_storage: *memory_limiter.MemoryLimiter,
) (errors.LuaError || stdlib.LibraryError)!*bindings.LuaState
```

Both `limiter_storage` and `memory_limiter_storage` are caller-owned
(stack-allocated in `executeSource`), matching the existing `context`
parameter's ownership convention — `createSandboxedState` never owns what
it is given a pointer to.

Order inside `createSandboxedState` (extends the existing four-step
sequence; step numbers below correspond to the existing doc comment on
this function):

1. create the state — now via `bindings.lua_newstate(memory_limiter.MemoryLimiter.alloc,
   memory_limiter_storage)` instead of `createState()`'s current
   `bindings.lua_newstate(defaultAlloc, null)` (§4)
2. open + prune the stdlib (unchanged)
3. install the execution context (unchanged — `host_context.installContext`)
4. install the run limiter + combined hook (new step, via
   `instruction_limiter.installLimiter`)
5. register the `platform.*` table (unchanged)

Installing the limiter after the context and before `registerAll` keeps
the existing invariant that no closure is reachable from Lua before every
piece of state it might depend on already exists.

### 3.2 Where `RunLimits` comes from: manifest vs. unmanifested `executeScript`

**Decision: `executeScriptWithManifest` sources `RunLimits` from the
verified manifest's already-validated fields (`max_instructions`,
`max_memory_bytes`, `timeout_seconds` — these pass through
`manifest.validateManifest` against `Limits` before `executeSource` is
ever reached, per the existing code in `executor.zig` lines 203-213).
`executeScript` (no manifest) uses a fixed, conservative host-side default
— it does NOT run unlimited.**

Justification for rejecting "intentionally unlimited": `executeScript`'s
own doc comment says it "keeps the sandbox, the context installation and
every capability gate" and "must never become a way to bypass a gate."
Leaving LUA-08/09/10 unenforced on this path makes it exactly that
bypass — any caller that skips the manifest today gets sandboxing and
capability checks but an script that can run forever and allocate without
bound, which is a strictly weaker guarantee than the manifest path for no
documented reason. `executeScript`'s call sites are LUA-04's existing
tests and other internal callers, none of which need genuinely unbounded
execution — an unbounded internal helper script does not exist as a
legitimate use case anywhere in this codebase. Defaulting to unlimited
would also mean the sandbox's resource guarantees quietly depend on
whether a caller happened to route through the manifest path, which is
exactly the kind of two-tier enforcement `manifest.zig`'s own header
comment warns against ("Validating a bound and enforcing it are different
claims; conflating them is how this subsystem reached RELEASED while
executing nothing" — the parallel failure mode here would be "enforcing
it on one path and not the other").

The default values are the existing `Limits` minimums from `manifest.zig`,
reused rather than duplicated:

```
pub const UNMANIFESTED_DEFAULT_LIMITS = RunLimits{
    .max_instructions = manifest.Limits.MIN_INSTRUCTIONS,   // 1_000
    .max_memory_bytes = manifest.Limits.MIN_MEMORY_BYTES,   // 1_048_576 (1 MB)
    .timeout_seconds = manifest.Limits.MIN_TIMEOUT_SECONDS, // 1
};
```

Using the *minimum* safe bound (not the maximum) is deliberate: an
unmanifested script has declared no capabilities and no resource need, so
the most conservative bound that still lets a trivial script (a few
variable reads, one host call) complete is the correct default — a caller
that needs more must go through the manifest path, which is exactly the
incentive structure LUA-07 already establishes for capabilities. This
does slightly change `executeScript`'s current behavior (previously
unbounded); that is the intended fix, not a side effect, and is inside
this run's declared acceptance criteria ("max_instructions source decided
and justified for both `executeScript` (no manifest) and
`executeScriptWithManifest` paths").

### 3.3 `executeSource` changes

```
fn executeSource(
    context: *const ExecutionContext,
    script_source: []const u8,
    manifest_hash: ?[32]u8,
    limits: RunLimits,
) !ScriptResult {
    ...
    var limiter_storage = instruction_limiter.RunLimiter{
        .instruction = instruction_limiter.InstructionLimiter.init(
            context.allocator, limits.max_instructions),
        .timeout = timeout_ctx.TimeoutContext.init(limits.timeout_seconds),
    };
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(
        context.allocator, limits.max_memory_bytes);

    const L = createSandboxedState(
        context, limits, &limiter_storage, &mem_limiter_storage,
    ) catch |err| { ... };  // unchanged error path
    defer bindings.lua_close(L);
    ...
```

`executeScript` calls `executeSource(context, script_source, null,
UNMANIFESTED_DEFAULT_LIMITS)`. `executeScriptWithManifest` calls
`executeSource(context, script_source, registered_hash, RunLimits{
.max_instructions = script_manifest.max_instructions, .max_memory_bytes =
script_manifest.max_memory_bytes, .timeout_seconds =
script_manifest.timeout_seconds })` after its existing
`manifest.validateManifest` call, which already rejects out-of-bound
values before this point — `executeSource` never needs to re-validate
`limits` itself.

### 3.4 Allocation-failure-during-limiter-init note

`instruction_limiter.InstructionLimiter.init` and
`memory_limiter.MemoryLimiter.init` do not allocate (confirmed by reading
both files — `init` only assigns fields), so there is no new fallible step
between entering `executeSource` and calling `createSandboxedState`. No
new error variant is required for this step.

---

## 4. Memory-limiter wiring into `lua_newstate`

### 4.1 The defect being closed

`executor.zig`'s current `createState()` always calls
`bindings.lua_newstate(defaultAlloc, null)`. `defaultAlloc` wraps
`std.c.malloc`/`realloc`/`free` directly with no ceiling and no `ud`
parameter use. `MemoryLimiter.alloc` (in `memory_limiter.zig`) already has
the exact `lua_Alloc` signature LuaJIT expects
(`callconv(.c) fn(?*anyopaque, ?*anyopaque, usize, usize) ?*anyopaque`) and
already enforces `max_memory_bytes` against `ud`, cast back to
`*MemoryLimiter` — it is simply never the function pointer that
`lua_newstate` receives.

### 4.2 The fix

`createState()` is replaced by passing `memory_limiter.MemoryLimiter.alloc`
and a pointer to the caller-owned `MemoryLimiter` instance as `lua_newstate`'s
two arguments, directly in `createSandboxedState` (§3.1 step 1) rather than
through the now-removed `createState()` indirection:

```
const L = bindings.lua_newstate(
    memory_limiter.MemoryLimiter.alloc,
    memory_limiter_storage,
) orelse return errors.LuaError.LuaAllocFailed;
```

`defaultAlloc` is retained in the source (not deleted) — it remains useful
as a plain allocator for any future test harness that wants to construct a
raw `lua_State` without limiter overhead, and its doc comment already
documents it is intentionally kept for exactly this kind of forward
reference. No test in this tranche relies on `defaultAlloc` being the
active allocator, so keeping it unused-by-default is not a coverage gap.

### 4.3 `max_memory_bytes` source

Same manifest-vs-unmanifested split as §3.2, sharing the same `RunLimits`
struct — no separate decision is needed here; `RunLimits.max_memory_bytes`
already carries the resolved value into `MemoryLimiter.init` (§3.3).

### 4.4 Allocation-limit ordering caveat

Because `MemoryLimiter.alloc` is now the *first* allocator LuaJIT uses —
including for the `lua_State` structure itself — an `UNMANIFESTED_DEFAULT_LIMITS.max_memory_bytes`
of 1 MB must be large enough for `lua_newstate` plus `loadSafeStdlib` to
succeed before any script code runs. 1 MB (the existing
`Limits.MIN_MEMORY_BYTES`) is the value already validated in production
manifests as a safe floor for a running script body per `manifest.zig`'s
own bounds, and `lua_newstate` + stdlib load is a fixed, small allocation
footprint (well under 1 MB in LuaJIT's normal operation) — so no
separate, larger "bootstrap" limit is introduced. If state construction
itself fails the ceiling, `lua_newstate` returns `null` exactly as it does
for a genuine host OOM today, and `createState`'s existing
`orelse return errors.LuaError.LuaAllocFailed` path already covers that outcome
without any new error variant.

---

## 5. Test specifications (mutation-checkable, per requirement)

Each test below must be written so that reverting the wiring in §2–§4
(i.e. restoring `defaultAlloc`/no-hook/no-timeout) makes the test FAIL,
and applying the wiring makes it PASS. A test that only asserts "the
function was called and did not crash" does not satisfy this — every
assertion below checks an observable outcome that cannot be produced by
an absent limiter.

### 5.1 TC-LUA-08-01 — runaway script is actually terminated within budget

**Script body:** `"while true do end"`

**Setup:** Call `executeScript` (or `executeScriptWithManifest` with a
manifest specifying a small `max_instructions`, e.g. `Limits.MIN_INSTRUCTIONS
= 1_000`) with a `RunLimits`/manifest whose `max_instructions` is small
(e.g. 1,000) and whose `timeout_seconds` is generously large (e.g. 3600 —
the max) so that ONLY the instruction limit can be the cause of
termination, isolating this test from LUA-10.

**Assertions:**
- The call returns (does not hang the test process) within a short wall-clock
  bound asserted by the test harness itself (e.g. `std.testing` deadline or a
  wrapping timer around the call — this is a test-infra assertion, not
  reliance on the limiter under test, so it catches a total failure of the
  wiring rather than assuming the limiter works).
- `result.success == false`.
- `result.error_message` contains the instruction-limit message text (e.g.
  matches `"instruction limit"`), NOT the timeout message text — proving the
  instruction path specifically fired, not a coincidental timeout.
- **Mutation check:** with `defaultAlloc`/no-hook restored (i.e. the
  pre-fix `installHook` never called from `createSandboxedState`), this
  exact test must hang or time out the test binary — this is the proof the
  test exercises real enforcement, not merely that `installHook` can be
  invoked standalone (which is what the pre-existing GH-500 test already
  covers and was explicitly found insufficient).

### 5.2 TC-LUA-09-01 — allocation past a tiny cap is actually rejected

**Script body:** a large-table-building loop, e.g.:
```lua
local t = {}
for i = 1, 1000000 do
  t[i] = string.rep("x", 1024)
end
return #t
```
(repeatedly allocates ~1 KB strings into a growing table — guaranteed to
exceed a small memory ceiling long before 1,000,000 iterations complete,
and does not rely on any host API call, so it isolates the memory limiter
from capability-gate behavior.)

**Setup:** `RunLimits.max_memory_bytes` set to a deliberately tiny cap —
e.g. 65,536 bytes (64 KB), below `Limits.MIN_MEMORY_BYTES` so this test
must call `executeSource`'s internals directly or use a manifest-bypass
test seam consistent with how the existing `instruction_limiter.zig`/
`memory_limiter.zig` unit tests already construct `MemoryLimiter` directly
without going through manifest validation (validated bounds apply to the
manifest path, not to direct internal construction used for testing).
`max_instructions` and `timeout_seconds` set generously (max values) so
memory exhaustion is isolated as the only possible cause of failure.

**Assertions:**
- `result.success == false`.
- `result.error_message` reflects a script-level allocation/runtime failure
  (LuaJIT's own out-of-memory error text when `lua_Alloc` returns `null`,
  e.g. containing `"not enough memory"` — the standard LuaJIT OOM string),
  not a host crash, not a Zig panic, and the test process itself does not
  abort.
- `mem_limiter_storage.getPeakMemory()` (accessible in the test because the
  test constructs `MemoryLimiter` itself per the setup above) is `<=
  max_memory_bytes` at return — the limiter never let the tracked total
  exceed the ceiling, proving rejection happened at the allocation boundary
  rather than after the fact.
- **Mutation check:** with `defaultAlloc` restored as the passed allocator
  (i.e. `lua_newstate` wired back to `defaultAlloc`/`null` instead of
  `MemoryLimiter.alloc`/`&mem_limiter_storage`), this exact script must
  succeed (`result.success == true`, large table built) rather than fail —
  proving the test discriminates the presence/absence of the wiring, not
  just LuaJIT's own unrelated behavior.

### 5.3 TC-LUA-10-01 — interruption by elapsed time, isolated from instruction count

**Script body:** `"while true do end"` (same runaway loop as 5.1 — the
distinguishing factor is the limit configuration, not the script).

**Setup:** `RunLimits.max_instructions` set to the maximum allowed
(`Limits.MAX_INSTRUCTIONS = 10_000_000`, high enough that 10 million
iterations of an empty Lua loop body will not complete within the test's
timeout window), and `RunLimits.timeout_seconds` set to the minimum
(`Limits.MIN_TIMEOUT_SECONDS = 1`). This ordering guarantees that if the
script terminates before instruction count could plausibly reach 10
million within ~1-2 seconds of wall-clock time, the timeout — not the
instruction cap — was the actual trigger.

**Assertions:**
- The call returns within a bounded wall-clock window (e.g. asserted at
  under 5 seconds — generous slack above the 1-second configured timeout
  to absorb scheduling jitter, but far below what 10,000,000 instructions
  at a high instruction limit would allow if the instruction path were the
  actual cause).
- `result.success == false`.
- `result.error_message` contains the timeout message text (e.g. matches
  `"timeout"`), NOT the instruction-limit message text.
- `limiter_storage.timeout.?.timed_out == true` (the test constructs
  `RunLimiter` itself, same seam as 5.2, so this field is directly
  readable) — proving the specific branch inside the combined hook that
  fired was the timeout check, not a coincidental instruction-count trip
  that happens to share a similar wall-clock footprint.
- **Mutation check:** with the timeout branch removed from `hookCallback`
  (i.e. `checkTimeout` never called, leaving only the instruction-count
  check from the pre-LUA-10 wiring), this exact test must run for the full
  10,000,000-instruction budget rather than stopping at ~1 second — a
  materially different, easily distinguished wall-clock outcome (many
  seconds vs. ~1 second), proving the test specifically exercises the
  timeout path and not just "the hook fires at all."

---

## 6. Public interface (summary)

```
// src/lua/instruction_limiter.zig
pub const RunLimiter = struct { instruction: InstructionLimiter, timeout: ?TimeoutContext };
pub const REGISTRY_KEY: [*:0]const u8;
pub fn installLimiter(L: *bindings.LuaState, limiter: *RunLimiter) void;
pub const HOOK_INSTRUCTION_INTERVAL: c_int = 100;
// InstructionLimiter.init, getInstructionCount, wasLimitExceeded — unchanged

// src/lua/memory_limiter.zig
// MemoryLimiter.init, .alloc, .getCurrentMemory, .getPeakMemory, .wasLimitExceeded — unchanged signatures

// src/lua/timeout.zig
// TimeoutContext.init, .checkTimeout, .getElapsedMs, .getTimeoutMs — unchanged signatures

// src/lua/executor.zig
pub const RunLimits = struct {
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
};
pub const UNMANIFESTED_DEFAULT_LIMITS: RunLimits;

pub fn createSandboxedState(
    context: *const ExecutionContext,
    limits: RunLimits,
    limiter_storage: *instruction_limiter.RunLimiter,
    memory_limiter_storage: *memory_limiter.MemoryLimiter,
) (errors.LuaError || stdlib.LibraryError)!*bindings.LuaState;

// executeScript / executeScriptWithManifest signatures UNCHANGED —
// RunLimits resolution happens internally in executeSource, not exposed
// to existing callers.
```

---

## 7. Error taxonomy

No new entries in `errors.LuaError` are required. The two new failure
modes surface through the existing, unchanged paths:

| Condition | Surfaces as | Existing mechanism |
|---|---|---|
| Instruction limit exceeded | `ScriptResult{ .success = false, .error_message = "...instruction limit exceeded" }` | `lua_pcall` non-zero status → existing `executeSource` error-message extraction (unchanged code path) |
| Wall-clock timeout exceeded | `ScriptResult{ .success = false, .error_message = "...wall-clock timeout exceeded" }` | same `lua_pcall` non-zero status path |
| Memory limit exceeded | `ScriptResult{ .success = false, .error_message = "<LuaJIT's own out-of-memory string>" }` | `lua_Alloc` returns `null` → LuaJIT raises its own OOM error internally → same `lua_pcall` non-zero status path |
| `lua_newstate` fails outright (e.g. cap too small for bootstrap) | `errors.LuaError.LuaAllocFailed` | existing `createState`/`createSandboxedState` error path (unchanged variant, no new error added) |

All three new failure modes are absorbed by `executeSource`'s existing
`lua_pcall`-failure branch (`call_status != 0`) or `createSandboxedState`'s
existing `catch |err|` branch — no new `LuaError` variant, no new
`ScriptResult` field, and no change to `errors.zig`'s `statusCodeFromError`
or `errorDescription` exhaustive switches is needed. This keeps the change
additive to the error taxonomy rather than expanding it, consistent with
§2.3's decision not to add a structured discriminator in this tranche.

---

## 8. Out of scope (explicit)

This design covers **only** LUA-08, LUA-09, LUA-10. It does not touch, and
must not be extended during implementation to cover:

- **LUA-11** (variable read/write) and **LUA-13** (logging) — split to
  ISS-0624 / GH-591.
- **LUA-12** (service call), **LUA-15** (structured failure), **LUA-16**
  (runtime error capture / stack trace) — split to ISS-0625 / GH-592.

None of the wiring in §1–§4 requires any change to `host_api/`,
`service_catalog.zig`, `events.zig`, `structured_logger.zig`, or
`manifest.zig`'s validation logic (only its already-existing, already-validated
fields are read). `executeScript` and `executeScriptWithManifest` keep
their existing public signatures unchanged — only their shared internal
`executeSource` helper gains a new (internal-only) `RunLimits` parameter.
If implementation discovers that any of LUA-11/12/13/15/16 must change to
make LUA-08/09/10 work, that is a signal the scope boundary was drawn
wrong and must be escalated to ORCH before proceeding, not silently
absorbed into this branch.

---

## 9. Key invariants

- **INV-1** `RunLimiter`/`MemoryLimiter` storage always outlives the
  `lua_State` it is installed into (same shape as `host_context.zig`'s
  CTX-1), guaranteed structurally by `executeSource`'s existing `defer
  bindings.lua_close(L)`.
- **INV-2** The limiter pointer is reachable from Lua script code only
  through `LUA_REGISTRYINDEX`, never through `_G` — no `lua_setglobal` call
  remains anywhere in `instruction_limiter.zig` after this change.
- **INV-3** Every script execution — manifested or not — runs under a
  finite `max_instructions`, `max_memory_bytes`, and `timeout_seconds`.
  There is no code path through `executeScript` or
  `executeScriptWithManifest` that reaches `lua_pcall` with any limit
  unset or infinite.
- **INV-4** `lua_sethook` is called exactly once per state, installing the
  single combined callback — no code path registers a second, competing
  hook.

---

## 10. External dependencies

- `src/lua/luajit_bindings.zig` — `lua_sethook`, `LUA_MASKCOUNT`,
  `lua_pushlightuserdata`, `lua_setfield`, `lua_getfield`, `lua_type`,
  `lua_touserdata`, `lua_pop`, `LUA_REGISTRYINDEX`, `LUA_TLIGHTUSERDATA`,
  `lua_newstate`, `lua_pushstring`, `lua_error` — all already used
  elsewhere in this module family (`host_context.zig`, `executor.zig`); no
  new binding is required.
- `src/lua/manifest.zig` — `Limits.MIN_INSTRUCTIONS`,
  `Limits.MIN_MEMORY_BYTES`, `Limits.MIN_TIMEOUT_SECONDS` (read-only reuse
  for `UNMANIFESTED_DEFAULT_LIMITS`; no change to `manifest.zig` itself).
- `src/lua/time_source.zig` — already used internally by `timeout.zig`;
  unchanged.

## 11. Open questions

None. All decisions required by the acceptance criteria (registry-based
storage, unmanifested-path limit policy, combined hook design, memory-cap
wiring, mutation-checkable tests) are resolved above. If BACKEND-DEV finds
a `luajit_bindings.zig` signature that does not match what is sketched
here (e.g. a different `lua_sethook` argument order), that is an
implementation-detail correction within this design's intent, not a
design gap requiring rework.
