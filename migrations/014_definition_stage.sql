-- 014_definition_stage.sql
-- Stage 2: PD-07 — add stage column to process_definitions for ?stage= filter support
ALTER TABLE process_definitions ADD COLUMN IF NOT EXISTS stage TEXT;
CREATE INDEX IF NOT EXISTS idx_def_stage ON process_definitions(stage) WHERE stage IS NOT NULL;
