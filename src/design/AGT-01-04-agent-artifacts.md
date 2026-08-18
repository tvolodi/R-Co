# Module: AGT-01–04 Agent Artifact Submission

## Module Purpose

This module defines the first-class agent artifact submission pipeline. An authoring agent
submits its work through a typed envelope endpoint; the platform discriminates the payload
schema by `kind`, enforces that artifacts may only be stored in non-production deployments,
provides per-attempt idempotency using a database-level `xmax` trick, and binds each artifact
to an immutable task spec identified by a content-addressed `spec_hash` (SHA-256 of RFC 8785
canonical JSON).

The design covers AGT-01 (envelope + kind discrimination), AGT-02 (environment enforcement),
AGT-03 (idempotency per attempt), and AGT-04 (immutable task specs and spec_hash).

---

## Classification (Lego Catalog)

All four requirements decompose into **Type E** (novel / cross-cutting). Each tip point:

- **AGT-01**: Handler must discriminate schema by `kind` field before store call; closed
  schema validation with per-kind error pointers does not fit a 15-line `// CUSTOM:` block.
- **AGT-02**: Environment check must fire before schema selection and before payload parsing;
  the environment is read from deployment config (not from the request), making this an
  out-of-band middleware concern that does not fit Type A wiring.
- **AGT-03**: `INSERT … ON CONFLICT … DO UPDATE … RETURNING xmax = 0 AS inserted` is a
  non-standard idempotency primitive; the handler's status-code outcome depends on three
  mutually exclusive runtime states (new / re-hit match / re-hit mismatch / regressed
  attempt), overflowing the Type A error-mapping model.
- **AGT-04**: Spec immutability requires a read-before-write guard plus RFC 8785
  canonicalization of the submitted document; there is no update path.

No Type A–D parameter files are produced for this batch.

---

## Requirement Coverage Matrix

| Requirement | Design Element | Acceptance Mapping |
|---|---|---|
| AGT-01 kind enum | `ArtifactKind` Zig enum, `kind` column on `staging.agent_artifacts` | Filtering on `kind` returns the row without payload parsing |
| AGT-01 schema discrimination | `KindSchemaRegistry` + per-kind closed JSON schema | Each `kind` value maps to exactly one schema; unrecognised kind → 400 |
| AGT-01 closed schema | `strict: true` flag in each schema descriptor | Unknown members rejected at validation time |
| AGT-01 schema publication | `GET /api/v1/agent/artifacts/schemas` | Returns versioned schema objects for all four kinds |
| AGT-02 env enforcement | `EnvironmentClass` deployment config + pre-parse guard | Production deployments always return 403 before payload is read |
| AGT-02 audit event | `ArtifactSubmissionRejected` audit entry shape | Every rejection appends the event with env class and principal |
| AGT-02 staging schema | `staging.agent_artifacts` table | No artifact table in public or production schema |
| AGT-03 idempotency index | `UNIQUE (tenant_id, task_spec_id, attempt_count)` | Concurrent inserts: exactly one observes `xmax = 0 IS TRUE` |
| AGT-03 xmax trick | `INSERT … ON CONFLICT … RETURNING xmax = 0 AS inserted` | New → 201; re-hit match → 200; re-hit mismatch → 409 spec_hash_mismatch |
| AGT-03 attempt regression | Max-attempt guard before insert | attempt_count < max stored → 409 attempt_count_regressed |
| AGT-04 spec_hash | `spec_hash CHAR(64)` on `task_specs` (already in migration 1170) | Verified against existing row |
| AGT-04 RFC 8785 | Canonical JSON normalisation step before SHA-256 | Different key orders / whitespace / number formats produce same hash |
| AGT-04 immutability | No UPDATE path on `task_specs`; 409 on update attempt | Stored row unchanged on any update call |
| AGT-04 spec_not_found | Lookup of `spec_hash` before insert of artifact | Unknown spec_hash → 404 task_spec_not_found |

---

## Database Schema

### Existing Table: `task_specs` (migration 1170 — no changes needed)

```sql
-- Already present; spec_hash CHAR(64) UNIQUE satisfies AGT-04 identity requirement.
-- orchestrator_principal is part of the hashed document, satisfying the SBX-02 coverage AC.
CREATE TABLE IF NOT EXISTS task_specs (
    task_spec_id            UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_hash               CHAR(64) NOT NULL,
    spec_body               JSONB    NOT NULL,
    orchestrator_principal  TEXT     NOT NULL,
    rng_seed                BIGINT   NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_ts_hash UNIQUE (spec_hash)
);
```

### New Table: `staging.agent_artifacts` (new migration — AGT-01, AGT-02, AGT-03)

```sql
-- scope: staging_only
-- This table is provisioned only in the `staging` schema.
-- On production deployments the migration runner skips this file (env-class gate).

CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.agent_artifacts (
    artifact_id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID        NOT NULL,
    task_spec_id            UUID        NOT NULL
                                        REFERENCES task_specs(task_spec_id),
    attempt_count           INTEGER     NOT NULL
                                        CHECK (attempt_count >= 0),
    kind                    TEXT        NOT NULL
                                        CHECK (kind IN (
                                            'test_report',
                                            'design_artifact',
                                            'patch_set',
                                            'scenario_run'
                                        )),
    spec_hash               CHAR(64)    NOT NULL,
    payload                 JSONB       NOT NULL,
    non_deterministic_fields JSONB,
    touched_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_aa_idempotency UNIQUE (tenant_id, task_spec_id, attempt_count)
);

CREATE INDEX IF NOT EXISTS idx_aa_kind
    ON staging.agent_artifacts (kind);
CREATE INDEX IF NOT EXISTS idx_aa_tenant_spec
    ON staging.agent_artifacts (tenant_id, task_spec_id);
```

**Design notes:**
- `uq_aa_idempotency` is the unique index that drives the `ON CONFLICT` clause in AGT-03.
- `kind` column carries a `CHECK` constraint matching the enum; the application-level
  check fires first (to return 400 with a structured error), but the DB constraint is a
  hard backstop.
- `non_deterministic_fields` is nullable JSONB carrying fields excluded from the spec_hash
  (e.g. wall-clock timings, random seeds captured at run time).
- `touched_at` is the only mutable field; it advances on every re-hit.
- `payload` is immutable after insertion; the `ON CONFLICT` clause never updates it.

---

## Zig Type Definitions

### Core Value Types

```zig
pub const ArtifactId = [16]u8;       // UUID bytes
pub const TenantId   = [16]u8;
pub const TaskSpecId = [16]u8;
pub const SpecHash   = [64]u8;       // lowercase hex, SHA-256 of RFC 8785 canonical JSON

/// Discriminant enum for the four accepted artifact kinds.
pub const ArtifactKind = enum {
    test_report,
    design_artifact,
    patch_set,
    scenario_run,

    /// Return the canonical string token used in the DB CHECK constraint and API.
    pub fn asSlice(self: ArtifactKind) []const u8;
    /// Parse from a string; returns null for unknown values.
    pub fn fromSlice(s: []const u8) ?ArtifactKind;
};

/// Deployment environment class — read from config at startup, never from requests.
pub const EnvironmentClass = enum {
    production,
    staging,
    development,
};
```

### DB Row Types

```zig
/// A fully loaded task_specs row (subset used by the artifact path).
pub const TaskSpecRow = struct {
    task_spec_id:           TaskSpecId,
    spec_hash:              SpecHash,
    spec_body:              []const u8,    // raw JSON bytes
    orchestrator_principal: []const u8,
    rng_seed:               i64,
    created_at:             i64,           // Unix ms UTC
};

/// A fully loaded agent_artifacts row.
pub const AgentArtifactRow = struct {
    artifact_id:             ArtifactId,
    tenant_id:               TenantId,
    task_spec_id:            TaskSpecId,
    attempt_count:           i32,
    kind:                    ArtifactKind,
    spec_hash:               SpecHash,
    payload:                 []const u8,   // raw JSONB bytes
    non_deterministic_fields: ?[]const u8, // nullable raw JSONB bytes
    touched_at:              i64,          // Unix ms UTC
    created_at:              i64,
};

/// Result of the idempotency INSERT, constructed from the RETURNING clause.
pub const ArtifactInsertOutcome = struct {
    artifact_id: ArtifactId,
    inserted:    bool,   // xmax = 0 → true means this was a fresh insert
    spec_hash:   SpecHash,
    touched_at:  i64,
};
```

### API Request Shape

```zig
/// Parsed and validated form of POST /api/v1/agent/artifacts request body.
pub const ArtifactSubmitRequest = struct {
    kind:                    ArtifactKind,
    task_spec_id:            TaskSpecId,
    attempt_count:           i32,
    spec_hash:               SpecHash,
    payload:                 []const u8,   // raw JSON; must match kind schema
    non_deterministic_fields: ?[]const u8, // nullable
};
```

### API Response Shapes

```zig
/// HTTP 201 — artifact created (fresh insert).
pub const ArtifactCreatedResponse = struct {
    artifact_id:  ArtifactId,
    kind:         ArtifactKind,
    task_spec_id: TaskSpecId,
    attempt_count: i32,
    spec_hash:    SpecHash,
    created_at:   i64,
    touched_at:   i64,
};

/// HTTP 200 — idempotent re-hit with matching spec_hash.
pub const ArtifactReplayResponse = struct {
    artifact_id:  ArtifactId,
    kind:         ArtifactKind,
    task_spec_id: TaskSpecId,
    attempt_count: i32,
    spec_hash:    SpecHash,
    created_at:   i64,
    touched_at:   i64,   // updated to now()
};

/// GET /api/v1/agent/artifacts/schemas — envelope listing all kind schemas.
pub const SchemaCatalogResponse = struct {
    schemas: []KindSchemaEntry,
};

pub const KindSchemaEntry = struct {
    kind:    ArtifactKind,
    version: []const u8,      // semver string, e.g. "1.0.0"
    schema:  []const u8,      // JSON Schema as raw JSON bytes (strict/closed)
};
```

### Task Spec Registration Types

```zig
/// POST /api/v1/agent/task-specs request body.
pub const TaskSpecRegisterRequest = struct {
    spec_body:               []const u8,   // raw JSON document to hash and store
    orchestrator_principal:  []const u8,
    rng_seed:                i64,
};

/// HTTP 201 — new task spec registered.
pub const TaskSpecCreatedResponse = struct {
    task_spec_id: TaskSpecId,
    spec_hash:    SpecHash,
    created_at:   i64,
};

/// HTTP 200 — task spec already registered (same spec_hash already present).
pub const TaskSpecExistsResponse = struct {
    task_spec_id: TaskSpecId,
    spec_hash:    SpecHash,
    created_at:   i64,
};
```

### Error Response Types

All error responses follow the RFC 9457 Problem Details schema. The platform-specific
`code` field carries a machine-readable slug.

Base error type, artifact validation errors, and environment errors:

```zig
/// Extended Problem Details with a machine-readable code field.
pub const AgentProblemDetails = struct {
    type:   []const u8,   // URI: "https://bpm.example.com/problems/<slug>"
    title:  []const u8,
    status: u16,
    detail: []const u8,
    code:   []const u8,   // one of the slugs in the error taxonomy below
    // Per-error extension fields are defined individually below.
};

pub const UnknownArtifactKindError = struct {
    base:             AgentProblemDetails, // status=400, code="unknown_artifact_kind"
    received_kind:    []const u8,
    accepted_kinds:   [4][]const u8,       // ["test_report","design_artifact","patch_set","scenario_run"]
};

pub const ArtifactPayloadInvalidError = struct {
    base:             AgentProblemDetails, // status=422, code="artifact_payload_invalid"
    kind:             ArtifactKind,
    failing_pointer:  []const u8,         // JSON Pointer (RFC 6901) to first failing member
    validation_errors: []PayloadValidationError,
};

pub const PayloadValidationError = struct {
    pointer:  []const u8,   // JSON Pointer
    message:  []const u8,
};

pub const WrongEnvironmentError = struct {
    base:             AgentProblemDetails, // status=403, code="wrong_environment"
    environment_class: []const u8,        // "production"
};
```

Idempotency and task spec errors:

```zig
pub const SpecHashMismatchError = struct {
    base:               AgentProblemDetails, // status=409, code="spec_hash_mismatch"
    stored_spec_hash:   SpecHash,
    submitted_spec_hash: SpecHash,
    artifact_id:        ArtifactId,          // the existing row's ID
};

pub const AttemptCountRegressedError = struct {
    base:                AgentProblemDetails, // status=409, code="attempt_count_regressed"
    submitted_attempt:   i32,
    max_stored_attempt:  i32,
    task_spec_id:        TaskSpecId,
};

pub const TaskSpecNotFoundError = struct {
    base:      AgentProblemDetails, // status=404, code="task_spec_not_found"
    spec_hash: SpecHash,
};

pub const TaskSpecImmutableError = struct {
    base:         AgentProblemDetails, // status=409, code="task_spec_immutable"
    task_spec_id: TaskSpecId,
    spec_hash:    SpecHash,
};
```

---

## API Route Signatures

All endpoints are authenticated (Bearer token required) and tenant-scoped.

```text
POST   /api/v1/agent/artifacts
GET    /api/v1/agent/artifacts/schemas
POST   /api/v1/agent/task-specs
GET    /api/v1/agent/task-specs/:spec_hash
```

### Route Table

| Method | Path | Request Body | Success Status | Error Codes |
|---|---|---|---|---|
| POST | `/api/v1/agent/artifacts` | `ArtifactSubmitRequest` (JSON) | 201 / 200 | 400 unknown_artifact_kind, 403 wrong_environment, 404 task_spec_not_found, 409 spec_hash_mismatch, 409 attempt_count_regressed, 422 artifact_payload_invalid |
| GET | `/api/v1/agent/artifacts/schemas` | — | 200 `SchemaCatalogResponse` | — |
| POST | `/api/v1/agent/task-specs` | `TaskSpecRegisterRequest` (JSON) | 201 / 200 | 409 task_spec_immutable |
| GET | `/api/v1/agent/task-specs/:spec_hash` | — | 200 `TaskSpecRow` projection | 404 task_spec_not_found |

### Zig Handler Signatures (no bodies)

```zig
pub fn handleArtifactSubmit(
    allocator:  std.mem.Allocator,
    request:    *const http.Request,
    env_class:  EnvironmentClass,
    db:         *pg.Pool,
) ArtifactHandlerError!http.Response;

pub fn handleSchemaCatalog(
    allocator:  std.mem.Allocator,
    request:    *const http.Request,
) ArtifactHandlerError!http.Response;

pub fn handleTaskSpecRegister(
    allocator:  std.mem.Allocator,
    request:    *const http.Request,
    db:         *pg.Pool,
) TaskSpecHandlerError!http.Response;

pub fn handleTaskSpecGet(
    allocator:  std.mem.Allocator,
    request:    *const http.Request,
    spec_hash:  []const u8,
    db:         *pg.Pool,
) TaskSpecHandlerError!http.Response;
```

---

## Data Flow: POST /api/v1/agent/artifacts

```
Request
  │
  ▼
[1] Environment class check (EnvironmentClass from deployment config)
    production → 403 wrong_environment + ArtifactSubmissionRejected audit event
                 (payload not read, no schema selection)
  │ staging / development
  ▼
[2] Parse envelope fields: kind, task_spec_id, attempt_count, spec_hash (no payload parse yet)
    unknown kind → 400 unknown_artifact_kind
  │ known kind
  ▼
[3] Validate payload JSON against the schema selected by kind (strict/closed)
    validation failure → 422 artifact_payload_invalid (first failing JSON pointer)
  │ valid
  ▼
[4] Lookup task_specs by spec_hash WHERE tenant_id = $tenant
    not found → 404 task_spec_not_found
  │ found
  ▼
[5] Attempt-count regression guard:
    SELECT MAX(attempt_count) FROM staging.agent_artifacts
      WHERE tenant_id = $tenant AND task_spec_id = $task_spec_id
    IF submitted attempt_count < MAX(stored) AND no row exists for this triple
      → 409 attempt_count_regressed
  │ OK (attempt is fresh or exact re-hit candidate)
  ▼
[6] Idempotency INSERT:
    INSERT INTO staging.agent_artifacts (tenant_id, task_spec_id, attempt_count, kind,
        spec_hash, payload, non_deterministic_fields)
    VALUES ($1 … $7)
    ON CONFLICT (tenant_id, task_spec_id, attempt_count)
      DO UPDATE SET touched_at = now()
    RETURNING artifact_id, spec_hash, touched_at, created_at, xmax = 0 AS inserted
  │
  ├─ inserted = true  → 201 ArtifactCreatedResponse
  │
  └─ inserted = false
       ├─ stored spec_hash = submitted spec_hash → 200 ArtifactReplayResponse
       └─ stored spec_hash ≠ submitted spec_hash → 409 spec_hash_mismatch
```

---

## Data Flow: POST /api/v1/agent/task-specs

```
Request
  │
  ▼
[1] Parse request body: spec_body (raw JSON), orchestrator_principal, rng_seed
  │
  ▼
[2] RFC 8785 canonical JSON normalisation of spec_body
    (key order, whitespace removal, number formatting — no content change)
  │
  ▼
[3] SHA-256(canonical_bytes) → spec_hash (64 lowercase hex chars)
  │
  ▼
[4] INSERT INTO task_specs (spec_hash, spec_body, orchestrator_principal, rng_seed)
    VALUES ($1 … $4)
    ON CONFLICT (spec_hash) DO NOTHING
    RETURNING task_spec_id, spec_hash, created_at, xmax = 0 AS inserted
  │
  ├─ inserted = true  → 201 TaskSpecCreatedResponse
  └─ inserted = false → 200 TaskSpecExistsResponse (no update, row unchanged)

UPDATE /PUT attempts on task_specs: not routed (no handler);
any request to a task-spec-update path returns 409 task_spec_immutable.
```

---

## Per-Kind Payload Schemas (AGT-01)

Schemas are closed (additional properties disallowed). All four are versioned at `1.0.0`.

### `test_report`

```
Required members:
  suite_id        string  — identifier of the test suite that produced this report
  run_id          string  — unique run identifier (UUID)
  passed          integer — count of passing assertions (≥ 0)
  failed          integer — count of failing assertions (≥ 0)
  skipped         integer — count of skipped assertions (≥ 0)
  duration_ms     integer — wall-clock duration (≥ 0)
  assertions      array   — per-assertion results (see AssertionResult below)

Optional members:
  coverage_pct    number  — line coverage percentage [0.0, 100.0]
  error_summary   string  — human-readable failure summary

AssertionResult (each element of assertions[]):
  Required: name (string), passed (boolean)
  Optional: message (string), duration_ms (integer)

Unknown top-level or nested members → 422 artifact_payload_invalid.
```

### `design_artifact`

```
Required members:
  artifact_path   string  — workspace-relative path of the design document
  format          string  — enum: "markdown", "yaml", "json"
  content_hash    string  — SHA-256 hex of the document content (64 chars)
  schema_version  string  — semver of the design schema used

Optional members:
  description     string  — one-line human summary
  open_issues     array of string — unresolved questions

Unknown members → 422.
```

### `patch_set`

```
Required members:
  base_commit     string  — full 40-char Git SHA of the base commit
  patches         array   — ordered list of PatchEntry (see below)
  total_files     integer — count of files modified (≥ 1)
  total_lines_added   integer — (≥ 0)
  total_lines_removed integer — (≥ 0)

PatchEntry:
  Required: file_path (string), diff_hash (string, SHA-256 hex of the unified diff)
  Optional: lines_added (integer), lines_removed (integer)

Unknown members → 422.
```

### `scenario_run`

```
Required members:
  scenario_id     string  — identifier of the executed scenario
  seed            integer — RNG seed used for this run
  passed          boolean — overall run outcome
  step_results    array   — per-step results (see StepResult below)

Optional members:
  elapsed_ms      integer — total wall-clock time (≥ 0)
  assertion_count integer — total assertions evaluated (≥ 0)

StepResult:
  Required: step_id (string), passed (boolean)
  Optional: message (string), elapsed_ms (integer)

Unknown members → 422.
```

---

## AGT-02: Environment Class Gating

### Configuration Source

`EnvironmentClass` is read once at server startup from the deployment configuration
(e.g. a compile-time constant, an environment variable read on boot, or a config file).
It is **never** read from the request body, request headers, or a database row.

### Guard Contract

```
IF deployment.environment_class == .production:
    record ArtifactSubmissionRejected audit event
    return 403 wrong_environment
    (payload is not read; no schema validation runs)
```

The guard executes as the first step of `handleArtifactSubmit`, before any JSON parsing.

### ArtifactSubmissionRejected Audit Event

```zig
pub const ArtifactSubmissionRejectedEvent = struct {
    event_type:        []const u8,   // "ArtifactSubmissionRejected"
    tenant_id:         TenantId,
    principal:         []const u8,   // calling principal from auth context
    environment_class: []const u8,   // "production"
    timestamp:         i64,          // Unix ms UTC
};
```

Fields **not** included in the audit record:
- Request body content
- Payload content
- Any headers beyond the principal

### Staging Schema Invariant

- `staging.agent_artifacts` is created only by the migration that runs on staging/development
  deployments. On production deployments, the migration is skipped (env-class gate in the
  migration runner). The absence of the table is the hard backstop.
- The route handler itself exists and is registered on all deployment classes; its existence
  cannot be probed by absence. On production it always returns 403 before touching the DB.

---

## AGT-03: Idempotency Design

### Unique Index

```sql
CONSTRAINT uq_aa_idempotency UNIQUE (tenant_id, task_spec_id, attempt_count)
```

This is the conflict target for `ON CONFLICT`. The uniqueness guarantee means that two
concurrent inserts for the same triple will serialize at the DB level, with exactly one
observing a fresh insert.

### xmax = 0 Idiom

PostgreSQL's system column `xmax` holds the transaction ID of the deleting or updating
transaction. For a newly inserted row (never touched by a subsequent write), `xmax = 0`.
After an `ON CONFLICT … DO UPDATE`, `xmax` holds the current transaction ID, which is
always non-zero.

Therefore:
```sql
INSERT … ON CONFLICT (tenant_id, task_spec_id, attempt_count)
  DO UPDATE SET touched_at = now()
RETURNING artifact_id, spec_hash, touched_at, created_at,
          (xmax = 0) AS inserted
```

- `inserted = true`: this transaction performed the fresh insert — return HTTP 201.
- `inserted = false, stored spec_hash = submitted spec_hash`: idempotent re-hit — return HTTP 200.
- `inserted = false, stored spec_hash ≠ submitted spec_hash`: hash collision on a
  different spec — return HTTP 409 `spec_hash_mismatch`.

### Attempt Count Regression Guard

Before the idempotency INSERT, the handler queries:

```sql
SELECT MAX(attempt_count) AS max_attempt
FROM staging.agent_artifacts
WHERE tenant_id = $1 AND task_spec_id = $2
```

If `max_attempt IS NOT NULL AND submitted_attempt_count < max_attempt`:
- Return HTTP 409 `attempt_count_regressed`.
- The stored row is not modified.

Note: `attempt_count` equal to `max_attempt` is allowed (exact re-hit candidate handled by
the xmax path). Only strictly less triggers the regression error.

### Concurrent Insert Safety

Two concurrent requests for the same (tenant_id, task_spec_id, attempt_count):
- One INSERT wins the unique index lock and observes `xmax = 0 = true` → HTTP 201.
- The other's INSERT conflicts and takes the DO UPDATE path → `xmax = 0 = false`.
  - It then compares spec_hash: if they submitted the same envelope, it returns HTTP 200.
  - If they submitted different envelopes (different spec_hash), it returns HTTP 409.

---

## AGT-04: Spec Hash and Immutability

### RFC 8785 Canonical JSON Normalisation

RFC 8785 (JSON Canonicalization Scheme, JCS) defines a deterministic serialisation:

1. **Key order**: object keys sorted by their Unicode code point (UTF-16 comparison, not
   UTF-8 byte order).
2. **Whitespace**: no insignificant whitespace (no spaces or newlines between tokens).
3. **Number formatting**: IEEE 754 double-precision representation; integers that fit in
   53-bit mantissa are serialised without a decimal point; `1.0` and `1` both produce `1`.
4. **String escaping**: only mandatory JSON escapes; no unnecessary `\uXXXX`.
5. **Unicode**: no Unicode normalisation (code points preserved as submitted).

The Zig canonicalisation function signature (no body):

```zig
/// Produce the RFC 8785 canonical form of the input JSON document.
/// Returns error.InvalidJson if input is not well-formed JSON.
/// Caller owns the returned slice.
pub fn canonicaliseJson(
    allocator: std.mem.Allocator,
    input:     []const u8,
) CanonicalError![]u8;

/// Compute SHA-256 of canonical JSON and return 64 lowercase hex chars.
/// Caller owns the returned slice.
pub fn computeSpecHash(
    allocator:      std.mem.Allocator,
    canonical_json: []const u8,
) CanonicalError!SpecHash;
```

### spec_hash Covers orchestrator_principal

The `orchestrator_principal` field is part of `spec_body` that the submitter provides.
Because `spec_hash = SHA-256(canonical(spec_body))` and `spec_body` includes
`orchestrator_principal`, a spec cannot be re-registered under a different orchestrator
identity without producing a different `spec_hash` (satisfying the SBX-02 coverage AC).

### Immutability Enforcement

- There is no `PUT`, `PATCH`, or `UPDATE` route on `task_specs`.
- Any attempt to register a spec whose `spec_body` differs from an existing row but
  where the caller sends an `attempt_count_regressed` or update intent: the platform
  registers a new row with a new `task_spec_id` and new `spec_hash`.
- If an explicit update is somehow attempted (e.g. direct API call to a non-existent
  update route), the platform returns 409 `task_spec_immutable` rather than 404, to
  prevent probing whether the spec exists.

### Hash Equality Verification

When an artifact is submitted:
1. The submitted `spec_hash` is matched against `task_specs.spec_hash` in the
   tenant's visible rows.
2. If no row matches: 404 `task_spec_not_found`.
3. If a row matches: the `task_spec_id` from that row is used as the FK in the artifact row.
4. The platform does NOT re-compute the hash from the stored `spec_body` on the read path;
   it trusts `spec_hash` as the primary lookup key.

---

## Dependencies

| Module | Direction | Reason |
|---|---|---|
| `src/api/errors.zig` | calls | RFC 9457 Problem Details builder |
| `src/audit/` | calls | ArtifactSubmissionRejected event write |
| `src/db/` (pg pool) | calls | SQL execution |
| deployment config module | reads | EnvironmentClass lookup |
| SHA-256 stdlib | calls | spec_hash computation |
| RFC 8785 canonicaliser | calls | canonical JSON for spec_hash |

This module must NOT depend on:
- `src/simulation/` or any simulation-context types
- The process-engine or definition-store modules (artifact submission is independent of BPM execution)
- Any module that reads tenant identity from request headers (environment class comes from config, not request)

---

## Error Taxonomy

| HTTP Status | code slug | Trigger |
|---|---|---|
| 400 | `unknown_artifact_kind` | `kind` not in {test_report, design_artifact, patch_set, scenario_run} |
| 403 | `wrong_environment` | Deployment is production; fires before payload parse |
| 404 | `task_spec_not_found` | Submitted `spec_hash` matches no `task_specs` row in tenant |
| 409 | `spec_hash_mismatch` | Re-hit of idempotency triple with a different `spec_hash` |
| 409 | `attempt_count_regressed` | Submitted `attempt_count` < MAX stored for the tenant+spec |
| 409 | `task_spec_immutable` | Attempt to update an existing `task_specs` row |
| 422 | `artifact_payload_invalid` | Payload fails the schema selected by `kind` (closed schema) |

All error responses are RFC 9457 Problem Details with `type`, `title`, `status`, `detail`,
and a platform extension field `code` carrying the slug above.

---

## Open Questions

None. All acceptance criteria are covered by the design above.

---

## Migration Artefact Reference

- **No change** to migration 1170 (`task_specs` table is sufficient as-is).
- **New migration** required: `1171_agt01_03_agent_artifacts.sql`
  - `-- scope: staging_only`
  - Creates `staging` schema + `staging.agent_artifacts` table
  - Creates `uq_aa_idempotency`, `idx_aa_kind`, `idx_aa_tenant_spec`
