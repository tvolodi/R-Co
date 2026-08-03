# Module: definition-leak-fix

## Module purpose
Fixes memory leak in Definition struct by adding an explicit cleanup method. Every Definition loaded with graph_json causes parseGraphJson to allocate strings (node IDs, labels, attributes, edge IDs, sources, targets, conditions, transforms) without a matching free. The Definition struct currently has no deinit method, so callers are unaware they must free these allocations. This design adds Definition.deinit(allocator) to make cleanup explicit and compiler-enforceable via defer statements.

## Root cause
parseGraphJson (src/definition/store.zig:1344-1391) performs allocator.dupe() on 8 different fields per graph node/edge:
- Node fields: id (required), label (optional), attributes (optional)
- Edge fields: id, source, target (all required), condition (optional), transform (optional)
- Plus 2 array allocations: nodes array, edges array

rowToDefinition (src/definition/store.zig:1396+) also allocates name, version, description, stage strings separately.

These allocations are embedded in the returned Definition struct. Neither Definition nor DefinitionGraph currently has a deinit method, so cleanup depends on callers manually invoking freeDefinition() or freeDefinitionGraph() — a requirement that is neither documented nor enforced.

Audit of 100+ call sites found only 1 caller (src/api/routes/definitions.zig:80 handleGetById) properly cleans up. All other load sites leak.

## Zig source files
- src/definition/graph.zig (change): Add Definition.deinit() method to existing Definition struct
- src/definition/store.zig (change): Add deinit calls to freeDefinition and freeDefinitionGraph functions (maintain backward compatibility)
- src/api/routes/definitions.zig (change): Replace manual freeDefinition call with defer def.deinit(allocator) in handleGetById; add defer statements to all other handlers
- tests/integration/iss601_state_snapshots_test.zig (change): Add defer def.deinit(allocator) statements after every create/getById/activate call
- tests/integration/definition_test.zig (change): Add defer statements to all Definition load sites
- Any other test or implementation file with Definition load calls (audit required)

## Public interface additions

### src/definition/graph.zig

Add to existing Definition struct (line ~87):

```zig
pub fn deinit(self: Definition, allocator: std.mem.Allocator) void
```

**Behavior:** Frees all allocated memory owned by this Definition. Must be called with the same allocator used to create the Definition. The method is idempotent and safe to call on partially-initialized Definitions.

**What it frees:**
- Top-level string fields: name, version
- Optional string fields: description (if non-null), stage (if non-null)
- All graph allocations via self.graph.deinit(allocator)

Add to existing DefinitionGraph struct (line ~81):

```zig
pub fn deinit(self: DefinitionGraph, allocator: std.mem.Allocator) void
```

**Behavior:** Frees all allocated memory owned by this DefinitionGraph. Must be called with the same allocator used to parse the graph.

**What it frees:**
- Each node's allocated strings: id (required), label (optional), attributes (optional)
- The nodes array itself
- Each edge's allocated strings: id, source, target (all required), condition (optional), transform (optional)
- The edges array itself

## Changes to existing cleanup functions

### src/definition/store.zig

**freeDefinitionGraph:** Update to delegate to DefinitionGraph.deinit. This maintains backward compatibility for any existing callers.

**freeDefinition:** Update to delegate to Definition.deinit. This maintains backward compatibility for any existing callers.

Both functions remain as thin wrappers around the new deinit methods, preserving the existing public API while standardizing on the idiomatic Zig deinit pattern internally.

## Migration strategy for existing call sites

Every site that loads a Definition must add a defer statement immediately after the load call:

**Before (leaking):**
```zig
const def = try store.getById(allocator, id);
// ... use def ...
// leaked on function return
```

**After (correct):**
```zig
const def = try store.getById(allocator, id);
defer def.deinit(allocator);
// ... use def ...
// automatically freed when scope exits
```

**Before (manual cleanup — old style):**
```zig
const def = try store.getById(allocator, id);
defer freeDefinition(allocator, def);
```

**After (idiomatic Zig — preferred):**
```zig
const def = try store.getById(allocator, id);
defer def.deinit(allocator);
```

This pattern applies to all Definition-returning functions:
- store.create(...)
- store.getById(...)
- store.getByName(...)
- store.getActiveByName(...)
- store.activate(...)

## Call sites requiring changes (non-exhaustive)

**Confirmed leaking sites from diagnosis:**
- tests/integration/iss601_state_snapshots_test.zig:189 (TC-ISS-601-01)
- tests/integration/iss601_state_snapshots_test.zig:201 (TC-ISS-601-01)
- tests/integration/iss601_state_snapshots_test.zig:659 (TC-ISS-601-05)
- tests/integration/iss601_state_snapshots_test.zig:904
- tests/integration/iss601_state_snapshots_test.zig:1063
- src/api/routes/definitions.zig:182 (handleGetByActiveRoute)
- src/api/routes/definitions.zig:324 (handleCreate)
- src/api/routes/definitions.zig:485 (handleUpdate)
- src/api/routes/definitions.zig:572 (handleActivate)

**Already correct (will convert to new style):**
- src/api/routes/definitions.zig:80 (handleGetById) — currently uses `defer freeDefinition(allocator, def)`

**Additional sites (requires full codebase grep):**
All call sites matching pattern: `store\.(create|getById|getByName|getActiveByName|activate)\(`

## Error taxonomy
None required. The deinit method is infallible. All allocator.free() operations are guaranteed to succeed when passed valid pointers obtained from the same allocator.

The method is safe to call on partially-initialized Definitions because it explicitly checks optional fields (description, stage) before freeing.

## Key invariants
1. **Matching allocator:** Definition.deinit MUST be called with the same allocator that was passed to the store method that created the Definition. Passing a different allocator is undefined behavior.

2. **Single deinit:** Each Definition must be deinit'd exactly once. Calling deinit twice on the same Definition is undefined behavior (double-free).

3. **Ownership transfer forbidden:** Do not pass a Definition by value after the original owner has deinit'd it. The Definition is invalidated after deinit.

4. **defer pattern:** Always use `defer def.deinit(allocator)` immediately after the load call. Never conditionally deinit based on control flow — defer ensures cleanup even on early return/error propagation.

## Testing approach

### Immediate verification (ISS-0601-LEAK-001 acceptance)
Run tests/integration/iss601_state_snapshots_test.zig with leak checking enabled after adding defer statements to all Definition loads in that file:

```bash
zig build test-integration-iss601
```

Expected result: Zero leaks reported for TC-ISS-601-01 and TC-ISS-601-05 (previously reported 48 and 42 leaks respectively).

### Full regression verification
After updating all known call sites, run the full integration test suite with leak checking:

```bash
zig build test-integration
```

Expected result: Zero memory leaks across all integration tests.

### Audit completeness
Grep the codebase for all Definition load patterns:

```bash
rg -t zig "store\.(create|getById|getByName|getActiveByName|activate)\(" src/ tests/
```

For each match, verify a corresponding `defer def.deinit(allocator)` exists on the following line (or within the same block before any control flow that could skip cleanup).

## Dependencies
- src/definition/graph.zig (modified)
- src/definition/store.zig (modified, but maintains backward compatibility)
- All callers of Definition-returning functions (modified to add defer statements)

## Open questions
None. The design is straightforward: add deinit methods to Definition and DefinitionGraph, then systematically add defer statements at all load sites.

## Alternative strategies considered (from diagnosis)

### Strategy 2: Arena allocator
Instead of explicit deinit, use an ArenaAllocator per Definition:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const def = try store.getById(arena.allocator(), id);
// All allocations freed by arena.deinit()
```

**Rejected because:**
- Requires changing all store function signatures to accept arena allocator
- More invasive than Strategy 1
- Arena grows with Definition size, wasteful for short-lived uses
- Still requires caller discipline (create arena, defer deinit)
- Does not eliminate the need for caller awareness

### Strategy 3: Ownership transfer
Change Definition to own an allocator pointer and free itself on scope exit.

**Rejected because:**
- Violates Zig idiom (structs do not own allocators)
- Makes Definition non-copyable
- Requires fundamental restructuring of the Definition API
- Does not work with stack-allocated Definitions

**Strategy 1 (this design) is preferred:** Minimal API surface change, idiomatic Zig pattern, compiler-checkable via defer.

## Implementation checklist

1. Add DefinitionGraph.deinit() method to src/definition/graph.zig
2. Add Definition.deinit() method to src/definition/graph.zig
3. Update freeDefinitionGraph to delegate to DefinitionGraph.deinit
4. Update freeDefinition to delegate to Definition.deinit
5. Add defer statements to all Definition load sites in tests/integration/iss601_state_snapshots_test.zig
6. Verify zero leaks in iss601 test: `zig build test-integration-iss601`
7. Add defer statements to all Definition load sites in src/api/routes/definitions.zig
8. Add defer statements to all Definition load sites in tests/integration/definition_test.zig
9. Grep for remaining call sites: `rg -t zig "store\.(create|getById|getByName|getActiveByName|activate)\(" src/ tests/`
10. Add defer statements to all remaining call sites found in step 9
11. Run full integration test suite: `zig build test-integration`
12. Verify zero memory leaks across all tests
