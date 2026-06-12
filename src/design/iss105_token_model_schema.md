# ISS-105: Persist the New Token Model ({token_id, node_id} + join_counters)

**Status:** Draft
**Classification:** Type E (schema change + serde + backfill -- cross-cutting)
**Requirement:** [ISS-105] from `docs/requirements/BPM_Architecture_Backlog.20260611.md`
**Epic:** EPIC-1 (Schema & migrations)
**Priority:** P0
**Design date:** 2026-06-12

---

## Purpose

Add two new JSONB columns (`active_tokens`, `join_counters`) to `instance_projections`
so the database stores the token multiset shape `[{token_id, node_id, branch_id}]` and
per-join-gateway convergence counters. This replaces the legacy `current_nodes` flat
string array with a structured projection that ISS-206 (engine token logic) depends on.
The change is additive: no columns are dropped, and a backfill converts existing rows.

---

## Public Interface

### Database columns added

| Column | Type | Default | Module |
|---|---|---|---|
| `instance_projections.active_tokens` | `JSONB NOT NULL` | `'[]'` | All instance write paths |
| `instance_projections.join_counters` | `JSONB NOT NULL` | `'{}'` | Parallel gateway joins |

### Zig functions affected

All functions are in `src/engine/instance.zig` (InstanceStore):

| Function | Change |
|---|---|
| `create()` | Serialize tokens with `token_id`; write `active_tokens` + `join_counters` alongside `current_nodes` |
| `applyTransition()` | Same as create -- serialize with `token_id`; write both columns |
| `completeTask()` | ADD `token_id` to token serialization; ADD `active_tokens` + `join_counters` to UPDATE |
| `cancelInstance()` | ADD `active_tokens = '[]'` to UPDATE |
| `setInstanceError()` | ADD `active_tokens = '[]'` to UPDATE |
| `getById()` | Read `active_tokens` (with COALESCE fallback for backfill safety) |

No new public functions are added. The change is internal to existing write/read paths.

### Migration

File: `migrations/084_instances_token_model_backfill.sql` (or amend existing `083_instances_token_model.sql`)

Steps: ADD COLUMN active_tokens, ADD COLUMN join_counters, backfill old-format rows, create GIN index.

---

## Error Taxonomy

| Error | Severity | Trigger | Recovery |
|---|---|---|---|
| Backfill collision on token_id | MINOR | gen_random_uuid() collision (negligible probability) | Re-run backfill; affected row count = 0 in practice |
| join_counters parse failure | MAJOR | Corrupted JSONB in column | Row skipped during read; COALESCE('{}') fallback prevents crash |
| active_tokens shape mismatch | MAJOR | Old code writes string array while new code expects object array | New code tolerates both shapes during transition; backfill converts old rows |
| Migration applies on missing table | BLOCKER | `instance_projections` does not exist in schema | Guarded by `to_regclass()` check; migration is no-op |

---

## 1. Overview

ISS-105 changes the storage shape of instance token state from a bare `[]NodeId` array to a
structured `[{token_id, node_id, branch_id, ...}]` multiset, and adds a persisted
`join_counters` column for parallel gateway convergence. This is the storage/migration/serde
half of the token-model work; engine logic (token multiplicity, join counting) is ISS-206.

### 1.1 Current state (pre-ISS-105)

`instance_projections.current_nodes` is a JSONB array of plain node-id strings:

```json
["gateway_A", "task_review", "end_point"]
```

There is no `active_tokens` column and no `join_counters` column.

### 1.2 Target state (post-ISS-105)

`instance_projections.active_tokens` is a JSONB array of objects:

```json
[
  {"token_id": "a1b2c3d4-...", "node_id": "gateway_A", "branch_id": "<instance_id>/gateway_A/0"},
  {"token_id": "e5f6a7b8-...", "node_id": "task_review",  "branch_id": "<instance_id>/task_review/0"}
]
```

`instance_projections.join_counters` is a JSONB object keyed by join gateway node ID:

```json
{
  "join_gateway_1": {"received_count": 1, "expected_from_branches": 2}
}
```

`current_nodes` continues to hold the token array (same content as `active_tokens`) for
backward compatibility during the transition.

---

## 2. Schema Changes

### 2.1 New columns on `instance_projections`

| Column | Type | Default | Description |
|---|---|---|---|
| `active_tokens` | `JSONB NOT NULL` | `'[]'` | Token multiset array: `[{token_id, node_id, branch_id, ?waiting_child_instance_id}]` |
| `join_counters` | `JSONB NOT NULL` | `'{}'` | Per-join-node counter map: `{NodeId: {received_count, expected_from_branches}}` |

### 2.2 Token object shape

Each element in `active_tokens`:

| Field | Type | Required | Description |
|---|---|---|---|
| `token_id` | UUID string | yes | Stable token identity (UUID v4 for now; deterministic for replay -- see ISS-206) |
| `node_id` | TEXT | yes | Node ID the token currently occupies |
| `branch_id` | TEXT | yes | Branch lineage key: `<instance_id>/<split_gateway>/<edge_index>` |
| `waiting_child_instance_id` | UUID string | no | Set when a token on a SUBPROCESS node awaits child completion |

### 2.3 Join counter object shape

Per-node entry in `join_counters`:

| Field | Type | Description |
|---|---|---|
| `received_count` | integer | How many tokens have arrived at this join so far |
| `expected_from_branches` | integer | Total branches expected (set when the parallel split activates) |

---

## 3. Migration Strategy

### 3.1 Migration file

Check `migrations/` for the highest existing number. Use the next available slot.

The migration must:

1. **ADD COLUMN `active_tokens`** -- `JSONB NOT NULL DEFAULT '[]'`
2. **ADD COLUMN `join_counters`** -- `JSONB NOT NULL DEFAULT '{}'`
3. **Backfill `active_tokens`** -- convert existing `current_nodes` arrays from `["node_A", "node_B"]` to `[{"token_id": "<generated_uuid>", "node_id": "node_A", "branch_id": "<derived>"}, ...]`
4. **Create GIN index** on `active_tokens` for query optimization

### 3.2 Additive-only principle

The migration is **additive only** -- no DROP COLUMN, no destructive change.
The old `current_nodes` column is preserved. Code writes both `current_nodes` and
`active_tokens` during the transition period. When all code paths read from `active_tokens`,
a follow-up issue may remove the `current_nodes` column.

### 3.3 Idempotency

- `ADD COLUMN IF NOT EXISTS` for both columns
- Guard against missing table via `to_regclass('instance_projections')`
- Index creation guarded by `IF NOT EXISTS` on `pg_indexes`

---

## 4. Backfill Approach

### 4.1 The problem

Existing rows have `current_nodes` as `["node_A", "node_B"]` (flat string array).
After the migration adds `active_tokens` with DEFAULT `'[]'`, these rows have an
empty `active_tokens` but non-empty `current_nodes`.

### 4.2 Conversion algorithm

For each row where `current_nodes` is a non-empty JSONB array and `active_tokens = '[]'`:

1. Parse `current_nodes` as JSONB array.
2. If the first element is a string (old format), convert each string to an object:
   - `token_id`: `gen_random_uuid()` (UUID v4)
   - `node_id`: the original string value
   - `branch_id`: `<instance_id>/<node_id>/0` (best-effort reconstruction from available data)
3. If the first element is already an object with `token_id` (new format), skip the row.
4. UPDATE `active_tokens` with the converted array.

### 4.3 Branch ID reconstruction for backfill

For rows being backfilled, the original `branch_id` is not recoverable from the old
`["node_A", "node_B"]` format. The backfill constructs a synthetic branch ID:

```
<instance_id_hex>/<node_id>/0
```

This is a best-effort reconstruction. The branch ID is used for cancellation targeting
(EE-07/EE-08). If a backfilled instance is later cancelled, the cancellation path
matches on branch ID prefix; the synthetic ID will work for instances that had a
single token per node (the common case before parallel gateways were introduced).

### 4.4 SQL pseudocode

```sql
UPDATE instance_projections
SET active_tokens = (
    SELECT jsonb_agg(
        jsonb_build_object(
            'token_id', gen_random_uuid()::text,
            'node_id', elem::text,
            'branch_id', instance_id::text || '/' || elem::text || '/0'
        )
    )
    FROM jsonb_array_elements_text(current_nodes) AS elem
)
WHERE current_nodes IS NOT NULL
  AND jsonb_typeof(current_nodes) = 'array'
  AND jsonb_array_length(current_nodes) > 0
  AND active_tokens = '[]'::jsonb
  AND (current_nodes -> 0) IS NOT NULL
  AND jsonb_typeof(current_nodes -> 0) = 'string';
```

The last two conditions ensure we only convert old-format rows (string elements),
not rows that have already been migrated (object elements).

---

## 5. Serde Changes in `src/engine/instance.zig`

### 5.1 Current state

The codebase already has partial ISS-105 serde in place:

- **Token serialization (write path):** `create()` and `applyTransition()` serialize tokens
  as `[{token_id, node_id, branch_id}]` JSON arrays. Token IDs are generated via
  `generateTokenId()` when missing.

- **Token deserialization (read path):** `completeTask()` deserializes `current_nodes` JSON
  into `[]Token`, parsing optional `token_id` and `waiting_child_instance_id` fields.

- **Join counters serialization:** `create()` and `applyTransition()` serialize
  `join_counters` via `std.json.Stringify.valueAlloc`.

- **Join counters deserialization:** `completeTask()` reads `join_counters` from
  `COALESCE(join_counters, '{}')` and deserializes it.

### 5.2 What needs to change

The serde code is already mostly implemented. The following gaps remain:

1. **`completeTask()` UPDATE statement** (line ~1756): The UPDATE in `completeTask()` currently
   sets `current_nodes` and `variables` but does **not** set `active_tokens` or `join_counters`.
   Both fields must be included in the UPDATE to keep the projection consistent.

2. **`completeTask()` token serialization** (lines 1675-1694): The token JSON builder in
   `completeTask()` does **not** include `token_id` in the serialized output. It must be
   updated to include `token_id` (same pattern as `create()` and `applyTransition()`).

3. **`cancelInstance()` UPDATE** (line ~2220): The UPDATE sets `current_nodes` to `'[]'` but
   does not set `active_tokens`. Both must be cleared together.

4. **`setInstanceError()` UPDATE** (line ~3400): Similar to cancel -- must update both
   `current_nodes` and `active_tokens`.

### 5.3 Serialization format (authoritative)

All write paths MUST use this JSON format for each token:

```json
{
  "token_id": "<uuid>",
  "node_id": "<node_id>",
  "branch_id": "<instance_id>/<split_node>/<edge_index>",
  "waiting_child_instance_id": "<uuid>"   // optional, only when set
}
```

Token IDs are generated via `generateTokenId()` (random UUID v4) when a `Token.token_id`
field is `null` or empty string. No token may be serialized without a `token_id`.

### 5.4 Deserialization contract

All read paths MUST tolerate:
- Missing `token_id` field (treat as null -- backfill rows may lack it)
- Missing `waiting_child_instance_id` field (treat as null)
- `join_counters` being NULL (treat as `{}` via COALESCE)

---

## 6. Replay Round-Trip Invariant

### 6.1 Statement

> Rebuilding an instance from its event stream MUST produce byte-identical
> `active_tokens` and `join_counters` as the projection stored during the
> original execution.

### 6.2 What makes this hold

1. **Deterministic token IDs (future):** ISS-206 will introduce deterministic token ID
   generation (UUID v3 from `(instance_id, node_id, branch_id, ordinal)`) so that replay
   produces identical token IDs. Until ISS-206, `generateTokenId()` uses random UUID v4,
   which means replay produces *different* token IDs. The ISS-105 round-trip test should
   verify structural equality (same tokens in same order, same node_id/branch_id values)
   while tolerating different `token_id` values until ISS-206 lands.

2. **Deterministic join counters:** Join counters are updated by the pure `transition()`
   function. Given the same event stream, `transition()` produces the same counter
   state deterministically.

3. **Event stream completeness:** The event store holds every state-changing event.
   Replay consumes the event stream in sequence order and calls `transition()` for each.
   Since `transition()` is pure (zero I/O), identical inputs produce identical outputs.

### 6.3 Round-trip test design

The integration test (Step 03) must:

1. Start an instance through the normal path -- capture `active_tokens` and `join_counters`
   from the projection row.
2. Reconstruct the instance by replaying its event stream through `transition()`.
3. Assert that the reconstructed `active_tokens` matches structurally (same `node_id`
   and `branch_id` values, same order) and `join_counters` matches byte-for-byte.
4. Assert that a backfilled old-format row round-trips correctly through replay.

---

## 7. Dependencies

| Dependency | Status | Notes |
|---|---|---|
| ISS-201 (transition returns TransitionResult) | MERGED | `join_counters` already in `InstanceState` |
| ISS-206 (engine token multiset logic) | PENDING | Consumes the schema changes from this issue |

---

## 8. Touchpoints

| File | Change |
|---|---|
| `migrations/0xx_instances_token_model_v2.sql` | New migration: ADD COLUMN + backfill |
| `src/engine/instance.zig` | Fix `completeTask()` token serialization to include `token_id`; add `active_tokens`/`join_counters` to UPDATE statements in `completeTask()`, `cancelInstance()`, `setInstanceError()` |
| `src/engine/transition.zig` | No changes (already has `join_counters` in InstanceState, Token.token_id field) |

Note: An earlier migration `083_instances_token_model.sql` exists but only adds columns
without the backfill step. A new migration (`084_instances_token_model_backfill.sql`)
should contain the complete additive migration with backfill.

---

## 9. Acceptance Criteria Mapping

| AC | Covered by |
|---|---|
| `active_tokens` stores `[{token_id, node_id}]` | Section 2.1, 2.2 |
| `join_counters JSONB NOT NULL DEFAULT '{}'` | Section 2.1 |
| Backfill converts existing `[node_id]` arrays | Section 4 |
| Replay reproduces identical state | Section 6 |
| No implementation code in this design | (this document contains no Zig/SQL code beyond pseudocode examples) |

---

## 10. Migration Numbering

The highest existing migration in `migrations/` is `086_iss107_tenant_storage_mode.sql`.
The next available number for an additive migration is `084` (083 is already used by
the partial migration). The new migration should be named:

```
084_instances_token_model_backfill.sql
```

Alternatively, if the existing `083_instances_token_model.sql` is amended to include
the backfill, no new file is needed. The decision should be documented in the
BACKEND-DEV handoff.
