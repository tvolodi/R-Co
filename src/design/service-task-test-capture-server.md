# Module: CaptureServer test-infrastructure fix (tests/unit/service_task_test.zig)

**Covers:** ISS-0207 / GH #528 — flaky `TC-EXT-01-U08a: executeHttpRequest injects trace, idempotency, and configured headers`
**Files:**
- `tests/unit/service_task_test.zig` — `CaptureServer` struct (lines ~12-98), `captureRequestHeaders` (lines ~106-117), test block `TC-EXT-01-U08a` (lines ~309-342). All changes are test-infrastructure only; no production source file is touched.

**Depends on:**
- `std.Thread` (already used for `server.thread`, `std.Thread.spawn`, `t.join()`)
- `std.Thread.ResetEvent` (new — synchronisation primitive introduced by this design)
- `std.Io.net.IpAddress` / the `listen()` mechanism already used in `run()` (line 46-47) and in `src/main.zig` line 183-184
- No new external dependencies; this is a self-contained change to one test file

---

## Module purpose

`CaptureServer` is a hand-rolled, single-request-capturing HTTP test double used only by `TC-EXT-01-U08a` to verify that `executeHttpRequest` sends the expected `X-Trace-Id`, `X-Bpm-Idempotency-Key`, and configured custom headers on outbound service-task HTTP calls. It runs its accept/read/respond loop on a background `std.Thread` while the test thread drives the request via `st.executeHttpRequest` and then asserts on fields the background thread wrote.

This design closes two independent races (ISS-0207 root cause analysis, both already confirmed sufficient on their own to cause the observed flake):

1. The server binds a **hardcoded TCP port 18181**, a machine-wide shared resource that can collide with another concurrent test binary or a parallel workspace checkout on the same host.
2. The test reads `server.first_trace_id` / `first_trace_id_len` (and the idempotency-key / custom-header equivalents) at line 339-341 with **no happens-before edge** to the background thread's write in `captureRequestHeaders`. `defer server.join()` (line 320) only runs at scope exit, i.e. *after* the assertions already ran — so it establishes no ordering guarantee for the reads that matter.

Both fixes are confined to `CaptureServer` and the one test block that instantiates it. No other test in the file uses `CaptureServer`, so no other test is affected.

---

## Scope and non-goals

**In scope:**
- Change `CaptureServer.port` handling so the server binds an OS-assigned ephemeral port (port 0) instead of the literal `18181`.
- Add a mechanism for the test to read back the actual bound port after `start()` returns, so it can build `url_template` dynamically.
- Add a `std.Thread.ResetEvent` (or equivalent single-shot signal) that the background thread sets once it has finished writing the captured-header fields for the request being tested, and that the test thread waits on before reading those fields.
- Replace the `defer server.join()`-before-assertions ordering with an explicit wait that happens *before* the four `expectEqual`/`expectEqualStrings` calls, not after.

**Out of scope:**
- Any change to `st.executeHttpRequest`, `src/service_task/*`, or any other production module. `CaptureServer` is test-only infrastructure; the service under test is unmodified.
- Any change to the other `CaptureServer` fields (`second_trace_id`, `second_idempotency_key`, `followed_count`, etc.) that are not read by `TC-EXT-01-U08a`. They may be left as-is; this design does not require synchronising fields no test reads. (If a future test starts reading `second_*` fields across the thread boundary, it must apply the same pattern — see "Key invariants" below.)
- Retry/redirect-follow tests that use `CaptureServer` with `max_requests > 1` are unaffected by this design as long as they do not read captured fields before joining; if any such test currently has the same defer-join-after-assert shape, that is a separate finding and should be filed as its own incidental issue rather than folded into this fix.

---

## (a) Ephemeral port binding

### Problem being fixed

`run()` currently parses a listen address from `"127.0.0.1"` and `self.port` (which is always the literal `18181`) and calls `.listen(io, .{ .reuse_address = true })` on it, and the test constructs `cfg.url_template` as the string literal `"http://127.0.0.1:18181/execute"`. Both the bind and the client target are pinned to the same fixed port, so nothing prevents two independent processes (concurrent `zig build test` binaries, or two parallel workspace checkouts on the same host, per the existing R-Co parallel-workspace convention of port-banding) from colliding on port 18181 — either failing the `listen()` call outright (masked today because `run()` silently `return`s on that error, which is itself why the test hangs/fails rather than erroring loudly) or, in the pathological case, one process's client connecting to a foreign listener.

### Design

1. **`CaptureServer.port` becomes the *requested* port, and defaults to `0`.** Change the field's semantics: `0` means "ask the OS for an ephemeral port." `TC-EXT-01-U08a` constructs the server with `.port = 0` instead of `.port = 18181`.

2. **`CaptureServer` gains a new field to publish the actual bound port back to the caller**, e.g. `bound_port: u16 = 0`, plus (per point (b) below) a `ResetEvent` that also signals "bind is complete and `bound_port` is safe to read." The server does not know its real port until the OS assigns it inside `listen()`, so the existing `start()`/`run()` split needs a second, earlier synchronisation point in addition to the per-request one — see the combined event design in section (b).

3. **Inside `run()`, immediately after the `listen()` call succeeds**, read the actual bound address back from the returned server/listener value (the same object returned by `listen_address.listen(io, .{ .reuse_address = true })`, call it `listener`). Zig's `std.Io.net` listener exposes the concrete bound socket address after `listen()` (the same mechanism `src/main.zig` and other call sites rely on to report the address they ended up bound to — consult whatever field/accessor the vendored `std.Io.net.Server`/`Listener` type exposes for its local address, e.g. a `.listen_address` field or a `getLocalAddress()`-style accessor on the returned server value). Extract the port number from that address and store it into `self.bound_port` *before* signalling readiness.

4. **Signal "server is bound and ready to accept"** (a distinct signal from "first request fully captured," described in section (b)) immediately after `self.bound_port` is written. The test thread, after calling `server.start()`, waits on this "bound" signal before reading `server.bound_port` and before constructing `url_template`. This prevents a second, more subtle race: reading `bound_port` before the background thread has written it (a plain field write on `start()`'s spawned thread with no synchronisation would itself be a fresh data race being introduced by this fix if the port readback isn't also synchronised).

5. **The test builds `url_template` dynamically, after the bind-ready wait**, by formatting `"http://127.0.0.1:{}/execute"` with `server.bound_port` (using `std.fmt.allocPrint` or equivalent, freed via `defer allocator.free(...)` — this test already uses `std.testing.allocator` and already frees other allocated fields such as `cfg.url_template` is *not* currently freed since it's a literal today; once it becomes an owned allocation the test must free it, matching the pattern already used for `cfg.node_id` / `cfg.url_template` in the `EXT-01` parse tests earlier in the same file).

6. **No change to `.reuse_address = true`** — keep it; it remains harmless and consistent with the rest of the file's usage even though ephemeral-port binding makes address reuse collisions structurally impossible for this test.

### Net effect

Every run of `TC-EXT-01-U08a` binds a fresh, OS-chosen, currently-unused port. Two concurrent test binaries (same host, same or different workspace checkout) can never collide on this port again, because the OS guarantees ephemeral ports it hands out are not already bound.

---

## (b) Happens-before synchronisation

### Problem being fixed

`captureRequestHeaders(self, &request)` (called from the background thread inside `run()`, line 66) writes `self.first_trace_id`, `first_trace_id_len`, `first_idempotency_key`, `first_idempotency_key_len`, `first_custom_header`, `first_custom_header_len` with no memory barrier or synchronisation object. The test thread, after `try st.executeHttpRequest(...)` returns (line 335), immediately reads those same fields at lines 339-341. `defer server.join()` (line 320) is scheduled to run when the enclosing test function's scope exits — which in Zig happens *after* every statement in the function body, including all four assertions. So the join (the one operation in the current code that *could* have established a happens-before edge) executes too late to protect the reads it was presumably meant to protect.

Because `executeHttpRequest` itself performs a real HTTP round-trip (it must wait for the server's `respond()` to complete in order to return a `result` at all), in practice the server has *usually* finished writing the header-capture fields by the time `executeHttpRequest` returns — the client-side read of the HTTP response is sequenced, on the wire, after the server wrote the response, which is itself sequenced after `captureRequestHeaders` ran. This is why the bug is rare rather than constant. But nothing in the Zig memory model gives the test thread a guaranteed *visibility* of those writes without an explicit synchronisation primitive — the ordering that usually saves this test is a socket round-trip, not a language-level happens-before edge, so the compiler/CPU are free to reorder or the test thread may observe stale cached values under contention (exactly what ISS-0207 observed once under full-suite concurrency).

### Design

Introduce a `std.Thread.ResetEvent` field on `CaptureServer` dedicated to signalling "the current request's headers have been fully captured and it is safe to read the `first_*` fields":

1. **New field:** `headers_captured: std.Thread.ResetEvent = .{}`. (If the bind-readiness signal from section (a) is implemented as a second, separate `ResetEvent`, name it distinctly, e.g. `listening: std.Thread.ResetEvent = .{}` — two single-shot events, one per readiness milestone, rather than overloading one event for two different meanings. A single combined event is not correct here because the test needs to observe two *different* points in the server's lifecycle: "bound and listening" (to read `bound_port`) and "first request captured" (to read `first_trace_id` etc.), and these do not happen at the same time.)

2. **Where the server sets it:** inside `run()`, in `captureRequestHeaders`'s caller, immediately after the call to `captureRequestHeaders(self, &request)` returns (line 66) and *before* the response is sent via `request.respond(...)` (lines 82-93). Concretely: right after line 66, call `self.headers_captured.set()`. Setting it before `respond()` (rather than after) is deliberately conservative — it guarantees the fields are fully written before any signal fires, and does not depend on the response having been transmitted. It also means the design is correct regardless of how `executeHttpRequest`'s own timing behaves, removing the implicit "the HTTP round-trip usually protects us" reasoning entirely.

   This only needs to fire for the *first* captured request in this test's usage (`max_requests = 1`), so no per-request reset/rearm logic is needed for `TC-EXT-01-U08a` specifically. (A future test that reuses `CaptureServer` across multiple requests and needs to synchronise on each one individually would need either multiple events or a reset-and-rewait pattern — out of scope here since `max_requests = 1` for this test.)

3. **Where the test waits on it:** in the test body, after `const result = try st.executeHttpRequest(...)` (line 335) and *before* the first assertion that reads a captured field (line 339). Call `server.headers_captured.wait()` (blocking wait; `ResetEvent.wait()` blocks the calling thread until `set()` has been called, with the necessary acquire/release semantics to make the writes in `captureRequestHeaders` visible to the waiting thread once `wait()` returns). Optionally use `server.headers_captured.timedWait(<bound>)` with a generous bound (e.g. a few seconds) and fail the test explicitly with a descriptive message if the wait times out, so a genuine server-side hang produces a clear test failure instead of an indefinite hang — this is a robustness improvement, not required to fix the race itself, and may be left as plain `wait()` if BACKEND-DEV prefers to keep the change minimal; either is acceptable, the choice is not a correctness-affecting design decision.

4. **`defer server.join()` (line 320) is retained but is no longer load-bearing for correctness of the assertions.** Once `headers_captured.wait()` has returned, the fields are already safely visible; `server.join()` at scope exit continues to serve its existing purpose of cleaning up the background thread (`run()` naturally exits after the single request in this test, since `max_requests = 1`) and preventing a leaked/detached thread. No change to its position is required — it is correct for it to remain a `defer` at scope exit, because thread cleanup (not data visibility) is its only remaining job.

5. **Ordering summary (the new, non-racy sequence):**
   - Test thread: `server.start()` → wait on `listening` event → read `bound_port`, build `url_template` → call `st.executeHttpRequest(...)` (which opens the connection, sends the request, and blocks until the response is received) → wait on `headers_captured` event (in practice this returns immediately since `executeHttpRequest` already returned, meaning the HTTP round trip completed, meaning `captureRequestHeaders` must already have run and the event must already be set — but the explicit wait makes this a guarantee rather than an assumption) → read `first_trace_id` etc. → assert.
   - Server thread: bind → set `listening` → accept → read headers into `first_*` fields via `captureRequestHeaders` → set `headers_captured` → respond → loop condition false (`request_count == max_requests`) → `run()` returns → thread exits → `join()` (deferred) returns promptly.

### Net effect

The test thread never reads `first_trace_id` / `first_trace_id_len` / `first_idempotency_key` / `first_idempotency_key_len` / `first_custom_header` / `first_custom_header_len` until the background thread has explicitly signalled, via a proper synchronisation primitive, that those exact writes have completed. This removes the data race by construction rather than relying on the incidental ordering a successful HTTP round-trip usually provides.

---

## Key invariants

1. **`CaptureServer` MUST NOT bind a hardcoded, literal port.** Requesting port `0` (OS-assigned ephemeral port) is mandatory for any `CaptureServer` instance used by a test that runs as part of `zig build test` (i.e. potentially concurrently with other test binaries or other workspace checkouts on the same host).
2. **The test thread MUST NOT read any `CaptureServer` field written by the background thread (`bound_port`, `first_trace_id`, `first_trace_id_len`, `first_idempotency_key`, `first_idempotency_key_len`, `first_custom_header`, `first_custom_header_len`, or their `second_*` counterparts if a future test reads them) without first waiting on a synchronisation primitive that the background thread signals strictly after writing that field.** A `defer`-scheduled `join()` that runs after the reads it was meant to guard does not satisfy this invariant — the wait must be sequenced in the code strictly before the read, not merely guaranteed to eventually run before the test function returns.
3. **Each readiness milestone gets its own signal.** "Bound and listening" and "first request's headers captured" are distinct events in the server's lifecycle and must not share one `ResetEvent`, because the test needs to act on each independently (read `bound_port` after the first; read `first_*` fields after the second).
4. **`server.join()` remains solely a thread-lifecycle cleanup step** after this change, not a data-visibility mechanism. Any future reviewer must not reintroduce reliance on `defer server.join()` ordering as a substitute for an explicit wait on the relevant `ResetEvent`.
5. **This fix must not alter `st.executeHttpRequest`'s behaviour or signature.** The service-task HTTP client code is production code and is out of scope; only the test double changes.

---

## Public interface (test-file-local; `CaptureServer` is not exported outside this test file)

Additions to the `CaptureServer` struct (prose signatures — no implementation code):

- Field `port: u16` — semantics change from "the port to bind" (previously always `18181` in practice) to "the port to *request*"; `0` requests an OS-assigned ephemeral port. `TC-EXT-01-U08a` sets this to `0`.
- New field `bound_port: u16` (default `0`) — populated by the background thread inside `run()`, immediately after `listen()` succeeds, with the actual port the OS assigned. Read by the test thread only after waiting on `listening`.
- New field `listening: std.Thread.ResetEvent` (default-initialised, unset) — set by the background thread once `bound_port` has been written and the listener is ready to accept. Waited on by the test thread before reading `bound_port` / building `url_template`.
- New field `headers_captured: std.Thread.ResetEvent` (default-initialised, unset) — set by the background thread immediately after `captureRequestHeaders` returns for the first captured request, before `respond()` is called. Waited on by the test thread, after `executeHttpRequest` returns and before reading any `first_*` field.
- `run()` gains two new statements (prose, not code): one immediately after the `listen()` call succeeds, to write `bound_port` from the listener's local address and then call `self.listening.set()`; one immediately after the existing call to `captureRequestHeaders(self, &request)`, to call `self.headers_captured.set()`.
- `TC-EXT-01-U08a`'s test body gains: construction with `.port = 0` instead of `.port = 18181`; a wait on `server.listening` after `server.start()` and before building `url_template`; dynamic construction of `url_template` (heap-allocated via the test's allocator, freed via `defer`) using `server.bound_port` instead of the `"http://127.0.0.1:18181/execute"` literal; a wait on `server.headers_captured` after `st.executeHttpRequest(...)` returns and before the first `expectEqualStrings` call on a captured field.

---

## Error taxonomy

No new error types. This is test-infrastructure code; failures surface as:
- `ResetEvent.wait()` — blocks indefinitely if the signal is never set (e.g. server thread crashed before signalling). BACKEND-DEV may choose `timedWait` with a bounded timeout and an explicit `std.testing.expect(false)`-style failure with a descriptive message on timeout, to avoid an indefinite hang masking a real defect as a stuck test run. This is a recommended robustness addition, not a hard requirement of this design.
- `listen()` failure (already handled today via `catch return` inside `run()`) — unchanged by this design; still out of scope. If BACKEND-DEV wants to surface a bind failure more loudly (e.g. so an ephemeral-port bind failure, which should be exceedingly rare, doesn't silently hang the test on the `listening` wait instead of the previous silent `run()` return), they may additionally have the `catch` branch call `self.listening.set()` before returning so the test thread's wait does not hang forever on a bind failure — again a robustness improvement, not required to satisfy the two acceptance criteria in ISS-0207.

---

## Dependencies

- `std.Thread.ResetEvent` — new dependency for this test file; standard library, no vendoring required.
- `std.Io.net` listener/server local-address accessor — already used indirectly via `listen_address.listen(io, ...)` in `run()`; this design only adds a read of the already-returned listener value's bound address, using whatever accessor the vendored Zig `std.Io.net.Server` (or equivalent) type provides (consult the same stdlib version already in use elsewhere in the repo, e.g. `src/main.zig` line 183-184, for the exact type returned by `.listen()` and its address-reporting member).
- No new build dependencies, no new files, no migration, no production source changes.

---

## Open questions

None. Both acceptance criteria (ephemeral port + happens-before synchronisation) are fully specified above; BACKEND-DEV has a concrete field list, a concrete statement-placement description for both the "set" and "wait" sides of each of the two `ResetEvent`s, and an explicit statement of which existing behaviour (`defer server.join()`) is retained and why it is no longer load-bearing for correctness.
