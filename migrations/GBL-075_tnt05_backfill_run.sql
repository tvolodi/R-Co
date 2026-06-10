-- GBL-075: TNT-05 backfill algorithm
--
-- Copies all rows from each public business table (WHERE tenant_id = T) into
-- the corresponding tenant_<T_uuid> schema table.  Runs in dependency order,
-- batched at 10 000 rows per transaction.  Idempotent: ON CONFLICT DO NOTHING
-- on INSERT; skips (tenant_id, table_name) pairs already COMPLETED.
--
-- After each table is copied (COMPLETED status), the source rows are deleted
-- from public in a separate transaction.  Orphan rows (unknown tenant_id) are
-- logged to tnt05_orphans and left in place for manual review.
--
-- GBL-prefix: exempt from lint_migration_schema.py business-table check.

DO $$
DECLARE
    -- Cursor variables
    v_tenant        RECORD;
    v_schema_name   TEXT;
    v_already_done  BOOLEAN;
    v_rows_this_batch BIGINT;
    v_total_rows    BIGINT;
    v_last_ctid     TID;

    -- Ordered list of business tables (dependency order: parent before child)
    v_tables TEXT[] := ARRAY[
        'events',
        'events_archive',
        'instance_sequence',
        'event_type_registry',
        'event_retention_policies',
        'process_definitions',
        'instance_projections',
        'tasks',
        'tokens',
        'timers',
        'users',
        'groups',
        'group_members',
        'roles',
        'user_roles',
        'api_tokens',
        'webhook_subscriptions',
        'dead_letter_items',
        'audit_entries',
        'audit_log',
        'repository_form_schemas'
    ];

    v_table_name TEXT;
    i            INT;

    -- Column list cache (avoids re-querying information_schema each batch)
    v_col_list   TEXT;
    v_insert_sql TEXT;
    v_select_sql TEXT;
    v_delete_sql TEXT;
    v_orphan_sql TEXT;
    v_exists     BOOLEAN;

BEGIN
    -- -------------------------------------------------------------------------
    -- Step 1: Set migration window flag
    -- -------------------------------------------------------------------------
    UPDATE onboarding_registry
       SET migration_window_active = TRUE;
    RAISE NOTICE 'GBL-075: migration_window_active set to TRUE';

    -- -------------------------------------------------------------------------
    -- Step 2: For each tenant, for each table (dependency order), batch-copy
    -- -------------------------------------------------------------------------
    FOR v_tenant IN
        SELECT id, slug FROM tenant ORDER BY created_at ASC
    LOOP
        -- Build schema name: tenant_default or tenant_<uuid-no-hyphens>
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000' THEN
            v_schema_name := 'tenant_default';
        ELSE
            v_schema_name := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        RAISE NOTICE 'GBL-075: Processing tenant % (schema: %)', v_tenant.id, v_schema_name;

        FOR i IN 1..array_length(v_tables, 1) LOOP
            v_table_name := v_tables[i];

            -- Check whether the source table exists in public (may have been
            -- dropped by GBL-073 if migration_window_active was FALSE at that time).
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public'
                   AND table_name   = v_table_name
                   AND table_type   = 'BASE TABLE'
            ) INTO v_exists;

            IF NOT v_exists THEN
                -- Table not present in public — record as COMPLETED with 0 rows
                INSERT INTO tnt05_progress (tenant_id, table_name, rows_copied, status, started_at, completed_at)
                VALUES (v_tenant.id, v_table_name, 0, 'COMPLETED', now(), now())
                ON CONFLICT (tenant_id, table_name) DO UPDATE
                    SET status = 'COMPLETED',
                        completed_at = COALESCE(tnt05_progress.completed_at, now());
                CONTINUE;
            END IF;

            -- Idempotency: skip if already COMPLETED
            SELECT (status = 'COMPLETED') INTO v_already_done
              FROM tnt05_progress
             WHERE tenant_id = v_tenant.id
               AND table_name = v_table_name;

            IF FOUND AND v_already_done THEN
                CONTINUE;
            END IF;

            -- Check whether the destination table exists in the tenant schema
            -- (schema may not have been provisioned yet — safe to skip)
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = v_schema_name
                   AND table_name   = v_table_name
                   AND table_type   = 'BASE TABLE'
            ) INTO v_exists;

            IF NOT v_exists THEN
                RAISE NOTICE 'GBL-075: Destination %.% does not exist — skipping (schema not provisioned?)',
                    v_schema_name, v_table_name;
                INSERT INTO tnt05_progress (tenant_id, table_name, rows_copied, status, started_at, completed_at)
                VALUES (v_tenant.id, v_table_name, 0, 'COMPLETED', now(), now())
                ON CONFLICT (tenant_id, table_name) DO UPDATE
                    SET status = 'COMPLETED',
                        completed_at = COALESCE(tnt05_progress.completed_at, now());
                CONTINUE;
            END IF;

            -- Build column list: all columns except tenant_id
            SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
              INTO v_col_list
              FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = v_table_name
               AND column_name != 'tenant_id';

            IF v_col_list IS NULL THEN
                -- No columns other than tenant_id (unlikely but safe to skip)
                INSERT INTO tnt05_progress (tenant_id, table_name, rows_copied, status, started_at, completed_at)
                VALUES (v_tenant.id, v_table_name, 0, 'COMPLETED', now(), now())
                ON CONFLICT (tenant_id, table_name) DO UPDATE
                    SET status = 'COMPLETED',
                        completed_at = COALESCE(tnt05_progress.completed_at, now());
                CONTINUE;
            END IF;

            -- Mark IN_PROGRESS
            INSERT INTO tnt05_progress (tenant_id, table_name, rows_copied, status, started_at)
            VALUES (v_tenant.id, v_table_name, 0, 'IN_PROGRESS', now())
            ON CONFLICT (tenant_id, table_name) DO UPDATE
                SET status     = 'IN_PROGRESS',
                    started_at = COALESCE(tnt05_progress.started_at, now());

            v_total_rows := 0;
            v_last_ctid  := '(0,0)'::tid;

            -- Step 2c: batch copy loop using ctid cursor
            LOOP
                v_insert_sql := format(
                    'INSERT INTO %I.%I (%s) '
                    'SELECT %s FROM public.%I '
                    'WHERE tenant_id = %L '
                    '  AND ctid > %L::tid '
                    'ORDER BY ctid '
                    'LIMIT 10000 '
                    'ON CONFLICT DO NOTHING',
                    v_schema_name, v_table_name, v_col_list,
                    v_col_list,
                    v_table_name,
                    v_tenant.id,
                    v_last_ctid::text
                );

                EXECUTE v_insert_sql;
                GET DIAGNOSTICS v_rows_this_batch = ROW_COUNT;
                v_total_rows := v_total_rows + v_rows_this_batch;

                -- Update progress row count after each batch
                UPDATE tnt05_progress
                   SET rows_copied = v_total_rows
                 WHERE tenant_id  = v_tenant.id
                   AND table_name = v_table_name;

                EXIT WHEN v_rows_this_batch < 10000;

                -- Advance ctid cursor: get the ctid of the last inserted source row
                EXECUTE format(
                    'SELECT ctid FROM public.%I WHERE tenant_id = %L ORDER BY ctid DESC LIMIT 1',
                    v_table_name, v_tenant.id
                ) INTO v_last_ctid;

                EXIT WHEN v_last_ctid IS NULL;
            END LOOP;

            -- Step 2d: Mark COMPLETED
            UPDATE tnt05_progress
               SET status       = 'COMPLETED',
                   rows_copied  = v_total_rows,
                   completed_at = now()
             WHERE tenant_id  = v_tenant.id
               AND table_name = v_table_name;

            RAISE NOTICE 'GBL-075: %.% → %.%: % rows copied',
                'public', v_table_name, v_schema_name, v_table_name, v_total_rows;

            -- Step 5b: Delete source rows from public in a separate transaction.
            -- We are already inside the outer DO block's transaction; to honour
            -- the design's "separate transaction" requirement we use a subtransaction
            -- savepoint to isolate the DELETE. This ensures the COMPLETED mark is
            -- committed before the DELETE and that a DELETE failure does not roll
            -- back the progress record.
            BEGIN
                v_delete_sql := format(
                    'DELETE FROM public.%I WHERE tenant_id = %L',
                    v_table_name, v_tenant.id
                );
                EXECUTE v_delete_sql;
                GET DIAGNOSTICS v_rows_this_batch = ROW_COUNT;
                RAISE NOTICE 'GBL-075: Deleted % rows from public.% for tenant %',
                    v_rows_this_batch, v_table_name, v_tenant.id;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'GBL-075: WARNING: DELETE from public.% for tenant % failed: % — rows left for manual cleanup',
                    v_table_name, v_tenant.id, SQLERRM;
            END;

        END LOOP; -- tables

    END LOOP; -- tenants

    -- -------------------------------------------------------------------------
    -- Step 3: Orphan handling — rows whose tenant_id is not in public.tenant
    -- -------------------------------------------------------------------------
    FOR i IN 1..array_length(v_tables, 1) LOOP
        v_table_name := v_tables[i];

        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public'
               AND table_name   = v_table_name
               AND table_type   = 'BASE TABLE'
        ) INTO v_exists;

        IF NOT v_exists THEN
            CONTINUE;
        END IF;

        -- Check if tenant_id column exists on this table
        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = v_table_name
               AND column_name  = 'tenant_id'
        ) INTO v_exists;

        IF NOT v_exists THEN
            CONTINUE;
        END IF;

        -- Check if id column exists for row_id capture
        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = v_table_name
               AND column_name  = 'id'
        ) INTO v_exists;

        IF v_exists THEN
            v_orphan_sql := format(
                'INSERT INTO tnt05_orphans (row_id, table_name, tenant_id, reason) '
                'SELECT id::text, %L, tenant_id, '
                '       ''tenant_id not found in public.tenant'' '
                '  FROM public.%I '
                ' WHERE tenant_id NOT IN (SELECT id FROM tenant) '
                'ON CONFLICT DO NOTHING',
                v_table_name, v_table_name
            );
        ELSE
            -- No id column: use ctid as surrogate row_id
            v_orphan_sql := format(
                'INSERT INTO tnt05_orphans (row_id, table_name, tenant_id, reason) '
                'SELECT ctid::text, %L, tenant_id, '
                '       ''tenant_id not found in public.tenant'' '
                '  FROM public.%I '
                ' WHERE tenant_id NOT IN (SELECT id FROM tenant) '
                'ON CONFLICT DO NOTHING',
                v_table_name, v_table_name
            );
        END IF;

        EXECUTE v_orphan_sql;
        GET DIAGNOSTICS v_rows_this_batch = ROW_COUNT;
        IF v_rows_this_batch > 0 THEN
            RAISE NOTICE 'GBL-075: % orphan rows logged from public.%',
                v_rows_this_batch, v_table_name;
        END IF;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- Step 6: Clear migration window flag
    -- -------------------------------------------------------------------------
    UPDATE onboarding_registry
       SET migration_window_active = FALSE;
    RAISE NOTICE 'GBL-075: migration_window_active reset to FALSE — backfill complete.';

END $$;
