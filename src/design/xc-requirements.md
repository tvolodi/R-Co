# Module: Cross-Cutting Requirements (XC-01 through XC-06)

**Covers:** XC-01, XC-02, XC-03, XC-04, XC-05, XC-06  
**Files:** Multiple modules across the platform (see Affected Modules below)  
**Design Status:** Specification-only; implementation is deferred to appropriate specialist agents

---

## Module Purpose

The six cross-cutting requirements define properties that apply to the platform as a whole, cutting across all stages and subsystems. They establish:

1. **XC-01: Trace propagation** — Every action originating from a REST request, scheduler firing, or future tool invocation carries a unique trace ID through all subsystems and database writes.
2. **XC-02: Audit immutability** — Audit logs are append-only with cryptographic chaining so tampering becomes detectable and attributable.
3. **XC-03: Configuration in repository** — Platform configuration (capability defaults, tier selections, budget limits, monitoring thresholds) is versioned and activated like any other artifact.
4. **XC-04: Kernel determinism** — The core execution kernel (event append, state transitions, scheduler, task activation, audit writes) contains no LLM calls. The kernel is deterministic by design.
5. **XC-05: Deterministic replay** — Given an instance's event log and snapshotted definition and script versions, replaying Tier 1, 2, and 3 nodes produces identical state at every step. Tier 4 (LLM) nodes replay from recorded outputs.
6. **XC-06: Backwards compatibility** — A new platform version loads and continues instances created by prior versions. Definition format changes are migration-pathed.

These requirements are **not new subsystems** but rather **design principles and constraints** that affect existing subsystems and set boundaries for future work.

---

## Affected Modules & Traceability

| Requirement | Primary Affected Modules | Integration Points |
|---|---|---|
| **XC-01** | `api/middleware/trace.zig`, `obs/logger.zig`, `obs/audit.zig`, event store, scheduler, Lua execution, Wasm execution | All modules that generate structured logs or audit entries |
| **XC-02** | `obs/audit.zig`, `src/design/adp-09-tamper-evident-audit-chain.md` | Audit append path (ADP-09 is the primary implementation design) |
| **XC-03** | `repository/artifacts.zig`, `repository/activation.zig`, new `config/` module | Platform initialization, identity provider config (OIDC-03), any feature flag or threshold loading |
| **XC-04** | `engine/transition.zig`, `event_store/store.zig`, `scheduler/scheduler.zig`, `api/middleware/audit.zig`, kernel-path functions | No new module needed; constraint is enforced at design review of existing modules |
| **XC-05** | `engine/transition.zig`, `event_store/store.zig`, Lua execution environment, retention policy (ADP-11), instance timeline (OBS-04) | Replay protocol documented in engine design and test specs |
| **XC-06** | `src/design/adp-12-default-tenant-regression-suite.md`, schema migration strategy (DB-01), definition snapshot semantics (PD-08) | Migration runner (db/migrations.zig), definition versioning (PD-03, PD-04), instance snapshot immutability (PD-08) |

---

## Detailed Design: XC-01 (Trace Propagation)

### Purpose

Every action originating from an external request or internal trigger must carry a unique trace ID that propagates through all subsystems. This enables coherent end-to-end tracing and correlates related log entries, audit records, and database writes.

### Trace ID Lifecycle

```
Entry point (REST, scheduler, future tool)
    │
    ├─► generate UUID v4 if no incoming X-Trace-Id header
    ├─► or propagate incoming X-Trace-Id header value (no validation)
    │
    ▼
trace_context (thread-local)
    │
    ├─► API route handlers (read via trace_context.get())
    ├─► obs/logger.zig (emit "trace_id" field on every log entry)
    ├─► obs/audit.zig (emit trace_id on every audit row)
    ├─► event_store append (optional: store in event metadata)
    ├─► scheduler background tasks (generate/set trace_id at task start)
    ├─► Lua script execution (trace_id available as read-only global)
    ├─► Wasm module execution (trace_id available in context)
    │
    ▼
HTTP response X-Trace-Id header
Structured log entries with trace_id field
Audit rows with trace_id column (OBS-03 extension)
```

### Design Decisions

1. **Trace context is thread-local** — Each request handler thread has its own trace ID (no request-parameter passing needed across call stacks).

2. **Propagation is non-validating** — The platform accepts any string from the `X-Trace-Id` header (UUID or not) and uses it as-is. This allows upstream services to use their own trace ID schemes.

3. **Generation is uniform** — The platform generates UUID v4 for all locally-initiated requests (missing or empty header).

4. **Trace ID participates in audit** — Every audit row (OBS-03) includes the trace_id of the triggering action.

5. **Trace ID is optional in event metadata** — ES-08 allows attaching trace_id to event metadata for later correlation of events to originating requests.

### Module Changes Required

#### `src/api/middleware/trace.zig` (new)

```zig
pub const TraceIdResult = struct {
    trace_id: []const u8,        // The effective trace ID for this request
    propagated: bool,             // true if from X-Trace-Id header; false if generated
};

/// Extract trace ID from X-Trace-Id header or generate UUID v4.
pub fn extractOrGenerate(
    allocator: std.mem.Allocator,
    x_trace_id_header: ?[]const u8,
) error{OutOfMemory}!TraceIdResult;

/// Generate UUID v4 string (36 chars) into provided buffer.
pub fn generateUuidV4(buf: *[36]u8) void;
```

**Invariants:**
- `extractOrGenerate()` always returns a non-empty trace_id.
- Trace ID is allocated and freed by the trace middleware; caller must `defer allocator.free(trace_id)`.
- Generation uses `std.crypto.random` (CSPRNG).

#### `src/api/trace_context.zig` (new)

```zig
/// Thread-local storage for current request's trace ID.
pub threadlocal var _current: []const u8 = "";

/// Return active trace ID for current thread. Returns "" outside request context.
pub fn get() []const u8;

/// Set active trace ID. Called only by trace middleware at request start.
pub fn set(id: []const u8) void;

/// Clear active trace ID. Called by trace middleware after response.
pub fn clear() void;
```

#### `src/api/errors.zig` (extend)

```zig
pub const ProblemDetails = struct {
    type: []const u8,
    title: []const u8,
    status: u16,
    detail: []const u8,
    trace_id: []const u8 = "",  // NEW: defaults to ""
};

/// Serialise to JSON. Resolves trace_id from trace_context.get() if not explicitly set.
pub fn serialise(allocator: std.mem.Allocator, p: ProblemDetails) error{OutOfMemory}![]const u8;
```

#### `src/obs/logger.zig` (extend)

Every structured log entry MUST include a `"trace_id"` field sourced from `trace_context.get()`:

```zig
pub fn logInfo(
    allocator: std.mem.Allocator,
    message: []const u8,
    fields: struct { /* application-defined fields */ },
) !void {
    const trace_id = trace_context.get();
    // Emit JSON: {"level":"INFO", "message":"...", "trace_id":"<value>", ...fields}
}
```

#### `src/obs/audit.zig` (extend)

The audit table (OBS-03) schema gains a `trace_id` column (nullable for pre-XC-01 rows):

```sql
ALTER TABLE audit_log ADD COLUMN trace_id TEXT NULL;
```

Every audit append must include the trace_id from `trace_context.get()`:

```zig
pub fn appendAuditInTx(
    tx: *db.Tx,
    actor_id: Uuid,
    action: []const u8,
    resource_type: []const u8,
    resource_id: Uuid,
    before_state: ?[]const u8,
    after_state: ?[]const u8,
    // NEW: trace_id sourced from trace_context.get()
) !AuditRecord;
```

#### `src/scheduler/scheduler.zig` (extend)

Background scheduler tasks that fire timers or manage recurring events MUST set their own trace ID:

```zig
// At task start:
const trace_id = try generateSchedulerTraceId(allocator);
trace_context.set(trace_id);
defer {
    trace_context.clear();
    allocator.free(trace_id);
}

// Now all log calls and audit writes within this task carry the trace_id.
```

#### Lua and Wasm execution contexts (future stages)

When Lua (Stage 8) and Wasm (Stage 9) are introduced:

- **Lua:** The trace_id is available as a read-only global `platform.trace_id` accessible to scripts.
- **Wasm:** The trace_id is passed in the execution context and accessible via an ABI call.

### XC-01 Acceptance Criteria

1. **End-to-end trace query:** Given a single API request, querying logs and audit entries by trace_id returns all related entries in coherent timeline order.
2. **Trace ID always present:** Every structured log entry has a `trace_id` field; every audit row has a non-null `trace_id` (post-migration).
3. **HTTP response header:** The `X-Trace-Id` response header is set on every response, including 401 (auth failure) and 5xx errors.
4. **Scheduler tasks:** Timer firings and scheduler background jobs have distinct trace IDs that do not collide with request IDs.

---

## Detailed Design: XC-02 (Audit Immutability)

### Purpose

Audit entries must be append-only and cryptographically chained so post-insertion tampering is detectable.

### Design Reference

**XC-02 is fully specified in `/src/design/adp-09-tamper-evident-audit-chain.md`.**

This document (XC-02 section) summarizes the key points:

### Audit Chain Properties

1. **Append-only semantics** — No UPDATE or DELETE on committed audit rows. The audit table is insert-only.

2. **Cryptographic chaining** — Each audit row (after migration to XC-02) includes:
   - `chain_hash`: SHA-256 hex of a canonical audit payload + predecessor hash
   - `prev_chain_hash`: Hash of the immediate predecessor in tenant-scoped order

3. **Tamper detection** — Recomputing hashes for all rows reveals the first tampered row (chain mismatch) and marks all descendants suspect.

4. **Per-tenant chains** — Each tenant has an independent chain. Different tenants' rows do not cross-reference.

5. **Legacy compatibility** — Pre-migration audit rows have `chain_hash = NULL` and `prev_chain_hash = NULL`. Chain validation begins at the first post-migration row and treats legacy rows as pre-chain history.

### Module Changes Required

#### `src/obs/audit.zig` schema migration

```sql
ALTER TABLE audit_log
  ADD COLUMN chain_hash TEXT NULL,
  ADD COLUMN prev_chain_hash TEXT NULL;

CREATE INDEX idx_audit_chain_lookup 
  ON audit_log(tenant_id, created_at, audit_id)
  WHERE chain_hash IS NOT NULL;
```

#### `src/obs/audit.zig` (extend with chain functions)

Per ADP-09 design:

```zig
pub const AuditChainCanonicalInput = struct { /* ... */ };
pub const AuditChainWriteInput = struct { /* ... */ };
pub const AuditChainValidationFilter = struct { /* ... */ };
pub const AuditChainValidationReport = struct { /* ... */ };

pub fn normalizeAuditCanonicalInput(...) AuditChainError!AuditChainCanonicalInput;
pub fn encodeAuditCanonicalBytes(...) AuditChainError![]const u8;
pub fn computeAuditChainHashHex(...) AuditChainError![64]u8;
pub fn selectPreviousChainHashForTenant(...) AuditChainError!?[64]u8;
pub fn appendAuditRowWithChainInTx(...) AuditChainError!AuditRecord;
pub fn validateAuditChain(...) AuditChainError!AuditChainValidationReport;
```

### XC-02 Acceptance Criteria

1. **Deterministic canonicalization** — Identical audit content always produces identical hash across repeated runs and key-order permutations.
2. **Per-tenant chaining** — First chained row in tenant has null `prev_chain_hash`; second row links to first; different tenants do not cross-reference.
3. **Tampered-row detection** — Injecting a tampered row into a committed chain breaks validation at the tampered row and marks descendants suspect.
4. **Legacy compatibility** — Pre-migration rows with null chain fields are accepted as legacy; chain validation begins at first non-null chained row per tenant.

---

## Detailed Design: XC-03 (Configuration in Repository)

### Purpose

Platform configuration (capability defaults, tier-selection rules, budget limits, monitoring thresholds) is stored as versioned artifacts in the repository and activated like any other artifact. This replaces ad-hoc environment-variable loading and unifies configuration lifecycle with artifact lifecycle.

### Configuration Artifacts

Configuration is stored as JSON artifact kind `"config"` in the repository:

| Configuration Category | Artifact Name | Example Content |
|---|---|---|
| **Capability defaults** | `capabilities` | `{"tier1_node_timeout_ms": 30000, "tier2_timeout_ms": 120000, ...}` |
| **Tier selection rules** | `tier_rules` | `{"lr_model_selector": "size_based", "rules": [...]}` |
| **Budget limits** | `budget_limits` | `{"llm_tokens_per_day": 1000000, "service_calls_per_minute": 1000, ...}` |
| **Monitoring thresholds** | `monitoring_config` | `{"alert_on_latency_p99_ms": 500, "alert_on_error_rate": 0.05, ...}` |
| **Identity provider config** | `oidc_config` (extends OIDC-03) | `{"providers": [{"issuer": "...", "client_id": "..."}]}` |

### Configuration Activation Flow

```
Developer / Operator
    │
    ├─► Prepare new configuration artifact (JSON)
    │   (e.g., update monitoring thresholds)
    │
    ▼
POST /repository/artifacts
    {
      "kind": "config",
      "name": "monitoring_config",
      "content": { "alert_on_latency_p99_ms": 600 },
      "description": "Increased latency threshold per on-call decision"
    }
    │
    ├─► Returns 201 with version_id
    │
    ▼
POST /tenants/{tenant_id}/activate
    {
      "activations": [
        {
          "artifact_kind": "config",
          "artifact_name": "monitoring_config",
          "target_version_id": "<version_id>"
        }
      ]
    }
    │
    ├─► Atomically activates the new configuration version
    ├─► Writes audit_log entry with action="configuration.activate"
    │
    ▼
Platform initialization (src/main.zig)
    │
    ├─► Load active configuration artifacts from repository
    ├─► Build in-memory configuration state from activated versions
    ├─► Apply configuration at runtime (capability timeouts, budget limits, etc.)
    │
    ▼
Running platform with new configuration
    │
    └─► No restart required (configuration is read on demand, not cached)
```

### Module Changes Required

#### New `src/config/` module

```zig
// src/config/loader.zig
pub const PlatformConfig = struct {
    capabilities: CapabilityConfig,
    tier_rules: TierSelectionRules,
    budget_limits: BudgetLimits,
    monitoring: MonitoringConfig,
    identity_providers: []IdentityProvider,
};

pub fn loadActiveConfig(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: Uuid,
) ConfigError!PlatformConfig;

pub const ConfigError = error{
    ConfigNotFound,
    ConfigParseError,
    ConfigValidationError,
    DatabaseError,
    OutOfMemory,
};
```

#### `src/main.zig` (extend)

```zig
// At startup:
const config = try config_loader.loadActiveConfig(allocator, pool, default_tenant_id);

// Store config in application state (passed to handlers):
pub const AppState = struct {
    pool: *db.Pool,
    config: PlatformConfig,  // NEW
    // ... other fields
};
```

#### `src/repository/artifacts.zig` (extend)

The repository already supports arbitrary artifact kinds via the `kind` parameter. Configuration artifacts are treated as any other artifact:
- Stored under SHA-256 hash (REPO-01, REPO-02)
- Versioned with parent linkage (REPO-03)
- Immutable after commit (REPO-02)
- Activated per tenant atomically (REPO-08, REPO-09)

No schema changes needed beyond what REPO-* requirements already specify.

#### Validation of configuration artifacts

When a configuration artifact is uploaded, `POST /repository/artifacts` performs schema validation:

```zig
pub fn validateConfigArtifact(
    content_json: []const u8,
    config_name: []const u8,  // e.g., "monitoring_config"
) ConfigError!void {
    // Validate structure against expected schema for this config kind
    // E.g., "monitoring_config" must have keys: alert_on_latency_p99_ms, etc.
}
```

### Configuration Read at Runtime

Configuration is **not cached in memory**. Every module that reads configuration calls:

```zig
const config = try repository.getActiveConfigArtifact(
    allocator,
    pool,
    tenant_id,
    "monitoring_config"
);
defer allocator.free(config);
```

This allows configuration changes to take effect without platform restart (though high-frequency reads should be wrapped in an in-process cache with TTL).

### XC-03 Acceptance Criteria

1. **Configuration as artifact** — Configuration is stored in the repository with the same versioning, immutability, and audit trail as process definitions.
2. **Atomic activation** — A configuration change activates atomically; no partial state.
3. **Per-tenant isolation** — Each tenant can have different active configuration versions.
4. **Backwards compatibility** — Platform starts without repository configuration artifacts; uses safe defaults for missing config (see XC-03 Open Questions).

---

## Detailed Design: XC-04 (Kernel Determinism)

### Purpose

The platform kernel — event append, state transition, scheduler firing, task activation, audit chaining — contains **no LLM calls**. The kernel is deterministic by design. LLM execution is permitted only within nodes whose execution tier is explicitly Tier 4 (a future stage), and Tier 4 sits alongside Tiers 1–3, not inside the kernel.

### Kernel Scope

**Kernel modules (deterministic, no LLM):**
- `src/event_store/store.zig` — event append logic
- `src/engine/transition.zig` — pure state transition (zero I/O)
- `src/scheduler/scheduler.zig` — timer polling and firing
- `src/tasks/manager.zig` — task lifecycle (activate, complete, assign)
- `src/obs/audit.zig` — audit chain hash computation
- `src/db/pool.zig`, `src/db/migrations.zig` — database access

**Non-kernel (may call external services):**
- `src/api/routes/instances.zig` — HTTP routing; may call services in handlers
- `src/api/routes/events.zig` — event receipt
- Lua execution (Stage 8) — Lua scripts may call services
- Wasm execution (Stage 9) — Wasm modules may call services
- Tier 4 node execution (future) — LLM invocations happen here

### No-LLM Constraint

Enforcement is via **design review and static analysis:**

1. **Design review (CODE-DESIGNER):** Before BACKEND-DEV implements any kernel module, CODE-DESIGNER's design file explicitly states "No LLM dependencies" and lists all external service calls.

2. **Static analysis (BACKEND-DEV validation):** After implementation, BACKEND-DEV runs:
   ```bash
   grep -r "llm\|openai\|anthropic\|model_inference" src/event_store src/engine src/scheduler src/tasks src/obs/audit
   ```
   If any matches (outside comments and strings), the build fails at code review.

3. **Tier 4 isolation:** Tier 4 node execution is scoped to a future `src/tier4/` module that sits outside the kernel path.

### Determinism Definition

**Determinism:** Given the same event log, definition snapshot, and script versions, re-executing the same instance always produces the same state at every step.

**Implications:**
- `src/engine/transition.zig` is a pure function: no randomness, no I/O, no `std.time` calls.
- Event append order is strictly sequential (ES-02) and immutable (ES-01).
- Scheduler firing order is deterministic (timer order + sequence tiebreaker).
- No floating-point arithmetic in state computation (use integer arithmetic or fixed-point decimals).

### XC-04 Acceptance Criteria

1. **Static kernel analysis:** `grep` for LLM API patterns in kernel modules returns zero matches (outside comments).
2. **Pure transition function:** `src/engine/transition.zig` has no I/O, no randomness, no time calls.
3. **Deterministic scheduler:** Given the same timer state and definition, re-running the scheduler fires timers in identical order.

---

## Detailed Design: XC-05 (Deterministic Replay)

### Purpose

Given an instance's event log, the snapshotted definition, and script versions, replaying the instance through Tier 1, 2, and 3 nodes produces identical state at every step. Tier 4 nodes (future LLM calls) replay from recorded outputs without re-invoking the model.

### Replay Protocol

**Replay is initiated by:**
- `src/engine/transition.zig` using `store.pointInTime()` (ES-06) to reconstruct state as of a given sequence number or timestamp.
- Test framework (integration tests) to validate state after X events matches expected state.

**Replay reads from:**
1. Event log (live `events` table + archived `events_archive` per ADP-11) — **XC-05 depends on ADP-11 to ensure archived events are replay-accessible.**
2. Instance snapshot (`instances.definition_snapshot`) — definition is immutable per PD-08.
3. Script versions (Lua, Wasm) — snapshotted at definition creation or referenced by hash.

**Replay does NOT:**
- Re-invoke external services (SERVICE_TASK nodes replay from recorded `service_task_output` events).
- Re-query LLM models (Tier 4 nodes replay from recorded `llm_response` events).
- Re-run Lua/Wasm with side effects (scripts are pure; re-running with same inputs yields same outputs).

### State Reconstruction (EE-11)

The engine's state reconstruction function:

```zig
pub fn reconstructInstanceState(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    instance_id: Uuid,
    up_to_sequence: ?i64,  // Stop at this sequence number (ES-06)
) !InstanceState {
    // 1. Read definition snapshot from instance record (immutable, PD-08)
    const snapshot = try instances.getSnapshot(instance_id);
    
    // 2. Read all events up to the specified sequence from both live and archive
    const events = try store.pointInTime(allocator, instance_id, up_to_sequence);
    defer allocator.free(events);
    
    // 3. Apply each event in order via pure transition function
    var state = try InstanceState.init(allocator, snapshot);
    for (events) |event| {
        const new_state = try transition.apply(allocator, state, event, snapshot);
        state.deinit();
        state = new_state;
    }
    
    return state;
}
```

### Archival & Replay Compatibility (ADP-11)

ADP-11 specifies replay-safe retention policies:

- Archived events remain queryable via `pointInTime()` (state reconstruction reads from both `events` and `events_archive`).
- Archival does not delete events; it only moves them.
- Sequence numbers remain globally unique across live + archived tables.
- Archive query joins by sequence number: `SELECT * FROM events_archive WHERE instance_id = $1 AND sequence_number ≤ $2 UNION ...`

### Tier 4 (LLM) Replay Semantics (future)

When Tier 4 is introduced:

- LLM node generates a `llm_response` event upon completion (recorded output).
- Replaying the instance reads the `llm_response` event and uses its payload as the recorded result.
- The LLM is NOT re-invoked during replay.

**Design placeholder:**
```zig
// Pseudocode (exact design deferred to Tier 4 implementation)
case .Tier4LLMNode:
    // On original execution:
    const response = try callLLM(...);
    try store.append(..., .{
        .event_type = "llm_response",
        .payload = serialize(response),
        ...
    });
    
    // On replay:
    const recorded_response_event = findEventOfType("llm_response", ...);
    const response = try deserialize(recorded_response_event.payload);
    // Do NOT call LLM again
```

### XC-05 Acceptance Criteria

1. **State reconstruction determinism** — Replaying an instance with `pointInTime()` up to sequence N produces identical state (all variables, active tokens, status) to original execution.
2. **Archive compatibility** — Replay test includes instance timeline spanning both live events and archived events; final state equals pre-archival baseline.
3. **Service task recorded output** — SERVICE_TASK nodes on replay use `service_task_output` event payload; service is not re-invoked.
4. **Tier 4 future readiness** — Design placeholder documents where Tier 4 LLM response recording will fit; no LLM re-invocation on replay.

---

## Detailed Design: XC-06 (Backwards Compatibility)

### Purpose

A new platform version loads and continues instances created by the prior version. Definition format changes are migration-pathed.

### Migration Scope

**XC-06 covers:**
1. Instance schema migrations (add new columns, not destructive changes).
2. Definition format versioning (if definition graph schema changes, a migration function transforms old→new).
3. Event schema evolution (new event types; old types remain valid).
4. Event retention policy compatibility (archival does not break old instances).

**XC-06 does NOT cover:**
- Deleting instances or definitions (only archival or soft-delete).
- Dropping tables or columns.

### Instance Schema Stability

Instances are immutable once created (PD-08 snapshot), so schema backwards-compatibility is automatic:

```sql
-- Migration 1 (Version A)
CREATE TABLE instances (
    instance_id UUID PRIMARY KEY,
    definition_snapshot JSONB,
    status TEXT,
    variables JSONB,
    active_tokens JSONB,
    created_at TIMESTAMP,
    -- ...
);

-- Migration 2 (Version B) — additive only
ALTER TABLE instances ADD COLUMN trace_id TEXT NULL;
ALTER TABLE instances ADD COLUMN is_replay_safe BOOLEAN DEFAULT false;

-- Version B can load instances created by Version A without issues.
-- Null columns are expected; defaults are applied.
```

### Definition Format Evolution

If the definition graph schema changes (e.g., new node attributes), a migration function is provided:

```zig
/// Migrate a definition graph from format V1 to V2.
/// V1 graphs may not have certain fields; add defaults for V2.
pub fn migrateDefinitionV1ToV2(
    allocator: std.mem.Allocator,
    v1_graph: []const u8,  // JSON bytes
) error{ParseError, SerializeError, OutOfMemory}![]const u8 {
    // Parse V1 JSON
    const v1 = try json.parse(V1Definition, v1_graph);
    defer v1.deinit();
    
    // Build V2 graph with migration rules applied
    var v2 = V2Definition.init(allocator);
    
    // Copy over unchanged fields
    v2.nodes = v1.nodes;
    v2.edges = v1.edges;
    
    // Add new fields with defaults
    for (v2.nodes) |*node| {
        if (node.escalation_timer_duration == null) {
            node.escalation_timer_duration = "PT1H";  // default 1 hour
        }
    }
    
    // Serialize V2 JSON
    return v2.serialize(allocator);
}
```

When activating a definition that came from a prior version, the migration is run at activation time:

```zig
pub fn activateDefinition(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    artifact_version_id: Uuid,
    current_platform_version: DefinitionFormatVersion,
) !void {
    // 1. Fetch artifact content from repository
    const artifact = try repository.getArtifactContent(artifact_version_id);
    
    // 2. Detect format version
    const stored_format_version = try detectFormatVersion(artifact);
    
    // 3. If stored < current, migrate
    var current_content = artifact;
    while (stored_format_version < current_platform_version) {
        current_content = try runMigration(stored_format_version, current_content);
        stored_format_version += 1;
    }
    
    // 4. Validate and activate migrated definition
    try activateDefinitionContent(allocator, pool, current_content);
}
```

### Default Tenant Regression Suite (ADP-12)

XC-06 is validated by ADP-12 (default tenant regression test suite):

```zig
// tests/integration/backwards_compatibility_test.zig
pub fn testLoadInstanceCreatedByPriorVersion() !void {
    // 1. Create a database snapshot with instances from prior platform version
    // 2. Upgrade schema via migrations
    // 3. Load and continue each instance to completion
    // 4. Assert state matches expected trajectory (no corruption, no loss)
}
```

### Migration File Strategy (DB-01)

Migrations are versioned and idempotent:

```
migrations/
├── 001_event_store.sql            (Version A)
├── 002_event_type_registry.sql
├── ...
├── 050_add_trace_id_audit.sql     (Version B — additive)
├── 051_add_chain_hash_audit.sql
├── ...
```

Each migration:
- Is idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`).
- Adds columns; never drops.
- Is run in sequence; migration runner verifies no gaps.

### XC-06 Acceptance Criteria

1. **Instance load test** — A database with instances created by prior version is loaded and continued to completion by new version; no errors.
2. **Definition format migration** — Definitions stored in prior format are automatically migrated at activation; no manual intervention.
3. **Regression suite** — ADP-12 regression test suite passes, validating all changes for default tenant.

---

## Interactions & Dependencies

### XC-01 → XC-02

Trace IDs are included in audit entries. Every audit row includes the trace_id of the action that triggered it.

### XC-01 → XC-03

Configuration artifacts are activated via API requests that generate trace IDs. Configuration reads are logged with trace_id.

### XC-02 → XC-03

Audit entries for configuration activation are chained (XC-02).

### XC-03 → XC-04

Configuration is read at startup and during runtime request handling. No LLM calls happen during configuration loading (kernel determinism).

### XC-04 → XC-05

Kernel determinism enables deterministic replay: state transitions are pure functions with no external state.

### XC-05 → XC-06

Backwards compatibility must preserve the ability to replay old instances. Archive retention (ADP-11) must not break replay queries.

---

## Schema Changes Summary

| Requirement | Tables Affected | Columns Added | Migration File |
|---|---|---|---|
| **XC-01** | `audit_log`, `event` (optional) | `trace_id TEXT NULL`, optional metadata `trace_id` | TBD (with OBS-01 implementation) |
| **XC-02** | `audit_log` | `chain_hash TEXT NULL`, `prev_chain_hash TEXT NULL` | adp-09 migration |
| **XC-03** | None (uses existing `repository_artifacts`) | — | None (repository already supports arbitrary kinds) |
| **XC-04** | None | — | None (design constraint, no schema) |
| **XC-05** | None (uses existing archival: `events_archive`) | — | adp-11 migration (replay-safe retention) |
| **XC-06** | None (backwards compatible additions only) | — | Standard additive-only migrations (DB-01) |

---

## Error Handling & Invariants

### XC-01 Invariants

1. `trace_context.get()` always returns a valid (possibly empty) string; never null.
2. `trace_context.set()` is called at request start; `trace_context.clear()` is called at request end (via `defer`).
3. All modules importing `trace_context` are read-only (except trace middleware which sets/clears).

### XC-02 Invariants

1. `chain_hash` is always a 64-character lowercase hex string or null.
2. `prev_chain_hash` is always a 64-character hex string, null, or the special boundary value.
3. For each tenant, there is at most one chain (each row has exactly one predecessor or is the boundary).
4. Tampering is irreversible without direct SQL manipulation; chain validation reveals it.

### XC-03 Invariants

1. Configuration artifacts are immutable (REPO-02).
2. Configuration is read on-demand, not cached in memory (unless wrapped by a separate cache layer with TTL).
3. Invalid configuration artifact uploads are rejected before storage (schema validation).

### XC-04 Invariants

1. No kernel module calls LLM APIs; verified by grep and code review.
2. `src/engine/transition.zig` has no I/O, no randomness, no time calls.

### XC-05 Invariants

1. Archived events remain queryable without re-fetching from external storage.
2. Replay produces identical state (all variables, token sets, status) to original execution.
3. Tier 4 nodes record outputs in audit trail; replay never re-invokes LLM.

### XC-06 Invariants

1. No instance or definition can be deleted permanently (only archived or soft-deleted).
2. All migrations are additive or idempotent; no destructive changes.
3. New platform version supports loading instances from prior versions.

---

## Implementation Roadmap

| Requirement | Implementation Order | Depends On |
|---|---|---|
| **XC-01** | Stage 1 or 2 (early middleware) | API server (src/api/server.zig) |
| **XC-02** | Stage 6 / ADP-09 | Audit log (OBS-03) |
| **XC-03** | Stage 10 (platform repository) | Repository module (REPO-*) |
| **XC-04** | Design review at each stage | Code review process |
| **XC-05** | Stage 3+ (test suite, engine) | State reconstruction (EE-11), archival (ADP-11) |
| **XC-06** | All stages (on-going) | Migration runner (DB-01) |

---

## Open Questions

1. **XC-01 propagated trace ID length limit:** Should the platform enforce a maximum length on propagated `X-Trace-Id` header values (e.g., 256 bytes) to prevent memory exhaustion? Or accept any string and rely on HTTP header size limits?

2. **XC-03 configuration default strategy:** If a configuration artifact is not active for a tenant, does the platform (a) fail to start, (b) use hardcoded safe defaults, or (c) allow undefined config keys? Recommend (c): read-on-demand and default missing keys to safe values.

3. **XC-03 refresh cadence:** Does the platform refresh configuration from repository on every request (slow), cache with TTL (eventual consistency), or only at startup (no rollback)? Recommend: cache with 5-minute TTL for performance; allow on-demand refresh endpoint.

4. **XC-05 Tier 4 replay semantics:** Exact design for Tier 4 LLM response recording and replay is deferred to Tier 4 implementation. This section is a placeholder.

5. **XC-06 schema migration rollback:** If a migration fails during upgrade, can the platform rollback to the prior version? Recommend: all migrations are idempotent and additive; rollback is manual (restore database snapshot).

---

## Testing Strategy

| Requirement | Test Category | Example Test Case |
|---|---|---|
| **XC-01** | Integration | End-to-end trace: API request → log entry → audit row; all carry same trace_id |
| **XC-02** | Integration | Inject tampered audit row; chain validation catches it at tampered row |
| **XC-03** | Integration | Upload config artifact, activate, read on-demand; different tenant sees different config |
| **XC-04** | Unit + static analysis | Grep kernel modules for LLM keywords; pure transition function unit tests |
| **XC-05** | Integration | Replay instance up to sequence N; final state matches original execution state |
| **XC-06** | Integration (ADP-12) | Load instance from prior version; continue to completion; state matches expected |

---

## Traceability

| Acceptance Criterion | Design Section | Testability |
|---|---|---|
| End-to-end trace query returns coherent timeline | XC-01 Acceptance Criteria | Query logs/audit by trace_id; verify all entries are related |
| Audit chain validation catches tampering | XC-02 Acceptance Criteria | Inject row, run validation, verify first mismatch detected |
| Configuration artifacts follow REPO-* lifecycle | XC-03 Acceptance Criteria | Upload, version, activate, read; observe immutability and versioning |
| Kernel modules contain no LLM calls | XC-04 Acceptance Criteria | Grep + code review; pure transition function tests |
| Replay produces identical state | XC-05 Acceptance Criteria | Replay test: state hash equals pre-archival baseline |
| New version loads old instances | XC-06 Acceptance Criteria | ADP-12 regression suite: load, continue, assert no errors |

---

## Summary

The six cross-cutting requirements establish foundational properties across the platform:

- **XC-01:** Every action has a trace ID for coherent observability.
- **XC-02:** Audit logs are tamper-detectable via cryptographic chaining.
- **XC-03:** Configuration is versioned and activated like any other artifact (future Stage 10).
- **XC-04:** The kernel is deterministic and LLM-free by design (affects code review).
- **XC-05:** Instances can be deterministically replayed (depends on ES-06, ADP-11).
- **XC-06:** New versions are backwards compatible with prior versions (standard DB practices).

No single module implements all XC requirements; instead, they cut across the platform's architecture and impose constraints and design patterns on every stage.
