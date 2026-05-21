# BPM Platform — Backend Architecture Description

**Version:** 0.1-draft · 2026-05-20  
**Based on:** BPM_Platform_Functional_Requirements.md v0.2-draft

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Technology Stack](#2-technology-stack)
3. [High-Level Component Map](#3-high-level-component-map)
4. [Process Boundaries & Data Flow](#4-process-boundaries--data-flow)
5. [Database Schema](#5-database-schema)
6. [Component Details](#6-component-details)
   - 6.1 [HTTP Server & Request Pipeline](#61-http-server--request-pipeline)
   - 6.2 [Event Store](#62-event-store)
   - 6.3 [Process Definition Registry](#63-process-definition-registry)
   - 6.4 [Execution Engine](#64-execution-engine)
   - 6.5 [Task Manager](#65-task-manager)
   - 6.6 [Scheduler](#66-scheduler)
   - 6.7 [Identity & Authorization](#67-identity--authorization)
   - 6.8 [Observability Subsystem](#68-observability-subsystem)
   - 6.9 [Webhook Dispatcher](#69-webhook-dispatcher)
   - 6.10 [Dead Letter Queue](#610-dead-letter-queue)
7. [Cross-Cutting Concerns](#7-cross-cutting-concerns)
8. [Deployment Model](#8-deployment-model)
9. [Stage-by-Stage Build Plan](#9-stage-by-stage-build-plan)
10. [Open Questions & Risks](#10-open-questions--risks)

---

## 1. System Overview

The BPM Platform is an event-sourced process execution kernel. Its single responsibility is to faithfully execute directed process graphs while maintaining a tamper-evident, replayable audit trail of every state change. All domain logic (ERP, CRM, HRM) lives above the platform API boundary.

**Core architectural commitments:**

| Principle | Realisation |
|---|---|
| Event sourcing as ground truth | `events` table is append-only; all derived state is rebuilt by replaying it |
| Crash safety | Every write is a single atomic PostgreSQL transaction |
| Pure execution kernel | The transition function `(Snapshot, State, Event) → State` has zero I/O |
| Platform / application separation | No domain concepts leak below the REST API boundary |

---

## 2. Technology Stack

| Concern | Choice | Rationale |
|---|---|---|
| Language | **Zig** (latest stable) | Deterministic memory, no GC pauses, explicit control flow |
| HTTP layer | **http.zig** (karlseguin) | Lightweight, idiomatic Zig, non-blocking I/O |
| Database driver | **pg.zig** (karlseguin) | Native PostgreSQL binary protocol, prepared statements |
| Database | **PostgreSQL 15+** | ACID, advisory locks, `SKIP LOCKED` for scheduler, JSONB indexing |
| Expression evaluator | **CEL (Common Expression Language)** — embedded interpreter | Gateway condition evaluation; no external evaluator process |
| Configuration | Environment variables | Twelve-factor compatible; validated at startup |
| Serialisation | JSON (stdlib) | API bodies, event payloads, definition graphs |
| Observability | Prometheus text exposition format | `GET /metrics` scrape target |

---

## 3. High-Level Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                        BPM Platform Process                      │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  HTTP Request Pipeline                   │    │
│  │  [TLS Termination] → [Auth/RBAC] → [Validation] → [Router] │  │
│  └──────────────────────────┬──────────────────────────────┘    │
│                              │                                    │
│        ┌─────────────────────┼──────────────────────┐           │
│        ▼                     ▼                       ▼           │
│  ┌──────────┐        ┌──────────────┐        ┌────────────┐     │
│  │Definition│        │  Execution   │        │    Task    │     │
│  │ Registry │        │   Engine     │        │  Manager   │     │
│  └──────────┘        └──────┬───────┘        └────────────┘     │
│                             │                                    │
│                      ┌──────▼───────┐                           │
│                      │  Event Store │                            │
│                      └──────┬───────┘                           │
│                             │                                    │
│  ┌──────────┐        ┌──────▼───────┐        ┌────────────┐     │
│  │Scheduler │        │  PostgreSQL  │        │  Identity  │     │
│  │ Thread   │◄──────►│  (primary)   │◄──────►│  Registry  │     │
│  └──────────┘        └─────────────┘        └────────────┘     │
│                                                                   │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────┐     │
│  │  Observability│  │   Webhook    │   │  Dead Letter    │     │
│  │  (metrics,   │  │  Dispatcher  │   │  Queue (DLQ)    │     │
│  │   audit log) │  └──────────────┘   └─────────────────┘     │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
              │                                 │
              ▼                                 ▼
       External callers                 External systems
       (REST clients)                 (webhooks, service tasks)
```

---

## 4. Process Boundaries & Data Flow

### 4.1 Starting a process instance

```
Client
  │ POST /instances {definition_id, correlation_key, variables}
  │
  ▼
Auth/RBAC middleware  ── 401/403 if unauthorized
  │
  ▼
Input validator       ── 422 if payload invalid
  │
  ▼
Definition Registry   ── load definition snapshot
  │
  ▼
Execution Engine      ── pure: compute initial state (START node → first task)
  │
  ▼
Event Store           ┐
  ATOMIC TRANSACTION  │  INSERT instance row (projection)
  │                   │  INSERT event: INSTANCE_STARTED
  │                   │  INSERT event: TASK_ACTIVATED (first task)
  │                   │  INSERT task row (status = PENDING)
  └───────────────────┘
  │
  ▼
Webhook Dispatcher    ── async: fire instance.started, task.activated
  │
  ▼
Client ← 201 {instance_id, task_id}
```

### 4.2 Completing a task

```
Client
  │ POST /tasks/:id/complete {output_variables}
  │
  ▼
Auth/RBAC + ownership check
  │
  ▼
Execution Engine (pure)
  │  load InstanceState (from projection cache or event replay)
  │  apply variable collision policy (EE-09)
  │  evaluate outgoing edge conditions (CEL)
  │  compute NewInstanceState
  │
  ▼
Event Store ATOMIC TRANSACTION
  │  INSERT TASK_COMPLETED event
  │  INSERT VARIABLE_OVERWRITTEN events (if any)
  │  INSERT next TASK_ACTIVATED event(s) / INSTANCE_COMPLETED / EXECUTION_ERROR
  │  UPDATE projection tables
  │  UPDATE task rows
  │  (De)arm timers if applicable
  │
  ▼
Webhook Dispatcher ── async outbound calls
  │
  ▼
Client ← 200 {updated_instance_state}
```

### 4.3 Timer firing (scheduler)

```
Scheduler Thread (background, every ~5 s + jitter)
  │
  ▼
SELECT timers WHERE fire_at <= now() FOR UPDATE SKIP LOCKED
  │  (advisory lock ensures single-node firing in cluster)
  │
  ▼
For each due timer:
  ATOMIC TRANSACTION
  │  mark timer FIRED
  │  append TIMER_FIRED event to event log
  │  drive Execution Engine (pure) → compute next state
  │  update projection tables
  │
  ▼
If all retries exhausted → move to DLQ
```

---

## 5. Database Schema

All migrations are versioned, idempotent SQL files applied in sequence. Migration state is tracked in a `schema_migrations` table.

### 5.1 Core tables

```sql
-- Migration 001: Event log (ground truth)
CREATE TABLE events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence_num    BIGINT GENERATED ALWAYS AS IDENTITY,  -- global ordering
    instance_id     UUID NOT NULL,
    event_type      TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}',
    metadata        JSONB NOT NULL DEFAULT '{}',          -- trace IDs, source tags
    actor_id        UUID,
    idempotency_key TEXT UNIQUE NOT NULL,                 -- global scope
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_instance_seq ON events (instance_id, sequence_num);
CREATE INDEX idx_events_global_seq   ON events (sequence_num);            -- global stream

-- Large payload side table (payloads > 4 KB; NFR-05)
CREATE TABLE event_payloads_overflow (
    event_id  UUID PRIMARY KEY REFERENCES events(event_id),
    payload   JSONB NOT NULL
);

-- Migration 002: Event type registry
CREATE TABLE event_type_registry (
    event_type      TEXT PRIMARY KEY,
    schema_version  INT NOT NULL DEFAULT 1,
    json_schema     JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Migration 003: Event archive (ES-07)
CREATE TABLE events_archive (LIKE events INCLUDING ALL);

-- Migration 004: Process definitions
CREATE TABLE definitions (
    definition_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    version_string  TEXT NOT NULL,
    description     TEXT,
    graph           JSONB NOT NULL,   -- {nodes: [...], edges: [...]}
    status          TEXT NOT NULL CHECK (status IN ('DRAFT','ACTIVE','DEPRECATED','ARCHIVED')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (name, version_string)
);
CREATE INDEX idx_definitions_name_status ON definitions (name, status);

-- Migration 005: Instance projection (derived state; rebuildable from events)
CREATE TABLE instances (
    instance_id       UUID PRIMARY KEY,
    definition_id     UUID NOT NULL REFERENCES definitions(definition_id),
    definition_snapshot JSONB NOT NULL,   -- copy of graph at start time (PD-08)
    correlation_key   TEXT,
    status            TEXT NOT NULL CHECK (status IN ('ACTIVE','COMPLETED','CANCELLED','ERROR')),
    variables         JSONB NOT NULL DEFAULT '{}',
    active_tokens     JSONB NOT NULL DEFAULT '[]',   -- array of node_ids
    last_event_seq    BIGINT NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (definition_id, correlation_key)
);

-- Migration 006: Tasks
CREATE TABLE tasks (
    task_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id   UUID NOT NULL REFERENCES instances(instance_id),
    node_id       TEXT NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('PENDING','COMPLETED','CANCELLED')),
    assignee_type TEXT CHECK (assignee_type IN ('USER','GROUP','ROLE')),
    assignee_ref  TEXT,
    form_schema   JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    completed_by  UUID
);
CREATE INDEX idx_tasks_instance    ON tasks (instance_id);
CREATE INDEX idx_tasks_assignee    ON tasks (assignee_type, assignee_ref) WHERE status = 'PENDING';

-- Migration 007: Timers
CREATE TABLE timers (
    timer_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id   UUID NOT NULL REFERENCES instances(instance_id),
    node_id       TEXT NOT NULL,
    fire_at       TIMESTAMPTZ NOT NULL,
    fired_at      TIMESTAMPTZ,
    cancelled_at  TIMESTAMPTZ,
    status        TEXT NOT NULL CHECK (status IN ('PENDING','FIRED','CANCELLED')),
    is_late_fire  BOOLEAN NOT NULL DEFAULT FALSE,
    recurrence    TEXT,   -- ISO 8601 repeat interval (SCH-07)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_timers_due ON timers (fire_at) WHERE status = 'PENDING';

-- Migration 008: Identity
CREATE TABLE users (
    user_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username     TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    email        TEXT UNIQUE NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE groups (
    group_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
    group_id UUID REFERENCES groups(group_id),
    user_id  UUID REFERENCES users(user_id),
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE roles (
    role_name TEXT PRIMARY KEY   -- PLATFORM_ADMIN | PROCESS_DESIGNER | PROCESS_OPERATOR | TASK_WORKER
);

CREATE TABLE user_roles (
    user_id   UUID REFERENCES users(user_id),
    role_name TEXT REFERENCES roles(role_name),
    PRIMARY KEY (user_id, role_name)
);

CREATE TABLE api_tokens (
    token_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash  TEXT UNIQUE NOT NULL,  -- bcrypt/SHA-256 hash; plaintext never stored
    user_id     UUID NOT NULL REFERENCES users(user_id),
    roles       TEXT[] NOT NULL,
    expires_at  TIMESTAMPTZ,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Migration 009: Audit log
CREATE TABLE audit_log (
    audit_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id       UUID,
    action         TEXT NOT NULL,
    resource_type  TEXT NOT NULL,
    resource_id    UUID NOT NULL,
    before_state   JSONB,
    after_state    JSONB,
    trace_id       UUID NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_resource ON audit_log (resource_type, resource_id);
CREATE INDEX idx_audit_actor    ON audit_log (actor_id);

-- Migration 010: Dead letter queue
CREATE TABLE dead_letter_items (
    dlq_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_type   TEXT NOT NULL CHECK (source_type IN ('EVENT','TIMER','SERVICE_TASK','WEBHOOK')),
    source_id     UUID NOT NULL,
    instance_id   UUID,
    context       JSONB NOT NULL,
    failure_reason TEXT NOT NULL,
    retry_count   INT NOT NULL DEFAULT 0,
    status        TEXT NOT NULL CHECK (status IN ('PENDING','RETRYING','DISCARDED','RESOLVED')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at   TIMESTAMPTZ
);

-- Migration 011: Webhook subscriptions
CREATE TABLE webhook_subscriptions (
    subscription_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_url      TEXT NOT NULL,
    event_filter    TEXT[] NOT NULL,  -- e.g. ['instance.started','task.completed']
    hmac_secret     TEXT NOT NULL,    -- stored encrypted at rest
    status          TEXT NOT NULL CHECK (status IN ('ACTIVE','PAUSED')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Migration 012: Retention policies (ES-07)
CREATE TABLE event_retention_policies (
    event_type      TEXT PRIMARY KEY REFERENCES event_type_registry(event_type),
    policy_type     TEXT NOT NULL CHECK (policy_type IN ('FOREVER','KEEP_DAYS','KEEP_COUNT')),
    policy_value    INT   -- NULL for FOREVER; N for KEEP_DAYS / KEEP_COUNT
);
```

### 5.2 Index strategy

- Primary lookup: `events(instance_id, sequence_num)` — event replay
- Global stream: `events(sequence_num)` — projection rebuilds
- Scheduler hot path: `timers(fire_at) WHERE status='PENDING'` — partial index
- Task worker queue: `tasks(assignee_type, assignee_ref) WHERE status='PENDING'` — partial index
- Definition lookup: `definitions(name, status)` — find active version by name

---

## 6. Component Details

### 6.1 HTTP Server & Request Pipeline

**Built on:** `http.zig`

Every inbound request passes through a fixed middleware chain in order:

```
[1] Trace ID injection        — generate UUID, attach to request context, emit X-Trace-Id header
[2] Structured log open       — log method, path, trace_id at DEBUG
[3] Auth middleware           — extract Bearer token, validate hash against api_tokens table
                                 → 401 if missing/invalid; populate request context with actor + roles
[4] RBAC middleware           — check actor roles against resource + action permission matrix
                                 → 403 if insufficient
[5] Rate limiter              — sliding-window counter keyed by token_id in-memory (API-10)
                                 → 429 + Retry-After if exceeded
[6] Body parser               — deserialise JSON; enforce max body size
[7] Input validator           — validate against per-endpoint schema → 422 RFC 9457 on failure
[8] Route handler             — dispatch to subsystem
[9] Audit writer              — on state-changing verbs (POST/PUT/PATCH/DELETE), write audit_log row
[10] Structured log close     — log status code, latency, trace_id at INFO
```

**Bootstrap token (Stage 4):** When `BPM_BOOTSTRAP_TOKEN` is set and `BPM_ENV != production`, the auth middleware accepts that raw token value and grants `PLATFORM_ADMIN`. On `BPM_ENV=production` with this variable set, the process exits with a fatal log message at startup.

**Error format (RFC 9457):**

```json
{
  "type": "https://bpm.platform/errors/validation-failed",
  "title": "Validation Failed",
  "status": 422,
  "trace_id": "...",
  "errors": [
    {"field": "graph.nodes[2].assignee_type", "message": "must be USER, GROUP, or ROLE"}
  ]
}
```

---

### 6.2 Event Store

**Responsibility:** Durable, ordered, idempotent append of typed events; global and per-instance read streams.

**Key operations:**

| Operation | Implementation |
|---|---|
| `append(instance_id, event_type, payload, actor_id, idempotency_key, metadata)` | Single `INSERT` inside caller's transaction; unique constraint on `idempotency_key` handles deduplication (ON CONFLICT DO NOTHING + return existing row) |
| `read(instance_id, from_seq?, to_seq?, to_timestamp?)` | `SELECT … WHERE instance_id = $1 AND sequence_num BETWEEN $2 AND $3 ORDER BY sequence_num` |
| `read_global(from_seq?)` | `SELECT … ORDER BY sequence_num` — used for projection rebuilds |
| `validate_event_type(event_type, payload)` | Load JSON Schema from `event_type_registry`; validate with embedded JSON Schema validator; return structured errors |

**Large payload handling (NFR-05):** Before insert, measure serialised payload size. If `> 4 KB`, store in `event_payloads_overflow` and set `payload` in the main table to `{"$ref": "overflow"}`. Reads transparently JOIN and reconstruct the full payload.

**Archival background job (ES-07):** A low-priority goroutine (Zig thread) wakes hourly, scans `event_retention_policies`, and moves qualifying events to `events_archive` within a transaction. The job acquires a PostgreSQL advisory lock to prevent concurrent runs on multiple nodes.

---

### 6.3 Process Definition Registry

**Responsibility:** Create, version, validate, lifecycle-manage, and retrieve definition graphs.

**Graph validation pipeline (PD-02):**

```
1. Deserialise graph JSON → internal node/edge representation
2. Check: exactly one START node
3. Check: at least one END node
4. Check: no duplicate node IDs
5. Check: all edge source/target IDs reference existing nodes
6. Check: no isolated nodes (every node has ≥1 edge in or out, except START/END)
7. Check: no cycles outside gateway paths (DFS with visited/recursion sets)
8. Check: node count ≤ 500; edge count ≤ 2,000
9. Check: required attributes present per node type (PD-05)
10. Check: EXCLUSIVE_GATEWAY outgoing edge CEL expressions parse without error (PD-06)
11. Check: EXCLUSIVE_GATEWAY has at most one default edge (is_default=true)
Return: []ValidationError or OK
```

**Lifecycle state machine:**

```
DRAFT ──activate──► ACTIVE ──(new version activated)──► DEPRECATED
  │                   │
  └──delete(hard)     └──archive──► ARCHIVED (terminal)
```

Transition rules are enforced at the database level via a `CHECK` constraint on valid `(old_status, new_status)` pairs, with the application layer providing the business guard (e.g. only one ACTIVE per name).

**Definition snapshot (PD-08):** At instance start, the full `graph` JSON is copied into `instances.definition_snapshot`. The definition registry is never queried again for that instance's execution.

---

### 6.4 Execution Engine

**Responsibility:** The pure, I/O-free core of the platform. Given a definition snapshot, current instance state, and a triggering event, produce the new instance state.

**Pure transition function signature (Zig):**

```zig
pub fn transition(
    alloc: std.mem.Allocator,
    snapshot: DefinitionSnapshot,
    state:    InstanceState,
    event:    Event,
) TransitionError!InstanceState
```

- No database calls, no network calls, no logging inside this function.
- All logging and persistence is done by the caller (orchestrator layer) wrapping this function.
- This function is the target for comprehensive unit tests before any persistence integration (per EE-02).

**InstanceState structure:**

```zig
pub const InstanceState = struct {
    instance_id:   Uuid,
    status:        InstanceStatus,     // ACTIVE | COMPLETED | CANCELLED | ERROR
    active_tokens: []NodeId,           // concurrent execution positions
    variables:     std.json.ObjectMap, // mutable variable map
    last_seq:      u64,
};
```

**Transition rules by event type:**

| Event | Engine action |
|---|---|
| `INSTANCE_STARTED` | Place token on START node; activate next node(s) |
| `TASK_COMPLETED` | Remove token from task node; evaluate outgoing edges; advance token(s) |
| `TIMER_FIRED` | Advance token from timer node |
| `INSTANCE_CANCELLED` | Set all tokens nil; status → CANCELLED |
| `EXECUTION_ERROR` | Status → ERROR; tokens frozen |

**Gateway logic:**

- **EXCLUSIVE_GATEWAY:** Evaluate CEL expressions in declared edge order. Take first `true`. If none match, check for `is_default=true` edge. If still no match → produce `EXECUTION_ERROR`.
- **PARALLEL_GATEWAY (split):** Emit one token per outgoing edge simultaneously.
- **PARALLEL_GATEWAY (join):** Increment join counter. Advance only when counter equals incoming-active-branch count (branches cancelled before reaching join do not count).

**Variable collision policy (EE-09):**

```
for each (key, new_value) in task_output:
    if key not in instance.variables:
        insert key → new_value
    else if schema_defined(key) and not schema_valid(key, new_value):
        emit EXECUTION_ERROR event; abort merge; break
    else:
        emit VARIABLE_OVERWRITTEN event (key, old_value, new_value)
        overwrite key → new_value
```

**CEL evaluation context:** The variable map is bound to the `variables` identifier in the CEL environment. Expressions access fields via `variables.amount`, `variables.status`, etc. The CEL interpreter is initialised once at startup and reused.

**Error recovery (EE-10):** Instances in ERROR status are frozen. The dead letter API (OBS-05) allows operators to supply a `retry` command, which re-presents the last triggering event to the engine, or a `discard` command which terminates the instance as CANCELLED.

---

### 6.5 Task Manager

**Responsibility:** Lifecycle management of task records; assignment; completion routing back to the Execution Engine.

**Task operations:**

| Operation | Description |
|---|---|
| `activate(instance_id, node_id, assignee)` | Insert task row (PENDING); schedule escalation timer if `escalation_timer_duration` defined on node |
| `complete(task_id, output_vars, actor_id)` | Validate actor has rights; call Execution Engine (pure); persist result atomically |
| `assign(task_id, new_assignee, actor_id)` | Update assignee fields; append `TASK_ASSIGNED` event |
| `reassign(task_id, new_assignee, actor_id)` | Same as assign; separate audit entry for reassignment intent |

**Claim semantics for GROUP/ROLE assignments:** A task assigned to a group is claimed by the first worker to call `POST /tasks/:id/assign` with themselves as the assignee. Optimistic lock (compare `assignee_ref IS NULL`) prevents double-claim.

---

### 6.6 Scheduler

**Responsibility:** Background thread that polls for due timers and fires them into the Execution Engine.

**Thread lifecycle:**

```
startup
  │
  ├─ validate poll_interval config
  ├─ log "scheduler started, poll_interval=Xs, jitter=±Yms"
  │
  └─► poll loop:
        sleep(poll_interval ± jitter)
        acquire pg_try_advisory_lock(SCHEDULER_LOCK_ID)
        │  if lock not acquired: another node is running; skip cycle
        │
        SELECT * FROM timers WHERE fire_at <= now() AND status='PENDING'
          FOR UPDATE SKIP LOCKED
        │
        for each timer:
          BEGIN TRANSACTION
          │  UPDATE timers SET status='FIRED', fired_at=now(), is_late_fire=(fire_at < now()-threshold)
          │  [call Execution Engine pure function with TIMER_FIRED event]
          │  INSERT events (TIMER_FIRED)
          │  UPDATE instances projection
          │  [re-arm if recurrence defined (SCH-07)]
          COMMIT
        │
        release pg_try_advisory_lock(SCHEDULER_LOCK_ID)
```

**Missed timer recovery (SCH-05):** On startup (before entering the poll loop), the scheduler runs one unconditional sweep for all `fire_at <= now()` timers. These are fired with `is_late_fire = TRUE`.

**Failure handling:** If firing a timer fails after N retries (configurable, default 3), the timer row is moved to status `FAILED` and a DLQ entry is created.

---

### 6.7 Identity & Authorization

**Responsibility:** User and group registry; API token issuance and validation; RBAC enforcement.

**Token validation (hot path):**

1. Extract raw token from `Authorization: Bearer <token>` header.
2. SHA-256 hash the raw token.
3. `SELECT token_id, user_id, roles, expires_at, revoked_at FROM api_tokens WHERE token_hash = $1`.
4. Reject if `revoked_at IS NOT NULL` or `expires_at < now()`.
5. Attach `(user_id, roles[])` to request context.
6. **Cache:** Validated tokens are cached in-process (LRU, TTL 60s) to avoid a DB round-trip per request. Cache is invalidated on revocation via a PostgreSQL `LISTEN/NOTIFY` channel (`token_revoked`).

**Token issuance (IDN-04):**

1. Generate cryptographically random 32-byte token (base64url encoded, yielding 43-char string).
2. Compute SHA-256 hash; store hash in `api_tokens`.
3. Return plaintext token **once** in the response body — never stored or retrievable again.

**RBAC matrix enforcement:** The permission matrix (Stage 5) is encoded as a static table in the RBAC middleware. Each route handler declares its required `(resource, action)` pair. The middleware checks the intersection of the actor's roles against the allowed roles for that pair.

---

### 6.8 Observability Subsystem

**Structured logging (OBS-01):**

Every log line is a JSON object emitted to stdout:

```json
{
  "timestamp": "2026-05-20T12:34:56.789012Z",
  "level": "INFO",
  "trace_id": "550e8400-e29b-41d4-a716-446655440000",
  "component": "execution_engine",
  "message": "task completed",
  "instance_id": "...",
  "task_id": "...",
  "duration_ms": 4
}
```

Log levels: `DEBUG`, `INFO`, `WARN`, `ERROR`. Level is configurable via `BPM_LOG_LEVEL`.

**Prometheus metrics (OBS-02):**

```
# Counters
bpm_events_appended_total{event_type}
bpm_http_requests_total{method, path, status_code}
bpm_tasks_completed_total{definition_name}
bpm_dlq_items_total{source_type}

# Gauges
bpm_instances_active
bpm_timers_pending
bpm_db_pool_connections_used

# Histograms (p50/p95/p99 computed by Prometheus)
bpm_event_append_duration_seconds
bpm_http_request_duration_seconds{method, path}
bpm_db_query_duration_seconds{query_name}
bpm_state_reconstruction_duration_seconds
```

Metrics are maintained in in-process atomic counters/histograms and serialised to Prometheus text format on `GET /metrics` requests.

**Audit log (OBS-03):** The audit writer middleware (step 9 of the request pipeline) writes one `audit_log` row per state-changing request, capturing `before_state` and `after_state` as JSONB snapshots.

**Instance timeline (OBS-04):** `GET /instances/:id/timeline` replays the event log and formats a human-readable chronological sequence:

```json
[
  {"at": "2026-05-20T10:00:00Z", "type": "INSTANCE_STARTED",  "actor": "user:alice", "detail": "..."},
  {"at": "2026-05-20T10:01:23Z", "type": "TASK_ACTIVATED",    "node": "review",      "detail": "..."},
  {"at": "2026-05-20T10:05:44Z", "type": "TASK_COMPLETED",    "actor": "user:bob",   "detail": "..."}
]
```

---

### 6.9 Webhook Dispatcher

**Responsibility:** At-least-once outbound HTTP delivery of platform events to registered subscribers.

**Dispatch flow:**

1. After each successful transaction that produces a publishable event, the dispatcher receives a notification (passed directly in-process, same goroutine/thread, not via DB polling).
2. For each matching active subscription, enqueue an outbound delivery record.
3. A delivery worker pool (configurable size, default 4 workers) reads from the queue and issues HTTP POST calls with:
   - JSON body: `{event_type, instance_id, payload, timestamp}`
   - Header `X-BPM-Signature: sha256=<HMAC-SHA256(secret, body)>`
   - Timeout: 10 seconds
4. On non-2xx or timeout: exponential back-off retry (delays: 5s, 30s, 2m, 10m, 30m — 5 attempts).
5. After 5 failures: set subscription status to `PAUSED`; trigger OBS-06 alert hook.

**Delivery state** is persisted in a `webhook_deliveries` table (not listed in migrations above — added in Stage 6) to survive process restarts.

---

### 6.10 Dead Letter Queue

**Responsibility:** Durable store for unprocessable events, timer firings, service task calls, and webhook deliveries that have exhausted retries.

**DLQ API (OBS-05):**

| Endpoint | Description |
|---|---|
| `GET /dlq` | List items, paginated, filterable by source_type/instance_id/status |
| `GET /dlq/:id` | Inspect full context of one item |
| `POST /dlq/:id/retry` | Re-submit the source event/timer/call to its processor |
| `POST /dlq/:id/discard` | Mark item as DISCARDED; if tied to an instance, transition instance to CANCELLED |

Access requires `PROCESS_OPERATOR` role or above (per the permission matrix).

---

## 7. Cross-Cutting Concerns

### 7.1 Crash safety (NFR-07)

Every write path follows this invariant:

```
BEGIN TRANSACTION
  [append event(s)]
  [update projection table(s)]
  [arm/cancel timer(s) if needed]
COMMIT  ← only observable state change
```

There are no multi-step sequences that span transaction boundaries. If the process is killed between `BEGIN` and `COMMIT`, PostgreSQL rolls back automatically. If killed after `COMMIT`, the event log and projection are consistent.

### 7.2 Connection pool (DB-02, NFR-06)

Pool is initialised at startup with size from `BPM_DB_POOL_SIZE` (default 10, bounds [2, 200]). A value outside bounds causes a fatal log and `exit(1)`. Pool exhaustion returns an immediate `HTTP 503 Service Unavailable` — no request queuing or indefinite blocking.

### 7.3 Idempotency (ES-03)

The PostgreSQL unique constraint on `events.idempotency_key` is the single mechanism. The application uses `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING *`. If the returning clause returns zero rows, the existing event is fetched and returned. This is lock-free and handles concurrent duplicate submissions correctly.

### 7.4 State reconstruction (EE-11, NFR-04)

Projection tables are the primary read path. When a projection row is stale (detected by `last_event_seq` mismatch) or missing, the engine falls back to event replay:

```
SELECT * FROM events WHERE instance_id = $1 ORDER BY sequence_num
→ fold through transition function for each event
→ rebuild InstanceState
→ update projection row
```

For instances with up to 10,000 events, this must complete in ≤ 5 seconds (NFR-04). The pure transition function has no I/O, so the bottleneck is the `SELECT` scan. The `(instance_id, sequence_num)` index guarantees a sequential heap scan — acceptable for this volume.

### 7.5 Configuration & startup validation

All configuration is read from environment variables at startup. The platform validates all required config before starting the HTTP server or scheduler. Validation failures emit a structured fatal log and exit. Config keys:

| Variable | Default | Notes |
|---|---|---|
| `BPM_DB_URL` | *(required)* | PostgreSQL connection string |
| `BPM_DB_POOL_SIZE` | `10` | Bounds: 2–200 |
| `BPM_PORT` | `8080` | HTTP listen port |
| `BPM_LOG_LEVEL` | `INFO` | DEBUG/INFO/WARN/ERROR |
| `BPM_ENV` | `development` | `production` disables bootstrap token |
| `BPM_BOOTSTRAP_TOKEN` | *(none)* | Fatal if set and `BPM_ENV=production` |
| `BPM_SCHEDULER_POLL_INTERVAL_MS` | `5000` | Timer poll frequency |
| `BPM_SCHEDULER_JITTER_MS` | `500` | ±jitter applied to poll interval |
| `BPM_RATE_LIMIT_RPM` | `1000` | Requests per minute per token |
| `BPM_DLQ_MAX_RETRIES` | `3` | Before moving to dead letter store |
| `BPM_SERVICE_TASK_TIMEOUT_S` | `30` | Default HTTP timeout for service tasks |

---

## 8. Deployment Model

### 8.1 Single-node (development / small production)

```
[Load Balancer / Reverse Proxy]
          │
   [BPM Platform Process]
          │
   [PostgreSQL 15+]
```

One process handles HTTP, scheduler, and webhook dispatch. The scheduler uses a PostgreSQL advisory lock even in single-node mode (consistent code path, no special-casing).

### 8.2 Multi-node (HA production)

```
[Load Balancer]
   │       │
[Node A] [Node B]    ← identical processes; no shared in-process state
   │       │
[PostgreSQL 15+ primary]  ← single writer
       │
[Read replicas]  ← optional; used for read-heavy projection queries
```

All nodes share the same PostgreSQL instance. The scheduler advisory lock (`pg_try_advisory_lock`) ensures exactly one node fires timers per cycle. HTTP requests can be served by any node because all state lives in PostgreSQL.

**Token revocation propagation:** A `LISTEN/NOTIFY` channel broadcasts token revocations across all nodes so in-process LRU caches are invalidated promptly.

### 8.3 Migration strategy

Migrations are applied by the process itself at startup using a `schema_migrations` table to track applied versions. Migrations are idempotent. In multi-node deployments, a startup advisory lock ensures only one node runs migrations concurrently.

---

## 9. Stage-by-Stage Build Plan

| Stage | Key deliverables | Zig modules / files |
|---|---|---|
| **1** | Event Store, DB schema (001–003), connection pool, health endpoints | `src/db/pool.zig`, `src/event_store/store.zig`, `src/event_store/registry.zig`, `src/api/health.zig`, `migrations/001_*.sql` … `003_*.sql` |
| **2** | Definition Registry, graph validator, CEL syntax check | `src/definition/registry.zig`, `src/definition/validator.zig`, `src/cel/parser.zig`, `migrations/004_*.sql` |
| **3** | Execution Engine (pure), instance projection, task manager | `src/engine/transition.zig`, `src/engine/state.zig`, `src/tasks/manager.zig`, `migrations/005_006_*.sql` |
| **4** | HTTP pipeline, REST routes, auth middleware, pagination | `src/api/server.zig`, `src/api/middleware/auth.zig`, `src/api/middleware/rbac.zig`, `src/api/routes/*.zig`, `src/api/pagination.zig` |
| **5** | Scheduler, identity registry, RBAC enforcement | `src/scheduler/scheduler.zig`, `src/identity/registry.zig`, `src/identity/tokens.zig`, `migrations/007_008_*.sql` |
| **6** | Observability, webhook dispatcher, DLQ, service task, sub-process | `src/obs/logger.zig`, `src/obs/metrics.zig`, `src/obs/audit.zig`, `src/webhook/dispatcher.zig`, `src/dlq/store.zig`, `src/engine/service_task.zig` |

**Test strategy per stage:**

- **Unit tests** for all pure functions (transition function, graph validator, CEL evaluator, variable collision policy). Written before integration.
- **Integration tests** against a real PostgreSQL instance (Docker in CI) covering idempotency, crash-safety (kill + restart), and event ordering.
- **NFR benchmarks** (NFR-01, NFR-02, NFR-04) run as part of each stage gate.

---

## 10. Open Questions & Risks

| # | Question / Risk | Notes |
|---|---|---|
| 1 | **CEL interpreter availability for Zig** | No native Zig CEL library exists as of this writing. Options: (a) port a minimal CEL subset in Zig, (b) embed via C FFI (e.g. `cel-cpp` or `cel-go` via CGo bridge). Needs a spike in Stage 2. |
| 2 | **JSON Schema validation library for Zig** | Required for event type registry (ES-05) and form schema validation. Same situation as CEL — evaluate FFI vs. pure Zig implementation. |
| 3 | **Read replica routing** | If read replicas are added (Stage 6+), the DB pool abstraction will need read/write split. Not required for initial stages; flag as an extension point. |
| 4 | **Sub-process cancellation vs. parent** | Requirements specify child ERROR → parent ERROR. What happens if the parent is cancelled while the child is running? The child should be cancelled too. This bidirectional coupling needs an explicit protocol (not yet specified in requirements). |
| 5 | **Webhook HMAC secret rotation** | No requirement currently covers rotating HMAC secrets on webhook subscriptions. Should be raised before Stage 6 implementation. |
| 6 | **OpenAPI generation (API-11)** | "Generated from code" with Zig requires either a custom code-gen step or runtime reflection. The approach (e.g. annotated route macros, separate spec-generation binary) needs design before Stage 4. |
