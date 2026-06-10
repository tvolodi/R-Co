-- GBL-073: Drop legacy business tables from public schema (TNT-01)
--
-- Migrations 001–059 created business tables directly in public. Migration 060
-- introduced schema-per-tenant provisioning but did NOT drop the legacy public
-- tables. This GBL migration performs the cleanup.
--
-- This file uses the GBL- prefix: it operates on the global public schema and
-- is exempt from the lint_migration_schema.py business-table check (which
-- rejects non-GBL files that reference public.<business_table>).
--
-- Guard: if migration_window_active = TRUE in public.onboarding_registry,
-- the DROP is skipped (NOTICE logged). In test environments this flag is FALSE
-- so the drops proceed. In production, the operator must set
-- migration_window_active = FALSE before this migration runs.
--
-- Idempotent: all drops use DROP TABLE IF EXISTS.
-- Dependency order: GBL-073 runs after 072_tnt01_rename_legacy_tables.sql,
-- which renames dead_letter_queue→dead_letter_items and
-- form_schema_registry→repository_form_schemas inside each tenant schema.
-- The legacy public copies retain the old names until this migration runs.

DO $$
DECLARE
    v_window_active BOOLEAN := FALSE;
BEGIN
    -- Check migration window flag; skip drops if window is active.
    BEGIN
        SELECT migration_window_active
          INTO v_window_active
          FROM public.onboarding_registry
         LIMIT 1;
    EXCEPTION
        WHEN undefined_table THEN
            v_window_active := FALSE;
        WHEN NO_DATA_FOUND THEN
            v_window_active := FALSE;
    END;

    IF v_window_active THEN
        RAISE NOTICE 'GBL-073: migration_window_active = TRUE — skipping DROP of legacy public business tables.';
        RETURN;
    END IF;

    -- Drop the 19 legacy business tables from public (in dependency order).
    -- Tables with triggers or FK references are dropped with CASCADE to
    -- avoid constraint errors from the pre-TNT trigger/audit infrastructure.

    DROP TABLE IF EXISTS public.audit_entries CASCADE;
    DROP TABLE IF EXISTS public.audit_log CASCADE;

    DROP TABLE IF EXISTS public.dead_letter_queue CASCADE;
    DROP TABLE IF EXISTS public.dead_letter_items CASCADE;

    DROP TABLE IF EXISTS public.form_schema_registry CASCADE;
    DROP TABLE IF EXISTS public.repository_form_schemas CASCADE;

    DROP TABLE IF EXISTS public.event_retention_policies CASCADE;
    DROP TABLE IF EXISTS public.event_type_registry CASCADE;
    DROP TABLE IF EXISTS public.webhook_subscriptions CASCADE;
    DROP TABLE IF EXISTS public.api_tokens CASCADE;
    DROP TABLE IF EXISTS public.user_roles CASCADE;
    DROP TABLE IF EXISTS public.roles CASCADE;
    DROP TABLE IF EXISTS public.group_members CASCADE;
    DROP TABLE IF EXISTS public.groups CASCADE;
    DROP TABLE IF EXISTS public.users CASCADE;
    DROP TABLE IF EXISTS public.timers CASCADE;
    DROP TABLE IF EXISTS public.tokens CASCADE;
    DROP TABLE IF EXISTS public.tasks CASCADE;
    DROP TABLE IF EXISTS public.instance_projections CASCADE;
    DROP TABLE IF EXISTS public.process_definitions CASCADE;
    DROP TABLE IF EXISTS public.events_archive CASCADE;
    DROP TABLE IF EXISTS public.events CASCADE;
    DROP TABLE IF EXISTS public.instance_sequence CASCADE;

    RAISE NOTICE 'GBL-073: Legacy public business tables dropped (TNT-01 cleanup complete).';
END $$;
