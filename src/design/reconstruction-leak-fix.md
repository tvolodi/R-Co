# Reconstruction Memory Leak Fix — Design

**Issue:** ISS-0601-RECON-LEAK  
**Severity:** MAJOR  
**Scope:** `src/engine/reconstruction.zig`  
**Classification:** Type E (novel/cross-cutting)

---

## Module Purpose

This design fixes two memory leak patterns in the event reconstruction module:

1. **Dangling key references** — ObjectMap keys borrowed from temporary ArenaAllocator become invalid after the arena is freed
2. **Unreleased values** — JsonValue objects stored in ObjectMap are never freed when the map is cleaned up

The fix introduces proper key duplication and a centralized cleanup helper to ensure all allocated memory is properly released.

---

## Root Cause Analysis

### The Key Lifetime Problem

Current code at line 851 (`parseObjectMapFromJson`):
```zig
result.put(allocator, key, cloned_value)
```

The `key` string is a slice from the source ObjectMap, which was parsed using an ArenaAllocator in `deserializeInstanceState` (line 661). When the function returns, `defer arena.deinit()` at line 662 frees the entire arena, **invalidating all key strings** in the returned ObjectMap.

Result: **use-after-free** — keys become dangling pointers to freed memory.

Same issue exists at line 904 (`cloneJsonValue` for nested objects):
```zig
new_obj.put(allocator, entry.key_ptr.*, cloned)
```

### The Value Cleanup Problem

Current code at line 925-927 (`freeJsonValue` .object case):
```zig
var it = obj.iterator();
while (it.next()) |entry| freeJsonValue(allocator, entry.value_ptr.*);
obj.deinit(allocator);
```

`obj.deinit(allocator)` only frees the ObjectMap's internal hash table bookkeeping. The **keys themselves are never freed**, leaking every key string in the map.

Additionally, tests call `variables.deinit(allocator)` directly without freeing the JsonValue objects first, causing all cloned values to leak.

---

## Why Arena Allocator Approach Failed

Previous rework attempts (WF03-gh406 rework 2/3) tried using ArenaAllocator as the persistent allocator for the entire InstanceState.

**Problem:** When `arena.deinit()` was called, ALL memory was freed at once, including memory still referenced by the InstanceState struct (tokens, variables, join_counters). Subsequent accesses touched freed memory → 131-142 test failures with segfaults.

**Lesson:** ArenaAllocator can only be used for **temporary** parsing buffers. All data that outlives the parsing phase must be allocated with the persistent allocator and explicitly managed.

---

## Memory Ownership Model

**Current (BROKEN):**
- ObjectMap keys: borrowed from arena (freed at function return) → **use-after-free**
- ObjectMap values: owned by persistent allocator (never freed) → **leak**
- Map structure: owned by persistent allocator (freed by `.deinit()`)

**Required (CORRECT):**
- ObjectMap keys: owned by persistent allocator → **must duplicate before `put()`**
- ObjectMap values: owned by persistent allocator → **must free before map cleanup**
- Map structure: owned by persistent allocator (freed by `.deinit()`)

---

## Public Interface Changes

### New Helper Function: `freeObjectMap`

```zig
/// Free all keys and values in a JsonValue ObjectMap, then deinit the map.
/// This is the REQUIRED cleanup pattern for ObjectMaps populated by
/// parseObjectMapFromJson or cloneJsonValue.
///
/// Usage in application code:
///   defer freeObjectMap(allocator, reconst_state.variables);
///
/// Usage in test code:
///   freeObjectMap(alloc, reconst_state.variables);
///   freeObjectMap(alloc, reconst_state.join_counters);
pub fn freeObjectMap(
    allocator: std.mem.Allocator,
    map: std.json.ObjectMap,
) void
```

**Behavior:**
1. Iterate over all entries in the map
2. Free each key string (allocated via `allocator.dupe()`)
3. Free each value via `freeJsonValue()` (recursive for nested objects/arrays)
4. Call `map.deinit(allocator)` to free the map structure itself

**Why public:** Tests need to call this function to properly clean up reconstructed state. Making it public avoids duplicating cleanup logic in test code.

---

## Modified Function Signatures

No function signatures change. The modifications are internal implementation details:

### `parseObjectMapFromJson` (line 839)
```zig
fn parseObjectMapFromJson(
    allocator: std.mem.Allocator,
    source: std.json.ObjectMap,
) error{OutOfMemory}!std.json.ObjectMap
```
**Change:** Duplicate keys before `put()` call.

### `cloneJsonValue` (line 863)
```zig
fn cloneJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) error{OutOfMemory}!std.json.Value
```
**Change:** In `.object` case, duplicate keys before `put()` call.

### `freeJsonValue` (line 919)
```zig
fn freeJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) void
```
**Change:** In `.object` case, free keys before calling `obj.deinit()`.

---

## Data Flow Changes

### Before (BROKEN):

```
deserializeInstanceState(persistent_alloc, ...)
  ├─ arena = ArenaAllocator.init(persistent_alloc)
  ├─ parsed = std.json.parseFromSlice(..., arena.allocator(), ...)
  ├─ parseObjectMapFromJson(persistent_alloc, parsed.value.object.get("variables"))
  │   └─ result.put(persistent_alloc, key, cloned_value)  // key from arena!
  └─ defer arena.deinit()  // <- FREES ALL KEYS IN RESULT MAP
       └─ RETURN result with dangling key pointers
```

### After (CORRECT):

```
deserializeInstanceState(persistent_alloc, ...)
  ├─ arena = ArenaAllocator.init(persistent_alloc)
  ├─ parsed = std.json.parseFromSlice(..., arena.allocator(), ...)
  ├─ parseObjectMapFromJson(persistent_alloc, parsed.value.object.get("variables"))
  │   ├─ key_duped = persistent_alloc.dupe(u8, key)  // COPY from arena
  │   └─ result.put(persistent_alloc, key_duped, cloned_value)
  └─ defer arena.deinit()  // frees temporary JSON tree only
       └─ RETURN result with valid keys in persistent_alloc
```

---

## Error Handling Strategy

### Key Duplication Failure

```zig
const key_duped = allocator.dupe(u8, key) catch return error.OutOfMemory;
result.put(allocator, key_duped, cloned_value) catch {
    allocator.free(key_duped);          // Free the key we just allocated
    freeJsonValue(allocator, cloned_value);  // Free the value
    return error.OutOfMemory;
};
```

**Critical:** If `put()` fails after we've allocated the key, we MUST free both the key and the value before returning the error. Otherwise they leak.

### Nested Object Cleanup

In `cloneJsonValue` .object case, the existing `errdefer` block already handles partial cleanup of values. We extend it to also clean up keys:

```zig
errdefer {
    var it2 = new_obj.iterator();
    while (it2.next()) |e| {
        allocator.free(e.key_ptr.*);  // NEW: free keys
        freeJsonValue(allocator, e.value_ptr.*);
    }
    new_obj.deinit(allocator);
}
```

---

## Test Cleanup Pattern

### Old Pattern (LEAKS):
```zig
reconst_state.variables.deinit(alloc);
reconst_state.join_counters.deinit(alloc);
```

### New Pattern (CORRECT):
```zig
freeObjectMap(alloc, reconst_state.variables);
freeObjectMap(alloc, reconst_state.join_counters);
```

**Locations to update:**
- `tests/integration/iss601_state_snapshots_test.zig:312-313`
- `tests/integration/iss601_state_snapshots_test.zig:906-907`

---

## Dependencies

### Internal Dependencies
- `std.mem.Allocator` — all manual memory management
- `std.json.ObjectMap` — map structure
- `std.json.Value` — value types
- `freeJsonValue` — recursive value cleanup (already exists, will be modified)

### External Dependencies
None. This is a pure memory management fix within the reconstruction module.

---

## State Transitions

No state machine changes. The fix only affects memory lifecycle management:

**Allocation:**
```
arena-allocated key → duplicate to persistent allocator → store in ObjectMap
```

**Cleanup:**
```
freeObjectMap() → free each key → free each value (via freeJsonValue) → deinit map structure
```

---

## Error Taxonomy

All existing error returns remain unchanged:
- `error.OutOfMemory` — propagated from `allocator.dupe()` and `map.put()`

No new error cases introduced. The fix only changes *when* cleanup happens (on success path, not just error path).

---

## Open Questions

None. The diagnosis is complete and the fix approach is straightforward.

---

## Prevention Rules

**Rule 1:** Never use arena-allocated strings as keys in persistent ObjectMaps.

**Rule 2:** Always duplicate strings when crossing allocator boundaries:
```zig
const key_duped = persistent_alloc.dupe(u8, arena_key) catch ...;
```

**Rule 3:** `ObjectMap.deinit()` alone is NOT sufficient cleanup — must free keys and values first.

**Rule 4:** Use `freeObjectMap()` helper for all JsonValue ObjectMap cleanup:
```zig
var map = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch ...;
defer freeObjectMap(allocator, map);  // NOT just map.deinit(allocator)
```

**Rule 5:** In tests, always pair ObjectMap allocations with proper cleanup in `defer` blocks.

---

## Verification

**Command:**
```bash
zig build test-integration-iss601
```

**Before fix:** 6,976 leaks; exit code 1  
**After fix:** 0 leaks; exit code 0

All 8 tests in `iss601_state_snapshots_test.zig` must pass with zero memory leaks reported by `GeneralPurposeAllocator`.
