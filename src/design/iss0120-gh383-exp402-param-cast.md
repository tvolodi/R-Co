# Design: ISS-0120 / GH-383 — Fix 42P18 in markRestoredOrphanInTx

**Type:** E (novel fix — SQL type-cast correction)
**Run:** WF03-GH383-20260809
**Requirement:** EXP-402
**Module:** `src/engine/reconstruction.zig`

---

## Module purpose

`reconstruction.zig` reconciles in-flight BPM instances after a tenant restore. The
function `markRestoredOrphanInTx` marks an instance as `RESTORED_ORPHAN` and records a
human-readable reason string into the `error_detail` JSONB column. The only defect
addressed here is a single missing type cast on one SQL parameter.

---

## Root cause

`jsonb_build_object` is declared in PostgreSQL as `jsonb_build_object(VARIADIC "any")`
— its argument types are `"any"`, meaning the engine cannot infer the concrete type of
any positional parameter at prepare time. When the query is prepared with extended-query
protocol, PostgreSQL raises:

```
ERROR 42P18: could not determine data type of parameter $2
```

The parameter `$2` carries the `reason` value (a `[]const u8` Zig string — always text).
The fix is a single explicit cast that gives PostgreSQL a concrete type to work with.

---

## Exact change (1 line)

**File:** `src/engine/reconstruction.zig`  
**Function:** `markRestoredOrphanInTx`

Before:
```sql
error_detail = jsonb_build_object('restored_orphan_reason', $2),
```

After:
```sql
error_detail = jsonb_build_object('restored_orphan_reason', $2::text),
```

No other lines in the function change. No other files change.

---

## Public interface

The function signature is unchanged:

```zig
pub fn markRestoredOrphanInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id: Uuid,
    reason: []const u8,
) ReconstructionError!void
```

`reason` is always a text string (it is a string literal at the only call site, line ~387).
Casting `$2::text` is correct and safe: it matches the Zig type exactly and produces a
valid JSONB text value for `jsonb_build_object`.

---

## Data flow

```
markRestoredOrphanInTx
    │
    ├─ $1 → inst_id_hex (uuid hex string) → $1::uuid cast already present
    └─ $2 → reason ([]const u8)           → $2::text cast ADDED (this fix)
                                                  │
                                                  ▼
                         jsonb_build_object('restored_orphan_reason', $2::text)
                         → error_detail JSONB column in instance_projections
```

---

## Error taxonomy

| Error | Trigger | Handling |
|---|---|---|
| `42P18` (indeterminate_datatype) | `$2` without cast inside variadic-any function | Eliminated by `$2::text` |
| `ReconstructionError.QueryFailed` | Any other `conn.exec` failure | Unchanged — propagated to caller |
| `ReconstructionError.OutOfMemory` | `uuidToHex` allocation fails | Unchanged |

---

## Dependencies

- `src/db/conn.zig` — `exec` (parameterised query, no change)
- `instance_projections` table — `error_detail` column is `JSONB` (no schema change needed)
- No other modules touched

---

## Open questions

None. The cast is unambiguous: `reason` is always a text string.

---

## Verification

Run the EXP integration test suite:

```bash
zig build test-integration -- --test-name-pattern "TC-EXP-402"
```

Expected: exits 0, no `42P18` error, TC-EXP-402-02 passes.
