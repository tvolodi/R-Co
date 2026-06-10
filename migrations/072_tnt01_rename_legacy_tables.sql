-- Migration 072: Rename legacy business tables to canonical names (TNT-01)
--
-- The original migrations (006, 047) created:
--   dead_letter_queue      → now renamed to dead_letter_items
--   form_schema_registry   → now renamed to repository_form_schemas
--
-- This migration runs inside the tenant schema context (migration runner sets
-- search_path to <tenant_schema>,public before executing this file per TNT-02
-- protocol). The renames therefore apply within the tenant schema automatically.
--
-- Idempotent: checks whether the old names still exist before renaming.
-- Safe to re-run: IF EXISTS guards prevent errors on repeated execution.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'dead_letter_queue'
    ) THEN
        ALTER TABLE dead_letter_queue RENAME TO dead_letter_items;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'form_schema_registry'
    ) THEN
        ALTER TABLE form_schema_registry RENAME TO repository_form_schemas;
    END IF;
END $$;
