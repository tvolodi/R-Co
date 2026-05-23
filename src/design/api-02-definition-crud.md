# Module: api-02-definition-crud

**Covers:** API-02, PD-01, PD-02, PD-03, PD-04, PD-05, PD-06, PD-07
**Files:** `src/api/routes/definitions.zig` (extend existing), `src/api/errors.zig` (no change)
**Depends on:** `src/design/definition.md` (read that artefact first)

---

## Module purpose

This module designs the complete HTTP handler layer for the Process Definition CRUD API (API-02). It extends the existing `src/api/routes/definitions.zig` — which already implements PD-07 read operations and PD-04 deprecate/archive actions — with the five remaining write routes: `POST /definitions` (create), `PUT /definitions/:id` (full replace), `PATCH /definitions/:id` (partial update), `DELETE /definitions/:id` (hard-delete or archive), and `POST /definitions/:id/activate` (DRAFT→ACTIVE transition). Together with the already-implemented routes, this completes all seven API-02 endpoints. No new domain module is needed: all business logic already lives in `src/definition/store.zig`.

---

## Public interface

All handler functions follow the established pattern from the existing `definitions.zig`: they accept a `*definition_store.Store`, an `std.mem.Allocator`, and the parsed inputs from the HTTP layer (path params, body). They return `HandlerResult` (the `{status_code, body}` struct already defined in that file). The existing `HandlerResult` and `errorResult()` helper are reused without modification.

### New request body types

```zig
/// Body for POST /api/v1/definitions  (PD-01 create).
/// All fields are validated before Store.create() is called.
pub const CreateDefinitionBody = struct {
    /// Non-empty, ≤ 255 characters (PD-01).
    name: []const u8,
    /// Non-empty string (PD-01).
    version: []const u8,
    /// Optional human-readable description.
    description: ?[]const u8,
    /// The definition graph; must have `nodes` and `edges` arrays (PD-02).
    graph: definition_store.DefinitionGraph,
    /// Optional process stage label (PD-07).
    stage: ?[]const u8,
};

/// Body for PUT /api/v1/definitions/:id  (full replacement, DRAFT only).
/// Identical fields to CreateDefinitionBody; all fields are required for a full replace.
pub const PutDefinitionBody = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    graph: definition_store.DefinitionGraph,
    stage: ?[]const u8,
};

/// Body for PATCH /api/v1/definitions/:id  (partial update, DRAFT only).
/// Any field omitted (null) is left unchanged in the stored record.
pub const PatchDefinitionBody = struct {
    name: ?[]const u8,
    version: ?[]const u8,
    description: ?[]const u8,
    graph: ?definition_store.DefinitionGraph,
    stage: ?[]const u8,
};
```

### New handler signatures

```zig
/// POST /api/v1/definitions
///
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN (API-08).
/// Parses CreateDefinitionBody from the JSON request body.
/// Delegates to Store.create(); validates via PD-02 graph pipeline.
///
/// Success:           HTTP 201 + JSON Definition body.
/// Name+ver conflict: HTTP 409.
/// Validation failure:HTTP 422 + violations array.
/// Auth missing:      HTTP 401 (enforced by upstream middleware).
/// Insufficient role: HTTP 403 (enforced by upstream middleware).
/// Pool exhausted:    HTTP 503.
/// Server error:      HTTP 500.
pub fn handleCreate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    body: CreateDefinitionBody,
    actor_id: definition_store.Uuid,
) HandlerResult;

/// PUT /api/v1/definitions/:id
///
/// Full replacement of a DRAFT definition.  Not permitted for ACTIVE/DEPRECATED/ARCHIVED.
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN.
/// Runs the full graph validation pipeline (PD-02, PD-05, PD-06) on the new graph.
///
/// Success:            HTTP 200 + JSON Definition body.
/// Not found:          HTTP 404.
/// Status ≠ DRAFT:     HTTP 409 ({"error":"not_draft","current_status":"<status>"}).
/// Validation failure: HTTP 422 + violations array.
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handlePut(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
    body: PutDefinitionBody,
) HandlerResult;

/// PATCH /api/v1/definitions/:id
///
/// Partial update of a DRAFT definition.  Not permitted for ACTIVE/DEPRECATED/ARCHIVED.
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN.
/// Only supplied (non-null) fields are updated.
/// If `graph` is supplied, the full graph validation pipeline runs on the new graph.
/// If `graph` is absent, no graph validation occurs.
///
/// Success:            HTTP 200 + JSON Definition body.
/// Not found:          HTTP 404.
/// Status ≠ DRAFT:     HTTP 409 ({"error":"not_draft","current_status":"<status>"}).
/// Validation failure: HTTP 422 + violations array.
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handlePatch(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
    body: PatchDefinitionBody,
) HandlerResult;

/// DELETE /api/v1/definitions/:id
///
/// Behaviour is status-dependent (PD-04):
///   DRAFT (never activated) → hard-delete → HTTP 204, no body.
///   ACTIVE                  → archive (ACTIVE → ARCHIVED transition) → HTTP 200 + Definition.
///   DEPRECATED              → archive (DEPRECATED → ARCHIVED) → HTTP 200 + Definition.
///   ARCHIVED                → HTTP 409 ({"error":"already_archived"}).
///   Not found               → HTTP 404.
///
/// Authorisation: PLATFORM_ADMIN only (stricter than write ops).
/// Pool exhausted: HTTP 503.
/// Server error:   HTTP 500.
///
/// NOTE: PD-04 says DELETE on ACTIVE triggers archive (not hard delete).
/// The handler reads current status first to dispatch to the correct Store method.
pub fn handleDelete(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult;

/// POST /api/v1/definitions/:id/activate
///
/// Transitions DRAFT → ACTIVE (PD-03).
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN.
/// Re-runs PD-02 graph validation before transitioning (per API-02 AC).
/// Idempotent: activating an already-ACTIVE definition returns HTTP 200 with current Definition.
///
/// Success (DRAFT→ACTIVE):   HTTP 200 + JSON Definition body.
/// Already ACTIVE (no-op):   HTTP 200 + JSON Definition body.
/// Status ≠ DRAFT, ≠ ACTIVE: HTTP 409 ({"error":"not_draft","current_status":"<status>"}).
/// Not found:                 HTTP 404.
/// Graph validation failure:  HTTP 422 + violations array (re-validation at activation).
/// Pool exhausted:            HTTP 503.
/// Server error:              HTTP 500.
pub fn handleActivate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult;
```

### New Store methods required (to be added by BACKEND-DEV)

The existing `store.zig` does not yet implement `update()` (PUT/PATCH semantics) or a status-aware delete. The following additions are needed:

```zig
/// Parameters for Store.update() — used by both PUT and PATCH handlers.
/// Null fields mean "do not change".  For PUT, the handler fills all fields.
/// For PATCH, the handler fills only the fields present in the request body.
pub const UpdateParams = struct {
    name:        ?[]const u8,
    version:     ?[]const u8,
    description: ?[]const u8,
    /// When non-null, the full graph validation pipeline is re-run.
    graph:       ?definition_store.DefinitionGraph,
    stage:       ?[]const u8,
};

/// Update a DRAFT definition.  Any null field in params is left unchanged.
/// If params.graph is non-null, runs validateGraph → validateNodeAttributes →
/// validateEdgeConditions before the UPDATE.
///
/// Errors:
///   DefinitionNotFound         → HTTP 404
///   NotDraft (status ≠ DRAFT)  → HTTP 409  (new error variant — see note below)
///   DuplicateNameVersion       → HTTP 409  (if name+version changed to a conflicting pair)
///   GraphValidationFailed      → HTTP 422  (if graph was supplied and invalid)
///   PoolExhausted              → HTTP 503
///   TransactionFailed          → HTTP 500
pub fn update(
    self:      *Store,
    allocator: std.mem.Allocator,
    id:        Uuid,
    params:    UpdateParams,
) DefinitionError!Definition;

/// Hard-delete a never-activated DRAFT definition.
/// Only permitted when no instance snapshot references the definition.
///
/// Errors:
///   DefinitionNotFound         → HTTP 404
///   NotDraft                   → HTTP 409  (if status ≠ DRAFT)
///   PoolExhausted              → HTTP 503
///   TransactionFailed          → HTTP 500
pub fn hardDelete(
    self:      *Store,
    allocator: std.mem.Allocator,
    id:        Uuid,
) DefinitionError!void;
```

**Note on `NotDraft` error variant:** `DefinitionError.NotDraft` is already present in the error set (added by PD-03 for `activate()`) and maps to HTTP 409. The `update()` and `hardDelete()` functions reuse this variant with the same HTTP mapping.

---

## Route table (complete API-02 surface)

| Method  | Path                                   | Handler                     | Role required                         | Req body    |
|---------|----------------------------------------|-----------------------------|---------------------------------------|-------------|
| `POST`  | `/api/v1/definitions`                  | `handleCreate`              | PROCESS_DESIGNER or PLATFORM_ADMIN    | JSON        |
| `GET`   | `/api/v1/definitions`                  | `handleList` (existing)     | Any authenticated                     | none        |
| `GET`   | `/api/v1/definitions/active/:name`     | `handleGetActiveByName` (existing) | Any authenticated             | none        |
| `GET`   | `/api/v1/definitions/search`           | `handleSearch` (existing)   | Any authenticated                     | none        |
| `GET`   | `/api/v1/definitions/:id`              | `handleGetById` (existing)  | Any authenticated                     | none        |
| `GET`   | `/api/v1/definitions/:id/export`       | `handleExport` (existing)   | Any authenticated                     | none        |
| `POST`  | `/api/v1/definitions/import`           | `handleImport` (existing)   | PROCESS_DESIGNER or PLATFORM_ADMIN    | JSON        |
| `PUT`   | `/api/v1/definitions/:id`              | `handlePut`                 | PROCESS_DESIGNER or PLATFORM_ADMIN    | JSON        |
| `PATCH` | `/api/v1/definitions/:id`              | `handlePatch`               | PROCESS_DESIGNER or PLATFORM_ADMIN    | JSON        |
| `DELETE`| `/api/v1/definitions/:id`              | `handleDelete`              | PLATFORM_ADMIN                        | none        |
| `POST`  | `/api/v1/definitions/:id/activate`     | `handleActivate`            | PROCESS_DESIGNER or PLATFORM_ADMIN    | none        |
| `POST`  | `/api/v1/definitions/:id/deprecate`    | `handleDeprecate` (existing)| PROCESS_DESIGNER or PLATFORM_ADMIN    | none        |
| `POST`  | `/api/v1/definitions/:id/archive`      | `handleArchive` (existing)  | PROCESS_DESIGNER or PLATFORM_ADMIN    | none        |

**Router registration note:** The `/active/:name` and `/search` routes MUST be registered before `/:id` to prevent `"active"` and `"search"` from being consumed as UUID path parameters.

---

## Request and response types

### POST /api/v1/definitions — create

**Request body:**
```json
{
  "name": "loan-approval",
  "version": "1.0",
  "description": "Loan approval workflow",
  "graph": {
    "nodes": [...],
    "edges": [...]
  },
  "stage": "staging"
}
```

**Success response (HTTP 201):** JSON `Definition` object — same shape as `GET /definitions/:id`.

**Validation error response (HTTP 422):**
```json
{
  "type": "https://bpm.example.com/errors/graph-validation-failed",
  "title": "Graph validation failed",
  "status": 422,
  "detail": "The process definition graph contains structural violations",
  "errors": [
    { "code": "MISSING_START_NODE", "message": "..." },
    { "code": "DANGLING_EDGE", "message": "Edge 'e1' references unknown node 'n99'" }
  ]
}
```

### PUT /api/v1/definitions/:id — full replace

**Request body:** identical to POST body; all fields required.

**Success response (HTTP 200):** JSON `Definition` object (updated record).

**Status conflict (HTTP 409):**
```json
{
  "type": "https://bpm.example.com/errors/not-draft",
  "title": "Definition is not in DRAFT status",
  "status": 409,
  "detail": "PUT is only permitted for DRAFT definitions",
  "current_status": "ACTIVE"
}
```

### PATCH /api/v1/definitions/:id — partial update

**Request body:** same shape as POST, all fields optional. Omitted fields are left unchanged. Example partial update:
```json
{
  "description": "Updated description"
}
```

**Success response (HTTP 200):** JSON `Definition` object (updated record).

**Status conflict (HTTP 409):** same shape as PUT conflict above.

### DELETE /api/v1/definitions/:id

**Request body:** none.

**Success responses:**
- DRAFT (never activated): HTTP 204, no body.
- ACTIVE or DEPRECATED: HTTP 200 + JSON `Definition` object (now in ARCHIVED status).

**Already ARCHIVED (HTTP 409):**
```json
{
  "type": "https://bpm.example.com/errors/already-archived",
  "title": "Definition is already ARCHIVED",
  "status": 409,
  "detail": "ARCHIVED is a terminal status; no further transitions are allowed"
}
```

### POST /api/v1/definitions/:id/activate

**Request body:** none.

**Success response (HTTP 200):** JSON `Definition` object (status = ACTIVE).

**Status conflict (HTTP 409):**
```json
{
  "type": "https://bpm.example.com/errors/not-draft",
  "title": "Only DRAFT definitions can be activated",
  "status": 409,
  "detail": "Definition has status DEPRECATED; only DRAFT definitions may be activated",
  "current_status": "DEPRECATED"
}
```

### Definition JSON object (shared response shape)

Returned by all write-operation success responses and all existing read endpoints:

```json
{
  "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "name": "loan-approval",
  "version": "1.0",
  "description": "Loan approval workflow",
  "status": "DRAFT",
  "graph": {
    "nodes": [...],
    "edges": [...]
  },
  "stage": "staging",
  "created_by": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "created_at": 1716220800000000,
  "updated_at": 1716220800000000,
  "archived_at": null
}
```

Timestamps are UTC epoch microseconds (i64). `archived_at` is null until the definition reaches ARCHIVED status.

---

## Data flow diagram

```
HTTP POST /api/v1/definitions
         │
         ▼
  api/middleware/auth.zig
         │  Parse + validate Bearer token → HTTP 401 if absent/invalid
         │  Set ctx.actor (user_id + roles)
         ▼
  api/middleware/rbac.zig
         │  Require PROCESS_DESIGNER or PLATFORM_ADMIN → HTTP 403 if denied
         ▼
  api/middleware/audit.zig
         │  Open audit record (written atomically with DB change)
         ▼
  api/routes/definitions.zig :: handleCreate
         │  1. Parse JSON body → CreateDefinitionBody  (HTTP 400 on malformed JSON)
         │  2. Validate Content-Type: application/json  (HTTP 415 if absent)
         │  3. Validate required fields present and non-empty  (HTTP 422 on failure)
         │
         ▼
  definition/store.zig :: Store.create(allocator, CreateParams)
         │
         ├─ [A] Input validation
         │      name non-empty, ≤ 255   → NameInvalid      → HTTP 422
         │      version non-empty        → VersionEmpty     → HTTP 422
         │
         ├─ [B]  graph.validateGraph()   → GraphValidationFailed → HTTP 422 + violations
         ├─ [B2] graph.validateNodeAttributes()  → same
         ├─ [B3] graph.validateEdgeConditions()  → same
         │
         ├─ [C] pool.acquire()           → PoolExhausted    → HTTP 503
         │
         ├─ [D] INSERT … ON CONFLICT (name, version) DO NOTHING RETURNING *
         │      0 rows → DuplicateNameVersion → HTTP 409
         │
         └─ return Definition            → HTTP 201 + JSON body


HTTP PUT /api/v1/definitions/:id
         │
         ▼ (same auth + RBAC + audit middleware)
         ▼
  handlePut
         │  1. Parse UUID from path    → HTTP 422 on bad UUID
         │  2. Parse JSON body → PutDefinitionBody (HTTP 400 on malformed JSON)
         │  3. Validate all fields present
         │
         ▼
  Store.update(id, UpdateParams{all fields set})
         │
         ├─ [A] SELECT current row → DefinitionNotFound → HTTP 404
         ├─ [B] Check status == DRAFT → NotDraft        → HTTP 409
         ├─ [C] Run full graph validation pipeline       → HTTP 422
         ├─ [D] UPDATE process_definitions SET ... WHERE id=$1 AND status='DRAFT' RETURNING *
         └─ return Definition                            → HTTP 200


HTTP PATCH /api/v1/definitions/:id
         │
         ▼ (same middleware)
         ▼
  handlePatch
         │  1. Parse UUID
         │  2. Parse JSON body → PatchDefinitionBody  (missing fields → null, not error)
         │
         ▼
  Store.update(id, UpdateParams{only non-null fields set})
         │  (same path as PUT; graph validation skipped if graph field is null)
         └─ return Definition → HTTP 200


HTTP DELETE /api/v1/definitions/:id
         │
         ▼ (PLATFORM_ADMIN required)
         ▼
  handleDelete
         │  1. Parse UUID
         │  2. Call Store.getById() to read current status → HTTP 404 if not found
         │
         ├─ status == DRAFT     → Store.hardDelete(id) → HTTP 204
         ├─ status == ACTIVE    → Store.archive(id) [requires ACTIVE→DEPRECATED first
         │                        per PD-04: DELETE on ACTIVE triggers archive]
         │                        SEE OPEN QUESTION 1
         ├─ status == DEPRECATED → Store.archive(id) → HTTP 200 + Definition
         └─ status == ARCHIVED   → HTTP 409 already_archived


HTTP POST /api/v1/definitions/:id/activate
         │
         ▼ (PROCESS_DESIGNER or PLATFORM_ADMIN)
         ▼
  handleActivate
         │  1. Parse UUID
         │  2. Fetch definition → HTTP 404 if not found
         │  3. Re-run graph validation on current stored graph (API-02 AC)
         │     → HTTP 422 if graph invalid
         │
         ▼
  Store.activate(id)
         │
         ├─ DRAFT   → ACTIVE (atomically deprecates prior ACTIVE for same name)
         │            → HTTP 200 + Definition
         ├─ ACTIVE  → AlreadyActive → HTTP 200 + Definition (idempotent)
         ├─ DEPRECATED/ARCHIVED → NotDraft → HTTP 409
         └─ not found → DefinitionNotFound → HTTP 404
```

---

## HTTP status codes — complete table

| Route                           | Condition                                  | HTTP status | Response body                          |
|---------------------------------|--------------------------------------------|-------------|----------------------------------------|
| `POST /definitions`             | Success                                    | 201         | Definition JSON                        |
| `POST /definitions`             | Name+version conflict                      | 409         | Problem Details `duplicate_name_version` |
| `POST /definitions`             | Graph/input validation failure             | 422         | Problem Details + `errors` array       |
| `POST /definitions`             | No auth token                              | 401         | Problem Details                        |
| `POST /definitions`             | Wrong role                                 | 403         | Problem Details                        |
| `POST /definitions`             | Pool exhausted                             | 503         | Problem Details                        |
| `POST /definitions`             | Server error                               | 500         | Problem Details                        |
| `GET /definitions`              | Success (any result count)                 | 200         | `{items:[...], cursor: str\|null}`     |
| `GET /definitions`              | Invalid `?status=` value                   | 422         | Problem Details                        |
| `GET /definitions`              | Invalid `?cursor=`                         | 422         | Problem Details                        |
| `GET /definitions`              | Expired cursor (>24h)                      | 410         | Problem Details                        |
| `GET /definitions`              | `?page_size=` ≤ 0 or > 200                | 422         | Problem Details                        |
| `GET /definitions/:id`          | Success                                    | 200         | Definition JSON                        |
| `GET /definitions/:id`          | Not found                                  | 404         | Problem Details                        |
| `GET /definitions/:id`          | Invalid UUID format                        | 422         | Problem Details                        |
| `PUT /definitions/:id`          | Success                                    | 200         | Definition JSON                        |
| `PUT /definitions/:id`          | Not found                                  | 404         | Problem Details                        |
| `PUT /definitions/:id`          | Status ≠ DRAFT                             | 409         | Problem Details `not_draft` + `current_status` |
| `PUT /definitions/:id`          | Name+version conflict (on rename)          | 409         | Problem Details `duplicate_name_version` |
| `PUT /definitions/:id`          | Graph validation failure                   | 422         | Problem Details + `errors` array       |
| `PUT /definitions/:id`          | No body supplied                           | 400         | Problem Details                        |
| `PATCH /definitions/:id`        | Success                                    | 200         | Definition JSON                        |
| `PATCH /definitions/:id`        | Not found                                  | 404         | Problem Details                        |
| `PATCH /definitions/:id`        | Status ≠ DRAFT                             | 409         | Problem Details `not_draft` + `current_status` |
| `PATCH /definitions/:id`        | Graph validation failure (if graph sent)   | 422         | Problem Details + `errors` array       |
| `DELETE /definitions/:id`       | Success (DRAFT hard-delete)                | 204         | (no body)                              |
| `DELETE /definitions/:id`       | Success (ACTIVE or DEPRECATED → archive)   | 200         | Definition JSON (ARCHIVED)             |
| `DELETE /definitions/:id`       | Not found                                  | 404         | Problem Details                        |
| `DELETE /definitions/:id`       | Already ARCHIVED                           | 409         | Problem Details `already_archived`     |
| `DELETE /definitions/:id`       | Wrong role (not PLATFORM_ADMIN)            | 403         | Problem Details                        |
| `POST /definitions/:id/activate`| Success (DRAFT→ACTIVE or already ACTIVE)   | 200         | Definition JSON                        |
| `POST /definitions/:id/activate`| Not found                                  | 404         | Problem Details                        |
| `POST /definitions/:id/activate`| Status ≠ DRAFT and ≠ ACTIVE               | 409         | Problem Details `not_draft` + `current_status` |
| `POST /definitions/:id/activate`| Graph re-validation failure                | 422         | Problem Details + `errors` array       |

---

## Error taxonomy

All errors produced by this module's handler layer, with their sources and HTTP mappings:

| Error variant                 | Source                                       | HTTP status | Error code string (in body)      |
|-------------------------------|----------------------------------------------|-------------|----------------------------------|
| `DefinitionError.NameInvalid` | name empty or > 255 chars                    | 422         | `name_invalid`                   |
| `DefinitionError.VersionEmpty`| version empty string                         | 422         | `version_empty`                  |
| `DefinitionError.GraphStructureInvalid` | graph not `{nodes,edges}` object   | 422         | `graph_structure_invalid`        |
| `DefinitionError.GraphValidationFailed` | CHK-01..CHK-08, PD-05, PD-06 rules | 422        | `graph_validation_failed` + `errors` array from `lastViolations()` |
| `DefinitionError.DuplicateNameVersion`  | UNIQUE(name,version) conflict     | 409         | `duplicate_name_version`         |
| `DefinitionError.DefinitionNotFound`    | id not in DB                      | 404         | `not_found`                      |
| `DefinitionError.NotDraft`    | attempt to mutate non-DRAFT via PUT/PATCH/activate | 409 | `not_draft` + `current_status` field |
| `DefinitionError.AlreadyActive`| activate() called on ACTIVE definition      | 200         | (no error; return Definition)    |
| `DefinitionError.InvalidStatusTransition` | status machine violation          | 409         | `invalid_status_transition` + `current_status` |
| `DefinitionError.PoolExhausted`| DB pool exhausted                           | 503         | `service_unavailable`            |
| `DefinitionError.TransactionFailed` | DB commit failure                      | 500         | `internal_error`                 |
| Malformed JSON body            | JSON parse error in handler                  | 400         | `malformed_json`                 |
| Missing `Content-Type`         | Header absent in middleware                  | 415         | `unsupported_media_type`         |
| Invalid UUID path param        | `parseUuid()` fails                          | 422         | `invalid_id_format`              |
| `AlreadyArchived`              | DELETE on ARCHIVED definition                | 409         | `already_archived`               |

**Error response shape (RFC 9457 Problem Details — all errors except 204):**

```json
{
  "type": "https://bpm.example.com/errors/<error-code>",
  "title": "<human-readable title>",
  "status": <integer>,
  "detail": "<specific message>",
  "errors": [...]
}
```

The `errors` array is present only for HTTP 422 responses from graph validation. For 409 responses on status conflicts, a `current_status` string field is added to the Problem Details object.

---

## State transitions

The full state machine lives in `src/definition/store.zig` and is documented in `src/design/definition.md`. The handler layer maps each route to the appropriate Store method:

```
DRAFT ──── PUT/PATCH ────► DRAFT       (update; graph re-validated)
DRAFT ──── POST /activate ─► ACTIVE
DRAFT ──── DELETE ──────────► (deleted, HTTP 204)

ACTIVE ─── PUT/PATCH ────► HTTP 409   (not_draft)
ACTIVE ─── DELETE ──────────► ARCHIVED (archive path, HTTP 200)
ACTIVE ─── POST /deprecate ─► DEPRECATED

DEPRECATED ─ PUT/PATCH ──► HTTP 409
DEPRECATED ─ DELETE ──────► ARCHIVED  (HTTP 200)
DEPRECATED ─ POST /archive ─► ARCHIVED

ARCHIVED ── any mutation ──► HTTP 409 (already_archived or invalid_status_transition)
```

See `src/design/definition.md § Authoritative state transition table` for the full PD-04 matrix.

---

## Role guard placement

Role checks are enforced by `api/middleware/rbac.zig` before any handler body executes. The handler layer itself receives `ctx.actor` and may inspect it for audit purposes, but MUST NOT re-implement role checks.

| Route group                                             | Required role                      |
|---------------------------------------------------------|------------------------------------|
| `POST /definitions`, `PUT /definitions/:id`, `PATCH /definitions/:id`, `POST /definitions/:id/activate`, `POST /definitions/:id/deprecate`, `POST /definitions/:id/archive` | PROCESS_DESIGNER or PLATFORM_ADMIN |
| `DELETE /definitions/:id`                               | PLATFORM_ADMIN only                |
| `GET /definitions`, `GET /definitions/:id`, `GET /definitions/active/:name`, `GET /definitions/search`, `GET /definitions/:id/export` | Any authenticated role             |
| `POST /definitions/import`                              | PROCESS_DESIGNER or PLATFORM_ADMIN |

---

## Pagination contract (API-06 integration)

`GET /definitions` uses the existing cursor-based pagination implemented in the current `handleList` function. The contract is unchanged:

- Cursor encoding: `base64url_no_pad(decimal_string(last_item.created_at_us))`.
- Next cursor present iff `items.len == effective_page_size`.
- Default page size: 50. Maximum: 200.
- Cursor expiry: 24 hours. Expired cursor returns HTTP 410.
- A cursor from `/definitions` MUST NOT be accepted by any other list endpoint.

The five new write routes do not return paginated responses.

---

## Graph validation trigger points (API-07 integration)

Per API-02 AC: *"All write operations trigger PD-02 graph validation."*

| Route                            | Validation triggered                                               |
|----------------------------------|--------------------------------------------------------------------|
| `POST /definitions`              | Full pipeline: `validateGraph` → `validateNodeAttributes` → `validateEdgeConditions` |
| `PUT /definitions/:id`           | Same full pipeline on the replacement graph                        |
| `PATCH /definitions/:id`         | Full pipeline only if `graph` field is present in the patch body; skipped otherwise |
| `POST /definitions/:id/activate` | Full pipeline re-runs on the current stored graph before `Store.activate()` is called |
| `DELETE /definitions/:id`        | No graph validation (delete/archive path)                          |

Validation is delegated entirely to `Store.create()`, `Store.update()`, and the handler's pre-activate validation call respectively. The handler layer MUST NOT re-implement graph validation logic.

---

## Dependencies

| Dependency                         | Direction                                        | Notes                                                           |
|------------------------------------|--------------------------------------------------|-----------------------------------------------------------------|
| `src/definition/store.zig`         | `definitions.zig` → `Store`                      | All five new handlers delegate to Store methods                  |
| `src/definition/export_import.zig` | existing handlers only                           | Not used by the five new handlers                               |
| `src/api/errors.zig`               | `definitions.zig` → error response builder       | RFC 9457 Problem Details serialisation                          |
| `src/api/middleware/auth.zig`      | upstream → provides `ctx.actor`                  | Handler receives `actor_id` from middleware context              |
| `src/api/middleware/rbac.zig`      | upstream → enforces role checks                  | Handler assumes role check already passed                        |
| `src/api/middleware/audit.zig`     | upstream → writes audit record                   | Handler does not write the audit record itself                   |
| `src/api/pagination.zig`           | existing `handleList` only                       | Cursor encode/decode; new handlers do not use pagination         |

**MUST NOT depend on:**
- `src/engine/` — definition CRUD is independent of the execution engine.
- `src/event_store/` — definitions have no event log.
- `src/scheduler/` — no scheduled operations in this module.
- Any external HTTP service.

---

## Open questions

**OQ-1 — DELETE on ACTIVE definition behaviour:**
API-02 AC states: *"DELETE on ACTIVE definition: triggers archive (not hard delete), HTTP 200."*
PD-04 AC states the permitted transitions as ACTIVE → DEPRECATED → ARCHIVED (two steps).
There is no direct ACTIVE → ARCHIVED path in the PD-04 state machine.

Two interpretations:
- (a) DELETE on ACTIVE auto-applies `deprecate()` then `archive()` in one transaction (two-step shortcut).
- (b) DELETE on ACTIVE means ACTIVE → DEPRECATED first (with HTTP 200 returning DEPRECATED Definition), and caller must issue a second DELETE to reach ARCHIVED.

Interpretation (a) is more consistent with the API-02 edge-case note (*"triggers archive"*), but contradicts the PD-04 transition table which has no direct ACTIVE→ARCHIVED.

**Action required:** REQ-ANALYST must clarify the intended sequence for `DELETE` on an ACTIVE definition before BACKEND-DEV implements `handleDelete`.

**OQ-2 — `hardDelete` safety check on DRAFT definitions that have snapshots:**
PD-08 edge case: *"Definition hard-deleted (DRAFT) after instances were started from it: instances retain their snapshot and continue normally."*
PD-04 says hard-delete is only for *"never-activated"* DRAFT definitions.

A DRAFT definition that was never activated cannot have been used to start an instance (instances require ACTIVE). However, a definition could theoretically be imported (PD-09) with DRAFT status, an instance snapshot could already reference it (if the import flow sets a pre-existing ID), or a race condition could occur during testing.

**Action required:** BACKEND-DEV should decide whether `Store.hardDelete()` should check for existing snapshot references before deleting. If the answer is yes, a FK constraint or a SELECT-before-DELETE guard is needed. This is a correctness question, not a schema design question.

**OQ-3 — `PUT /definitions/:id` with name+version change:**
If a caller issues `PUT /definitions/:id` with a different `name` and/or `version`, and that combination already exists in another row, the Store should return `DuplicateNameVersion`. However, there is also a question about whether the `id` in the URL path takes precedence or whether the caller's supplied `name`+`version` is expected to match the original values.

**Action required:** REQ-ANALYST should clarify whether PUT is allowed to rename a definition (change its name or version string) or whether `name` and `version` are immutable after creation (only `description`, `graph`, and `stage` can be replaced via PUT).
