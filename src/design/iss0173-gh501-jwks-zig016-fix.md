# ISS-0173 / GH-501 — `src/oidc/jwks.zig` Zig 0.16 migration + orphan-fate

## Scope

This artefact designs the fix for [ISS-0173](https://github.com/tvolodi/R-Co/issues/501) (GH-501).
The diagnosis at [docs/issue-reports/ISS-0173-gh501-diagnosis.yaml](docs/issue-reports/ISS-0173-gh501-diagnosis.yaml)
established that `src/oidc/jwks.zig` is **orphaned on three independent axes**:

1. No `addTest` root reaches it — its 16 in-file `test {}` blocks never compile.
2. `build.zig` does **not** register it as a named module.
3. `src/main.zig:78` re-exports it as `oidc_jwks`, but **zero callers** in the workspace
   reach that re-export (verified: `Get-ChildItem -Recurse -Include "*.zig","*.ts","*.tsx"`
   | Select-String -Pattern "\boidc_jwks\b"` returns exactly one hit — `src/main.zig:78` itself).

A direct `zig test src/oidc/jwks.zig` exits 1 with five compile errors rooted in Zig 0.16
API removals (`std.Thread.Mutex`) and form changes (`std.ArrayList(T)` is now unmanaged;
`.deinit()` and `.append()` take an allocator argument).

This artefact is the **fix design** — it covers all six deliverables the diagnosis prescribed
and is the single source of truth for the BACKEND-DEV step (WF-03 Step 3) that follows.

> **CRITICAL CONSTRAINT:** No source files are modified in this design step. The design is
> a recipe for BACKEND-DEV. The only file BACKEND-DEV may edit at the end of this run is
> `handoffs/WF03-GH501-20260808/step-02-code-designer.json`.

---

## Public interface (target post-fix)

There are **two** possible end-states; both are designed below. Decision matrix in §6.

### State A — DELETE (recommended; default)

```zig
// no public interface — the file does not exist.
// src/main.zig:78 is removed.
// pub const oidc_jwks = @import("oidc/jwks.zig");  ← DELETED
```

BACKEND-DEV must verify with a workspace grep that no caller of `main.oidc_jwks` exists
before deleting; the diagnosis already did this — workspace is clean.

### State B — KEEP + RENAME + WIRE

If a future intent resurrects ISS-402's token cache, the file moves to
`src/oidc/token_cache.zig` (SHOULD-1) and the design must additionally change every
`pub fn` to thread `io: std.Io` as the first parameter. Target signatures:

```zig
// Module-level lifecycle (now take Io because the mutex needs it).
pub fn initCache(io: std.Io, allocator: std.mem.Allocator) error{ OutOfMemory, std.Io.Cancelable }!void;
pub fn deinitCache(io: std.Io) void;

// Cache API (now take Io because every lock site threads it).
pub fn checkCache(io: std.Io, realm: []const u8, jti: []const u8, now: i64) ?CachedValidation;
pub fn putCache(io: std.Io, realm: []const u8, jti: []const u8, valid: bool,
                principal_json: []const u8, exp: i64, now: i64) error{ OutOfMemory, std.Io.Cancelable }!void;
pub fn isRevoked(io: std.Io, realm: []const u8, jti: []const u8, now: i64) bool;
pub fn revokeToken(io: std.Io, realm: []const u8, jti: []const u8, expires_at: i64) error{ OutOfMemory, std.Io.Cancelable }!void;
pub fn revokeRealmTokens(io: std.Io, realm: []const u8, now: i64) error{ OutOfMemory, std.Io.Cancelable }!void;
pub fn evictExpired(io: std.Io, now: i64) void;
```

This signature change is a **breaking change** for any caller. Because there are no callers
(State A is correct), the breaking-change cost is zero — but the Io-threading effort is
non-trivial (see §4).

---

## Data types

### Existing (unchanged)

```zig
pub const MAX_CACHE_TTL_SECONDS: i64 = 300;
const FAILURE_CACHE_TTL_SECONDS: i64 = 60;

pub const TokenCacheKey = struct { realm: []const u8, jti: []const u8 };
pub const TokenCacheKeyContext = struct { /* hash, eql */ };
pub const CachedValidation = struct { valid: bool, principal_json: []const u8, expires_at: i64 };

const DenylistEntry = struct { realm: []const u8, jti: []const u8, expires_at: i64 };

pub const TokenValidationCache = struct { allocator, map /* HashMap */ };
pub const JtiDenylist = struct { allocator, entries /* ArrayList(DenylistEntry) */ };
```

### Required changes (mechanical, applies to State B)

```zig
// Before:
.entries = std.ArrayList(DenylistEntry).init(allocator),
// After (Zig 0.16 std.ArrayList(T) returns Aligned(T, null) — the unmanaged form):
.entries = std.ArrayList(DenylistEntry).empty,

// Before:
self.entries.append(.{ ... });
// After:
try self.entries.append(self.allocator, .{ ... });
// or, for the swallow-error pattern at jwks.zig:144,168:
to_remove.append(self.allocator, .{ ... }) catch continue;

// Before:
self.entries.deinit();
// After:
self.entries.deinit(self.allocator);
```

`sortedRemove` and `pop` are unchanged on the unmanaged form (confirmed against
`lib/std/array_list.zig` in installed Zig 0.16 toolchain).

### Required changes (non-mechanical — mutex)

```zig
// Before:
var cache_mutex: std.Thread.Mutex = .{};
cache_mutex.lock();
defer cache_mutex.unlock();

// After (one of two options):
// (a) Module-level static Io + Io.Mutex — requires a global Io instance:
// var global_io: ?std.Io = null;
// var cache_mutex: std.Io.Mutex = .init;
// fn doX(io: std.Io) {
//     cache_mutex.lockUncancelable(io);  // no cancellation point on the hot path
//     defer cache_mutex.unlock(io);
//     ...
// }
//
// (b) Per-instance mutex — TokenValidationCache/JtiDenylist carry their own mutex:
// pub const TokenValidationCache = struct {
//     allocator: std.mem.Allocator,
//     map: ...,
//     mutex: std.Io.Mutex, // .init
// };
// All wrapper functions take an `io: std.Io` parameter, lock with
// `c.mutex.lockUncancelable(io)` (the cached lock path has no async work and cannot be
// cancelled; `lock(io) Cancelable!void` is overkill).

// The fix design chooses option (b) — see §4 rationale.
```

`std.Io.Mutex` API surface (verified against installed Zig 0.16 `lib/std/Io.zig:1587-1648`):

| Method | Signature |
|---|---|
| `init: Mutex` | constant `.{ .state = .init(.unlocked) }` — no fn call |
| `tryLock` | `(m: *Mutex) bool` — no `io` arg |
| `lock` | `(m: *Mutex, io: Io) Cancelable!void` |
| `lockUncancelable` | `(m: *Mutex, io: Io) void` |
| `unlock` | `(m: *Mutex, io: Io) void` |

`lockUncancelable` is the right choice for the cached path because `checkCache` /
`putCache` / `isRevoked` are called synchronously from token-validation paths that have
no Io-driven cancellation context.

---

## Key invariants

1. **The build must be RED before any fix** — `zig test src/oidc/jwks.zig` (or `zig build
   test-oidc-src` after wiring) must emit the 5 errors above. This is the empirical proof
   that the file is now being compiled. If a "fix" is committed while the build is green,
   the blind spot has re-appeared.

2. **The build must be GREEN after the fix** — `zig build` and `zig build test-oidc-src`
   must exit 0 with the same test count as before (or +16 if State B is chosen and the
   in-file tests are now exercised).

3. **No caller of `main.oidc_jwks` exists** — verified at diagnosis time and re-verified
   in §6 of this artefact. This makes State A (DELETE) the lowest-risk action.

4. **`std.Io.Mutex` always takes `io: std.Io`** — there is no Io-less lock. Every wrapper
   function that touches `cache_mutex` must thread the Io parameter through. The compiler
   enforces this; ignore it and the build breaks.

5. **`std.ArrayList(T)` is unmanaged in Zig 0.16** — `.init(allocator)` no longer exists.
   Use `.empty` for the initialiser, pass `allocator` to `.append(...)` and
   `.deinit(...)`. The compiler's "no member named init" error message is misleading:
   the unmanaged form actually DOES have `.init(gpa)` — but `ArrayList(T)` resolves to
   `Aligned(T, null)` (the unmanaged variant) and the unmanaged `.init` takes an
   `Allocator`. The migration is unambiguous.

6. **`swapRemove` and `pop` are unchanged** — these have always been the same on both
   managed and unmanaged forms. Do not touch them.

7. **ISS-402 (token validation cache) is preserved if State B** — if the file is kept,
   the cache and denylist API must remain thread-safe. The mutex refactor is the
   minimum viable change to make it compile; it does NOT change correctness guarantees.

---

## External dependencies

| Module | Direction | Note |
|---|---|---|
| `src/identity/provider/oidc/jwks_cache.zig` | parallel — not duplicate | Different concern (JSON Web Key Set cache; key IDs per URI). NOT a substitute for the token-validation cache. |
| `src/main.zig:78` | re-export of the orphan | Re-export has zero callers — safe to delete the line. |
| `src/oidc_test_root.zig` | test root | If State B, add `pub const jwks = @import("oidc/token_cache.zig");` here. If State A, no change. |
| `build.zig:265-268` | named module wiring | If State B, add a `createModule` for the renamed file. If State A, no change. |
| `lib/std/Io.zig` | new dependency | Only State B introduces `std.Io` usage; this codebase has no other `std.Io` users yet. |
| `lib/std/array_list.zig` | API form change | Both State A and State B are affected (State B by migration; State A vacuously by deletion). |

---

## Data flow diagram

### State A (DELETE) — data flow unchanged

```
[no callers] ─→ src/main.zig ─→ (delete line 78) ─→ no public surface
```

### State B (KEEP + RENAME) — data flow with Io threading

```
Caller (none today, future intent)
    │
    │  io: std.Io, realm, jti, ...
    ▼
src/oidc/token_cache.zig (renamed)
    │
    │  TokenValidationCache.mutex.lockUncancelable(io)
    │  defer cache.mutex.unlock(io)
    ▼
TokenValidationCache.get / put / evictExpired / evictRealm
    │
    │  std.ArrayList(DenylistEntry).append(self.allocator, ...)
    ▼
Heap-allocated entries + principal_json slices
```

---

## Error taxonomy

| Error | Source | Mapping |
|---|---|---|
| `error.OutOfMemory` | `append`, `dupe` | bubbled up — unchanged from 0.15 |
| `std.Io.Cancelable` | `lock(io)` if used | If `lockUncancelable(io)` is chosen (recommended), this is not produced |
| compile error "no member named init" | ArrayList unmanaged form migration | fix by `.empty` |
| compile error "expected 1 argument(s), found 0" | ArrayList unmanaged `deinit` | fix by `.deinit(allocator)` |
| compile error "expected 2 argument(s), found 1" | ArrayList unmanaged `append` | fix by `.append(allocator, item)` |
| compile error "Thread has no member named Mutex" | Zig 0.16 removed `std.Thread.Mutex` | fix by per-instance `std.Io.Mutex` |
| (State A only) compile error in unrelated code if anything transitively imports `oidc/jwks.zig` | none — verified zero callers | n/a |

---

## State transitions (n/a for DELETE)

If State B is chosen, the lock state machine is unchanged (single owner at a time,
uncontended fast path). The `cache_initialized: bool` flag transitions
`false → true` on `initCache` and `true → false` on `deinitCache`. No new states.

---

## Step 1 — Wire the file into a real test target first (mandatory pre-flight)

> **This step is identical for State A and State B. It is the empirical proof that the
> fix is real and that the build is now actively compiling the file.**

**Rationale:** the file is broken precisely because no compilation reaches it. A fix that
compiles while no compilation reaches the file is a fix to nothing. The pre-flight must
make the build RED, then the fix makes it GREEN, then we know the GREEN is genuine.

**Action for State A (DELETE path):**

1. Add `pub const jwks = @import("oidc/jwks.zig");` to `src/oidc_test_root.zig`.
2. Add `std.testing.refAllDecls(jwks);` and a wrapper call inside the existing `test {}`
   block: `try jwks.initCache(std.testing.allocator); defer jwks.deinitCache();`
3. Run `zig build test-oidc-src --summary all` — **expect RED** with the 5 errors.
4. Capture stdout/stderr to `scratch/_iss0173_wired_red.log` as evidence.
5. **DO NOT commit step 1 in isolation.** Step 1 is a transient wire-up that is reverted
   in the same commit as the fix (State A: delete the file + delete the test-root line;
   State B: rename + migrate + keep the test-root line).

**Action for State B (KEEP path):** the same five substeps, with the additional
constraint that the `test {}` body must exercise the **mutex path** via
`initCache`/`deinitCache` wrappers (not the underlying `TokenValidationCache.init` which
bypasses the module-level mutex). Per MUST-7 in the diagnosis, this is non-negotiable.

**Why the file is wired into `test-oidc-src` rather than a new target:** building a
new `addTest` target for one file is overhead and would create an `oidc-token-cache`
target that nobody runs. `test-oidc-src` already collects the other six `src/oidc/*.zig`
files and is on the regular `zig build test` path, so the file gets compiled on every
test run.

**Edge case — single-owner rule:** `oidc/jwks.zig` cannot simultaneously be a named module
in `build.zig` AND a relative member of `src/oidc_test_root.zig` in the same compilation.
Per the diagnosis and the comment block at `src/oidc_test_root.zig:18-22`, Zig enrolls
`test {}` blocks only from the root module's own file set, so reaching it by a named
module in `build.zig` would compile ZERO of its tests. **State A wires by relative
import only.** State B must do the same and not create a `jwks_mod` named module.

---

## Step 2 — Mechanical `ArrayList` unmanaged migration list

For State B only (State A deletes the file entirely). Each line below is one concrete
edit. The compiler will emit a specific error if any is missed; the list is exhaustive
against the source as of `25f6aaf7` (HEAD of `feature/WF03-GH501-20260808`).

### Site 1 — `jwks.zig:140` — `TokenValidationCache.evictExpired` local var
```diff
- var to_remove = std.ArrayList(TokenCacheKey).init(self.allocator);
+ var to_remove = std.ArrayList(TokenCacheKey).empty;
```
The allocator is moved to the `.deinit` and `.append` calls below — see sites 2 and 3.

### Site 2 — `jwks.zig:144` — `evictExpired` `to_remove.append` (swallow-error path)
```diff
- to_remove.append(.{
+ to_remove.append(self.allocator, .{
      .realm = entry.key_ptr.realm,
      .jti = entry.key_ptr.jti,
  }) catch continue;
```

### Site 3 — `jwks.zig:148` — `evictExpired` `defer to_remove.deinit`
```diff
- defer to_remove.deinit();
+ defer to_remove.deinit(self.allocator);
```

### Site 4 — `jwks.zig:164` — `TokenValidationCache.evictRealm` local var
```diff
- var to_remove = std.ArrayList(TokenCacheKey).init(self.allocator);
+ var to_remove = std.ArrayList(TokenCacheKey).empty;
```

### Site 5 — `jwks.zig:168` — `evictRealm` `to_remove.append` (swallow-error path)
```diff
- to_remove.append(.{
+ to_remove.append(self.allocator, .{
      .realm = entry.key_ptr.realm,
      .jti = entry.key_ptr.jti,
  }) catch continue;
```

### Site 6 — `jwks.zig:172` — `evictRealm` `defer to_remove.deinit`
```diff
- defer to_remove.deinit();
+ defer to_remove.deinit(self.allocator);
```

### Site 7 — `jwks.zig:194` — `collectRealmEntries` `list.append`
```diff
- try list.append(.{
+ try list.append(self.allocator, .{
      .realm = entry.key_ptr.realm,
      .jti = entry.key_ptr.jti,
  });
```
(`list` is a `*std.ArrayList(TokenCacheKey)` passed in by caller. Its allocator is the
caller's allocator — typically `self.allocator`. Confirm this is the case at the call
site; the file as written does not call `collectRealmEntries`, so this site is dead code
but still must compile.)

### Site 8 — `jwks.zig:239` — `JtiDenylist.init` field
```diff
- .entries = std.ArrayList(DenylistEntry).init(allocator),
+ .entries = std.ArrayList(DenylistEntry).empty,
```

### Site 9 — `jwks.zig:248` — `JtiDenylist.deinit` field
```diff
- self.entries.deinit();
+ self.entries.deinit(self.allocator);
```
(Site 247 `for (self.entries.items) |*e|` is unchanged — `items` access is the same on
managed and unmanaged forms.)

### Site 10 — `jwks.zig:265` — `JtiDenylist.add` field
```diff
- try self.entries.append(.{
+ try self.entries.append(self.allocator, .{
      .realm = try alloc.dupe(u8, realm),
      .jti = try alloc.dupe(u8, jti),
      .expires_at = expires_at,
  });
```
(Note: `alloc` is the per-call allocator parameter; `self.allocator` is the denylist's
allocator. The diagnosis at MUST-5 says use `self.allocator` for symmetry — but the
original code uses `alloc` because the caller may pass a different allocator. **Decision:
keep `alloc`** to preserve the existing dual-allocator pattern. Document this in the
post-fix commit message.)

### Sites explicitly NOT migrated

| Site | Why unchanged |
|---|---|
| `jwks.zig:127` `self.map.deinit()` | `std.HashMap` deinit signature did not change in Zig 0.16 |
| `jwks.zig:255,259` `self.entries.swapRemove(i)` | unmanaged `swapRemove` is identical to managed |
| `jwks.zig:269,272` `self.entries.items[i]` | `.items` is a slice field on both forms |
| `jwks.zig:284` `cache.evictExpired(now)` | method call on struct; no ArrayList involvement |

---

## Step 3 — Non-mechanical `std.Io.Mutex` refactor

For State B only. State A skips this entirely. State B threads an `io: std.Io`
parameter through every public wrapper.

### Why `std.Io.Mutex` and not a hand-rolled spinlock

| Option | Pros | Cons |
|---|---|---|
| `std.Io.Mutex.lockUncancelable` (chosen) | Same semantics as old `std.Thread.Mutex`; no async cancellation in hot path | Requires an `Io` parameter at every call site |
| `std.Io.Mutex.lock` | Allows cancellation points between calls | Hot-path overhead; cancellation points inside a cache lookup are pointless |
| `std.atomic` spinlock (hand-rolled) | No `Io` parameter needed | Recreates mutex from scratch; not the recommended pattern |
| Drop thread-safety entirely | No `Io` parameter; minimum lines changed | Violates ISS-402 contract — the cache MUST be thread-safe for production token validation |

**Decision: per-instance `std.Io.Mutex` + `lockUncancelable`.** Each public wrapper takes
`io: std.Io` as its first parameter and locks the per-instance mutex.

### Concrete edits

#### Edit M-1 — `jwks.zig:322` — replace module-level `std.Thread.Mutex`
```diff
- var cache_mutex: std.Thread.Mutex = .{};
- var oidc_cache: ?TokenValidationCache = null;
- var oidc_denylist: ?JtiDenylist = null;
- var cache_initialized: bool = false;
+ var oidc_cache: ?TokenValidationCache = null;
+ var oidc_denylist: ?JtiDenylist = null;
+ var cache_initialized: bool = false;
```
The module-level mutex is replaced by per-instance mutexes inside `TokenValidationCache`
and `JtiDenylist` (Edit M-2 and M-3). The module-level wrappers in §M-4 then take an Io
parameter and lock both per-instance mutexes in a deterministic order
(TokenValidationCache first, then JtiDenylist) to avoid deadlock if a future caller nests.

#### Edit M-2 — `TokenValidationCache` struct (around `jwks.zig:64-70`)
```diff
  pub const TokenValidationCache = struct {
      const Self = @This();

      allocator: std.mem.Allocator,
      map: std.HashMap(...),
+     mutex: std.Io.Mutex,

      pub fn init(allocator: std.mem.Allocator) Self {
          return .{
              .allocator = allocator,
              .map = std.HashMap(...).init(allocator),
+             .mutex = .init,
          };
      }
```
(`.init` here is the constant `std.Io.Mutex.init` of type `Mutex = .{ .state = .init(.unlocked) }`,
not a function call — verified at `lib/std/Io.zig:1591`.)

#### Edit M-3 — `JtiDenylist` struct (around `jwks.zig:227-237`)
```diff
  pub const JtiDenylist = struct {
      const Self = @This();

      allocator: std.mem.Allocator,
      entries: std.ArrayList(DenylistEntry),
+     mutex: std.Io.Mutex,

      pub fn init(allocator: std.mem.Allocator) Self {
          return .{
              .allocator = allocator,
              .entries = std.ArrayList(DenylistEntry).empty,
+             .mutex = .init,
          };
      }
```

#### Edit M-4 — every public wrapper in `jwks.zig:325..423`
Each wrapper adds `io: std.Io` as its first parameter and replaces
`cache_mutex.lock()` / `cache_mutex.unlock()` with `lockUncancelable(io)` / `unlock(io)`
on the appropriate per-instance mutex. Concretely:

```diff
- pub fn initCache(allocator: std.mem.Allocator) error{OutOfMemory}!void {
-     cache_mutex.lock();
-     defer cache_mutex.unlock();
+ pub fn initCache(io: std.Io, allocator: std.mem.Allocator) error{ OutOfMemory, std.Io.Cancelable }!void {
+     // No mutex needed — single-init by convention (cache_initialized flag).
+     _ = io;

      if (cache_initialized) return;
      oidc_cache = TokenValidationCache.init(allocator);
      oidc_denylist = JtiDenylist.init(allocator);
      cache_initialized = true;
  }
```
`initCache` and `deinitCache` are conventionally called once at startup/shutdown with no
concurrent access; the per-call mutex is unnecessary. They still take `io` for signature
uniformity (the caller already has an `io`; passing it is free).

For the others, the pattern is:
```zig
pub fn checkCache(io: std.Io, realm: []const u8, jti: []const u8, now: i64) ?CachedValidation {
    const cache_ptr = oidc_cache orelse return null;
    cache_ptr.mutex.lockUncancelable(io);
    defer cache_ptr.mutex.unlock(io);
    return cache_ptr.get(realm, jti, now);
}
```
And analogous edits for `putCache`, `isRevoked`, `revokeToken`, `revokeRealmTokens`,
`evictExpired`. The complete edit list:

| Wrapper | Action |
|---|---|
| `initCache` (jwks.zig:329) | add `io: std.Io` parameter; remove `cache_mutex` calls; `_ = io;` |
| `deinitCache` (jwks.zig:340) | add `io: std.Io` parameter; remove `cache_mutex` calls; `_ = io;` |
| `checkCache` (jwks.zig:351) | add `io`; lock `oidc_cache.?.mutex.lockUncancelable(io)`; defer unlock |
| `putCache` (jwks.zig:362) | add `io`; same lock pattern on `oidc_cache.?` |
| `isRevoked` (jwks.zig:376) | add `io`; lock `oidc_denylist.?.mutex.lockUncancelable(io)`; defer unlock |
| `revokeToken` (jwks.zig:386) | add `io`; lock `oidc_denylist.?` then `oidc_cache.?` in order |
| `revokeRealmTokens` (jwks.zig:399) | add `io`; lock `oidc_cache.?` then `oidc_denylist.?` in order |
| `evictExpired` (jwks.zig:413) | add `io`; lock both |

#### Lock-ordering invariant

Whenever both caches are touched in the same wrapper, lock **TokenValidationCache first,
then JtiDenylist**. This is the order used in `revokeRealmTokens` today (cache first to
find active JTIs, then denylist to add). Document this as an invariant in the file's
header comment.

#### Internal methods that don't need Io

`TokenValidationCache.get`, `.put`, `.evictExpired`, `.evictRealm`, `.iterate`,
`JtiDenylist.isRevoked`, `.evictExpired` are called from inside the wrappers, which
already hold the per-instance mutex. They do NOT take `io` (passing it through adds
no value because the mutex is held). The in-file tests at jwks.zig:438..538 call
`TokenValidationCache.init(allocator)` and `JtiDenylist.init(allocator)` directly —
which is fine; their per-instance mutex starts in `.unlocked` state.

### Why this is non-mechanical

This refactor touches **every public wrapper** (8 wrappers) plus two struct definitions
and changes the public API surface of the module. It cannot be done by `zig fmt` or a
textual substitution; it requires a deliberate decision on lock ordering, on which
methods take `io`, and on whether to expose `initCache` as cancelable. The compiler will
catch missing `io` parameters (the lock signature forces it), but the lock-ordering
discipline is human.

---

## Step 4 — Orphan fate decision (delete vs rename vs rewire)

### Option matrix

| Option | Lines changed | Risk | Outcome |
|---|---|---|---|
| **A — DELETE** (recommended) | +1, -1 (`main.zig:78`); -538 (`jwks.zig`); -1 (`oidc_test_root.zig` wire-up) | Zero — no caller exists. ISS-402 feature is silently dropped but it was never wired in to begin with. | File gone; re-export gone; ISS-402 stays in git history. |
| B — KEEP + RENAME to `src/oidc/token_cache.zig` (SHOULD-1) | +1, -1 (`main.zig:78`); rename; ArrayList migration (§2, 10 edits); Io mutex refactor (§3, 12 edits); wire into `oidc_test_root.zig`; add `jwks_mod` only if a separate target is created | Medium — preserves intent but adds ~22 deliberate edits; every future caller must thread `io`; the file remains orphaned because no caller reaches the renamed version either | File survives with thread-safe API; future intent can wire it. |
| C — KEEP + REWIRE a caller | same as B plus finding/creating a real caller | High — would expand GH-501's scope beyond the reported defect; ISS-402 has no design doc to anchor a real caller | Out of scope for this WF-03 run |

### Decision: **A — DELETE**

**Rationale:**

1. **Zero callers** — the workspace grep at diagnosis time returned only `src/main.zig:78`
   itself. Deleting the file and the re-export is functionally a no-op.
2. **ISS-402 was never completed** — the file was added in PR #94 but never wired into
   any call path. The token validation flow today does NOT use this cache; the cache is
   dead code.
3. **ISS-402 remains in git history** — if a future intent wants the token-validation
   cache, the entire file is recoverable from `git log -- src/oidc/jwks.zig`. The fix
   preserves the design history without carrying the broken bytes forward.
4. **Smaller surface area** — State B would commit ~22 deliberate edits + a renaming +
   an Io threading change. Each is a non-trivial decision that risks introducing new
   bugs. State A is two single-line deletions.
5. **The diagnosis explicitly flagged this** — MUST-8 option (a) is the recommendation;
   option (b) is the fallback only if a caller is found during the implementation step.

### Concrete edits for State A

| File | Edit |
|---|---|
| `src/main.zig:78` | DELETE the line `pub const oidc_jwks = @import("oidc/jwks.zig"); // ISS-402 OIDC token cache and JTI denylist` |
| `src/oidc/jwks.zig` | DELETE the file (entire 538 lines) |
| `src/oidc_test_root.zig` | DO NOT add the wire-up (no need — file is gone) |

### Validation for State A

```bash
zig build                     # must exit 0
zig build test                # must exit 0 (test count unchanged)
zig build test-oidc-src       # must exit 0 (test count unchanged from 25/30 baseline)
grep -rn "oidc_jwks\|oidc/jwks" src/ tests/ web/  # must return zero hits
```

If `grep` returns any hits: STOP, escalate, do not delete. The grep is the gate.

### Pre-flight (mandatory — re-verify before deleting)

BACKEND-DEV must run this command sequence in this exact order:

```bash
# 1. Confirm zero callers in current HEAD
Get-ChildItem -Recurse -Include "*.zig","*.ts","*.tsx" |
  Where-Object { $_.FullName -notmatch 'zig-out|zig-pkg|.venv|node_modules|vendor' } |
  Select-String -Pattern "\boidc_jwks\b" |
  Tee-Object -FilePath scratch/_iss0173_preflight_callers.txt
# Expect: ONLY src/main.zig:78 — that is the re-export, not a caller.

# 2. Confirm no test imports it
Get-ChildItem tests -Recurse -Include "*.zig" |
  Select-String -Pattern "oidc/jwks|oidc_jwks" |
  Tee-Object -FilePath scratch/_iss0173_preflight_tests.txt
# Expect: zero hits.

# 3. Confirm build is GREEN before any edit (baseline)
zig build 2>&1 | Tee-Object -FilePath scratch/_iss0173_preflight_build.log
# Expect: exit 0
```

If all three match the expected output: proceed with the deletion. If any differs:
STOP, do not delete, escalate to ORCH.

---

## Step 5 — Deliberate-mutation regression test plan

The ISS-0172 acceptance criterion (mirrored in ISS-0173 / GH-500's deliberate-mutation
verification) requires proving the build is genuinely compiling the affected code. The
test plan has three phases.

### Phase 1 — RED proof (State A's wire-up is unnecessary because the file is being deleted; this phase applies to State B only)

If State B is chosen: before applying the fix, inject `const _x: u32 = "not an int";`
inside `initCache` (between the function signature and the `cache_mutex.lock();` line).
Run `zig build test-oidc-src`. Confirm RED with a type error. Capture stdout/stderr to
`scratch/_iss0173_mut_red.log`. Revert the mutation.

This phase proves the test target compiles `jwks.zig` (or `token_cache.zig`).

### Phase 2 — GREEN proof

After the fix is applied:

1. `zig build` exits 0.
2. `zig build test-oidc-src` exits 0 with the same test count as the baseline (25/30 PASS,
   5 SKIP) — State A path. State B: +16 PASS if the in-file tests are collected.

### Phase 3 — Deliberate mutation to confirm the fix is being exercised

State A path: after deletion, the orphan cannot rot again because the file is gone.
**Deliberate mutation target: the deleted re-export line.** Re-add a dummy
`pub const oidc_jwks = @import("oidc/jwks.zig");` to `src/main.zig` (with the file
absent). Run `zig build` — must be RED with "file not found" or similar. This proves
the build path is alive; revert immediately.

State B path: after the migration, inject `const _y: u32 = "not an int";` inside
`initCache`. Run `zig build test-oidc-src` — must be RED. Revert. Capture
`scratch/_iss0173_mut2_red.log` as evidence the mutex path is now compiled.

### Evidence to capture

| Evidence | Path | Captured when |
|---|---|---|
| Pre-flight caller grep | `scratch/_iss0173_preflight_callers.txt` | before deletion |
| Pre-flight test grep | `scratch/_iss0173_preflight_tests.txt` | before deletion |
| Pre-flight build log | `scratch/_iss0173_preflight_build.log` | before deletion |
| Post-deletion build log | `scratch/_iss0173_postdel_build.log` | after deletion |
| Post-deletion test-oidc-src | `scratch/_iss0173_postdel_oidcsrc.log` | after deletion |
| Re-add-re-export RED log | `scratch/_iss0173_readd_red.log` | Phase 3 of State A |

---

## Step 6 — Classification per `templates/lego-catalog.md`

The diagnosis's fix plan did not ask for a lego-catalog classification, but a fix design
that touches multiple types of work (build wiring, ArrayList migration, mutex refactor,
deletion, regression test) benefits from explicit classification so BACKEND-DEV can match
the right codegen template (or skip it for novel edits).

### Per-deliverable classification

| Deliverable | Lego type | Codegen template? | Time budget |
|---|---|---|---|
| Step 1 — wire file into test target | n/a (test infrastructure) | none — manual edit to `oidc_test_root.zig` | 5 min |
| Step 2 — ArrayList unmanaged migration | n/a (mechanical find/replace) | none — 10 textual edits | 5 min |
| Step 3 — Io.Mutex refactor | **Type E (novel — cross-cutting)** | none — design-driven; 12 edits with deliberate lock-ordering decisions | 30 min |
| Step 4 — orphan fate | **Type E (novel — architectural decision)** | none — DELETE decision is documented in this artefact | 10 min |
| Step 5 — deliberate-mutation regression | n/a (test infrastructure) | none — manual `zig build` runs with captures | 10 min |

**The fix is entirely Type E (novel work)** — there is no Type A/B/C/D parameter file
applicable. The reason: every change is either a textual mechanical migration (which
the lego catalog explicitly says is "Type E — novel business logic" if not a CRUD/migration/
React-Flow/list-page pattern) or a deliberate cross-cutting architectural decision
(orphan fate; Io threading). Type E is correct for this run.

### What this means for BACKEND-DEV

- Do **not** run any `codegen_*.py` script.
- Edit files directly. The fixes are precise text replacements described in §2 (ArrayList)
  and §3 (mutex), plus a two-line deletion for §4 (orphan fate).
- Do **not** edit `templates/specs/*.yaml` — this run has no parameter files.
- The artefacts for `artifacts_out` are: this design file (`src/design/iss0173-gh501-jwks-zig016-fix.md`)
  and the deletion diff (covered by the post-fix commit message).

---

## Open questions

1. **Lock ordering under future composition** — State B commits to "cache first, denylist
   second" if both are touched. If a future caller adds a denylist→cache path, that
   violates the invariant. Recommend documenting this in the file header. **Out of scope
   for GH-501; deferred until a caller exists.**

2. **`initCache` / `deinitCache` taking `io`** — these are conventionally called once at
   startup; passing `io` is for signature uniformity. An alternative is to make them
   `io`-less and have them assume a static global. The current design takes the
   uniform-signature path; if `initCache` is ever called inside a hot path with a
   cancellable Io, this matters. State A sidesteps the question entirely.

3. **Cancellation propagation** — `lockUncancelable` is the right choice for cached
   lookups (no cancellation point inside the lock). If the cache ever holds an `Io`
   that can be cancelled mid-iteration (it doesn't today), `lock` would be required.
   State A sidesteps.

4. **Recovery from accidental resurrection** — if a future engineer resurrects ISS-402
   by `git checkout HEAD~ -- src/oidc/jwks.zig`, the same five errors return and the
   build stays green (because nothing compiles the file). This is the same blind spot
   the diagnosis documents. **Recommendation: file a follow-up ISS-0174 for a lint that
   detects orphan `pub const X = @import(...)` re-exports in `src/main.zig`** (SHOULD-2
   from the diagnosis). Out of scope for this run.

---

## Decision summary

| Aspect | Decision |
|---|---|
| **Fate of `src/oidc/jwks.zig`** | DELETE (State A) |
| **Fate of `src/main.zig:78`** | DELETE the re-export line |
| **Fate of `src/oidc_test_root.zig`** | NO CHANGE (no wire-up added; the orphan is gone) |
| **Mechanical ArrayList migration** | NOT APPLICABLE — file is deleted |
| **std.Io.Mutex refactor** | NOT APPLICABLE — file is deleted |
| **Regression test** | Phase 3 deliberate-mutation: re-add the re-export line and confirm RED, then revert |
| **Lego classification** | Type E (novel — no codegen) |
| **Follow-up issues to file** | ISS-0174: linter for dead `pub const X = @import(...)` re-exports in `src/main.zig` (SHOULD-2) |

---

## References

- Diagnosis: [docs/issue-reports/ISS-0173-gh501-diagnosis.yaml](docs/issue-reports/ISS-0173-gh501-diagnosis.yaml)
- Local issue: [docs/issues/ISS-0173.json](docs/issues/ISS-0173.json)
- GitHub: <https://github.com/tvolodi/R-Co/issues/501>
- Sibling design (parent class — pin-form blind spot): [src/design/iss-0619-group-tasks-fix.md](src/design/iss-0619-group-tasks-fix.md)
- Lego catalog: [templates/lego-catalog.md](templates/lego-catalog.md)
- Design artefact format: [docs/guides/backend_developer_guide.md §7](docs/guides/backend_developer_guide.md)
- Zig 0.16 stdlib: `C:/Users/tvolo/AppData/Local/Microsoft/WinGet/Packages/zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe/zig-x86_64-windows-0.16.0/lib/std/Io.zig:1587-1648`
