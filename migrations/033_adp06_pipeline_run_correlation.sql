-- 033_adp06_pipeline_run_correlation.sql
-- Stage 6.5: ADP-06 -- additive pipeline run correlation for audit and event metadata.

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS pipeline_run_id UUID NULL;

CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_pipeline_time
    ON audit_entries (tenant_id, pipeline_run_id, timestamp DESC, audit_id DESC)
    WHERE pipeline_run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_events_tenant_pipeline_run_seq
    ON events (tenant_id, (metadata->>'pipeline_run_id'), sequence_number)
    WHERE metadata ? 'pipeline_run_id';

CREATE INDEX IF NOT EXISTS idx_events_archive_tenant_pipeline_run_seq
    ON events_archive (tenant_id, (metadata->>'pipeline_run_id'), sequence_number)
    WHERE metadata ? 'pipeline_run_id';

CREATE OR REPLACE FUNCTION bpm_audit_apply_pipeline_run_id()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    pipeline_run_setting TEXT;
BEGIN
    IF NEW.pipeline_run_id IS NOT NULL THEN
        RETURN NEW;
    END IF;

    pipeline_run_setting := NULLIF(current_setting('bpm.pipeline_run_id', true), '');
    IF pipeline_run_setting IS NULL THEN
        RETURN NEW;
    END IF;

    NEW.pipeline_run_id := bpm_audit_try_uuid(pipeline_run_setting);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bpm_audit_apply_pipeline_run_id ON audit_entries;
CREATE TRIGGER trg_bpm_audit_apply_pipeline_run_id
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_pipeline_run_id();
