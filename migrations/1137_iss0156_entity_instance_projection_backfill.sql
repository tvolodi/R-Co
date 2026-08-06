-- 1137_iss0156_entity_instance_projection_backfill.sql
--
-- ISS-0156 / GH #475 — BLOCKER data repair.
--
-- src/entities/commands.zig getOrCreateEntityTypeInstance() INSERTed the
-- entity_type -> instance_id mapping row into entity_type_instances but never
-- created the corresponding instance_projections row that store.append()
-- requires. store.append() begins every append with
--
--     SELECT status FROM instance_projections WHERE instance_id = $1
--
-- and returns StoreError.InstanceNotFound on zero rows — so every entity
-- record create/update/delete failed against a real database.
--
-- The code fix (same commit) makes getOrCreateEntityTypeInstance create the
-- projection row alongside the mapping row, with ON CONFLICT (instance_id)
-- DO NOTHING. That is self-repairing, but only lazily: an entity type whose
-- mapping row predates the fix regains a projection row on its NEXT command.
-- This migration repairs those rows eagerly, so a database that ran the
-- broken code is consistent immediately after deploy rather than after the
-- next write to each affected entity type.
--
-- The synthetic projection row is written exactly as src/engine/instance.zig
-- writes one for a process instance — status 'ACTIVE', empty variables and
-- current_nodes — differing only in carrying the entity-stream sentinel
-- definition_id (00000000-0000-0000-0000-0000000e2117, matching
-- ENTITY_STREAM_DEFINITION_ID in src/entities/commands.zig) and a NULL
-- correlation_key. instance_projections.definition_id is NOT NULL but has no
-- foreign key to process_definitions, so the sentinel is valid.
--
-- started_at/updated_at are taken from entity_type_instances.created_at so the
-- backfilled instance carries the real age of the entity type rather than the
-- migration's run time.
--
-- Non-destructive and idempotent: INSERT ... SELECT with a NOT EXISTS guard
-- plus ON CONFLICT (instance_id) DO NOTHING. It only ADDS rows that should
-- have existed all along; it never modifies or deletes an existing
-- instance_projections row, and it skips any tenant schema that lacks either
-- table (entity_type_instances is created by migration 094).

BEGIN;

DO $$
DECLARE
    rec        RECORD;
    v_sql      TEXT;
    v_inserted BIGINT;
    v_total    BIGINT := 0;
BEGIN
    FOR rec IN
        SELECT nspname
          FROM pg_namespace
         WHERE nspname LIKE 'tenant_%'
           AND nspname NOT LIKE 'pg_%'
           AND nspname NOT LIKE 'pgtoast%'
         ORDER BY nspname
    LOOP
        -- Both tables must exist in this schema; entity_type_instances is
        -- only present where migration 094 has been applied.
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = rec.nspname
               AND c.relname = 'entity_type_instances'
               AND c.relkind = 'r'
        );
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = rec.nspname
               AND c.relname = 'instance_projections'
               AND c.relkind = 'r'
        );

        v_sql := format(
            'INSERT INTO %I.instance_projections '
            '    (tenant_id, instance_id, definition_id, correlation_key, '
            '     status, variables, current_nodes, started_at, updated_at) '
            'SELECT eti.tenant_id, eti.instance_id, '
            '       %L::uuid, NULL, '
            '       ''ACTIVE'', ''{}''::jsonb, ''[]''::jsonb, '
            '       eti.created_at, eti.created_at '
            '  FROM %I.entity_type_instances eti '
            ' WHERE NOT EXISTS ( '
            '           SELECT 1 FROM %I.instance_projections ip '
            '            WHERE ip.instance_id = eti.instance_id) '
            'ON CONFLICT (instance_id) DO NOTHING',
            rec.nspname,
            '00000000-0000-0000-0000-0000000e2117',
            rec.nspname,
            rec.nspname
        );

        EXECUTE v_sql;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        v_total := v_total + v_inserted;

        IF v_inserted > 0 THEN
            RAISE NOTICE 'ISS-0156 backfill: % orphaned entity-type instance(s) repaired in schema %',
                v_inserted, rec.nspname;
        END IF;
    END LOOP;

    RAISE NOTICE 'ISS-0156 backfill complete: % instance_projections row(s) created in total', v_total;
END $$;

COMMIT;
