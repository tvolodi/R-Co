# BPM Platform — Functional Requirements Specification

**Version:** 0.2-draft · 2026-05-20

---

## Introduction

This document specifies the functional requirements for the BPM Platform — a low-level process execution kernel designed to serve as the foundation for higher-level business applications such as ERP, CRM, HRM, and others. Requirements are grouped by delivery stage, reflecting an incremental build strategy where each stage produces an independently runnable and testable system increment.

**Priority notation:**

- **MUST** — mandatory for stage completion; no release without it.
- **SHOULD** — strongly recommended; defer only with documented reason.
- **COULD** — desirable if capacity allows; safe to defer.

---

## Glossary

| Term | Definition |
|---|---|
| **Execution token** | A logical cursor representing an active position within a process instance graph. Multiple tokens exist simultaneously in parallel branches. |
| **Correlation key** | A caller-supplied string used to link a process instance to an external business entity (e.g. an order ID). Must be unique per definition. |
| **Event log** | The append-only, ordered sequence of immutable events that constitutes the ground truth of an instance's state. |
| **Projection / read model** | A derived, queryable state table built by replaying the event log. May be rebuilt at any time from the log. |
| **Instance state** | The current derived state of a process instance, including active tokens, variable map, and status — reconstructable from the event log. |
| **Definition graph** | A directed graph of nodes and edges that describes the structure of a process, consumed by the execution engine. |
| **Idempotency key** | A caller-supplied string that guarantees duplicate event submissions are deduplicated. Scoped globally across all instances. |
| **Dead letter store (DLQ)** | A durable store for events or timer firings that have exhausted their retry budget. |
| **Service task** | A node type that invokes an external HTTP endpoint as part of process execution. |
| **Sub-process** | A node type that starts a child process instance from a referenced definition, with the parent waiting for child completion. |

---

## Non-Functional Requirements

The following NFRs apply across all stages. Each stage's requirements must be validated against these targets before that stage is considered complete.

| ID | Requirement | Target |
|---|---|---|
| **NFR-01** | **API response latency (p99)** | ≤ 200 ms for read operations; ≤ 500 ms for write operations under nominal load |
| **NFR-02** | **Event append throughput** | ≥ 1,000 events/sec sustained on a single node (PostgreSQL on equivalent hardware) |
| **NFR-03** | **Availability** | ≥ 99.5% uptime measured monthly; planned maintenance excluded |
| **NFR-04** | **State reconstruction time** | Replaying an instance with up to 10,000 events SHALL complete in ≤ 5 seconds |
| **NFR-05** | **Database storage** | Event log rows SHALL be designed to fit within PostgreSQL's 8 KB page size; large payloads (> 4 KB JSON) SHALL be stored in a side table linked by reference |
| **NFR-06** | **Connection pool bounds** | Pool size MUST be between 2 and 200 (inclusive); default 10; values outside range at startup SHALL cause a fatal error with a clear message |
| **NFR-07** | **Crash safety** | The platform MUST be killable at any point without leaving the database in a partially-written state. Every write is either fully committed or fully rolled back. |

---

## Constraints & Assumptions

- **Implementation language:** Zig. Libraries: `http.zig` (karlseguin), `pg.zig` (karlseguin).
- **Database:** PostgreSQL 15+. All schema changes delivered as versioned, idempotent SQL migration files.
- **Stage ordering:** Each stage must be fully correct and tested before the next stage begins. A working Stage 3 with no scheduler is better than a half-working Stage 5.
- **Condition expression language:** Edge conditions (see PD-06, EE-05) SHALL be evaluated using [CEL (Common Expression Language)](https://cel.dev). The platform embeds a CEL interpreter; no external evaluator process is used. Variable references in expressions use dot notation against the instance variable map (e.g. `variables.amount > 1000`).
- **Out of scope for this platform:** Domain-specific logic for ERP, CRM, or HRM; user-facing UI; report generation; file storage; email/SMS delivery (notification *dispatch* is handled by external systems; the platform emits events that trigger them via webhooks).

---

## Stage 1 — Event Store & Infrastructure Foundation

**Goal:** A running process that can durably append and read immutable events to/from PostgreSQL, with a verified schema, connection pool, and health check. No business logic yet. This is the bedrock every other subsystem depends on.

---

### ES-01 — Append event `[MUST]`

> The platform SHALL append a typed, immutable event record to the event log for a given process instance. Each event carries: `event_id` (UUID v4), `instance_id`, `event_type`, `payload` (JSON), `actor_id`, and `created_at` (UTC timestamp with microsecond precision).

**Acceptance Criteria:**
- GIVEN a valid append request with all required fields, WHEN processed, THEN the platform returns HTTP 201 with the persisted event record including the platform-assigned `event_id` (UUID v4) and `created_at` (UTC, microsecond precision).
- `event_id` MUST be a version-4 UUID. No two events in the event log MAY share the same `event_id`.
- `instance_id` MUST reference an existing process instance; if the instance does not exist, the platform returns HTTP 404.
- `event_type` MUST be a non-empty string. The registry validation rule (ES-05) is applied before the record is persisted.
- `payload` MUST be a valid JSON object (not null, not a JSON array, not a scalar). An empty object `{}` is permitted. If `payload` exceeds 4 KB in serialised form, it MUST be stored in a side table with the event log row containing only a reference (per NFR-05).
- `actor_id` MUST be a non-empty string. A null or absent `actor_id` MUST be rejected with HTTP 422.
- `created_at` MUST be stored in UTC with microsecond precision. Two events appended within the same microsecond on the same instance receive distinct, monotonically increasing sequence numbers (tie-broken by sequence, not by timestamp).
- Once persisted, no field of an event record SHALL be modifiable by any API or internal operation.
- Appending an event to a CANCELLED or COMPLETED instance MUST be rejected with HTTP 409.

**See:** ES-03 (idempotency key deduplicates concurrent appends), ES-05 (type registry validates `event_type` and `payload` schema before persist), DB-03 (append and state-table update are one atomic transaction), NFR-05 (8 KB page / 4 KB payload side-table rule)

**Edge cases:**
- `payload = null`: rejected with HTTP 422.
- `payload = []` (JSON array): rejected with HTTP 422.
- `payload = {}` (empty object): accepted; no schema violation.
- `actor_id = ""` (empty string): rejected with HTTP 422.
- Payload size exactly at 4 KB: stored inline. One byte over: stored in side table.
- Concurrent appends to the same instance: serialised by row-level lock; both succeed with distinct sequence numbers.

---

### ES-02 — Ordered read `[MUST]`

> Events for an instance SHALL be retrievable in strict append order (sequence number). Concurrent reads MUST NOT return events out of sequence.

**Acceptance Criteria:**
- GIVEN an instance with N persisted events, WHEN events are retrieved, THEN they are returned sorted by ascending sequence number with no gaps.
- A read issued during a concurrent append sees only fully committed events; no partially-committed event is visible.
- Concurrent reads by multiple callers for the same instance each receive the same ordered sequence for events that have already committed.
- An attempt to read events for a non-existent instance MUST return HTTP 404.
- Sequence numbers are monotonically increasing per instance; rolled-back transactions leave no gap in the committed sequence.

**See:** ES-06 (point-in-time variant of this query), ES-04 (global stream applies the same ordering guarantee cross-instance), EE-11 (state reconstruction depends on this ordering guarantee)

**Edge cases:**
- Instance with zero events: returns an empty ordered list, HTTP 200.
- Read issued exactly as an append commits: the reader sees either N or N+1 events (snapshot isolation); never a partial state.

---

### ES-03 — Event idempotency `[MUST]`

> Each event append SHALL include a caller-supplied idempotency key. The key is **global** in scope — unique across all instances and event types. Duplicate submissions with the same key MUST be silently deduplicated and return the original event record.

**Acceptance Criteria:**
- GIVEN an append request with idempotency key K that has already committed, WHEN the same K is submitted again (any payload, any instance), THEN the platform returns HTTP 200 with the original event record unchanged; no new event is inserted.
- GIVEN an append request with a fresh key K, WHEN processed, THEN the event is persisted and HTTP 201 is returned.
- If two concurrent requests arrive with the same key before either commits, exactly one MUST commit as a new event; the other MUST be deduplicated against it. The platform MUST NOT return two distinct event records for the same key.
- Deduplication MUST be durable: a duplicate submitted after a platform restart returns the original record.
- A missing or empty idempotency key MUST be rejected with HTTP 422.
- Idempotency keys MUST be accepted up to 255 characters. Keys longer than 255 characters MUST be rejected with HTTP 422.

**See:** ES-01 (event record structure returned on deduplication), DB-03 (uniqueness enforced by database unique constraint within the transaction)

**Edge cases:**
- Same key resubmitted with a different `payload`: deduplication wins; original payload is returned, new payload is silently discarded.
- Same key resubmitted against a different `instance_id`: still deduplicated (key is global).

---

### ES-04 — Global event stream `[MUST]`

> The platform SHALL expose a global ordered stream of all events across all instances, usable for projections and read-model rebuilding.

**Acceptance Criteria:**
- GIVEN events appended across multiple instances, WHEN the global stream is queried, THEN it returns all events ordered by a global sequence number that is monotonically increasing across all instances.
- The global stream MUST support cursor-based pagination: a caller can resume from any position using an opaque cursor without re-reading earlier events.
- A caller replaying the global stream from position 0 MUST arrive at a state consistent with the union of all per-instance ordered reads (ES-02).
- The global stream includes events from all instances regardless of instance status.
- Reading the global stream MUST NOT block ongoing event appends or per-instance reads.

**See:** ES-02 (per-instance ordering is a subset of global ordering), ES-01 (event record structure in the stream), EE-11 (state reconstruction may use global stream as input)

**Edge cases:**
- Empty platform (no events): returns empty stream, HTTP 200.
- Cursor older than 24 hours (per API-06 spec): platform MUST return HTTP 410 with a message to re-query from the beginning or a known checkpoint.

---

### ES-05 — Event type registry `[MUST]`

> All event types SHALL be registered with a name, schema version, and JSON Schema. Appending an event with an unregistered or schema-invalid payload MUST be rejected with HTTP 422 and a structured error listing all validation failures, using RFC 9457 Problem Details format.

**Acceptance Criteria:**
- GIVEN an event type T with a valid JSON Schema registered, WHEN a caller appends an event with `event_type = T` and a payload valid against the schema, THEN the append proceeds normally.
- GIVEN event type T is not registered, WHEN a caller appends an event with `event_type = T`, THEN the platform returns HTTP 422 with an RFC 9457 body identifying the unknown event type.
- GIVEN event type T is registered, WHEN a caller appends a payload that fails the registered schema, THEN the platform returns HTTP 422 with an RFC 9457 body listing every validation failure (field path, constraint violated, actual value).
- An event type name MUST be a non-empty string of ≤ 128 characters. Registering a duplicate name+version combination MUST be rejected with HTTP 409.
- The JSON Schema stored per event type MUST itself be valid JSON Schema (draft-07 or later). Submitting an invalid schema document MUST be rejected with HTTP 422.
- Updating an existing event type's schema MUST use a new schema version; overwriting an existing version is rejected with HTTP 409.

**See:** ES-01 (`event_type` field and payload validated here before persist), API-07 (general input validation layer; ES-05 adds domain-level validation on top)

**Edge cases:**
- Payload is `{}` and schema has no required fields: valid.
- Payload is `{}` and schema requires fields: rejected with HTTP 422 listing all missing required fields.

---

### ES-06 — Point-in-time query `[MUST]`

> Callers SHALL be able to request the event list for an instance up to a specific sequence number or timestamp, enabling state reconstruction at any point in history.

**Acceptance Criteria:**
- GIVEN an instance with events at sequence numbers 1..N, WHEN queried with `up_to_sequence = K` (K ≤ N), THEN the platform returns exactly events 1..K in ascending sequence order.
- GIVEN a query with `up_to_timestamp = T`, THEN the platform returns all events whose `created_at ≤ T` in ascending sequence order.
- If both `up_to_sequence` and `up_to_timestamp` are supplied, `up_to_sequence` takes precedence.
- If `up_to_sequence` exceeds the highest committed sequence number, the platform returns all events (no error).
- If `up_to_sequence = 0`, the platform returns an empty list, HTTP 200.
- An attempt to query a non-existent instance MUST return HTTP 404.

**See:** ES-02 (base ordered-read guarantee this query specialises), EE-11 (state reconstruction uses point-in-time query as its core operation)

**Edge cases:**
- `up_to_timestamp` in the future: returns all currently committed events.
- `up_to_timestamp` before the first event's `created_at`: returns empty list, HTTP 200.

---

### ES-07 — Retention policy `[SHOULD]`

> The platform SHALL support configurable event retention policies per event type: keep forever, keep N days, or keep N events. Expired events SHALL be moved to a dedicated `events_archive` table (same schema), not deleted. Archived events SHALL be retrievable via a separate API endpoint (GET /archive/events). Archival MUST NOT affect active instance state reconstruction.

**Acceptance Criteria:**
- GIVEN a "keep N days" policy on event type T, WHEN the archival process runs, THEN all events of type T with `created_at < NOW() - N days` are moved atomically from `events` to `events_archive` in a single transaction.
- GIVEN a "keep N events" policy on event type T, WHEN the archival process runs, THEN the oldest events of type T beyond the N most-recent per instance are moved to `events_archive`.
- GIVEN a "keep forever" policy, archival MUST NOT touch events of that type.
- Archived events are retrievable via `GET /archive/events` with the same field structure as live events (ES-01 schema).
- GIVEN an instance whose early events have been archived, WHEN state reconstruction (EE-11) is requested, THEN reconstruction reads from both `events` and `events_archive` and produces a result identical to pre-archival reconstruction.
- The archival operation MUST be idempotent: running it twice produces the same result.

**See:** ES-01 (archived events retain the same record structure), EE-11 (reconstruction must span both tables), DB-03 (archival move is one transaction)

**Edge cases:**
- An event is being read during archival: archival transaction must not block reads beyond the DB lock timeout.
- Retention policy changed mid-operation: the new policy applies on the next archival run.

---

### ES-08 — Event metadata `[SHOULD]`

> Each event SHALL carry an optional free-form metadata map (string → string) for tracing, correlation IDs, and source tagging without polluting the business payload.

**Acceptance Criteria:**
- GIVEN an append request that includes a `metadata` field (JSON object with string keys and string values), WHEN the event is persisted, THEN the metadata is stored verbatim and returned in all read operations for that event.
- GIVEN an append request with no `metadata` field, WHEN the event is persisted, THEN `metadata` defaults to `{}` and is returned as such.
- A `metadata` value that is not a string (e.g. number, object, array) MUST be rejected with HTTP 422 identifying the offending key.
- `metadata` keys MUST be non-empty strings of ≤ 128 characters. Values MUST be strings of ≤ 1,024 characters. Violations MUST be rejected with HTTP 422.
- The total number of metadata entries per event MUST NOT exceed 50; exceeding this limit is rejected with HTTP 422.
- `metadata` is NOT validated against the event type's JSON Schema (ES-05); it is orthogonal to the business payload.

**See:** ES-01 (metadata is an additional field on the event record), API-09 (trace_id SHOULD be propagated into metadata automatically by the platform)

**Edge cases:**
- `metadata = null`: treated as absent; defaults to `{}`.
- `metadata = {}`: valid.
- Duplicate metadata keys in the submitted object: last-write-wins (standard JSON semantics).

---

### DB-01 — Schema initialisation `[MUST]`

> The platform SHALL include idempotent SQL migration scripts that create all required tables, indexes, and constraints on a fresh PostgreSQL 15+ database.

**Acceptance Criteria:**
- GIVEN a fresh PostgreSQL 15+ database with no application schema, WHEN all migration scripts are applied in order, THEN all required tables, indexes, and constraints exist and the platform starts without error.
- GIVEN a database where all migrations have already been applied, WHEN the migrations are re-applied, THEN they complete without error and the schema is unchanged (idempotent).
- Each migration file is numbered sequentially (e.g. `001_`, `002_`) and MUST be applied in numeric order. Applying migration N+1 before migration N MUST fail with a clear error.
- Migration scripts MUST NOT use `DROP TABLE` or other destructive statements; additive-only changes are required at this stage.
- GIVEN a migration script that fails mid-execution, WHEN the failure occurs, THEN the entire migration is rolled back and the database is left in the pre-migration state.

**See:** DB-03 (migrations run inside transactions to satisfy crash safety), NFR-07 (crash safety applies to migrations)

**Edge cases:**
- Running migrations on PostgreSQL < 15: platform MUST log a fatal error and refuse to start.
- Out-of-order manual application: migration tracker table MUST detect and reject.

---

### DB-02 — Connection pooling `[MUST]`

> All database access SHALL go through a connection pool. Pool size MUST be configurable via environment variable, subject to bounds defined in NFR-06. An exhausted pool MUST return an error immediately, not block indefinitely.

**Acceptance Criteria:**
- GIVEN `BPM_DB_POOL_SIZE=20` is set, WHEN the platform starts, THEN the pool is initialised with exactly 20 connections.
- GIVEN pool size is set to a value < 2 or > 200, WHEN the platform starts, THEN it exits with a fatal error identifying the invalid value and the valid range (NFR-06).
- GIVEN the pool is fully exhausted (all connections in use), WHEN a new database operation is requested, THEN the platform returns an error immediately (no blocking wait) and the caller receives HTTP 503.
- All database queries MUST use a connection acquired from the pool; direct connection creation outside the pool is forbidden.
- Pool connections MUST be validated on acquisition; a stale connection MUST be discarded and replaced before use.

**See:** NFR-06 (pool bounds 2–200, default 10), DB-04 (health check verifies pool is functional), DB-03 (transactional operations hold a pool connection for the duration of the transaction)

**Edge cases:**
- `BPM_DB_POOL_SIZE` not set: defaults to 10.
- `BPM_DB_POOL_SIZE=0` or negative: fatal error at startup.
- Database goes offline while connections are held: all affected operations return errors; pool reconnects on next successful attempt.

---

### DB-03 — Transactional integrity `[MUST]`

> Event append and any associated state-table update MUST occur within a single database transaction. Partial writes MUST NOT be observable.

**Acceptance Criteria:**
- GIVEN an event append that also updates a read-model (state table), WHEN both writes succeed, THEN exactly one committed transaction contains both changes — no reader ever sees the event row without the state update, or vice versa.
- GIVEN an event append where the state-table update fails, WHEN the failure occurs, THEN the entire transaction is rolled back: the event log row is NOT committed and the state table is NOT updated.
- GIVEN a crash after the event log write but before the state-table update commits, WHEN the platform restarts, THEN neither write is observable (the transaction did not commit).
- This guarantee applies to every write operation that spans multiple tables, not only event append.

**See:** ES-01 (the event append this wraps), DB-01 (FK constraints make partial writes structurally impossible), NFR-07 (crash safety requirement)

**Edge cases:**
- Crash during COMMIT: PostgreSQL WAL ensures either the full commit is durable or a clean rollback occurs on recovery.
- Nested transactions (savepoints): rolling back a savepoint reverts only the savepoint's changes; the outer transaction remains intact.

---

### DB-04 — Health check query `[MUST]`

> The platform SHALL expose an internal function that verifies database reachability and returns latency, used by the health endpoint (see API-12).

**Acceptance Criteria:**
- GIVEN the database is reachable, WHEN the health check function is invoked, THEN it returns a success result including the round-trip latency in milliseconds.
- GIVEN the database is unreachable (connection refused, timeout, or pool exhausted), WHEN the health check function is invoked, THEN it returns a failure result with an error description within 5 seconds.
- The health check MUST use a connection from the pool (DB-02); it MUST NOT open a separate connection.
- The health check query MUST be read-only (e.g. `SELECT 1`) and MUST NOT modify any data.
- Latency returned MUST reflect the real round-trip time: duration from connection acquisition to result receipt.

**See:** API-12 (health endpoint calls this function and exposes the result), DB-02 (pool availability is part of reachability)

**Edge cases:**
- Pool exhausted but database is reachable: health check reports failure (cannot acquire connection), correctly reflecting that the platform cannot currently serve requests.
- Health check during database failover: may transiently fail; subsequent invocations succeed once failover completes.

---

## Stage 2 — Process Definition Model

**Goal:** Callers can create, version, validate, and retrieve process definitions expressed as directed graphs. No execution yet — this stage defines the blueprint layer that the engine will consume in Stage 3.

### Node type specifications

| Node type | Required attributes | Notes |
|---|---|---|
| **START** | *(none)* | Exactly one per definition graph |
| **END** | *(none)* | At least one per definition graph |
| **HUMAN_TASK** | `name` (string), `assignee_type` (USER \| GROUP \| ROLE), `assignee_ref` (string), `form_schema` (JSON Schema, optional), `escalation_timer_duration` (ISO 8601 duration, optional) | `escalation_timer_duration` activates SCH-04 in Stage 5 |
| **EXCLUSIVE_GATEWAY** | *(none beyond graph edges)* | Outgoing edges carry CEL condition expressions (PD-06) |
| **PARALLEL_GATEWAY** | *(none)* | Acts as split when outgoing edges > 1; acts as join when incoming edges > 1 |

Additional node types (SERVICE_TASK, TIMER, SUB_PROCESS) are introduced in later stages.

---

### PD-01 — Create definition `[MUST]`

> Authorised callers SHALL be able to create a new process definition by submitting a name, version string, description, and a definition graph (nodes + edges as JSON). The platform assigns a UUID and sets status = DRAFT.

**Acceptance Criteria:**
- GIVEN an authorised caller submits a valid request with name, version string, description, and a definition graph, WHEN processed, THEN the platform returns HTTP 201 with the assigned UUID, `status = DRAFT`, and all submitted fields.
- The definition graph MUST be a JSON object with a `nodes` array and an `edges` array.
- A definition name MUST be a non-empty string of ≤ 255 characters. A version string MUST be non-empty.
- Two definitions with the same name and version string MUST be rejected with HTTP 409.
- The caller MUST be authorised: PROCESS_DESIGNER or PLATFORM_ADMIN role (per IDN-03).
- Newly created definitions are assigned `status = DRAFT`; callers cannot specify a different initial status.

**See:** PD-02 (graph validation runs during creation), PD-03 (version management governs same-name constraints), API-08 (authorisation check)

**Edge cases:**
- Empty `nodes` array: rejected by PD-02 (no START node).
- `description` omitted: allowed (optional field).
- Two concurrent requests with the same name+version: exactly one succeeds; the other receives HTTP 409.

---

### PD-02 — Graph validation `[MUST]`

> On creation or update, the platform SHALL validate: graph is a directed graph with exactly one START node and at least one END node; all edge source/target references point to existing nodes; no isolated nodes exist; no duplicate node IDs within a definition; no cycles exist in paths that do not pass through a gateway node; node count does not exceed 500 and edge count does not exceed 2,000.

**Acceptance Criteria:**
- GIVEN a graph with exactly one START, at least one END, all edges referencing existing nodes, no isolated nodes, no duplicate node IDs, no non-gateway cycles, and counts within limits, WHEN validated, THEN validation passes.
- GIVEN zero or more than one START node, THEN HTTP 422 identifies the START node violation.
- GIVEN no END nodes, THEN HTTP 422 is returned.
- GIVEN an edge referencing a node ID not in the `nodes` array, THEN HTTP 422 identifies the dangling reference.
- GIVEN a cycle that does not pass through a gateway node, THEN HTTP 422 identifies the cycle path.
- GIVEN > 500 nodes or > 2,000 edges, THEN HTTP 422 identifies the limit exceeded.
- Validation errors MUST list ALL violations found, not just the first.

**See:** PD-01 (validation runs on creation and update), PD-05 (node-type attribute validation runs after graph-structure validation), PD-06 (edge condition syntax validated here)

**Edge cases:**
- A cycle that passes through a PARALLEL_GATEWAY or EXCLUSIVE_GATEWAY node: permitted (cycle passes through gateway).
- A node with no incoming and no outgoing edges that is not the START node: rejected (isolated node).
- Self-loop (edge from node X to itself): rejected (cycle not through gateway).

---

### PD-03 — Version management `[MUST]`

> Each definition name MAY have multiple versions. Only one version per name SHALL be in ACTIVE status at a time. Activating a version automatically sets the prior active version to DEPRECATED.

**Acceptance Criteria:**
- GIVEN definition name N has an existing ACTIVE version V1, WHEN version V2 is activated for name N, THEN V1's status changes to DEPRECATED atomically in the same transaction.
- At no point MAY two versions of the same name simultaneously have `status = ACTIVE`.
- GIVEN a definition name with no ACTIVE version, WHEN the first version is activated, THEN it becomes ACTIVE with no prior version to deprecate.
- Listing definitions filtered by `status=ACTIVE` MUST return at most one version per name.
- Version strings are compared as opaque strings; no semantic-versioning ordering is enforced.

**See:** PD-04 (lifecycle transitions leading to DEPRECATED), PD-08 (snapshot uses the version at instance-start time, so later changes do not affect running instances)

**Edge cases:**
- Activating the already-ACTIVE version of the same name: no-op; returns HTTP 200 (idempotent).
- Activating a DEPRECATED or ARCHIVED version: rejected with HTTP 409 (only DRAFT definitions can be activated).

---

### PD-04 — Definition lifecycle `[MUST]`

> A definition SHALL progress through statuses: DRAFT → ACTIVE → DEPRECATED → ARCHIVED. Transitions to ARCHIVED are terminal. DRAFT definitions that have never been activated MAY be permanently deleted via DELETE /definitions/:id (hard delete, no archive). Running instances keep a snapshot of the definition version they were started with.

**Acceptance Criteria:**
- Valid transitions: DRAFT → ACTIVE (via `POST /definitions/:id/activate`), ACTIVE → DEPRECATED (auto, triggered by PD-03), DEPRECATED → ARCHIVED (via PATCH), DRAFT (never activated) → deleted (via DELETE). All other transitions MUST be rejected with HTTP 409.
- GIVEN a DRAFT definition that has never been activated, WHEN `DELETE /definitions/:id` is called, THEN the definition is hard-deleted and HTTP 204 is returned.
- A definition that has been activated once can never return to DRAFT.
- ARCHIVED status is terminal: any further transition attempt returns HTTP 409.
- Running instances are unaffected by lifecycle changes to their source definition (per PD-08).

**See:** PD-03 (DEPRECATED is set by activation of a successor), PD-08 (snapshot guarantees isolation from lifecycle changes), API-02 (HTTP verbs and routes for each transition)

**Edge cases:**
- Deleting an ACTIVE definition: rejected with HTTP 409.
- Deleting a DEPRECATED definition: triggers archival (soft delete), not hard delete.

---

### PD-05 — Node types `[MUST]`

> The platform SHALL support the built-in node types defined in the node type specifications table above. Each node type's required attributes MUST be validated on definition creation or update.

**Acceptance Criteria:**
- GIVEN a HUMAN_TASK node, WHEN validated, THEN `name`, `assignee_type` (one of USER | GROUP | ROLE), and `assignee_ref` are verified as present and non-empty.
- GIVEN `escalation_timer_duration` is specified on a HUMAN_TASK, WHEN validated, THEN it MUST be a valid ISO 8601 duration string (e.g. `PT1H`); an invalid value MUST be rejected with HTTP 422.
- GIVEN an EXCLUSIVE_GATEWAY node, WHEN validated, THEN all outgoing edges carry a CEL condition expression unless one is the designated default edge (per PD-06).
- GIVEN a PARALLEL_GATEWAY node, WHEN validated, THEN it has either > 1 outgoing edge (split) or > 1 incoming edge (join), or both.
- An unknown node type MUST be rejected with HTTP 422 identifying the unsupported type.

**See:** PD-06 (edge condition validation on EXCLUSIVE_GATEWAY), PD-02 (structural validation precedes attribute validation), EE-05 (EXCLUSIVE_GATEWAY runtime behaviour), EE-06/EE-07 (PARALLEL_GATEWAY runtime behaviour)

**Edge cases:**
- PARALLEL_GATEWAY with exactly one incoming and one outgoing edge: structurally valid but semantically a no-op; a non-blocking lint warning SHOULD be returned.
- HUMAN_TASK with `assignee_type = ROLE` but no matching role defined: role validation is deferred to runtime (identity model is not loaded at definition creation time).

---

### PD-06 — Edge conditions `[MUST]`

> Edges originating from EXCLUSIVE_GATEWAY nodes SHALL carry a CEL condition expression (string). The platform SHALL validate that the expression is syntactically valid CEL at definition creation time. Evaluation against instance variables occurs at runtime (see EE-05).

**Acceptance Criteria:**
- GIVEN an edge from an EXCLUSIVE_GATEWAY with a `condition` field, WHEN the definition is created or updated, THEN the platform validates that the expression is syntactically valid CEL. An invalid expression MUST be rejected with HTTP 422 identifying the edge and the parse error.
- An edge with `is_default = true` MUST NOT carry a condition expression. Both `is_default = true` and a non-empty `condition` on the same edge MUST be rejected with HTTP 422.
- At most one outgoing edge per EXCLUSIVE_GATEWAY may have `is_default = true`; more than one default edge MUST be rejected with HTTP 422.
- Edges not originating from an EXCLUSIVE_GATEWAY MUST NOT carry condition expressions; if present, they MUST be rejected with HTTP 422.
- CEL syntax is validated at definition creation time. Semantic validity (whether referenced variables exist at runtime) is evaluated at runtime (EE-05).

**See:** PD-05 (node-type validation includes EXCLUSIVE_GATEWAY checks), EE-05 (runtime evaluation), Constraints section (CEL interpreter is embedded in the platform)

**Edge cases:**
- Empty string condition on an EXCLUSIVE_GATEWAY non-default edge: treated as missing; rejected with HTTP 422.
- CEL expression referencing a variable that may not exist at runtime: accepted at definition time; handled by EE-05 error routing.

---

### PD-07 — Definition retrieval `[MUST]`

> Callers SHALL be able to retrieve a definition by ID, list all definitions (paginated, filterable by status and name), and fetch the active version for a given name.

**Acceptance Criteria:**
- `GET /definitions/:id` returns the full definition (graph, metadata, status) for a known ID; returns HTTP 404 if ID does not exist.
- `GET /definitions` returns a paginated list of definitions per API-06, filterable by `status` and `name` (exact or prefix match). Results MUST be sorted by `created_at` descending by default.
- `GET /definitions?name=N&status=ACTIVE` returns the single ACTIVE version for name N, or an empty list if none exists.
- All retrieval endpoints require authentication (API-08); any authenticated role can read definitions (per IDN-03 permission matrix).

**See:** PD-04 (status values that can be filtered), API-06 (pagination contract), API-08 (auth requirement)

**Edge cases:**
- `GET /definitions` with no filters: returns all definitions across all statuses, paginated.
- `GET /definitions/:id` for an ARCHIVED definition: returns the definition with `status = ARCHIVED` (not HTTP 404).

---

### PD-08 — Definition snapshot `[MUST]`

> When a process instance is started, the platform SHALL store a copy of the definition graph at that moment. Subsequent changes to the definition MUST NOT affect running instances.

**Acceptance Criteria:**
- GIVEN an instance is started from definition version V, WHEN the platform starts the instance, THEN it stores an immutable copy of the full definition graph (nodes, edges, all attributes) in the instance record, atomically with instance creation.
- Subsequent updates to the definition (PUT/PATCH) MUST NOT modify any stored snapshot.
- GIVEN definition V is deprecated or archived after an instance was started, WHEN the instance's execution engine evaluates transitions, THEN it uses the snapshot, not the current definition.
- The snapshot MUST include all fields: node types, attributes, edge conditions, `is_default` flags.
- Snapshots are read-only after creation; no API endpoint permits modification of a snapshot.

**See:** PD-04 (lifecycle changes do not affect running instances), EE-01 (start instance stores the snapshot), EE-02 (transition function operates on the snapshot)

**Edge cases:**
- Definition hard-deleted (DRAFT) after instances were started from it: instances retain their snapshot and continue normally.
- Two instances started from the same definition version have independent snapshots; changes to one do not affect the other.

---

### PD-09 — Definition import/export `[SHOULD]`

> The platform SHALL support export of a definition as a self-contained JSON document and import from the same format, enabling migration between environments.

**Acceptance Criteria:**
- GIVEN a definition with any status, WHEN exported, THEN the platform returns a self-contained JSON document containing all definition fields, the full graph, and a `bpm_export_schema_version` field.
- GIVEN a valid exported JSON document, WHEN imported to a target environment with no conflicting name+version, THEN the definition is created with `status = DRAFT` on the target, preserving all fields.
- GIVEN an exported document where the same name+version already exists on the target, WHEN imported, THEN the import is rejected with HTTP 409.
- CEL conditions on imported definitions are re-validated by the target platform's CEL interpreter; invalid expressions cause import to be rejected with HTTP 422.

**See:** PD-01 (import is equivalent to create), PD-03 (version conflicts on import follow the same rules as create), PD-06 (CEL re-validation on import)

**Edge cases:**
- Exporting a DRAFT definition: permitted (useful for copying in-progress definitions across environments).

---

### PD-10 — Definition search `[COULD]`

> Callers SHALL be able to full-text search definition names and descriptions. Results SHALL be ranked by relevance and filtered by status.

**Acceptance Criteria:**
- GIVEN a search query string Q, WHEN `GET /definitions?q=Q` is called, THEN the platform returns definitions whose name or description contains Q, ranked by relevance (full-text match quality), paginated per API-06.
- Results MAY be filtered by `status` in combination with the search query.
- An empty query string MUST be rejected with HTTP 422 (use `GET /definitions` for unfiltered listing).
- Full-text search is case-insensitive.

**See:** PD-07 (base retrieval; search augments it), API-06 (pagination applies to search results)

**Edge cases:**
- Query with only stop words (e.g. "the a"): platform may return zero results.
- Query containing SQL injection attempts: treated as literal search terms (parameterised queries prevent injection).

---

## Stage 3 — Execution Engine

**Goal:** Process instances can be started, driven through nodes by task completion, and terminated. The engine supports sequential flow, exclusive gateways, and parallel gateways. State is fully event-sourced and reconstructable.

**Note:** The transition function (EE-02) is the intellectual core of the platform. It must be implemented as a pure function with comprehensive unit tests before integration with persistence.

### Variable collision policy

When task output variables are merged into the instance variable map (EE-09):

1. If a key does not exist in the instance map, it is inserted.
2. If a key exists and the new value is schema-compatible (or no schema is defined), the old value is **overwritten** and an `VARIABLE_OVERWRITTEN` entry is appended to the event log, recording the key, old value, and new value.
3. If a key exists and a registered variable schema is defined and the new value **fails** schema validation, the engine SHALL treat this as an unresolvable condition, set the instance to ERROR status, and append an `EXECUTION_ERROR` event (see EE-10). The merge is not applied.

---

### EE-01 — Start instance `[MUST]`

> An authorised caller SHALL start a process instance by supplying a definition ID (or name + version), an optional correlation key (unique per definition), and an initial variables map (JSON object). The platform returns an `instance_id` and sets status = ACTIVE.

**Acceptance Criteria:**
- GIVEN an authorised caller submits a valid start request with an existing ACTIVE definition ID, WHEN processed, THEN the platform returns HTTP 201 with `instance_id` (UUID), `status = ACTIVE`, and `created_at`.
- GIVEN a `correlation_key` is supplied, WHEN a second start request is made for the same definition with the same correlation key, THEN HTTP 409 is returned (uniqueness per definition).
- GIVEN no `correlation_key` is supplied, no uniqueness constraint is applied; multiple keyless instances of the same definition may run concurrently.
- `initial_variables` MUST be a JSON object (not null, not array). An empty object `{}` is permitted.
- GIVEN a definition that is not in ACTIVE status, WHEN a start request is made, THEN HTTP 409 is returned.
- A snapshot of the definition graph is stored atomically with the instance creation event (PD-08).
- The execution token is placed on the START node; the first task activation (EE-03) fires immediately for the first non-START node.

**See:** PD-08 (snapshot stored on start), EE-02 (transition function moves token off START immediately), EE-09 (initial_variables populate the instance variable map)

**Edge cases:**
- `initial_variables = null`: rejected with HTTP 422; use `{}` for empty variables.
- Starting from a definition by name when there is no ACTIVE version: HTTP 404.

---

### EE-02 — Pure transition function `[MUST]`

> The execution engine SHALL implement a pure function: `(DefinitionSnapshot, InstanceState, Event) → NewInstanceState`. This function MUST have no I/O and be independently unit-testable.

**Acceptance Criteria:**
- GIVEN any `(DefinitionSnapshot, InstanceState, Event)` triple, WHEN the transition function is called, THEN it returns a new `InstanceState` without performing any I/O (no database reads, no network calls, no file system access).
- The function MUST be deterministic: identical inputs MUST always produce identical outputs.
- A test suite MUST exercise the function directly with in-memory inputs without starting the platform; this test suite MUST pass at 100% before the function is integrated with persistence (per stage note).
- The function covers all node-type transitions defined in PD-05 and gateway rules in EE-05, EE-06, EE-07.
- An unknown event type passed to the function MUST return an error state, not panic or crash.

**See:** EE-01 (provides the DefinitionSnapshot and initial InstanceState), EE-03..EE-10 (all runtime behaviours route through this function), NFR-07 (purity enables crash-safe replay)

**Edge cases:**
- InstanceState with a token on a non-existent node ID: the function MUST return an error state identifying the inconsistency.
- Calling the function with the same inputs twice in rapid succession: both calls return identical output (no side effects).

---

### EE-03 — Task activation `[MUST]`

> Upon entering a node, the platform SHALL create a Task record with status = PENDING and persist it atomically with the state transition event.

**Acceptance Criteria:**
- GIVEN the execution token enters a HUMAN_TASK node, WHEN the transition function produces a new state, THEN the persistence layer creates a Task record with `status = PENDING`, `task_id` (UUID), `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, and `created_at`.
- The Task record creation and the state transition event append MUST occur in a single transaction (DB-03).
- START and END nodes MUST NOT create Task records.
- EXCLUSIVE_GATEWAY and PARALLEL_GATEWAY nodes MUST NOT create Task records (gateway evaluation is internal to the transition function).
- A newly created Task is visible to `GET /tasks` immediately after its transaction commits.

**See:** EE-02 (transition function determines which node is entered), EE-04 (task completion is the next step), DB-03 (atomic write), API-04 (task retrieval endpoints)

**Edge cases:**
- Activation of a HUMAN_TASK where `assignee_ref` is a group with no current members: Task is created in PENDING status; assignment resolution is deferred to runtime.
- Token entering an END node: instance transitions to COMPLETED; no task is created; timer cancellation (SCH-03) is triggered.

---

### EE-04 — Complete task `[MUST]`

> An authorised caller SHALL complete an active task by submitting an output variables map. The engine evaluates outgoing edge conditions, activates the next node(s), and records a `TASK_COMPLETED` event.

**Acceptance Criteria:**
- GIVEN an authorised caller submits `POST /tasks/:id/complete` with an `output_variables` JSON object, WHEN the task is PENDING, THEN the platform merges output variables per EE-09, evaluates outgoing edge conditions, activates the next node(s), appends a `TASK_COMPLETED` event, and returns HTTP 200.
- GIVEN the task does not exist, THEN HTTP 404 is returned.
- GIVEN the task has status ≠ PENDING (already COMPLETED or CANCELLED), THEN HTTP 409 is returned.
- The task status change, variable merge, state transition, and `TASK_COMPLETED` event MUST all commit in a single transaction.
- `output_variables` may be an empty object `{}`; this is valid (task completed with no output).

**See:** EE-09 (variable merge logic including collision policy), EE-05 (if next node is EXCLUSIVE_GATEWAY, conditions evaluated after merge), EE-03 (next node activation follows completion), DB-03 (atomic transaction)

**Edge cases:**
- `output_variables = null`: rejected with HTTP 422; use `{}` for no output.
- TASK_WORKER completing a task assigned to a different user: HTTP 403 (per IDN-03 role matrix).

---

### EE-05 — Exclusive gateway `[MUST]`

> When the execution token reaches an EXCLUSIVE_GATEWAY, the platform SHALL evaluate outgoing edge CEL conditions in declared order and follow the first edge whose condition evaluates to `true`. One edge MAY be designated as the **default edge** via a boolean `is_default` flag in the edge definition. The default edge is evaluated last, regardless of declared order, and does not carry a condition expression. If no condition matches and no default edge is defined, the engine transitions the instance to ERROR status per EE-10.

**Acceptance Criteria:**
- GIVEN the execution token reaches an EXCLUSIVE_GATEWAY, WHEN CEL conditions are evaluated in declared edge order, THEN the token follows the first edge whose condition evaluates to `true` against the current instance variables.
- GIVEN one edge has `is_default = true`, WHEN no non-default condition evaluates to `true`, THEN the token follows the default edge (evaluated last regardless of declared order).
- GIVEN no condition evaluates to `true` and no default edge exists, WHEN all conditions are exhausted, THEN the instance transitions to ERROR status per EE-10, with a structured reason identifying the gateway node ID and the evaluated conditions.
- A CEL runtime error (e.g. type mismatch) on a condition expression MUST be treated as `false` for that condition.
- Exactly one outgoing edge is followed per evaluation; never zero, never more than one.

**See:** PD-06 (conditions are validated at definition creation time), EE-02 (gateway evaluation is inside the pure transition function), EE-10 (error path when no condition matches), EE-09 (variables are merged before gateway evaluation)

**Edge cases:**
- Condition expression accessing an undefined variable: CEL returns a runtime error → treated as `false`.
- All non-default conditions are `false` and a default edge exists: default edge is followed correctly.

---

### EE-06 — Parallel gateway (split) `[MUST]`

> A PARALLEL_GATEWAY SHALL activate all outgoing edges simultaneously, creating concurrent execution tokens. Each token progresses independently.

**Acceptance Criteria:**
- GIVEN the execution token reaches a PARALLEL_GATEWAY with N outgoing edges, WHEN evaluated, THEN N independent execution tokens are created simultaneously, one per outgoing edge.
- Each token progresses independently; task completions on one branch do not block other branches.
- The split event MUST be recorded in the event log.
- All N tokens are created in a single transaction (DB-03).

**See:** EE-02 (split logic is inside the pure transition function), EE-07 (the join that corresponds to this split), EE-09 (variables from parallel branches merge at join per collision policy)

**Edge cases:**
- PARALLEL_GATEWAY with 2 outgoing edges where one branch immediately reaches the join before the other starts: join waits for the second token (see EE-07).

---

### EE-07 — Parallel gateway (join) `[MUST]`

> A PARALLEL_GATEWAY acting as join SHALL wait until all **active** incoming tokens have arrived before activating the single outgoing edge. An incoming branch that was cancelled (via EE-08) contributes no token and is excluded from the join count. If all branches of a parallel split are cancelled before any reaches the join, the join node is also cancelled and the instance transitions to CANCELLED status.

**Acceptance Criteria:**
- GIVEN N active tokens approaching a PARALLEL_GATEWAY join, WHEN all N active tokens have arrived, THEN the join fires and a single outgoing token is created.
- "Active" excludes tokens on branches cancelled via EE-08.
- GIVEN one branch is cancelled and all remaining active branches arrive at the join, WHEN the last active token arrives, THEN the join fires normally (cancelled branch excluded from count).
- GIVEN all branches of a split are cancelled before any reaches the join, WHEN the last cancellation occurs, THEN the join node is also cancelled and the instance transitions to CANCELLED status.
- The join fires exactly once regardless of the arrival order of concurrent tokens.

**See:** EE-06 (the split that created the tokens), EE-08 (branch cancellation that affects the join count), DB-03 (join firing is a single atomic transaction)

**Edge cases:**
- Variable key collision from two parallel branches merging at join: EE-09 collision policy applies (overwrite + log).
- All branches cancelled: the final `INSTANCE_CANCELLED` event covers both the branch cancellations and the join cancellation.

---

### EE-08 — Instance cancellation `[MUST]`

> An authorised caller SHALL cancel a running instance. All open tasks SHALL be set to CANCELLED. All pending timers for the instance SHALL be cancelled atomically (see SCH-03). All in-flight SERVICE_TASK HTTP calls SHALL be abandoned (best-effort; no retry). An `INSTANCE_CANCELLED` event is appended. Cancelled instances are terminal.

**Acceptance Criteria:**
- GIVEN an authorised caller submits `POST /instances/:id/cancel`, WHEN the instance is ACTIVE, THEN all open tasks are set to CANCELLED, all pending timers are cancelled (SCH-03), in-flight SERVICE_TASK calls are abandoned (best-effort), an `INSTANCE_CANCELLED` event is appended, and instance status is set to CANCELLED. HTTP 200 is returned.
- GIVEN the instance is already CANCELLED or COMPLETED, THEN HTTP 409 is returned.
- The task cancellations, timer cancellations, status change, and `INSTANCE_CANCELLED` event MUST all commit in a single transaction.
- Cancelled instances are terminal: no further operations (task completion, event append) may be performed on them.

**See:** SCH-03 (timer cancellation called atomically here), EE-07 (parallel join behaviour when branches are cancelled), API-03 (HTTP endpoint), IDN-03 (PROCESS_OPERATOR or above may cancel)

**Edge cases:**
- Cancelling an instance with no open tasks or timers: valid; `INSTANCE_CANCELLED` event is still appended.
- Concurrent cancellation while a task is being completed: the first operation to acquire the row-level lock wins; the other receives HTTP 409.

---

### EE-09 — Variable scoping `[MUST]`

> Instance variables SHALL be a mutable JSON object. Task output variables SHALL be merged into the instance variable map upon task completion per the variable collision policy defined above.

**Acceptance Criteria:**
- GIVEN task completion with `output_variables` containing key K not present in the instance map, WHEN merged, THEN K is inserted into the instance map.
- GIVEN task completion with `output_variables` containing key K already present, and the new value is schema-compatible (or no schema is defined), WHEN merged, THEN K is overwritten and a `VARIABLE_OVERWRITTEN` event is appended recording the key, old value, and new value.
- GIVEN task completion with `output_variables` containing key K already present, and a registered variable schema rejects the new value, WHEN merge is attempted, THEN the merge is NOT applied, the instance transitions to ERROR status (EE-10), and an `EXECUTION_ERROR` event is appended.
- Variable state after merge is immediately accessible to subsequent CEL condition evaluations (EE-05).

**See:** EE-04 (merge triggered by task completion), EE-10 (schema violation error path), EE-05 (variables read by gateway conditions post-merge)

**Edge cases:**
- Empty `output_variables = {}`: merge is a no-op; no `VARIABLE_OVERWRITTEN` event is appended.
- Duplicate key in one task completion's JSON object: standard JSON semantics (last value wins in the parsed object before merge).

---

### EE-10 — Execution error handling `[MUST]`

> If the engine encounters an unresolvable condition (no matching gateway edge and no default edge, schema violation on variable merge), it SHALL set the instance to ERROR status, record an `EXECUTION_ERROR` event with a structured reason, and halt progression. The instance remains in ERROR status until an operator retries or discards it via the dead letter API (see OBS-05).

**Acceptance Criteria:**
- GIVEN an unresolvable condition (no matching gateway edge + no default edge, or schema violation on variable merge), WHEN detected, THEN `status` is set to ERROR and an `EXECUTION_ERROR` event is appended containing: error type, affected node or field, a human-readable reason, and the instance variable state at the time of the error.
- GIVEN an instance in ERROR status, WHEN a task completion is attempted, THEN HTTP 409 is returned.
- Instances in ERROR status remain in ERROR until an operator action (retry or discard via OBS-05).
- The transition to ERROR and the `EXECUTION_ERROR` event append MUST be atomic (single transaction).
- `EXECUTION_ERROR` events MUST carry sufficient context for an operator to diagnose the root cause without replaying the instance.

**See:** EE-05 (gateway no-match triggers this), EE-09 (schema violation triggers this), OBS-05 (dead letter API for retry/discard)

**Edge cases:**
- Two concurrent operations that both trigger EE-10 on the same instance: the first to commit wins; the second sees `status = ERROR` and its operation is rejected with HTTP 409.

---

### EE-11 — State reconstruction `[MUST]`

> At any time, the platform SHALL be able to reconstruct the full current state of any instance by replaying its event log from the beginning. Reconstructed state MUST be identical to persisted state. Reconstruction MUST complete within the time bound defined in NFR-04.

**Acceptance Criteria:**
- GIVEN an instance with N events in its event log, WHEN state reconstruction is invoked, THEN the platform replays all N events through the pure transition function (EE-02) and produces an `InstanceState` equal to the persisted projection, field-for-field: same active tokens, same variable map, same task set, same instance status.
- Reconstruction MUST complete within NFR-04 (≤ 5 seconds for up to 10,000 events).
- Reconstruction MUST be possible even if the read-model (projection table) is corrupt or absent.
- After successful reconstruction, the platform MAY write the result back to the projection table to restore the read model.
- Reconstruction that spans both `events` and `events_archive` tables (ES-07) MUST produce identical results to pre-archival reconstruction.

**See:** EE-02 (reconstruction uses the pure transition function), ES-02 (ordered event retrieval is the input), NFR-04 (time bound), ES-06 (point-in-time reconstruction uses a filtered event list)

**Edge cases:**
- Instance with 0 events: reconstructed state = initial state (token on START, empty variables, ACTIVE status).
- Event log contains an `EXECUTION_ERROR` event: reconstructed status = ERROR.

---

### EE-12 — Concurrent instance safety `[MUST]`

> Multiple instances of the same definition SHALL execute concurrently without interference. Instance state MUST be fully isolated.

**Acceptance Criteria:**
- GIVEN 100 instances of the same definition running simultaneously, WHEN state transitions are applied to each, THEN no instance's state (variable map, task set, event log, token positions) is corrupted by another instance's operation.
- Database row-level locking MUST be used to serialise concurrent operations on the same instance; cross-instance contention MUST be zero (no global lock held across instance boundaries).
- Two concurrent task completions on the SAME instance: one succeeds; the other receives HTTP 409 (optimistic concurrency control or row-level lock).
- Load test: 100 concurrent task completions across 100 distinct instances MUST all succeed without deadlock or data corruption.

**See:** DB-03 (transactional writes prevent corruption within one instance), ES-01 (event log isolation is per `instance_id`)

---

## Stage 4 — REST API & Authentication

**Goal:** The platform is accessible over HTTP with a documented, authenticated REST API. All core operations (definition management, instance lifecycle, task operations, history) are exposed.

**Note on authentication bootstrapping:** Stage 4 requires Bearer token authentication (API-08), but token issuance (IDN-04) is not available until Stage 5. During Stage 4 development and testing, a **bootstrap token** SHALL be configurable via environment variable (`BPM_BOOTSTRAP_TOKEN`). This token grants PLATFORM_ADMIN privileges and MUST be disabled (startup fatal error) in production environments (detected via `BPM_ENV=production`).

### Pagination

All list endpoints use cursor-based pagination. Cursors are opaque base64-encoded strings containing a sort key and a record ID. Cursors expire after 24 hours. If the underlying data changes between pages (e.g. a new instance is created), the page boundary reflects the cursor's sort key — new records inserted after cursor creation may not appear until a fresh query is issued. Clients MUST NOT attempt to parse or construct cursors.

---

### API-01 — REST conventions `[MUST]`

> All endpoints SHALL follow REST conventions: nouns for resources, HTTP verbs for actions, JSON request/response bodies, `Content-Type: application/json`. Error responses SHALL use RFC 9457 Problem Details format.

**Acceptance Criteria:**
- All platform endpoints use nouns for resource paths and standard HTTP verbs: GET (read), POST (create/action), PUT (full replace), PATCH (partial update), DELETE (remove).
- All request and response bodies use `Content-Type: application/json`.
- Requests that supply a body without `Content-Type: application/json` MUST be rejected with HTTP 415.
- All error responses MUST use RFC 9457 Problem Details format with at minimum: `type` (URI), `title` (human-readable), `status` (HTTP status code), `detail` (specific message).
- HTTP success codes: 200 (OK), 201 (Created), 204 (No content, no body).

**See:** API-07 (validation errors add an `errors` array to Problem Details), API-09 (tracing adds `trace_id` to all responses)

**Edge cases:**
- PUT with no body: HTTP 400 (body required for full replacement).
- POST to a non-existent resource path: HTTP 404.

---

### API-02 — Process definition CRUD `[MUST]`

> The API SHALL expose: `POST /definitions`, `GET /definitions`, `GET /definitions/:id`, `PUT /definitions/:id` (full replacement of DRAFT only), `PATCH /definitions/:id` (partial update of DRAFT only), `DELETE /definitions/:id` (hard delete of DRAFT; archive of ACTIVE/DEPRECATED), `POST /definitions/:id/activate`.

**Acceptance Criteria:**
- `POST /definitions`: creates a definition; returns HTTP 201 with definition ID. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `GET /definitions`: lists definitions, paginated (API-06), filterable by `status` and `name`. Any authenticated role.
- `GET /definitions/:id`: returns definition. HTTP 404 if not found. Any authenticated role.
- `PUT /definitions/:id`: full replacement; only valid for DRAFT definitions. HTTP 409 if `status ≠ DRAFT`. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `PATCH /definitions/:id`: partial update; only valid for DRAFT. HTTP 409 if `status ≠ DRAFT`. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `DELETE /definitions/:id`: hard delete of never-activated DRAFT (HTTP 204); archive of ACTIVE or DEPRECATED (HTTP 200). HTTP 404 if not found. Requires PLATFORM_ADMIN.
- `POST /definitions/:id/activate`: transitions DRAFT → ACTIVE. HTTP 409 if `status ≠ DRAFT`. Triggers PD-02 graph re-validation. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- All write operations trigger PD-02 graph validation; validation failures return HTTP 422.

**See:** PD-01..PD-08 (business rules for each operation), API-01 (conventions), API-07 (validation), API-08 (auth)

**Edge cases:**
- PUT/PATCH on an ACTIVE definition: rejected with HTTP 409.
- DELETE on an ACTIVE definition: triggers archive (not hard delete), HTTP 200.

---

### API-03 — Instance management `[MUST]`

> The API SHALL expose: `POST /instances` (start), `GET /instances/:id` (state + current tasks), `POST /instances/:id/cancel`, `GET /instances` (list, paginated, filterable by status/definition).

**Acceptance Criteria:**
- `POST /instances`: starts instance; body contains `definition_id` (or `name` + `version`), optional `correlation_key`, optional `initial_variables`. Returns HTTP 201 with `instance_id` and `status = ACTIVE`. Requires PROCESS_OPERATOR or above.
- `GET /instances/:id`: returns instance state including `status`, `current_tasks`, `variables`, `started_at`. HTTP 404 if not found. Any authenticated role.
- `POST /instances/:id/cancel`: cancels instance per EE-08. HTTP 409 if already terminal. Requires PROCESS_OPERATOR or above.
- `GET /instances`: lists instances, paginated (API-06), filterable by `status` and `definition_id`. Any authenticated role.

**See:** EE-01 (start logic), EE-08 (cancel logic), API-06 (pagination), API-08 (auth)

**Edge cases:**
- `GET /instances/:id` for a CANCELLED instance: returns instance with `status = CANCELLED`.
- Starting with a `definition_id` that belongs to a DRAFT definition: HTTP 409.

---

### API-04 — Task operations `[MUST]`

> The API SHALL expose: `GET /tasks` (list, filterable by assignee/status/instance), `GET /tasks/:id`, `POST /tasks/:id/complete`, `POST /tasks/:id/assign`, `POST /tasks/:id/reassign`.

**Acceptance Criteria:**
- `GET /tasks`: lists tasks, paginated, filterable by `assignee_id`, `status`, `instance_id`. TASK_WORKER sees only their own tasks; PROCESS_OPERATOR and above see all.
- `GET /tasks/:id`: returns task including `status`, `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, `created_at`. HTTP 404 if not found.
- `POST /tasks/:id/complete`: completes task per EE-04. Body: `{ "output_variables": {...} }`. HTTP 409 if already completed or cancelled.
- `POST /tasks/:id/assign`: assigns an unassigned task to a specific user. Body: `{ "user_id": "..." }`. HTTP 409 if task already assigned.
- `POST /tasks/:id/reassign`: changes the assignee of an already-assigned task. Requires PROCESS_OPERATOR or above.

**See:** EE-03 (task creation), EE-04 (completion logic), IDN-03 (role permission matrix), API-06 (pagination for task list)

**Edge cases:**
- TASK_WORKER attempts to complete a task assigned to a different user: HTTP 403.
- Task for a CANCELLED instance: task is already CANCELLED; completion returns HTTP 409.

---

### API-05 — History endpoint `[MUST]`

> `GET /instances/:id/history` SHALL return the full ordered event log for an instance, with optional filtering by event type and time range.

**Acceptance Criteria:**
- `GET /instances/:id/history` returns all events for the instance in ascending sequence order. HTTP 404 if instance not found.
- Optional query parameters: `event_type` (filter to a specific event type), `from` (ISO 8601 timestamp, inclusive), `to` (ISO 8601 timestamp, inclusive).
- Results are paginated per API-06.
- Each event in the response includes all fields from the event record (ES-01) plus the sequence number.
- Any authenticated role may access instance history.
- Archived events (ES-07) MUST be included in their correct sequence position.

**See:** ES-02 (ordered read backing this endpoint), ES-06 (timestamp filtering uses point-in-time query), API-06 (pagination)

**Edge cases:**
- Instance with no events: returns empty list, HTTP 200.
- `from` > `to`: HTTP 422.

---

### API-06 — Pagination `[MUST]`

> All list endpoints SHALL support cursor-based pagination per the pagination spec above. Page size SHALL be configurable per request, default 50, maximum 200.

**Acceptance Criteria:**
- All list endpoints return a `cursor` field in the response body when more pages are available. If `cursor` is absent, the caller has received the last page.
- Callers pass the cursor via `?cursor=<value>` on subsequent requests.
- Cursors are opaque base64-encoded strings; clients MUST NOT parse them.
- Cursors expire 24 hours after creation. An expired cursor returns HTTP 410 with a message to start fresh.
- Default page size is 50. Callers specify `?page_size=N` where N ≤ 200. N > 200 MUST be rejected with HTTP 422. N ≤ 0 MUST be rejected with HTTP 422.
- A cursor from one endpoint MUST NOT be usable on a different endpoint.

**See:** API-01 (REST conventions), API-02..API-05 (all apply this pagination contract)

**Edge cases:**
- Empty result set: HTTP 200, empty `items` array, no `cursor`.
- Single item fitting on the first page: HTTP 200, no `cursor`.
- Data changes between pages: new records after cursor creation may not appear until a fresh query.

---

### API-07 — Input validation `[MUST]`

> The platform SHALL validate all incoming request payloads against defined schemas before processing. Validation errors MUST return HTTP 422 with a structured list of field-level errors in RFC 9457 format.

**Acceptance Criteria:**
- GIVEN a request body missing a required field, THEN HTTP 422 is returned with an RFC 9457 body containing an `errors` array, each entry identifying the field path, constraint violated, and actual value received.
- GIVEN a request body with a field of the wrong type, THEN HTTP 422 with field-level error detail.
- Validation MUST run before any business logic; no side effects (writes) occur for invalid requests.
- An empty required field (e.g. `""` for a required non-empty string) MUST be treated as missing and reported with HTTP 422.
- All 422 responses MUST list ALL validation errors found, not just the first.

**See:** API-01 (Problem Details format for error responses), ES-05 (domain-level validation adds to this layer)

**Edge cases:**
- Malformed JSON body: HTTP 400 (bad request), not HTTP 422.
- Valid JSON body with all fields empty strings when all are required: all required fields listed in the errors array.

---

### API-08 — Bearer token auth `[MUST]`

> All API endpoints SHALL require a Bearer token in the `Authorization` header. Requests without a valid token MUST receive HTTP 401. Requests with insufficient permissions MUST receive HTTP 403. See bootstrapping note above for Stage 4 testing.

**Acceptance Criteria:**
- GIVEN a request to any platform endpoint without an `Authorization` header, THEN HTTP 401 is returned with a `WWW-Authenticate: Bearer` header.
- GIVEN a request with `Authorization: Bearer <token>` where the token is unknown or revoked, THEN HTTP 401 is returned.
- GIVEN a request with a valid token but the caller's role does not permit the operation, THEN HTTP 403 is returned.
- GIVEN `BPM_ENV=production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN the platform MUST refuse to start (fatal error).
- GIVEN `BPM_ENV ≠ production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN requests with that token are accepted with PLATFORM_ADMIN role.
- Token validation MUST be performed on every request; no caching of authorisation decisions beyond the request lifetime.

**See:** IDN-03 (role permission matrix), IDN-04 (token issuance), API-01 (error format for 401/403)

**Edge cases:**
- Token present but `Bearer` prefix missing: HTTP 401 (malformed header).
- `BPM_BOOTSTRAP_TOKEN` set to an empty string: treated as not set; bootstrap auth disabled.

---

### API-09 — Request tracing `[MUST]`

> Each request SHALL be assigned a `trace_id` (UUID). The `trace_id` SHALL appear in the response headers (`X-Trace-Id`) and in all log entries generated during that request.

**Acceptance Criteria:**
- GIVEN any request to any platform endpoint, WHEN processed, THEN the response includes an `X-Trace-Id` header containing a UUID v4 assigned at request start.
- If the caller supplies an `X-Trace-Id` request header, the platform MUST use that value as the trace ID for that request (propagation).
- The trace ID MUST appear in every log entry emitted during that request's processing.
- The trace ID MUST appear in the `trace_id` field of any error response body.

**See:** OBS-01 (structured logging carries trace_id), API-01 (error response format)

**Edge cases:**
- Request fails authentication (HTTP 401): trace ID is still assigned and returned.
- Caller supplies an `X-Trace-Id` that is not a valid UUID: platform SHOULD accept and propagate it as-is (no validation enforced on incoming trace IDs).

---

### API-10 — Rate limiting `[SHOULD]`

> The API SHALL enforce per-token rate limits (configurable, default 1,000 req/min). Exceeded limits MUST return HTTP 429 with a `Retry-After` header.

**Acceptance Criteria:**
- GIVEN a token T that has exceeded 1,000 requests in the current 1-minute window, WHEN request N+1 arrives, THEN HTTP 429 is returned with a `Retry-After` header indicating seconds until the window resets.
- The rate limit is per-token, not per-IP.
- The default limit of 1,000 req/min MUST be overridable per-token via configuration.
- Requests that receive HTTP 429 MUST NOT be processed (no state changes occur).

**See:** API-08 (token identity used to bucket the counter)

**Edge cases:**
- Token with no configured limit: uses the global default.
- `Retry-After: 0`: window has just reset; client may retry immediately.

---

### API-11 — OpenAPI specification `[SHOULD]`

> The platform SHALL publish a machine-readable OpenAPI 3.1 specification at `GET /openapi.json`. The spec SHALL be generated from code, not manually maintained.

**Acceptance Criteria:**
- `GET /openapi.json` returns a valid OpenAPI 3.1 document describing all platform endpoints, request schemas, response schemas, and error shapes.
- The spec MUST be generated from code (annotations or schema registry); a manually maintained spec is not permitted.
- The spec MUST be accessible without authentication (HTTP 200 with no `Authorization` header required).
- The spec `info.version` field MUST match the platform release version.

**See:** API-01..API-12 (all endpoints appear in the spec)

---

### API-12 — Health endpoints `[MUST]`

> `GET /health/live` SHALL return HTTP 200 if the process is running. `GET /health/ready` SHALL return HTTP 200 only if DB connectivity and all critical subsystems are operational.

**Acceptance Criteria:**
- `GET /health/live` returns HTTP 200 with `{ "status": "ok" }` if the process is running. No auth required.
- `GET /health/ready` returns HTTP 200 with `{ "status": "ok", "db_latency_ms": N }` if the database is reachable and all critical subsystems are operational. Returns HTTP 503 with a structured body identifying the failing subsystem if not ready. No auth required.
- `GET /health/ready` MUST call DB-04 to verify database connectivity.
- Both endpoints MUST respond within 1 second.
- Health endpoints MUST NOT require authentication (used by load balancers and container orchestrators).

**See:** DB-04 (database health check function), API-09 (trace ID still assigned to health requests)

**Edge cases:**
- `GET /health/live` called during startup before DB connection: returns HTTP 200 (process is running; readiness is separate).
- `GET /health/ready` with pool exhausted: returns HTTP 503 identifying "database pool exhausted".

---

## Stage 5 — Scheduler & Identity

**Goal:** The platform acquires durable timer support (enabling escalations and time-bounded steps) and a first-class identity model (users, groups, roles, API tokens).

### Role permission matrix

| API area | PLATFORM_ADMIN | PROCESS_DESIGNER | PROCESS_OPERATOR | TASK_WORKER |
|---|:---:|:---:|:---:|:---:|
| Create / update / activate definitions | ✓ | ✓ | — | — |
| Read definitions | ✓ | ✓ | ✓ | ✓ |
| Start instances | ✓ | ✓ | ✓ | — |
| Cancel instances | ✓ | — | ✓ | — |
| Read instance state & history | ✓ | ✓ | ✓ | ✓ |
| Complete / assign tasks | ✓ | — | ✓ | ✓ (own tasks only) |
| Manage users, groups, roles | ✓ | — | — | — |
| Issue / revoke API tokens | ✓ | — | — | — |
| Access audit log | ✓ | — | ✓ | — |
| Inspect / retry dead letter items | ✓ | — | ✓ | — |
| Access metrics endpoint | ✓ | — | ✓ | — |

Roles are additive: a user may hold multiple roles; their effective permissions are the union.

---

### SCH-01 — Durable timer creation `[MUST]`

> The platform SHALL allow a process definition to declare timer events on nodes. When execution reaches such a node, a durable timer is persisted with a `fire_at` timestamp. Timers MUST survive process restarts.

**Acceptance Criteria:**
- GIVEN execution reaches a timer node, WHEN the transition function processes the arrival, THEN a durable timer record is persisted in the same transaction as the state transition event (DB-03), with: `timer_id` (UUID), `instance_id`, `fire_at` (absolute UTC timestamp), `status = PENDING`, and associated event payload.
- `fire_at` MUST be an absolute UTC timestamp derived from the node's duration/schedule at the moment of token arrival.
- GIVEN the platform is restarted, WHEN it comes back up, THEN all PENDING timers are intact and will be evaluated by the scheduler (SCH-02).
- GIVEN `fire_at ≤ NOW()` at creation time, THEN the timer is treated as due immediately on the next SCH-02 poll.

**See:** EE-02 (timer nodes processed by the transition function), SCH-02 (polling fires created timers), SCH-03 (cancellation), DB-03 (atomic persistence)

**Edge cases:**
- Timer creation for an already-CANCELLED instance: rejected; instance is in terminal state.

---

### SCH-02 — Timer polling `[MUST]`

> A background scheduler thread SHALL poll for due timers at a configurable interval (default 5 seconds). Due timers SHALL be fired atomically — the timer is marked FIRED and the associated instance event is appended in a single transaction. In clustered deployments, the platform SHALL use a PostgreSQL advisory lock to ensure only one node fires a given timer.

**Acceptance Criteria:**
- GIVEN the scheduler thread runs, WHEN it polls, THEN it selects all timers with `status = PENDING` and `fire_at ≤ NOW()`.
- For each due timer, in a single transaction: mark timer as `FIRED` and append the associated event to the instance's event log.
- In a clustered deployment, BEFORE processing a due timer, the scheduler MUST acquire a PostgreSQL advisory lock on the timer's ID. If the lock is unavailable, that timer is skipped (another node is processing it). The lock is released when the transaction commits.
- Default polling interval is 5 seconds; configurable via environment variable.

**See:** SCH-01 (timers created here), SCH-03 (cancellation sets status = CANCELLED before polling picks it up), SCH-05 (overdue timers on restart), SCH-06 (jitter on interval)

**Edge cases:**
- Database unavailable during firing: the transaction rolls back; timer remains PENDING and is retried on next poll.
- A timer due during the interval between polls: fires on the next poll (maximum latency = poll interval + jitter).

---

### SCH-03 — Timer cancellation `[MUST]`

> When an instance is cancelled or completes, all pending timers for that instance SHALL be cancelled atomically within the same transaction that records the cancellation/completion event.

**Acceptance Criteria:**
- GIVEN an instance is cancelled (EE-08) or completes, WHEN the cancellation/completion transaction commits, THEN all PENDING timers for that instance have `status` set to CANCELLED within the same transaction.
- No PENDING timer for a CANCELLED or COMPLETED instance MUST ever be fired by SCH-02.
- GIVEN SCH-02 has already acquired an advisory lock on a timer and is mid-fire, WHEN the instance is concurrently cancelled: the first transaction to commit wins (either the fire or the cancel); the other is rolled back. Both outcomes are valid.

**See:** EE-08 (cancel instance triggers this), SCH-02 (polling must not fire CANCELLED timers), DB-03 (atomic transaction)

**Edge cases:**
- Instance with zero pending timers cancelled: no timer cancellations occur; operation proceeds normally.
- Timer with `status = FIRED` is not affected by instance cancellation (already processed).

---

### SCH-04 — Escalation timer `[MUST]`

> HUMAN_TASK nodes SHALL support an optional escalation timer (via `escalation_timer_duration` in the node spec). If the task is not completed within the defined duration, the platform SHALL append an `ESCALATION` event and optionally reassign or notify per the escalation configuration in the node definition.

**Acceptance Criteria:**
- GIVEN a HUMAN_TASK node with `escalation_timer_duration` defined, WHEN the task is activated (EE-03), THEN a timer is created per SCH-01 with `fire_at = task.created_at + escalation_timer_duration`.
- GIVEN the escalation timer fires and the task is still PENDING, THEN an `ESCALATION` event is appended to the instance event log.
- GIVEN the escalation configuration specifies a reassignment target, WHEN the escalation fires, THEN the task is reassigned in the same transaction as the `ESCALATION` event.
- GIVEN the task is completed before the escalation timer fires, WHEN the task is completed, THEN the escalation timer is cancelled atomically per SCH-03.
- `escalation_timer_duration` MUST be a valid ISO 8601 duration (validated per PD-05).

**See:** PD-05 (escalation_timer_duration on HUMAN_TASK), SCH-01 (timer creation), SCH-03 (timer cancelled on task completion), EE-03 (task activation)

**Edge cases:**
- Task completed exactly when escalation timer fires concurrently: one transaction wins; the other is rolled back.

---

### SCH-05 — Missed timer recovery `[MUST]`

> If the scheduler was offline when a timer was due, it SHALL fire all overdue timers immediately on restart, with a flag indicating the timer fired late.

**Acceptance Criteria:**
- GIVEN the platform was offline when one or more timers became due, WHEN the platform restarts and SCH-02 begins polling, THEN it fires all timers with `status = PENDING` and `fire_at ≤ NOW()` as overdue.
- Overdue timer events MUST include a flag `fired_late: true` and the actual firing timestamp vs the scheduled `fire_at`.
- No overdue timer MUST be skipped; all are fired exactly once.
- The first SCH-02 poll after restart fires ALL overdue timers in sequence to avoid thundering-herd behaviour.

**See:** SCH-02 (base polling mechanism), SCH-01 (timers persist across restarts), NFR-07 (crash safety means timers are never lost)

**Edge cases:**
- Overdue timer for a CANCELLED instance: timer has `status = CANCELLED` (SCH-03 ran before shutdown); skipped.
- Platform offline for an extended period with many overdue timers: all are fired in sequence; none dropped.

---

### SCH-06 — Timer jitter `[SHOULD]`

> The scheduler SHALL apply a configurable random jitter (±N ms) to polling intervals to prevent thundering-herd effects in clustered deployments.

**Acceptance Criteria:**
- GIVEN jitter is configured (e.g. `BPM_SCHEDULER_JITTER_MS=500`), WHEN the scheduler schedules its next poll, THEN the actual delay is `base_interval ± random(0, jitter_ms)`.
- Jitter MUST be randomised independently on each node in a cluster (no shared seed).
- Default jitter is 0 ms (disabled); enabling requires explicit configuration.
- Jitter MUST NOT be applied to the timer's `fire_at` value; only to the polling interval.

**See:** SCH-02 (polling interval where jitter is applied)

**Edge cases:**
- Jitter larger than base interval: minimum effective interval is 0; the platform does not validate this.

---

### SCH-07 — Recurring timers `[SHOULD]`

> The platform SHALL support recurring timers defined by ISO 8601 repeat intervals (e.g. `R/PT1H`). The timer automatically re-arms after firing.

**Acceptance Criteria:**
- GIVEN a recurring timer with an ISO 8601 repeat interval (e.g. `R/PT1H`), WHEN the timer fires (SCH-02), THEN a new timer is created automatically with `fire_at = previous_fire_at + interval` in the same transaction as the firing.
- GIVEN a repeat count N specified (e.g. `R3/PT1H`), WHEN the timer has fired N times, THEN no new timer is created (series complete).
- GIVEN `R/PT1H` (infinite repeats), the timer re-arms indefinitely until the instance terminates.

**See:** SCH-01 (timer creation used for re-arm), SCH-03 (instance cancellation cancels the recurring chain), SCH-02 (fires recurring timers like any other)

**Edge cases:**
- Platform restarts mid-series with missed firings: SCH-05 fires all missed occurrences as overdue.
- Interval shorter than polling period: fires once per poll cycle.

---

### IDN-01 — User registry `[MUST]`

> The platform SHALL maintain a registry of users with: `user_id` (UUID), `username`, `display_name`, `email`, `status` (ACTIVE/INACTIVE), and `created_at`. Authentication of human users (login, passwords, SSO) is out of scope for this platform; users are created programmatically via API and identified in task assignments and audit logs.

**Acceptance Criteria:**
- GIVEN an authorised PLATFORM_ADMIN creates a user with `username`, `display_name`, `email`, and `status = ACTIVE`, THEN the platform returns HTTP 201 with a platform-assigned UUID `user_id` and `created_at`.
- `username` MUST be unique across all users; a duplicate username MUST be rejected with HTTP 409.
- `email` MUST be a valid email format; invalid format MUST be rejected with HTTP 422.
- GIVEN a user's status is set to INACTIVE, WHEN that user's token is used for authentication, THEN HTTP 401 is returned.
- `user_id` is assigned by the platform; callers MUST NOT specify it.

**See:** IDN-02 (users are members of groups), IDN-03 (users hold roles), IDN-04 (tokens are scoped to users), API-08 (authentication uses tokens, not user credentials)

**Edge cases:**
- Creating a user with `status = INACTIVE`: permitted (pre-registering future users).
- Deleting a user: not supported; use `status = INACTIVE` to deactivate.

---

### IDN-02 — Group management `[MUST]`

> Users SHALL be assignable to one or more named groups. Task assignment rules SHALL support assignment to a user, a group (any member may claim), or a role.

**Acceptance Criteria:**
- GIVEN an authorised PLATFORM_ADMIN creates a group with a `name`, THEN the platform returns HTTP 201 with a UUID `group_id`. Group names MUST be unique.
- Users MAY be assigned to one or more groups via `POST /groups/:id/members` with `{ "user_id": "..." }`. A non-existent `user_id` MUST cause HTTP 404.
- `GET /groups/:id/members` returns the paginated list of users in the group.
- Task assignment with `assignee_type = GROUP` allows any ACTIVE member of the group to claim and complete the task.
- Removing a user from a group (`DELETE /groups/:id/members/:user_id`) MUST NOT affect already-assigned tasks.

**See:** IDN-01 (users are members), EE-03 (task `assignee_ref` references a group name or ID), IDN-03 (GROUP assignment is part of task access control)

**Edge cases:**
- Group with no members: valid; tasks assigned to the group remain PENDING until a user is added.
- Same user added to the same group twice: idempotent (HTTP 200 on the second add, no duplicate entry).

---

### IDN-03 — Role-based access `[MUST]`

> The platform SHALL enforce the role permission matrix defined above. Roles are additive.

**Acceptance Criteria:**
- GIVEN a user holds role TASK_WORKER only, WHEN they attempt to create a definition, THEN HTTP 403 is returned.
- GIVEN a user holds roles TASK_WORKER and PROCESS_OPERATOR, WHEN they attempt to cancel an instance, THEN the operation is permitted (roles are additive; effective permissions = union).
- GIVEN a user holds TASK_WORKER only, WHEN they call `GET /tasks`, THEN only tasks assigned to them are returned (row-level filtering, not HTTP 403).
- The permission matrix in Stage 5 (IDN-03 table) is authoritative; any endpoint not covered by the matrix defaults to PLATFORM_ADMIN only.

**See:** IDN-01 (users who hold roles), IDN-04 (tokens carry the user's role set), API-08 (token validation extracts roles)

**Edge cases:**
- User with no roles assigned: valid token with no write permissions; read endpoints open to all roles remain accessible.
- TASK_WORKER completing a group-assigned task: any member of the group may complete it (not only the originally assigned user).

---

### IDN-04 — API token management `[MUST]`

> Authorised PLATFORM_ADMINs SHALL be able to issue, list, and revoke API tokens scoped to a specific user and role set. Tokens SHALL carry an optional expiry. Once issued, token values are shown only once and are not retrievable again.

**Acceptance Criteria:**
- GIVEN a PLATFORM_ADMIN calls `POST /tokens` with `{ "user_id": "...", "roles": [...], "expires_at": "..." }`, THEN the platform returns HTTP 201 with the token value (shown once only) and a `token_id`.
- Token values MUST be stored as a cryptographic hash (e.g. SHA-256); the plain-text value is returned only at creation time and never again.
- `GET /tokens` lists token metadata (`token_id`, `user_id`, `roles`, `expires_at`, `status`) but NEVER the token value.
- `DELETE /tokens/:id` revokes the token immediately; subsequent requests using that token receive HTTP 401.
- An expired token (`created_at > expires_at`) MUST be rejected with HTTP 401 on use.
- `expires_at` is optional; tokens without an expiry are valid until revoked.

**See:** IDN-01 (user_id must exist), IDN-03 (roles specified must be valid role names), API-08 (token validation uses this registry)

**Edge cases:**
- Creating a token with `expires_at` in the past: rejected with HTTP 422.
- Revoking a token mid-request: the in-flight request completes (token was valid at request start); subsequent requests are rejected.

---

## Stage 6 — Observability, Extensions & Integration

**Goal:** The platform is production-observable and extensible. Higher-level applications can integrate against a stable, monitored kernel.

---

### OBS-01 — Structured logging `[MUST]`

> All platform components SHALL emit structured JSON log entries to stdout. Each entry SHALL include: `timestamp`, `level`, `trace_id`, `component`, `message`, and optional key-value context.

**Acceptance Criteria:**
- Every log entry emitted by the platform MUST be a single-line JSON object containing at minimum: `timestamp` (ISO 8601), `level` (DEBUG/INFO/WARN/ERROR), `trace_id` (UUID or empty string), `component` (module or subsystem name), `message` (human-readable string).
- Log level is configurable via `BPM_LOG_LEVEL` environment variable. Valid values: DEBUG, INFO, WARN, ERROR. Invalid value MUST cause a fatal startup error.
- Structured logs MUST NOT include sensitive data: no token values, no plaintext credentials, no password fields.
- All log entries within a request's processing MUST carry the same `trace_id` as the response `X-Trace-Id` header (API-09).

**See:** API-09 (trace_id propagation), OBS-03 (audit log is a separate concern)

**Edge cases:**
- Log entry for a background task (scheduler, timer poller): `trace_id` is an internally generated UUID for that background operation.
- A log entry that would include a sensitive field: the value MUST be replaced with `"[REDACTED]"`.

---

### OBS-02 — Prometheus metrics `[MUST]`

> The platform SHALL expose `GET /metrics` in Prometheus text format. Core metrics SHALL include: active instances count, task completion rate, event append latency (p50/p95/p99), DB query latency, HTTP request rate and error rate.

**Acceptance Criteria:**
- `GET /metrics` returns HTTP 200 with `Content-Type: text/plain; version=0.0.4` (Prometheus text format). No authentication required.
- The following metrics MUST be present:
  - `bpm_active_instances_total` (Gauge): count of instances with `status = ACTIVE`.
  - `bpm_task_completions_total` (Counter): total task completions since startup, labelled by `definition_id`.
  - `bpm_event_append_duration_seconds` (Histogram): latency of event append operations (p50, p95, p99 buckets).
  - `bpm_db_query_duration_seconds` (Histogram): latency of database queries, labelled by `query_type`.
  - `bpm_http_requests_total` (Counter): HTTP requests labelled by `method`, `path`, `status`.
  - `bpm_http_errors_total` (Counter): HTTP 5xx responses labelled by `path`.
- Metrics collection MUST be non-blocking; a slow metrics scrape MUST NOT delay API request processing.

**See:** OBS-01 (logging is complementary, not a substitute for metrics), API-12 (health endpoints are a separate concern)

**Edge cases:**
- Metrics endpoint called during DB outage: returns HTTP 200 with available in-memory metrics; `bpm_active_instances_total` may be stale.

---

### OBS-03 — Audit log `[MUST]`

> All state-changing API actions SHALL be recorded in an audit log with: `actor_id`, `action`, `resource_type`, `resource_id`, `timestamp`, and before/after state diff.

**Acceptance Criteria:**
- GIVEN any state-changing API request (POST/PUT/PATCH/DELETE) succeeds, THEN an audit record is written in the same transaction as the state change, containing: `audit_id` (UUID), `actor_id`, `action` (e.g. `definition.activate`), `resource_type`, `resource_id`, `timestamp`, `before_state` (JSON or null), `after_state` (JSON or null).
- `GET /audit` lists audit records; filterable by `actor_id`, `resource_type`, `resource_id`, `from` / `to` timestamps. Paginated (API-06).
- Audit records are immutable after creation; no API permits modification or deletion of audit records.
- Read-only requests (GET) MUST NOT generate audit records.

**See:** OBS-05 (discard action from dead letter queue requires an audit record), DB-03 (audit write is atomic with state change)

**Edge cases:**
- Audit log table unavailable during a write: the entire transaction (including the state change) MUST fail to maintain consistency.
- Audit records for cancelled token requests: audit is still written if the request authenticated and took an action.

---

### OBS-04 — Instance timeline view `[MUST]`

> The API SHALL provide `GET /instances/:id/timeline` returning a human-readable sequence of events, task completions, and actor actions, suitable for display in a monitoring UI.

**Acceptance Criteria:**
- `GET /instances/:id/timeline` returns HTTP 200 with events in ascending chronological order.
- Each timeline entry includes: `event_type`, `timestamp`, `actor_display_name` (or `"system"` for automated events), `description` (human-readable text), and relevant context fields (e.g. task_id, node_id).
- Results are paginated per API-06.
- Any authenticated role may access the timeline.
- HTTP 404 if the instance does not exist.

**See:** ES-02 (underlying event log), ES-07 (archived events included in timeline), API-06 (pagination), IDN-01 (actor display names resolved from user registry)

**Edge cases:**
- Instance created by an automated API token with no associated user: `actor_display_name = "system"` or the token's description.
- Timeline for a CANCELLED instance: returns complete event history including the `INSTANCE_CANCELLED` event.

---

### OBS-05 — Dead letter queue `[MUST]`

> Events or timer firings that fail processing after N retries (configurable, default 3) SHALL be moved to a dead letter store with full context. Operators with PROCESS_OPERATOR role or above SHALL be able to inspect, retry, or discard dead-letter items via API.

**Acceptance Criteria:**
- GIVEN a processing failure (SERVICE_TASK, webhook dispatch, or timer firing) that has exceeded N retries (default 3), WHEN the N-th retry fails, THEN the item is moved to the dead letter store with full context: original payload, instance_id, error chain, timestamp.
- `GET /dlq` returns dead-letter items, paginated, filterable by `instance_id` and `item_type`. Requires PROCESS_OPERATOR or above.
- `POST /dlq/:id/retry` re-submits the item for processing; retry counter is reset to 0. Requires PROCESS_OPERATOR or above.
- `POST /dlq/:id/discard` permanently removes the item from the DLQ and appends an audit record per OBS-03. Requires PROCESS_OPERATOR or above.

**See:** EXT-01 (SERVICE_TASK exhausted retries feed DLQ), EXT-02 (webhook failures feed DLQ), OBS-03 (discard generates audit record), OBS-06 (DLQ depth threshold triggers alerting hook)

**Edge cases:**
- Retrying a DLQ item that belongs to a CANCELLED instance: the retry is rejected with HTTP 409; the item is discarded.
- Retrying a DLQ item that succeeds: item is removed from DLQ; instance resumes.

---

### OBS-06 — Alerting hooks `[SHOULD]`

> The platform SHALL support configurable webhook calls on defined system events: instance stuck in ERROR for > N minutes, DLQ depth exceeds threshold, scheduler lag exceeds threshold.

**Acceptance Criteria:**
- GIVEN an alerting webhook is configured for "instance stuck in ERROR > N minutes", WHEN an instance has been in ERROR status for > N consecutive minutes, THEN the platform delivers a POST to the configured URL with a JSON body identifying the instance, error reason, and duration.
- GIVEN a DLQ depth threshold is configured, WHEN the DLQ item count crosses the threshold, THEN the alerting hook fires ONCE. It does not re-fire on every poll while depth remains above threshold.
- GIVEN a scheduler lag threshold is configured, WHEN the scheduler detects its actual poll interval exceeds the threshold (e.g. due to lock contention), THEN the alerting hook fires.
- Failed alert deliveries are retried 3 times with exponential backoff; after 3 failures, the failure is logged (OBS-01) but no further action is taken.

**See:** OBS-05 (DLQ depth monitored here), SCH-02 (scheduler lag source), EXT-02 (subscription pause notified via this mechanism)

**Edge cases:**
- Multiple instances simultaneously entering ERROR state: one alert per instance (not one aggregate alert).
- DLQ depth drops below threshold then rises again: hook fires again on the second crossing.

---

### EXT-01 — Service task node type `[MUST]`

> The platform SHALL support a SERVICE_TASK node type that invokes an external HTTP endpoint (URL, method, and optional headers defined in the node configuration) as part of process execution. Response payload (on HTTP 2xx) is merged into instance variables. **Failure handling:** configurable timeout (default 30s); on timeout, non-2xx response, or network error, the platform SHALL retry up to N times (configurable per node, default 3) with exponential back-off. After exhausting retries, the failed invocation is moved to the DLQ (OBS-05) and the instance transitions to ERROR status (EE-10).

**Acceptance Criteria:**
- GIVEN execution reaches a SERVICE_TASK node, WHEN the HTTP call receives an HTTP 2xx response, THEN the JSON response body is merged into instance variables per EE-09.
- GIVEN an HTTP 2xx response body that is not a JSON object, THEN it is NOT merged; instance transitions to ERROR (EE-10).
- Timeout default is 30 seconds; configurable per node via `timeout_ms`. On timeout: counted as a failure, retry logic applies.
- GIVEN N retries are exhausted, THEN the failed invocation is moved to OBS-05 DLQ and the instance transitions to ERROR per EE-10.
- The platform MUST NOT follow HTTP redirects automatically. Redirect responses (3xx) MUST be treated as failures.

**See:** EE-09 (response merge into variables), EE-10 (ERROR path on exhausted retries), OBS-05 (DLQ storage), API-09 (trace_id included in outgoing request headers)

**Edge cases:**
- SERVICE_TASK URL containing a template variable that resolves to an empty string: rejected at node activation with EE-10.
- HTTP 429 from the external service: treated as a failure; retry logic applies.

---

### EXT-02 — Webhook event dispatch `[MUST]`

> The platform SHALL dispatch outbound webhook calls on: instance started, instance completed, instance errored, task activated, task completed. Subscribers register via API with a target URL and event filter. Delivery is **at-least-once**: failed deliveries are retried with exponential back-off up to 5 attempts. After 5 failures, the subscription is paused and the operator is notified via OBS-06. Subscribers SHOULD verify a shared HMAC-SHA256 signature in the `X-BPM-Signature` request header.

**Acceptance Criteria:**
- `POST /webhooks/subscriptions` creates a subscription with: `target_url`, `event_types` (array), optional `secret` for HMAC. Returns HTTP 201.
- GIVEN a matching event occurs, WHEN the platform dispatches the webhook, THEN it sends an HTTP POST to `target_url` with: JSON body (event type, instance_id, timestamp, payload), `X-BPM-Signature: sha256=<HMAC-SHA256-of-body>` header (if `secret` is configured).
- Delivery is at-least-once: if the target returns non-2xx or times out, the platform retries with exponential backoff, up to 5 attempts.
- GIVEN 5 consecutive delivery failures, THEN the subscription status is set to PAUSED and an OBS-06 alert is triggered.
- `GET /webhooks/subscriptions` and `DELETE /webhooks/subscriptions/:id` are provided. Requires PLATFORM_ADMIN.

**See:** OBS-06 (alerts on subscription pause), OBS-03 (subscription creation/deletion is audited), EXT-01 (SERVICE_TASK is a different outbound mechanism)

**Edge cases:**
- Target URL returns HTTP 200 but with an invalid JSON body: treated as a successful delivery (HTTP 2xx received).
- Same event triggers multiple subscriptions: each subscription has its own independent retry counter.

---

### EXT-03 — Plugin interface `[SHOULD]`

> The platform SHALL define a stable internal interface for registering custom node type handlers. A handler receives the current instance context and returns an outcome. Handlers are registered at startup.

**Acceptance Criteria:**
- GIVEN a plugin is registered at platform startup, WHEN execution reaches a node with the plugin's registered type, THEN the platform calls the plugin handler with the current instance context (variables, node config).
- Plugin handlers MUST return one of: `COMPLETE` (with optional output variables), `ERROR` (with a reason string).
- GIVEN a plugin handler panics, WHEN the panic is caught by the platform, THEN it is treated as `ERROR` outcome and EE-10 is applied.
- Plugins are registered in-process at startup only; no dynamic loading at runtime.
- A stable Zig interface type is defined; changes to it constitute a breaking API change requiring a major version bump.

**See:** EE-10 (ERROR outcome from plugin triggers this), EE-09 (COMPLETE with output variables uses this merge)

**Edge cases:**
- Plugin registered for a node type that also has a built-in handler: plugin takes precedence; built-in is shadowed.

---

### EXT-04 — Variable transformer `[SHOULD]`

> Process definitions SHALL support declaration of CEL variable transformation expressions on edges, allowing field mapping or computation between task output and next task input without a gateway node.

**Acceptance Criteria:**
- GIVEN an edge in a process definition with a `transform` CEL expression, WHEN the execution token traverses that edge, THEN the CEL expression is evaluated against the current instance variables, and the result (which MUST be a JSON object) is merged into the instance variables per EE-09.
- GIVEN the CEL expression returns a non-object type, THEN the transform is an error and EE-10 is applied.
- CEL transformer expressions are validated at definition activation time (PD-02); invalid CEL syntax is rejected at definition time.
- Transformer expressions are evaluated AFTER task output merge (EE-09) and BEFORE next-node activation.

**See:** EE-09 (merge used for transformer output), PD-06 (CEL expressions validated at definition time), EE-05 (CEL evaluation context is the same)

**Edge cases:**
- Expression accesses a variable that doesn't exist yet: CEL returns a runtime error → EE-10.
- Empty transform expression `""`: treated as no transformer; edge is followed without transformation.

---

### EXT-05 — Sub-process support `[SHOULD]`

> The platform SHALL support a SUB_PROCESS node type that starts a child process instance from a referenced definition. The parent instance waits for the child to complete before continuing. **Child failure handling:** if the child instance transitions to ERROR status, the parent also transitions to ERROR status and appends a `CHILD_PROCESS_ERROR` event referencing the child instance ID. If the child is cancelled externally, the parent also transitions to ERROR status with a `CHILD_PROCESS_CANCELLED` event. Sub-processes do not support timeout at this stage; that is deferred to a future requirement.

**Acceptance Criteria:**
- GIVEN execution reaches a SUB_PROCESS node, WHEN activated, THEN a child instance is started from the referenced definition; the parent token enters a WAITING state.
- The child instance inherits a copy of the parent's variable map at the time of activation. Mutations in the child do NOT affect the parent.
- GIVEN the child instance reaches COMPLETED status, WHEN the completion event is detected, THEN the parent token advances past the SUB_PROCESS node and the child's output variables are merged into the parent per EE-09.
- GIVEN the child instance transitions to ERROR, THEN the parent also transitions to ERROR and a `CHILD_PROCESS_ERROR` event is appended containing the child's `instance_id`.
- GIVEN the child instance is cancelled externally (EE-08), THEN the parent also transitions to ERROR and a `CHILD_PROCESS_CANCELLED` event is appended.
- Cancelling the parent instance (EE-08) MUST NOT cascade to the child; the child continues independently.

**See:** EE-01 (child instance start reuses this logic), EE-08 (cancel parent does not cancel child), EE-09 (child output merged to parent on completion), EE-10 (ERROR state for parent on child failure)

**Edge cases:**
- Child definition is deprecated between parent activation and child completion: child instance uses the snapshot captured at start time (EE-01 snapshot rule).
- Parent cancelled while child is in WAITING for its own sub-process: parent cancels; child continues independently.

---

## Appendix A — Requirement Count Summary

| Stage | MUST | SHOULD | COULD | Total |
|---|---|---|---|---|
| Stage 1 — Event Store & Infrastructure | 8 (ES) + 4 (DB) = **12** | 2 | 0 | **14** |
| Stage 2 — Process Definition Model | **8** | 1 | 1 | **10** |
| Stage 3 — Execution Engine | **12** | 0 | 0 | **12** |
| Stage 4 — REST API & Authentication | **10** | 2 | 0 | **12** |
| Stage 5 — Scheduler & Identity | **9** | 2 | 0 | **11** |
| Stage 6 — Observability & Extensions | **7** | 4 | 0 | **11** |
| **Total** | **58** | **11** | **1** | **70** |

NFRs and constraints are not counted in the table above as they are cross-cutting.

---

## Appendix B — Guiding Design Principles

### Event sourcing as ground truth

No state is stored as mutable rows updated in place. All state is derived by projecting the immutable event log. Projected state may be cached in read-model tables for performance, but the event log is always authoritative.

### Explicit over magic

The platform avoids implicit behaviour. Every transition, every variable mutation, every timer firing must be traceable to a specific event in the log. There is no hidden framework magic.

### Platform/application separation

The platform has no knowledge of ERP, CRM, or HRM domain concepts. Application-level logic lives above the platform API boundary. The platform provides mechanism; applications provide policy.

### Incremental correctness

Each stage must be fully correct and tested before the next stage begins. A working Stage 3 with no scheduler is better than a half-working Stage 5. Scope is reduced before quality is reduced.

### Crash safety

The platform assumes it can be killed at any point. Every write is designed so that a crash either fully committed or fully rolled back. There are no multi-step sequences that leave the system in a partially written state without recovery capability.
