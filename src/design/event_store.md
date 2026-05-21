# Module: event_store

**Covers:** ES-01, ES-02, ES-03, ES-04, ES-05, ES-06, ES-07, ES-08  
**Files:** `src/event_store/store.zig`, `src/event_store/registry.zig`

---

## Public interface

### Shared types (imported by both store.zig and registry.zig)

```zig
/// Raw 16-byte UUID v4 representation.
pub const Uuid = [16]u8;
```

---

### store.zig

```zig
pub const StoreError = error{
    /// Pool.acquire() returned ExhaustedPool → HTTP 503
    PoolExhausted,
    /// instance_id does not exist in instance_projections → HTTP 404 (ES-01)
    InstanceNotFound,
    /// Append to an instance with status CANCELLED or COMPLETED → HTTP 409 (ES-01)
    InstanceTerminated,
    /// event_type not registered in event_type_registry → HTTP 422 (ES-05)
    UnknownEventType,
    /// Payload fails registered JSON Schema → HTTP 422 (ES-05)
    PayloadSchemaInvalid,
    /// metadata value is not a string, key > 128 chars, value > 1024 chars,
    /// or more than 50 entries → HTTP 422 (ES-08)
    MetadataInvalid,
    /// idempotency_key is absent or empty → HTTP 422 (ES-03)
    IdempotencyKeyMissing,
    /// idempotency_key > 255 chars → HTTP 422 (ES-03)
    IdempotencyKeyTooLong,
    /// payload is null, a JSON array, or a JSON scalar → HTTP 422 (ES-01)
    PayloadInvalid,
    /// actor_id is nil or empty → HTTP 422 (ES-01)
    ActorIdMissing,
    /// A multi-table transaction failed to commit (DB-03)
    TransactionFailed,
};

/// Result of append(). is_duplicate tells the HTTP layer whether to return 201 or 200.
/// NOTE: the task specification lists the return type as `!EventRecord`; this design
/// refines it to `!AppendResult` to carry the duplicate flag without losing the record.
/// The HTTP handler must not call a second DB query to determine 200 vs 201.
pub const AppendResult = struct {
    record:       EventRecord,
    /// true  → idempotency_key was already committed; return HTTP 200 (ES-03)
    /// false → new event persisted; return HTTP 201 (ES-01)
    is_duplicate: bool,
};

pub const Store = struct {
    /// pool must outlive Store. registry must outlive Store.
    pub fn init(
        allocator: std.mem.Allocator,
        pool:      *db.Pool,
        registry:  *Registry,
    ) Store;

    pub fn deinit(self: *Store) void;

    /// Append a typed, immutable event to the event log.
    /// Covers: ES-01 (fields, immutability, active-instance guard),
    ///         ES-02 (sequence assignment via instance_sequence row lock),
    ///         ES-03 (idempotency via ON CONFLICT DO NOTHING),
    ///         ES-05 (registry.validatePayload() called before any write),
    ///         ES-08 (metadata validated and stored),
    ///         DB-03 (all writes in one transaction).
    pub fn append(
        self:      *Store,
        allocator: std.mem.Allocator,
        params:    AppendParams,
    ) StoreError!AppendResult;

    /// Return events for instance_id in ascending sequence_number order.
    /// Covers: ES-02 (strict order), ES-06 (point-in-time filters).
    /// Returns InstanceNotFound if instance_id does not exist.
    pub fn read(
        self:        *Store,
        allocator:   std.mem.Allocator,
        instance_id: Uuid,
        opts:        ReadOpts,
    ) StoreError![]EventRecord;

    /// Return events across all instances ordered by global_seq (ES-04).
    /// Supports cursor-based pagination via GlobalReadOpts.after_global_seq.
    pub fn readGlobal(
        self:      *Store,
        allocator: std.mem.Allocator,
        opts:      GlobalReadOpts,
    ) StoreError![]EventRecord;

    /// Return events for instance_id with created_at <= before (UTC microseconds).
    /// Convenience wrapper over read() with ReadOpts.up_to_timestamp = before.
    /// Covers ES-06.
    pub fn pointInTime(
        self:        *Store,
        allocator:   std.mem.Allocator,
        instance_id: Uuid,
        before:      i64,
    ) StoreError![]EventRecord;

    /// Move expired events to events_archive per event_retention_policies.
    /// retention_days is the global fallback: applied to event types with no registered
    /// policy when retention_days > 0. 0 means "only apply explicitly registered policies".
    /// Returns the total number of event rows moved.
    /// Covers ES-07.
    pub fn archive(
        self:           *Store,
        allocator:      std.mem.Allocator,
        retention_days: u32,
    ) StoreError!u64;
};
```

---

### registry.zig

```zig
pub const RegistryError = error{
    /// Pool.acquire() returned ExhaustedPool → HTTP 503
    PoolExhausted,
    /// event_type name not found in event_type_registry → HTTP 422 (ES-05)
    UnknownEventType,
    /// (name, schema_version) already exists → HTTP 409 (ES-05)
    DuplicateEventTypeVersion,
    /// Submitted json_schema is not valid JSON Schema draft-07+ → HTTP 422 (ES-05)
    InvalidJsonSchema,
    /// Event type name > 128 chars → HTTP 422 (ES-05)
    EventTypeNameTooLong,
    /// Event type name is empty → HTTP 422 (ES-05)
    EventTypeNameEmpty,
    /// Payload fails the registered schema; see lastValidationFailures() (ES-05)
    PayloadValidationFailed,
    /// INSERT to event_type_registry failed (transient DB error)
    TransactionFailed,
};

/// One field-level failure from JSON Schema validation.
pub const ValidationFailure = struct {
    /// JSON Pointer (RFC 6901) to the failing location, e.g. "/required_field"
    field_path: []const u8,
    /// Schema keyword that failed, e.g. "required", "type", "maxLength"
    constraint: []const u8,
    /// Serialised actual value at that location (may be "null" if absent)
    actual:     []const u8,
};

pub const Registry = struct {
    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) Registry;
    pub fn deinit(self: *Registry) void;

    /// Register a new event type (or a new schema version of an existing type).
    /// Validates json_schema is a valid JSON Schema document before persisting.
    /// Covers ES-05.
    pub fn registerType(
        self:      *Registry,
        allocator: std.mem.Allocator,
        params:    RegisterParams,
    ) RegistryError!EventTypeRecord;

    /// Validate payload bytes against the registered JSON Schema for event_type.
    /// On failure: returns PayloadValidationFailed; call lastValidationFailures()
    /// to retrieve per-field detail before the next registry call.
    /// Covers ES-05.
    pub fn validatePayload(
        self:       *Registry,
        allocator:  std.mem.Allocator,
        event_type: []const u8,
        payload:    []const u8,
    ) RegistryError!void;

    /// Retrieve the most recent schema version record for event_type.
    /// Returns UnknownEventType if name is not registered.
    /// Covers ES-05.
    pub fn getType(
        self:       *Registry,
        allocator:  std.mem.Allocator,
        event_type: []const u8,
    ) RegistryError!EventTypeRecord;

    /// After a PayloadValidationFailed error, return per-field failure detail.
    /// The returned slice is owned by the Registry and is valid until the next
    /// call to any Registry method.
    pub fn lastValidationFailures(self: *Registry) []const ValidationFailure;
};
```

---

## Data types

### EventRecord
| Field | Type | Notes |
|---|---|---|
| `event_id` | `Uuid` | Platform-assigned UUIDv4; never duplicated (ES-01) |
| `instance_id` | `Uuid` | Owning process instance; must be ACTIVE at append time |
| `event_type` | `[]const u8` | Must exist in `event_type_registry` (ES-05) |
| `payload` | `[]const u8` | JSON object bytes; inline ≤ 4096 bytes, else fetched from `event_payload_store` |
| `actor_id` | `Uuid` | Must be non-nil (ES-01) |
| `created_at` | `i64` | UTC microseconds since Unix epoch; microsecond precision (ES-01) |
| `sequence_number` | `i64` | Per-instance monotonically increasing; assigned from `instance_sequence` (ES-02) |
| `idempotency_key` | `[]const u8` | Global unique key, 1..255 chars (ES-03) |
| `metadata` | `[]const u8` | JSON bytes; string→string map; defaults to `"{}"` (ES-08) |
| `global_seq` | `i64` | Cross-instance monotone; from `events_global_seq` PostgreSQL sequence (ES-04) |

### AppendParams
| Field | Type | Notes |
|---|---|---|
| `instance_id` | `Uuid` | Target instance; checked ACTIVE inside transaction |
| `event_type` | `[]const u8` | Must match a registered `event_type_registry` name |
| `payload` | `[]const u8` | JSON object bytes; null/array/scalar → `PayloadInvalid`; > 4096 bytes → side table |
| `actor_id` | `Uuid` | Must be non-nil |
| `idempotency_key` | `[]const u8` | 1..255 chars; global uniqueness enforced by DB UNIQUE constraint |
| `metadata` | `?[]const u8` | Optional; null → stored as `"{}"`; if present must be string→string JSON object |

### ReadOpts
| Field | Type | Notes |
|---|---|---|
| `up_to_sequence` | `?i64` | Return events with `sequence_number ≤ value`; null = no upper limit (ES-06) |
| `up_to_timestamp` | `?i64` | Return events with `created_at ≤ value` (UTC µs); null = no upper limit (ES-06) |
| — | — | If both set, `up_to_sequence` takes precedence (ES-06) |

### GlobalReadOpts
| Field | Type | Notes |
|---|---|---|
| `after_global_seq` | `?i64` | Resume cursor: return events with `global_seq > value`; null = stream from beginning (ES-04) |
| `limit` | `u32` | Page size; 1..1000; 0 treated as default 100 (ES-04) |

### EventTypeRecord
| Field | Type | Notes |
|---|---|---|
| `id` | `Uuid` | Platform-assigned UUIDv4 |
| `name` | `[]const u8` | 1..128 chars |
| `schema_version` | `u32` | Monotonically increasing per name |
| `json_schema` | `[]const u8` | JSON bytes; valid JSON Schema draft-07+ |
| `description` | `?[]const u8` | Free text; may be null |
| `created_at` | `i64` | UTC µs |
| `updated_at` | `i64` | UTC µs |

### RegisterParams
| Field | Type | Notes |
|---|---|---|
| `name` | `[]const u8` | 1..128 chars; must be non-empty |
| `schema_version` | `u32` | Must be > all existing versions for this name; 0 is invalid |
| `json_schema` | `[]const u8` | Must be valid JSON Schema draft-07+ |
| `description` | `?[]const u8` | Optional |

### AppendResult
| Field | Type | Notes |
|---|---|---|
| `record` | `EventRecord` | The persisted (or previously persisted for duplicates) event |
| `is_duplicate` | `bool` | `true` → idempotency_key already committed → HTTP 200 (ES-03) |

### ValidationFailure
| Field | Type | Notes |
|---|---|---|
| `field_path` | `[]const u8` | JSON Pointer to failing location |
| `constraint` | `[]const u8` | Schema keyword that failed |
| `actual` | `[]const u8` | Serialised actual value |

---

## Key invariants

1. **Event immutability** — No public function updates any field of a committed `events` row. There is no `updateEvent()` or similar. Enforced by the absence of any such function in this interface. (ES-01)

2. **Per-instance sequence monotonicity** — `sequence_number` is assigned via `SELECT … FOR UPDATE` on `instance_sequence.next_seq`, then the counter is incremented in the same transaction. This row-level lock serialises concurrent appends to the same instance; no two committed events for the same instance share a `sequence_number`. (ES-02)

3. **Global sequence monotonicity** — `global_seq` is assigned by `DEFAULT nextval('events_global_seq')`. PostgreSQL sequences never reuse values after a committed insert. Transaction rollbacks may leave gaps; gaps are acceptable — consumers must not assume gap-free. (ES-04)

4. **Idempotency key global uniqueness** — The `uq_event_idempotency` UNIQUE index on `events(idempotency_key)` enforces uniqueness at the DB level. `append()` uses `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING *`; if RETURNING yields no rows the original record is fetched and returned with `is_duplicate = true`. (ES-03)

5. **Idempotency durability across archival** — After an event is moved to `events_archive`, its `idempotency_key` is no longer in the `events` UNIQUE index. To maintain ES-03 durability, `append()` must also check `events_archive(idempotency_key)` when the primary insert returns no conflict rows. BACKEND-DEV MUST add a UNIQUE index on `events_archive(idempotency_key)` in the migration. *(See Open Questions #1.)*

6. **Atomic append** — One transaction contains: `instance_projections` status check, `instance_sequence` lock + increment, `events` insert, optional `event_payload_store` insert for large payloads, and `instance_projections` update (`last_event_seq`, `updated_at`). All or nothing. (DB-03)

7. **Payload size boundary** — Payloads > 4096 bytes are stored in `event_payload_store`; `events.payload` holds `{"$ref": "<uuid>"}`. Read functions (`read`, `readGlobal`, `pointInTime`) transparently fetch and splice in side-table payloads before returning `EventRecord`. (NFR-05, ES-01)

8. **Registry-first validation** — `Registry.validatePayload()` is called inside `Store.append()` before any write. If validation fails, zero DB rows are written. (ES-05)

9. **Metadata validation pre-DB** — Metadata constraints (≤ 50 entries, key ≤ 128 chars, value ≤ 1024 chars, all values must be JSON strings) are checked in Zig before any SQL query is issued. (ES-08)

10. **Active-instance guard** — `append()` reads `instance_projections.status` inside the transaction. Status `CANCELLED` or `COMPLETED` → return `InstanceTerminated`; no rows written. (ES-01)

11. **Archival idempotency** — `archive()` moves rows using `INSERT INTO events_archive … ON CONFLICT DO NOTHING`, then deletes only rows confirmed present in `events_archive`. Running twice produces the same final state. (ES-07)

12. **Archival does not block active instances** — The archival transaction does not lock `instance_projections` or `instance_sequence`. Row-level locks on individual archived `events` rows are held only during the move operation. (ES-07)

---

## DB tables / columns per operation

### `append` (ES-01, ES-02, ES-03, ES-05, ES-08, DB-03)
| Table | Columns read | Columns written | Operation |
|---|---|---|---|
| `instance_projections` | `status` | — | SELECT WHERE instance_id = $1 (check ACTIVE) |
| `instance_sequence` | `next_seq` | `next_seq` | SELECT FOR UPDATE; UPDATE next_seq + 1 (or INSERT ON CONFLICT) |
| `event_type_registry` | `name`, `json_schema` | — | SELECT WHERE name = $1 (registry cache; part of validatePayload) |
| `events` | `idempotency_key` | all columns | INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING * |
| `event_payload_store` | — | `event_id`, `payload`, `byte_size` | INSERT if payload > 4096 bytes |
| `instance_projections` | — | `last_event_seq`, `updated_at` | UPDATE (same TX; DB-03) |

### `read` / `pointInTime` (ES-02, ES-06)
| Table | Columns | Operation |
|---|---|---|
| `events` | all columns | SELECT WHERE instance_id = $1 [AND seq ≤ $2 / AND created_at ≤ $3] ORDER BY sequence_number |
| `event_payload_store` | `payload` | SELECT WHERE event_id = $1 if events.payload contains `{"$ref":…}` |

### `readGlobal` (ES-04)
| Table | Columns | Operation |
|---|---|---|
| `events` | all columns | SELECT WHERE global_seq > $1 ORDER BY global_seq LIMIT $2 |
| `event_payload_store` | `payload` | SELECT WHERE event_id = $1 if events.payload contains `{"$ref":…}` |

### `archive` (ES-07)
| Table | Columns | Operation |
|---|---|---|
| `event_retention_policies` | `event_type`, `policy`, `keep_days`, `keep_count` | SELECT all policies |
| `events` | all columns | SELECT qualifying rows per policy; DELETE matched rows |
| `events_archive` | all columns + `archived_at` | INSERT moved rows (ON CONFLICT DO NOTHING) |

### `registerType` (ES-05)
| Table | Columns | Operation |
|---|---|---|
| `event_type_registry` | all columns | INSERT (name, schema_version, json_schema, description) |

### `validatePayload` / `getType` (ES-05)
| Table | Columns | Operation |
|---|---|---|
| `event_type_registry` | `name`, `json_schema`, `schema_version` | SELECT WHERE name = $1 |

---

## Concurrency design

### Per-instance sequence monotonicity (ES-02)

The `instance_sequence` table (from `001_event_store.sql`) holds one row per instance:
```
instance_id  UUID   PRIMARY KEY
next_seq     BIGINT NOT NULL DEFAULT 1
```

**Append protocol (inside a single transaction):**
1. Acquire row-level lock: `SELECT next_seq FROM instance_sequence WHERE instance_id = $1 FOR UPDATE`
2. The locked `next_seq` value becomes this event's `sequence_number`.
3. Increment: `UPDATE instance_sequence SET next_seq = next_seq + 1 WHERE instance_id = $1`
4. `INSERT INTO events (…, sequence_number = <locked_value>, …)`
5. COMMIT.

**First append to a new instance** (no `instance_sequence` row yet):
```sql
INSERT INTO instance_sequence (instance_id, next_seq)
VALUES ($1, 2)
ON CONFLICT (instance_id) DO UPDATE
  SET next_seq = instance_sequence.next_seq + 1
RETURNING next_seq - 1 AS assigned_seq
```
The `FOR UPDATE` lock serialises concurrent appends to the same instance. Cross-instance appends proceed fully in parallel.

### Global sequence monotonicity (ES-04)

`events.global_seq` uses `DEFAULT nextval('events_global_seq')`. PostgreSQL sequences are transaction-safe; the sequence value is consumed at INSERT time and is never reused after a commit. Transaction rollbacks leave gaps in `global_seq` — this is expected and acceptable. Consumers must treat `global_seq` as a non-gap-free monotone cursor.

### Read isolation

All reads use PostgreSQL default isolation (READ COMMITTED). A reader sees only fully committed `events` rows, satisfying ES-02's requirement that "no partially-committed event is visible."

---

## Data flow diagram

```
HTTP Request
     │
     ▼
api/routes/events.zig
     │  Validate request shape (actor_id, idempotency_key, metadata constraints)
     │
     ▼
Store.append(params)
     │
     ├─► Registry.validatePayload(event_type, payload)
     │        │
     │        └─► SELECT event_type_registry WHERE name = $1
     │                    [JSON Schema validation in-process]
     │
     ├─► BEGIN TRANSACTION
     │        │
     │        ├─► SELECT instance_projections WHERE instance_id = $1
     │        │   (guard: ACTIVE only)
     │        │
     │        ├─► SELECT instance_sequence FOR UPDATE
     │        │   (acquire per-instance sequence lock)
     │        │
     │        ├─► INSERT events … ON CONFLICT DO NOTHING RETURNING *
     │        │   (idempotency handled here)
     │        │
     │        ├─► [if payload > 4096] INSERT event_payload_store
     │        │
     │        ├─► UPDATE instance_sequence next_seq + 1
     │        │
     │        └─► UPDATE instance_projections last_event_seq
     │
     └─► COMMIT → AppendResult{record, is_duplicate}
```

---

## Cross-module dependencies

| Dependency | Direction | Why |
|---|---|---|
| `src/db/pool.zig` | Store → Pool | All SQL queries use `pool.acquire()` / `pool.release()` (DB-02) |
| `src/event_store/registry.zig` | Store → Registry | `append()` calls `registry.validatePayload()` before any write (ES-05) |
| `src/engine/` (future Stage 2) | Engine → Store | EE-11 state reconstruction calls `store.read()` / `store.pointInTime()` |
| `src/api/routes/events.zig` | API → Store | HTTP handlers call `append`, `read`, `readGlobal`, `archive` |
| `src/obs/logger.zig` | Store → Logger | Structured logging on append/error paths |

**Must NOT depend on:**
- `src/engine/transition.zig` — pure function with zero I/O; event_store must never call it
- `src/api/` — direction is API → Store only; no circular imports
- `src/tasks/` — lateral dependency; must not cross-import

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Payload side-table join cost | Increased read latency for large-payload events | `event_payload_store.event_id` has a UNIQUE index; join is O(1) per row; most payloads are inline |
| Global stream scaling at high volume | `readGlobal` scans large `events` table | `idx_events_global_seq` index; cursor-based pagination caps result set; sharding is a future concern |
| Idempotency key durability after archival | Old key could be reused post-archival | See Open Question #1: add UNIQUE index on `events_archive(idempotency_key)` and check archive on conflict |
| Concurrent append deadlock | Two transactions locking resources in reverse order | Lock order is always `instance_sequence` → `events`; no reverse path exists in this design |
| Instance sequence lock contention | High-frequency appends to one instance serialise | Expected design constraint; heavy single-instance use cases should batch events or use coarser-grained events |
| `event_type_registry` schema validation cost | Latency spike on payload validation | Registry caches the most recently used schemas in-process; schema is a read-heavy, write-rare resource |

---

## Open questions

**#1 — Idempotency key durability across archival (ES-03)**  
ES-03 requires "a duplicate submitted after a platform restart returns the original record." After `archive()` moves a row from `events` to `events_archive`, the `uq_event_idempotency` UNIQUE index on `events` no longer covers that key. A new append with the same key would succeed as a fresh insert, violating ES-03.

*Recommended resolution:* BACKEND-DEV should add a `UNIQUE` index on `events_archive(idempotency_key)`, and `Store.append()` should implement a two-phase deduplication check:
  1. `INSERT INTO events … ON CONFLICT (idempotency_key) DO NOTHING RETURNING *`
  2. If no rows returned: `SELECT * FROM events_archive WHERE idempotency_key = $1`
  3. If found in archive: return the archived record with `is_duplicate = true`
  4. If not found anywhere: the insert genuinely had a race; retry or report error

This resolution should be confirmed by ORCH / REQ-ANALYST before BACKEND-DEV implements `append()`.

---

*Traceability:*  
- ES-01 → `Store.append()`, `AppendParams`, `EventRecord`, `StoreError.PayloadInvalid/ActorIdMissing/InstanceTerminated`  
- ES-02 → `Store.read()`, sequence lock protocol, `uq_event_sequence` index  
- ES-03 → `StoreError.IdempotencyKeyMissing/TooLong`, `AppendResult.is_duplicate`, ON CONFLICT pattern  
- ES-04 → `Store.readGlobal()`, `GlobalReadOpts`, `events_global_seq` sequence, `idx_events_global_seq`  
- ES-05 → `Registry.*`, `RegistryError.*`, `ValidationFailure`, `EventTypeRecord`, `RegisterParams`  
- ES-06 → `Store.pointInTime()`, `ReadOpts.up_to_sequence/up_to_timestamp`  
- ES-07 → `Store.archive()`, `event_retention_policies`, `events_archive`  
- ES-08 → `AppendParams.metadata`, `EventRecord.metadata`, `StoreError.MetadataInvalid`
