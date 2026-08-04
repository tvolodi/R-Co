# Module: repository

**Covers:** REPO-01, REPO-02, REPO-03, REPO-04, REPO-05, REPO-06, REPO-07, REPO-08, REPO-09, REPO-10, REPO-11, REPO-12, REPO-13, REPO-14  
**Files:** `src/repository/artifacts.zig`, `src/repository/canonicaliser.zig`, `src/repository/schemas.zig`, `src/repository/service_catalog.zig`, `src/repository/activation.zig`  
**Related:** DB-03 (atomic writes), API-06 (pagination), OBS-03 (audit log), ES-05 (event type registry), PD-* (definition engine)

---

## Module purpose

The repository module is the versioned, content-addressed artifact store. It is the source of truth for all platform artifacts: process definitions, form schemas, event type registries, Lua scripts, Wasm modules, projections, and test scenarios. Every artifact is immutably stored under a SHA-256 hash of its canonical serialisation, with full versioning and parent linkage. Multiple versions of the same artifact can exist and be activated independently per tenant, with atomic multi-artifact activation and a complete audit trail of all activations.

---

## Module boundaries

- `src/repository/artifacts.zig`
  - Artifact storage contract, deduplication logic, versioning and parent-linkage queries.
  - All database operations on `repository_artifacts`, `artifact_versions`.
  - Owns content addressing (SHA-256 hash computation and validation).
  - Owns immutability enforcement.

- `src/repository/canonicaliser.zig`
  - Pure function: canonical serialisation of JSON artifacts (sorted keys, normalised whitespace and numbers).
  - Binary artifacts (Wasm, etc.) are hashed by byte identity (no canonicalisation).
  - Owns comparison of content equality pre-deduplication.

- `src/repository/schemas.zig`
  - Form schema indexing and queryability by field name, type, label.
  - Database operations on `form_schema_registry`.
  - Search and aggregation queries for agent-driven schema discovery.

- `src/repository/service_catalog.zig`
  - Service registration with endpoint URL, request/response schemas, required auth.
  - Extends event_store registry (ES-05) with service definitions used by SERVICE_TASK nodes and Lua service calls.
  - Database operations on `service_catalog`.
  - Dependency validation (definition registration checks service catalog).

- `src/repository/activation.zig`
  - Tenant-scoped artifact activation.
  - Atomic multi-artifact activation (activation groups).
  - Activation history audit trail per tenant.
  - Database operations on `artifact_activations`, `artifact_activation_history`.

Out of scope:
- Direct definition parsing or validation (owned by definition module).
- Event store event type registry (ES-05) — repository extends it, does not own it.
- Tenant isolation enforcement — owned by auth/identity modules; repository respects tenant context passed by caller.

---

## Design decisions

### Content addressing (REPO-01, REPO-02)

1. **SHA-256 hashing:** Every artifact is stored under a SHA-256 hash of its canonical form. Equal content produces equal hashes and deduplicates to the same storage.

2. **Immutability by design:** The database schema makes immutability natural:
   - `repository_artifacts.content_hash` is the PRIMARY KEY; there is no UPDATE statement that modifies committed content.
   - An attempt to "update" an artifact returns an error (`ArtifactImmutable`).
   - A PUT with different content produces a new version record pointing to a different hash (new `repository_artifacts` row if the hash is new, or deduplication if the hash already exists).

3. **Deduplication:** Before inserting into `repository_artifacts`, a query checks `SELECT * FROM repository_artifacts WHERE content_hash = $1`. If found, the new version links to the existing artifact row without duplicating storage.

### Canonical serialisation (REPO-04)

1. **JSON artifacts** (definitions, forms, schemas, test scenarios):
   - Keys are sorted alphabetically.
   - All insignificant whitespace is removed (output is single-line).
   - Numbers are normalised: integers without decimal point; no exponent notation unless required.
   - `null` values are preserved as-is.
   - Arrays maintain their original order.

2. **Binary artifacts** (Wasm modules, compiled Lua bytecode):
   - Canonical form is byte identity; no transformation.
   - Hash is computed directly on the uploaded bytes.

3. **Canonicaliser module** provides:
   ```zig
   pub fn canonicaliseJson(allocator, json_bytes) -> canonical_bytes
   pub fn hashContent(content_bytes, content_type) -> [32]u8  // SHA-256
   ```

### Versioning with parent linkage (REPO-03)

1. Each named artifact can have multiple versions:
   - `artifact_name` (e.g., "order_process_definition", "invoice_form")
   - `artifact_kind` (e.g., "definition", "form", "schema", "service_catalog")
   - `version_number` (monotonically increasing per name+kind; starts at 1)

2. Parent linkage:
   - `artifact_versions.parent_version_id` is nullable.
   - When a developer creates version 2 of "order_process_definition", they optionally specify version 1 as parent (or null if unrelated).
   - Lineage query returns ordered list with parent pointers.

3. Versioning queries:
   ```zig
   pub fn listVersions(
       kind: []const u8,
       name: []const u8,
       opts: PaginationOpts,
   ) ![]ArtifactVersionRecord
   ```
   Returns versions in chronological order (creation_at ASC) with pagination support (API-06).

### Schema registries (REPO-05, REPO-06)

1. **Form schema indexing (REPO-05):**
   - Every form schema is indexed by field name, type (string, number, date, enum, currency, etc.), and display label.
   - `form_schema_registry(artifact_version_id, field_name, field_type, field_label)` enables agent queries like:
     ```sql
     SELECT DISTINCT artifact_version_id FROM form_schema_registry
     WHERE field_type = 'currency' AND field_label LIKE 'Amount%'
     ```
   - Full-text search on labels is supported via PostgreSQL GIN index.

2. **Event type registry extension (REPO-06):**
   - REPO-06 registers event types used in any active definition, with name, JSON schema, and producing definitions.
   - This registry **extends** ES-05 (the event store's event type registry):
     - ES-05 is the working registry used at runtime for schema validation of incoming events.
     - REPO-06 is the platform-wide catalog of all event types used across all definitions, linked to their producer definitions.
   - `event_type_registry_producers(event_type_id, definition_version_id)` links an event type to the definition(s) that produce it.
   - Activation of a definition that uses an unregistered event type is rejected.

### Service catalog (REPO-07)

1. Service registration includes:
   - `service_id` — unique stable identifier (e.g., "crm.customer_lookup")
   - `endpoint_url` — HTTPS endpoint to invoke
   - `request_schema` — JSON Schema for the request body
   - `response_schema` — JSON Schema for the response body
   - `required_auth` — authentication method required (enum: NONE, API_KEY, OAUTH2, MUTUAL_TLS)
   - `timeout_ms` — maximum request duration
   - `retry_policy` — backoff strategy

2. Service references:
   - SERVICE_TASK nodes reference a service by `service_id`.
   - Definition activation checks that all referenced services exist in `service_catalog`.
   - Lua `service.call()` uses the catalog to route and validate requests/responses.

3. Service catalog queries:
   ```zig
   pub fn getService(service_id: []const u8) !ServiceRecord
   pub fn listServices(opts: PaginationOpts) ![]ServiceRecord
   ```

### Atomic activation (REPO-08, REPO-09)

1. **Atomic multi-artifact activation:**
   - An activation group can include a definition version, its referenced form schemas, service catalog entries, and dependencies.
   - All artifacts in the group are activated in a single transaction; partial activation is impossible.
   - Within the transaction:
     - All `artifact_activations(tenant_id, artifact_kind, artifact_name)` rows for the group are inserted or updated.
     - An `artifact_activation_history` record is inserted (audit trail).
     - All succeed or all roll back.

2. **Per-tenant activation (REPO-09):**
   - Each tenant has independent active versions per artifact.
   - Activation is scoped: `artifact_activations(tenant_id, artifact_kind, artifact_name, active_version_id)`.
   - Activating in tenant A does not affect tenant B.
   - Queries are always tenant-filtered: `SELECT * FROM artifact_activations WHERE tenant_id = $1 AND ...`

### Activation history (REPO-10)

1. Every activation is recorded in `artifact_activation_history`:
   - `history_id` (UUID)
   - `tenant_id` (UUID)
   - `artifact_kind` (string)
   - `artifact_name` (string)
   - `previous_version_id` (nullable — what was active before)
   - `new_version_id` (UUID — what is now active)
   - `activator_user_id` (UUID — who initiated the activation)
   - `activated_at` (UTC timestamp)
   - `rationale` (free text — why this activation was done)

2. Activation history queries return full chronological record per tenant and artifact.

3. Activations are also written to the audit log (`OBS-03`):
   - `action = "artifact_activation.activate"`
   - `resource_type = "artifact"`
   - `resource_id = artifact_version_id`
   - `before_state` and `after_state` contain the affected definitions/schemas/etc.

---

## API endpoints

### REPO-11 — Create artifact

**POST /repository/artifacts**

Request body:
```json
{
  "kind": "definition",
  "name": "order_process",
  "content": "<JSON or binary bytes, base64 if binary>",
  "content_type": "application/json | application/wasm",
  "description": "Order processing workflow"
}
```

Response (201 Created):
```json
{
  "artifact_id": "uuid",
  "content_hash": "sha256-hex",
  "version_id": "uuid",
  "kind": "definition",
  "name": "order_process",
  "version_number": 1,
  "created_by": "user-uuid",
  "created_at": "2026-05-28T10:30:00Z",
  "is_duplicate": false
}
```

**Behavior:**
- Canonicalises content (if JSON) and computes SHA-256 hash.
- Checks if hash already exists in `repository_artifacts`.
- If yes: reuses existing artifact, increments version counter for the (kind, name) pair, inserts new `artifact_versions` row. Returns 200 with `is_duplicate = true`.
- If no: inserts new `repository_artifacts` row, inserts new `artifact_versions` row. Returns 201 with `is_duplicate = false`.

**Errors:**
- 400: invalid kind / name too long / description too long
- 409: if the submitted content is malformed (e.g., invalid JSON for kind="definition")
- 500: DB transaction failed

### REPO-12 — List versions

**GET /repository/{kind}/{name}/versions?cursor=&limit=20**

Response (200 OK):
```json
{
  "versions": [
    {
      "version_id": "uuid",
      "version_number": 1,
      "content_hash": "sha256-hex",
      "parent_version_id": null,
      "created_by": "user-uuid",
      "created_at": "2026-05-28T10:00:00Z",
      "description": "Initial version"
    },
    {
      "version_id": "uuid",
      "version_number": 2,
      "content_hash": "different-sha256-hex",
      "parent_version_id": "uuid-of-version-1",
      "created_by": "user-uuid",
      "created_at": "2026-05-28T10:30:00Z",
      "description": "Bugfix: fixed gateway condition"
    }
  ],
  "cursor": "...",
  "has_next": false
}
```

**Behavior:**
- Returns all versions for the given (kind, name) in chronological order (creation_at ASC).
- Supports cursor-based pagination (API-06).
- Includes parent version linkage.

**Errors:**
- 404: kind or name not found in repository

### REPO-13 — Tenant activations

**GET /tenants/{tenant_id}/activations?kind=definition&name=order_process**

Response (200 OK):
```json
{
  "activations": [
    {
      "artifact_kind": "definition",
      "artifact_name": "order_process",
      "active_version_id": "uuid",
      "version_number": 2,
      "content_hash": "sha256-hex",
      "activated_at": "2026-05-28T12:00:00Z",
      "activator_user_id": "user-uuid"
    },
    {
      "artifact_kind": "form",
      "artifact_name": "order_form",
      "active_version_id": "uuid",
      "version_number": 1,
      "content_hash": "sha256-hex",
      "activated_at": "2026-05-28T11:50:00Z",
      "activator_user_id": "user-uuid"
    }
  ]
}
```

**Behavior:**
- Returns active versions per artifact (kind, name) for the given tenant.
- Optional filters by artifact kind and/or name.
- Requires authentication and tenant context from API caller.

**Errors:**
- 403: caller is not in the specified tenant
- 404: tenant not found

### POST /repository/activations

Request body:
```json
{
  "activation_group": [
    {
      "artifact_kind": "definition",
      "artifact_name": "order_process",
      "version_id": "uuid"
    },
    {
      "artifact_kind": "form",
      "artifact_name": "order_form",
      "version_id": "uuid"
    }
  ],
  "rationale": "Promotion from staging to production"
}
```

Response (200 OK):
```json
{
  "group_id": "uuid",
  "activated": [
    {
      "artifact_kind": "definition",
      "artifact_name": "order_process",
      "version_number": 2,
      "previous_version_id": "uuid-of-old-version"
    }
  ],
  "timestamp": "2026-05-28T12:00:00Z"
}
```

**Behavior (atomic):**
- All artifacts in the group are activated in a single transaction.
- For each artifact, a new `artifact_activations` row is inserted or the existing row is updated.
- An `artifact_activation_history` record is inserted for the entire group.
- All state-changing operations commit together or all rollback together.
- Validation (e.g., definition references valid services) happens before the transaction.

**Errors:**
- 400: invalid version_id / artifact kind not found
- 409: if a referenced service or dependent artifact is not found in repository
- 422: if definition validation fails (graph, service catalog references)
- 503: transaction failed / pool exhausted

### GET /repository/{kind}/{name}/activation-history?tenant_id=&limit=50&cursor=

Response (200 OK):
```json
{
  "history": [
    {
      "history_id": "uuid",
      "previous_version_id": null,
      "new_version_id": "uuid",
      "new_version_number": 1,
      "activator_user_id": "user-uuid",
      "activated_at": "2026-05-28T10:30:00Z",
      "rationale": "Initial production deployment"
    },
    {
      "history_id": "uuid",
      "previous_version_id": "uuid",
      "new_version_id": "uuid",
      "new_version_number": 2,
      "activator_user_id": "user-uuid",
      "activated_at": "2026-05-28T12:00:00Z",
      "rationale": "Hotfix for edge case in gateway evaluation"
    }
  ],
  "cursor": "...",
  "has_next": false
}
```

**Behavior:**
- Returns activation history in reverse chronological order (most recent first).
- Filtered by tenant_id (from caller's auth context).
- Supports cursor-based pagination.

---

## Public interface

### artifacts.zig

```zig
pub const ArtifactsError = error{
    PoolExhausted,           // DB pool exhausted → HTTP 503
    ContentHashInvalid,      // Hash verification failed → HTTP 400
    ImmutableViolation,      // Attempt to update committed artifact → HTTP 409
    UnknownArtifactKind,     // Kind not supported → HTTP 400
    NameTooLong,             // name > 255 chars → HTTP 400
    NameEmpty,               // name is "" → HTTP 400
    DescriptionTooLong,      // description > 4096 chars → HTTP 400
    ArtifactNotFound,        // artifact_id does not exist → HTTP 404
    VersionNotFound,         // version_id does not exist → HTTP 404
    InvalidParentVersion,    // parent_version_id not in repository → HTTP 422
    TransactionFailed,       // DB transaction failed → HTTP 500
};

pub const ArtifactRecord = struct {
    artifact_id:   [16]u8,        // UUID
    content_hash:  [32]u8,        // SHA-256
    content_type:  []const u8,    // "application/json", "application/wasm"
    byte_size:     u64,           // Size of stored content
    created_at:    i64,           // UTC microseconds
};

pub const ArtifactVersionRecord = struct {
    version_id:         [16]u8,   // UUID
    artifact_id:        [16]u8,   // Refers to ArtifactRecord
    artifact_kind:      []const u8,    // "definition", "form", "schema", "service_catalog", "script", "module", "scenario"
    artifact_name:      []const u8,    // Semantic name of the artifact
    version_number:     u32,      // Monotonic per (kind, name)
    content_hash:       [32]u8,   // SHA-256 of canonical content
    parent_version_id:  ?[16]u8,  // Optional parent for lineage
    created_by:         [16]u8,   // User UUID
    created_at:         i64,      // UTC microseconds
    description:        ?[]const u8,  // Optional free-text description
};

pub const CreateArtifactParams = struct {
    kind:           []const u8,
    name:           []const u8,
    content:        []const u8,
    content_type:   []const u8,   // "application/json" or "application/wasm"
    description:    ?[]const u8,
    parent_version_id: ?[16]u8,   // Optional parent for lineage
    created_by:     [16]u8,        // Actor user_id
};

pub const CreateArtifactResult = struct {
    artifact_record:     ArtifactRecord,
    version_record:      ArtifactVersionRecord,
    is_duplicate:        bool,  // true → hash already existed; content deduplicated
};

pub const ListVersionsOpts = struct {
    kind:           []const u8,
    name:           []const u8,
    after_version:  ?[16]u8,  // Cursor for pagination
    limit:          u32,      // 1..1000; default 100
};

pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) Artifacts;

pub fn deinit(self: *Artifacts) void;

/// Create or deduplicate an artifact. Canonicalises JSON and computes SHA-256.
/// Returns (artifact_record, version_record, is_duplicate).
pub fn create(
    self: *Artifacts,
    allocator: std.mem.Allocator,
    params: CreateArtifactParams,
) ArtifactsError!CreateArtifactResult;

/// Fetch a single version record by version_id.
pub fn getVersion(
    self: *Artifacts,
    allocator: std.mem.Allocator,
    version_id: [16]u8,
) ArtifactsError!ArtifactVersionRecord;

/// Fetch a single artifact record by content_hash.
pub fn getArtifact(
    self: *Artifacts,
    allocator: std.mem.Allocator,
    content_hash: [32]u8,
) ArtifactsError!ArtifactRecord;

/// List versions for (kind, name), paginated.
pub fn listVersions(
    self: *Artifacts,
    allocator: std.mem.Allocator,
    opts: ListVersionsOpts,
) ArtifactsError![]ArtifactVersionRecord;

/// Retrieve the active version for a given (tenant_id, artifact_kind, artifact_name).
/// Returns VersionNotFound if nothing is active for this artifact in this tenant.
pub fn getActiveVersion(
    self: *Artifacts,
    allocator: std.mem.Allocator,
    tenant_id: [16]u8,
    artifact_kind: []const u8,
    artifact_name: []const u8,
) ArtifactsError!ArtifactVersionRecord;
```

### canonicaliser.zig

```zig
pub const CanonicaliserError = error{
    OutOfMemory,
    InvalidJson,  // Malformed JSON input
    InvalidBinary, // Binary content has invalid header (e.g., bad Wasm magic)
};

/// Pure function: canonicalise JSON by sorting keys, removing whitespace,
/// normalising numbers. Output is deterministic and reversible per input.
pub fn canonicaliseJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) CanonicaliserError![]const u8;

/// Compute SHA-256 hash of content (after canonicalisation for JSON, byte-identity for binary).
/// Returns 32-byte SHA-256 digest.
pub fn hashContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    content_type: []const u8,  // "application/json" or "application/wasm"
) CanonicaliserError![32]u8;

/// Verify that a given content's hash matches expected_hash.
/// Used for integrity checks on artifact retrieval.
pub fn verifyHash(
    allocator: std.mem.Allocator,
    content: []const u8,
    content_type: []const u8,
    expected_hash: [32]u8,
) CanonicaliserError!bool;
```

### schemas.zig

```zig
pub const SchemasError = error{
    PoolExhausted,
    FieldNameTooLong,      // > 255 chars
    FieldNameEmpty,        // ""
    FieldTypeTooLong,      // > 128 chars
    FieldTypeMissing,
    FieldLabelTooLong,     // > 4096 chars
    FormNotFound,          // version_id not found
    InvalidIndexing,       // Malformed schema document
    TransactionFailed,
};

pub const FormSchemaField = struct {
    field_name:  []const u8,
    field_type:  []const u8,  // "string", "number", "date", "enum", "currency", etc.
    field_label: []const u8,  // User-visible label
    required:    bool,
    pattern:     ?[]const u8, // Regex or null
};

pub const FormSchemaIndexParams = struct {
    version_id:   [16]u8,   // Refers to ArtifactVersionRecord
    artifact_name: []const u8,
    fields:       []FormSchemaField,
};

pub const FormSchemaSearchOpts = struct {
    field_type:  ?[]const u8,      // Filter by type, e.g., "currency"
    field_name:  ?[]const u8,      // Exact match or substring
    field_label: ?[]const u8,      // Substring match (case-insensitive)
    after_field: ?[]const u8,      // Cursor for pagination
    limit:       u32,              // 1..1000; default 100
};

pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) Schemas;

pub fn deinit(self: *Schemas) void;

/// Index a form schema by parsing and extracting all fields.
/// Called when a form artifact is activated.
pub fn indexSchema(
    self: *Schemas,
    allocator: std.mem.Allocator,
    params: FormSchemaIndexParams,
) SchemasError!void;

/// Search form schemas by field type, name, or label. Returns deduplicated list of artifact versions.
pub fn searchSchemas(
    self: *Schemas,
    allocator: std.mem.Allocator,
    opts: FormSchemaSearchOpts,
) SchemasError![]FormSchemaField;

/// Clear all index entries for a given version_id (e.g., when deactivating).
pub fn clearIndex(
    self: *Schemas,
    allocator: std.mem.Allocator,
    version_id: [16]u8,
) SchemasError!void;
```

### service_catalog.zig

```zig
pub const CatalogError = error{
    PoolExhausted,
    ServiceIdTooLong,      // > 255 chars
    ServiceIdEmpty,        // ""
    ServiceIdInvalid,      // Invalid characters
    ServiceNotFound,       // service_id does not exist → HTTP 404
    DuplicateService,      // service_id already registered → HTTP 409
    InvalidAuthMethod,     // Unknown enum value → HTTP 400
    InvalidSchema,         // request_schema or response_schema not valid JSON Schema → HTTP 400
    EndpointUrlInvalid,    // Malformed URL → HTTP 400
    TimeoutInvalid,        // timeout_ms <= 0 or > 3600000 → HTTP 400
    TransactionFailed,
};

pub const AuthMethod = enum {
    NONE,
    API_KEY,
    OAUTH2,
    MUTUAL_TLS,
};

pub const ServiceCatalogRecord = struct {
    service_id:      []const u8,
    endpoint_url:    []const u8,
    request_schema:  []const u8,     // JSON Schema bytes
    response_schema: []const u8,      // JSON Schema bytes
    required_auth:   AuthMethod,
    timeout_ms:      u32,             // 1..3600000
    retry_policy:    []const u8,      // JSON object: {"strategy": "exponential", "max_attempts": 3}
    created_at:      i64,             // UTC microseconds
    updated_at:      i64,
};

pub const RegisterServiceParams = struct {
    service_id:      []const u8,
    endpoint_url:    []const u8,
    request_schema:  []const u8,
    response_schema: []const u8,
    required_auth:   AuthMethod,
    timeout_ms:      u32,
    retry_policy:    ?[]const u8,     // null → default {"strategy": "exponential", "max_attempts": 3}
};

pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) ServiceCatalog;

pub fn deinit(self: *ServiceCatalog) void;

/// Register a new service or update an existing one.
pub fn register(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    params: RegisterServiceParams,
) CatalogError!ServiceCatalogRecord;

/// Fetch a service by ID.
pub fn getService(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    service_id: []const u8,
) CatalogError!ServiceCatalogRecord;

/// List all registered services, paginated.
pub fn listServices(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    after_id: ?[]const u8,
    limit: u32,
) CatalogError![]ServiceCatalogRecord;

/// Check if a service exists (used for validation during definition registration).
pub fn exists(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    service_id: []const u8,
) CatalogError!bool;
```

### activation.zig

```zig
pub const ActivationError = error{
    PoolExhausted,
    ArtifactNotFound,          // version_id does not exist → HTTP 404
    ServiceNotFound,           // Referenced service not in catalog → HTTP 409
    DefinitionValidationFailed, // Graph validation failed → HTTP 422
    InvalidActivationGroup,    // Empty group or duplicates → HTTP 400
    TenantNotFound,            // tenant_id does not exist → HTTP 404
    RationaleTooLong,          // > 4096 chars → HTTP 400
    TransactionFailed,
    InvalidArtifactKind,       // Kind not in supported list → HTTP 400
};

pub const ArtifactActivation = struct {
    activation_id:     [16]u8,
    tenant_id:         [16]u8,
    artifact_kind:     []const u8,
    artifact_name:     []const u8,
    active_version_id: [16]u8,
    activated_at:      i64,      // UTC microseconds
    activator_user_id: [16]u8,
};

pub const ActivationHistoryRecord = struct {
    history_id:         [16]u8,
    tenant_id:          [16]u8,
    artifact_kind:      []const u8,
    artifact_name:      []const u8,
    previous_version_id: ?[16]u8,  // null if first activation
    new_version_id:     [16]u8,
    new_version_number: u32,
    activator_user_id:  [16]u8,
    activated_at:       i64,       // UTC microseconds
    rationale:          []const u8,
};

pub const ActivationGroupMember = struct {
    artifact_kind: []const u8,
    artifact_name: []const u8,
    version_id:    [16]u8,
};

pub const ActivateGroupParams = struct {
    tenant_id: [16]u8,
    group:     []ActivationGroupMember,  // ≥ 1 member
    activator_user_id: [16]u8,
    rationale: []const u8,               // 1..4096 chars
};

pub const ActivateGroupResult = struct {
    group_id:   [16]u8,
    activated:  []ArtifactActivation,     // Same-length as params.group
    timestamp:  i64,                      // UTC microseconds
};

pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, artifacts: *Artifacts) Activation;

pub fn deinit(self: *Activation) void;

/// Atomically activate a group of artifacts for a tenant.
/// All or nothing: either the entire group is activated and history recorded, or transaction rolls back.
/// Pre-activation validation:
///   - Each version_id must exist and match the specified (kind, name).
///   - If any artifact is a definition: call definition.validate() to check graph and service references.
///   - If any artifact is a form: call schemas.indexSchema() to update searchability.
/// Post-validation, all updates happen in a single transaction.
pub fn activateGroup(
    self: *Activation,
    allocator: std.mem.Allocator,
    params: ActivateGroupParams,
) ActivationError!ActivateGroupResult;

/// Fetch the currently active version for a single artifact in a tenant.
pub fn getActive(
    self: *Activation,
    allocator: std.mem.Allocator,
    tenant_id: [16]u8,
    artifact_kind: []const u8,
    artifact_name: []const u8,
) ActivationError!?ArtifactActivation;

/// List all active artifacts for a tenant, with optional kind/name filter.
pub fn listActive(
    self: *Activation,
    allocator: std.mem.Allocator,
    tenant_id: [16]u8,
    filter_kind: ?[]const u8,
    filter_name: ?[]const u8,
    after_id: ?[16]u8,
    limit: u32,
) ActivationError![]ArtifactActivation;

/// Fetch activation history for a single artifact, paginated.
pub fn listActivationHistory(
    self: *Activation,
    allocator: std.mem.Allocator,
    tenant_id: [16]u8,
    artifact_kind: []const u8,
    artifact_name: []const u8,
    after_id: ?[16]u8,
    limit: u32,
) ActivationError![]ActivationHistoryRecord;
```

---

## Data types

### ArtifactRecord
| Field | Type | Notes |
|---|---|---|
| `artifact_id` | UUID | Primary identifier; immutable |
| `content_hash` | bytes[32] | SHA-256 digest; PRIMARY KEY in repository_artifacts |
| `content_type` | string | "application/json" or "application/wasm" |
| `byte_size` | u64 | Stored content size in bytes |
| `created_at` | i64 | UTC microseconds; never changes |

### ArtifactVersionRecord
| Field | Type | Notes |
|---|---|---|
| `version_id` | UUID | Primary identifier |
| `artifact_id` | UUID | Foreign key to repository_artifacts |
| `artifact_kind` | string | "definition", "form", "schema", "service_catalog", "script", "module", "scenario" |
| `artifact_name` | string | Semantic name; 1..255 chars |
| `version_number` | u32 | Monotonic per (kind, name); starts at 1 |
| `content_hash` | bytes[32] | Refers to repository_artifacts(content_hash) |
| `parent_version_id` | UUID or null | For lineage tracking (REPO-03) |
| `created_by` | UUID | User who uploaded this version |
| `created_at` | i64 | UTC microseconds |
| `description` | string or null | Optional free-text description |

### ArtifactActivation
| Field | Type | Notes |
|---|---|---|
| `activation_id` | UUID | Primary key |
| `tenant_id` | UUID | Scopes activation to a specific tenant (REPO-09) |
| `artifact_kind` | string | Must match the artifact being activated |
| `artifact_name` | string | Must match the artifact being activated |
| `active_version_id` | UUID | Which version is currently active in this tenant |
| `activated_at` | i64 | UTC microseconds; when activation was committed |
| `activator_user_id` | UUID | Who initiated the activation |

### ActivationHistoryRecord
| Field | Type | Notes |
|---|---|---|
| `history_id` | UUID | Unique record identifier |
| `tenant_id` | UUID | Tenant that was affected |
| `artifact_kind` | string | Kind of artifact that was activated |
| `artifact_name` | string | Name of artifact that was activated |
| `previous_version_id` | UUID or null | What was active before; null if first activation |
| `new_version_id` | UUID | What is now active |
| `new_version_number` | u32 | Version number of the newly activated version |
| `activator_user_id` | UUID | User who initiated the activation |
| `activated_at` | i64 | UTC microseconds |
| `rationale` | string | Free-text reason for the activation |

### FormSchemaField (from index)
| Field | Type | Notes |
|---|---|---|
| `field_name` | string | Name of the field in the form schema (e.g., "customer_amount") |
| `field_type` | string | Type ("string", "number", "date", "enum", "currency", etc.) |
| `field_label` | string | User-visible label (e.g., "Customer Amount (USD)") |
| `required` | bool | Whether the field is mandatory |
| `pattern` | string or null | Optional validation pattern (regex) |

### ServiceCatalogRecord
| Field | Type | Notes |
|---|---|---|
| `service_id` | string | Stable identifier; PRIMARY KEY (REPO-07) |
| `endpoint_url` | string | HTTPS URL to invoke |
| `request_schema` | string | JSON Schema (bytes) defining request shape |
| `response_schema` | string | JSON Schema (bytes) defining response shape |
| `required_auth` | enum | NONE / API_KEY / OAUTH2 / MUTUAL_TLS |
| `timeout_ms` | u32 | Request timeout in milliseconds (1..3600000) |
| `retry_policy` | string | JSON object; default `{"strategy": "exponential", "max_attempts": 3}` |
| `created_at` | i64 | UTC microseconds |
| `updated_at` | i64 | UTC microseconds |

---

## Key invariants

1. **Content-addressed immutability (REPO-01, REPO-02):** Every artifact is stored in `repository_artifacts(content_hash, ...)` with `content_hash` as PRIMARY KEY. Once committed, a row is never updated. An attempt to "update" an artifact fails with `ImmutableViolation`. A PUT with different content produces a new version record and either a new `repository_artifacts` row (if hash is novel) or reuses existing artifact row (if hash already exists — deduplication).

2. **Canonical serialisation determinism (REPO-04):** The canonicaliser is deterministic: the same logical content always produces the same canonical form and hash, regardless of whitespace, key order, or number representation in the input. Tests verify this property.

3. **Version lineage (REPO-03):** Each `ArtifactVersionRecord` has an optional `parent_version_id`. This allows history queries to return an ordered list with parent pointers, enabling agents to understand the provenance of a version.

4. **Per-tenant activation isolation (REPO-09):** Every row in `artifact_activations` is scoped by (tenant_id, artifact_kind, artifact_name). An activation in tenant A does not affect tenant B. Queries always filter by tenant_id.

5. **Atomic multi-artifact activation (REPO-08):** All writes in `activateGroup()` happen in a single transaction. If any validation fails before the transaction (e.g., service not found, definition graph invalid), no rows are written. If all validation passes, either the entire group is activated and the history record is inserted, or all roll back.

6. **Activation history durability (REPO-10):** Every activation is recorded in `artifact_activation_history`. An entry contains previous_version_id (nullable), new_version_id, activator_user_id, timestamp, and rationale. This record is inserted in the same transaction as the `artifact_activations` update, ensuring consistency.

7. **Form schema indexing completeness (REPO-05):** When a form artifact is activated, all fields are extracted and indexed in `form_schema_registry(version_id, field_name, field_type, field_label)`. The index is complete for all active form versions, enabling efficient searchability.

8. **Event type registry extension (REPO-06):** When a definition artifact is activated, all event types it produces are registered (or updated) in `event_type_registry_producers(event_type_id, definition_version_id)`. Definition activation fails if it uses an event type not already registered in `event_store.event_type_registry` (ES-05).

9. **Service catalog validation (REPO-07):** When a definition artifact is activated, all services it references are validated to exist in `service_catalog`. Activation fails with `ServiceNotFound` if any referenced service is missing.

---

## Database schema overview

### repository_artifacts
```sql
CREATE TABLE repository_artifacts (
    content_hash     BYTEA NOT NULL PRIMARY KEY,        -- SHA-256 (32 bytes)
    content_type     VARCHAR(64) NOT NULL,              -- "application/json", "application/wasm"
    byte_size        BIGINT NOT NULL,                   -- Stored content length
    created_at       TIMESTAMPTZ NOT NULL,
    -- Index on (content_type, created_at) for type-filtered queries
);
```
**Immutability:** PRIMARY KEY is content hash; no UPDATE statement modifies rows.

### artifact_versions
```sql
CREATE TABLE artifact_versions (
    version_id           UUID NOT NULL PRIMARY KEY,
    artifact_id          UUID NOT NULL,
    artifact_kind        VARCHAR(64) NOT NULL,      -- "definition", "form", "schema", ...
    artifact_name        VARCHAR(255) NOT NULL,
    version_number       BIGINT NOT NULL,
    content_hash         BYTEA NOT NULL,            -- FK to repository_artifacts
    parent_version_id    UUID,                      -- FK to artifact_versions (nullable)
    created_by           UUID NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL,
    description          TEXT,
    -- Indexes
    UNIQUE (artifact_kind, artifact_name, version_number),
    INDEX (artifact_kind, artifact_name, created_at),
    INDEX (content_hash),
    FOREIGN KEY (content_hash) REFERENCES repository_artifacts(content_hash),
    FOREIGN KEY (parent_version_id) REFERENCES artifact_versions(version_id),
);
```

### artifact_activations
```sql
CREATE TABLE artifact_activations (
    activation_id       UUID NOT NULL PRIMARY KEY,
    tenant_id           UUID NOT NULL,
    artifact_kind       VARCHAR(64) NOT NULL,
    artifact_name       VARCHAR(255) NOT NULL,
    active_version_id   UUID NOT NULL,
    activated_at        TIMESTAMPTZ NOT NULL,
    activator_user_id   UUID NOT NULL,
    -- Indexes
    UNIQUE (tenant_id, artifact_kind, artifact_name),  -- One active per (tenant, kind, name)
    INDEX (tenant_id, artifact_kind),
    FOREIGN KEY (active_version_id) REFERENCES artifact_versions(version_id),
);
```

### artifact_activation_history
```sql
CREATE TABLE artifact_activation_history (
    history_id          UUID NOT NULL PRIMARY KEY,
    tenant_id           UUID NOT NULL,
    artifact_kind       VARCHAR(64) NOT NULL,
    artifact_name       VARCHAR(255) NOT NULL,
    previous_version_id UUID,                      -- FK nullable; null if first activation
    new_version_id      UUID NOT NULL,
    new_version_number  BIGINT NOT NULL,
    activator_user_id   UUID NOT NULL,
    activated_at        TIMESTAMPTZ NOT NULL,
    rationale           TEXT NOT NULL,
    -- Indexes
    INDEX (tenant_id, artifact_kind, artifact_name, activated_at DESC),
    INDEX (activated_at DESC),
    FOREIGN KEY (new_version_id) REFERENCES artifact_versions(version_id),
);
```

### form_schema_registry
```sql
CREATE TABLE form_schema_registry (
    registry_id      UUID NOT NULL PRIMARY KEY,
    version_id       UUID NOT NULL,
    artifact_name    VARCHAR(255) NOT NULL,
    field_name       VARCHAR(255) NOT NULL,
    field_type       VARCHAR(128) NOT NULL,    -- "string", "number", "currency", etc.
    field_label      VARCHAR(4096),
    required         BOOLEAN DEFAULT FALSE,
    pattern          TEXT,
    -- Indexes
    INDEX (version_id),
    INDEX (field_type),
    INDEX (field_label),                        -- Full-text search via GIN
    INDEX (field_name),
    UNIQUE (version_id, field_name),
    FOREIGN KEY (version_id) REFERENCES artifact_versions(version_id),
);
```

### event_type_registry_producers
```sql
CREATE TABLE event_type_registry_producers (
    id                  UUID NOT NULL PRIMARY KEY,
    event_type_id       UUID NOT NULL,
    definition_version_id UUID NOT NULL,
    registered_at       TIMESTAMPTZ NOT NULL,
    -- Indexes
    INDEX (event_type_id),
    INDEX (definition_version_id),
    UNIQUE (event_type_id, definition_version_id),
    FOREIGN KEY (event_type_id) REFERENCES event_type_registry(id),
    FOREIGN KEY (definition_version_id) REFERENCES artifact_versions(version_id),
);
```

### service_catalog
```sql
CREATE TABLE service_catalog (
    service_id       VARCHAR(255) NOT NULL PRIMARY KEY,
    endpoint_url     VARCHAR(2048) NOT NULL,
    request_schema   TEXT NOT NULL,              -- JSON Schema bytes
    response_schema  TEXT NOT NULL,
    required_auth    VARCHAR(64) NOT NULL,       -- "NONE", "API_KEY", "OAUTH2", "MUTUAL_TLS"
    timeout_ms       INTEGER NOT NULL CHECK (timeout_ms >= 1 AND timeout_ms <= 3600000),
    retry_policy     TEXT,                       -- JSON object
    created_at       TIMESTAMPTZ NOT NULL,
    updated_at       TIMESTAMPTZ NOT NULL,
);
```

---

## Cross-module dependencies

| Dependency | Direction | Why |
|---|---|---|
| `src/db/pool.zig` | repository → Pool | All SQL operations use pool.acquire() / release() (DB-02) |
| `src/event_store/registry.zig` | activation → event_store | When activating a definition, check that all event types are registered (REPO-06, ES-05) |
| `src/definition/` | activation → definition | When activating a definition version, call definition.validate() to verify graph structure and service catalog references (REPO-07) |
| `src/obs/audit.zig` | activation → audit | Activation operations must be audited (REPO-10, OBS-03) |
| `src/api/` | API → repository | HTTP handlers call repository module functions to create, list, and activate artifacts |
| `src/identity/` | repository → identity | User context (activator_user_id) comes from identity module auth |

**Must NOT depend on:**
- `src/engine/transition.zig` — pure function, no state; repository has no interaction
- `src/tasks/` — lateral dependency; no cross-module imports

---

## Transactional guarantees

### CreateArtifact (REPO-01, REPO-02)
1. Canonicalise content (if JSON).
2. Compute SHA-256 hash.
3. Query `SELECT * FROM repository_artifacts WHERE content_hash = $1`.
4. If found:
   - (No new artifact row needed; hash already exists)
   - Increment version counter for (artifact_kind, artifact_name).
   - Insert new `artifact_versions` row pointing to existing artifact.
   - Return (existing artifact record, new version record, is_duplicate=true).
5. If not found:
   - BEGIN TRANSACTION
     - INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at)
     - INSERT INTO artifact_versions (version_id, artifact_id, ..., version_number=1)
   - COMMIT
   - Return (new artifact record, new version record, is_duplicate=false)
6. All writes for a non-duplicate artifact happen in a single transaction (DB-03).

### ActivateGroup (REPO-08, REPO-09, REPO-10)
1. For each member in the group:
   - Fetch version_id from artifact_versions.
   - Verify (artifact_kind, artifact_name) match.
   - If artifact_kind == "definition": call definition.validate() (includes service catalog check).
   - If artifact_kind == "form": call schemas.indexSchema() to prepare index updates.
2. BEGIN TRANSACTION
   - For each member:
     - Query `SELECT * FROM artifact_activations WHERE tenant_id = $1 AND artifact_kind = $2 AND artifact_name = $3`.
     - If found: capture previous_version_id; prepare UPDATE.
     - If not found: prepare INSERT (previous_version_id = null).
   - Execute all updates/inserts (idempotent via UPSERT or conditional logic).
   - For each member: INSERT INTO artifact_activation_history (history_id, tenant_id, ..., previous_version_id, new_version_id, ..., activated_at, rationale).
   - [If any member is a form: execute schema indexing inserts/updates prepared in step 1.]
3. COMMIT
4. Return activated list with timestamps.

All or nothing: if any validation fails before the transaction, no rows are written. If all validation passes, the entire group is activated atomically.

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| SHA-256 collision | Two different artifacts map to same hash | Cryptographically infeasible; no mitigation required |
| Large artifact storage | Repository grows unbounded if unused versions accumulate | REPO-03 versioning is explicit; no automatic pruning. Agents must archive/delete old versions explicitly. Future WF might add a retention policy. |
| Canonicalisation bug | Content with different whitespace produces different hashes (breaks deduplication) | Canonicaliser is pure and deterministic; covered by unit tests with property-based examples. |
| Concurrent activation race | Two activations of different versions of the same artifact in the same tenant | `UNIQUE (tenant_id, artifact_kind, artifact_name)` on artifact_activations enforces one active per artifact per tenant; race resolved by DB-level uniqueness constraint (loser gets constraint violation). |
| Form schema index staleness | Index is out-of-sync with active version | Index is updated atomically in the same transaction as artifact_activations (REPO-08). If activation rolls back, index is not written. |
| Event type registry gap | Definition references event type not registered in ES-05 | Definition activation is rejected with DefinitionValidationFailed if any event type is missing. (REPO-06, ES-05). |
| Service catalog gap | Definition references service not in catalog | Definition activation is rejected with ServiceNotFound if any service is missing. (REPO-07). |

---

## Open questions

None identified at design phase. All requirements are addressed in the API, data model, and transaction semantics.

---

## REPO-14 — Bulk bundle operations (SHOULD)

**Design note:** REPO-14 is a SHOULD requirement and is covered by the `activateGroup()` function above. No separate API endpoint is required; a single "artifact bundle" is modeled as one `ActivateGroupParams` with multiple members. The `activateGroup()` function already provides atomic bundle activation.

Optional enhancement (deferred to future stage):
- `POST /repository/bundles` — Create a named, reusable bundle artifact that encapsulates multiple artifact versions together. Activation would be a single call to activate a bundle.
- `POST /repository/bundles/{bundle_id}/activate` — Activate an entire bundle in one call.

For now, REPO-14 is satisfied by `POST /repository/activations` with a multi-member group.

---

*Traceability:*
- REPO-01 (Content addressing) → `Artifacts.create()`, `ArtifactRecord`, `canonicaliser.hashContent()`, deduplication logic
- REPO-02 (Immutability) → `repository_artifacts` PRIMARY KEY on content_hash, no UPDATE statement, `ArtifactsError.ImmutableViolation`
- REPO-03 (Versioning) → `ArtifactVersionRecord`, `parent_version_id`, `Artifacts.listVersions()`
- REPO-04 (Canonical serialisation) → `canonicaliser.canonicaliseJson()`, deterministic algorithm, unit tests
- REPO-05 (Form schema indexing) → `Schemas.indexSchema()`, `form_schema_registry` table, `Schemas.searchSchemas()`
- REPO-06 (Event type registry) → `event_type_registry_producers` table, activation validation checks ES-05
- REPO-07 (Service catalog) → `ServiceCatalog.*`, `service_catalog` table, definition activation checks for valid service references
- REPO-08 (Atomic activation) → `Activation.activateGroup()`, single transaction semantics
- REPO-09 (Per-tenant activation) → `artifact_activations(tenant_id, ...)`, all queries filter by tenant_id
- REPO-10 (Activation history) → `artifact_activation_history` table, `ActivationHistoryRecord`, inserted in same transaction as activation
- REPO-11 (Create artifact) → `POST /repository/artifacts` endpoint, `Artifacts.create()`, deduplication with is_duplicate flag
- REPO-12 (List versions) → `GET /repository/{kind}/{name}/versions`, `Artifacts.listVersions()`, cursor-based pagination (API-06)
- REPO-13 (Tenant activations) → `GET /tenants/{tenant_id}/activations`, `Activation.listActive()`
- REPO-14 (Bulk bundle operations) → `POST /repository/activations` with multi-member `ActivationGroupMember[]`
