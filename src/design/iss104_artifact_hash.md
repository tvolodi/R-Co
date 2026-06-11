# ISS-104: Instance Artifact Hash — Design Document

**Requirement:** ISS-104 — Add `instances.artifact_hash` and populate at start  
**Epic:** EPIC-1 · **Priority:** P1 · **Stage:** Artifact Repository (§15)  
**Produced by:** CODE-DESIGNER · **Relates to:** ADP-05, §15.1 BPM_Platform_Backend_Architecture.md

---

## Overview

This design adds a nullable `artifact_hash TEXT` column to the `instances` table, enabling reproducibility and provenance tracking for instances executed against repository-backed process definitions. The hash is immutable once set and records the exact artifact version (by content) used at instance start.

**Key principle:** `definition_snapshot` remains authoritative for execution; `artifact_hash` is metadata for provenance and reproducibility.

---

## Table of Contents

1. [Module Purpose](#module-purpose)
2. [Public Interface — Code Integration Points](#public-interface--code-integration-points)
3. [Data Flow Diagram](#data-flow-diagram)
4. [Error Taxonomy](#error-taxonomy)
5. [State & Constraints](#state--constraints)
6. [Dependencies](#dependencies)
7. [Open Questions](#open-questions)

---

## Module Purpose

When an instance is started from a promoted process definition in the artifact repository, the execution engine records both:
- The **definition snapshot** (`instances.definition_snapshot`) — the full graph JSON, used for execution and replay.
- The **artifact hash** (`instances.artifact_hash`) — the SHA-256 content hash, used for reproducibility queries and audit linkage.

This design specifies:
1. When and how the hash is persisted (instance-start transaction).
2. Reproducibility query patterns.
3. Fallback and error handling.
4. Backward compatibility (legacy NULL).

---

## Public Interface — Code Integration Points

### 1. Instance Start Handler (`src/engine/instance.zig` :: StartInstanceRequest)

**Current behavior:**
```zig
// Pseudocode from src/engine/instance.zig
pub fn startInstance(
    tx: *const TransactionHandle,
    definition_id: UUID,
    correlation_key: ?[]const u8,
    variables: JsonObject,
    // ...
) !UUID {
    const snap = try loadDefinitionSnapshot(tx, definition_id);
    const instance_id = gen_random_uuid();
    try insertInstance(tx, .{
        .instance_id = instance_id,
        .definition_id = definition_id,
        .definition_snapshot = snap,
        // ... other fields
    });
    // ...
}
```

**New behavior (ISS-104):**
1. After loading the definition snapshot, check if it came from the repository.
   - **Repository-backed path:** The handler loads `definition_id` from the definition registry. Cross-reference the registry with the artifacts table to find the matching artifact record.
   - **Non-repository path:** artifact_hash = NULL.
2. If repository-backed, call `artifacts.zig :: getContentHashByDefinitionId()` to retrieve the hash.
3. Persist both snapshot and hash in the same `insertInstance()` transaction:
   ```zig
   try insertInstance(tx, .{
       .instance_id = instance_id,
       .definition_id = definition_id,
       .definition_snapshot = snap,
       .artifact_hash = optional_hash,  // NULL if unavailable or non-repo path
       // ... other fields
   });
   ```
4. If hash lookup fails (artifact not found, repository unavailable), log warning and continue with NULL. The instance is valid; snapshot is authoritative.

**Error handling:**
- If `getContentHashByDefinitionId()` returns `ArtifactStoreError.NotFound` → set artifact_hash = NULL and continue.
- If `getContentHashByDefinitionId()` returns `ArtifactStoreError.RepositoryUnavailable` → log warning, set artifact_hash = NULL and continue.
- If `insertInstance()` fails due to schema validation → propagate error as before (instance-start fails).

**No changes to error set** — existing `StartInstanceError` set covers this flow.

### 2. Artifact Store (`src/repository/artifacts.zig`)

**New public function:**
```zig
pub fn getContentHashByDefinitionId(
    self: *ArtifactStore,
    tx: *const TransactionHandle,
    definition_id: UUID,
) ArtifactStoreError!?[]const u8
{
    // Query artifacts table:
    // SELECT content_hash FROM artifacts
    //   WHERE definition_id = $1 AND is_promoted = true
    //   ORDER BY promoted_at DESC LIMIT 1;
    // Return the most recently promoted artifact's hash.
    // Return null if no promoted artifact exists for this definition.
}
```

**Guarantees:**
- Hash is immutable (never updated after insertion).
- Query returns the most recent promoted version for a definition_id.
- If definition_id has no promoted artifact, returns NULL (non-repository definition).

**Error cases:**
- `ArtifactStoreError.NotFound` — definition_id exists but has no promoted artifacts.
- `ArtifactStoreError.RepositoryUnavailable` — transaction cannot connect to artifacts table (db offline, transaction error). Caller must handle gracefully (set to NULL).

### 3. Reproducibility Queries (Caller Responsibility)

**Pattern for resolving an instance to its artifact:**
```sql
-- Step 1: Fetch instance with its artifact hash.
SELECT instance_id, artifact_hash, definition_snapshot
  FROM instances
  WHERE instance_id = $1;

-- Step 2: If artifact_hash IS NOT NULL, resolve the artifact.
SELECT artifact_id, content_hash, promoted_at, metadata
  FROM artifacts
  WHERE content_hash = $2
  ORDER BY promoted_at DESC
  LIMIT 1;
```

**Ownership:** Callers (API endpoints, audit functions) implement this pattern as needed. The migration does not include a stored procedure or view; this is intentional (let callers choose their join logic).

---

## Data Flow Diagram

```
Client: Start Instance
        ↓
   Load Definition (Registry)
        ↓
   Is Repo-Backed?
   ↙ YES      ↘ NO
  ↓            ↓
Artifact      hash = NULL
Store
Get Hash
  ↓
Found?
↙ YES ↘ NO
hash  NULL
  ↓ ↓
  INSERT instances
  (artifact_hash = $value)
  + INSTANCE_STARTED event
        ↓
    201 {id}
```

---

## Error Taxonomy

### Instance-Start Errors (pre-existing; no changes)

These errors from `startInstance()` pre-date this design and are unaffected:

| Error | Cause | Handler |
|---|---|---|
| `InstanceError.DefinitionNotFound` | `definition_id` doesn't exist in registry | → 404 |
| `InstanceError.InvalidVariables` | Payload validation fails | → 422 |
| `InstanceError.CorrelationKeyExists` | Duplicate correlation key | → 409 |
| `InstanceError.TransactionFailed` | DB transaction rolled back (deadlock, etc.) | → 503 |

### Artifact Hash Resolution Errors (new)

These errors occur during hash lookup and are handled **gracefully** (set artifact_hash = NULL):

| Error | Cause | Handler |
|---|---|---|
| `ArtifactStoreError.NotFound` | Definition exists but no promoted artifact | Set artifact_hash = NULL, continue |
| `ArtifactStoreError.RepositoryUnavailable` | DB/transaction error during hash lookup | Log warning, set artifact_hash = NULL, continue |

**No user-facing error:** Instance-start succeeds even if hash is unavailable. Instance validity does not depend on artifact_hash.

---

## State & Constraints

### Column Specification

```sql
ALTER TABLE instances ADD COLUMN artifact_hash TEXT NULL;
```

- **Type:** TEXT
- **Nullable:** YES (critical for backward compatibility)
- **Default:** NULL
- **Indexed:** NO (hash is not a lookup key; unique constraint is content_hash in artifacts table)
- **Constraint:** None (no CHECK, no UNIQUE)

### Invariants

1. **Immutability:** Once set at instance-start, `artifact_hash` never changes. No UPDATE permitted by application code.
2. **Content:** Must be a valid SHA-256 hex string (64 characters) if non-NULL. **Validation responsibility:** ArtifactStore.
3. **Provenance:** If non-NULL, `artifact_hash` uniquely identifies the definition version used at instance start (via JOIN on artifacts.content_hash).
4. **Backward Compatibility:** Legacy instances (created before this migration) have artifact_hash = NULL; they remain valid and executable (snapshot is authoritative).

### Semantics of NULL vs. Non-NULL

| Scenario | artifact_hash | Meaning | Reproducibility |
|---|---|---|---|
| Repo-backed start, hash found | `"sha256:abc..."` | Instance executed against a versioned artifact | ✅ Can query artifacts table to resolve exact version |
| Repo-backed start, hash unavailable | `NULL` | Definition came from repo but hash lookup failed (artifact not found, DB issue) | ⚠️ Snapshot is authoritative; artifact version unknown |
| Non-repo definition start | `NULL` | Definition loaded directly (not from repo) | ⚠️ Snapshot is authoritative; no artifact version exists |
| Legacy instance (pre-migration) | `NULL` | Instance created before artifact_hash column existed | ⚠️ Snapshot is authoritative |

**Reconstruction behavior:** When replaying an instance for state reconstruction:
1. Load instance row; check if `artifact_hash IS NOT NULL`.
2. If non-NULL, attempt repository resolution (prefer artifact).
3. If NULL or artifact not found, fall back to `definition_snapshot` (existing behavior).

---

## Dependencies

### Inbound Dependencies (Who calls this?)

- **Instance-start handler** (`src/engine/instance.zig`) — must call `getContentHashByDefinitionId()` if definition is repo-backed.
- **Reproducibility queries** — external (API endpoints, audit) — use artifact_hash in joins.

### Outbound Dependencies (What this calls)

- **Definition Registry** (`src/repository/definitions.zig`) — already called by instance-start to load snapshot.
- **Artifact Store** (`src/repository/artifacts.zig`) — NEW dependency — `getContentHashByDefinitionId()` queries artifacts table.
- **Database transaction** (`src/db/transaction.zig`) — unchanged.
- **UUID generation** — unchanged.

### No changes to

- **Execution engine** (`src/engine/transition.zig`) — zero I/O, pure function. No changes.
- **Event Store** (`src/event/store.zig`) — unchanged. Artifact hash is not part of event payloads (it's instance metadata).
- **Task Manager** (`src/task/manager.zig`) — unchanged.

---

## Open Questions

1. **Repository-backed detection logic:** How does instance-start determine if a definition_id is repo-backed?
   - **Current assumption:** A definition_id with a matching record in `artifacts` table (filtered by is_promoted = true) is repo-backed.
   - **Alternative:** An explicit `backend_type` or `source` field in definitions table or artifacts table.
   - **CLARIFICATION NEEDED:** Confirm the repo-backed detection strategy before BACKEND-DEV implements.

2. **Hash computation & storage:** Who computes the hash?
   - **Current assumption:** The hash is pre-computed when the artifact is promoted and stored in the artifacts table.
   - **Artifact Store responsibility:** `getContentHashByDefinitionId()` merely reads the pre-computed hash from artifacts.
   - **CLARIFICATION NEEDED:** Confirm that artifact promotion (src/repository/artifacts.zig :: promote()) computes and stores content_hash.

3. **Audit of NULL artifacts:** Should there be an audit log entry if hash lookup fails?
   - **Current design:** Silent fallback to NULL (warning in logs).
   - **Alternative:** Audit log entry: INSTANCE_HASH_UNAVAILABLE.
   - **CLARIFICATION NEEDED:** Does ISS-104 require audit entries for unavailable hashes, or is that a separate requirement?

4. **Determinism in reproducibility:** Is a single instance allowed to match multiple artifacts (e.g., if two artifacts have the same content hash)?
   - **Current assumption:** No. Content hash uniqueness is enforced in artifacts table.
   - **CLARIFICATION NEEDED:** Confirm that (artifacts.content_hash) is UNIQUE or treated as a natural key.

---

## Integration Checklist (for BACKEND-DEV)

- [ ] Migration generated and applied successfully (zig build migrate exits 0)
- [ ] `getContentHashByDefinitionId()` implemented in `src/repository/artifacts.zig`
- [ ] Instance-start modified to call `getContentHashByDefinitionId()` when definition is repo-backed
- [ ] Artifact hash persisted in `insertInstance()` transaction
- [ ] Error cases (NotFound, RepositoryUnavailable) handled gracefully → NULL fallback
- [ ] No changes to error set or function signatures in `instance.zig`
- [ ] No changes to execution engine (transition.zig)
- [ ] Integration test: start instance from promoted artifact, assert artifact_hash matches
- [ ] Integration test: start instance with legacy non-repo path, assert artifact_hash = NULL
- [ ] Reproducibility query works: (instance_id, artifact_hash) → artifacts table join succeeds
