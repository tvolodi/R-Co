-- 022_obs06_alerting_state.sql
-- Stage 6: OBS-06 alert trigger state and per-hook emission dedupe state.

CREATE TABLE IF NOT EXISTS obs_alert_trigger_state (
    trigger_key TEXT PRIMARY KEY,
    is_armed BOOLEAN NOT NULL DEFAULT TRUE,
    last_sample_value BIGINT NOT NULL DEFAULT 0,
    last_fired_at TIMESTAMPTZ,
    last_correlation_id TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_obs_alert_trigger_state_updated
    ON obs_alert_trigger_state(updated_at DESC);

CREATE TABLE IF NOT EXISTS obs_alert_hook_emission_state (
    hook_id TEXT NOT NULL,
    trigger_key TEXT NOT NULL,
    last_emitted_key TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (hook_id, trigger_key)
);

CREATE INDEX IF NOT EXISTS idx_obs_alert_hook_emission_state_updated
    ON obs_alert_hook_emission_state(updated_at DESC);
