# Module: LUA-16 stack-trace capture via lua_pcall message handler (errfunc)

**Issue:** ISS-0628 / GH-595 (MINOR — does not block LUA-16's release)
**Requirements in scope:** LUA-16 (`ScriptErrorPayload.stack_trace`)
**Out of scope:** LUA-15 (explicit failure — confirmed untouched, §6), LUA-08/09/10
(limiter/watchdog mechanisms themselves — unchanged; only their *observable output*
gains a stack trace, §5)

## Module purpose

`ScriptErrorPayload.stack_trace` (`src/lua/events.zig`) is always empty for real
LuaJIT runtime errors today. `src/lua/executor.zig`'s `lua_pcall(L, 0, 1, 0)` call
(currently line ~543) passes `errfunc = 0` — no message handler. Per the Lua 5.1 /
LuaJIT 2.1 `lua_pcall` contract, a message handler (if installed) is invoked *at the
moment the error is raised*, while the erroring call frames are still live on the
stack; its return value becomes the error object `lua_pcall` hands back to the
caller. With `errfunc = 0`, none of that happens — `lua_pcall` simply unwinds to the
protected boundary, and by the time `captureStackTrace` (executor.zig ~L701) runs
*after* `lua_pcall` has already returned, `lua_getstack(level=0)` finds nothing: the
frames are gone.

This design installs a small internal `lua_CFunction` closure as the message
handler so `captureStackTrace`'s existing walk runs *while the frames are still
live*, and threads the resulting trace back to `ScriptErrorPayload` without
disturbing the existing `error_message` extraction path.

**Explicit non-goal, corrected against GH-595's own filed text:** this design does
NOT install `debug.traceback` and does NOT open the `debug` library, even
partially. `src/lua/stdlib.zig`'s `loadSafeStdlib` documents `debug` as
permanently unopened (invariant SBX-1: "Never opened: io, os, package, debug, jit,
ffi, bit, coroutine") — `debug.traceback` is not a reachable global inside the
sandbox and `lua_getglobal(L, "debug")` would push `nil`. `tests/integration/iss0625_lua_12_15_16_test.zig`'s
existing comment (~L561-566) is itself wrong on this point and is corrected in §4.
The handler this design specifies is a plain host-side `lua_CFunction`, installed
via the already-bound `lua_pushcclosure` (`luajit_bindings.zig:134`) — it requires
no stdlib exposure change and no new binding.

---

## 1. The message-handler closure

### 1.1 Shape: fixed-buffer, no allocator inside the callback

A `lua_CFunction` has signature `fn(L: *LuaState) callconv(.c) c_int` — no
allocator parameter, no way to receive one as an argument, and it runs on the
`.c` calling convention where an escaping Zig error union or an allocation that
survives a subsequent `longjmp` (if some *later*, unrelated error occurs while
this handler's own allocation is still live) is a leak risk. `captureStackTrace`
as it exists today (`executor.zig` ~L701) takes `(L, allocator) ![]u8` and builds
its output in a heap-backed `std.ArrayList(u8)` — that signature cannot be used
as the handler body directly; it must be adapted, not rewritten.

**Decision: the handler is a NEW, small function, `errfuncHandler`, that
reimplements the same `lua_getstack`/`lua_getinfo` walk `captureStackTrace`
already performs, but writes into a fixed-size stack buffer instead of an
`ArrayList`, and never calls `context.allocator`.**

This mirrors the two existing precedents named in the handoff:
`instruction_limiter.zig`'s `raiseLimit` and `host_context.zig`'s `raiseMessage`
both format diagnostic text into a fixed stack buffer specifically because they
run inside a path that is about to raise/longjmp and must not leak or depend on
allocator availability at that point. `errfuncHandler` runs under the same
constraint — it executes *during* `lua_pcall`'s own error unwind, before control
returns to any Zig frame that owns an allocator reference in scope.

**Reuse, not duplication, of the walk logic.** `captureStackTrace`'s per-frame
walk (`lua_getstack(L, level, &ar)` / `lua_getinfo(L, "Sl", &ar)`, formatting
`"  at <source>:<line> in '<name>'\n"` per frame) is factored into a shared,
allocator-free primitive:

```
fn writeStackFrames(L: *bindings.LuaState, buf: []u8) usize {
    var writer = FixedWriter.init(buf);
    var level: c_int = 0;
    var ar: bindings.lua_Debug = .{ ... };
    while (bindings.lua_getstack(L, level, &ar) != 0) : (level += 1) {
        if (bindings.lua_getinfo(L, "Sl", &ar) == 0) continue;
        writer.writeFrame(ar);   // same "  at src:line in 'name'\n" shape
    }
    return writer.len;
}
```

Both `errfuncHandler` (new, buffer-based, called live) and a thin
allocator-based `captureStackTrace` (existing signature, KEPT for
TC-ISS-0625-LUA-16-02, §3) call `writeStackFrames`. `captureStackTrace`'s body
becomes: allocate a scratch buffer (or write directly into the `ArrayList`'s
backing via `writer.writeFrame` reused against an allocator-backed writer type;
either sub-choice is an implementation detail BACKEND-DEV may pick — the
requirement this design fixes is that the frame-formatting logic exists in
exactly one place, not two independently-maintained copies). `FixedWriter` is a
small, private, non-allocating append helper identical in spirit to
`host_context.zig`'s `Writer` (append-only over a caller-owned buffer, silent
truncation past capacity — a truncated *trace* is an acceptable degradation, the
same judgement call `host_context.raiseMessage`'s `Writer` already makes for
diagnostic text).

**Buffer size.** `STACK_TRACE_BUFFER_BYTES = 4096`. Rationale: `captureStackTrace`
already has no depth cap today (unbounded `ArrayList`), so 4096 is not a
regression on any currently-passing test — the deepest chain in the existing
test suite (TC-ISS-0625-LUA-16-int-01's `f3 → f2 → f1 → main`, 4 frames) uses a
small fraction of that. A pathologically deep recursive script truncates its
trace rather than growing the buffer without bound inside a `callconv(.c)`
callback that must not allocate — an intentional, documented trade-off, not an
oversight.

**Why not go through the registry channel for the allocator instead.** The
handoff raises this as an open question: could the handler reach
`context.allocator` via `host_context.contextFromState(L)`, the same channel
every other host function already uses? Technically yes — `contextFromState`
works from any `lua_CFunction`, including this one, since it is installed the
same way any other closure is. **Rejected anyway**, because unlike an ordinary
host function (`platform.call_service`, etc.) which runs in a normal call frame
with a clear allocation/deallocation boundary, the message handler runs *during*
`lua_pcall`'s unwind — if the handler's own `allocator.dupe`/`ArrayList.append`
call itself failed (`OutOfMemory`) or if a subsequent stack operation inside the
handler triggered another Lua error before the handler returns cleanly, an
allocation made here has no defined owner to free it: the handler cannot
`errdefer` across a `callconv(.c)` boundary the way a normal Zig function can,
and `ScriptResult`'s existing convention (every failure becomes a message, never
a propagated error union, per `iss0169-lua08-09-10-limiter-wiring.md` §2.5.3's
same convention for `WatchdogHandle.start`) has no slot for "the stack-trace
capture itself ran out of memory while capturing a stack trace." A fixed buffer
sidesteps the question entirely: it cannot fail to allocate because it never
allocates. This is the same reasoning `raiseMessage`/`raiseLimit` already
applied to error *messages*; extending it to the *trace* is the conservative,
consistent choice, not a new pattern.

---

## 2. Push ordering and stack index

### 2.1 Current stack shape at the call site

At `executor.zig` ~L512-543 today: `createSandboxedState` returns `L` with an
empty stack (stdlib open, context/limiter installed, nothing pushed for the
script itself yet). `luaL_loadbuffer` then pushes exactly one value — the
compiled chunk (a Lua function) — onto that otherwise-empty stack, at absolute
index 1. `lua_pcall(L, 0, 1, 0)` is called immediately after, with the chunk
still at index 1 (it is the "function to be called", consumed by the call).

### 2.2 Required new ordering

The Lua reference manual's message-handler contract is explicit: the handler
must be pushed **before** the function-to-be-called and its arguments, and its
**absolute** stack index (not a relative/negative one) is passed as `lua_pcall`'s
4th argument — absolute, because by the time `lua_pcall` is invoked, the chunk
(and, in the general case, its arguments) have already been pushed on top of the
handler, so a negative index computed before those pushes would silently point
at the wrong slot; using `lua_gettop(L)` right after pushing the handler and
before pushing anything else captures the correct absolute position regardless
of what is pushed afterward.

Exact sequence, replacing the current `luaL_loadbuffer` → `lua_pcall(L, 0, 1, 0)`
pair:

1. `bindings.lua_pushcclosure(L, errfuncHandler, 0)` — push the handler as a
   zero-upvalue C closure. It needs no upvalues: `errfuncHandler` only touches
   the live `L` it receives as its own argument and a fixed local buffer: it
   has no need to reach `ExecutionContext` (§1's decision already rules that
   out).
2. `const handler_index = bindings.lua_gettop(L);` — capture the absolute
   index immediately. On the empty-stack precondition of §2.1 this is `1`, but
   the design does not hardcode `1`: it calls `lua_gettop` so the same code is
   correct even if a future change pushes something else onto `L` before this
   point (e.g. a future diagnostic value) — computing the index structurally,
   not by assumption, is the same discipline `host_context.zig`'s own comments
   apply to registry-vs-stack indices elsewhere in this codebase.
3. `bindings.luaL_loadbuffer(L, script_source.ptr, script_source.len,
   "bpm_script")` — unchanged call, now landing at index `handler_index + 1`
   (index 2 under §2.1's precondition) because the handler already occupies
   index `handler_index`.
4. The existing `if (status != 0)` compile-error branch is unchanged in shape,
   but must now also pop the handler before returning (`bindings.lua_pop(L,
   1)` — or simply let `lua_close` reclaim it, since every return path in
   `executeSource` already runs through `defer bindings.lua_close(L)`; this
   design does NOT require an explicit pop on the compile-error path, because
   leaving an unused closure on a stack about to be closed is not a leak —
   `lua_close` frees the entire state including its stack).
5. `const call_status = bindings.lua_pcall(L, 0, 1, handler_index);` — the
   only line-level change to the call itself: `0` becomes `handler_index`.

This ordering is the single piece of the design most likely to be gotten wrong
by transposition (handler after chunk, or a relative index used instead of
absolute) — both mistakes are silent at compile time and produce either "no
handler actually installed" (relative index accidentally resolving to the
chunk's own slot, `lua_pcall` erroring with an invalid errfunc index, or worse,
successfully invoking the wrong Lua value as if it were the handler) or "handler
installed but errfunc argument still 0" (ordering correct, 4th argument
forgotten). BACKEND-DEV must implement steps 1-5 in exactly this order and in
the same function scope, with no intervening push between step 1 and step 2.

---

## 3. How the trace reaches `ScriptResult` / `ScriptErrorPayload`

### 3.1 The problem this section resolves

Once a handler is installed, `lua_pcall`'s error VALUE — whatever is on top of
the stack when it returns non-zero, currently read via
`bindings.lua_tostring(L, -1)` at executor.zig ~L545 to populate `err_msg` — is
no longer the raw string the script's `error()` call raised. It is whatever the
handler's Lua-level return value was. If the handler pushes a two-piece result
(message + trace combined, or a table), `err_msg` extraction breaks unless the
call site changes to match.

### 3.2 Decision: handler returns the ORIGINAL error value unchanged; the trace
rides the registry channel, not the return value

`errfuncHandler` does two things when invoked:

1. Runs `writeStackFrames` (§1) against the still-live `L` and stores the
   resulting bytes on the **existing LUA_REGISTRYINDEX channel pattern**
   (`host_context.zig`'s `installContext`/`FAILURE_REASON_KEY` precedent) under
   a new private key, e.g. `bindings.lua_pushlstring` of the fixed buffer's
   content, `lua_setfield(L, LUA_REGISTRYINDEX, STACK_TRACE_KEY)`. This is a
   Lua-string copy — LuaJIT's own GC now owns the bytes, identical to how
   `setExplicitFailure`'s `reason` field is stored (`host_context.zig` ~L215).
2. Returns exactly what it was called with — the original error object
   untouched (`return 1;` after nothing has changed about what is on top of
   the stack at index matching its single argument). A `lua_CFunction` message
   handler receives the raw error value as its only argument (arg index 1) and
   whatever is on the stack when it returns becomes the new error object; by
   leaving that value exactly where it started (not popping, not pushing a
   replacement), the handler is a transparent pass-through from `lua_pcall`'s
   caller's point of view.

**Consequence: `executor.zig`'s existing `err_msg` extraction
(`bindings.lua_tostring(L, -1)` at ~L545) requires ZERO changes.** The error
object `lua_pcall` returns is bit-for-bit the same value the script itself
raised — the handler observed it and stashed a side artefact, but did not
transform it. This is the design's central simplifying choice.

### 3.3 Reading the trace back out

Immediately after the existing `readExplicitFailure`/`clearExplicitFailure`
LUA-15 branch (§6 confirms that branch is unchanged and unconditionally runs
first), the LUA-16 runtime-error branch reads the new registry key the same way
`readExplicitFailure` already reads `FAILURE_REASON_KEY` — a new small helper,
e.g. `host_context.readStackTrace(L, allocator) []const u8`, following the
exact existing pattern: `lua_getfield` + `LUA_TSTRING` type guard +
`lua_tolstring` + `allocator.dupe` + `lua_pop(L, 1)`. This helper is added
alongside — not instead of — the existing `captureStackTrace`; the standalone
walk (§1.1) remains for the idle-stack unit test's use, but the *production*
call site's `captureStackTrace(L, context.allocator) catch ""` call at
executor.zig ~L585 is replaced with `host_context.readStackTrace(L,
context.allocator)`. The registry key is cleared right after reading
(`lua_pushnil` + `lua_setfield`), mirroring `clearExplicitFailure`'s existing
"never let stale state leak into the next script" discipline, so a script that
succeeds after a prior script's failure never observes a stale trace.

### 3.4 Why this approach over the alternatives

The handoff names two alternatives: (a) format message+trace together into one
string and have the caller re-split, or (b) the registry side-slot this design
picks. **(b) is chosen** because:

- It requires **zero changes** to `err_msg` extraction (§3.2) — the single
  highest-risk edit surface named in the handoff (line 545) is untouched.
- It requires **zero changes** to any existing test or caller that asserts on
  `error_message` content (e.g. TC-ISS-0625-LUA-16-int-01's `"boom in f3"`
  substring check, ~L551) — those assertions read the value the script itself
  produced, unaffected by trace plumbing.
- It reuses an already-proven, already-reviewed mechanism
  (`LUA_REGISTRYINDEX` + private string key, not `_G`, not script-reachable)
  rather than inventing string-delimiter parsing (fragile: a script's own
  error message could itself contain the chosen delimiter) or a table-shaped
  return value (would require `err_msg` extraction to branch on
  `lua_type(L, -1)` being table-vs-string, a change to a code path this design
  is deliberately trying to leave alone).

Alternative (a) is rejected for exactly the reason above: it is strictly more
invasive (both extraction sites change) for no compensating benefit — nothing
about "the trace travels attached to the error value" is more correct or more
efficient than "the trace travels on the same side-channel LUA-15 already
established for exactly this class of problem."

---

## 4. Test updates

### 4.1 TC-ISS-0625-LUA-16-02 (`src/lua/iss0625_lua_12_15_16_test.zig` ~L272) — unchanged

This unit test calls `captureStackTrace` directly against a freshly-constructed,
idle sandboxed state (no script executed, no active call frame) and asserts an
empty result. `captureStackTrace`'s signature and behavior are untouched by this
design (§1.1 keeps it as the allocator-based entry point, now internally
delegating to the shared `writeStackFrames` primitive but observably identical
on an idle stack — `lua_getstack(L, 0, &ar)` still returns `0` immediately,
since nothing about installing a message handler changes what counts as an
"active call frame" on a state where no `lua_pcall` is in flight). No edit
required.

### 4.2 TC-ISS-0625-LUA-16-int-01 (`tests/integration/iss0625_lua_12_15_16_test.zig` ~L511-574) — flip + correct

Two required edits:

1. **Assertion flip.** Line 573's `try testing.expectEqual(@as(usize, 0),
   payload.stack_trace.len);` becomes `try testing.expect(payload.stack_trace.len
   > 0);`.
2. **Comment and title correction.** The test's title
   (`"... (KKNOWN LIMITATION: trace empty on LuaJIT 2.1)"`) and the block at
   ~L553-567 — which currently states the limitation is permanent, cites
   `debug.traceback` as "the proper fix," and references a tracking issue by
   the wrong ID (`ISS-0626`) — are both stale relative to this fix and must be
   rewritten to describe what actually now happens: a message-handler closure
   (`errfuncHandler`, §1-§2) captures the trace while call frames are live, and
   the trace round-trips via the registry channel (§3), not by installing
   `debug.traceback` (§0 correction). The rewritten comment should reference
   ISS-0628 / GH-595, not ISS-0626.
3. **Strengthen the content assertion**, not just the length check: given the
   test's own `f3 → f2 → f1 → main` script (~L533-537, `f3` raises via
   `error("boom in f3")`), the trace is expected to contain at least one frame
   attributable to `f3` specifically — assert
   `std.mem.indexOf(u8, payload.stack_trace, "f3") != null` (the frame-format
   string produced by `writeStackFrames`, `"  at bpm_script:<line> in
   'f3'\n"`, contains the function name verbatim) in addition to the
   `len > 0` check from point 1. A handler that captured nothing meaningful but
   still stashed *some* non-empty placeholder string would satisfy `len > 0`
   without proving the walk actually ran against live frames; asserting the
   named function appears is what makes this genuinely mutation-checkable —
   see §4.3.

### 4.3 New TC — proving real content, mutation-checkable

Per ISS-0628's acceptance criteria (the issue does not mandate a specific test
ID; the handoff suggests `TC-ISS-0626-LUA-16-stacktrace-01` as a placeholder
naming inherited from the stale comment's wrong tracking-issue reference — this
design renames it to match the correct issue): **`TC-ISS-0628-LUA-16-stacktrace-01`**,
added to `tests/integration/iss0625_lua_12_15_16_test.zig` alongside
TC-ISS-0625-LUA-16-int-01.

**Script:** a chain distinct from TC-ISS-0625-LUA-16-int-01's (so the two tests
cannot pass or fail in lockstep on a shared fixture) that fails at a
predictable, named point — e.g. a function `deepFn` that raises after a fixed
number of nested calls, with a script-source line count the test computes
itself (not a magic literal) so the expected line number in the assertion is
derived, not guessed.

**Assertions:**
- `result.script_error != null`, `payload.stack_trace.len > 0` (baseline, as
  §4.2).
- The trace contains the specific function name the script raised from (e.g.
  `"deepFn"`), proving the walk captured a real frame for the actual failing
  function and not a placeholder.
- The trace contains at least as many `"  at "` frame markers as there are
  nested calls in the fixture script (e.g. 3 markers for a 3-deep chain) —
  proving multiple live frames were captured, not just the innermost one
  (guards against an off-by-one in the walk's `level` loop that would silently
  stop after one frame and still pass a weaker "contains something" check).

**Mutation check (required per this session's established rigor —
`iss0169-lua08-09-10-limiter-wiring.md` §5's own standard):**
- **Reverted** (handler not installed — `lua_pcall`'s 4th argument restored to
  the literal `0`): this exact test must FAIL, specifically by observing
  `payload.stack_trace.len == 0` — the same empty-trace outcome
  TC-ISS-0625-LUA-16-int-01 asserted before this fix. A test that would still
  pass with the fix reverted is not proof of anything.
- **Applied:** passes with the named-function and frame-count assertions both
  satisfied, not merely a non-empty string.

---

## 5. Instruction-limiter / watchdog interaction — decision

**Confirmed independently (source read, not assumed):** `instruction_limiter.zig`'s
`raiseLimit` (both LUA-08's instruction-count trip and LUA-10's tight-loop
timeout trip route through it, ~L100/L105) calls `lua_pushstring` +
`lua_error(L)` — the identical `lua_error`-based longjmp mechanism a genuine
script runtime error uses. `lua_error` unwinds through the nearest enclosing
`lua_pcall` exactly like any other Lua error, with no special-casing for "this
error came from a host-installed hook rather than script code." **Consequence,
verified against the design in this document rather than assumed:** once
`errfuncHandler` is installed as `lua_pcall`'s errfunc (§2), a limiter-triggered
`lua_error` call ALSO invokes `errfuncHandler` before `lua_pcall` returns —
there is no code path inside `lua_pcall`'s C implementation that distinguishes
"the error value on the stack came from `raiseLimit`" from "the error value
came from a script's own `error()` call." Both look identical to the message
handler: an error object on the stack, live call frames beneath it.

**Decision: accepted as in-scope, additional diagnostic value. No
special-casing.**

**Justification:**
- Nothing in `instruction_limiter.zig`'s own design
  (`iss0169-lua08-09-10-limiter-wiring.md` §2.2-§2.3) or its test specifications
  (§5.1/§5.3 of the same document) asserts that a limiter-triggered
  `ScriptResult`/`ScriptErrorPayload` must have an *empty* stack trace — §2.3 of
  that design explicitly scopes itself to "the two messages... are already
  textually distinguishable" for `error_message`, and is silent on
  `stack_trace` entirely. There is no existing invariant this change would
  violate.
- A confirming grep of `tests/` (this design's own verification pass) found no
  test anywhere asserting `stack_trace.len == 0` specifically conditioned on a
  limiter-triggered error (`"instruction limit exceeded"` or `"wall-clock
  timeout exceeded"` in the message). The only test asserting an empty trace
  was TC-ISS-0625-LUA-16-int-01, which is the organic-runtime-error case this
  design's whole purpose is to flip to non-empty (§4.2) — it was never a
  limiter-specific assertion.
- A stack trace showing *where* a runaway script was when it tripped the
  instruction/timeout limit is strictly useful operational information (which
  function, which line, how deep the call chain was) for whoever is debugging
  a runaway workflow script — there is no confidentiality or correctness
  reason to suppress it, unlike (for contrast) LUA-15's explicit-failure path,
  which deliberately has no trace because a `platform.fail()` call is a
  deliberate API signal, not a debugging aid (§6).
- Special-casing would require `errfuncHandler` (or the call site) to
  distinguish "this error came from `raiseLimit`" from "this error came from
  script code" — the only way to do that robustly is to compare the error
  message text against the two known limiter strings, which is fragile
  (string-matching an error message to gate a feature) and adds real
  complexity for a behavior change nothing requires suppressing.

**No test currently asserts empty trace on a limiter trip** (confirmed above),
so no existing assertion needs flipping for this decision — TC-LUA-08-01 and
TC-LUA-10-01 (`iss0169-lua08-09-10-limiter-wiring.md` §5.1/§5.3) assert on
`result.error_message` content and wall-clock bounds only; neither inspects
`stack_trace`. This design adds no new assertion to those tests — they are
out of scope for this fix and continue passing unchanged, now simply carrying a
non-empty `stack_trace` as an incidental, unasserted field, exactly like any
other field those tests do not currently check.

---

## 6. Explicit scope note — LUA-15 unaffected

`host_context.readExplicitFailure` (`host_context.zig` ~L317, called from
`executor.zig` ~L555, BEFORE the LUA-16 branch) reads the `FAILURE_EXPLICIT_KEY`
/ `FAILURE_REASON_KEY` / `FAILURE_DETAILS_KEY` registry channel that
`platform.fail()` (LUA-15) writes via `setExplicitFailure` — a channel entirely
separate from the new `STACK_TRACE_KEY` this design adds (§3.3) and from
`captureStackTrace`/`errfuncHandler` (§1) altogether. The `view.kind ==
.Explicit` branch (executor.zig ~L566-581) returns before `captureStackTrace`
(now `readStackTrace`) is ever called — this control flow is unchanged by this
design. Confirmed: **zero changes required to LUA-15's explicit-failure path.**
One second-order effect worth naming explicitly rather than leaving implicit: an
explicit `platform.fail()` call still goes through `lua_error` internally
(`raiseMessage`, `host_context.zig` ~L470), so `errfuncHandler` still fires and
still writes a trace into `STACK_TRACE_KEY` for that call — but because the
`.Explicit` branch returns before `readStackTrace` is reached, that written
value is simply never read on this path, and `clearExplicitFailure`
(unconditionally called at executor.zig ~L564, before the branch on
`view.kind`) already runs regardless of outcome. The new registry key is left
holding a stale value after an explicit failure; it is silently overwritten (or
read-and-cleared) the next time `readStackTrace` executes for a subsequent
runtime error, and a subsequent *explicit* failure never reads it at all — no
behavior-visible staleness is possible given the code shape, but the design
records this rather than leaving it as an unstated assumption.

---

## Public interface (summary)

```
// src/lua/executor.zig
fn errfuncHandler(L: *bindings.LuaState) callconv(.c) c_int;   // NEW — message handler
fn writeStackFrames(L: *bindings.LuaState, buf: []u8) usize;   // NEW — shared, allocator-free walk
pub fn captureStackTrace(L: *bindings.LuaState, allocator: std.mem.Allocator) ![]u8;  // UNCHANGED signature, internally reuses writeStackFrames
const STACK_TRACE_BUFFER_BYTES: usize = 4096;                   // NEW

// src/lua/host_context.zig
pub const STACK_TRACE_KEY: [*:0]const u8 = "bpm.stack_trace";   // NEW — registry key, same pattern as FAILURE_REASON_KEY
pub fn readStackTrace(L: *bindings.LuaState, allocator: std.mem.Allocator) []const u8;  // NEW
```

**Call-site changes, `executor.zig` `executeSource`:**
- `luaL_loadbuffer` call site (~L518-523): gains two new statements immediately
  before it (push handler, capture `handler_index`) — see §2.2 steps 1-2.
- `lua_pcall(L, 0, 1, 0)` (~L543): 4th argument becomes `handler_index`.
- `captureStackTrace(L, context.allocator) catch ""` (~L585): replaced with
  `host_context.readStackTrace(L, context.allocator)`.
- `err_msg` extraction (~L545): **unchanged** (§3.2/§3.4).
- LUA-15 branch (~L555-581): **unchanged** (§6).

**Test changes:**
- `src/lua/iss0625_lua_12_15_16_test.zig` TC-ISS-0625-LUA-16-02: unchanged (§4.1).
- `tests/integration/iss0625_lua_12_15_16_test.zig` TC-ISS-0625-LUA-16-int-01:
  assertion flip + comment/title correction (§4.2).
- `tests/integration/iss0625_lua_12_15_16_test.zig`: new
  TC-ISS-0628-LUA-16-stacktrace-01 (§4.3).
- `tests/specs/LUA-16.md`: update to list the new/changed test cases per the
  test guide's spec-mirrors-implementation convention.

## Error taxonomy

No new `LuaError` variant is introduced. `errfuncHandler` cannot itself fail in
a way that needs to surface as a Zig error: `writeStackFrames` is a plain,
non-allocating, non-fallible walk over a fixed buffer (worst case, it truncates
— §1.1 — which is a degraded trace, not a failure). `host_context.readStackTrace`
follows `readExplicitFailure`'s existing shape: any read/type-mismatch case
degrades to an empty string rather than propagating an error, matching the
current `captureStackTrace(...) catch ""` call site's own existing
fail-soft convention (a missing/malformed trace must never turn a successful
error classification into a harder failure).
