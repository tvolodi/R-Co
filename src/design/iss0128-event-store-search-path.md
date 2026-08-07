# ISS-0128 Fix Design: event_store search_path Transaction Guard

## Purpose

Apply transaction-scoped search_path protection to `event_store/store.zig::append()` to eliminate the pooled-connection search_path race condition that causes `StoreError.InstanceNotFound` when querying `instance_projections`.

## Root Cause

`append()` opens a transaction with `BEGIN` (line 306) but does not issue `SET LOCAL search_path` before executing unqualified queries. When the acquired connection carries stale session-level `search_path` from prior pool usage, the unqualified query at line 320:

```zig
"SELECT status FROM instance_projections WHERE instance_id = $1"
```

resolves against the wrong schema, returns 0 rows, and triggers `InstanceNotFound` even when the instance exists in the correct tenant schema.

## Resolution Strategy

Apply the ISS-0130 pattern (PR #531, `src/db/migrations.zig:424-447`): immediately after `BEGIN`, issue `SET LOCAL search_path TO <schema>,public` to guarantee correct schema visibility for all subsequent queries in the transaction. `SET LOCAL` is transaction-scoped and auto-resets on `COMMIT`/`ROLLBACK`, so it never leaks across pool boundaries.

## Module Affected

- **File**: `src/event_store/store.zig`
- **Function**: `append()`
- **Lines**: Insert new code between lines 306-307 (after `BEGIN`, before `errdefer`)

## Public Interface

No changes to public interface. The fix is internal to `append()`:

```zig
pub fn append(
    self: *Store,
    allocator: std.mem.Allocator,
    params: AppendParams,
) StoreError!AppendResult
```

`AppendParams` already includes `tenant_id: []const u8`, which provides the input for schema name derivation.

## Data Flow

```
1. append() acquires pooled connection (line 279-282)
   ├─ Connection may have stale session-level search_path
   └─ Calling SET search_path on acquire (pool.zig:258) is necessary but not sufficient

2. BEGIN transaction (line 306)
   └─ Opens transaction boundary but does NOT reset search_path

3. [NEW] SET LOCAL search_path TO <schema>,public
   ├─ Derive schema name from params.tenant_id via db.schemaNameForTenant
   ├─ Construct SET LOCAL statement via std.fmt.bufPrint
   ├─ Execute SET LOCAL; ROLLBACK on failure
   └─ Transaction-scoped; auto-resets at COMMIT/ROLLBACK

4. [EXISTING] pipeline_run_id set_config (lines 309-315, conditional)
   └─ Unchanged

5. [EXISTING] instance_projections query (line 320)
   └─ Now guaranteed to resolve against correct schema
   └─ Will find the instance row if it exists

6. [EXISTING] Remainder of transaction (sequence lock, validation, INSERT)
   └─ All unqualified queries benefit from SET LOCAL
```

## Implementation Pseudo-code

Insert immediately after line 306 (`conn.exec("BEGIN", &.{})`):

```zig
// BEGIN
conn.exec("BEGIN", &.{}) catch return StoreError.TransactionFailed;
errdefer conn.exec("ROLLBACK", &.{}) catch {};

// ISS-0128: SET LOCAL search_path TO <schema>,public
// Transaction-scoped protection against stale session-level search_path
// on pooled connections. Pattern from ISS-0130 (PR #531, migrations.zig).
const db_mod = @import("pool");
var schema_buf: [80]u8 = undefined;
const schema_name = db_mod.schemaNameForTenant(params.tenant_id, &schema_buf);

var set_path_buf: [128]u8 = undefined;
const set_path_sql = std.fmt.bufPrint(
    &set_path_buf,
    "SET LOCAL search_path TO {s},public",
    .{schema_name},
) catch {
    conn.exec("ROLLBACK", &.{}) catch {};
    return StoreError.TransactionFailed;
};

conn.exec(set_path_sql, &.{}) catch {
    conn.exec("ROLLBACK", &.{}) catch {};
    return StoreError.TransactionFailed;
};

// [EXISTING] pipeline_run_id set_config (conditional)
if (effective_pipeline_run_id.len > 0) {
    // ... unchanged ...
}
```

### Key Implementation Details

1. **Import**: `const db_mod = @import("pool");` may already exist at module level; verify before adding
2. **Stack allocation**: `schema_buf` and `set_path_buf` are stack-allocated; safe for this hot path
3. **Schema derivation**: 
   - `params.tenant_id = "00000000-0000-0000-0000-000000000000"` → `"tenant_default"`
   - Non-default UUID → `"tenant_<uuid_without_hyphens>"`
4. **Error handling**: On any failure (bufPrint or exec), ROLLBACK and return TransactionFailed
5. **Placement**: Must execute AFTER BEGIN, BEFORE any query, BEFORE pipeline_run_id set_config

## Error Taxonomy

No new error variants. Existing `StoreError.TransactionFailed` covers SET LOCAL failures.

**Failure modes**:
- `std.fmt.bufPrint` overflow (128-byte buffer too small) → ROLLBACK → `TransactionFailed`
  - Impossible in practice: max schema name is 39 bytes ("tenant_" + 32-char UUID)
- `conn.exec(set_path_sql, &.{})` fails (DB error) → ROLLBACK → `TransactionFailed`
  - Rare; only if PostgreSQL connection is dying

## State Transitions

No module state changes. The transaction state transitions are:

```
[pool connection acquired]
  ↓
[BEGIN executed] ← transaction starts
  ↓
[SET LOCAL search_path executed] ← NEW step (ISS-0128 fix)
  ↓
[unqualified queries execute] ← now resolve correctly
  ↓
[COMMIT or ROLLBACK] ← SET LOCAL auto-resets here
  ↓
[connection released to pool] ← no search_path leak
```

## Dependencies

- **Imports**: `@import("pool")` for `schemaNameForTenant` function
  - Module-level import already exists as `const db = @import("pool");` (line 16)
  - Can reuse: `const schema_name = db.schemaNameForTenant(...);`

- **Functions called**:
  - `db.schemaNameForTenant(tenant_id: []const u8, buf: *[80]u8) []const u8`
    - Defined: `src/db/pool.zig:137`
    - Allocation-free, hot-path safe
  - `std.fmt.bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) ![]const u8`
    - Standard library
  - `conn.exec(sql: []const u8, params: []const ?[]const u8) !void`
    - Existing, already used at line 306

- **No circular dependencies**: `pool.zig` does not import `event_store`

## Constraints

1. **ES-01 (Determinism)**: SET LOCAL does not violate determinism; schema routing is derived from `tenant_id`, not external state
2. **ES-02 (Transaction safety)**: Fix enhances transaction correctness by guaranteeing schema visibility
3. **ES-03 (Idempotency)**: Unaffected; idempotency logic is downstream of instance lookup
4. **DB-03 (Single transaction)**: Preserves single-transaction boundary; SET LOCAL executes within it
5. **TNT-02 (Schema isolation)**: Fix is the enforcement mechanism for tenant isolation
6. **Performance**: 
   - Adds one additional `exec()` per append (< 1ms overhead)
   - Stack allocation only; no heap pressure
   - SET LOCAL is lightweight PostgreSQL operation

## Open Questions

None. ISS-0130 (PR #531) validated this exact pattern for `migrations.zig` across all integration tests. The pattern is proven safe and effective.

## Verification Steps

1. **Run TC-DB-03-01** (tests/integration/db_integration_test.zig:255)
   - Pre-fix: Fails with `StoreError.InstanceNotFound`
   - Post-fix: Must pass
   - Acceptance criterion: Test completes with event appended to `tenant_default.events`

2. **Run all event_store integration tests**:
   ```bash
   zig build test-integration-tm
   ```
   - All existing tests must remain passing (no regression)

3. **Verify search_path isolation**:
   - Add debug log after SET LOCAL: `std.debug.print("search_path set to: {s}\n", .{schema_name});`
   - Confirm output shows correct schema for each test's tenant_id
   - Remove debug log before commit

4. **Check stale-path resistance**:
   - Manually set stale search_path on a connection before releasing to pool
   - Re-acquire connection and call append()
   - Verify append() succeeds (SET LOCAL overrides stale session state)

## Reference

- **Pattern source**: ISS-0130 fix in `src/db/migrations.zig:424-447` (PR #531, GH #423)
- **Related issues**:
  - ISS-0114: Tenant provisioning fix (set storage_mode=SCHEMA)
  - ISS-0130: Migration runner search_path race (RESOLVED via this pattern)
  - ISS-0129: Migration advisory lock (orthogonal fix)
- **Design artefact**: `src/design/event_store.md` (ES-01 through ES-08)
- **Test spec**: TC-DB-03 (tests/specs/TC-DB-03.md) — event_store append validation

## Prevention

**Rule**: Every function that opens a transaction with `BEGIN` and issues unqualified table queries MUST issue `SET LOCAL search_path TO <schema>,public` immediately after `BEGIN` and before any query.

**Detection**: Grep for `conn.exec("BEGIN"` and verify `SET LOCAL search_path` appears within 5 lines (accounting for errdefer, comments, and conditional logic).

**Enforcement**: Code review checklist item for any new transactional code in tenant-schema-aware modules.
