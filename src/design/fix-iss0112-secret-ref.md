# Fix Design: ISS-0112 — Add webhook_subscriptions.secret_ref to SCHEMA-mode tenant schemas

**Issue:** ISS-0112  
**Severity:** BLOCKER  
**Run ID:** WF03-gh375-20260804  
**Design Date:** 2026-08-04  
**Author:** CODE-DESIGNER (WF-03 Step 2)

---

## 1. Problem Statement

### 1.1 Symptom
Integration tests that access `webhook_subscriptions.secret_ref` in SCHEMA-mode tenant contexts fail with PostgreSQL error:
```
column "secret_ref" does not exist
```

### 1.2 Root Cause
Migration `GBL-128_exp501_secrets.sql` (lines 67-76) attempts to add two columns to the `webhook_subscriptions` table:
- `secret_ref TEXT`
- `secret_key_id TEXT`

However, GBL-128 contains a guard condition:
```sql
IF to_regclass('webhook_subscriptions') IS NOT NULL THEN
```

This guard evaluates against the **public schema**, where `webhook_subscriptions` was already dropped by `GBL-073` (GBL-112_tnt01_drop_legacy_public_business_tables.sql:59). Therefore:
1. The guard evaluates to `FALSE`
2. The `ALTER TABLE` statements never execute
3. GBL migrations by definition run only against the public schema (per `src/db/migrations.zig`)

Migration `GBL-133_iss0112_schema_ledger_reconcile.sql` (lines 200-204) attempts to fix this, but only adds the columns to `public.webhook_subscriptions` (which doesn't exist). Neither migration touches SCHEMA-mode tenant schemas.

**Result:** The `webhook_subscriptions` table in all SCHEMA-mode tenant schemas is missing both `secret_ref` and `secret_key_id` columns.

### 1.3 Affected Scope
- **Tenants:** All tenants with `storage_mode='SCHEMA'` in `public.tenant`
- **Tests:** `tests/integration/ext02_webhook_dispatch_test.zig` (10 test cases)
- **Requirements:** TC-EXT-02 (webhook dispatch functionality)
- **Current impact:** 1 SCHEMA-mode tenant (default tenant, id=00000000-0000-0000-0000-000000000000, schema=tenant_default)

---

## 2. Solution Approach

### 2.1 Strategy
Create a **NON-GBL corrective migration** (migration number 134) that:
1. Iterates over all tenants with `storage_mode='SCHEMA'` from `public.tenant`
2. For each SCHEMA tenant, constructs the tenant schema name:
   - Default tenant (`id='00000000-0000-0000-0000-000000000000'`) → `tenant_default`
   - All other tenants → `tenant_{uuid_without_dashes}`
3. Uses `EXECUTE format()` to add both columns to `webhook_subscriptions` in each tenant schema
4. Uses `ADD COLUMN IF NOT EXISTS` to ensure idempotency
5. Includes a validation query to confirm columns exist after migration

### 2.2 Why NON-GBL?
- **GBL migrations** run only against the `public` schema (hardcoded in `src/db/migrations.zig`)
- **NON-GBL migrations** can use dynamic SQL to execute DDL against multiple schemas
- This migration must operate on per-tenant schemas, therefore it cannot be GBL-prefixed

### 2.3 Reference Patterns
This design follows established patterns from:
- **Tenant iteration:** `migrations/GBL-133_iss0112_schema_ledger_reconcile.sql` lines 220-250 (entity_type_instances loop)
- **Tenant loop structure:** `migrations/GBL-116_tnt07_rls_cleanup.sql` lines 1-100
- **Column definitions:** `migrations/GBL-128_exp501_secrets.sql` lines 70-75

---

## 3. Migration Structure

### 3.1 Migration Number
**134_iss0112_add_secret_ref_to_tenant_webhooks.sql**

Next available number after GBL-133 (verified via `migrations/` directory listing).

### 3.2 High-Level Algorithm
```sql
DO $$
DECLARE
    v_tenant         RECORD;
    v_tenant_schema  TEXT;
    v_columns_added  INTEGER := 0;
BEGIN
    -- Iterate over all SCHEMA-mode tenants
    FOR v_tenant IN
        SELECT id FROM public.tenant WHERE storage_mode = 'SCHEMA'
    LOOP
        -- Construct tenant schema name
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_tenant_schema := 'tenant_default';
        ELSE
            v_tenant_schema := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        -- Verify schema exists before attempting DDL
        IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_tenant_schema) THEN
            -- Add both columns using IF NOT EXISTS (idempotent)
            EXECUTE format(
                'ALTER TABLE %I.webhook_subscriptions
                 ADD COLUMN IF NOT EXISTS secret_ref TEXT,
                 ADD COLUMN IF NOT EXISTS secret_key_id TEXT',
                v_tenant_schema
            );
            v_columns_added := v_columns_added + 1;
            
            -- Optional: Backfill secret_ref for existing rows (same pattern as GBL-128)
            EXECUTE format(
                'UPDATE %I.webhook_subscriptions
                 SET secret_ref = COALESCE(secret_ref, ''sec://tenant/'' || $1 || ''/webhook/subscription-'' || id::text),
                     secret_key_id = COALESCE(secret_key_id, ''legacy'')
                 WHERE secret_ref IS NULL OR secret_key_id IS NULL',
                v_tenant_schema
            ) USING (SELECT slug FROM public.tenant WHERE id = v_tenant.id);
        ELSE
            RAISE NOTICE 'Skipping tenant % — schema % does not exist', v_tenant.id, v_tenant_schema;
        END IF;
    END LOOP;

    RAISE NOTICE 'ISS-0112 corrective migration completed: added secret_ref/secret_key_id to % SCHEMA-mode tenant webhook_subscriptions tables', v_columns_added;
END $$;
```

### 3.3 Key Design Elements

#### Schema Name Construction
- **Default tenant:** hardcoded UUID `00000000-0000-0000-0000-000000000000` → schema `tenant_default`
- **Other tenants:** UUID with dashes removed → schema `tenant_{uuid_no_dashes}`
- Pattern matches `src/db/provisioning.zig` tenant schema creation logic

#### Idempotency Guarantees
1. **Column addition:** `ADD COLUMN IF NOT EXISTS` (PostgreSQL 9.6+)
2. **Backfill update:** `COALESCE(secret_ref, ...)` ensures NULL values are backfilled, existing values preserved
3. **Schema check:** `EXISTS (SELECT 1 FROM information_schema.schemata ...)` prevents DDL attempts on non-existent schemas
4. **Re-run safety:** Migration can be applied multiple times without errors or data corruption

#### Column Definitions
Both columns match GBL-128 specifications:
- `secret_ref TEXT` — stores secret reference URI (e.g., `sec://tenant/default/webhook/subscription-<id>`)
- `secret_key_id TEXT` — stores key identifier (defaults to `'legacy'` for pre-existing rows)

---

## 4. Validation Steps

### 4.1 Pre-Migration Verification
Before implementing the migration, verify the problem exists:
```sql
-- Check SCHEMA-mode tenants
SELECT id, slug, storage_mode FROM public.tenant WHERE storage_mode = 'SCHEMA';

-- For each tenant schema, check if secret_ref column exists
SELECT 
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'tenant_default'
  AND table_name = 'webhook_subscriptions'
  AND column_name IN ('secret_ref', 'secret_key_id');
-- Expected: 0 rows (columns missing)
```

### 4.2 Post-Migration Verification
After applying the migration:

#### Step 1: Check Migration Applied
```sql
SELECT version, description, applied_at
FROM public.schema_migrations
WHERE version = '134_iss0112_add_secret_ref_to_tenant_webhooks.sql';
-- Expected: 1 row
```

#### Step 2: Verify Columns Exist in All SCHEMA Tenants
```sql
DO $$
DECLARE
    v_tenant         RECORD;
    v_tenant_schema  TEXT;
    v_has_secret_ref BOOLEAN;
    v_has_key_id     BOOLEAN;
BEGIN
    FOR v_tenant IN
        SELECT id FROM public.tenant WHERE storage_mode = 'SCHEMA'
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_tenant_schema := 'tenant_default';
        ELSE
            v_tenant_schema := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = v_tenant_schema
              AND table_name = 'webhook_subscriptions'
              AND column_name = 'secret_ref'
        ) INTO v_has_secret_ref;

        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = v_tenant_schema
              AND table_name = 'webhook_subscriptions'
              AND column_name = 'secret_key_id'
        ) INTO v_has_key_id;

        IF NOT v_has_secret_ref OR NOT v_has_key_id THEN
            RAISE EXCEPTION 'Tenant % (schema %) missing columns: secret_ref=%, secret_key_id=%',
                v_tenant.id, v_tenant_schema, v_has_secret_ref, v_has_key_id;
        END IF;

        RAISE NOTICE 'Tenant % (schema %): columns verified ✓', v_tenant.id, v_tenant_schema;
    END LOOP;
END $$;
```

#### Step 3: Run Integration Tests
```bash
zig build migrate           # Apply migration 134
zig build test-integration-ext02  # Run webhook dispatch tests
```
Expected: All 10 ext02 test cases pass, no "column does not exist" errors.

---

## 5. Idempotency Guarantees

### 5.1 Multiple Executions
The migration can be run multiple times without:
- **Errors:** `ADD COLUMN IF NOT EXISTS` succeeds whether column exists or not
- **Data loss:** `COALESCE` in backfill UPDATE preserves existing values
- **Schema conflicts:** `information_schema.schemata` check prevents attempts on missing schemas

### 5.2 Partial Completion Handling
If the migration is interrupted mid-execution (e.g., process killed during tenant loop):
- Some tenants will have the columns added
- Re-running the migration will:
  - Skip tenants that already have the columns (no-op for `ADD COLUMN IF NOT EXISTS`)
  - Add columns to remaining tenants
  - Eventually reach a consistent state where all SCHEMA tenants have both columns

### 5.3 No Rollback Required
This is an additive change:
- No data is deleted
- No constraints are dropped
- Rollback is not required; if needed, columns can be dropped manually per tenant

---

## 6. Dependencies

### 6.1 Prerequisites
- **Migration GBL-128** must be applied (defines the column semantics)
- **Migration GBL-073** must be applied (drops public.webhook_subscriptions)
- `public.tenant` table must exist with `storage_mode` column
- Tenant schemas must already be provisioned per `src/db/provisioning.zig`

### 6.2 Affected Systems
- **Database:** PostgreSQL 13+ (uses `ADD COLUMN IF NOT EXISTS`)
- **Source modules:**
  - `src/webhook/dispatcher.zig` (reads `secret_ref` from webhook_subscriptions)
  - `src/db/migrations.zig` (migration runner)
- **Test files:**
  - `tests/integration/ext02_webhook_dispatch_test.zig`

### 6.3 No Application Code Changes Required
The application already expects these columns to exist (per GBL-128 design). This migration simply corrects the schema drift — no Zig source changes needed.

---

## 7. Error Handling

### 7.1 Schema Does Not Exist
If a tenant is registered in `public.tenant` with `storage_mode='SCHEMA'` but its schema does not exist in `information_schema.schemata`:
- **Action:** Skip with `RAISE NOTICE` (non-fatal)
- **Reason:** Protects against orphaned tenant records or partially-provisioned tenants
- **Example:** Tenant created but provisioning step failed

### 7.2 Table Does Not Exist
If `webhook_subscriptions` does not exist in a tenant schema:
- **PostgreSQL behavior:** `ALTER TABLE` raises error `relation does not exist`
- **Mitigation:** Not needed — webhook_subscriptions is created by earlier migrations (GBL-073 onward)
- **Assumption:** All SCHEMA tenants have a complete table set per provisioning spec

### 7.3 Column Already Exists (Different Type)
If a column named `secret_ref` or `secret_key_id` exists with a non-TEXT type:
- **PostgreSQL behavior:** `ADD COLUMN IF NOT EXISTS` succeeds (no-op), existing column retained
- **Risk:** Type mismatch could break application code
- **Detection:** Pre-migration validation query (section 4.1) should check `data_type`

---

## 8. Open Questions

None. All design requirements are resolved:
- ✅ Column definitions: from GBL-128
- ✅ Tenant iteration pattern: from GBL-133
- ✅ Schema name construction: matches provisioning.zig
- ✅ Idempotency: `IF NOT EXISTS` + `COALESCE` backfill
- ✅ Validation: introspection queries + integration tests

---

## 9. Next Steps (for BACKEND-DEV Step 3)

1. Create migration file: `migrations/134_iss0112_add_secret_ref_to_tenant_webhooks.sql`
2. Implement the migration per section 3.2 structure
3. Add migration comment header (issue reference, date, description)
4. Test locally:
   - `zig build migrate` (confirm exits 0, migration 134 applied)
   - Run validation queries from section 4.2
   - `zig build test-integration-ext02` (confirm all tests pass)
5. Commit with message: `fix(migrations): add secret_ref to SCHEMA tenant webhook_subscriptions (ISS-0112)`

---

## 10. Design Classification

Per `templates/lego-catalog.md`:
- **Type:** E (Novel/cross-cutting)
- **Reason:** Corrective migration with dynamic multi-schema iteration logic; not a standard CRUD/parameter pattern
- **Output:** This prose design document only (no parameter YAML)

---

**Design completed:** 2026-08-04  
**Ready for:** CODE-DESIGN-VALIDATOR (Step 2b) → BACKEND-DEV (Step 3)
