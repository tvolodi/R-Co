# Module: Lua Resource Limiter Wiring (LUA-08, LUA-09, LUA-10)

**Issue:** ISS-0169 tranche 2 / GH #495 (narrowed scope, 2026-08-08)
**Requirements in scope:** LUA-08 (instruction limit), LUA-09 (memory limit), LUA-10 (wall-clock timeout)
**Out of scope:** LUA-11, LUA-12, LUA-13, LUA-15, LUA-16 — see §8
**Revision note (rework 1):** CODE-DESIGN-VALIDATOR FAILed the first
version of this design (CDV-0169-1..4) because LUA-10's combined
count-hook (§2, unchanged by this revision) only covers a tight
Lua-bytecode loop and cannot satisfy LUA-10's other two acceptance
criteria — a script blocked inside a host function call, and enforcement
"from outside the Lua state." §2.5 is new in this revision and adds a
genuinely separate, host-external watchdog thread for those two cases.
§5.4/§5.5 are new tests exercising them. §11 now honestly names the one
sub-case (true pre-emption of an in-flight blocking syscall) this
tranche still cannot close, with a recommendation rather than a silent
gap. LUA-08 and LUA-09's sections (§1, §3 excluding the watchdog-start
addition, §4) were APPROVED as designed and are unchanged in substance.

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
internally except that it gains one new caller for its existing
`TimeoutContext`, plus one new, separate type (`WatchdogState` /
`WatchdogHandle`, §2.5) for the host-external mechanism LUA-10's full
acceptance criteria require — the two mechanisms coexist (§2.5.5) rather
than one replacing the other.

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

**§2.1–§2.4 above cover only the tight-Lua-loop sub-case of LUA-10** (a
script that never leaves Lua bytecode dispatch, so the count hook keeps
getting control). LUA-10's own acceptance criteria name two more
sub-cases the count hook cannot reach at all — §2.5 below is new in this
revision and addresses them with a genuinely separate, host-external
mechanism. Nothing in §2.5 changes the count-hook design above; the two
mechanisms run side by side (§2.5.5).

### 2.5 Host-external watchdog (REWORK — addresses CDV-0169-1, CDV-0169-2)

#### 2.5.1 Why the count hook cannot cover this, restated precisely

`lua_sethook`'s `LUA_MASKCOUNT` callback is invoked *by LuaJIT's own
bytecode dispatch loop*, on the same OS thread, inside the same call stack
as `lua_pcall`. Two consequences follow directly from that, and both are
structural — no interval tuning or callback rewrite changes them:

1. **It cannot fire while a `lua_CFunction` is running.** Once
   `platformCallService` (or any `host_api/*.zig` registration) is
   entered, LuaJIT is not dispatching Lua bytecode — it is executing a
   plain C function on the Lua thread's C stack. The count hook has
   nothing to attach to until that C function returns control to the VM.
   A `lua_CFunction` that blocks (waits on a socket, sleeps, spins)
   therefore blocks past any instruction-count threshold, no matter how
   small `HOOK_INSTRUCTION_INTERVAL` is set. This is LUA-10's own
   acceptance criterion 1 ("a script that blocks on a host function is
   still terminable within the configured timeout").
2. **It is enforcement from *inside* the Lua state's own execution, not
   from outside it.** `hookCallback` runs only because the Lua VM chose
   to call it, on the VM's own thread. Anything that can prevent the VM
   from ever reaching that call point (a `lua_CFunction` that never
   returns, or — hypothetically — a modified/compromised hook table)
   also prevents the "enforcement" from ever running. This is LUA-10's
   own acceptance criterion 2 ("the timeout is enforced from outside the
   Lua state").

A mechanism that satisfies both criteria must run on a **different OS
thread** than the one executing `lua_pcall`, and must not depend on the
Lua VM voluntarily calling back into host code to notice the deadline.

#### 2.5.2 What "terminate" can safely mean here — the hard constraint

`luajit_bindings.zig` exposes no cross-thread cancellation primitive:
there is no `lua_State` variant of "call this from another thread and
have it interrupt whatever the owning thread is doing" (no POSIX
`pthread_cancel` equivalent, no `lua_State`-safe async signal, and
critically: **`lua_error`, `lua_close`, and every other `lua_*` function
in this binding file are documented and used everywhere in this codebase
as callable only from the thread that owns `L`** — `host_context.zig`'s
own `raiseMessage` relies on `lua_error`'s `longjmp` unwinding the
*calling* thread's C stack; calling it from a second thread while the
first thread is inside a blocking C function would call `longjmp` across
stacks it does not own, which is undefined behavior, not a controlled
interrupt).

This means a watchdog thread **cannot safely call any `lua_*` function
against the same `lua_State` while the owning thread might still be
using it.** That rules out the `lua-integration.md` §15.2 sketch this
design deliberately does not carry forward (`g_lua_state_for_timeout...
c.lua_error(L)` called from "a signal handler or timer callback" on a
foreign thread/stack) — the prior design named that shape without this
constraint and never revisited it; this revision does.

**Decision, stated explicitly rather than left implicit:** the watchdog's
job in this tranche is *detection and flagging from outside*, not
*forced pre-emption of the blocked call itself*. It guarantees three
things unconditionally:

- The deadline is tracked and detected by a thread the Lua VM does not
  control and cannot delay (satisfies "enforced from outside the Lua
  state" for the *detection* half of the requirement).
- Once a `lua_CFunction` **returns** control to the Lua VM (i.e. the
  blocking call completes, however late), the very next opportunity the
  host has to observe the deadline — the count hook's next tick, or the
  host-side wrapper around the specific blocking call — raises the
  timeout error immediately, without waiting for the script's own
  instruction budget or any further cooperation.
- For the one host function currently capable of blocking
  (`platform.call_service` / `call_service.zig`), the watchdog's deadline
  is additionally threaded into that call's own execution so the call
  itself can observe the deadline had passed and refuses to return a
  successful result — see §2.5.4.

What this tranche does **not** claim: that a `lua_CFunction` body already
blocked inside a foreign, uninterruptible syscall (a real blocking socket
read, once LUA-12 lands) will be forcibly killed mid-syscall at the exact
deadline. §2.5.4 explains why `call_service.zig` as it exists *today* has
no such syscall to interrupt, and §11 records the remaining gap as an
explicit, flagged open question rather than a silent one.

#### 2.5.3 Watchdog structure: start, deadline, stop

```
// src/lua/timeout.zig (extended) -- illustrative signatures only

pub const WatchdogState = struct {
    deadline_ns: std.atomic.Value(i64),   // set once at init, read by both threads
    fired: std.atomic.Value(bool),        // written ONLY by the watchdog thread
    stop_requested: std.atomic.Value(bool), // written ONLY by the owning thread

    pub fn init(timeout_seconds: u32) WatchdogState;
    pub fn hasFired(self: *const WatchdogState) bool; // .acquire load of `fired`
};

// Runs on its own std.Thread. Touches ONLY the atomics above -- never L,
// never RunLimiter/MemoryLimiter. Polls every 10ms; on deadline reached,
// sets `fired` and returns (detection is one-shot). Exits early if
// `stop_requested` is observed first.
fn watchdogLoop(state: *WatchdogState) void;

pub const WatchdogHandle = struct {
    state: *WatchdogState,
    thread: std.Thread,

    // Caller owns `state` (stack-allocated, must outlive this handle AND
    // the lua_State -- INV-1/INV-5 shape). Spawn failure surfaces to the
    // caller; see the "Spawn failure" paragraph below for handling.
    pub fn start(state: *WatchdogState) std.Thread.SpawnError!WatchdogHandle;

    // Sets stop_requested then joins. MUST be called exactly once on every
    // exit path from executeSource (defer-guaranteed, INV-5) -- every run
    // that reaches start() also reaches stop(), or the thread leaks.
    pub fn stop(self: *WatchdogHandle) void;
};
```

`WatchdogState.fired` is the only field the watchdog thread ever writes,
and `stop_requested` is the only field the owning thread ever writes —
each thread only *reads* what the other writes, which is what removes the
need for a lock (§2.5.5 makes this precise). `hasFired`/`init` are the
only two entry points anything outside `timeout.zig` calls directly;
`watchdogLoop` is private, reached only via `WatchdogHandle.start`.

**Started:** in `executeSource`, immediately after `limiter_storage` and
`mem_limiter_storage` are constructed and before `createSandboxedState` is
called — i.e. before any Lua bytecode can possibly run, so there is no
window where a script executes with no deadline tracked at all.
**Deadline:** `limits.timeout_seconds`, the same resolved value
`TimeoutContext.init` already receives (§3.3) — one wall-clock budget, one
source of truth, read into two independent tracking mechanisms (the
in-VM `TimeoutContext` the count hook already checks, and the
out-of-VM `WatchdogState` this section adds). **Stopped:** via
`defer handle.stop()` immediately after `start()` succeeds, so every exit
path out of `executeSource` — success, script error, capability denial,
`createSandboxedState` failure — joins the thread before the function
returns. No thread outlives the call that spawned it.

**Spawn failure.** `std.Thread.spawn` can fail (`SpawnError`, e.g.
resource-limited host). This is a genuine new fallible step this design
introduces (unlike §3.4's allocation-free limiter `init` calls). Decision:
treat it the same as any other `createSandboxedState`-adjacent setup
failure — `executeSource` returns a `ScriptResult{ .success = false,
.error_message = "could not start execution watchdog" }` rather than
either (a) silently running without a watchdog (which would quietly
regress §2.5.2's "enforced from outside" guarantee with no signal to the
caller) or (b) propagating a raw `SpawnError` past `ScriptResult`'s
existing all-failures-are-a-message-not-an-error-union convention used
everywhere else in this function. This is additive: no existing error
path changes shape, one new early-return is added right after the
existing `createSandboxedState` failure branch.

#### 2.5.4 Interaction with `call_service.zig` specifically

The watchdog thread itself never touches `L` (2.5.2, 2.5.3). For the
blocking-host-call acceptance criterion to mean something operationally
(not just "a flag gets set somewhere while the script is still stuck"),
the one host function that can currently take non-trivial time —
`platformCallService` — is given a way to observe `WatchdogState.hasFired()`
on its **own** thread (the Lua-owning thread; this is a same-thread read
of atomics written by a different thread, which is exactly what the
`.acquire`/`.release` ordering above exists for — safe, unlike calling
`lua_*` cross-thread).

`ExecutionContext` gains an optional pointer to the active
`WatchdogState` (mirroring how `host_context.zig` threads
`ExecutionContext` itself through the registry — see the minimal,
additive interface note at the end of this subsection):

```
// src/lua/host_api/call_service.zig (extended)

fn platformCallService(L: *bindings.LuaState) callconv(.c) c_int {
    const svc_id = host_context.checkString(L, FN_NAME, 1);
    // ... existing capability check, unchanged ...

    if (activeWatchdogFired(L)) {
        host_context.raiseMessage(L, "platform.call_service: wall-clock timeout exceeded");
    }

    // ... existing simulation-path / non-simulation-path body, unchanged ...

    // Re-check immediately before returning a result: a call that took long
    // enough to cross the deadline while it ran must not report success.
    if (activeWatchdogFired(L)) {
        host_context.raiseMessage(L, "platform.call_service: wall-clock timeout exceeded");
    }
    // ... push results, return 2 ...
}

/// host_context.zig helper (new, small): reads context.active_watchdog off
/// the SAME ExecutionContext contextFromState already returns, then calls
/// hasFired() on it. No new registry key -- the watchdog rides the existing
/// "bpm.execution_context" channel as one more field on the struct already
/// installed there, same as every other ExecutionContext field host
/// functions already read (e.g. .capabilities). Returns false (not an
/// error) if contextFromState itself returns null or active_watchdog is
/// null -- this is a liveness check, not a security gate, so it fails open
/// on "no context installed" the same way CAP-2's fail-closed rule does NOT
/// apply here (that rule is specific to capability denial, §2.2's note on
/// limiterFromState's orelse makes the same distinction).
fn activeWatchdogFired(L: *bindings.LuaState) bool {
    const context = host_context.contextFromState(L) orelse return false;
    const wd = context.active_watchdog orelse return false;
    return wd.hasFired();
}
```

`activeWatchdogFired` reuses the existing `host_context.contextFromState`
read-back — no new `LUA_REGISTRYINDEX` key is introduced. The watchdog
pointer rides the same `"bpm.execution_context"` channel `host_context.zig`
already installs and every host function already reads from for
`.capabilities`; it is simply one more field on the struct already there
(§2.5.4 interface note below), not a fourth parallel registry lookup.

**Honest scope limit, stated plainly:** this pre-check/post-check pattern
catches a slow call *before* it starts and *after* it finishes — it
demonstrably satisfies TC-LUA-10-03 for `call_service.zig` as the
function is implemented **today**, because today's implementation (per
`call_service.zig`'s own header comment, "does NOT implement it... still
returns a hardcoded `{}`... that is LUA-12") has no real blocking I/O
inside it: the simulation path calls
`simulation_interceptor.executeMockedServiceCall`, an in-process,
non-blocking lookup, and the non-simulation path is a hardcoded
same-tick return. There is currently no code inside `platformCallService`
that can itself block for seconds, so there is nothing mid-call for the
watchdog to interrupt — the pre/post check brackets the entire call
because the entire call is already short. **This will stop being true
the moment LUA-12 gives `call_service` a real outbound HTTP client call**
(a genuine blocking or async-with-blocking-wait network round trip);
at that point a deadline check only before and after the call can still
observe a call that ran past its budget (so the script still gets a
timeout error and never sees a stale successful result — the correctness
property holds), but it cannot make that call *return early* — the host
process will still wait out however long the real socket operation takes
before the post-check ever runs. Making a real network call itself
interruptible (passing a deadline into the HTTP client, using a
cancellable request) is host_api/HTTP-client work, not Lua-limiter-wiring
work, and is explicitly named as a follow-up in §11.

**Minimal, additive interface change this requires (flagged per the
handoff's instruction to call these out explicitly):** `ExecutionContext`
(`executor.zig`) gains one new optional field,
`active_watchdog: ?*const timeout_ctx.WatchdogState = null`, defaulted so
no existing construction site (tests, other callers) breaks. It is set
by `executeSource` right after the watchdog starts and before
`createSandboxedState` installs the context, so `installContext`'s
existing invariants (CTX-1..CTX-4) apply to it unchanged — same pointer,
same lifetime, same const-through-the-call-path guarantee. This is the
only field added to `ExecutionContext`; nothing in `RunLimiter` (§1.2) or
`RunLimits` (§3.1) changes shape.

#### 2.5.5 Interaction with the count hook — no race, no double-raise

Both mechanisms read from the same wall-clock source
(`time_source.currentNanoTimestamp()`) but write to disjoint state: the
count hook's `TimeoutContext.checkTimeout()` (§2.2) mutates
`limiter.timeout.?.timed_out`, a field only the Lua-owning thread ever
writes; the watchdog thread only ever writes `WatchdogState.fired`, a
field the Lua-owning thread only ever reads. Neither thread writes what
the other writes, so there is no data race requiring a lock, and no
scenario where both raise: whichever of the two the *Lua-owning thread*
happens to observe first — the hook's own `checkTimeout()` failing on its
next tick, or a `platform.call_service` call noticing
`wd.hasFired()` — raises via `lua_error` and unwinds `lua_pcall`
immediately; `lua_error`'s `longjmp` means execution never reaches the
other check afterward. This mirrors §2.3's existing "whichever trip
condition is reached first wins" shape for LUA-08 vs LUA-10-tight-loop,
extended to a third condition. Both messages remain distinguishable text
(§2.3); the watchdog's messages use the same `"...timeout exceeded"`
substring so a test asserting on timeout text does not need to know which
of the two mechanisms actually fired.

**Ordering guarantee this gives LUA-10 overall:** for a tight Lua loop,
the count hook fires first (the watchdog thread would also eventually set
`fired`, but nothing ever reads it because the hook already raised and
unwound the state before any host function get a chance to check it —
harmless, not a race, since the watchdog thread's write and the
(now-unwound, closing) Lua state's non-reads never touch shared Lua data).
For a blocking `call_service` call, the count hook cannot fire (2.5.1) so
the watchdog's `fired` flag is what `call_service.zig`'s own check
observes — this is the path that makes TC-LUA-10-03 pass.

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
3. install the execution context — unchanged call site
   (`host_context.installContext`), but the `*const ExecutionContext` it
   installs now carries `active_watchdog` (§2.5.4) as one more field,
   already set by `executeSource` before this call (§3.3) — no separate
   watchdog install step is added here, because the watchdog rides the
   same registry channel the context already uses
4. install the run limiter + combined hook (new step, via
   `instruction_limiter.installLimiter`)
5. register the `platform.*` table (unchanged)

Installing the limiter after the context and before `registerAll` keeps
the existing invariant that no closure is reachable from Lua before every
piece of state it might depend on already exists. The watchdog thread
itself (§2.5.3) is started even earlier — in `executeSource`, before
`createSandboxedState` is called at all (step 0, outside this function) —
because a script that fails during state construction still needs its
watchdog thread stopped and joined by `executeSource`'s `defer`, not
leaked.

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
    var limiter_storage = instruction_limiter.RunLimiter{ ... };  // unchanged (§1.2/§2.2)
    var mem_limiter_storage = memory_limiter.MemoryLimiter.init(
        context.allocator, limits.max_memory_bytes);

    // NEW (§2.5.3): started before any Lua bytecode can run; stopped via
    // `defer` on every exit path. Spawn failure returns early as a
    // ScriptResult (see §2.5.3 "Spawn failure" for the exact shape).
    var watchdog_state = timeout_ctx.WatchdogState.init(limits.timeout_seconds);
    var watchdog_handle = timeout_ctx.WatchdogHandle.start(&watchdog_state) catch {
        return ScriptResult{ .success = false, .value = null,
            .error_message = try context.allocator.dupe(u8, "could not start execution watchdog"),
            .manifest_hash = manifest_hash };
    };
    defer watchdog_handle.stop();

    // NEW (§2.5.4): a local copy carries the watchdog pointer onward: the
    // caller's `context.*` is never mutated (CTX-1..CTX-4 preserved).
    var context_with_watchdog = context.*;
    context_with_watchdog.active_watchdog = &watchdog_state;

    const L = createSandboxedState(
        &context_with_watchdog, limits, &limiter_storage, &mem_limiter_storage,
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
`limits` itself. Both callers reach the watchdog wiring identically,
since it lives inside the shared `executeSource` body, not in either
public entry point — LUA-10 protection is not something a caller can
accidentally skip by choosing one entry point over the other, same
guarantee §3.2 already establishes for LUA-08/LUA-09.

### 3.4 Allocation-failure-during-limiter-init note

`instruction_limiter.InstructionLimiter.init` and
`memory_limiter.MemoryLimiter.init` do not allocate (confirmed by reading
both files — `init` only assigns fields), so neither introduces a new
fallible step between entering `executeSource` and calling
`createSandboxedState`. No new error variant is required for either.

`timeout_ctx.WatchdogState.init` is equally non-allocating (plain field
assignment, same shape). `timeout_ctx.WatchdogHandle.start` (§2.5.3) is
the one genuinely new fallible step this design adds before
`createSandboxedState` runs — `std.Thread.spawn` can fail — and its
failure handling is specified in full in §2.5.3 (a `ScriptResult` early
return, not a new `LuaError` variant, keeping §7's error taxonomy
additive rather than expanded).

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

**Coverage note:** this test exercises only the tight-loop sub-case (the
count hook's own timeout check, §2.2–§2.4). It does NOT exercise
`tests/specs/LUA-10.md`'s TC-LUA-10-03 or TC-LUA-10-04 — those require the
watchdog mechanism added in §2.5, and are covered by 5.4 and 5.5 below,
which are new in this revision.

### 5.4 TC-LUA-10-02 — blocking host call is still terminable within timeout (maps to spec TC-LUA-10-03)

**Script body:**
```lua
local ok, err = pcall(function()
    return platform.call_service("slow_svc", "POST", "/slow", {}, "")
end)
return ok, err
```

**Setup:** a test-only seam is required because, per §2.5.4's honest scope
note, `call_service.zig` as it stands today has no code path that blocks
for a controllable duration — the simulation path
(`simulation_interceptor.executeMockedServiceCall`) returns in-process,
effectively instantly. To make this test genuinely exercise "blocked
inside a host function call" rather than "returned immediately, so the
pre-check trivially passed," the test registers a simulation handler for
`"slow_svc"` (via the existing simulation harness
`simulation_interceptor`/`simulation_runtime` test seams already used by
other `call_service` tests) that sleeps
(`std.Thread.sleep`) for a duration longer than the configured timeout
(e.g. handler sleeps 3 seconds, `RunLimits.timeout_seconds = 1`) before
returning its mocked response — this simulates "a host function call that
takes real wall-clock time" using a mechanism already present in the
codebase for test determinism, without requiring LUA-12's real HTTP
client to exist. `RunLimits.max_instructions` is set high
(`Limits.MAX_INSTRUCTIONS`) so the instruction path cannot be the cause.

**Assertions:**
- The call returns within a bounded window measured from the *test's*
  wall clock (e.g. under 2 seconds — inside the 3-second handler sleep,
  proving the script did not simply wait out the full handler duration
  and get caught by the ordinary post-return path).
- `result.success == false`.
- `result.error_message` contains the timeout message text
  (`"wall-clock timeout exceeded"`, per §2.5.4's `platformCallService`
  message), not an unrelated Lua runtime error.
- **Mutation check:** with §2.5.4's `activeWatchdogFired` checks removed
  from `platformCallService` (reverting it to today's unwatched body),
  this exact test must instead wait out the full handler sleep (~3
  seconds) and then observe whatever the mocked response's face-value
  result is (`ok == true`, no timeout error) — a materially different,
  easily distinguished outcome (task actually completing vs. being cut
  off), proving the test exercises the watchdog's effect on
  `call_service.zig` specifically, not a coincidental instruction-count
  or scheduling artifact.

**Honest limit inherited from §2.5.4, restated for this test:** this test
proves the watchdog causes the *script* to receive a timeout error and
never see a stale success value for a slow call — it does NOT prove (and
does not claim to prove) that the underlying simulated "slow" operation
itself was killed at the 1-second mark; the test's mock handler is free
to keep sleeping in the background after `platformCallService` raises.
That is consistent with §2.5.2's stated scope (detection-and-flagging,
not forced pre-emption of the blocked primitive) and is why this test
asserts on the *script's* return path, not on the mock handler's own
lifetime.

### 5.5 TC-LUA-10-03 — timeout enforced from outside the Lua state (maps to spec TC-LUA-10-04)

**Script body:** `"while true do end"` (same runaway tight loop as 5.3).

**Setup:** simulate "the Lua-side hook is disabled/delayed" — per the
pre-existing spec's own framing ("assumes Lua hook callback can be
disabled or delayed") — by constructing the test to install the watchdog
(§2.5.3) but deliberately calling `instruction_limiter.installLimiter`
with a `RunLimiter.timeout` of `null` (i.e. only LUA-08's instruction
check is wired into the hook, exactly like the pre-LUA-10-wiring state
this design's own mutation checks elsewhere revert to), while the
watchdog thread is still started and `context.active_watchdog` is still
installed as normal. `RunLimits.max_instructions` is set to the maximum
(`Limits.MAX_INSTRUCTIONS`) so the count hook's instruction path cannot
plausibly fire within the test's wall-clock budget. This isolates: with
the in-VM hook mechanism fully neutralized for timeout purposes, does
anything still stop the script?

**Assertions:**
- The call still returns within a bounded window (e.g. under 5 seconds),
  even though the count hook — the only in-VM mechanism — has been
  configured to never observe the timeout.
- `result.success == false`, `result.error_message` contains the timeout
  message text.
- **This is only possible because of a mechanism this test spec's own
  premise ("disabled or delayed hook") does not disable: `WatchdogState`
  is a plain Zig struct polled by an independent `std.Thread`, with no
  dependency on `lua_sethook` ever firing.** The test therefore asserts
  directly on `watchdog_state.hasFired() == true` after the call returns,
  as the specific, named proof that detection happened outside the Lua
  VM's own instruction-dispatch loop.
- **Mutation check:** with the watchdog thread removed entirely (i.e.
  `WatchdogHandle.start` never called, `context.active_watchdog` stays
  `null`) IN ADDITION to the hook's timeout branch already being disabled
  by this test's setup, this exact test must run for the full
  10,000,000-instruction budget (many seconds) rather than stopping at
  ~1 second — proving the watchdog thread specifically, not any
  leftover in-VM mechanism, is what terminates the script in this
  scenario.

**Honest limit, stated explicitly:** "from outside the Lua state" is
satisfied here in the sense the requirement's own acceptance criterion
names — the *detecting* mechanism runs on a thread with no dependency on
the Lua VM's cooperation, dispatch loop, or hook table. It is not a claim
that the watchdog can reach into an already-running, uninterruptible
tight Lua loop and forcibly halt bytecode execution mid-instruction from
outside — no primitive in `luajit_bindings.zig` makes that possible
without either the count hook (in-VM, LuaJIT-cooperative) or terminating
the whole process/thread (out of scope — killing the host thread would
tear down `executeSource`'s own caller, not just the script). What the
watchdog adds beyond the count hook is coverage for the cases the count
hook structurally cannot reach at all (§2.5.1) — the blocking-host-call
case (5.4) — plus an independent, cooperation-free detection path for
the tight-loop case as a defense-in-depth measure, which is what 5.5
demonstrates.

---

## 6. Public interface (summary)

**Unchanged from the approved LUA-08/LUA-09 sections** (§1, §3, §4):

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
```

**New in this revision** (§2.5, watchdog):

```
// src/lua/timeout.zig (extended — §2.5.3)
pub const WatchdogState = struct {
    deadline_ns: std.atomic.Value(i64),
    fired: std.atomic.Value(bool),
    stop_requested: std.atomic.Value(bool),

    pub fn init(timeout_seconds: u32) WatchdogState;
    pub fn hasFired(self: *const WatchdogState) bool;
};
pub const WatchdogHandle = struct {
    state: *WatchdogState,
    thread: std.Thread,

    pub fn start(state: *WatchdogState) std.Thread.SpawnError!WatchdogHandle;
    pub fn stop(self: *WatchdogHandle) void;
};

// src/lua/host_context.zig (extended — §2.5.4)
fn activeWatchdogFired(L: *bindings.LuaState) bool; // internal, not pub

// src/lua/executor.zig — ExecutionContext gains ONE new, defaulted field:
active_watchdog: ?*const timeout_ctx.WatchdogState = null,
```

`createSandboxedState`'s signature (`context`, `limits`, `limiter_storage`,
`memory_limiter_storage` → `!*bindings.LuaState`) is unchanged by this
revision — the watchdog pointer travels inside `context.active_watchdog`,
not as a new parameter. `executeScript` / `executeScriptWithManifest`
signatures stay UNCHANGED — watchdog start/stop is entirely internal to
`executeSource`, not exposed to existing callers.

---

## 7. Error taxonomy

No new entries in `errors.LuaError` are required for the instruction,
memory, or in-VM timeout paths. The watchdog (§2.5) adds exactly one new
failure surface, handled the same additive way. All failure modes surface
through existing, unchanged paths:

| Condition | Surfaces as | Existing mechanism |
|---|---|---|
| Instruction limit exceeded | `ScriptResult{ .success = false, .error_message = "...instruction limit exceeded" }` | `lua_pcall` non-zero status → existing `executeSource` error-message extraction (unchanged code path) |
| Wall-clock timeout exceeded (tight-loop, count-hook path) | `ScriptResult{ .success = false, .error_message = "...wall-clock timeout exceeded" }` | same `lua_pcall` non-zero status path |
| Wall-clock timeout exceeded (blocking host call, watchdog path — NEW §2.5.4) | `ScriptResult{ .success = false, .error_message = "platform.call_service: wall-clock timeout exceeded" }` | `activeWatchdogFired` → `host_context.raiseMessage` → same `lua_pcall` non-zero status path — no new raise mechanism, reuses the existing `raiseMessage` helper every other host function denial already uses |
| Memory limit exceeded | `ScriptResult{ .success = false, .error_message = "<LuaJIT's own out-of-memory string>" }` | `lua_Alloc` returns `null` → LuaJIT raises its own OOM error internally → same `lua_pcall` non-zero status path |
| `lua_newstate` fails outright (e.g. cap too small for bootstrap) | `errors.LuaError.LuaAllocFailed` | existing `createState`/`createSandboxedState` error path (unchanged variant, no new error added) |
| Watchdog thread fails to start (NEW §2.5.3) | `ScriptResult{ .success = false, .error_message = "could not start execution watchdog" }` | new early-return in `executeSource`, positioned immediately after the existing `createSandboxedState` failure branch — same `ScriptResult`-shaped failure convention, not a new `LuaError` variant or a propagated `std.Thread.SpawnError` |

All failure modes are absorbed by `executeSource`'s existing
`lua_pcall`-failure branch (`call_status != 0`), `createSandboxedState`'s
existing `catch |err|` branch, or the one new `ScriptResult`-shaped early
return for watchdog spawn failure — no new `LuaError` variant, no new
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

**One narrow, flagged exception, new in this revision:** §2.5.4's watchdog
mechanism adds two `activeWatchdogFired(L)` checks (pre-call and
pre-return) inside `src/lua/host_api/call_service.zig`'s
`platformCallService` — the one host function this tranche's LUA-10
acceptance criteria explicitly require to respect the timeout while
blocked. This is the only touch to `host_api/` this design makes, it does
NOT change `call_service.zig`'s existing behavior, arguments, return
shape, capability gate, or simulation-vs-non-simulation branching (§2.5.4
"Honest scope limit") — it only adds two early-raise checks around the
existing body. It is not LUA-12 work (implementing the real service call)
and does not touch `service_catalog.zig`. If implementation discovers
that any of LUA-11/12/13/15/16 must change beyond this one narrow,
already-specified touch to make LUA-08/09/10 work, that is a signal the
scope boundary was drawn wrong and must be escalated to ORCH before
proceeding, not silently absorbed into this branch.

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
- **INV-5** (NEW, §2.5.3) Every `WatchdogHandle.start` that succeeds is
  matched by exactly one `WatchdogHandle.stop` on every exit path from
  `executeSource` (success, script error, capability denial,
  `createSandboxedState` failure) — guaranteed structurally by `defer
  watchdog_handle.stop()` placed immediately after the successful
  `start()` call, the same `defer`-guarantees-cleanup shape `bindings.lua_close(L)`
  already uses one line below it. No code path returns from
  `executeSource` with a live, un-joined watchdog thread.
- **INV-6** (NEW, §2.5.2/§2.5.3) The watchdog thread never calls any
  `lua_*` function and never dereferences `L`, `RunLimiter`, or
  `MemoryLimiter` — its only shared state is `WatchdogState`'s three
  atomics. This is what makes it safe to run concurrently with the
  Lua-owning thread without a lock: the two threads have disjoint write
  sets (§2.5.5) and the Lua-owning thread never blocks waiting on the
  watchdog thread (it only ever reads `fired`, non-blocking).
- **INV-7** (NEW, §2.5.5) At most one of {instruction-limit raise,
  in-VM-timeout raise, watchdog-detected raise} actually unwinds a given
  `lua_pcall` — because `lua_error`'s `longjmp` makes every raise
  terminal for that call, no later check in the same execution can ever
  also raise. This is a consequence of §2.3's existing trip-condition
  design, not a new mechanism, extended to the watchdog's raise points in
  `call_service.zig`.

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
  unchanged; the watchdog (§2.5.3) reuses
  `time_source.currentNanoTimestamp()` as its clock source, same as
  `TimeoutContext` — one clock source for both mechanisms.
- `std.Thread` (NEW dependency for this revision, §2.5) —
  `std.Thread.spawn`, `std.Thread.Thread.join`, `std.Thread.sleep`.
  **Verified distinct from the constraint `memory_limiter.zig`'s header
  comment documents:** that comment rules out `std.Thread.Mutex`
  specifically (removed from the Zig 0.16 standard library, per
  `memory_limiter.zig` lines 8-13/30-42 — a struct/lock API, not a
  threading API). `std.Thread.spawn`/`.join`/`.sleep` are a different,
  still-present part of `std.Thread` — the watchdog design does not use
  `std.Thread.Mutex` or any other lock, relying instead on
  `std.atomic.Value` exactly the way `memory_limiter.zig` itself already
  does for `current_memory_bytes`/`peak_memory_bytes` (same file, same
  precedent, same reasoning: a `callconv(.c)` boundary and now a
  cross-thread boundary are both better served by atomics than by a lock
  this Zig version does not offer in the shape this code needs). This
  should be confirmed against the actual `zig version` this repo builds
  with before implementation (the comment names Zig 0.16 as current);
  if `std.Thread.spawn`/`.join`/`.sleep` have also moved or changed
  signature, that is the same class of implementation-detail correction
  §11 already permits without rework.

## 11. Open questions

**Not "None" this time (CDV-0169-3's finding was correct — the prior
version of this section claimed completeness that did not exist).**

1. **True pre-emption of a blocking foreign call is not achieved by this
   design, and is not achievable without host_api/HTTP-client
   restructuring beyond this tranche.** §2.5.4 gives the full technical
   reasoning: the watchdog can guarantee a script never *returns* a
   result past its deadline (detection-and-flagging, checked before and
   after each blocking-capable host call), but it cannot forcibly abort
   an in-flight blocking syscall the host process is already waiting on
   inside a `lua_CFunction` — no primitive in `luajit_bindings.zig`
   supports cross-thread interruption of `L` (§2.5.2), and there is no
   general cross-thread I/O cancellation primitive wired into
   `call_service.zig` today. **This does not currently cost LUA-10
   anything observable**, because `call_service.zig`'s own implementation
   in this tranche has no blocking I/O to pre-empt (§2.5.4's "honest
   scope limit" — it is a same-tick simulation/hardcoded-return path).
   The gap becomes real the moment LUA-12 gives `call_service` a genuine
   outbound HTTP client. **Recommendation: escalate to ORCH now, not at
   LUA-12 implementation time** — file a follow-up issue scoped to "make
   the LUA-12 HTTP client itself deadline-aware / cancellable" (e.g. pass
   a deadline into the HTTP client's request call, use a client library
   with request cancellation, or bound the client's own connect/read
   timeouts to the remaining watchdog budget so the call unblocks on its
   own before the process would otherwise wait out a much longer default
   socket timeout) so LUA-12's design work inherits this constraint
   instead of rediscovering it.
2. **The watchdog's 10ms poll granularity (`POLL_INTERVAL_NS`, §2.5.3) is
   a deliberate, undiscussed-until-now constant.** It bounds worst-case
   detection latency at ~10ms past the true deadline, which is negligible
   against `Limits.MIN_TIMEOUT_SECONDS = 1` (1000ms) but is a real,
   named number a reviewer should be able to see rather than infer. Not
   blocking — flagged so it is visible rather than assumed.
3. **Test 5.4's simulation-handler-sleep seam** (a test-only mock handler
   that calls `std.Thread.sleep` to fake a slow host call) is the
   mechanism this design proposes for exercising the blocking-call path
   before LUA-12 exists. If TEST-DESIGNER finds the existing
   `simulation_interceptor`/`simulation_runtime` test harness cannot
   register a handler with an artificial delay this way, that is a small
   test-infra gap in the simulation harness, not a gap in this design's
   production wiring — flagged so it does not silently become a reason
   to weaken 5.4's assertions instead of fixing the harness seam.

If BACKEND-DEV finds a `luajit_bindings.zig` or `std.Thread` signature
that does not match what is sketched here (e.g. a different
`lua_sethook` argument order, or a renamed `std.Thread` method), that is
an implementation-detail correction within this design's intent, not a
design gap requiring rework. Item 1 above, by contrast, is a genuine
scope boundary and is not implementation-detail — it requires ORCH
sign-off on the recommendation, not a silent BACKEND-DEV judgment call.
