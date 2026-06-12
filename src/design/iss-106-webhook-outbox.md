# Module: iss-106-webhook-outbox

**Covers:** ISS-106 (Webhook deliveries transactional-outbox table formalization)
**Related:** EXT-02 (webhook event dispatch — original table + dispatcher), ISS-205 (outbox insert + worker claim + back-off ladder — OUT OF SCOPE here)
**Primary design targets:** `migrations/084_iss106_webhook_deliveries_outbox.sql`

---

## Module purpose

ISS-106 formalizes the existing `webhook_deliveries` table into the transactional-outbox contract: a fixed column set, a constrained uppercase `status` domain `(PENDING, DELIVERED, FAILED, RETRYING)`, and a `(status, next_attempt_at)` worker-claim index. The table already exists (created in EXT-02), so the work is a single additive, idempotent reconciliation migration that brings the live table up to contract without destroying data and without touching the dispatcher/worker logic (that is ISS-205). The deliverable is one SQL migration file and nothing else.

---

## Why this is Type E (not Type C)

Per `templates/lego-catalog.md` selection rules, a migration normally classifies as **Type C**. ISS-106 does NOT fit the Type C codegen because the reconciliation requires three operations the Type C `mode: alter` codegen cannot emit:

1. **`DROP CONSTRAINT IF EXISTS` on the existing status CHECK** — `codegen_migration.py._emit_alter_table()` emits only `ADD COLUMN IF NOT EXISTS` and `ADD <constraint>`. It has no `DROP CONSTRAINT` path, so it cannot replace the existing status CHECK.
2. **A data-remap `UPDATE` of existing rows before the new CHECK is applied** — the existing rows hold lowercase status values (`pending`, `success`, `failed`, `exhausted`); the new CHECK only permits `(PENDING, DELIVERED, FAILED, RETRYING)`. Without a remap UPDATE executed *before* `ADD CONSTRAINT`, the migration would fail on any existing row. Type C YAML has no field to express an ordered "UPDATE then ADD CONSTRAINT" sequence.
3. **Ordering guarantees** — the remap UPDATE must run strictly between the DROP CONSTRAINT and the ADD CONSTRAINT. Type C emits statements grouped by kind, not by required execution order.

A wrongly-forced Type C here would silently drop the remap step and produce a migration that fails on existing tenant data. Therefore this is **Type E prose**, and the migration is implemented as hand-written SQL by BACKEND-DEV per the contract below.

---

## Scope

**IN SCOPE (ISS-106):**
- One additive, idempotent migration that reconciles the existing `webhook_deliveries` table to the ISS-106 outbox contract (columns + status CHECK values + worker-claim index).

**OUT OF SCOPE (ISS-205 — explicitly excluded):**
- The transactional-outbox INSERT that enqueues a delivery in the same transaction as the event commit.
- The `FOR UPDATE SKIP LOCKED` worker claim query.
- The exponential back-off ladder / `next_attempt_at` scheduling logic.
- Any change to `src/webhook/dispatcher.zig`, `src/webhook/subscription_store.zig`, or any Zig source. ISS-106 is **table + migration + index only**. No Zig is written for this issue.

---

## Current schema (discovered — authoritative)

The `webhook_deliveries` table already exists. Its current shape is the union of three migrations:

**Original CREATE TABLE — `migrations/010_dlq.sql` (lines 34–62):**

| Column | Type | Notes |
|---|---|---|
| `id` | `UUID` | `PRIMARY KEY DEFAULT gen_random_uuid()` |
| `subscription_id` | `UUID` | `NOT NULL REFERENCES webhook_subscriptions(id) ON DELETE CASCADE` |
| `event_id` | `UUID` | originally `NOT NULL REFERENCES events(event_id)` |
| `status` | `TEXT` | `NOT NULL DEFAULT 'pending'`; commented domain `'pending' \| 'success' \| 'failed' \| 'exhausted'` — **no explicit CHECK constraint in 010** |
| `attempt_count` | `INTEGER` | `NOT NULL DEFAULT 0` |
| `max_attempts` | `INTEGER` | `NOT NULL DEFAULT 5` |
| `next_attempt_at` | `TIMESTAMPTZ` | nullable in 010 |
| `last_attempt_at` | `TIMESTAMPTZ` | |
| `http_status` | `INTEGER` | |
| `response_body` | `TEXT` | |
| `error_message` | `TEXT` | |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` |
| `updated_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` |

Indexes from 010: `idx_wd_pending ON (next_attempt_at) WHERE status IN ('pending','failed')`, `idx_wd_subscription ON (subscription_id)`.

**`migrations/023_ext02_webhook_event_dispatch.sql` added (lines 24–44):** columns `event_type TEXT`, `instance_id UUID`, `payload_json JSONB`, `trace_id TEXT`, `delivered_at TIMESTAMPTZ`, `last_http_status INTEGER`, `last_error TEXT`; backfilled `next_attempt_at` to `NOW()` where NULL and set its `DEFAULT NOW()`; created `idx_wd_status_next_attempt ON (status, next_attempt_at)` and `idx_wd_event_type ON (event_type)`.

**`migrations/025_webhook_delivery_event_id_nullable.sql`:** `ALTER COLUMN event_id DROP NOT NULL`.

**Live status values in use** (`src/webhook/dispatcher.zig`): the running dispatcher writes lowercase `'pending'`, `'success'`, `'exhausted'`, `'failed'` to `status`, and reads/writes the `attempt_count` column. (It also writes `'PAUSED'` to the *subscription* row, not the delivery row.)

---

## ISS-106 contract vs. current state

Contract columns: `delivery_id`, `subscription_id`, `event_id`, `status ∈ (PENDING, DELIVERED, FAILED, RETRYING)`, `attempt`, `next_attempt_at`, `last_error`, `created_at`.
Contract index: `(status, next_attempt_at)` for worker claim.

| Contract element | Current state | Action required by 084 |
|---|---|---|
| `delivery_id` (PK) | exists as **`id`** (PK, `gen_random_uuid()`) | **Satisfied by `id`.** Do NOT rename — the live dispatcher and FK chains depend on `id`. Treat `id` as the logical `delivery_id`. (Renaming is a destructive change outside additive-first policy and would break ISS-205 code.) Documented as a naming alias, no DDL. |
| `subscription_id` | exists, `NOT NULL`, FK | none |
| `event_id` | exists, nullable (per 025) | none — already present |
| `status` values `(PENDING,DELIVERED,FAILED,RETRYING)` | `TEXT`, lowercase values, **no CHECK** | **remap existing rows → uppercase, then ADD CHECK** (see §Reconciliation) |
| `attempt` | exists as **`attempt_count`** (different name) | **ADD COLUMN `attempt INTEGER NOT NULL DEFAULT 0`** as an additive alias; backfill from `attempt_count`. Keep `attempt_count` (live dispatcher writes it — ISS-205 will converge the two). |
| `next_attempt_at` | exists, `DEFAULT NOW()` | none |
| `last_error` | exists (added in 023) | none |
| `created_at` | exists, `NOT NULL DEFAULT NOW()` | none |
| index `(status, next_attempt_at)` | `idx_wd_status_next_attempt` already exists (023) | **none — reconcile, do NOT duplicate.** Emit `CREATE INDEX IF NOT EXISTS idx_wd_status_next_attempt` so the migration is self-contained and idempotent even if 023 was skipped. |

**Net new DDL the 084 migration adds:** (1) `attempt` column + backfill; (2) status value remap + new status CHECK; (3) idempotent re-assertion of `idx_wd_status_next_attempt`. Everything else already exists.

---

## Reconciliation design (hand-written SQL contract for BACKEND-DEV)

The migration file is `migrations/084_iss106_webhook_deliveries_outbox.sql`. It MUST be additive, idempotent (re-runnable as a no-op), use **unqualified** table names (so it applies under each per-tenant `search_path`), and must NOT contain `DROP TABLE` or `DROP COLUMN`.

Implement exactly these steps, in this order:

### Step 1 — Add the `attempt` column (additive)

```
ALTER TABLE webhook_deliveries
    ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 0;
```

`IF NOT EXISTS` makes it idempotent. `NOT NULL DEFAULT 0` is safe on a populated table (existing rows get 0, then the backfill in Step 2 corrects them).

### Step 2 — Backfill `attempt` from the existing `attempt_count`

```
UPDATE webhook_deliveries
SET attempt = attempt_count
WHERE attempt IS DISTINCT FROM attempt_count;
```

Idempotent: once `attempt = attempt_count`, the `WHERE` matches nothing. `attempt_count` is retained (the live dispatcher writes it; ISS-205 owns converging the dispatcher onto `attempt`). This is a deliberate, documented temporary duplication, not an oversight.

### Step 3 — Remap existing status values to the uppercase domain (MUST run before Step 4)

The new CHECK only permits `(PENDING, DELIVERED, FAILED, RETRYING)`. Existing rows may hold legacy lowercase values. Remap them first so the CHECK cannot fail on existing data:

```
UPDATE webhook_deliveries
SET status = CASE status
    WHEN 'pending'   THEN 'PENDING'
    WHEN 'success'   THEN 'DELIVERED'
    WHEN 'failed'    THEN 'FAILED'
    WHEN 'exhausted' THEN 'FAILED'
    ELSE status
END
WHERE status IN ('pending', 'success', 'failed', 'exhausted');
```

Mapping rationale:
- `pending → PENDING` (queued, not yet delivered).
- `success → DELIVERED` (terminal success).
- `failed → FAILED` (the legacy `failed` meant "attempt failed, will retry"; under the new domain a row mid-retry is `RETRYING`, but legacy rows carry no flag distinguishing transient from terminal, so the conservative, CHECK-safe choice is `FAILED`. ISS-205, which owns retry scheduling, sets `RETRYING` on rows it re-queues; ISS-106 introduces no new `RETRYING` rows.)
- `exhausted → FAILED` (terminal failure after max attempts).
- `ELSE status` leaves any already-uppercase value untouched → **idempotent on re-run** (second run matches nothing in the `WHERE`, and any row already uppercase falls through `ELSE`).

`RETRYING` is a valid target value in the CHECK domain but is intentionally **not produced by this remap** — there is no legacy value that maps to it, and producing it is ISS-205's responsibility.

### Step 4 — Replace the status CHECK constraint

Drop any prior status CHECK (idempotent via `IF EXISTS`), then add the contract CHECK. Use a stable explicit constraint name so the operation is idempotent and matchable in tests:

```
ALTER TABLE webhook_deliveries
    DROP CONSTRAINT IF EXISTS webhook_deliveries_status_check;

ALTER TABLE webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_status_check
    CHECK (status IN ('PENDING', 'DELIVERED', 'FAILED', 'RETRYING'));
```

On re-run: the DROP removes the constraint added by the prior run, the ADD re-creates it identically → net no-op. The ADD is validated against the table; because Step 3 already remapped all rows, validation cannot fail.

> Note: there is no separate `DROP CONSTRAINT IF EXISTS` guard needed for a differently-named legacy CHECK — migration 010 created the column with an inline *comment* only, not a named CHECK, so no legacy CHECK constraint exists to collide. The `IF EXISTS` on our own constraint name is sufficient and safe.

### Step 5 — Re-assert the worker-claim index (reconcile, do not duplicate)

```
CREATE INDEX IF NOT EXISTS idx_wd_status_next_attempt
    ON webhook_deliveries (status, next_attempt_at);
```

`idx_wd_status_next_attempt` already exists from migration 023. Emitting it with `IF NOT EXISTS` makes 084 self-contained (correct even if applied to a schema where 023 was somehow skipped) and a no-op on the normal path. **No new index name is introduced** — the contract index `(status, next_attempt_at)` is exactly this existing index.

---

## Idempotency summary

Every statement is individually idempotent:
- Step 1: `ADD COLUMN IF NOT EXISTS`.
- Step 2 & 3: `UPDATE` guarded by a `WHERE` that matches nothing on the second run.
- Step 4: `DROP CONSTRAINT IF EXISTS` + deterministic re-`ADD` of the same named constraint.
- Step 5: `CREATE INDEX IF NOT EXISTS`.

Re-running `migrate` after 084 has been applied performs no schema change and no data change.

---

## Per-tenant application

All table names are **unqualified**. The migration runner applies each migration once per tenant schema with that schema on the `search_path`; unqualified `webhook_deliveries` resolves to the correct per-tenant table. No `public.`-qualified or otherwise schema-prefixed names appear (anti-patterns.md: schema-qualified names in migrations are forbidden). No `information_schema` lookups are used; if BACKEND-DEV adds any introspection, it MUST filter `AND table_schema = current_schema()` per anti-patterns.

---

## Public interface

This module adds **no Zig public functions** and **no API routes**. Its entire surface is the DDL contract above. The store/dispatcher continue to operate against `webhook_deliveries` unchanged for ISS-106; ISS-205 will introduce the outbox-insert and claim methods.

---

## Error taxonomy

No Zig error set is introduced (no Zig code). Migration-level failure modes and their mitigations:

| Failure mode | Cause | Mitigation in design |
|---|---|---|
| CHECK violation on `ADD CONSTRAINT` | An existing row holds a value not in the new domain | Step 3 remaps all known legacy values before Step 4; `ELSE status` plus the prior runs guarantee only the four target values (or already-valid uppercase) remain |
| `NOT NULL` violation on `ADD COLUMN attempt` | populated table | `DEFAULT 0` supplies a value for every existing row at add time |
| Duplicate index error | `idx_wd_status_next_attempt` already exists | `CREATE INDEX IF NOT EXISTS` |
| Duplicate column error on re-run | migration applied twice | `ADD COLUMN IF NOT EXISTS` |
| Duplicate constraint error on re-run | migration applied twice | `DROP CONSTRAINT IF EXISTS` precedes the `ADD` |

---

## Dependencies

- `migrations/010_dlq.sql` — original `webhook_deliveries` CREATE TABLE.
- `migrations/023_ext02_webhook_event_dispatch.sql` — added `last_error`, `next_attempt_at DEFAULT NOW()`, and the `idx_wd_status_next_attempt` index this contract reconciles.
- `migrations/025_webhook_delivery_event_id_nullable.sql` — `event_id` nullable.
- Migration number **084** is the next free numeric slot (latest numeric migration is `083_instances_token_model.sql`; `GBL-`-prefixed files are a separate global series and do not occupy numeric slots).

---

## Acceptance criteria mapping

| ISS-106 acceptance criterion | Where satisfied |
|---|---|
| Contract columns `delivery_id, subscription_id, event_id, status, attempt, next_attempt_at, last_error, created_at` | Current-state table (`id` as `delivery_id`, `subscription_id`, `event_id`, `status`, `next_attempt_at`, `last_error`, `created_at` already present) + Step 1 adds `attempt` |
| status ∈ (PENDING, DELIVERED, FAILED, RETRYING) | Step 3 (remap) + Step 4 (new CHECK) |
| Index `(status, next_attempt_at)` for worker claim, no duplication | Step 5 reconciles the existing `idx_wd_status_next_attempt` with `IF NOT EXISTS` |
| Lists existing vs added | §"ISS-106 contract vs current state" table |
| Additive + idempotent, no DROP TABLE/COLUMN, every tenant schema | §"Idempotency summary" + §"Per-tenant application" |
| Status CHECK reconciled; existing values migrated safely | Step 3 ordered before Step 4 |
| ISS-205 engine/dispatcher excluded | §"Scope" |

---

## Rollback strategy

Forward-only (append-only policy). If the outbox table must be retired, a future migration archives rows to a `webhook_deliveries_archive` table and supersedes this one — never a `DROP TABLE`/`DROP COLUMN`. The added `attempt` column and the status CHECK are non-destructive; reverting the status domain would itself be a forward remap migration.
