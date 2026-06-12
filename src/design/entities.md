# Module: entities (Dynamic Entity Subsystem)

**Covers:** EXP-201, EXP-202  
**Files:** `src/entities/mod.zig`, `src/entities/definition.zig`, `src/entities/validator.zig`, `src/entities/commands.zig`, `src/entities/projector.zig`, `src/api/routes/entities.zig`  
**Migrations:** `migrations/094_entity_subsystem.sql`  
**Related:** REPO-01..14 (repository), ES-01..08 (event store), DB-03 (atomic writes), API-06 (pagination), OBS-03 (audit)

---

## Module purpose

The entities module introduces a first-class dynamic-entity abstraction into BPM. Each entity type is defined by a JSON schema (fields, types, constraints, indexes, foreign keys) stored as a versioned Repository artifact (kind = "entity"). Entity records are created, updated, and deleted exclusively by appending events to the event store (`ENTITY_RECORD_CREATED`, `ENTITY_RECORD_UPDATED`, `ENTITY_RECORD_DELETED`). The event stream is the system of record; any read projection is rebuildable from events alone.

This module is the foundation for EXP-2 (dynamic entity subsystem). EXP-203 (typed projection tables) and EXP-204 (re-projection) extend the `projector.zig` sub-module in subsequent runs.

---

## Classification per templates/lego-catalog.md

| Requirement | Classification | Rationale |
|---|---|---|
| EXP-201 Entity definition format | **Type E** | Novel data model + validation rules + cross-module integration with repository. No existing template covers entity definition schemas or repository kind extensions. |
| EXP-202 Entity command API → event family | **Type E** | New event family + REST command routes + idempotency + stream replay semantics. Cross-cutting across event_store, repository, and API layers. |

**No Type A–D parameter files are produced.** Both requirements are Type E novel/cross-cutting work. The single design artefact is this file.

---

## Data flow diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           REST API Layer                                 │
│  POST   /api/v1/entities/:type          → createEntityRecord            │
│  PATCH  /api/v1/entities/:type/:id      → updateEntityRecord            │
│  DELETE /api/v1/entities/:type/:id      → deleteEntityRecord            │
│  GET    /api/v1/entity-definitions      → listDefinitions               │
│  GET    /api/v1/entity-definitions/:id  → getDefinition                 │
│  POST   /api/v1/entity-definitions      → createDefinition              │
└───────────────────────┬──────────────────────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      src/entities/commands.zig                           │
│  • validatePayloadAgainstDefinition(definition, payload) → void|error    │
│  • buildEventPayload(definition, action, record_id, fields) → JSON      │
│  • appendEntityEvent(pool, registry, params) → AppendResult              │
│                                                                          │
│  Transaction boundary:                                                   │
│    1. Load entity definition (from entity_definitions or cache)          │
│    2. Validate payload fields against definition schema                  │
│    3. Reserve record_id (UUID) if create                                │
│    4. Compute idempotency key                                            │
│    5. Append event via event_store.Store.append()                        │
│    6. Upsert entity_record_latest (projection)                           │
│    7. Commit                                                             │
└──────────┬──────────────────────┬────────────────────────────────────────┘
           │                      │
           ▼                      ▼
┌────────────────────┐  ┌──────────────────────────────────────────────────┐
│  event_store/       │  │  entity_definitions table                        │
│  Store.append()     │  │  • Stores the entity definition JSON             │
│                     │  │  • content_hash from canonicaliser               │
│  events table:      │  │  • logical_shape_version (incremented)           │
│  event_type =       │  │  • Registered as repository artifact             │
│    ENTITY_RECORD_   │  │    kind = "entity"                               │
│    {CREATED,        │  └──────────────────────────────────────────────────┘
│     UPDATED,        │
│     DELETED}        │  ┌──────────────────────────────────────────────────┐
│                     │  │  entity_record_latest table                      │
│  payload =          │  │  • One row per entity record (projection)        │
│    {entity_type,    │  │  • current_state JSONB (full field values)        │
│     record_id,      │  │  • version_seq (event count)                     │
│     field_values,   │  │  • Updated atomically with each event            │
│     changed_fields} │  └──────────────────────────────────────────────────┘
└────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                    src/entities/projector.zig                             │
│  • replayEntityStream(events) → []RecordSnapshot                         │
│  • rebuildProjection(pool, entity_type) → void                           │
│  EXP-203 will extend this to generate typed projection tables            │
│  with real columns for queried fields. For EXP-201/202, the              │
│  projection is entity_record_latest with a JSONB current_state.          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Entity definition JSON schema

An entity definition is a JSON document describing the shape and constraints of one entity type. It is stored as a Repository artifact with `kind = "entity"` and `content_type = "application/json"`, and also persisted in the `entity_definitions` table for fast lookup.

### Schema structure (pseudocode)

```
EntityDefinition {
  name:               string,       // required, 1..128 chars, [a-z][a-z0-9_]*, unique per tenant
  display_name:       string,       // required, 1..256 chars, human-readable
  description:        string|null,  // optional, max 4096 chars
  version:            integer,      // required, ≥1, auto-incremented on shape change
  fields:             [FieldDef],   // required, 1..64 fields
  indexes:            [IndexDef],   // optional, 0..32 indexes
  foreign_keys:       [FKDef],      // optional, 0..16 foreign keys
  constraints:        [ConstraintDef], // optional, 0..32 table-level constraints
}

FieldDef {
  name:               string,       // required, 1..128 chars, [a-z][a-z0-9_]*, unique within entity
  display_name:       string,       // required, 1..256 chars
  type:               FieldType,    // required (see FieldType enum below)
  required:           boolean,      // default false
  unique:             boolean,      // default false
  queried:            boolean,      // default false — if true, becomes a typed projection column (EXP-203)
  default_value:      any|null,     // optional, must match type
  validation:         ValidationSpec|null, // optional per-field rules
  description:        string|null,  // optional, max 1024 chars
}

FieldType enum:
  text | integer | decimal | boolean | date | timestamp | uuid | enum | json

  - text:     variable-length string, max length in validation
  - integer:  64-bit signed integer
  - decimal:  fixed-point decimal, precision/scale in validation
  - boolean:  true/false
  - date:     ISO 8601 date (no time component)
  - timestamp: ISO 8601 datetime with timezone
  - uuid:     UUID v4 string
  - enum:     one of a predefined set of string values (values in validation)
  - json:     arbitrary JSON (free-form, never queried/indexed)

ValidationSpec {
  // Applied per FieldType:
  max_length:     integer|null,     // text: max character count (1..65535)
  min_value:      number|null,      // integer, decimal: lower bound
  max_value:      number|null,      // integer, decimal: upper bound
  precision:      integer|null,     // decimal: total digits (1..38)
  scale:          integer|null,     // decimal: fractional digits (0..precision)
  pattern:        string|null,      // text: regex pattern (ECMAScript)
  values:         [string]|null,    // enum: allowed values (1..256 entries)
  allowed_types:  [string]|null,    // json: JSON Schema type constraints
}

IndexDef {
  name:               string,       // required, 1..128 chars, unique within entity
  fields:             [string],     // required, 1..4 field names (field must have queried: true)
  unique:             boolean,      // default false
  method:             string,       // "btree" (default) | "hash" — future-proofing
}

FKDef {
  name:               string,       // required, 1..128 chars
  fields:             [string],     // required, 1..4 field names
  target_entity:      string,       // required, name of the referenced entity definition
  target_fields:      [string],     // required, 1..4 field names in target entity
  on_delete:          string,       // "restrict" (default) | "cascade" | "set_null"
}

ConstraintDef {
  name:               string,       // required, 1..128 chars
  type:               string,       // "check" | "unique_composite"
  definition:         string,       // For check: expression referencing field names
                                     // For unique_composite: comma-separated field list
}
```

### Validation rules (enforced by `src/entities/validator.zig`)

1. **Name format:** Entity `name` and field `name` must match `[a-z][a-z0-9_]*`, length 1..128.
2. **Field uniqueness:** No two fields in the same definition may share a `name`.
3. **Queried + json exclusion:** A field with `queried: true` MUST NOT have `type: json`. The validator rejects this with a specific error (`FieldQueriedAndJson`). This is acceptance criterion EXP-201-3.
4. **Index field coverage:** Every field referenced in an `IndexDef` must exist in `fields` and must have `queried: true`.
5. **FK field coverage:** Every field in `FKDef.fields` must exist and must have `queried: true`. Every field in `FKDef.target_fields` must exist in the target entity definition.
6. **Enum validation:** If `type: enum`, `validation.values` must be a non-empty array of unique strings, each 1..256 chars.
7. **Decimal validation:** If `type: decimal`, `validation.precision` and `validation.scale` must both be present, with `scale ≤ precision` and `precision` in 1..38.
8. **Max fields:** No more than 64 fields per definition.
9. **Max indexes:** No more than 32 indexes per definition.
10. **Max foreign keys:** No more than 16 foreign keys per definition.
11. **No self-referential FK (Phase 1):** An entity definition may not reference itself in a FK. This is deferred to a later phase.

### Deterministic canonicalisation (EXP-201 acceptance)

Entity definition JSON is canonicalised using the existing `src/repository/canonicaliser.zig` — sorted keys, no whitespace, normalised numbers. The SHA-256 hash of the canonical form is stored as `content_hash` in both `entity_definitions` and the repository artifact system. Two definitions with identical logical content produce identical hashes.

### Logical shape versioning

The **logical shape** of an entity definition is the set of field names, field types, and index declarations. When a new version of an entity definition is created:

1. The canonical form and hash are computed.
2. If the hash matches the latest version's hash → no change, return existing (idempotent).
3. If the hash differs → increment `logical_shape_version` on the `entity_definitions` row.
4. Old logical shapes are retained in `entity_definition_versions` as long as any entity record or in-flight instance references them (pinning, see below).
5. The definition is also registered as a repository artifact (`kind = "entity"`) so it participates in the existing activation and versioning system.

### Definition pinning from instances

When a process instance creates or modifies entity records, the instance's `definition_snapshot` captures the `logical_shape_version` of each entity definition used. This prevents garbage collection of a shape version while instances depend on it. The mechanism mirrors the existing `instance_definition_snapshots` pattern.

---

## Repository artifact integration (EXP-201)

### New artifact kind: "entity"

The existing `ALLOWED_KINDS` array in `src/repository/artifacts.zig` gains `"entity"`:

```
ALLOWED_KINDS = [...existing..., "entity"]
```

When an entity definition is created or updated via the entity API:

1. The definition JSON is stored as a repository artifact with `kind = "entity"`, `name = entity_definition.name`, `content_type = "application/json"`.
2. The repository's existing canonicalisation, deduplication, versioning, and activation machinery applies without modification.
3. Entity definitions also get a dedicated row in `entity_definitions` for fast lookup (denormalised, rebuildable from repository artifacts).

### Lifecycle

- Entity definitions follow the same lifecycle as other repository artifacts: DRAFT → ACTIVE → DEPRECATED → ARCHIVED.
- Activation: `artifact_activations` with `kind = "entity"` tracks which entity definition version is active per tenant.
- Only ACTIVE entity definitions can receive entity command events (CREATE/UPDATE/DELETE).

---

## Entity event family (EXP-202)

### Event types

Three new event types are registered in `event_type_registry`:

**1. ENTITY_RECORD_CREATED**

Payload structure:
```
{
  entity_type:        string,       // entity definition name
  entity_def_version: integer,      // logical_shape_version at create time
  record_id:          string (UUID),
  field_values:       object,       // { field_name: value, ... }
}
```

**2. ENTITY_RECORD_UPDATED**

Payload structure:
```
{
  entity_type:        string,
  entity_def_version: integer,
  record_id:          string (UUID),
  field_values:       object,       // full new state of all fields
  changed_fields:     [string],     // list of field names that changed
}
```

**3. ENTITY_RECORD_DELETED**

Payload structure:
```
{
  entity_type:        string,
  entity_def_version: integer,
  record_id:          string (UUID),
  prior_field_values: object,       // snapshot of values at deletion time
}
```

### Event registration

These three event types are seeded in the migration (`094_entity_subsystem.sql`) into `event_type_registry` with their JSON Schema definitions. This follows the same pattern as `INSTANCE_STARTED`, `TASK_COMPLETED`, etc. in `002_event_type_registry.sql`.

### Event replay guarantee (EXP-202 acceptance)

Replaying all events for a given `(entity_type, record_id)` in `sequence_number` order reproduces the exact current state of the record:

- CREATED: state = `field_values`
- UPDATED: state = merge(state, `field_values`) for keys in `changed_fields`
- DELETED: state = null (record removed)

The projector (`src/entities/projector.zig`) implements this replay logic. It reads events from `entity_events` (or `events` with entity-specific filters) and produces the `entity_record_latest` projection.

### Instance scoping

Entity events are scoped to a synthetic `instance_id` per entity type. This allows the existing event store machinery (sequence numbers, idempotency, global ordering) to work without modification. The mapping is stored in `entity_type_instances`:

```
entity_type_instances {
  entity_type       TEXT PRIMARY KEY,
  instance_id       UUID NOT NULL UNIQUE REFERENCES instances(id),
}
```

On first entity definition activation, a synthetic instance is created. All entity events for that type are appended under that instance_id.

---

## REST API routes

### Entity definition routes

**POST /api/v1/entity-definitions** — Create entity definition

- Input: `EntityDefinition` JSON (see schema above)
- Auth: authenticated user with `EntityDefinitionsManage` permission
- Steps:
  1. Validate definition via `validator.zig`
  2. Canonicalise + hash via `canonicaliser.zig`
  3. Store in `entity_definitions` table
  4. Register as repository artifact (kind = "entity")
  5. Register entity event types in `event_type_registry` if not already present
  6. Create synthetic instance for this entity type
- Success: HTTP 201 + definition JSON with id, content_hash, logical_shape_version
- Errors: 400 (invalid schema), 409 (name already exists), 422 (validation failed), 503 (pool exhausted)

**GET /api/v1/entity-definitions** — List entity definitions

- Query params: `cursor`, `page_size` (standard pagination per API-06)
- Auth: authenticated user with `EntityDefinitionsRead` permission
- Success: HTTP 200 + paginated list
- Errors: 503

**GET /api/v1/entity-definitions/:id** — Get entity definition by ID

- Auth: authenticated user with `EntityDefinitionsRead` permission
- Success: HTTP 200 + definition JSON
- Errors: 404, 503

**GET /api/v1/entity-definitions/name/:name** — Get active entity definition by name

- Auth: authenticated user with `EntityDefinitionsRead` permission
- Returns the currently active version for the caller's tenant
- Success: HTTP 200 + definition JSON
- Errors: 404, 503

### Entity command routes

**POST /api/v1/entities/:type** — Create entity record

- URL param `type`: entity definition name (must be ACTIVE)
- Input: `{ "field_values": { ... }, "idempotency_key": "..." }`
- Auth: authenticated user with `EntityRecordsWrite` permission
- Steps (single transaction):
  1. Load entity definition (active version for tenant)
  2. Validate field_values against definition (required fields present, types match, constraints pass)
  3. Generate `record_id` (UUID v4)
  4. Build ENTITY_RECORD_CREATED event payload
  5. Compute idempotency key (from client-supplied key)
  6. Append event via `event_store.Store.append()`
  7. Upsert `entity_record_latest`
  8. Commit
- Success: HTTP 201 + record JSON `{ "record_id", "entity_type", "field_values", "version_seq" }`
- Idempotent: if idempotency_key already exists → HTTP 200 + existing record
- Errors: 400 (invalid payload), 404 (entity type not found/not active), 422 (validation failed), 409 (unique constraint violated), 503

**PATCH /api/v1/entities/:type/:id** — Update entity record

- URL param `type`: entity definition name
- URL param `id`: record UUID
- Input: `{ "field_values": { ... }, "idempotency_key": "..." }`
- Auth: authenticated user with `EntityRecordsWrite` permission
- Steps (single transaction):
  1. Load entity definition
  2. Load current record state from `entity_record_latest`
  3. If record not found → 404
  4. If record deleted → 410 (Gone)
  5. Merge new field_values with current state to produce full new state
  6. Compute changed_fields (diff of old vs new)
  7. Validate new state against definition
  8. Build ENTITY_RECORD_UPDATED event payload
  9. Append event
  10. Update `entity_record_latest`
  11. Commit
- Success: HTTP 200 + updated record
- Idempotent: same pattern as create
- Errors: 400, 404, 410, 422, 409, 503

**DELETE /api/v1/entities/:type/:id** — Delete entity record

- URL param `type`: entity definition name
- URL param `id`: record UUID
- Input: `{ "idempotency_key": "..." }`
- Auth: authenticated user with `EntityRecordsWrite` permission
- Steps (single transaction):
  1. Load entity definition
  2. Load current record state from `entity_record_latest`
  3. If record not found → 404
  4. If already deleted → 200 (idempotent)
  5. Build ENTITY_RECORD_DELETED event payload
  6. Append event
  7. Mark record deleted in `entity_record_latest` (set `deleted_at`)
  8. Commit
- Success: HTTP 200 + `{ "record_id", "deleted_at" }`
- Idempotent: if already deleted → HTTP 200
- Errors: 404, 503

### Entity query routes (minimal for EXP-202)

**GET /api/v1/entities/:type** — List entity records

- URL param `type`: entity definition name
- Query params: `cursor`, `page_size`, `include_deleted=false`
- Returns paginated list from `entity_record_latest`
- Success: HTTP 200 + paginated list
- Errors: 404 (entity type not found), 503

**GET /api/v1/entities/:type/:id** — Get entity record by ID

- Success: HTTP 200 + record JSON
- Errors: 404, 410 (if deleted), 503

---

## Module structure — new files

| File | Responsibility |
|---|---|
| `src/entities/mod.zig` | Public re-exports, module init/deinit, shared types |
| `src/entities/definition.zig` | Entity definition CRUD: create, read, list, getByType. Manages `entity_definitions` and `entity_definition_versions` tables. Integrates with repository for artifact storage. |
| `src/entities/validator.zig` | Pure validation of entity definition JSON. Checks all rules listed in "Validation rules" above. Returns structured error list with field paths. |
| `src/entities/commands.zig` | Entity record command handlers: createRecord, updateRecord, deleteRecord. Each runs in a single transaction that validates → appends event → updates projection. |
| `src/entities/projector.zig` | Event replay logic: replayStream → current state. rebuildProjection for a full re-projection from event log. For EXP-201/202, produces `entity_record_latest` rows. EXP-203 extends this to generate typed tables. |
| `src/api/routes/entities.zig` | HTTP handler functions for all entity definition and entity command routes listed above. |

### Public interface (type signatures in pseudocode)

```
// src/entities/definition.zig

fn createDefinition(allocator, pool, repository, params: CreateDefinitionParams) !DefinitionRecord
fn getDefinition(allocator, pool, definition_id: Uuid) !DefinitionRecord
fn getDefinitionByName(allocator, pool, tenant_id, name: string) !DefinitionRecord
fn listDefinitions(allocator, pool, opts: ListOpts) ![]DefinitionRecord

CreateDefinitionParams = {
  name:           string,
  display_name:   string,
  description:    string|null,
  fields:         []FieldDef,
  indexes:        []IndexDef,
  foreign_keys:   []FKDef,
  constraints:    []ConstraintDef,
  created_by:     Uuid,
}

DefinitionRecord = {
  id:                     Uuid,
  tenant_id:              Uuid,
  name:                   string,
  display_name:           string,
  description:            string|null,
  definition_json:        string,     // full JSON
  content_hash:           [32]u8,     // SHA-256 of canonical form
  logical_shape_version:  u32,
  status:                 string,     // DRAFT | ACTIVE | DEPRECATED | ARCHIVED
  created_by:             Uuid,
  created_at:             i64,
  updated_at:             i64,
}

// src/entities/validator.zig

fn validateDefinition(allocator, definition_json: string) !void
// Returns void on success. On failure, returns one of:
//   error.InvalidNameFormat
//   error.FieldNameConflict
//   error.FieldQueriedAndJson
//   error.IndexFieldNotQueried
//   error.FKFieldNotQueried
//   error.MissingEnumValues
//   error.InvalidDecimalPrecision
//   error.TooManyFields
//   error.TooManyIndexes
//   error.TooManyForeignKeys
// Detailed per-field errors available via lastValidationErrors()

fn lastValidationErrors(validator) []ValidationError

ValidationError = {
  field_path:    string,    // e.g. "/fields/3/type"
  constraint:    string,    // e.g. "queried_and_json_exclusion"
  message:       string,    // e.g. "Field 'notes' is marked queried=true but type is json"
}

// src/entities/commands.zig

fn createRecord(allocator, pool, store, registry, params: CreateRecordParams) !RecordResult
fn updateRecord(allocator, pool, store, registry, params: UpdateRecordParams) !RecordResult
fn deleteRecord(allocator, pool, store, registry, params: DeleteRecordParams) !RecordResult

CreateRecordParams = {
  entity_type:       string,
  field_values:      map<string, any>,
  idempotency_key:   string,
  actor_id:          Uuid,
  tenant_id:         string,
}

UpdateRecordParams = {
  entity_type:       string,
  record_id:         Uuid,
  field_values:      map<string, any>,
  idempotency_key:   string,
  actor_id:          Uuid,
  tenant_id:         string,
}

DeleteRecordParams = {
  entity_type:       string,
  record_id:         Uuid,
  idempotency_key:   string,
  actor_id:          Uuid,
  tenant_id:         string,
}

RecordResult = {
  record_id:        Uuid,
  entity_type:      string,
  field_values:     map<string, any>,
  version_seq:      i64,
  is_duplicate:     bool,
}

// src/entities/projector.zig

fn replayStream(allocator, events: []EventRecord) !?RecordSnapshot
fn rebuildProjection(allocator, pool, entity_type: string, tenant_id: string) !void

RecordSnapshot = {
  record_id:      Uuid,
  entity_type:    string,
  field_values:   map<string, any>,
  version_seq:    i64,
  deleted:        bool,
}
```

---

## Migration SQL structure

**File:** `migrations/094_entity_subsystem.sql`

### Table: entity_definitions

Stores one row per entity definition version. Denormalised from repository artifacts for fast lookup.

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | UUID | PK DEFAULT gen_random_uuid() | Definition version ID |
| tenant_id | UUID | NOT NULL | Owning tenant |
| name | TEXT | NOT NULL | Machine name (e.g. "customer") |
| display_name | TEXT | NOT NULL | Human-readable name |
| description | TEXT | | Optional description |
| definition_json | JSONB | NOT NULL | Full definition JSON |
| content_hash | BYTEA | NOT NULL | SHA-256 of canonical form (32 bytes) |
| logical_shape_version | INTEGER | NOT NULL DEFAULT 1 | Incremented on shape change |
| artifact_version_id | UUID | NOT NULL REFERENCES artifact_versions(version_id) | Link to repository artifact |
| status | TEXT | NOT NULL DEFAULT 'DRAFT' | DRAFT, ACTIVE, DEPRECATED, ARCHIVED |
| created_by | UUID | NOT NULL | User who created |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Creation time |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last modification |

**Unique constraint:** (tenant_id, name, logical_shape_version)

**Indexes:**
- idx_entity_defs_tenant_name on (tenant_id, name)
- idx_entity_defs_status on (tenant_id, status)
- idx_entity_defs_content_hash on (content_hash)

### Table: entity_type_instances

Maps entity type names to synthetic instance IDs for event store integration.

| Column | Type | Constraints | Description |
|---|---|---|---|
| entity_type | TEXT | PK | Entity definition name |
| tenant_id | UUID | NOT NULL | Owning tenant |
| instance_id | UUID | NOT NULL UNIQUE REFERENCES instances(id) | Synthetic instance for event appending |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Creation time |

### Table: entity_record_latest

Projection table — one row per entity record, updated atomically with each event.

| Column | Type | Constraints | Description |
|---|---|---|---|
| tenant_id | UUID | NOT NULL | Owning tenant |
| entity_type | TEXT | NOT NULL | Entity definition name |
| record_id | UUID | NOT NULL | Record identifier |
| current_state | JSONB | NOT NULL DEFAULT '{}' | Current field values |
| version_seq | BIGINT | NOT NULL DEFAULT 0 | Number of applied events |
| entity_def_version | INTEGER | NOT NULL | logical_shape_version at last write |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation time |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last modification |
| deleted_at | TIMESTAMPTZ | | Set when record is deleted |

**Primary key:** (entity_type, record_id)

**Unique constraint:** (tenant_id, entity_type, record_id)

**Indexes:**
- idx_erl_tenant_type on (tenant_id, entity_type)
- idx_erl_tenant_type_updated on (tenant_id, entity_type, updated_at DESC) — for keyset pagination

### Seed data: entity event types

INSERT into `event_type_registry`:

- ENTITY_RECORD_CREATED with JSON Schema validating `entity_type`, `entity_def_version`, `record_id`, `field_values`
- ENTITY_RECORD_UPDATED with JSON Schema adding `changed_fields`
- ENTITY_RECORD_DELETED with JSON Schema using `prior_field_values`

### Extension to artifact kinds

The migration also adds "entity" to the allowed artifact kinds. Since `ALLOWED_KINDS` is enforced in Zig code (not in SQL), this is a code-only change — no migration DDL needed for this part.

### Additive / rollback-safe

- All tables are new (CREATE TABLE IF NOT EXISTS).
- Event type registrations are INSERT ... ON CONFLICT DO NOTHING.
- No existing tables are modified.
- Rollback: DROP TABLE entity_record_latest, entity_type_instances, entity_definitions; DELETE event_type_registry rows for entity event types.

---

## Error taxonomy

### EntityDefinitionError

| Error | HTTP | Description |
|---|---|---|
| InvalidNameFormat | 422 | Entity or field name does not match `[a-z][a-z0-9_]*` |
| FieldNameConflict | 422 | Two fields share the same name |
| FieldQueriedAndJson | 422 | Field marked `queried: true` with `type: json` (EXP-201 acceptance criterion) |
| IndexFieldNotQueried | 422 | Index references a field without `queried: true` |
| FKFieldNotQueried | 422 | FK references a field without `queried: true` |
| FKTargetNotFound | 422 | FK target entity definition does not exist |
| MissingEnumValues | 422 | Enum field has no `validation.values` |
| InvalidDecimalSpec | 422 | Decimal field has missing/invalid precision or scale |
| TooManyFields | 422 | Definition exceeds 64 fields |
| TooManyIndexes | 422 | Definition exceeds 32 indexes |
| TooManyForeignKeys | 422 | Definition exceeds 16 foreign keys |
| DefinitionNotFound | 404 | Entity definition ID does not exist |
| DefinitionNameExists | 409 | Entity definition name already exists for tenant |
| DefinitionNotActive | 422 | Entity definition is not in ACTIVE status |
| PoolExhausted | 503 | Database pool exhausted |
| TransactionFailed | 500 | Multi-table transaction failed |

### EntityCommandError

| Error | HTTP | Description |
|---|---|---|
| EntityTypeNotFound | 404 | Entity type name not found or not active |
| RecordNotFound | 404 | Record ID does not exist for this entity type |
| RecordDeleted | 410 | Record was previously deleted |
| FieldValidationError | 422 | One or more field values fail validation (type, required, constraints) |
| UniqueConstraintViolation | 409 | Field value violates a unique constraint |
| FKConstraintViolation | 422 | Field value references non-existent parent record |
| IdempotencyKeyMissing | 422 | No idempotency_key provided |
| PoolExhausted | 503 | Database pool exhausted |
| TransactionFailed | 500 | Multi-table transaction failed |
| EventAppendFailed | 500 | Underlying event store append failed |

### HTTP error responses

All errors use the existing RFC 9457 Problem Details format from `src/api/errors.zig`. Example for `FieldQueriedAndJson`:

```
{
  "type": "https://bpm.example.com/problems/entity-field-queried-and-json",
  "title": "Field cannot be both queried and JSON",
  "status": 422,
  "detail": "Field 'notes' is marked queried=true but type is json. Queried fields become typed projection columns and cannot be free-form JSON.",
  "trace_id": "..."
}
```

---

## Cross-module dependencies

### Depends on

| Module | What is used | Why |
|---|---|---|
| `src/repository/artifacts.zig` | `Artifacts.create()`, `ALLOWED_KINDS` extension | Store entity definitions as repository artifacts |
| `src/repository/canonicaliser.zig` | `canonicaliseJson()`, `hashContent()` | Deterministic hashing of entity definitions |
| `src/repository/activation.zig` | `Activation.activateGroup()` | Activate entity definitions per tenant |
| `src/event_store/store.zig` | `Store.append()`, `Store.read()` | Append entity events, read event streams for replay |
| `src/event_store/registry.zig` | `Registry.registerType()`, `Registry.validatePayload()` | Register and validate entity event payloads |
| `src/db/pool.zig` | `Pool`, transactions | Database access |
| `src/api/errors.zig` | `ProblemDetails`, error builders | HTTP error responses |
| `src/api/pagination.zig` | `PaginationOpts`, cursor encode/decode | List endpoints |
| `src/api/authorization.zig` | Permission checks | New permissions: `EntityDefinitionsManage`, `EntityDefinitionsRead`, `EntityRecordsWrite`, `EntityRecordsRead` |

### Must NOT depend on

| Module | Why |
|---|---|
| `src/engine/transition.zig` | Transition function is pure (zero I/O rule) |
| `src/scheduler/*` | Entity events are not timer-driven |
| `src/webhook/*` | No outbound webhook delivery needed |
| `src/identity/tokens.zig` | Auth is handled by upstream middleware, not by entity code |

### Extends (for future phases)

| Future requirement | What this design enables |
|---|---|
| EXP-203 (typed projection tables) | `projector.zig` will generate DDL from the entity definition's `queried` fields and `indexes` |
| EXP-204 (re-projection) | Logical shape versioning + event replay supports zero-downtime schema evolution |
| EXP-205 (query API) | `entity_record_latest` provides the read surface; EXP-203 adds typed columns for filter/sort |
| EXP-206 (optimistic concurrency) | `version_seq` on entity_record_latest is the CAS token |

---

## Open questions

1. **Entity type ownership model:** Should entity definitions be tenant-scoped (each tenant defines their own "customer" entity) or platform-scoped (shared entity types)? The current design assumes tenant-scoped definitions with `tenant_id` on all tables. If shared definitions are needed, a separate `platform_entity_definitions` table would be required. Deferring to REQ-ANALYST.

2. **Entity record instance_id strategy:** The current design uses one synthetic instance per entity type (via `entity_type_instances`). An alternative is one synthetic instance per entity record. The per-type approach keeps the event count per instance manageable and aligns with the event store's instance-scoped sequence numbering. The per-record approach would give each record its own event stream but create many instances. Deferring this decision is safe — the table structure supports either model via a migration.

3. **Bulk operations:** The current design handles one record at a time. Bulk create/update/delete is a future enhancement (EXP-205 era) and would use batch event appending within a single transaction. No design change needed now.

---

## Acceptance criteria mapping

| Criterion | Design element |
|---|---|
| EXP-201-1: An entity definition canonicalises + hashes deterministically | Canonicalisation via `repository/canonicaliser.zig`; SHA-256 stored in `entity_definitions.content_hash` |
| EXP-201-2: Logical-shape versions are retained while referenced | `entity_definitions.logical_shape_version` incremented on shape change; old versions preserved in table; pinning via `instance_definition_snapshots` pattern |
| EXP-201-3: Validator rejects a field marked both queried and JSONB-only | `validator.zig` → `error.FieldQueriedAndJson` |
| EXP-202-1: A create/update/delete appends exactly one event | `commands.zig` transaction: validate → append one event → update projection |
| EXP-202-2: Replaying the stream reproduces record state | `projector.zig.replayStream()` applies CREATED/UPDATED/DELETED events in sequence order |
| EXP-202-3: Idempotent re-submit is a no-op | Idempotency key passed to `event_store.Store.append()` → `is_duplicate = true` → HTTP 200 with existing record |
