# Design: Platform-Event Append Convention (ISS-0670)

**Author:** CODE-DESIGNER  
**Run:** WF03-ISS0670-20260812  
**Requirement:** PAR-02 AC5  
**Related:** PAR-03 AC6 (EXECUTION_PARTITION_DETACHED, EXECUTION_PARTITION_DROPPED), and four other
unimplemented EXECUTION_* platform events named in docs/requirements.yaml  
**GitHub issue:** https://github.com/tvolodi/R-Co/issues/711  
**Status:** DESIGN — not implementation

---

## Module Purpose

Background scheduler jobs (partition maintenance, migration validator, outbox gate, etc.) are
platform-level processes with no owning workflow instance. They need to emit `EXECUTION_*` events
to the event log, but `Store.append()` hard-requires the caller's `instance_id` to exist as an
ACTIVE row in `instance_projections` (`StoreError.InstanceNotFound` on lines 382/383 of
`src/event_store/store.zig`). No system/platform instance_id convention exists anywhere in this
codebase today.

This document establishes that convention and specifies the API surface BACKEND-DEV must implement.

---

## Option Analysis

### Option A — `Store.appendPlatform()`  
Add a new function that skips the `instance_projections` look-up entirely and writes directly to
`events` using a well-known `PLATFORM_INSTANCE_ID` sentinel and a `PLATFORM_ACTOR_ID` sentinel.
No migration needed. The platform sentinel values are convention-only and are never inserted into
`instance_projections`.

**Pros:**
- Zero migration surface; no fake row in `instance_projections` that has no business meaning.
- No risk of a maintenance job racing with instance lifecycle state transitions (CANCELLED/COMPLETED
  guard in `Store.append()` is irrelevant and bypassed correctly).
- Simpler reasoning: platform events are structurally distinct from instance-scoped events; a
  separate code path makes that boundary explicit rather than papering over it with a seeded row.
- Reusable for all six platform event types without seeding or lifecycle management.

**Cons:**
- A second code path in the event store requires its own test coverage.
- The idempotency + sequence numbering logic must be reproduced (or shared) carefully.

### Option B — Seed a system row in `instance_projections`  
Add a migration that inserts `(PLATFORM_INSTANCE_ID, status='ACTIVE')` into
`instance_projections`. Then call the existing `Store.append()` with that id.

**Pros:**
- Reuses the entire existing append path.

**Cons:**
- Introduces a fake instance row with no business meaning into a table that owns real workflow
  instances. Status transitions (CANCEL, COMPLETE) applied accidentally to this row would break
  every subsequent platform event. Guards against such accidents require additional migration-level
  constraints or application-level special-casing.
- Adds a migration that must be present before any `appendPlatform` call is valid, creating an
  ordering dependency for tests and for any environment that skips migrations.
- `instance_sequence` would accumulate a sequence counter for the platform row — an artefact with
  no semantic meaning that complicates any sequence-based replay or audit query.

**Recommendation: Option A.** Lower coupling. No migration. Explicit code path. No fake row.

---

## Chosen Design: Option A

### 1. Constants — `src/event_store/platform.zig` (new file)

```zig
//! Platform-event conventions for non-instance-scoped scheduler events.
//! XC-04: no LLM, HTTP, or external service dependencies in this file.

/// Sentinel instance_id used for all platform-level EXECUTION_* events.
/// Chosen to be visually distinct and grep-stable; never inserted into
/// instance_projections.
pub const PLATFORM_INSTANCE_ID: []const u8 = "00000000-0000-0000-0000-0000000000ff";

/// Sentinel actor_id for scheduler-driven events (no human actor).
pub const PLATFORM_ACTOR_ID: []const u8 = "00000000-0000-0000-0000-000000000000";

/// Sentinel tenant_id written into platform events.
/// Uses the same DEFAULT_TENANT_ID the rest of the store uses (store.zig).
pub const PLATFORM_TENANT_ID: []const u8 = "00000000-0000-0000-0000-000000000000";
```

Rationale for `0000…00ff` as PLATFORM_INSTANCE_ID:
- All-zeros (`0000…0000`) is already `DEFAULT_TENANT_ID` and `PLATFORM_ACTOR_ID` — reuse would be
  ambiguous in query results.
- `0000…00ff` ("FF sentinel") is visually identifiable, outside any valid UUIDv4 node range, and
  not a plausible collision with any generated `gen_random_uuid()` value.
- It is a pure convention constant, never stored in `instance_projections`.

### 2. New struct — `PlatformAppendParams`

In `src/event_store/store.zig`, add alongside `AppendParams`:

```zig
/// Parameters for a platform-scoped event (no owning workflow instance).
/// `instance_id` is fixed to PLATFORM_INSTANCE_ID by `appendPlatform`.
/// `actor_id` is fixed to PLATFORM_ACTOR_ID by `appendPlatform`.
/// `tenant_id` is fixed to PLATFORM_TENANT_ID by `appendPlatform`.
pub const PlatformAppendParams = struct {
    event_type: []const u8,
    payload: []const u8,
    idempotency_key: []const u8,
};
```

### 3. New function — `Store.appendPlatform()`

In `src/event_store/store.zig`, inside `pub const Store`:

```zig
/// Append a platform-scoped EXECUTION_* event.
///
/// Differences from Store.append():
///  - Skips the instance_projections existence check (Step 1 of append()).
///  - Skips the instance_sequence counter (Step 2 of append()); sequence_number
///    is written as 0 (platform events do not belong to any per-instance stream).
///  - Uses PLATFORM_INSTANCE_ID, PLATFORM_ACTOR_ID, and PLATFORM_TENANT_ID
///    fixed sentinels (src/event_store/platform.zig).
///  - Does NOT update instance_projections.last_event_seq.
///  - All other guarantees (ES-03 idempotency via plat_event_idempotency,
///    ES-05 registry validation, DB-03 atomicity) are preserved.
///
/// Returns AppendResult with is_duplicate=true if the idempotency_key was
/// already committed (ES-03).
pub fn appendPlatform(
    self: *Store,
    allocator: std.mem.Allocator,
    params: PlatformAppendParams,
) StoreError!AppendResult
```

#### Internal transaction steps for `appendPlatform`

1. Pre-write validation: `idempotency_key` 1..255 chars; `payload` is a JSON object; `event_type`
   non-empty. (Same helpers as `validateAppendParams`, minus `actor_id` check — actor is fixed.)
2. ES-05: `self.registry.validatePayload(allocator, params.event_type, params.payload)`.
3. PAR-03 routing: `self.registry.getType(allocator, params.event_type)` → `target_table`.
4. Acquire connection. `BEGIN`.
5. `SET LOCAL search_path TO public` (platform events are cross-tenant; no schema prefix needed).
6. `INSERT INTO plat_event_idempotency … ON CONFLICT DO NOTHING RETURNING event_id, created_at_us`.
   - If zero rows returned → idempotency duplicate; resolve and return `is_duplicate=true`
     (same pattern as `Store.append()` Step 3's duplicate branch).
7. `INSERT INTO <target_table> (event_id, instance_id, event_type, payload, actor_id,
   sequence_number, idempotency_key, metadata, tenant_id) VALUES ($1, $2, $3, $4, $5, 0, $6, '{}',
   $7)` — `instance_id` = PLATFORM_INSTANCE_ID, `actor_id` = PLATFORM_ACTOR_ID,
   `tenant_id` = PLATFORM_TENANT_ID, `sequence_number` = 0.
8. `COMMIT`. Return `AppendResult{ .record = …, .is_duplicate = false }`.

**Note on `SET LOCAL search_path TO public`:** platform events are not tenant-schema-scoped. The
`events` / `events_ephemeral` / `plat_event_idempotency` tables live in `public`. Using `public`
unconditionally (rather than computing a tenant schema name) is correct here; if a tenant schema
were used, the platform event would be invisible from cross-tenant reads and would break the design
intent that platform events are global log entries.

**Note on `sequence_number = 0`:** platform events share no per-instance sequence stream. Writing
0 is a sentinel that distinguishes them from any real instance event (which has sequence_number ≥
1, assigned by `instance_sequence`). BACKEND-DEV must verify there is no NOT NULL / > 0 constraint
on `events.sequence_number`; if one exists, use -1 or add a `platform_event BOOLEAN DEFAULT FALSE`
column (open question — see below).

### 4. Idempotency key shape for `EXECUTION_PARTITION_CREATED`

```
"EXECUTION_PARTITION_CREATED:<partition_name>"
```

Example: `"EXECUTION_PARTITION_CREATED:events_2026_09"`

Rationale:
- Partition creation is idempotent per PAR-02 AC2. A second maintenance run for the same partition
  in the same month must not emit a duplicate event. Keying on `(event_type, partition_name)` makes
  it content-addressed and deterministic.
- 255-char limit: `EXECUTION_PARTITION_CREATED:` (29 chars) + partition name (max
  `<parent>_YYYY_MM` = ~20 chars) = well within limit.

For the other platform events:
- `EXECUTION_PARTITION_DETACHED:<partition_name>`
- `EXECUTION_PARTITION_DROPPED:<partition_name>`
- `EXECUTION_MIGRATION_VALIDATED:<migration_id>`
- `EXECUTION_OUTBOX_GATE_OPENED:<gate_id>` (or timestamp-qualified)
- `EXECUTION_CORRELATION_LAG:<run_date_iso8601>`

### 5. Payload shape for `EXECUTION_PARTITION_CREATED`

```json
{
  "partition_name": "events_2026_09",
  "parent_table": "events",
  "range_start": "2026-09-01T00:00:00Z",
  "range_end": "2026-10-01T00:00:00Z"
}
```

All four fields are already in scope at the `ensurePartitionAttached()` call site:
- `partition_name` — allocated at line 269 of `partition_maintenance.zig`
- `parent` — function parameter
- `start_text` / `end_text` — allocated at lines 285–288

### 6. Call site — `partition_maintenance.zig::ensurePartitionAttached()`, line 328

Insert before `return true;` (currently the last statement in the `ok` branch, after the
`plat_partition_catalog` upsert commits):

```zig
// PAR-02 AC5: emit EXECUTION_PARTITION_CREATED via platform-event convention (ISS-0670).
const ikey = try std.fmt.allocPrint(
    allocator,
    "EXECUTION_PARTITION_CREATED:{s}",
    .{partition_name},
);
defer allocator.free(ikey);

const payload_json = try std.fmt.allocPrint(
    allocator,
    "{{\"partition_name\":\"{s}\",\"parent_table\":\"{s}\"," ++
        "\"range_start\":\"{s}\",\"range_end\":\"{s}\"}}",
    .{ partition_name, parent, start_text, end_text },
);
defer allocator.free(payload_json);

_ = self.store.appendPlatform(allocator, .{
    .event_type = "EXECUTION_PARTITION_CREATED",
    .payload = payload_json,
    .idempotency_key = ikey,
}) catch |err| {
    // Non-fatal: log and continue. The partition is already attached;
    // failing to emit the audit event must not undo the DDL work.
    std.log.warn(
        "appendPlatform EXECUTION_PARTITION_CREATED failed for {s}: {any}",
        .{ partition_name, err },
    );
};

return true;
```

**BACKEND-DEV note — `self.store` field:** `PartitionMaintenanceScheduler` currently has no
`Store` reference. BACKEND-DEV must add a `store: *Store` (or `store: Store`) field to the
`PartitionMaintenanceScheduler` struct and pass it at init time. The `Store` itself only holds
`allocator`, `pool`, and `registry` pointers and is lightweight. This is the only structural
change required in `partition_maintenance.zig` beyond the call site.

**BACKEND-DEV note — error handling:** platform event emission is best-effort and must not roll
back the partition creation. The `catch |err|` block above logs and continues. This matches the
intent of AC5 ("appends … carrying the partition name") without making partition management
contingent on event-store availability.

**BACKEND-DEV note — connection:** `appendPlatform` acquires its own connection from the pool.
The `conn` parameter of `ensurePartitionAttached` is a single borrowed connection used for DDL
within the partition attach transaction, which commits before this call. `appendPlatform` runs in
its own independent transaction.

### 7. `EXECUTION_PARTITION_CREATED` must be registered in the event type registry

Before `appendPlatform` can succeed (ES-05), the event type must be registered. BACKEND-DEV must
verify whether a seed migration or startup registration call already covers
`EXECUTION_PARTITION_CREATED`. If not, add a migration:

```sql
-- migration: 1150_platform_event_types_seed.sql (new)
INSERT INTO event_type_registry (name, json_schema, retention_class)
VALUES
  ('EXECUTION_PARTITION_CREATED', '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}', 'keep_forever'),
  ('EXECUTION_PARTITION_DETACHED', '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}', 'keep_forever'),
  ('EXECUTION_PARTITION_DROPPED',  '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}', 'keep_forever')
ON CONFLICT (name) DO NOTHING;
```

`retention_class = 'keep_forever'` is mandatory: PAR-03 AC1 and `EXECUTION_*` prefix protection
in `registry.zig::validateRegisterParams` (verified in `tests/unit/event_store_test.zig` line 227)
forbid `retention_class = 'delete'` for any `EXECUTION_*`-prefixed type.

### 8. No migration required for `instance_projections`

Option A requires no new row in `instance_projections`. The PLATFORM_INSTANCE_ID sentinel is a
code constant only.

---

## PAR-02 AC5 Test Assertion

Add `TC-PAR-02-09` to `tests/integration/par02_partition_catalog_test.zig`:

```zig
// TC-PAR-02-09 (PAR-02 AC5): ensurePartitionAttached emits
// EXECUTION_PARTITION_CREATED in the events table after a new partition is
// created and attached.
test "par02_ac5: ensurePartitionAttached emits EXECUTION_PARTITION_CREATED" {
    // Setup: initialise Store + Registry + PartitionMaintenanceScheduler
    // (with the new .store field). Call ensurePartitionAttached for a
    // synthetic partition name that does not exist yet in plat_partition_catalog.
    //
    // Assert:
    //   SELECT COUNT(*) FROM events
    //   WHERE instance_id = '00000000-0000-0000-0000-0000000000ff'
    //     AND event_type = 'EXECUTION_PARTITION_CREATED'
    //     AND payload->>'partition_name' = '<synthetic_partition_name>'
    //   returns 1.
    //
    // Assert idempotency: call ensurePartitionAttached a second time for
    // the SAME synthetic partition. The plat_partition_catalog check (already
    // ATTACHED) returns false early, so no second event is emitted.
    //   SELECT COUNT(*) returns 1 still (not 2).
}
```

The test must use `PLATFORM_INSTANCE_ID` from `src/event_store/platform.zig` for the WHERE clause
rather than a hardcoded string literal, so the test stays in sync with the constant.

---

## Reuse for Other EXECUTION_* Platform Events

The same `appendPlatform` API covers all six events. Each caller follows the same pattern:
1. Build `idempotency_key = "<EVENT_TYPE>:<discriminator>"`.
2. Build `payload_json` from the relevant fields in scope.
3. Call `self.store.appendPlatform(allocator, .{ … })` — `catch |err|` log and continue.

No per-caller migration or convention change is needed beyond registering the event type (§7).

---

## Dependencies

- `Store.appendPlatform` depends on: `registry.zig` (ES-05), `plat_event_idempotency` table
  (ES-03), `events` / `events_ephemeral` (PAR-03 routing), `db.Pool`.
- `Store.appendPlatform` must NOT depend on: `instance_projections`, `instance_sequence`.
- `partition_maintenance.zig` depends on: `Store` (new dependency via the new `.store` field).

---

## Error Taxonomy

| Error | Origin | Caller action |
|---|---|---|
| `StoreError.UnknownEventType` | event type not registered (ES-05) | log WARN; continue |
| `StoreError.PayloadSchemaInvalid` | payload fails JSON schema (ES-05) | log WARN; continue |
| `StoreError.IdempotencyKeyMissing` | key empty (should never happen) | log WARN; continue |
| `StoreError.PoolExhausted` | all connections busy | log WARN; continue (transient) |
| `StoreError.TransactionFailed` | DB error | log WARN; continue (transient) |
| `StoreError.PartitionMissingForWrite` | no partition for current month | log WARN; continue — ironic but possible if events partitions themselves are not yet created |

All errors are non-fatal at the call site. The partition DDL work is already committed when
`appendPlatform` is called; no rollback is possible or desired.

---

## Open Questions

1. **`sequence_number = 0` constraint:** Does `events.sequence_number` have a `> 0` or `NOT NULL`
   constraint that would reject 0? BACKEND-DEV must inspect the migration DDL for the `events`
   table (likely `migrations/1148_par02_partition_catalog.sql` or an earlier migration). If 0 is
   rejected, use -1 or add `platform_event BOOLEAN DEFAULT FALSE` as a flag column with a new
   migration. Recommended fallback: use `sequence_number = -1` as the platform sentinel if 0 is
   rejected.

2. **Registry seed timing:** Is `EXECUTION_PARTITION_CREATED` seeded before the scheduler starts?
   If the scheduler runs before the migration that seeds the event type, `appendPlatform` will
   return `StoreError.UnknownEventType`. BACKEND-DEV must confirm seed ordering (migration sequence
   number must precede any code path that calls `appendPlatform`).

3. **`global_seq` column:** `appendPlatform`'s INSERT must populate `global_seq` from the
   `events_global_seq` PostgreSQL sequence (ES-04), same as `Store.append()`. BACKEND-DEV must
   include `global_seq = nextval('events_global_seq')` in the INSERT (or rely on a column DEFAULT
   if one is defined).
