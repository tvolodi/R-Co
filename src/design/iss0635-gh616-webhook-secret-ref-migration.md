# iss0635-gh616-webhook-secret-ref-migration — Corrective Migration Design

**Issue:** ISS-0635 / GH #616  
**Run:** WF03-GH616-20260809 Step 2 (CODE-DESIGNER)  
**Type:** C (corrective migration, all\_schemas scope)  
**Migration file:** `migrations/1138_iss0635_webhook_secret_ref_corrective.sql`

---

## Purpose

Migration 1134 was declared `-- scope: public` and iterated over tenant rows to add
`secret_ref` and `secret_key_id` columns to each SCHEMA-mode tenant's
`webhook_subscriptions` table. However, it ran before any SCHEMA-mode tenant schemas
were provisioned: all 21 schemas (including `tenant_default`) were created after the
ledger row was written, so the `webhook_subscriptions` table did not exist for any
tenant when migration 1134 iterated. The `IF EXISTS` table guard correctly no-opped,
but the public-pass ledger row prevents re-application.

This corrective migration (number 1138) carries **no** `-- scope: public` header, so
the migration runner executes it for every schema (`all_schemas` mode). For each
tenant schema whose `webhook_subscriptions` table exists, the migration adds the two
missing columns idempotently via `ADD COLUMN IF NOT EXISTS` and backfills any rows
whose `secret_ref` or `secret_key_id` is NULL.

---

## Public Interface

Single `DO $$...$$` block, no external parameters. The migration runner calls
`runForSchema(allocator, pool, migrations_dir, schema_name, false)` for each schema.
Before executing the file, the runner issues `SET search_path TO <schema_name>,public`,
so unqualified table names resolve to the target schema.

**No-op conditions:**
- Schema = `public` — `webhook_subscriptions` was dropped by GBL-073; `IF EXISTS`
  guard short-circuits.
- Any tenant schema where `webhook_subscriptions` has not yet been provisioned.
- Any tenant schema where both columns are already present and all rows have non-NULL
  values (the `ADD COLUMN IF NOT EXISTS` is a no-op; the UPDATE touches zero rows).

**Action condition:**
- Any tenant schema where `webhook_subscriptions` exists and either column is absent or
  any row has a NULL value.

---

## SQL

```sql
-- 1138_iss0635_webhook_secret_ref_corrective.sql
-- ISS-0635 / GH-616: corrective — missing secret_ref/secret_key_id columns
-- in tenant webhook_subscriptions tables provisioned after migration 1134.
-- No -- scope: public header: executed for every schema (all_schemas mode).
DO $$
DECLARE
    v_schema TEXT := current_schema();
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = v_schema
          AND table_name = 'webhook_subscriptions'
    ) THEN
        RAISE NOTICE 'ISS-0635: webhook_subscriptions absent in schema % — no-op', v_schema;
    ELSE
        ALTER TABLE webhook_subscriptions
            ADD COLUMN IF NOT EXISTS secret_ref TEXT,
            ADD COLUMN IF NOT EXISTS secret_key_id TEXT;
        UPDATE webhook_subscriptions ws
        SET
            secret_ref    = COALESCE(ws.secret_ref,
                'sec://tenant/' || COALESCE(
                    (SELECT t.slug FROM public.tenant t
                     WHERE (v_schema = 'tenant_default'
                            AND t.id = '00000000-0000-0000-0000-000000000000'::uuid)
                        OR ('tenant_' || replace(t.id::text, '-', '') = v_schema)
                     LIMIT 1),
                    v_schema
                ) || '/webhook/subscription-' || ws.id::text),
            secret_key_id = COALESCE(ws.secret_key_id, 'legacy')
        WHERE ws.secret_ref IS NULL OR ws.secret_key_id IS NULL;
        RAISE NOTICE 'ISS-0635: Confirmed secret_ref/secret_key_id in %.webhook_subscriptions', v_schema;
    END IF;
END $$;
```

### Scope annotation rules

| Header present | Execution mode |
|---|---|
| `-- scope: public` | Public pass only; skipped in per-tenant passes |
| None (this migration) | All schemas — public pass + every tenant schema pass |

### Idempotency

`ADD COLUMN IF NOT EXISTS` is safe to re-run. The `UPDATE` only touches rows where
`secret_ref IS NULL OR secret_key_id IS NULL`; rows already populated are untouched.
A second application of the migration for the same schema produces zero DDL changes
and zero DML rows affected.

---

## Error Cases

| Condition | Source | Handling |
|---|---|---|
| `webhook_subscriptions` absent | Not an error; guard skips via NOTICE | No action required |
| `information_schema.tables` inaccessible | Should not occur; always available | Migration fails; runner rolls back and returns `MigrationFailed` |
| `public.tenant` inaccessible | search_path includes `public`; this should not occur | Migration fails; runner rolls back |
| Column already exists with wrong type | Cannot happen; `ADD COLUMN IF NOT EXISTS` is a no-op when column exists | No action required |
| `secret_key_id` column already present, `secret_ref` absent | Handled; both columns added independently via separate `ADD COLUMN IF NOT EXISTS` clauses | Both clauses run; one is a no-op |

---

## Dependencies

- `public.tenant` (read-only) — for slug lookup during backfill
- `public.schema_migrations` — written by the migration runner after successful application
- `migrations.zig` `runForSchema` — sets `search_path` before executing
- Migration 1134 (`1134_iss0112_add_secret_ref_to_tenant_schemas.sql`) — this
  migration is the corrective companion; 1134 remains in the ledger and is not
  re-applied

---

## Acceptance Criteria

- `migrations/1138_iss0635_webhook_secret_ref_corrective.sql` exists with no
  `-- scope: public` header
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS secret_ref TEXT` and
  `ADD COLUMN IF NOT EXISTS secret_key_id TEXT` are present
- `webhook_subscriptions` table guard (`IF NOT EXISTS` check on
  `information_schema.tables`) is present
- `zig build migrate` exits 0 on a database where `tenant_default.webhook_subscriptions`
  exists but is missing the columns
- After migration, `SELECT secret_ref, secret_key_id FROM webhook_subscriptions` in
  `tenant_default` returns non-NULL values for every existing row
