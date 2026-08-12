# Design — ISS-0669: Pool mutex type replacement and acquire() SQL-outside-lock reorder

**File:** `src/db/pool.zig` only  
**Type:** E (production source modification, prose design)  
**Issue:** ISS-0669 / GH #709  
**Requirement IDs:** ORD-01, ORD-04  
**Author:** CODE-DESIGNER, 2026-08-12

---

## Module purpose

`src/db/pool.zig` manages a fixed-size PostgreSQL connection pool (`Pool`) over
`vendor/pg/pg.zig`. It has two bugs that interact to produce incorrect row-lock
isolation when `Pool.acquire()` is called concurrently from genuine OS threads
spawned via `std.Thread.spawn`:

1. `Pool.mutex` is `std.Io.Mutex` — an async-cooperative mutex tied to Zig 0.16's
   `Io.Threaded` scheduler. Raw OS threads are not registered `Io.Threaded` tasks; they
   carry no async frame. When a raw thread calls `lockUncancelable(io)` and contends,
   the cooperative park is either a no-op (the thread cannot be parked → the lock is
   immediately "granted" while the previous owner still holds it) or corrupts the
   scheduler's internal task queue. Both outcomes allow two OS threads to hold the mutex
   simultaneously, racing on `idle_count` and `idle_indices` and producing
   non-deterministic connection assignment.

2. `maybeRedirectToTenantHost` and `applyRequestStorageRouting` are called from
   `acquire()` while the mutex is still held (the `defer self.mutex.unlock(self.io)`
   at the top of `acquire()` fires only when the function returns — after both SQL
   helpers complete). Both helpers issue up to 3–4 SQL statements via `conn.exec()` /
   `conn.queryRow()`. Driving `Io.Threaded` async I/O while the pool mutex is held
   causes cross-thread response misdelivery when another OS thread simultaneously tries
   to complete its own I/O through the same event loop.

This design specifies the minimal source changes to fix both bugs in `pool.zig` without
touching any other file.

---

## Public interface — no changes

All public types (`Pool`, `Conn`, `PoolError`, `PoolConfig`, `HealthResult`),
function signatures, and `Pool.acquire()` / `Pool.release()` call conventions are
unchanged. The fix is entirely internal to `pool.zig`.

---

## Data flow — acquire() before and after

### Before (buggy)

```
Thread A          Thread B
──────────────    ──────────────
acquire()         acquire()
  lock(io)          lock(io)         ← BOTH may succeed simultaneously
  pop conn[0]       pop conn[0]      ← race: same index
  SQL (under lock)  SQL (under lock) ← Io.Threaded responses cross-wired
  return conn[0]    return conn[0]   ← same *Conn given to two threads
```

### After (correct)

```
Thread A                Thread B
──────────────────      ──────────────────
acquire()               acquire()
  lock()
  pop conn[0]
  unlock()              ← critical section ends; conn[0] exclusively owned by A
  SQL (no lock)
  return conn[0]        acquire()
                          lock()
                          pop conn[1]
                          unlock()
                          SQL (no lock)
                          return conn[1]
```

---

## Exact changes — `src/db/pool.zig`

### Change 1 — `Pool` struct field

**Location:** `Pool` struct definition, field `mutex`.

| Before | After |
|---|---|
| `mutex: std.Io.Mutex,` | `mutex: std.Thread.Mutex,` |

`std.Thread.Mutex` is an OS-level mutex (futex on Linux, CRITICAL_SECTION on Windows).
It does not require an `io` parameter and is safe to call from any OS thread.

### Change 2 — `Pool.init()` initializer

The return literal `.mutex = .init,` is **unchanged**. Both `std.Io.Mutex` and
`std.Thread.Mutex` expose a `pub const init` sentinel usable as a comptime default,
so the existing `.init` initializer compiles correctly after the type change with no
edits to `Pool.init()`.

### Change 3 — Lock/unlock call-site signature changes

`std.Thread.Mutex.lock()` and `.unlock()` take no parameters (no `io` argument).
Every call site in `pool.zig` must change:

| Before | After |
|---|---|
| `self.mutex.lockUncancelable(self.io)` | `self.mutex.lock()` |
| `self.mutex.unlock(self.io)` | `self.mutex.unlock()` |

**Affected call sites (4 total):**

| Function | Position | Change |
|---|---|---|
| `Pool.acquire()` | top — exclusive-lock line | `lockUncancelable(self.io)` → `lock()` |
| `Pool.acquire()` | top — `defer` unlock | `unlock(self.io)` → `unlock()` |
| `Pool.release()` | early-exit block (failed remote reconnect) — lock | `lockUncancelable(self.io)` → `lock()` |
| `Pool.release()` | early-exit block (failed remote reconnect) — unlock | `unlock(self.io)` → `unlock()` |
| `Pool.release()` | main — final lock | `lockUncancelable(self.io)` → `lock()` |
| `Pool.release()` | main — final `defer` unlock | `unlock(self.io)` → `unlock()` |

(Six edit points total across the four logical call sites.)

### Change 4 — `Pool.acquire()`: unlock before SQL calls

This is the structural change. The `defer self.mutex.unlock(self.io)` at the top of
`acquire()` must be replaced with an explicit early unlock immediately after the
stale-connection block. The SQL helpers must run after the unlock, with per-error
re-lock-pushback-unlock paths.

#### Current structure (abridged):

```zig
pub fn acquire(self: *Pool) PoolError!*Conn {
    self.mutex.lockUncancelable(self.io);     // ← A
    defer self.mutex.unlock(self.io);          // ← B  fires on return, AFTER SQL

    if (self.idle_count == 0) return PoolError.ExhaustedPool;

    self.idle_count -= 1;
    const idx = self.idle_indices[self.idle_count];
    const conn = &self.conns[idx];

    if (!conn._is_valid) {                     // ← stale-conn block
        conn._pg.close();
        conn._pg = pg.Conn.connectUrl(...) catch {
            // ... pushback ...
            return PoolError.ConnectionFailed; // defer fires → unlocks
        };
        conn._is_valid = true;
        conn._io = self.io;
        if (conn._remote_host) |old| { ... }
    }

    // ← mutex still held for both calls below
    maybeRedirectToTenantHost(conn, self.allocator, self.io) catch |err| {
        // ... pushback ...
        return err;                            // defer fires → unlocks
    };
    applyRequestStorageRouting(conn) catch |err| {
        // ... pushback ...
        return err;                            // defer fires → unlocks
    };

    return conn;                               // defer fires → unlocks
}
```

#### Required structure (pseudocode — no implementation code):

```
acquire(self) -> PoolError!*Conn:

  [CRITICAL SECTION BEGIN]
  self.mutex.lock()

  if self.idle_count == 0:
      self.mutex.unlock()
      return ExhaustedPool

  self.idle_count -= 1
  idx  ← self.idle_indices[self.idle_count]
  conn ← &self.conns[idx]

  if not conn._is_valid:
      conn._pg.close()
      new_pg ← pg.Conn.connectUrl(self.io, self.allocator, conn._url) on_error:
          self.idle_indices[self.idle_count] = idx
          self.idle_count += 1
          self.mutex.unlock()
          return ConnectionFailed
      conn._pg    = new_pg
      conn._is_valid = true
      conn._io    = self.io
      if conn._remote_host != null: free and null it

  // Critical section ends: conn is exclusively owned by this caller.
  // No other thread can access conn until it is released.
  self.mutex.unlock()
  [CRITICAL SECTION END]

  // SQL helpers run WITHOUT the lock.
  maybeRedirectToTenantHost(conn, self.allocator, self.io) on_error |err|:
      self.mutex.lock()
      self.idle_indices[self.idle_count] = idx
      self.idle_count += 1
      self.mutex.unlock()
      return err

  applyRequestStorageRouting(conn) on_error |err|:
      self.mutex.lock()
      self.idle_indices[self.idle_count] = idx
      self.idle_count += 1
      self.mutex.unlock()
      return err

  return conn
```

**Key invariants this enforces:**

- `idle_count` and `idle_indices` are only read or written while `mutex` is held.
- `conn._is_valid`, `conn._pg`, `conn._remote_host`, and `conn._io` are only written
  inside the critical section (before the unlock), so no other thread can observe a
  partial stale-conn rewrite.
- SQL I/O (`maybeRedirectToTenantHost`, `applyRequestStorageRouting`) runs outside the
  lock. The connection is exclusively owned at that point; no invariant protects it, but
  none is needed — ownership is exclusive until `Pool.release()` is called.

### Change 5 — `Pool.release()`: no structural change required

`release()` already executes all SQL (`resetConnectionSearchPath`,
`clearConnectionAdvisoryLocks`) BEFORE acquiring the mutex. The mutex in `release()`
only protects the `idle_indices` push — which is correct. The only changes needed in
`release()` are the call-site signature renames from Change 3 (6 edit points covering
the 2 locked blocks inside `release()`).

---

## Error taxonomy

| Error | Source | Behaviour after fix |
|---|---|---|
| `ExhaustedPool` | `idle_count == 0` | unchanged — returned while lock held, then unlock |
| `ConnectionFailed` | stale-conn reconnect fails | unchanged — unlock inside the critical section before return |
| `ConnectionFailed` | `maybeRedirectToTenantHost` | NEW path: re-lock, pushback, unlock, return |
| `QueryFailed` | `applyRequestStorageRouting` | NEW path: re-lock, pushback, unlock, return |
| `QueryFailed` | `maybeRedirectToTenantHost` | NEW path: same as above |

The new re-lock-pushback-unlock paths in the error returns of `maybeRedirectToTenantHost`
and `applyRequestStorageRouting` must protect `idle_count` / `idle_indices` writes. This
is a new lock-acquire operation not present in the current code.

---

## State transitions — `idle_count`

```
idle_count = N (pool fully idle)

Thread calls acquire():
  lock → idle_count = N-1, idx = idle_indices[N-1] → unlock
  SQL succeeds → return conn         (idle_count stays N-1 until release)
  SQL fails    → lock, idle_count = N, pushback → unlock, return error

Thread calls release(conn):
  [SQL resets outside lock]
  lock → idle_indices[idle_count] = conn._pool_idx, idle_count++ → unlock
```

---

## Dependencies

`pool.zig` depends on:
- `std.Thread.Mutex` (replaces `std.Io.Mutex`) — provided by the Zig standard library,
  no import change
- `vendor/pg/pg.zig` — unchanged
- `@import("tenant_context")`, `@import("pipeline_context")` — unchanged
- `@import("obs_metrics")` — unchanged

`pool.zig` must NOT depend on `std.Io.Mutex` after this change (one occurrence to
remove: the struct field).

---

## Open questions

1. **Stale-conn reconnect under the lock:** `pg.Conn.connectUrl(self.io, ...)` in
   the stale-conn block establishes a new TCP connection while the pool mutex is held.
   This serialises all `acquire()` callers during a reconnect event. With
   `std.Thread.Mutex` this is a real blocking wait, not the broken cooperative park.
   It is correct but may add latency under high concurrency when connections go stale.
   Moving the reconnect outside the lock (similar to Change 4) is a future improvement
   (separate issue); it is out of scope for ISS-0669 which targets the correctness
   regression.

2. **`Conn.exec()` / `Conn.query()` use `std.Io.Clock.real.now(self._io)`:** After the
   fix `_io` is set to `self.io` (the pool's `std.Io`). If the pool's `io` is an
   `Io.Threaded` instance, `Clock.real.now(io)` may still enter the event loop from a
   raw OS thread context. This is limited to timestamping (no data delivery path) and
   does not cause the row-lock isolation failure. However it should be reviewed for
   thread-safety in a follow-up. (REQ-ANALYST flag: OUT-OF-SCOPE for ISS-0669.)
