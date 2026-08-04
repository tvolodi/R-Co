# Module: definition

**Covers:** PD-01, PD-02, PD-04
**Files:** `src/definition/store.zig`, `src/definition/graph.zig`

---

## Module purpose

The definition module manages the lifecycle of process definitions — the declarative graph
structure (nodes + edges) that the BPM engine evaluates at runtime. `store.zig` owns all
DB-backed CRUD and query operations against `process_definitions` and
`instance_definition_snapshots`. `graph.zig` implements the structural validation pipeline
required by PD-02; it is a pure, allocation-bounded function called synchronously inside
the PD-01 create path before any write is committed to the database.

---

## Public interface

### Shared types (imported by both store.zig and graph.zig)

```zig
/// Raw 16-byte UUID v4 representation.
pub const Uuid = [16]u8;

/// Every node type supported by the BPM graph model (PD-05).
/// NOTE: USER_TASK was renamed to HUMAN_TASK and SCRIPT_TASK replaced by TIMER per PD-05.
pub const NodeType = enum {
    START,
    END,
    HUMAN_TASK,
    SERVICE_TASK,
    EXCLUSIVE_GATEWAY,
    PARALLEL_GATEWAY,
    TIMER,
};

/// Allowed values for `process_definitions.status` (PD-04).
pub const DefinitionStatus = enum {
    DRAFT,
    ACTIVE,
    DEPRECATED,
    ARCHIVED,
};

/// Single node in the definition graph.
pub const GraphNode = struct {
    /// Non-empty, unique within the definition.
    id:        []const u8,
    node_type: NodeType,
    /// Display label — optional.
    label:     ?[]const u8,
    /// JSON object string containing type-specific attributes (PD-05).
    /// May be null for node types with no required attributes.
    /// See validateNodeAttributes() for per-type validation rules.
    attributes: ?[]const u8,
};

/// Directed edge connecting two nodes.
pub const GraphEdge = struct {
    /// Non-empty, unique within the definition.
    id:         []const u8,
    /// Refers to an existing GraphNode.id.
    source:     []const u8,
    /// Refers to an existing GraphNode.id.
    target:     []const u8,
    /// CEL condition expression for EXCLUSIVE_GATEWAY routing (PD-06).
    /// MUST be present (non-null, non-empty) on every non-default outgoing
    /// edge from an EXCLUSIVE_GATEWAY. MUST be null on all other edges.
    condition:  ?[]const u8,
    /// When true, this edge is the default (fallback) route from an
    /// EXCLUSIVE_GATEWAY. MUST NOT coexist with a non-null condition.
    /// At most one outgoing edge per EXCLUSIVE_GATEWAY may be default.
    is_default: bool,
};

/// Serialised form of the `graph` JSONB column: `{"nodes": [...], "edges": [...]}`.
pub const DefinitionGraph = struct {
    nodes: []GraphNode,
    edges: []GraphEdge,
};

/// In-memory representation of one row in `process_definitions`.
pub const Definition = struct {
    id:          Uuid,
    name:        []const u8,
    version:     []const u8,
    description: ?[]const u8,
    status:      DefinitionStatus,
    graph:       DefinitionGraph,
    created_by:  Uuid,
    /// UTC epoch microseconds (from TIMESTAMPTZ).
    created_at:  i64,
    /// UTC epoch microseconds (from TIMESTAMPTZ).
    updated_at:  i64,
    /// Null until definition enters ARCHIVED status.
    archived_at: ?i64,
};
```

---

### graph.zig

`graph.zig` is **pure**: no I/O, no DB calls, no logging, no clock reads. The caller
supplies an `std.mem.Allocator` solely for the `violations` output slice.

```zig
pub const GraphError = error{
    /// Allocation of the violations slice failed.
    OutOfMemory,
};

/// A single structural violation found during graph validation (PD-02).
pub const Violation = struct {
    /// Short machine-readable code — one of the CHK-XX codes in the table below.
    code:    []const u8,
    /// Human-readable message. MUST name the offending node ID or edge ID where applicable
    /// so that HTTP 422 responses can identify the exact element (PD-02 AC).
    message: []const u8,
};

/// Validation outcome. If `valid == false`, `violations` is non-empty.
/// `violations` is allocated with the caller-supplied allocator; caller owns it.
pub const ValidationResult = struct {
    valid:      bool,
    violations: []Violation,
};

/// Validate the graph structure per PD-02. ALL checks are executed; ALL violations
/// are collected before returning. Never exits early after the first failure.
///
/// Parameters:
///   allocator — used only for the returned violations slice.
///   graph     — the parsed DefinitionGraph to validate.
///
/// Returns GraphError.OutOfMemory only on allocation failure; not a validation error.
pub fn validateGraph(
    allocator: std.mem.Allocator,
    graph:     DefinitionGraph,
) GraphError!ValidationResult;
```

#### Named validation checks (PD-02)

| Check ID | Description                                                                                              | Violation code            | PD-02 AC |
|----------|----------------------------------------------------------------------------------------------------------|---------------------------|----------|
| CHK-01   | Exactly one START node present                                                                           | `MISSING_START_NODE` / `MULTIPLE_START_NODES` | AC-2 |
| CHK-02   | At least one END node present                                                                            | `MISSING_END_NODE`        | AC-3     |
| CHK-03   | No dangling edges: every edge `source` and `target` must reference an existing node ID                  | `DANGLING_EDGE`           | AC-4     |
| CHK-04   | No isolated nodes: every non-START/END node has ≥ 1 incoming and ≥ 1 outgoing edge; START has ≥ 1 outgoing; END has ≥ 1 incoming | `ISOLATED_NODE` | AC-1 |
| CHK-05   | No duplicate node IDs within the definition                                                              | `DUPLICATE_NODE_ID`       | AC-1     |
| CHK-06   | No cycles on paths that do not pass through a gateway node (EXCLUSIVE_GATEWAY or PARALLEL_GATEWAY). DFS-based detection; self-loops always rejected. | `CYCLE_WITHOUT_GATEWAY` | AC-5 |
| CHK-07   | Node count ≤ 500                                                                                         | `NODE_LIMIT_EXCEEDED`     | AC-6     |
| CHK-08   | Edge count ≤ 2,000                                                                                       | `EDGE_LIMIT_EXCEEDED`     | AC-6     |

**Algorithm outline for CHK-06:**

```
1. Build adjacency list from edges.
2. Build set GW = {node.id | node.node_type in {EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY}}.
3. DFS from every unvisited node; maintain a "recursion stack" set.
4. On each edge (u → v):
   a. If v is already on the recursion stack AND v ∉ GW AND u ∉ GW:
      → record CYCLE_WITHOUT_GATEWAY violation with the cycle path.
   b. A cycle that enters or exits a gateway node is permitted (PD-02 edge case).
5. Continue DFS until all nodes visited.
6. Collect all violations; do not abort early.
```

---

### store.zig

```zig
pub const DefinitionError = error{
    /// db.Pool.acquire() returned ExhaustedPool → HTTP 503
    PoolExhausted,
    /// UNIQUE (name, version) constraint violated — either sequential or concurrent → HTTP 409 (PD-01)
    DuplicateNameVersion,
    /// id not found in process_definitions → HTTP 404
    DefinitionNotFound,
    /// Attempted status transition not permitted by the lifecycle rules (PD-04) → HTTP 422
    InvalidStatusTransition,
    /// Caller supplied a non-DRAFT initial status → HTTP 422 (PD-01)
    InitialStatusNotDraft,
    /// name is empty or longer than 255 characters → HTTP 422 (PD-01)
    NameInvalid,
    /// version is empty → HTTP 422 (PD-01)
    VersionEmpty,
    /// graph is not a JSON object with a `nodes` array and an `edges` array → HTTP 422 (PD-01)
    GraphStructureInvalid,
    /// graph failed one or more PD-02 structural checks; call lastViolations() → HTTP 422 (PD-02)
    GraphValidationFailed,
    /// DB transaction failed to commit (transient) → HTTP 500
    TransactionFailed,
};

/// Parameters for Store.create() (PD-01).
pub const CreateParams = struct {
    name:        []const u8,
    version:     []const u8,
    /// Optional; stored as NULL when omitted.
    description: ?[]const u8,
    graph:       DefinitionGraph,
    /// Taken from auth middleware ctx.actor.user_id.
    created_by:  Uuid,
};

/// Options for Store.list().
pub const ListOpts = struct {
    /// Filter by exact name; null = all names.
    name:           ?[]const u8,
    /// Filter by status; null = all statuses.
    status:         ?DefinitionStatus,
    /// Cursor-based pagination: start after this created_at UTC µs value.
    after_created:  ?i64,
    /// Maximum rows to return (default 50, max 200).
    limit:          u8,
};

pub const Store = struct {
    /// pool and graph_validator must outlive Store.
    pub fn init(
        allocator: std.mem.Allocator,
        pool:      *db.Pool,
    ) Store;

    pub fn deinit(self: *Store) void;

    /// Validate input fields, call graph.validateGraph(), then INSERT into
    /// process_definitions with status = DRAFT and platform-assigned UUID.
    ///
    /// Returns the fully-populated Definition on success (HTTP 201).
    /// On PD-02 failure: returns GraphValidationFailed; call lastViolations() for detail.
    /// On name+version collision: returns DuplicateNameVersion (HTTP 409).
    ///
    /// Covers: PD-01 (create, validation, status assignment, UUID assignment)
    ///         PD-02 (graph validation called before every INSERT)
    pub fn create(
        self:      *Store,
        allocator: std.mem.Allocator,
        params:    CreateParams,
    ) DefinitionError!Definition;

    /// Retrieve a single definition by primary key.
    /// Returns DefinitionNotFound if id is not in process_definitions.
    pub fn getById(
        self:      *Store,
        allocator: std.mem.Allocator,
        id:        Uuid,
    ) DefinitionError!Definition;

    /// List definitions with optional filters; cursor-based, ordered by created_at ASC.
    /// Returns an empty slice (not an error) when no rows match.
    pub fn list(
        self:      *Store,
        allocator: std.mem.Allocator,
        opts:      ListOpts,
    ) DefinitionError![]Definition;

    /// After a GraphValidationFailed error, return the PD-02 violations from the
    /// most recent create() or update() call.
    /// The returned slice is owned by Store; valid until the next Store method call.
    pub fn lastViolations(self: *Store) []const graph.Violation;
};
```

---

## Data types

All types are enumerated in the **Shared types** section above. Summary:

| Type             | Kind          | Notes                                                  |
|------------------|---------------|--------------------------------------------------------|
| `Uuid`           | `[16]u8`      | 16-byte raw UUID v4                                    |
| `NodeType`       | `enum`        | START, END, HUMAN_TASK, SERVICE_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY, TIMER |
| `DefinitionStatus` | `enum`      | DRAFT / ACTIVE / DEPRECATED / ARCHIVED                |
| `GraphNode`      | `struct`      | id, node_type, label, attributes                       |
| `GraphEdge`      | `struct`      | id, source, target, condition, is_default           |
| `DefinitionGraph`| `struct`      | Holds `[]GraphNode` and `[]GraphEdge`                  |
| `Definition`     | `struct`      | Full row representation                                |
| `Violation`      | `struct`      | code + message; used in PD-02 error responses          |
| `ValidationResult` | `struct`    | valid flag + violations slice                          |
| `CreateParams`   | `struct`      | Input to `Store.create()`                              |
| `ListOpts`       | `struct`      | Filtering + pagination for `Store.list()`              |

---

## Data flow diagram

```
HTTP POST /definitions
         │
         ▼
  api/routes/definitions.zig
         │  1. Parse JSON body into CreateParams
         │  2. RBAC: require PROCESS_DESIGNER or PLATFORM_ADMIN role (PD-01 AC, IDN-03)
         │
         ▼
  store.create(allocator, params)
         │
         ├─ [A] Input validation
         │      • name non-empty, ≤ 255 chars     → NameInvalid (HTTP 422)
         │      • version non-empty               → VersionEmpty (HTTP 422)
         │      • graph is {nodes:[], edges:[]}   → GraphStructureInvalid (HTTP 422)
         │      • initial status not specified    → InitialStatusNotDraft (HTTP 422)
         │
         ├─ [B] graph.validateGraph(allocator, params.graph)
         │      ┌─ CHK-01 … CHK-08 run in full ──────────────────────┐
         │      │  all violations collected; never early exit         │
         │      └────────────────────────────────────────────────────┘
         │      if violations → store violations → GraphValidationFailed → HTTP 422
         │
         ├─ [C] pool.acquire()
         │
         ├─ [D] INSERT INTO process_definitions
         │      (id=gen_random_uuid(), status='DRAFT', graph=<jsonb>, ...)
         │      ON CONFLICT (name, version) DO NOTHING RETURNING *
         │      if 0 rows returned → DuplicateNameVersion → HTTP 409
         │
         ├─ [E] pool.release()
         │
         └─ return Definition → HTTP 201
```

---

## Database mapping

### `process_definitions` ↔ `Definition`

| `Definition` field | SQL column                          | Type / Constraint                        |
|--------------------|-------------------------------------|------------------------------------------|
| `id`               | `process_definitions.id`            | UUID PK, `DEFAULT gen_random_uuid()`     |
| `name`             | `process_definitions.name`          | TEXT NOT NULL                            |
| `version`          | `process_definitions.version`       | TEXT NOT NULL                            |
| `description`      | `process_definitions.description`   | TEXT NULLABLE                            |
| `status`           | `process_definitions.status`        | TEXT NOT NULL, DEFAULT `'DRAFT'`         |
| `graph`            | `process_definitions.graph`         | JSONB NOT NULL, DEFAULT `'{"nodes":[],"edges":[]}'` |
| `created_by`       | `process_definitions.created_by`    | UUID NOT NULL                            |
| `created_at`       | `process_definitions.created_at`    | TIMESTAMPTZ → i64 UTC µs                 |
| `updated_at`       | `process_definitions.updated_at`    | TIMESTAMPTZ → i64 UTC µs                 |
| `archived_at`      | `process_definitions.archived_at`   | TIMESTAMPTZ NULLABLE                     |

### Unique constraints (from `migrations/004_definitions.sql`)

| Constraint                  | Column(s)              | Condition              | Purpose                     |
|-----------------------------|------------------------|------------------------|-----------------------------|
| `uq_definition_version`     | `(name, version)`      | —                      | PD-01: duplicate rejection  |
| `uq_active_definition`      | `(name)`               | `WHERE status='ACTIVE'`| PD-03: one active per name  |

### `instance_definition_snapshots` (used at instance launch — PD-08)

Not written by `store.zig`. Populated by the engine at instance start time to freeze the graph.
Included here for DB-mapping completeness.

| Column              | Notes                                                |
|---------------------|------------------------------------------------------|
| `instance_id`       | FK to `process_instances.id`                         |
| `definition_id`     | FK to `process_definitions.id`                       |
| `definition_name`   | Denormalised for human readability in logs/reports   |
| `definition_ver`    | Denormalised version string                          |
| `graph`             | Immutable JSONB snapshot; running instances unaffected by later definition changes |
| `snapshotted_at`    | TIMESTAMPTZ                                          |

---

## Concurrency safety note (HTTP 409 path, PD-01)

Two concurrent `POST /definitions` requests with the same `name + version` will race at
`INSERT` time. The strategy is:

```
INSERT INTO process_definitions (...)
VALUES (...)
ON CONFLICT (name, version) DO NOTHING
RETURNING *
```

- **Winner:** `RETURNING *` yields one row → commit → HTTP 201.
- **Loser:** `RETURNING *` yields zero rows → `store.zig` maps to `DuplicateNameVersion` → HTTP 409.

No application-level lock is required. PostgreSQL's MVCC guarantees exactly one INSERT
wins, even under concurrent load. The loser's transaction is automatically rolled back
before the INSERT completes. This covers the PD-01 edge case:

> *"Two concurrent requests with the same name+version: exactly one succeeds; the other receives HTTP 409."*

---

## Error taxonomy

| Error                    | Source check        | HTTP status | PD ref    |
|--------------------------|---------------------|-------------|-----------|
| `NameInvalid`            | name empty / > 255  | 422         | PD-01     |
| `VersionEmpty`           | version empty       | 422         | PD-01     |
| `InitialStatusNotDraft`  | caller set status   | 422         | PD-01     |
| `GraphStructureInvalid`  | not `{nodes,edges}` | 422         | PD-01     |
| `GraphValidationFailed`  | CHK-01 … CHK-08     | 422         | PD-02     |
| `DuplicateNameVersion`   | UNIQUE conflict     | 409         | PD-01     |
| `DefinitionNotFound`     | id not in DB        | 404         | —         |
| `InvalidStatusTransition`| lifecycle rule      | 422         | PD-04     |
| `PoolExhausted`          | pool.acquire()      | 503         | DB-02     |
| `TransactionFailed`      | DB commit           | 500         | DB-03     |
| `GraphError.OutOfMemory` | violations alloc    | 500         | —         |

All PD-02 violations are returned together in a single HTTP 422 response; the API layer
serialises `lastViolations()` into the problem detail body. This satisfies PD-02 AC:
*"Validation errors MUST list ALL violations found, not just the first."*

---

## State transitions (DefinitionStatus)

```
                  create()
                     │
                     ▼
                  DRAFT ──────────────────────────────────────────────────┐
                     │                                                    │
             activate()                                               archive()
                     │                                                    │
                     ▼                                                    ▼
                  ACTIVE ──────────────── deprecate() ──────> DEPRECATED  │
                     │                                              │      │
                 archive()                                      archive()  │
                     │                                              │      │
                     └─────────────────────────────────────────────┴──>  ARCHIVED
                                                                        (terminal)
```

Permitted transitions:
- `DRAFT → ACTIVE` (activate)
- `DRAFT → ARCHIVED` (archive without activating)
- `ACTIVE → DEPRECATED` (deprecate)
- `ACTIVE → ARCHIVED` (archive)
- `DEPRECATED → ARCHIVED` (archive)
- `ARCHIVED → (none)` — terminal

*Full lifecycle rule enforcement is PD-04 scope; this module enforces the constraint at
the DB layer and returns `InvalidStatusTransition` on violation. PD-04 design will be
covered in a separate CODE-DESIGNER handoff.*

---

## Dependencies

| Dependency               | Direction                          | Notes                                              |
|--------------------------|------------------------------------|----------------------------------------------------|
| `src/db/pool.zig`        | `store.zig` → `db.Pool`            | Connection pool; `pool` must outlive `Store`       |
| `src/definition/graph.zig` | `store.zig` → `graph.validateGraph()` | Pure call; never touches DB                   |
| `src/api/errors.zig`     | `api/routes/definitions.zig` → `DefinitionError` | HTTP status mapping            |
| `migrations/004_definitions.sql` | Schema               | `process_definitions`, `instance_definition_snapshots` |
| `src/api/middleware/auth.zig` | Provides `ctx.actor.user_id`  | Stored as `created_by`                         |
| `src/api/middleware/rbac.zig` | Enforces PD-01 role check     | PROCESS_DESIGNER or PLATFORM_ADMIN             |

**Must NOT depend on:**

- `src/engine/transition.zig` — engine must not depend on definition CRUD at runtime.
- `src/event_store/` — definitions have no event log.
- Any external HTTP service.
- `src/scheduler/` — definitions have no scheduled jobs.

---

## Key invariants

1. `graph.validateGraph()` MUST be called before every INSERT or UPDATE touching the `graph` column. No bypass path exists in `store.zig`.
2. Initial `status` is always `DRAFT`; `store.create()` hard-codes this — the `params` struct carries no `status` field.
3. `store.zig` never interpolates user-supplied values directly into SQL strings. All values are passed as `pg.zig` parameterised query arguments (`$1`, `$2`, …).
4. `graph.zig` is pure: no I/O, no DB calls, no logging, no `std.time` calls. The only allocation it performs is the output `violations` slice.
5. All PD-02 violations are collected before returning `GraphValidationFailed`. `validateGraph()` never short-circuits after the first failure.
6. On `DuplicateNameVersion`, `store.zig` returns the error without leaking which caller "won" the race — both callers receive HTTP 409 with the same message shape.

---

## PD-01 and PD-02 acceptance criteria traceability

| Requirement AC                                                                               | Design element                                        |
|----------------------------------------------------------------------------------------------|-------------------------------------------------------|
| PD-01 AC: HTTP 201, UUID, status=DRAFT, all fields returned                                  | `Store.create()` → `Definition` return type           |
| PD-01 AC: graph must be `{nodes:[], edges:[]}`                                               | Input check A → `GraphStructureInvalid`               |
| PD-01 AC: name ≤ 255 non-empty, version non-empty                                           | Input check A → `NameInvalid`, `VersionEmpty`         |
| PD-01 AC: same name+version → HTTP 409                                                       | ON CONFLICT → `DuplicateNameVersion`; concurrency note |
| PD-01 AC: PROCESS_DESIGNER or PLATFORM_ADMIN role                                            | RBAC middleware; not in store.zig                     |
| PD-01 AC: initial status always DRAFT                                                        | `Store.create()` hard-codes DRAFT; no caller override  |
| PD-01 edge: concurrent same name+version → exactly one 201, one 409                         | Concurrency safety note; ON CONFLICT DO NOTHING       |
| PD-02 AC: valid graph passes                                                                  | `validateGraph()` returns `{valid:true, violations:[]}` |
| PD-02 AC: 0 or 2+ START → 422 with identification                                           | CHK-01 → `MISSING_START_NODE` / `MULTIPLE_START_NODES` |
| PD-02 AC: no END → 422                                                                       | CHK-02 → `MISSING_END_NODE`                           |
| PD-02 AC: dangling edge reference → 422                                                      | CHK-03 → `DANGLING_EDGE` with edge ID                 |
| PD-02 AC: non-gateway cycle → 422                                                            | CHK-06 → `CYCLE_WITHOUT_GATEWAY` with cycle path      |
| PD-02 AC: >500 nodes or >2000 edges → 422                                                   | CHK-07 → `NODE_LIMIT_EXCEEDED`; CHK-08 → `EDGE_LIMIT_EXCEEDED` |
| PD-02 AC: all violations listed, not just first                                               | Key invariant 5; `validateGraph()` never exits early  |
| PD-02 edge: cycle through gateway permitted                                                   | CHK-06 algorithm: gateway nodes exempt from cycle check |
| PD-02 edge: isolated node (no edges, non-START) rejected                                      | CHK-04 → `ISOLATED_NODE`                             |
| PD-02 edge: self-loop rejected                                                                | CHK-06: self-loop is cycle without gateway → rejected  |

---

## PD-04 — Definition lifecycle: deprecate and archive

### Corrections to pre-PD-04 placeholder content

Two items written as placeholders in earlier sections are superseded by this PD-04 design:

1. **State transition diagram** ("State transitions" section above): The placeholder incorrectly listed `DRAFT→ARCHIVED` and `ACTIVE→ARCHIVED` as permitted transitions. The authoritative PD-04 rule is: **only DRAFT→ACTIVE, ACTIVE→DEPRECATED, and DEPRECATED→ARCHIVED are permitted**. All other transitions are rejected with `InvalidStatusTransition` (HTTP 409). The authoritative table is in § "Authoritative state transition table" below.

2. **Error taxonomy** (above, `InvalidStatusTransition` row): The HTTP status was recorded as 422. Per PD-04, the correct status is **HTTP 409** (conflict with the resource's current state, not a request-body validation error).

---

### New function signatures (Store extensions for PD-04)

The following two methods are added to `pub const Store` in `src/definition/store.zig`:

```zig
/// Transition this definition from ACTIVE to DEPRECATED.
///
/// Precondition:  definition with the given `id` exists and has status = ACTIVE.
/// Postcondition: status = DEPRECATED, updated_at = NOW().
///
/// Errors:
///   DefinitionNotFound         — id not in process_definitions        → HTTP 404
///   InvalidStatusTransition    — current status ≠ ACTIVE               → HTTP 409
///   PoolExhausted              — pool.acquire() failed                 → HTTP 503
///   TransactionFailed          — DB commit failed (transient)           → HTTP 500
pub fn deprecate(
    self:      *Store,
    allocator: std.mem.Allocator,
    id:        Uuid,
) DefinitionError!Definition;

/// Transition this definition from DEPRECATED to ARCHIVED.
///
/// Precondition:  definition with the given `id` exists and has status = DEPRECATED.
/// Postcondition: status = ARCHIVED, archived_at = NOW(), updated_at = NOW().
///               ARCHIVED is terminal — no further transitions are possible.
///
/// Errors:
///   DefinitionNotFound         — id not in process_definitions        → HTTP 404
///   InvalidStatusTransition    — current status ≠ DEPRECATED           → HTTP 409
///                                (covers ACTIVE→ARCHIVED shortcut and ARCHIVED→ARCHIVED)
///   PoolExhausted              — pool.acquire() failed                 → HTTP 503
///   TransactionFailed          — DB commit failed (transient)           → HTTP 500
pub fn archive(
    self:      *Store,
    allocator: std.mem.Allocator,
    id:        Uuid,
) DefinitionError!Definition;
```

---

### Authoritative state transition table (PD-04)

| From \ To      | DRAFT       | ACTIVE          | DEPRECATED      | ARCHIVED        |
|----------------|-------------|-----------------|-----------------|------------------|
| **DRAFT**      | —           | `activate()` ✓  | ✗ HTTP 409      | ✗ HTTP 409       |
| **ACTIVE**     | ✗ HTTP 409  | —               | `deprecate()` ✓ | ✗ HTTP 409       |
| **DEPRECATED** | ✗ HTTP 409  | ✗ HTTP 409      | —               | `archive()` ✓    |
| **ARCHIVED**   | ✗ HTTP 409  | ✗ HTTP 409      | ✗ HTTP 409      | — (terminal)     |

- `✓` = permitted; implemented by the function shown.
- `✗ HTTP 409` = rejected; `store.zig` returns `InvalidStatusTransition` which the route handler maps to HTTP 409.
- `—` = not applicable (no self-transition defined).
- **ARCHIVED is terminal.** Calling `archive()` on an already-ARCHIVED definition returns `InvalidStatusTransition` (HTTP 409) because the WHERE clause (`status = 'DEPRECATED'`) matches zero rows.

#### SQL implementation pattern for `deprecate()`

```sql
UPDATE process_definitions
SET    status     = 'DEPRECATED',
       updated_at = NOW()
WHERE  id = $1
  AND  status = 'ACTIVE'
RETURNING *
```

Zero-row resolution: re-fetch by `$1`; if row exists → current status ≠ ACTIVE → return `InvalidStatusTransition`; if row absent → return `DefinitionNotFound`.

#### SQL implementation pattern for `archive()`

```sql
UPDATE process_definitions
SET    status      = 'ARCHIVED',
       archived_at = NOW(),
       updated_at  = NOW()
WHERE  id = $1
  AND  status = 'DEPRECATED'
RETURNING *
```

Zero-row resolution: identical pattern — re-fetch; if found → `InvalidStatusTransition`; if absent → `DefinitionNotFound`.

Both UPDATE statements use `$1` (parameterised). No user-supplied string is interpolated into SQL.

---

### HTTP API routes (PD-04)

Two new route entries are added to `src/api/routes/definitions.zig`:

| Method | Path                                | Handler             | Required role                       |
|--------|-------------------------------------|---------------------|--------------------------------------|
| `POST` | `/definitions/{id}/deprecate`       | `Store.deprecate()` | PROCESS_DESIGNER or PLATFORM_ADMIN  |
| `POST` | `/definitions/{id}/archive`         | `Store.archive()`   | PROCESS_DESIGNER or PLATFORM_ADMIN  |

Request body: none. The operation is fully identified by the URL path parameter `{id}`.

Successful response: HTTP 200 with the updated `Definition` serialised as JSON (same shape as `GET /definitions/{id}`).

Error response mapping:

| `DefinitionError`         | HTTP status | Response body field `"error"`                          |
|---------------------------|-------------|--------------------------------------------------------|
| `DefinitionNotFound`      | 404         | `"definition_not_found"`                               |
| `InvalidStatusTransition` | 409         | `"invalid_status_transition"` + `"current_status"` field |
| `PoolExhausted`           | 503         | `"service_unavailable"`                                |
| `TransactionFailed`       | 500         | `"internal_error"`                                     |

RBAC enforcement is identical to `POST /definitions/{id}/activate` (PD-03): the RBAC middleware rejects callers whose role is neither PROCESS_DESIGNER nor PLATFORM_ADMIN with HTTP 403 before the handler is invoked.

---

### Instance-start guard (informational — enforced by EE-01)

> Enforcement lives in the engine layer (EE-01), not in `store.zig`. This note exists for cross-requirement traceability.

- **Only ACTIVE definitions may be used to start a new process instance.** The engine's instance-start path reads the definition's current `status` from `process_definitions` and returns HTTP 409 if `status ≠ ACTIVE`.
- **DEPRECATED definitions and running instances:** existing process instances that were started while the definition was ACTIVE hold an immutable snapshot in `instance_definition_snapshots` (PD-08). These instances MUST continue to completion; the platform MUST NOT terminate them due to the deprecation of their source definition. The snapshot mechanism fully isolates running instances from subsequent definition status changes.
- **ARCHIVED definitions:** treated identically to DEPRECATED at the instance-start boundary — HTTP 409. No new instances may start from an ARCHIVED definition.

---

### PD-04 acceptance criteria traceability

| PD-04 Acceptance Criterion | Design element |
|---|---|
| DRAFT → ACTIVE on activate request | `Store.activate()` (PD-03 scope); included in authoritative transition table above |
| ACTIVE → DEPRECATED on deprecate request | `Store.deprecate()` signature; SQL `WHERE status = 'ACTIVE'`; returns `InvalidStatusTransition` (HTTP 409) for any other current status |
| DEPRECATED → ARCHIVED on archive request | `Store.archive()` signature; SQL `WHERE status = 'DEPRECATED'`; sets `archived_at = NOW()`; returns `InvalidStatusTransition` (HTTP 409) for any other current status |
| Any other transition attempt → HTTP 409 | `InvalidStatusTransition` error variant; HTTP 409 mapping in route handler; every forbidden cell in the state transition table above |
| ARCHIVED → HTTP 409 for any modification (update, re-activate, re-deprecate, re-archive) | `deprecate()` WHERE clause rejects ARCHIVED; `archive()` WHERE clause rejects ARCHIVED; terminal-state row in transition table |
| Existing instances on DEPRECATED definition continue to completion | Instance-start guard note; `instance_definition_snapshots` snapshot mechanism (PD-08) isolates running instances from status changes |
| New instances only from ACTIVE definitions | Instance-start guard note; enforced in engine by EE-01; DEPRECATED and ARCHIVED both yield HTTP 409 at the engine layer |
| Edge case: ACTIVE → ARCHIVED directly (skip DEPRECATED) → HTTP 409 | `Store.archive()` `WHERE status = 'DEPRECATED'` fails for ACTIVE → `InvalidStatusTransition` → HTTP 409 |
| Edge case: DRAFT → ARCHIVED → HTTP 409 | `Store.archive()` `WHERE status = 'DEPRECATED'` fails for DRAFT → `InvalidStatusTransition` → HTTP 409 |

---

## Open questions

None — PD-01 and PD-02 are fully validated requirements. The following are noted as out
of scope for this artefact and require separate handoffs:

- **PD-04** (lifecycle transition rules beyond the DRAFT→ACTIVE path): `InvalidStatusTransition` is declared in the error set but the full rule table is deferred.
- **PD-05** (node-type attribute validation): runs after graph-structure validation; needs its own design artefact covering attribute schemas per `NodeType`.

---

## PD-03 — Version management (`Store.activate`)

**Covers:** PD-03
**Extends:** The PD-01/PD-02 sections above; read those first.

---

### New public function: `Store.activate`

```zig
/// Activate a DRAFT definition, atomically deprecating any previously ACTIVE version
/// of the same name — all within a single DB transaction.
///
/// Behaviour by current status of the target definition (checked inside the transaction):
///   DRAFT      → transition to ACTIVE; prior ACTIVE version for the same name (if any)
///              is transitioned to DEPRECATED in the same transaction.
///              Returns the updated Definition (HTTP 200).
///   ACTIVE     → idempotent no-op; returns DefinitionError.AlreadyActive.
///              The HTTP handler MUST map this to HTTP 200 and return the current
///              Definition body (fetched by the handler before replying).
///   DEPRECATED → rejected; returns DefinitionError.NotDraft (HTTP 409).
///   ARCHIVED   → rejected; returns DefinitionError.NotDraft (HTTP 409).
///   not found  → returns DefinitionError.DefinitionNotFound (HTTP 404).
///
/// Covers: PD-03 (version management, single-active-per-name invariant)
pub fn activate(
    self:      *Store,
    allocator: std.mem.Allocator,
    id:        Uuid,
) DefinitionError!Definition;
```

---

### Extended `DefinitionError` set (PD-03 additions)

Two new variants are added to the `DefinitionError` error set declared in the
PD-01/PD-02 section:

```zig
pub const DefinitionError = error{
    // ── existing entries (PD-01 / PD-02) ──────────────────────────────────
    PoolExhausted,
    DuplicateNameVersion,
    DefinitionNotFound,
    InvalidStatusTransition,
    InitialStatusNotDraft,
    NameInvalid,
    VersionEmpty,
    GraphStructureInvalid,
    GraphValidationFailed,
    TransactionFailed,

    // ── PD-03 additions ───────────────────────────────────────────────────

    /// Target definition is already in ACTIVE status — no state change performed.
    /// The HTTP handler maps this to HTTP 200 and returns the current Definition body.
    /// Satisfies PD-03 edge case: "activating the already-ACTIVE version is a no-op."
    AlreadyActive,

    /// Attempted to activate a definition whose status is DEPRECATED or ARCHIVED.
    /// Only DRAFT definitions may be activated.
    /// The HTTP handler maps this to HTTP 409.
    /// Satisfies PD-03 edge case: "activating DEPRECATED or ARCHIVED is rejected."
    NotDraft,
};
```

`DefinitionNotFound` (HTTP 404) is shared with the PD-01 error set and applies unchanged
to `activate()`.

---

### SQL transaction outline (`Store.activate`)

The transaction performs an atomic two-step swap: deprecate any existing ACTIVE version
for the same name, then activate the target. This ordering guarantees the
`uq_active_definition` partial unique index (`ON process_definitions(name) WHERE
status = 'ACTIVE'`) is never transiently violated within the transaction.

```sql
BEGIN;

-- Step 1: Lock the target row and read its current status.
-- The FOR UPDATE prevents a concurrent activate() call from changing this row
-- between the status check and the final UPDATE.
SELECT id, status, name
FROM   process_definitions
WHERE  id = $1            -- $1 = target definition UUID
FOR UPDATE;

-- (application): 0 rows → ROLLBACK; return DefinitionNotFound (HTTP 404)
-- (application): status = 'ACTIVE'      → ROLLBACK; return AlreadyActive (HTTP 200 no-op)
-- (application): status ≠ 'DRAFT'       → ROLLBACK; return NotDraft (HTTP 409)
-- $2 is set to the `name` value returned by Step 1.

-- Step 2: Lock the existing ACTIVE row for the same name (if any).
-- Acquiring this lock before any UPDATE serialises concurrent activate() calls
-- that share the same name group, preventing two transactions from each believing
-- they need to deprecate the same prior-ACTIVE row.
SELECT id
FROM   process_definitions
WHERE  name   = $2        -- $2 = name obtained from Step 1
  AND  status = 'ACTIVE'
FOR UPDATE;

-- Step 3: Deprecate the prior ACTIVE version.
-- This is a no-op (0 rows affected) when no ACTIVE version exists for the name.
-- MUST precede Step 4 to avoid transiently violating uq_active_definition.
UPDATE process_definitions
SET    status     = 'DEPRECATED',
       updated_at = NOW()
WHERE  name   = $2
  AND  status = 'ACTIVE';

-- Step 4: Activate the target definition.
UPDATE process_definitions
SET    status     = 'ACTIVE',
       updated_at = NOW()
WHERE  id = $1
RETURNING *;

COMMIT;
```

**Ordering rationale:** Step 3 (ACTIVE → DEPRECATED) MUST execute before Step 4
(DRAFT → ACTIVE). Reversing the order would transiently create two ACTIVE rows for the
same name, violating the `uq_active_definition` partial unique index constraint.

---

### Updated state transition diagram (PD-03 extension)

The diagram from the PD-01/PD-02 section is reproduced and annotated to show the
`activate()` side-effect introduced by PD-03.

```
                  create()
                     │
                     ▼
                  DRAFT ──────────────────────────────────────────────────┐
                     │                                                    │
             activate()                                               archive()
                     │                                                    │
                     ▼                                                    │
                  ACTIVE ──────────────── deprecate() ──────> DEPRECATED  │
               ↑  │                                                │      │
               │  │  Side-effect (PD-03):                      archive()  │
               │  │  prior ACTIVE for same                          │      │
               │  │  name → DEPRECATED,                            │      │
               │  │  atomically in same txn                        │      │
               │  │                                                │      │
               │  └── archive() ──────────────────────────────────┴──> ARCHIVED
               │                                                        (terminal)
               │
        activate() on already-ACTIVE → AlreadyActive (no-op, HTTP 200)
```

**PD-03 transition summary table:**

| Current status of target | `activate(id)` result         | Side-effect on name group                        |
|--------------------------|-------------------------------|--------------------------------------------------|
| `DRAFT`                  | → `ACTIVE`; return Definition | Prior `ACTIVE` for same name → `DEPRECATED`      |
| `ACTIVE`                 | `AlreadyActive` (HTTP 200)    | None (no-op)                                     |
| `DEPRECATED`             | `NotDraft` (HTTP 409)         | None                                             |
| `ARCHIVED`               | `NotDraft` (HTTP 409)         | None                                             |
| not found                | `DefinitionNotFound` (HTTP 404)| None                                            |

---

### Extended error taxonomy (PD-03)

The error taxonomy table from the PD-01/PD-02 section is extended with PD-03 entries:

| Error                | Source check                            | HTTP status  | PD ref |
|----------------------|-----------------------------------------|--------------|--------|
| `NotDraft`           | target status = `DEPRECATED`/`ARCHIVED` | 409          | PD-03  |
| `AlreadyActive`      | target status already = `ACTIVE`        | 200 (no-op)  | PD-03  |
| `DefinitionNotFound` | target `id` not in DB                   | 404          | PD-03  |
| `TransactionFailed`  | DB commit failure                       | 500          | DB-03  |
| `PoolExhausted`      | `pool.acquire()` failed                 | 503          | DB-02  |

*`DefinitionNotFound`, `TransactionFailed`, and `PoolExhausted` are shared with the
PD-01/PD-02 error set and apply unchanged to `activate()`.*

---

### Concurrency safety note (`Store.activate`)

Two concurrent `PATCH /definitions/{id}/activate` requests — whether for the same
definition `id` or for two different DRAFT definitions sharing the same `name` — must
not be able to produce two simultaneous ACTIVE rows.

**Mechanism:**

1. **Step-1 `FOR UPDATE` on the target row** — serialises concurrent activations of
   the *same* definition: the second concurrent caller blocks until the first commits,
   then reads `status = 'ACTIVE'` and returns `AlreadyActive` (HTTP 200 no-op).

2. **Step-2 `FOR UPDATE` on the current ACTIVE row** — serialises concurrent activations
   of *different* DRAFT definitions that share the same `name`: the second caller blocks
   until the first has already deprecated the prior ACTIVE version and committed, at
   which point Step 2 finds no ACTIVE row to lock and proceeds to activate without
   conflict.

3. **`uq_active_definition` partial unique index** — acts as the final DB-level safety
   net. Even if the application-level locking were somehow bypassed, the index rejects
   any attempt to INSERT or UPDATE a second `ACTIVE` row for the same `name`. The
   transaction rolls back and `store.zig` maps this to `TransactionFailed` (HTTP 500).

**Invariant guaranteed:** At no point do two versions of the same `name` simultaneously
carry `status = 'ACTIVE'` — satisfying PD-03 AC: *"At no point MAY two versions of the
same name simultaneously have `status = ACTIVE`."*

No application-level mutex or advisory lock is required.

---

### PD-03 acceptance criteria traceability

| PD-03 acceptance criterion                                                                                                                    | Design element satisfying it                                                                                    |
|-----------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| GIVEN name N has existing ACTIVE version V1, WHEN V2 is activated for N, THEN V1's status → DEPRECATED atomically in the same transaction     | SQL transaction Steps 2–4; single `BEGIN/COMMIT`; Step 3 deprecates V1 before Step 4 activates V2             |
| At no point MAY two versions of the same name simultaneously have `status = ACTIVE`                                                           | `uq_active_definition` partial unique index (DB constraint); Step 3 precedes Step 4; `FOR UPDATE` locking       |
| GIVEN no ACTIVE version for name N, WHEN the first version is activated, THEN it becomes ACTIVE with no prior version to deprecate             | Step 3 `UPDATE … WHERE status = 'ACTIVE'` matches 0 rows (no-op); Step 4 activates the target                  |
| Listing definitions filtered by `status=ACTIVE` MUST return at most one version per name                                                      | `uq_active_definition` partial unique index enforces this invariant at DB level at all times                    |
| Version strings compared as opaque strings; no semantic-versioning ordering enforced                                                          | `activate()` targets the definition by `id` (UUID), never parses or orders version strings                     |
| Activating the already-ACTIVE version of the same name: no-op; HTTP 200 (idempotent)                                                         | Step-1 status check → `AlreadyActive`; HTTP handler maps to 200 with current Definition body                   |
| Activating a DEPRECATED or ARCHIVED version: rejected with HTTP 409 (only DRAFT may be activated)                                            | Step-1 status check → `NotDraft`; HTTP handler maps to 409                                                      |

---

## PD-05 — Node types

**Covers:** PD-05
**Extends:** The PD-01/PD-02/PD-03 sections above; read those first.

---

### Enum and struct changes relative to prior design

This section documents the corrective changes required to bring `src/definition/graph.zig`
into conformance with PD-05. The shared-type definitions block at the top of this document
has been updated accordingly; the source code must match.

#### NodeType enum correction

The **current** `NodeType` enum in `src/definition/graph.zig` is incorrect:

```zig
// BEFORE (does not match PD-05):
pub const NodeType = enum {
    START,
    END,
    USER_TASK,          // ← wrong name
    SERVICE_TASK,
    EXCLUSIVE_GATEWAY,
    PARALLEL_GATEWAY,
    SCRIPT_TASK,        // ← wrong name; must be replaced by TIMER
};
```

The **required** enum per PD-05:

```zig
// AFTER (correct):
pub const NodeType = enum {
    START,
    END,
    HUMAN_TASK,         // renamed from USER_TASK
    SERVICE_TASK,
    EXCLUSIVE_GATEWAY,
    PARALLEL_GATEWAY,
    TIMER,              // replaces SCRIPT_TASK
};
```

**Downstream rename impacts (BACKEND-DEV must address all before build passes):**

| Location | Impact |
|---|---|
| `src/definition/graph.zig` | Enum definition itself; also any `switch` on `NodeType` inside `validateGraph()` or helpers |
| `tests/unit/definition_test.zig` | 12+ occurrences of `.USER_TASK`; no `SCRIPT_TASK` references found in tests — all must be updated to `.HUMAN_TASK` |
| JSON serialisation / deserialisation | Any code that maps `"USER_TASK"` / `"SCRIPT_TASK"` string literals to enum variants must be updated to `"HUMAN_TASK"` / `"TIMER"` |
| API documentation / OpenAPI spec | String values in request/response schemas must reflect the new names |
| Any existing stored data in `process_definitions.graph` JSONB | Migration guidance: if the DB contains rows with `type: "USER_TASK"` or `type: "SCRIPT_TASK"`, a data migration is required; BACKEND-DEV must assess and include a migration if needed |

---

#### Updated GraphNode struct

The `GraphNode` struct gains an `attributes` field to hold per-node type-specific
configuration as a JSON object string:

```zig
pub const GraphNode = struct {
    /// Non-empty, unique within the definition.
    id:         []const u8,
    node_type:  NodeType,
    /// Display label — optional.
    label:      ?[]const u8,
    /// JSON object string containing type-specific attributes.
    /// May be null for node types with no required attributes.
    /// See validateNodeAttributes() for per-type validation rules.
    attributes: ?[]const u8,
};
```

**Memory ownership:** `attributes` is a slice pointing into the caller-owned input buffer
(same as `id` and `label`). `GraphNode` does not own or allocate this memory.

---

### New public function: `validateNodeAttributes`

```zig
/// Validate per-node-type mandatory attributes for all nodes in the graph.
///
/// Called after validateGraph() succeeds in the Store.create() path.
/// Same memory contract as validateGraph(): the caller supplies an allocator
/// used only for the output violations slice and message strings.
///
/// ALL nodes are checked; ALL violations are collected before returning.
/// The function never exits early after the first failure.
///
/// Memory contract:
///   - The returned ValidationResult.violations slice is allocated with allocator.
///   - Every Violation.message string is also allocated with allocator.
///   - On success (valid == true, violations empty), caller frees:
///       allocator.free(result.violations);   // empty slice, still valid to free
///   - On validation failure (valid == false), caller frees:
///       for (result.violations) |v| allocator.free(v.message);
///       allocator.free(result.violations);
///   - On GraphError.OutOfMemory nothing has been allocated.
///
/// Pure function: no I/O, no DB calls, no logging.
/// Lives in graph.zig alongside validateGraph().
pub fn validateNodeAttributes(
    allocator: std.mem.Allocator,
    graph:     DefinitionGraph,
) GraphError!ValidationResult;
```

---

### Attribute validation rules (all 7 node types)

| NodeType | Required attributes | Validation rules | Violation code(s) |
|---|---|---|---|
| `START` | none | — | — |
| `END` | none | — | — |
| `HUMAN_TASK` | `role` | non-empty string; absence or empty string rejected HTTP 422 | `HUMAN_TASK_MISSING_ROLE` |
| `SERVICE_TASK` | `endpoint`, `timeout_ms` | `endpoint`: non-empty string; `timeout_ms`: positive integer in range [1, 300000]; 0 is rejected; > 300000 is rejected | `SERVICE_TASK_MISSING_ENDPOINT`, `SERVICE_TASK_MISSING_TIMEOUT`, `SERVICE_TASK_INVALID_TIMEOUT` |
| `EXCLUSIVE_GATEWAY` | none | — | — |
| `PARALLEL_GATEWAY` | none | — | — |
| `TIMER` | `duration_iso8601` | valid ISO 8601 duration string; absence or invalid format rejected HTTP 422; `P0D` (zero duration) is explicitly permitted | `TIMER_MISSING_DURATION`, `TIMER_INVALID_DURATION` |

**Attribute JSON parsing note:** For each node where `attributes` is non-null,
`validateNodeAttributes` must parse the JSON object string to extract the required
attribute keys. If `attributes` is null for a node type that has required attributes,
that is treated as if all required attributes are absent (generates the appropriate
`MISSING_*` violation codes).

**Extra attributes:** Undeclared attributes on a node are silently ignored for
forward-compatibility (PD-05 edge case: *"Extra undeclared attributes on a node:
ignored."*).

**Unrecognised node type:** If a `NodeType` value is encountered that is not in the
seven variants above, this is a compile-time impossibility in Zig (exhaustive switch).
At the JSON deserialisation boundary, an unknown string value must be rejected with
`GraphStructureInvalid` before `validateNodeAttributes` is called.

---

### ISO 8601 duration validation rules (TIMER nodes)

| Rule | Description |
|---|---|
| Must start with `P` | The string must begin with the literal character `P` (uppercase). Empty or null string → `TIMER_MISSING_DURATION`. |
| At least one designator required | Pattern: `P[nY][nM][nW][nD][T[nH][nM][nS]]`. At least one numeric component designator (Y, M, W, D, H, S) must appear after `P`. A bare `P` with no designators is invalid → `TIMER_INVALID_DURATION`. |
| `P0D` (zero duration) is permitted | Fires immediately; represents a zero-delay timer event. This is the only explicitly permitted zero-value case per PD-05. |
| Integer component values only | Each numeric component must be a non-negative integer. Fractional values (e.g. `PT1.5H`) are rejected → `TIMER_INVALID_DURATION`. |
| Time section requires `T` prefix | Hour (`H`), Minute (`M`), and Second (`S`) designators must appear after the `T` separator. Placing them before `T` is invalid → `TIMER_INVALID_DURATION`. |
| Absence of `duration_iso8601` | If the `duration_iso8601` key is missing from the `attributes` JSON object, or if `attributes` itself is null → `TIMER_MISSING_DURATION`. |
| Invalid format | Any string that begins with `P` but does not conform to the pattern above → `TIMER_INVALID_DURATION`. |

**Implementation guidance for BACKEND-DEV:** A simple validator that checks the `P`
prefix, uses a scan-forward parser for `[nY][nM][nW][nD]`, optionally `T[nH][nM][nS]`,
and rejects anything else is sufficient. No external library is required.

---

### Integration into `Store.create()`

After `graph.validateGraph()` passes (step [B] in the existing data flow diagram),
and before the `INSERT` (step [D]), call `graph.validateNodeAttributes()`:

```
         ├─ [B] graph.validateGraph(allocator, params.graph)
         │      if violations → GraphValidationFailed → HTTP 422
         │
         ├─ [B2] graph.validateNodeAttributes(allocator, params.graph)
         │      ┌─ HUMAN_TASK: role present and non-empty ─────────────┐
         │      │  SERVICE_TASK: endpoint + timeout_ms valid            │
         │      │  TIMER: duration_iso8601 valid ISO 8601               │
         │      │  all violations collected; never early exit           │
         │      └─────────────────────────────────────────────────────┘
         │      if violations → store violations → GraphValidationFailed → HTTP 422
         │
         ├─ [C] pool.acquire()
```

Both `validateGraph()` and `validateNodeAttributes()` failures map to the same
`GraphValidationFailed` error and the same HTTP 422 response shape. The violations from
the failing call are stored via the existing `lastViolations()` mechanism. There is **no
new `DefinitionError` variant** — attribute validation failures reuse `GraphValidationFailed`.

**Note:** If `validateGraph()` fails, `validateNodeAttributes()` is NOT called — the
implementation returns immediately after collecting graph-structural violations. Attribute
validation only runs on a structurally valid graph.

---

### PD-05 acceptance criteria traceability

| PD-05 acceptance criterion | Design element satisfying it |
|---|---|
| GIVEN `type = HUMAN_TASK`, WHEN definition saved, THEN `role` attribute must be non-empty string; absence rejected HTTP 422 | `validateNodeAttributes()` → `HUMAN_TASK_MISSING_ROLE` violation → `GraphValidationFailed` → HTTP 422 |
| GIVEN `type = SERVICE_TASK`, WHEN definition saved, THEN `endpoint` (non-empty string URL) and `timeout_ms` (positive int ≤ 300,000) required; violations rejected HTTP 422 | `validateNodeAttributes()` → `SERVICE_TASK_MISSING_ENDPOINT`, `SERVICE_TASK_MISSING_TIMEOUT`, `SERVICE_TASK_INVALID_TIMEOUT` violations → HTTP 422 |
| GIVEN `type = TIMER`, WHEN definition saved, THEN `duration_iso8601` must be valid ISO 8601 duration; invalid rejected HTTP 422 | `validateNodeAttributes()` → `TIMER_MISSING_DURATION` / `TIMER_INVALID_DURATION` violation → HTTP 422 |
| GIVEN `type = EXCLUSIVE_GATEWAY` or `PARALLEL_GATEWAY`, WHEN definition saved, THEN no mandatory additional attributes required | `validateNodeAttributes()` performs no checks for these types; always passes |
| GIVEN `type = START` or `type = END`, WHEN definition saved, THEN no additional attributes required | `validateNodeAttributes()` performs no checks for these types; always passes |
| Any node with an unrecognised `type` value MUST be rejected HTTP 422 listing the invalid type | JSON deserialisation boundary rejects unknown strings before validation; `GraphStructureInvalid` |
| Edge case: `timeout_ms = 0` rejected | `SERVICE_TASK_INVALID_TIMEOUT` (must be positive: range [1, 300000]) |
| Edge case: `duration_iso8601 = "P0D"` (zero duration) permitted | ISO 8601 validation rule: `P0D` explicitly permitted |
| Edge case: extra undeclared attributes on a node are ignored | `validateNodeAttributes()` only checks for required keys; extra keys silently ignored |

---

## PD-06 — Edge conditions

**Covers:** PD-06
**Extends:** PD-01/PD-02/PD-03/PD-04/PD-05 sections above; read those first.

---

### Updated `GraphEdge` struct (with `is_default`)

The `GraphEdge` struct in the shared-types block has been updated. The source code in
`src/definition/graph.zig` must match:

```zig
pub const GraphEdge = struct {
    /// Non-empty, unique within the definition.
    id:         []const u8,
    /// Refers to an existing GraphNode.id.
    source:     []const u8,
    /// Refers to an existing GraphNode.id.
    target:     []const u8,
    /// CEL condition expression for EXCLUSIVE_GATEWAY routing (PD-06).
    /// MUST be present (non-null, non-empty) on every non-default outgoing
    /// edge from an EXCLUSIVE_GATEWAY. MUST be null on all other edges.
    condition:  ?[]const u8,
    /// When true, this edge is the default (fallback) route from an
    /// EXCLUSIVE_GATEWAY. MUST NOT coexist with a non-null condition.
    /// At most one outgoing edge per EXCLUSIVE_GATEWAY may be default.
    is_default: bool,
};
```

**Memory ownership:** `condition` is a slice pointing into the caller-owned input buffer
(same as `id`, `source`, `target`). `GraphEdge` does not own or allocate this memory.
`is_default` is a value type (no allocation needed).

---

### CEL syntax validation — `isValidCelSyntax`

Because `vendor/cel/cel.zig` is a stub (one comment line, no implementation), a minimal
pure-Zig validator is specified here. This satisfies PD-06's requirement that syntactically
invalid expressions are rejected at definition creation time, without depending on the
incomplete CEL library.

#### Interface

```zig
/// Validate that `expr` is syntactically valid CEL (minimal subset check).
/// Returns true if the expression passes all structural checks; false otherwise.
///
/// Pure function: no allocations, no I/O, no logging, no clock reads.
/// Lives in graph.zig alongside validateGraph() and validateNodeAttributes().
fn isValidCelSyntax(expr: []const u8) bool
```

#### Minimal grammar subset validated

The validator checks the following rules in a single linear pass over the expression
bytes. It does NOT attempt to fully parse the CEL grammar — the goal is to catch
obviously malformed expressions with zero allocations.

| Rule | Description |
|---|---|
| Non-empty | `expr.len > 0`. An empty or all-whitespace string fails. |
| At least one non-whitespace token | After stripping ASCII whitespace, at least one non-whitespace byte must remain. |
| Balanced parentheses `()` | Every `(` must have a matching `)`. Unmatched open or close parenthesis fails. |
| Balanced square brackets `[]` | Every `[` must have a matching `]`. Unmatched open or close bracket fails. |
| No unmatched string delimiters | Single-quote (`'`) and double-quote (`"`) strings must be properly terminated. A `'` or `"` that is opened but never closed (accounting for `\\` escapes) fails. |
| No stray null bytes | A null byte (`\x00`) anywhere in the expression fails. |

**What this validator intentionally does NOT check:**
- Operator precedence or arity
- Valid CEL keyword usage
- Variable reference resolution
- Type compatibility
- Any grammar beyond the structural rules above

**Algorithm sketch for BACKEND-DEV:**

```
state = NORMAL
depth_paren = 0
depth_bracket = 0
has_non_whitespace = false
i = 0

while i < expr.len:
    c = expr[i]
    if state == NORMAL:
        if c == '\x00': return false
        if c == '(':  depth_paren  += 1
        if c == ')':
            depth_paren -= 1
            if depth_paren < 0: return false
        if c == '[':  depth_bracket += 1
        if c == ']':
            depth_bracket -= 1
            if depth_bracket < 0: return false
        if c == '"': state = IN_DOUBLE_QUOTE
        if c == '\'': state = IN_SINGLE_QUOTE
        if c not in { ' ', '\t', '\n', '\r' }: has_non_whitespace = true
    elif state == IN_DOUBLE_QUOTE:
        if c == '\x00': return false
        if c == '\\': i += 1  // skip escaped char
        elif c == '"': state = NORMAL
    elif state == IN_SINGLE_QUOTE:
        if c == '\x00': return false
        if c == '\\': i += 1  // skip escaped char
        elif c == '\'': state = NORMAL
    i += 1

return state == NORMAL
    and depth_paren == 0
    and depth_bracket == 0
    and has_non_whitespace
```

This is a pure `O(n)` scan with no heap allocations, suitable for the pure `graph.zig`
validation context.

---

### New public function: `validateEdgeConditions`

```zig
/// Validate PD-06 edge condition rules for all edges in the graph.
///
/// Called after validateNodeAttributes() passes in the Store.create() path.
/// Same memory contract as validateGraph() and validateNodeAttributes():
/// the caller supplies an allocator used only for the output violations slice
/// and message strings.
///
/// ALL edges are checked; ALL violations are collected before returning.
/// The function never exits early after the first failure.
///
/// Memory contract:
///   - The returned ValidationResult.violations slice is allocated with allocator.
///   - Every Violation.message string is also allocated with allocator.
///   - On success (valid == true, violations empty), caller frees:
///       allocator.free(result.violations);   // empty slice, still valid to free
///   - On validation failure (valid == false), caller frees:
///       for (result.violations) |v| allocator.free(v.message);
///       allocator.free(result.violations);
///   - On GraphError.OutOfMemory nothing has been allocated.
///
/// Pure function: no I/O, no DB calls, no logging.
/// Lives in graph.zig alongside validateGraph() and validateNodeAttributes().
pub fn validateEdgeConditions(
    allocator: std.mem.Allocator,
    graph:     DefinitionGraph,
) GraphError!ValidationResult;
```

---

### Edge condition validation rules (CHK-EC-01 … CHK-EC-06)

All six checks are exhaustive — no early exit. All violations are collected before
returning. The checks are applied to every edge in the graph; for checks that require
per-gateway aggregation (CHK-EC-05), a stack-allocated bitset or fixed-size array
bounded by `MAX_EDGES` is used (no heap allocation until the violation message is
formatted).

| Check ID  | Rule                                                                                                     | Violation code                 | Message format                                                                                      |
|-----------|----------------------------------------------------------------------------------------------------------|--------------------------------|------------------------------------------------------------------------------------------------------|
| CHK-EC-01 | Edge from a **non-EXCLUSIVE_GATEWAY** source MUST NOT have `condition != null`                           | `EDGE_CONDITION_NOT_ALLOWED`   | `"Edge '{s}' has a condition but its source '{s}' is not an EXCLUSIVE_GATEWAY"`                     |
| CHK-EC-02 | Edge from a **non-EXCLUSIVE_GATEWAY** source MUST NOT have `is_default = true`                          | `EDGE_DEFAULT_NOT_ALLOWED`     | `"Edge '{s}' has is_default=true but its source '{s}' is not an EXCLUSIVE_GATEWAY"`                 |
| CHK-EC-03 | Each EXCLUSIVE_GATEWAY **non-default** outgoing edge MUST have a non-null, non-empty `condition`        | `EDGE_MISSING_CONDITION`       | `"Edge '{s}' leaves EXCLUSIVE_GATEWAY '{s}' without a condition (and is not the default edge)"`     |
| CHK-EC-04 | An edge with `is_default = true` MUST NOT also have a non-null/non-empty `condition`                    | `EDGE_DEFAULT_HAS_CONDITION`   | `"Edge '{s}' is the default edge but also has a condition expression"`                               |
| CHK-EC-05 | At most **one** outgoing edge per EXCLUSIVE_GATEWAY may have `is_default = true`                        | `EDGE_MULTIPLE_DEFAULTS`       | `"EXCLUSIVE_GATEWAY '{s}' has more than one default outgoing edge"`                                 |
| CHK-EC-06 | If `condition` is non-null and non-empty, it MUST be syntactically valid CEL per `isValidCelSyntax()`   | `EDGE_INVALID_CEL`             | `"Edge '{s}' has an invalid CEL expression: '{s}'"` (expression truncated to 80 chars in message)   |

**CHK-EC-05 implementation note:** Because an EXCLUSIVE_GATEWAY may have many outgoing
edges, CHK-EC-05 requires aggregating the count of `is_default = true` edges per gateway
node ID. Use a stack-allocated fixed-size array (capped at `MAX_EDGES`) to track
per-gateway default counts during the edge scan — no heap allocation until the violation
message is formatted.

**CHK-EC-06 truncation note:** When formatting the `EDGE_INVALID_CEL` message, truncate
`condition` to 80 characters if longer, appending `"…"`. This prevents arbitrarily long
user-supplied expressions from inflating the violation message.

**Check ordering per edge:** For each edge, apply CHK-EC-01 and CHK-EC-02 first (source
type checks). If the source is not EXCLUSIVE_GATEWAY and both fail, no further checks are
needed for that edge. If the source IS EXCLUSIVE_GATEWAY, apply CHK-EC-03, CHK-EC-04,
CHK-EC-06 (per-edge). CHK-EC-05 is applied after all edges have been scanned (per-gateway
aggregation step).

---

### Integration into `Store.create()`

The updated `Store.create()` validation sequence is:

```
         ├─ [B]  graph.validateGraph(allocator, params.graph)
         │       if violations → GraphValidationFailed → HTTP 422
         │
         ├─ [B2] graph.validateNodeAttributes(allocator, params.graph)
         │       if violations → GraphValidationFailed → HTTP 422
         │
         ├─ [B3] graph.validateEdgeConditions(allocator, params.graph)
         │       ┌─ CHK-EC-01 … CHK-EC-06 run in full ─────────────────┐
         │       │  all violations collected; never early exit          │
         │       └──────────────────────────────────────────────────────┘
         │       if violations → store violations → GraphValidationFailed → HTTP 422
         │
         ├─ [C]  pool.acquire()
         ├─ [D]  INSERT INTO process_definitions …
```

**Validation sequence rule:** `validateEdgeConditions()` is only called if
`validateNodeAttributes()` returned `valid == true`. If node-attribute validation fails,
edge-condition validation is skipped (same pattern as graph-structure → node-attribute
ordering). All three validation steps share the same `GraphValidationFailed` error path
and `lastViolations()` retrieval mechanism.

**No new `DefinitionError` variant** is introduced — all edge-condition validation
failures reuse `GraphValidationFailed`.

---

### TypeScript API type update

`web/src/types/api.ts` — the `GraphEdge` interface must be updated to include `is_default`:

```typescript
export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  condition?: string | null;
  is_default?: boolean;
}
```

**Notes for FRONTEND-DEV:**
- `condition` is optional/nullable (absent on non-EXCLUSIVE_GATEWAY edges).
- `is_default` is optional; absent/`false` on edges that are not the fallback route.
- The UI form for definition creation must allow the user to mark exactly one outgoing
  edge per EXCLUSIVE_GATEWAY as the default (checkbox/toggle), and to enter a CEL
  condition string on all other outgoing edges from that gateway.

---

### Extended error taxonomy (PD-06)

The following violation codes extend the check table from PD-02. All produce the same
`GraphValidationFailed` top-level error and HTTP 422 response.

| Violation code               | Trigger (check)   | HTTP status | PD ref |
|------------------------------|-------------------|-------------|--------|
| `EDGE_CONDITION_NOT_ALLOWED` | CHK-EC-01         | 422         | PD-06  |
| `EDGE_DEFAULT_NOT_ALLOWED`   | CHK-EC-02         | 422         | PD-06  |
| `EDGE_MISSING_CONDITION`     | CHK-EC-03         | 422         | PD-06  |
| `EDGE_DEFAULT_HAS_CONDITION` | CHK-EC-04         | 422         | PD-06  |
| `EDGE_MULTIPLE_DEFAULTS`     | CHK-EC-05         | 422         | PD-06  |
| `EDGE_INVALID_CEL`           | CHK-EC-06         | 422         | PD-06  |

---

### PD-06 acceptance criteria traceability

| PD-06 acceptance criterion                                                                                                     | Design element satisfying it                                                                |
|--------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| Edge from EXCLUSIVE_GATEWAY with `condition` field: validated as syntactically valid CEL                                       | CHK-EC-06 → `isValidCelSyntax()` → `EDGE_INVALID_CEL` violation                            |
| Invalid CEL expression rejected HTTP 422 identifying the edge and parse error                                                  | CHK-EC-06 → `EDGE_INVALID_CEL` message names edge ID and truncated expression → `GraphValidationFailed` → HTTP 422 |
| `is_default = true` edge MUST NOT carry a condition expression                                                                 | CHK-EC-04 → `EDGE_DEFAULT_HAS_CONDITION`                                                    |
| More than one default edge per EXCLUSIVE_GATEWAY rejected HTTP 422                                                             | CHK-EC-05 → `EDGE_MULTIPLE_DEFAULTS`                                                        |
| Non-EXCLUSIVE_GATEWAY edge MUST NOT carry condition expression                                                                 | CHK-EC-01 → `EDGE_CONDITION_NOT_ALLOWED`                                                    |
| Non-EXCLUSIVE_GATEWAY edge MUST NOT have `is_default = true`                                                                   | CHK-EC-02 → `EDGE_DEFAULT_NOT_ALLOWED`                                                      |
| Empty string condition treated as missing; rejected HTTP 422                                                                   | CHK-EC-03 requires non-null AND non-empty; empty string treated as absent                   |
| CEL syntax validated at definition creation time; semantic validity deferred to runtime                                        | `isValidCelSyntax()` checks structural syntax only; no variable resolution at this stage    |
| All violations listed, not just the first                                                                                      | `validateEdgeConditions()` never exits early; all six checks are exhaustive                 |

---

## PD-07 — Definition retrieval

**Covers:** PD-07
**Extends:** PD-01/PD-02/PD-03/PD-04/PD-05/PD-06 sections above; read those first.

---

### Module purpose (PD-07 extension)

This section extends the definition module with read-side HTTP endpoints and the
`getActiveByName` store function. The three new endpoints expose the existing
`getById`, `list`, and a new `getActiveByName` store functions over HTTP. The
`list` endpoint adds a `?stage=` filter, requiring a schema extension
(`migrations/014_definition_stage.sql`). Cursor encoding is aligned with the
API-06 opaque base64 contract. All three endpoints require authentication (API-08).

---

### New public function: `Store.getActiveByName`

`getActiveByName` is a new function added to `store.zig`. It retrieves the single
definition whose `status = 'ACTIVE'` and `name` matches the provided string.
Because the `uq_active_definition` partial unique index guarantees at most one ACTIVE
row per name, this query always returns exactly zero or one row.

```zig
/// Retrieve the currently ACTIVE version of a definition by name.
/// Returns DefinitionError.DefinitionNotFound if no ACTIVE version exists for the given name.
///
/// Security: name binds as $1 — no SQL string interpolation.
pub fn getActiveByName(
    self:      *Store,
    allocator: std.mem.Allocator,
    name:      []const u8,
) DefinitionError!Definition;
```

**SQL outline:**

```sql
SELECT id, name, version, description, status, graph, created_by,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
       (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint
FROM   process_definitions
WHERE  name   = $1        -- $1 = name (bound parameter)
  AND  status = 'ACTIVE';
```

- 0 rows → `DefinitionError.DefinitionNotFound`
- 1 row → return `Definition`
- The `uq_active_definition` partial unique index makes > 1 row structurally impossible;
  if somehow more than one row appears the first row is returned (defensive behaviour).

---

### Updated `ListOpts` struct (PD-07 `?stage=` filter)

The existing `ListOpts` struct gains a `stage` field to support the `?stage=`
query-parameter filter required by PD-07.

```zig
pub const ListOpts = struct {
    /// Filter by exact name; null = all names.
    name:          ?[]const u8,
    /// Filter by status; null = all statuses.
    status:        ?DefinitionStatus,
    /// Filter by process stage label; null = all stages.   -- NEW (PD-07)
    stage:         ?[]const u8,
    /// Cursor: return rows with created_at (UTC µs) strictly after this value.
    after_created: ?i64,
    /// Maximum rows to return; 0 → default 50; max 200.
    limit:         u8,
};
```

**`Store.list()` SQL extension for `stage`:** When `opts.stage` is non-null, add the
clause `AND stage = $N` (where `$N` is the next available placeholder index). The value
binds as a text parameter — no SQL string interpolation. The clause is appended using the
same dynamic SQL-builder pattern already used for `name`, `status`, and `after_created`.

---

### Schema extension: migration `014_definition_stage.sql`

The `process_definitions` table has no `stage` column. PD-07 requires a `?stage=` filter,
so a new migration adds the column. The column is nullable so that existing rows are
unaffected (no back-fill required).

```sql
-- 014_definition_stage.sql
-- PD-07: add nullable stage column to process_definitions for ?stage= filter support.

ALTER TABLE process_definitions
    ADD COLUMN IF NOT EXISTS stage TEXT;

CREATE INDEX IF NOT EXISTS idx_def_stage
    ON process_definitions(stage)
    WHERE stage IS NOT NULL;
```

**Design rationale:**
- `TEXT` (nullable): existing rows keep `stage = NULL`; no data migration required.
- Partial index `WHERE stage IS NOT NULL` avoids indexing null entries and keeps the
  index compact.
- The HTTP handler passes the raw query-parameter string as the `stage` filter value;
  no enum validation is applied (stage labels are open-ended text per PD-07).

**BACKEND-DEV must also:**
- Extend the `RETURNING` column list in `Store.create()` and `Store.getById()` SELECT
  queries to include `stage` (the column is nullable; return it as `?[]const u8` in
  `Definition`).
- Add a `stage: ?[]const u8` field to the `Definition` struct in `graph.zig`.
- Add `stage` to the `CreateParams` struct (optional; stored as NULL when omitted).

---

### HTTP handler signatures: `src/api/routes/definitions.zig`

The `vendor/http/http.zig` module is currently a stub. Handler signatures below follow
the de-facto convention for Zig HTTP frameworks (request/response context struct pointers)
that BACKEND-DEV should adopt when wiring the real HTTP layer. Each handler maps directly
to a `Store` method.

```zig
//! src/api/routes/definitions.zig
//! HTTP route handlers for PD-07 definition retrieval endpoints.
//!
//! All three handlers require a valid authenticated session (API-08).
//! Auth is enforced by upstream middleware — handlers may assume ctx.actor is set.
//!
//! Route registration (BACKEND-DEV to wire in main.zig or router.zig):
//!   GET /api/v1/definitions/:id             → handleGetById
//!   GET /api/v1/definitions                 → handleList
//!   GET /api/v1/definitions/active/:name    → handleGetActiveByName

/// Handle GET /api/v1/definitions/:id
///
/// Path parameter: `id` — UUID string; parsed from ctx.req.param("id").
/// Success:  HTTP 200 + JSON body of the full Definition.
/// Errors:   DefinitionNotFound → 404; PoolExhausted → 503; TransactionFailed → 500.
pub fn handleGetById(
    store: *Store,
    ctx:   *HttpContext,
) anyerror!void;

/// Handle GET /api/v1/definitions
///
/// Query parameters (all optional):
///   ?name=<string>          exact name filter
///   ?status=<string>        one of DRAFT, ACTIVE, DEPRECATED, ARCHIVED
///   ?stage=<string>         free-text stage label filter
///   ?cursor=<base64>        opaque pagination cursor (base64-encoded created_at µs)
///   ?page_size=<integer>    1–200 inclusive (default 50 when absent or 0)
///
/// Validation performed by the handler before calling Store.list():
///   - page_size ≤ 0 or > 200 → HTTP 422, body: {"error":"page_size must be between 1 and 200"}
///   - cursor present but not valid base64 or not parseable as an integer → HTTP 422,
///     body: {"error":"invalid cursor"}
///   - status= present but not one of DRAFT/ACTIVE/DEPRECATED/ARCHIVED → HTTP 422,
///     body: {"error":"invalid status value"}
///
/// Success: HTTP 200 + JSON body: {"items": [...], "cursor": "<base64>" | null}
///   cursor in response is null when items.len < effective page_size.
///   cursor is base64(decimal_string(last_item.created_at)) when items.len == effective page_size.
pub fn handleList(
    store: *Store,
    ctx:   *HttpContext,
) anyerror!void;

/// Handle GET /api/v1/definitions/active/:name
///
/// Path parameter: `name` — URL-decoded definition name.
/// Success:  HTTP 200 + JSON body of the full Definition (status=ACTIVE).
/// Errors:   DefinitionNotFound → 404; PoolExhausted → 503; TransactionFailed → 500.
pub fn handleGetActiveByName(
    store: *Store,
    ctx:   *HttpContext,
) anyerror!void;
```

**`HttpContext` interface** (defined by the HTTP framework layer; handlers must not assume
a specific implementation until `vendor/http` is completed):

```zig
/// Minimal HTTP context interface expected by route handlers.
/// BACKEND-DEV: adapt field/method names to match the real vendor/http implementation.
pub const HttpContext = struct {
    req:  *Request,   // parsed HTTP request (path params, query params, body)
    res:  *Response,  // response writer (status, headers, body)
    actor: ActorCtx,  // set by auth middleware; contains user_id and roles
};
```

---

### Cursor encoding scheme (API-06 compliance)

The `GET /definitions` endpoint uses opaque base64-encoded cursors to implement
forward-only cursor-based pagination, satisfying API-06.

**Cursor value encoding:**

```
cursor_payload = decimal_string(last_item.created_at)  // i64 UTC microseconds as ASCII decimal
cursor_string  = base64_std_encode(cursor_payload)      // standard base64, no padding required
```

Example:
```
last_item.created_at = 1716220800000000  (UTC µs)
cursor_payload       = "1716220800000000"
cursor_string        = base64("1716220800000000") = "MTcxNjIyMDgwMDAwMDAwMA=="
```

**Cursor decoding in `handleList`:**

```
1. base64_decode(cursor_string)      → raw bytes (or HTTP 422 "invalid cursor" on failure)
2. parse integer from decoded bytes  → after_created: i64 (or HTTP 422 "invalid cursor" on failure)
3. pass after_created into ListOpts.after_created
```

**Cursor presence rules:**
- Response `cursor` field is `null` when `items.len < effective_page_size`.
- Response `cursor` field is the encoded value of `items[items.len - 1].created_at` when
  `items.len == effective_page_size`.
- On the first request (no cursor supplied), `ListOpts.after_created = null`; the query
  returns rows from the beginning of the ordered set.

**`page_size` defaults and clamping:**
- Absent or `?page_size=0` → effective page_size = 50.
- `page_size` outside [1, 200] → HTTP 422 before any Store call.
- The `Store.list()` `limit` field holds the effective page_size (already clamped
  internally, but the HTTP handler must reject out-of-range values before calling Store).

---

### API-06 response body contract

```json
{
  "items": [
    { /* Definition object */ },
    { /* ... */ }
  ],
  "cursor": "MTcxNjIyMDgwMDAwMDAwMA==" 
}
```

- `items`: array of `Definition` objects (may be empty `[]`).
- `cursor`: base64-encoded string pointing to the next page, or `null` when no further
  pages exist.

Empty result (no definitions match the filters):
```json
{ "items": [], "cursor": null }
```

---

### Error mapping table (all `DefinitionError` values, PD-07 context)

| `DefinitionError`        | HTTP status | Notes                                                                                 |
|--------------------------|-------------|--------------------------------------------------------------------------------------|
| `DefinitionNotFound`     | 404         | `GET /definitions/:id` and `GET /definitions/active/:name`                           |
| `PoolExhausted`          | 503         | Any handler; DB connection pool exhausted                                            |
| `TransactionFailed`      | 500         | Any handler; transient DB failure                                                    |
| `InvalidStatus` (HTTP layer) | 422     | `?status=` query param with unrecognised value — validated by handler before Store call |

**Note on `InvalidStatus`:** This is not a `DefinitionError` variant; it is a
handler-level validation failure applied before `Store.list()` is invoked. The handler
parses the raw `?status=` string and rejects any value that is not one of the four known
`DefinitionStatus` enum variants (`DRAFT`, `ACTIVE`, `DEPRECATED`, `ARCHIVED`) with
HTTP 422 before touching the Store. No new error set entry is required.

**Handler-level validation failures and their HTTP responses:**

| Condition                                              | HTTP status | Response body                                                 |
|--------------------------------------------------------|-------------|---------------------------------------------------------------|
| `?status=` value not in {DRAFT, ACTIVE, DEPRECATED, ARCHIVED} | 422 | `{"error":"invalid status value"}`                   |
| `?cursor=` not valid base64 or not a parseable integer | 422         | `{"error":"invalid cursor"}`                                  |
| `?page_size=` ≤ 0 or > 200                            | 422         | `{"error":"page_size must be between 1 and 200"}`            |

---

### `?status=` validation rule

The HTTP handler for `GET /definitions` MUST validate the `?status=` query parameter
before passing it to `Store.list()`. The validation logic:

```zig
// In handleList(), before building ListOpts:
const status_filter: ?DefinitionStatus = blk: {
    const raw = ctx.req.query("status") orelse break :blk null;
    if (std.mem.eql(u8, raw, "DRAFT"))      break :blk .DRAFT;
    if (std.mem.eql(u8, raw, "ACTIVE"))     break :blk .ACTIVE;
    if (std.mem.eql(u8, raw, "DEPRECATED")) break :blk .DEPRECATED;
    if (std.mem.eql(u8, raw, "ARCHIVED"))   break :blk .ARCHIVED;
    // Unknown value — reject before any Store interaction.
    try ctx.res.writeJson(422, .{ .@"error" = "invalid status value" });
    return;
};
```

This ensures the `Store.list()` function always receives a valid `?DefinitionStatus`
(or null) and never needs to handle an unknown status string from user input.

---

### Data flow diagram (PD-07 read paths)

```
GET /api/v1/definitions/:id
         │
         ▼
  handleGetById(store, ctx)
         │  1. Parse UUID from path param (:id)
         │  2. Auth/RBAC middleware already verified (API-08)
         │
         ▼
  store.getById(allocator, id)
         │
         ├─ PoolExhausted         → HTTP 503
         ├─ DefinitionNotFound    → HTTP 404
         ├─ TransactionFailed     → HTTP 500
         └─ Definition            → HTTP 200, JSON body


GET /api/v1/definitions?name=...&status=...&stage=...&cursor=...&page_size=...
         │
         ▼
  handleList(store, ctx)
         │  1. Parse & validate ?status= (422 if unknown)
         │  2. Decode ?cursor= base64 → i64 (422 if invalid)
         │  3. Validate ?page_size= in [1,200] (422 if out of range)
         │  4. Build ListOpts{name, status, stage, after_created, limit}
         │
         ▼
  store.list(allocator, opts)
         │
         ├─ PoolExhausted         → HTTP 503
         ├─ TransactionFailed     → HTTP 500
         └─ []Definition (may be empty)
                   │
                   ▼
         Encode cursor if len == page_size
         Respond HTTP 200: {"items":[...], "cursor":<base64>|null}


GET /api/v1/definitions/active/:name
         │
         ▼
  handleGetActiveByName(store, ctx)
         │  1. URL-decode :name path param
         │  2. Auth/RBAC middleware already verified (API-08)
         │
         ▼
  store.getActiveByName(allocator, name)
         │
         ├─ PoolExhausted         → HTTP 503
         ├─ DefinitionNotFound    → HTTP 404
         ├─ TransactionFailed     → HTTP 500
         └─ Definition            → HTTP 200, JSON body
```

---

### Dependencies (PD-07 additions)

| Dependency                          | Direction                                               | Notes                                         |
|-------------------------------------|---------------------------------------------------------|-----------------------------------------------|
| `src/definition/store.zig`          | `definitions.zig` → `Store.getById`, `Store.list`, `Store.getActiveByName` | All read-only store methods |
| `migrations/014_definition_stage.sql` | Schema              | Adds `stage TEXT` column to `process_definitions` |
| `vendor/http` (stub)                | `definitions.zig` → `HttpContext`, `Request`, `Response` | BACKEND-DEV implements when stub is replaced  |
| `src/api/middleware/auth.zig`       | Enforces API-08 auth requirement                        | All three handlers require authenticated actor |
| `web/src/api/definitions.ts`        | Frontend client                                         | Already calls the three endpoints; `list()` needs `stage` param added |

**Must NOT depend on:**
- `src/engine/transition.zig`
- `src/event_store/`
- `src/scheduler/`

---

### Frontend type update (PD-07)

`web/src/api/definitions.ts` — the `list()` call should be extended to accept a `stage`
query parameter (FRONTEND-DEV to implement):

```typescript
list: (params?: {
  status?: DefinitionStatus;
  name?: string;
  stage?: string;          // NEW — PD-07
  cursor?: string;
  page_size?: number;
}) =>
  client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions', params as Record<string, unknown>),
```

`web/src/types/api.ts` — `ProcessDefinition` interface should gain an optional `stage` field:

```typescript
export interface ProcessDefinition {
  // ... existing fields ...
  stage?: string | null;   // NEW — PD-07
}
```

---

### PD-07 acceptance criteria traceability

| AC | Design element |
|----|----------------|
| `GET /definitions/{id}` → 200 + full definition including graph, status, metadata | `Store.getById` + `handleGetById`; returns `Definition` struct serialised to JSON |
| `GET /definitions/{id}` unknown UUID → 404 | `DefinitionNotFound` → HTTP 404 in `handleGetById` error mapping |
| `GET /definitions` paginated per API-06 (default page size, up to max) | Cursor encoding in `handleList`; `ListOpts.limit` controls page size; defaults to 50, max 200 |
| `?name=`, `?status=`, `?stage=` filters; each optional and combinable | `ListOpts.name`, `ListOpts.status`, `ListOpts.stage`; handler parses all three; combinable via AND clauses in dynamic SQL |
| `?status=` unrecognised value → 422 | Handler-level validation before Store call; rejects unknown strings with HTTP 422 `{"error":"invalid status value"}` |
| Listing when no definitions exist → 200 + empty array | `Store.list` returns `[]Definition{}`; handler responds `{"items":[],"cursor":null}` |
| `GET /definitions/active/{name}` ACTIVE exists → 200 | `Store.getActiveByName` + `handleGetActiveByName`; `uq_active_definition` guarantees at most one ACTIVE per name |
| `GET /definitions/active/{name}` no ACTIVE version → 404 | `DefinitionNotFound` → HTTP 404 in `handleGetActiveByName` error mapping |
| Pagination `page_size` validated per API-06 | Handler rejects `page_size` ≤ 0 or > 200 with HTTP 422 `{"error":"page_size must be between 1 and 200"}` |
| Cursor decode failure → 422 `"invalid cursor"` | Handler base64-decodes and integer-parses cursor; on failure responds HTTP 422 before Store call |

---

### Open questions

None — PD-07 is fully specified. The following are noted for downstream agents:

- **BACKEND-DEV:** Must add `stage: ?[]const u8` to the `Definition` struct and
  `CreateParams` struct, and must update `Store.create()`/`Store.getById()` SELECT
  column lists to include the new `stage` column. Also must create
  `migrations/014_definition_stage.sql` and wire all three HTTP handlers in
  `main.zig`/router.
- **FRONTEND-DEV:** Must extend `definitionsApi.list()` with `stage?` param and add
  `stage?` to `ProcessDefinition` interface.
- **`vendor/http` stub:** Handler signatures above assume a request/response context
  interface. BACKEND-DEV must adapt to the actual vendor/http API once the stub is
  replaced.

---

## PD-08 — Definition snapshot

**Covers:** PD-08
**Extends:** PD-01/PD-02/PD-03/PD-04/PD-05/PD-06/PD-07 sections above; read those first.

---

### Module file: `src/definition/snapshot.zig`

PD-08 is a Stage 2 requirement and belongs in the definition module. The snapshot write
path lives in a new file `src/definition/snapshot.zig` rather than inside `src/engine/`.

**Rationale for location:**

- **Stage 2 boundary:** `snapshot.zig` is owned by the definition module and is fully
  testable in isolation before Stage 3 begins. No engine code is required to validate
  the create/retrieve paths.
- **Stage 3 integration point:** The engine calls `SnapshotStore.create()` at instance-
  start time (EE-01). Placing the snapshot in the definition module creates a one-way
  dependency: `engine` → `definition/snapshot.zig`. The definition module does NOT
  import the engine. This keeps `transition.zig` pure and prevents circular dependencies.
- **Schema already present:** `instance_definition_snapshots` is already created by
  `migrations/004_definitions.sql`; no new migration is required for PD-08.

---

### `SnapshotError` error set

```zig
pub const SnapshotError = error{
    /// The referenced definition_id does not exist in process_definitions.
    /// HTTP 404.
    DefinitionNotFound,
    /// A snapshot for this instance_id already exists — violation of PD-08:
    /// snapshots are immutable after creation; a duplicate insert is rejected.
    /// HTTP 409.
    SnapshotAlreadyExists,
    /// db.Pool.acquire() returned ExhaustedPool.
    /// HTTP 503.
    PoolExhausted,
    /// DB transaction failed to commit (transient).
    /// HTTP 500.
    TransactionFailed,
};
```

**HTTP status mappings:**

| Error | HTTP status | Notes |
|---|---|---|
| `DefinitionNotFound` | 404 | `definition_id` not in `process_definitions` |
| `SnapshotAlreadyExists` | 409 | Duplicate `instance_id` (idempotency enforcement) |
| `PoolExhausted` | 503 | `db.Pool.acquire()` exhausted |
| `TransactionFailed` | 500 | DB commit error |

---

### `Snapshot` struct

```zig
pub const Snapshot = struct {
    /// Primary key of the snapshot row; one-to-one with a process instance.
    /// Maps to: instance_definition_snapshots.instance_id (UUID PRIMARY KEY)
    instance_id:     graph_mod.Uuid,
    /// FK to process_definitions.id — the definition version snapshotted.
    /// Maps to: instance_definition_snapshots.definition_id (UUID NOT NULL REFERENCES process_definitions(id))
    definition_id:   graph_mod.Uuid,
    /// Denormalised definition name at time of snapshot; preserved for logs/reports.
    /// Maps to: instance_definition_snapshots.definition_name (TEXT NOT NULL)
    definition_name: []const u8,
    /// Denormalised version string at time of snapshot.
    /// Maps to: instance_definition_snapshots.definition_ver (TEXT NOT NULL)
    definition_ver:  []const u8,
    /// Full immutable DefinitionGraph (nodes, edges, attributes, is_default flags).
    /// Populated from the `graph` JSONB column of process_definitions at snapshot time.
    /// Maps to: instance_definition_snapshots.graph (JSONB NOT NULL)
    graph:           graph_mod.DefinitionGraph,
    /// UTC epoch microseconds derived from TIMESTAMPTZ snapshotted_at column.
    /// Maps to: instance_definition_snapshots.snapshotted_at (TIMESTAMPTZ)
    snapshotted_at:  i64,
};
```

**DB column mapping:**

| `Snapshot` field | `instance_definition_snapshots` column | Type / Constraint |
|---|---|---|
| `instance_id` | `instance_id` | UUID PRIMARY KEY |
| `definition_id` | `definition_id` | UUID NOT NULL REFERENCES process_definitions(id) |
| `definition_name` | `definition_name` | TEXT NOT NULL |
| `definition_ver` | `definition_ver` | TEXT NOT NULL |
| `graph` | `graph` | JSONB NOT NULL |
| `snapshotted_at` | `snapshotted_at` | TIMESTAMPTZ → i64 UTC µs |

---

### `SnapshotStore` struct

```zig
const std = @import("std");
const db = @import("../db/pool.zig");
const graph_mod = @import("graph.zig");

pub const SnapshotStore = struct {
    pool: *db.Pool,

    /// Create an immutable snapshot of `definition_id` bound to `instance_id`.
    ///
    /// Reads the definition row from `process_definitions` (under FOR SHARE lock)
    /// and inserts a row into `instance_definition_snapshots` — both within a
    /// single DB transaction. This atomicity ensures the captured graph is
    /// consistent with the row referenced by the FK.
    ///
    /// Returns DefinitionNotFound if `definition_id` is not in process_definitions.
    /// Returns SnapshotAlreadyExists if a snapshot for `instance_id` already exists
    ///   (INSERT ... ON CONFLICT DO NOTHING returned 0 rows).
    ///
    /// Called by the engine at instance-start time (EE-01), BEFORE the
    /// `InstanceStarted` event is appended to the event store.
    /// If this function returns any error, the EE-01 caller MUST abort.
    ///
    /// Security: all values bound as pg parameters — no SQL string interpolation.
    pub fn create(
        self:          *SnapshotStore,
        allocator:     std.mem.Allocator,
        instance_id:   graph_mod.Uuid,
        definition_id: graph_mod.Uuid,
    ) SnapshotError!Snapshot;

    /// Retrieve the immutable snapshot for a running instance.
    ///
    /// Returns DefinitionNotFound (repurposed) if no snapshot row exists for
    /// `instance_id`. Used by the engine transition function (EE-02) to obtain
    /// the graph for evaluating state transitions.
    ///
    /// Security: `instance_id` binds as $1 — no SQL string interpolation.
    pub fn getByInstanceId(
        self:        *SnapshotStore,
        allocator:   std.mem.Allocator,
        instance_id: graph_mod.Uuid,
    ) SnapshotError!Snapshot;
};
```

---

### SQL transaction pattern for `SnapshotStore.create()`

```sql
BEGIN;

-- Step 1: Read the definition under a shared lock.
-- FOR SHARE prevents any concurrent transaction from hard-deleting or
-- exclusively locking the definition row between the read and the INSERT.
-- This guarantees the graph captured in the snapshot is consistent with
-- the FK reference written in Step 2.
SELECT id, name, version, graph
FROM   process_definitions
WHERE  id = $1            -- $1 = definition_id (UUID bound parameter)
FOR SHARE;

-- (application): 0 rows → ROLLBACK; return DefinitionNotFound (HTTP 404)
-- $2 = instance_id, $3 = name (from Step 1), $4 = version (from Step 1), $5 = graph (from Step 1)

-- Step 2: Insert the snapshot row idempotently.
-- ON CONFLICT (instance_id) DO NOTHING: if a snapshot already exists for
-- this instance_id (e.g. a retry of the EE-01 path), the INSERT is skipped.
-- If RETURNING yields 0 rows, the snapshot already existed → SnapshotAlreadyExists.
INSERT INTO instance_definition_snapshots
    (instance_id, definition_id, definition_name, definition_ver, graph)
VALUES
    ($2, $1, $3, $4, $5)
ON CONFLICT (instance_id) DO NOTHING
RETURNING
    instance_id,
    definition_id,
    definition_name,
    definition_ver,
    graph,
    (EXTRACT(EPOCH FROM snapshotted_at) * 1000000)::bigint AS snapshotted_at_us;

COMMIT;
```

**SQL pattern for `SnapshotStore.getByInstanceId()`:**

```sql
SELECT
    instance_id,
    definition_id,
    definition_name,
    definition_ver,
    graph,
    (EXTRACT(EPOCH FROM snapshotted_at) * 1000000)::bigint AS snapshotted_at_us
FROM   instance_definition_snapshots
WHERE  instance_id = $1;   -- $1 = instance_id (UUID bound parameter)
```

0 rows → `SnapshotError.DefinitionNotFound` (repurposed: no snapshot for this instance).

---

### Atomicity guarantee

**`FOR SHARE` on the definition read** acquires a row-level shared lock on the
`process_definitions` row for the duration of the transaction. This prevents:

- A concurrent `DELETE FROM process_definitions WHERE id = $1` from succeeding between
  Step 1 and Step 2. Any such DELETE must acquire an exclusive lock and will block until
  the snapshot transaction commits or rolls back.
- A concurrent exclusive lock (e.g. another writer `UPDATE ... FOR UPDATE`) from
  modifying the definition row while the graph is being captured, ensuring the snapshot
  reflects a stable graph value.

Result: the graph stored in the snapshot is always consistent with the `definition_id`
FK reference written in the same transaction.

**`ON CONFLICT (instance_id) DO NOTHING`** enforces idempotency at the DB level:

- If two concurrent EE-01 calls for the same `instance_id` race, only one INSERT wins.
  The loser's INSERT silently produces 0 rows returned; the application maps this to
  `SnapshotAlreadyExists` (HTTP 409).
- No application-level mutex or advisory lock is required.

**FK without `ON DELETE CASCADE`:** The `instance_definition_snapshots.definition_id`
column references `process_definitions(id)` but carries no `ON DELETE CASCADE`. This
means:

- Deletion of the source definition does NOT automatically remove snapshot rows.
- Snapshot rows persist with their captured `graph`, `definition_name`, and
  `definition_ver` regardless of what happens to the source definition.
- This directly satisfies the PD-08 edge case: *"Definition hard-deleted (DRAFT) after
  instances were started from it: instances retain their snapshot and continue normally."*

---

### Integration contract for EE-01 (Stage 3)

When BACKEND-DEV implements EE-01 (start instance), the following call ordering MUST be
observed without exception:

```
EE-01 start-instance sequence:
  1. SnapshotStore.create(instance_id, definition_id)
         ↳ If any error is returned → abort the entire EE-01 operation immediately.
            Propagate the error to the HTTP caller.
            Do NOT append any event to the event store.
  2. Append InstanceStarted event to event_store (only reached if step 1 succeeds)
  3. (Optional) EE-02 transition to advance the token off the START node
```

**Strict ordering rule:** `SnapshotStore.create()` MUST be called **before** the
`InstanceStarted` event is appended. If `create()` returns any error, the EE-01 handler
aborts and propagates the error. No partial state is permitted — an `InstanceStarted`
event without a corresponding snapshot row must never exist.

**Rationale:** `transition.zig` (EE-02) calls `SnapshotStore.getByInstanceId()` to
obtain the graph for every token evaluation. If the snapshot is absent, the transition
function cannot operate. Requiring the snapshot to exist before the `InstanceStarted`
event eliminates the window where an event exists without its snapshot.

---

### `bpm.zig` export

The `snapshot` module MUST be exported from `src/bpm.zig` alongside the existing
`definition` export, so that integration tests can import it from the single re-export
root:

```zig
// src/bpm.zig — addition required by BACKEND-DEV
pub const snapshot = @import("definition/snapshot.zig");
```

**Full `src/bpm.zig` after update:**

```zig
pub const pool       = @import("db/pool.zig");
pub const registry   = @import("event_store/registry.zig");
pub const store      = @import("event_store/store.zig");
pub const definition = @import("definition/store.zig");
pub const snapshot   = @import("definition/snapshot.zig");  // PD-08
```

---

### Data flow diagram (PD-08)

```
EE-01: POST /instances (Stage 3)
         │
         ▼
  engine/instance_start.zig
         │  1. Validate definition_id is ACTIVE (pre-check via Store.getById)
         │  2. Generate new instance_id (UUID v4)
         │
         ▼
  SnapshotStore.create(instance_id, definition_id)
         │
         ├─ BEGIN TRANSACTION
         │
         ├─ SELECT id, name, version, graph
         │    FROM process_definitions WHERE id = $1 FOR SHARE
         │      0 rows → ROLLBACK → DefinitionNotFound → HTTP 404 (abort EE-01)
         │
         ├─ INSERT INTO instance_definition_snapshots ...
         │    ON CONFLICT (instance_id) DO NOTHING RETURNING *
         │      0 rows → ROLLBACK → SnapshotAlreadyExists → HTTP 409 (abort EE-01)
         │
         ├─ COMMIT → return Snapshot
         │
         ▼  (only reached if create() succeeded)
  event_store.append(InstanceStarted event)
         │
         ▼
  (optional) EE-02: transition off START node
         │  reads snapshot via SnapshotStore.getByInstanceId(instance_id)
         │
         ▼
  HTTP 201 Created (instance started)


GET /instances/{id}/graph (read path, no modification allowed)
         │
         ▼
  SnapshotStore.getByInstanceId(instance_id)
         │
         ├─ SELECT ... FROM instance_definition_snapshots WHERE instance_id = $1
         │      0 rows → DefinitionNotFound → HTTP 404
         │
         └─ return Snapshot → HTTP 200
```

---

### Dependencies (PD-08 additions)

| Dependency | Direction | Notes |
|---|---|---|
| `src/db/pool.zig` | `snapshot.zig` → `db.Pool` | Connection pool; `pool` must outlive `SnapshotStore` |
| `src/definition/graph.zig` | `snapshot.zig` → `graph_mod.Uuid`, `graph_mod.DefinitionGraph` | Shared type imports only; no validation calls |
| `migrations/004_definitions.sql` | Schema | `instance_definition_snapshots` table already present; no new migration needed |
| `src/bpm.zig` | Re-exports `snapshot` module | Required for integration test imports |
| `src/engine/` (Stage 3, EE-01) | `engine` → `snapshot.zig` | One-way: engine calls SnapshotStore; snapshot does NOT import engine |

**Must NOT depend on:**

- `src/engine/transition.zig` — snapshot is called BY the engine; reverse dependency forbidden.
- `src/event_store/` — snapshot has no event log of its own.
- `src/scheduler/` — snapshot has no scheduled operations.
- Any external HTTP service.

---

### Traceability table — PD-08 acceptance criteria

| AC | Design element |
|---|---|
| Instance started → immutable copy stored atomically with instance creation | `SnapshotStore.create()` transaction with `FOR SHARE` + `ON CONFLICT DO NOTHING`; EE-01 integration contract requires `create()` to succeed before `InstanceStarted` event is appended |
| Subsequent definition updates MUST NOT modify snapshot | Snapshot row has no UPDATE path; all definition writes target `process_definitions` only; `SnapshotStore` exposes only `create()` and `getByInstanceId()` |
| Snapshot used by execution engine for transitions | `SnapshotStore.getByInstanceId()` called by engine transition function (EE-02) to obtain the immutable graph for token evaluation |
| Snapshot includes all fields: node types, attributes, edge conditions, is_default flags | `graph JSONB` captures full `DefinitionGraph` which includes all `GraphNode` (id, node_type, label, attributes) and `GraphEdge` (id, source, target, condition, is_default) fields |
| Snapshots read-only after creation; no API endpoint permits modification | No `PUT`/`PATCH`/`DELETE` route for snapshots; `SnapshotAlreadyExists` error on duplicate `instance_id` insert; `SnapshotStore` exposes no mutation method beyond `create()` |
| Definition hard-deleted after instance started: instances retain snapshot and continue | Snapshot stored in `instance_definition_snapshots`; FK on `definition_id` has no `ON DELETE CASCADE`; snapshot row persists independently of source definition lifecycle |
| Two instances from same definition have independent snapshots | Each `instance_id` is a separate `PRIMARY KEY` row in `instance_definition_snapshots`; no shared mutable state between snapshot rows |

---

## PD-09 — Definition import/export

**Covers:** PD-09
**Extends:** PD-01/PD-02/PD-03/PD-04/PD-05/PD-06/PD-07/PD-08 sections above; read those first.

---

### Module file: `src/definition/export_import.zig`

PD-09 export/import logic is implemented in a new file `src/definition/export_import.zig`.

**Rationale for location:**

- **Cohesion with definition module:** Export/import is a definition-layer concern. The
  data being serialised/deserialised (`DefinitionGraph`, `Definition`) is owned by the
  definition module, so the handler code belongs alongside `store.zig`, `graph.zig`, and
  `snapshot.zig` rather than in the API layer.
- **Clean API separation:** The API handlers in `src/api/routes/definitions.zig` call
  into `ExportImportStore` rather than directly manipulating graph types. This preserves
  the existing pattern of thin route handlers that delegate to a typed store.
- **Testability:** `ExportImportStore` can be unit-tested in isolation with a test DB
  pool, without starting the HTTP layer.
- **No circular dependency:** `export_import.zig` imports `store.zig` and `graph.zig`
  (definition module internals). The API layer imports `export_import.zig`. No reverse
  dependency is introduced.

---

### `EXPORT_SCHEMA_VERSION` constant

```zig
pub const EXPORT_SCHEMA_VERSION: []const u8 = "bpm/definition/v1";
```

**Rationale:** The version string is embedded in every exported document and checked on
import. If the export format evolves (e.g. new required fields added in a later platform
version), the version string is bumped (e.g. `"bpm/definition/v2"`). This enables
forward-compatible version detection: the import path can reject a document from an
incompatible future version with `UnknownSchemaVersion` rather than silently
misinterpreting unknown fields.

The value `"bpm/definition/v1"` is stable for the initial PD-09 implementation.

---

### `ExportDocument` struct

```zig
pub const ExportDocument = struct {
    /// Schema version identifier. Must equal EXPORT_SCHEMA_VERSION on import.
    /// JSON key: "bpm_export_schema_version"
    bpm_export_schema_version: []const u8,

    /// The definition's original UUID in the source environment (informational only).
    /// The target platform generates a new UUID on import; this field is NOT used as
    /// the primary key of the imported definition.
    /// JSON key: "id"
    id: graph_mod.Uuid,

    /// Definition name — preserved exactly on import.
    /// JSON key: "name"
    name: []const u8,

    /// Definition version string — preserved exactly on import.
    /// JSON key: "version"
    version: []const u8,

    /// Human-readable description — preserved exactly on import; may be empty string.
    /// JSON key: "description"
    description: []const u8,

    /// Full definition graph: all nodes (with attributes), all edges
    /// (with conditions and is_default flags).
    /// JSON key: "graph"
    graph: graph_mod.DefinitionGraph,

    /// ISO8601 timestamp indicating when this document was produced (UTC).
    /// Format: "2026-05-21T16:00:00Z"
    /// JSON key: "exported_at"
    exported_at: []const u8,
};
```

**Field summary:**

| # | Field | JSON key | Type | Notes |
|---|-------|----------|------|-------|
| 1 | `bpm_export_schema_version` | `"bpm_export_schema_version"` | `[]const u8` | Must equal `EXPORT_SCHEMA_VERSION` on import |
| 2 | `id` | `"id"` | `graph_mod.Uuid` | Original UUID; informational only on import |
| 3 | `name` | `"name"` | `[]const u8` | Preserved on import |
| 4 | `version` | `"version"` | `[]const u8` | Preserved on import |
| 5 | `description` | `"description"` | `[]const u8` | Preserved on import; empty string when absent |
| 6 | `graph` | `"graph"` | `graph_mod.DefinitionGraph` | Full graph with nodes, edges, conditions, is_default |
| 7 | `exported_at` | `"exported_at"` | `[]const u8` | ISO8601 UTC timestamp of export time |

---

### `ExportImportError` error set

```zig
pub const ExportImportError = error{
    /// Export path: definition_id not found in process_definitions.
    /// HTTP 404.
    DefinitionNotFound,

    /// Import path: a definition with the same name+version already exists on the
    /// target platform (SELECT COUNT(*) > 0 for the name+version pair).
    /// HTTP 409.
    NameVersionConflict,

    /// Import path: the bpm_export_schema_version field in the document is missing
    /// or does not equal EXPORT_SCHEMA_VERSION.
    /// HTTP 422.
    UnknownSchemaVersion,

    /// Import path: the graph in the document failed one or more validation checks
    /// (validateGraph(), validateNodeAttributes(), or validateEdgeConditions()
    /// including CEL re-validation).
    /// HTTP 422.
    InvalidGraph,

    /// DB pool exhausted: db.Pool.acquire() returned ExhaustedPool.
    /// HTTP 503.
    PoolExhausted,

    /// DB operation failed (transient error).
    /// HTTP 500.
    DatabaseError,
};
```

**HTTP status mapping table:**

| Error | HTTP status | Context |
|---|---|---|
| `DefinitionNotFound` | 404 | `exportDefinition()`: definition_id not in process_definitions |
| `NameVersionConflict` | 409 | `importDefinition()`: name+version collision on target |
| `UnknownSchemaVersion` | 422 | `importDefinition()`: unrecognised bpm_export_schema_version |
| `InvalidGraph` | 422 | `importDefinition()`: graph fails validation including CEL re-check |
| `PoolExhausted` | 503 | Any path: db.Pool.acquire() exhausted |
| `DatabaseError` | 500 | Any path: DB operation failed |

---

### `ExportImportStore` struct and function signatures

```zig
const std      = @import("std");
const db       = @import("../db/pool.zig");
const graph_mod = @import("graph.zig");
const store_mod = @import("store.zig");

pub const ExportImportStore = struct {
    pool: *db.Pool,

    /// Export the definition identified by `definition_id`.
    ///
    /// Reads the full definition row from `process_definitions`. Works for definitions
    /// in ANY status (DRAFT, ACTIVE, DEPRECATED, ARCHIVED) — no status filter applied.
    /// This satisfies PD-09 edge case: exporting a DRAFT definition is permitted.
    ///
    /// On success returns an ExportDocument with:
    ///   - bpm_export_schema_version = EXPORT_SCHEMA_VERSION
    ///   - id = definition_id (original UUID, informational)
    ///   - name, version, description from the process_definitions row
    ///   - graph from the process_definitions row (full DefinitionGraph)
    ///   - exported_at = current UTC timestamp in ISO8601 format
    ///
    /// Returns ExportImportError.DefinitionNotFound if no row exists for definition_id.
    ///
    /// Security: definition_id bound as $1 — no SQL string interpolation.
    pub fn exportDefinition(
        self:          *ExportImportStore,
        allocator:     std.mem.Allocator,
        definition_id: graph_mod.Uuid,
    ) ExportImportError!ExportDocument;

    /// Import a definition from an ExportDocument onto the target platform.
    ///
    /// Steps (executed in strict order):
    ///
    ///   Step 1 — Schema version check:
    ///     Validate that doc.bpm_export_schema_version == EXPORT_SCHEMA_VERSION.
    ///     If the field is missing or the value does not match, return
    ///     ExportImportError.UnknownSchemaVersion immediately (no DB interaction).
    ///
    ///   Step 2 — Name+version uniqueness check:
    ///     Execute:
    ///       SELECT COUNT(*) FROM process_definitions WHERE name = $1 AND version = $2
    ///     where $1 = doc.name and $2 = doc.version.
    ///     If count > 0, return ExportImportError.NameVersionConflict (HTTP 409).
    ///     Security: both values bound as pg parameters — no SQL string interpolation.
    ///
    ///   Step 3 — Graph re-validation:
    ///     Call validateGraph(allocator, doc.graph). If violations found, return
    ///     ExportImportError.InvalidGraph.
    ///     If validateGraph passes, call validateNodeAttributes(allocator, doc.graph).
    ///     If violations found, return ExportImportError.InvalidGraph.
    ///     If validateNodeAttributes passes, call validateEdgeConditions(allocator, doc.graph).
    ///     validateEdgeConditions calls isValidCelSyntax() on every non-default
    ///     EXCLUSIVE_GATEWAY edge condition — this is the CEL re-validation required
    ///     by PD-09 AC.
    ///     If violations found, return ExportImportError.InvalidGraph.
    ///
    ///   Step 4 — Create definition:
    ///     Call Store.create() with the following fields from the document:
    ///       name        = doc.name
    ///       version     = doc.version
    ///       description = doc.description (null if empty)
    ///       graph       = doc.graph
    ///       created_by  = caller's actor.user_id (supplied by API handler)
    ///     Store.create() always assigns status = DRAFT (PD-09 AC; PD-01 invariant).
    ///     The target platform generates a new UUID for the imported definition;
    ///     doc.id is NOT used as the primary key.
    ///     Returns the fully-populated Definition on success.
    ///
    /// Security: all values passed through Store.create() which binds all fields as
    /// pg parameters — no SQL string interpolation at any step.
    pub fn importDefinition(
        self:      *ExportImportStore,
        allocator: std.mem.Allocator,
        doc:       ExportDocument,
        created_by: graph_mod.Uuid,
    ) ExportImportError!store_mod.Definition;
};
```

---

### HTTP handler signatures (additions to `src/api/routes/definitions.zig`)

Two new handlers are added to `src/api/routes/definitions.zig`:

```
GET  /api/v1/definitions/{id}/export  → handleExport
POST /api/v1/definitions/import       → handleImport
```

```zig
//! Route additions for PD-09 (add to src/api/routes/definitions.zig):
//!
//!   GET  /api/v1/definitions/:id/export   → handleExport
//!   POST /api/v1/definitions/import       → handleImport
//!
//! Both handlers require a valid authenticated session (API-08).
//! Auth is enforced by upstream middleware — handlers may assume ctx.actor is set.

/// Handle GET /api/v1/definitions/:id/export
///
/// Path parameter: `id` — UUID string; parsed from ctx.req.param("id").
///   If the UUID is malformed (not a valid 16-byte UUID): HTTP 422,
///   body: {"error": "invalid_definition_id"}.
///
/// On success: HTTP 200 + JSON-serialised ExportDocument body.
///
/// Error mapping:
///   ExportImportError.DefinitionNotFound → HTTP 404
///   ExportImportError.PoolExhausted      → HTTP 503
///   ExportImportError.DatabaseError      → HTTP 500
pub fn handleExport(
    store: *ExportImportStore,
    ctx:   *HttpContext,
) anyerror!void;

/// Handle POST /api/v1/definitions/import
///
/// Request body: JSON-serialised ExportDocument.
///   If body cannot be parsed as a valid ExportDocument: HTTP 422,
///   body: {"error": "invalid_request_body"}.
///
/// On success: HTTP 201 + JSON-serialised Definition
///   (identical response shape to the PD-01 POST /definitions create endpoint).
///
/// Error mapping:
///   ExportImportError.UnknownSchemaVersion → HTTP 422, {"error": "unknown_schema_version"}
///   ExportImportError.NameVersionConflict  → HTTP 409, {"error": "name_version_conflict"}
///   ExportImportError.InvalidGraph         → HTTP 422, {"error": "invalid_graph", "detail": <violations>}
///   ExportImportError.PoolExhausted        → HTTP 503
///   ExportImportError.DatabaseError        → HTTP 500
pub fn handleImport(
    store: *ExportImportStore,
    ctx:   *HttpContext,
) anyerror!void;
```

**Complete HTTP status code mapping table:**

| Condition | HTTP status | Response body |
|---|---|---|
| Export success | 200 | JSON `ExportDocument` |
| Import success | 201 | JSON `Definition` (same as PD-01 create) |
| Malformed UUID in export path | 422 | `{"error": "invalid_definition_id"}` |
| Malformed request body on import | 422 | `{"error": "invalid_request_body"}` |
| `DefinitionNotFound` (export) | 404 | `{"error": "definition_not_found"}` |
| `UnknownSchemaVersion` (import) | 422 | `{"error": "unknown_schema_version"}` |
| `NameVersionConflict` (import) | 409 | `{"error": "name_version_conflict"}` |
| `InvalidGraph` (import) | 422 | `{"error": "invalid_graph", "detail": <violations>}` |
| `PoolExhausted` (any) | 503 | `{"error": "service_unavailable"}` |
| `DatabaseError` (any) | 500 | `{"error": "internal_error"}` |

---

### Import always creates with status = DRAFT

Imported definitions always land with `status = DRAFT`, regardless of the status the
definition held in the source environment. This is enforced by calling `Store.create()`
in `importDefinition()` Step 4, which hard-codes `status = DRAFT` (PD-01 invariant —
`Store.create()` accepts no `status` field in `CreateParams`).

**Rationale (PD-09 AC):** A definition exported from a production environment
(e.g. `ACTIVE` or `DEPRECATED`) must be reviewed and explicitly activated on the target
platform before it can be used to start instances. Importing directly to ACTIVE would
bypass the PD-03 single-active-per-name invariant checks and the human review step that
activation represents.

**`id` field is informational only:** The `id` UUID in the export document identifies
the definition in the source environment. On import, the target platform calls
`Store.create()` which assigns a new platform-generated UUID. The source `id` is
preserved in the `ExportDocument` structure for audit/traceability purposes but is not
written to the `process_definitions` table on the target.

---

### CEL re-validation on import

`importDefinition()` Step 3 calls `validateEdgeConditions(allocator, doc.graph)`. This
function (already implemented for PD-06) iterates every edge and calls
`isValidCelSyntax()` on each non-null, non-default condition expression (CHK-EC-06).

**Why re-validate on import?** CEL expressions are stored as opaque text strings in the
graph. A document exported from one platform version may contain expressions that are
syntactically valid on the source but use constructs not accepted by the target's minimal
CEL validator (e.g. different platform versions with different `isValidCelSyntax()`
implementations). Re-validating on import ensures that:

1. The imported definition's conditions will be parseable by the target platform at
   runtime.
2. A document that was intentionally or accidentally corrupted after export is caught
   before it is stored.

Any CEL violation produces `ExportImportError.InvalidGraph` and maps to HTTP 422 with
the violation detail. This satisfies PD-09 AC: *"CEL conditions on imported definitions
are re-validated by the target platform's CEL interpreter; invalid expressions cause
import to be rejected with HTTP 422."*

---

### `bpm.zig` export

The `export_import` module MUST be exported from `src/bpm.zig` alongside the existing
definition module exports, so that integration tests and any future callers can import it
from the single re-export root:

```zig
// src/bpm.zig — addition required by BACKEND-DEV for PD-09
pub const export_import = @import("definition/export_import.zig");
```

**Full `src/bpm.zig` after update:**

```zig
pub const pool          = @import("db/pool.zig");
pub const registry      = @import("event_store/registry.zig");
pub const store         = @import("event_store/store.zig");
pub const definition    = @import("definition/store.zig");
pub const snapshot      = @import("definition/snapshot.zig");     // PD-08
pub const export_import = @import("definition/export_import.zig"); // PD-09
```

---

### Data flow diagram (PD-09)

```
GET /api/v1/definitions/:id/export
         │
         ▼
  handleExport(export_import_store, ctx)
         │  1. Parse UUID from path param (:id); 422 if malformed
         │  2. Auth middleware verified (API-08)
         │
         ▼
  ExportImportStore.exportDefinition(allocator, definition_id)
         │
         ├─ SELECT id, name, version, description, graph
         │    FROM process_definitions WHERE id = $1  (any status)
         │      0 rows → DefinitionNotFound → HTTP 404
         │
         ├─ Build ExportDocument{bpm_export_schema_version, id, name, version,
         │    description, graph, exported_at=now()}
         │
         └─ return ExportDocument → HTTP 200, JSON body


POST /api/v1/definitions/import
         │
         ▼
  handleImport(export_import_store, ctx)
         │  1. Parse ExportDocument from request body JSON
         │     parse failure → HTTP 422 "invalid_request_body"
         │  2. Auth middleware verified (API-08)
         │
         ▼
  ExportImportStore.importDefinition(allocator, doc, actor.user_id)
         │
         ├─ [Step 1] Check bpm_export_schema_version == EXPORT_SCHEMA_VERSION
         │      mismatch → UnknownSchemaVersion → HTTP 422 "unknown_schema_version"
         │
         ├─ [Step 2] SELECT COUNT(*) FROM process_definitions
         │             WHERE name = $1 AND version = $2
         │      count > 0 → NameVersionConflict → HTTP 409 "name_version_conflict"
         │
         ├─ [Step 3] validateGraph(allocator, doc.graph)
         │      violations → InvalidGraph → HTTP 422 "invalid_graph" + detail
         │   validateNodeAttributes(allocator, doc.graph)
         │      violations → InvalidGraph → HTTP 422 "invalid_graph" + detail
         │   validateEdgeConditions(allocator, doc.graph)   ← CEL re-validation
         │      violations → InvalidGraph → HTTP 422 "invalid_graph" + detail
         │
         ├─ [Step 4] Store.create(allocator, CreateParams{
         │             name, version, description, graph, created_by
         │           })  → status = DRAFT (always); new UUID assigned
         │      → Definition
         │
         └─ return Definition → HTTP 201, JSON body
```

---

### Dependencies (PD-09 additions)

| Dependency | Direction | Notes |
|---|---|---|
| `src/db/pool.zig` | `export_import.zig` → `db.Pool` | Connection pool; `pool` must outlive `ExportImportStore` |
| `src/definition/graph.zig` | `export_import.zig` → `graph_mod` | `Uuid`, `DefinitionGraph`, `validateGraph()`, `validateNodeAttributes()`, `validateEdgeConditions()` |
| `src/definition/store.zig` | `export_import.zig` → `store_mod.Store`, `store_mod.CreateParams`, `store_mod.Definition` | `importDefinition()` Step 4 calls `Store.create()` |
| `src/api/routes/definitions.zig` | Adds `handleExport`, `handleImport` | Calls `ExportImportStore`; thin handler layer |
| `src/bpm.zig` | Re-exports `export_import` module | Required for integration test imports |

**Must NOT depend on:**

- `src/engine/transition.zig` — export/import is a definition-layer concern with no engine involvement.
- `src/event_store/` — definitions have no event log.
- `src/scheduler/` — export/import is synchronous; no scheduled operations.
- `src/definition/snapshot.zig` — snapshots are per-instance; export/import is per-definition.
- Any external HTTP service.

---

### Edge case: exporting a DRAFT definition

`exportDefinition()` applies no status filter when querying `process_definitions`. A
definition in `DRAFT`, `ACTIVE`, `DEPRECATED`, or `ARCHIVED` status may be exported.

**Use case:** Copying an in-progress (DRAFT) definition from a development environment
to a staging environment for review, without requiring it to be activated first. The
imported copy lands as DRAFT on the target, preserving the intent that a human must
activate it before it can be used.

---

### Traceability table — PD-09 acceptance criteria

| PD-09 AC | Design element satisfying it |
|---|---|
| GIVEN a definition with any status, WHEN exported, THEN the platform returns a self-contained JSON document containing all definition fields, the full graph, and a `bpm_export_schema_version` field | `ExportDocument` struct (7 fields including `bpm_export_schema_version` and `graph`); `exportDefinition()` reads from `process_definitions` with no status filter; `exported_at` timestamp included |
| GIVEN a valid exported JSON document, WHEN imported to a target environment with no conflicting name+version, THEN the definition is created with `status = DRAFT` on the target, preserving all fields | `importDefinition()` Steps 1–4; Step 4 calls `Store.create()` which hard-codes `status = DRAFT`; name, version, description, graph all preserved from `ExportDocument`; new UUID assigned by target |
| GIVEN an exported document where the same name+version already exists on the target, WHEN imported, THEN the import is rejected with HTTP 409 | `importDefinition()` Step 2: `SELECT COUNT(*) ... WHERE name=$1 AND version=$2`; returns `NameVersionConflict`; `handleImport()` maps to HTTP 409 `{"error":"name_version_conflict"}` |
| CEL conditions on imported definitions are re-validated by the target platform's CEL interpreter; invalid expressions cause import to be rejected with HTTP 422 | `importDefinition()` Step 3 calls `validateEdgeConditions()`; `validateEdgeConditions()` calls `isValidCelSyntax()` on every non-default EXCLUSIVE_GATEWAY edge condition (CHK-EC-06); `InvalidGraph` → HTTP 422 `{"error":"invalid_graph","detail":<violations>}` |

---

### Open questions

None — PD-09 is fully specified by the requirements document. The following are noted
for downstream agents:

- **BACKEND-DEV:** Must create `src/definition/export_import.zig`, implement
  `ExportImportStore.exportDefinition()` and `ExportImportStore.importDefinition()`,
  add `handleExport` and `handleImport` to `src/api/routes/definitions.zig`, wire both
  routes in the router/main, and update `src/bpm.zig` with the `export_import` export.
- **BACKEND-DEV:** The `importDefinition()` Step 3 graph violation detail must be
  passed back to `handleImport()` for inclusion in the HTTP 422 `"detail"` field. The
  existing `Store.lastViolations()` mechanism is not available on `ExportImportStore`
  (which delegates to `Store.create()`); the handler may call `Store.lastViolations()`
  on the inner `Store` instance after `InvalidGraph` is returned, or `ExportImportStore`
  may expose its own `lastViolations()` accessor. BACKEND-DEV to decide during
  implementation.
- **No new migration needed:** `exportDefinition()` reads from `process_definitions`
  (already created by `migrations/004_definitions.sql`); `importDefinition()` inserts
  via `Store.create()` which uses the same table. No additional schema change is required
  for PD-09.



## PD-10 — Definition search

**Covers:** PD-10
**Extends:** PD-01/PD-02/PD-03/PD-04/PD-05/PD-06/PD-07/PD-08/PD-09 sections above; read those first.

---

### Module purpose (PD-10 extension)

This section extends the definition module with a full-text search endpoint over definition
names and descriptions. Search lives inside the existing `store.zig` (a new `Store.search()`
method) and `src/api/routes/definitions.zig` (a new `handleSearch` handler). No new Zig
source file or SQL migration is required.

---

### Endpoint

```
GET /api/v1/definitions/search?q={query}&limit={n}&offset={n}
```

**Rationale for placement in `src/api/routes/definitions.zig`:** All definition read
endpoints (`handleGetById`, `handleList`, `handleGetActiveByName`) already live in this
file and share the `definition_store.Store` dependency. Adding `handleSearch` here follows
the same pattern, avoids creating a new route file, and keeps all definition HTTP surface in
one place for easy maintenance.

---

### `SearchOptions` struct

```zig
/// Input to Store.search() (PD-10).
pub const SearchOptions = struct {
    /// The search query string.
    /// MUST be non-empty (QueryEmpty → HTTP 422) and ≤ 512 characters (QueryTooLong → HTTP 422).
    /// Validated by the HTTP handler before Store.search() is called;
    /// also validated inside Store.search() as belt-and-suspenders.
    query: []const u8,
    /// Pagination: maximum number of results to return.
    /// Corresponds to API-06 `limit`; default 20, max 100.
    limit: u32,
    /// Pagination: number of results to skip.
    /// Corresponds to API-06 `offset`; default 0.
    offset: u32,
};
```

**Validation rules:**

| Field | Constraint | Error on violation |
|---|---|---|
| `query` | Non-empty (length > 0) | `QueryEmpty` → HTTP 422 |
| `query` | Length ≤ 512 characters | `QueryTooLong` → HTTP 422 |
| `limit` | 1–100 inclusive; absent/0 → default 20 | HTTP 422 if > 100 (handler-level) |
| `offset` | ≥ 0; absent → default 0 | n/a |

---

### `SearchResult` struct

```zig
/// A single result item returned by Store.search() (PD-10).
pub const SearchResult = struct {
    /// The matching definition (all fields identical to Definition).
    definition: Definition,
    /// Relevance rank: higher means more relevant. Computed by PostgreSQL CASE expression.
    /// Possible values: 3.0 (exact name match), 2.0 (partial name match), 1.0 (description-only match).
    rank: f32,
};
```

---

### `DefinitionError` additions (PD-10)

Two new variants are appended to the `DefinitionError` error set declared in the
PD-01/PD-02 section above. They share the same error set to preserve the single-error-union
convention used throughout `store.zig`.

```zig
pub const DefinitionError = error{
    // ── existing entries (PD-01 … PD-09) ──────────────────────────────────
    PoolExhausted,
    DuplicateNameVersion,
    DefinitionNotFound,
    InvalidStatusTransition,
    InitialStatusNotDraft,
    NameInvalid,
    VersionEmpty,
    GraphStructureInvalid,
    GraphValidationFailed,
    TransactionFailed,
    AlreadyActive,
    NotDraft,

    // ── PD-10 additions ───────────────────────────────────────────────────

    /// Search query is empty or whitespace-only → HTTP 422.
    /// Validated by both the HTTP handler (step 1) and Store.search() (belt-and-suspenders).
    QueryEmpty,

    /// Search query exceeds 512 characters → HTTP 422.
    /// Validated by both the HTTP handler (step 2) and Store.search() (belt-and-suspenders).
    QueryTooLong,
};
```

**HTTP status mappings for PD-10 errors:**

| Error | HTTP status | Response body |
|---|---|---|
| `QueryEmpty` | 422 | `{"error": "query_empty"}` |
| `QueryTooLong` | 422 | `{"error": "query_too_long"}` |

---

### `Store.search()` function signature

```zig
/// Search definitions by name or description (PD-10).
///
/// Algorithm:
///   1. Validate opts.query: if len == 0 → QueryEmpty (HTTP 422).
///      If len > 512 → QueryTooLong (HTTP 422).
///   2. Build two pg bind parameters:
///      $1 = opts.query                (exact match pattern, e.g. "invoice")
///      $2 = "%" ++ opts.query ++ "%"  (partial match pattern, e.g. "%invoice%")
///      Both are bound as pg parameters — NO SQL string interpolation.
///   3. Execute the ILIKE SELECT (see SQL section below) with $1, $2, $3=$limit, $4=$offset.
///   4. Map result rows to []SearchResult, ordered by rank DESC, created_at DESC
///      (ORDER BY is in SQL; caller receives rows in that order).
///
/// Returns an empty slice (not an error) when no rows match.
/// An empty result satisfies PD-10 AC: "no-match → HTTP 200 with empty array."
///
/// Security: query bound as pg parameters; the '%' wildcard characters are placed
/// in the SQL text as literals ($2 pattern), NOT appended in Zig to user input before
/// binding. This prevents any SQL injection through wildcard escaping or quoting attacks.
/// SQL-special characters in opts.query (' % _ \) are escaped by the pg driver.
///
/// Covers: PD-10 (full-text search over definitions, ranked results, pagination).
pub fn search(
    self:      *Store,
    allocator: std.mem.Allocator,
    opts:      SearchOptions,
) DefinitionError![]SearchResult;
```

---

### SQL implementation

```sql
SELECT
    id,
    name,
    version,
    description,
    status,
    stage,
    graph,
    created_by,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint AS updated_at_us,
    (EXTRACT(EPOCH FROM archived_at) * 1000000)::bigint AS archived_at_us,
    CASE
        WHEN name ILIKE $1 THEN 3.0
        WHEN name ILIKE $2 THEN 2.0
        ELSE 1.0
    END AS rank
FROM process_definitions
WHERE name ILIKE $2
   OR description ILIKE $2
ORDER BY rank DESC, created_at DESC
LIMIT $3 OFFSET $4
```

**Parameter bindings:**

| Placeholder | Bound value | Example (query = `"invoice"`) | Notes |
|---|---|---|---|
| `$1` | `opts.query` (exact) | `"invoice"` | Scores 3.0: exact name match |
| `$2` | `"%" ++ opts.query ++ "%"` | `"%invoice%"` | Scores 2.0 (name) or 1.0 (description); also drives WHERE clause |
| `$3` | `opts.limit` | `20` | LIMIT for pagination |
| `$4` | `opts.offset` | `0` | OFFSET for pagination |

**Important:** The `%` wildcard characters in `$2` are in the SQL string as literals, not
appended to `opts.query` in Zig before binding. The binding sequence in Zig is:

```zig
// Correct: compose the pattern string, then bind it as one parameter value.
const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{opts.query});
defer allocator.free(pattern);
// pg.zig bind call:  query.bindText(2, pattern)
// This passes the entire "%invoice%" string as a single parameter value to the pg driver.
// The driver escapes the value; the SQL engine interprets % as a wildcard only
// within the ILIKE operator — not as SQL syntax.
```

**Why ILIKE instead of `tsvector`/`to_tsquery`:**

- `tsvector` full-text search requires a language dictionary configuration (e.g.
  `pg_catalog.english`). Dictionary selection is environment-specific and can fail on
  custom database clusters.
- `ILIKE` is a built-in PostgreSQL operator with no external configuration, no stemming
  ambiguity, and no need for a GIN index to function correctly.
- PD-10 is a `COULD` priority requirement; the simpler ILIKE approach meets all
  acceptance criteria without adding operational risk.
- Partial word matching (the `SHOULD` criterion) is satisfied by the `'%query%'` pattern.
- If full-text search performance becomes a concern at scale, a GIN index can be added
  as a follow-up migration without any API change.

**Ranking semantics:**

| CASE branch | Score | Description |
|---|---|---|
| `name ILIKE $1` (exact) | 3.0 | The definition name is exactly the query string (case-insensitive) |
| `name ILIKE $2` (partial) | 2.0 | The definition name contains the query string |
| Otherwise (description match only) | 1.0 | The description contains the query string but the name does not |

Results with equal rank are sub-sorted by `created_at DESC` (newest first) for
deterministic ordering.

---

### HTTP handler `handleSearch`

```zig
/// GET /api/v1/definitions/search?q={query}&limit={n}&offset={n}
///
/// Handler logic (9 steps):
///   1. Parse `q` from query string; if absent or empty → HTTP 422 + {"error":"query_empty"}.
///   2. If len(q) > 512 → HTTP 422 + {"error":"query_too_long"}.
///   3. Parse `limit` from query string; absent/0 → default 20; > 100 → HTTP 422 + {"error":"limit_out_of_range"}.
///   4. Parse `offset` from query string; absent → default 0.
///   5. Build SearchOptions{.query=q, .limit=limit, .offset=offset}.
///   6. Call Store.search(allocator, opts).
///   7–9. Map Store.search() result to HTTP response (see status code table below).
///
/// Route registration (wire in router.zig / main.zig):
///   GET /api/v1/definitions/search → handleSearch
///   NOTE: this route MUST be registered BEFORE /api/v1/definitions/:id in the router,
///   otherwise "search" may be interpreted as a :id path parameter by some routers.
pub fn handleSearch(
    store:     *definition_store.Store,
    allocator: std.mem.Allocator,
    params:    SearchQueryParams,
) HandlerResult;
```

**`SearchQueryParams` struct (handler input type):**

```zig
/// Query parameters accepted by GET /api/v1/definitions/search.
pub const SearchQueryParams = struct {
    /// The search query string; null if `q=` is absent from the URL.
    q: ?[]const u8,
    /// Page size limit; null or 0 → default 20.
    limit: ?u32,
    /// Page offset; null → default 0.
    offset: ?u32,
};
```

**9-step handler logic:**

| Step | Condition | Action |
|---|---|---|
| 1 | `q` absent or `q` is empty string | HTTP 422 + `{"error": "query_empty"}` |
| 2 | `len(q) > 512` | HTTP 422 + `{"error": "query_too_long"}` |
| 3 | `limit > 100` | HTTP 422 + `{"error": "limit_out_of_range"}` |
| 4 | `offset` absent | Use default 0 |
| 5 | Build `SearchOptions` | `.query=q`, `.limit=effective_limit`, `.offset=effective_offset` |
| 6 | Call `Store.search(allocator, opts)` | — |
| 7 | `error.QueryEmpty` returned | HTTP 422 + `{"error": "query_empty"}` (belt-and-suspenders) |
| 8 | `error.QueryTooLong` returned | HTTP 422 + `{"error": "query_too_long"}` (belt-and-suspenders) |
| 9 | `[]SearchResult` returned (may be empty) | HTTP 200 + JSON array |

**Status code mapping table:**

| Store.search() result | HTTP status | Response body |
|---|---|---|
| `QueryEmpty` | 422 | `{"error": "query_empty"}` |
| `QueryTooLong` | 422 | `{"error": "query_too_long"}` |
| `PoolExhausted` | 503 | `{"error": "service_unavailable"}` |
| `TransactionFailed` / `DatabaseError` | 500 | `{"error": "internal_error"}` |
| `[]SearchResult` (empty) | 200 | `[]` |
| `[]SearchResult` (non-empty) | 200 | JSON array of `{"definition": {...}, "rank": 2.0}` objects |

**JSON response shape (HTTP 200):**

```json
[
  {
    "definition": {
      "id": "...",
      "name": "Invoice Approval",
      "version": "1.0",
      "description": "Approves vendor invoices",
      "status": "ACTIVE",
      "stage": null,
      "graph": { "nodes": [...], "edges": [...] },
      "created_by": "...",
      "created_at": 1716220800000000,
      "updated_at": 1716220800000000,
      "archived_at": null
    },
    "rank": 2.0
  }
]
```

The `definition` object uses the same JSON structure as `GET /definitions` (PD-07).

---

### No new migration required

A new SQL migration is NOT needed for PD-10.

**Rationale:**
- `ILIKE` queries work directly against the existing `name TEXT NOT NULL` and
  `description TEXT` columns in `process_definitions` (created by `migrations/004_definitions.sql`).
- Correctness does not require a GIN index. PostgreSQL performs a sequential scan through
  the table for ILIKE queries without an index, which is acceptable at the current scale.
- A GIN index on `(name, description)` would improve search performance at larger table
  sizes but is a performance optimisation, not a correctness requirement.
- PD-10 is a `COULD` priority requirement. Deferring the GIN index reduces migration risk
  and operational complexity for the initial implementation.
- The index can be introduced as a standalone migration in a future sprint if search
  latency becomes a concern, without any change to the API contract or Zig code.

---

### Security note — SQL injection prevention

The search handler and `Store.search()` are designed so that **no user-supplied value is
ever interpolated into a SQL string**. The security mechanism works as follows:

1. `opts.query` is passed to `Store.search()` as a `[]const u8` slice (a plain Zig string).
2. Inside `Store.search()`, the pattern string `"%{query}%"` is built with
   `std.fmt.allocPrint(allocator, "%{s}%", .{opts.query})` — this is a Zig string
   concatenation that produces a normal string value.
3. That pattern string is then bound as parameter `$2` to the pg query using
   `pg.zig`'s parameter-binding API (e.g. `query.bindText(2, pattern)`).
4. The PostgreSQL driver transmits `$2`'s value through the **binary or extended query
   protocol** as a data value, never as SQL syntax. The `%` characters in the pattern
   are interpreted by the ILIKE operator as wildcard metacharacters inside the pattern
   value — they are not SQL syntax characters.
5. SQL-special characters in `opts.query` — including single quote (`'`), percent (`%`),
   underscore (`_`), and backslash (`\`) — are transmitted as literal data values by the
   pg driver's escaping layer. They cannot escape the parameter boundary to inject SQL
   syntax.

**Why this is safe:** The `%` wildcards are placed in the SQL query text as literals
(i.e., the SQL contains `ILIKE $2` and the value of `$2` contains `%`). They are never
built into the SQL string itself by appending user input to SQL source. An attacker who
supplies `q='; DROP TABLE process_definitions; --` would have the entire string
(including the single quote and semicolon) bound as the value of `$2` — the pg driver
will transmit it as a parameter value and PostgreSQL will interpret it as a literal search
pattern, not SQL commands.

**Edge case — query containing `%` or `_`:** If the user queries `q=50%`, the `%` is
part of the value passed to the pg driver. PostgreSQL's ILIKE will treat this `%` as a
wildcard (matching any sequence of characters), which may produce broader results than
expected. This is a UX concern, not a security concern. If literal `%` and `_` matching
is required in a future iteration, the implementation can escape them in the Zig pattern
builder (`%` → `\%`, `_` → `\_`) and append `ESCAPE '\'` to the SQL — both changes are
safe and do not affect the security model.

---

### Data flow diagram (PD-10)

```
GET /api/v1/definitions/search?q=invoice&limit=20&offset=0
         │
         ▼
  handleSearch(store, allocator, params)
         │  1. q absent/empty           → HTTP 422 {"error":"query_empty"}
         │  2. len(q) > 512             → HTTP 422 {"error":"query_too_long"}
         │  3. limit > 100              → HTTP 422 {"error":"limit_out_of_range"}
         │  4. Build SearchOptions
         │
         ▼
  store.search(allocator, opts)
         │
         ├─ [A] Validate opts.query (belt-and-suspenders)
         │      len == 0 → QueryEmpty
         │      len > 512 → QueryTooLong
         │
         ├─ [B] Build pattern: "%" ++ query ++ "%"  (Zig string alloc)
         │
         ├─ [C] pool.acquire()  → PoolExhausted (HTTP 503) on failure
         │
         ├─ [D] Execute ILIKE SELECT
         │      $1 = query  (exact), $2 = pattern (partial)
         │      $3 = limit, $4 = offset
         │      ORDER BY rank DESC, created_at DESC
         │      → TransactionFailed (HTTP 500) on DB error
         │
         ├─ [E] pool.release()
         │
         └─ return []SearchResult (may be empty)
                   │
                   ▼
         handleSearch maps to HTTP 200 + JSON array
         (empty array when []SearchResult has len == 0)
```

---

### Dependencies (PD-10 additions)

No new module dependencies. PD-10 reuses the existing:

| Dependency | Direction | Notes |
|---|---|---|
| `src/db/pool.zig` | `store.zig` → `db.Pool` | Same pool used by all other Store methods |
| `src/definition/graph.zig` | `store.zig` → `graph_mod.Definition` | `SearchResult.definition` field type |
| `src/api/routes/definitions.zig` | Adds `handleSearch` | Same file as PD-07 handlers; no new file |
| `migrations/004_definitions.sql` | Schema | `name` and `description` columns already present |

**Must NOT depend on:**
- `src/engine/transition.zig`
- `src/event_store/`
- `src/scheduler/`
- Any external HTTP service or search index.

---

### Extended error taxonomy (PD-10)

| Error | Source check | HTTP status | PD ref |
|---|---|---|---|
| `QueryEmpty` | `query.len == 0` | 422 | PD-10 |
| `QueryTooLong` | `query.len > 512` | 422 | PD-10 |
| `PoolExhausted` | `pool.acquire()` | 503 | DB-02 |
| `TransactionFailed` | DB execute | 500 | DB-03 |

All other `DefinitionError` variants are not reachable from `Store.search()`.

---

### Edge case — SQL-special characters in query

When `opts.query` contains characters that have special meaning in SQL or in ILIKE pattern
syntax (`'`, `%`, `_`, `\`):

- **Single quote (`'`):** Bound as a parameter value by the pg driver. The driver escapes
  it (doubling or using the extended protocol) before transmitting to PostgreSQL. It cannot
  terminate a string literal in the SQL text because it is never embedded in the SQL text.
- **Percent (`%`):** Transmitted as part of the `$2` pattern value. PostgreSQL's ILIKE
  operator interprets `%` as a wildcard within the pattern. This means a query of
  `q=50%off` will match any string containing `50` followed by any characters followed by
  `off`. This is a usability consideration; it is not a security vulnerability.
- **Underscore (`_`):** Similarly transmitted as the `$2` value. ILIKE interprets `_` as
  a single-character wildcard. A query of `q=v_1` matches `v11`, `v21`, `vA1`, etc.
- **Backslash (`\`):** Transmitted as the value. ILIKE's default escape character in
  PostgreSQL depends on the `standard_conforming_strings` setting. Because the value is
  bound through the extended query protocol (not embedded in SQL text), backslash
  handling is handled entirely by the pg driver — no SQL injection vector exists.

**Conclusion:** All SQL-special characters are handled safely because the query is bound
as a parameter value, never interpolated into SQL text. No additional escaping is required
for security correctness in the initial implementation.

---

### PD-10 acceptance criteria traceability

| AC | Design element |
|---|---|
| `GET /definitions/search?q={query}` → HTTP 200 + ranked list | `handleSearch` → `Store.search()` → SQL `ORDER BY rank DESC, created_at DESC` |
| Results MUST be ordered by relevance (highest-scoring first) | SQL `CASE WHEN name ILIKE $1 THEN 3.0 WHEN name ILIKE $2 THEN 2.0 ELSE 1.0 END AS rank` + `ORDER BY rank DESC` |
| Empty query (`q=`) → HTTP 422 | `handleSearch` step 1 (absent/empty `q`) + `QueryEmpty` error in `Store.search()` belt-and-suspenders |
| Query > 512 chars → HTTP 422 | `handleSearch` step 2 + `QueryTooLong` error in `Store.search()` belt-and-suspenders |
| Pagination MUST be supported per API-06 | `SearchOptions.limit` and `SearchOptions.offset`; `handleSearch` parses `?limit=` (default 20, max 100) and `?offset=` (default 0) |
| Search MUST be case-insensitive | `ILIKE` in PostgreSQL is case-insensitive by definition |
| Partial word matching (SHOULD) | `$2` pattern is `"%{query}%"` — matches any name or description containing the query string as a substring |
| No-match → HTTP 200 + empty array | `Store.search()` returns `[]SearchResult{}` (empty slice, not an error); `handleSearch` responds HTTP 200 with `[]` |
| SQL injection safe | `$1` (exact query) and `$2` (pattern) are pg-bound parameters; no string interpolation; pg driver escapes all values |
| SQL-special chars handled safely | Bound parameter value — pg driver transmits through extended query protocol; no SQL injection vector |

---

### Open questions

None — PD-10 is fully validated (`status: VALIDATED` in `docs/requirements/PD-10.md`).
All design decisions are resolved above. No REQ-ANALYST clarification is required.

**Downstream agent notes:**
- **BACKEND-DEV:** Implement `SearchOptions`, `SearchResult`, `QueryEmpty`, `QueryTooLong`
  in `src/definition/store.zig`; implement `Store.search()` with the ILIKE SQL query;
  implement `handleSearch` in `src/api/routes/definitions.zig`; register route before
  `GET /api/v1/definitions/:id` in the router.
- **No migration needed** (ILIKE works on existing columns; GIN index deferred).
- **FRONTEND-DEV:** Add search API call and UI once BACKEND-DEV delivers the endpoint.
