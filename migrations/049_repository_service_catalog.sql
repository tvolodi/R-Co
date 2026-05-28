-- Migration 049: Repository service catalog (REPO-07)
--
-- Service registration with endpoint URLs, request/response schemas, and auth requirements.
-- Used by SERVICE_TASK nodes and Lua service calls.
-- Covers:
--   - REPO-07: Service catalog

CREATE TABLE IF NOT EXISTS service_catalog (
    service_id           VARCHAR(255) NOT NULL PRIMARY KEY,
    endpoint_url         VARCHAR(2048) NOT NULL,
    request_schema       TEXT NOT NULL,                  -- JSON Schema bytes
    response_schema      TEXT NOT NULL,                  -- JSON Schema bytes
    required_auth        VARCHAR(64) NOT NULL,           -- "NONE", "API_KEY", "OAUTH2", "MUTUAL_TLS"
    timeout_ms           INTEGER NOT NULL,               -- 1..3600000 (max 1 hour)
    retry_policy         TEXT,                           -- JSON object: {"strategy": "exponential", "max_attempts": 3}
    created_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Constraints
    CONSTRAINT ck_service_timeout CHECK (timeout_ms >= 1 AND timeout_ms <= 3600000),
    CONSTRAINT ck_service_auth_method CHECK (required_auth IN ('NONE', 'API_KEY', 'OAUTH2', 'MUTUAL_TLS')),

    -- Indexes
    INDEX idx_service_catalog_created (created_at),
    INDEX idx_service_catalog_updated (updated_at)
);

COMMENT ON TABLE service_catalog IS 'Service registry for SERVICE_TASK nodes and Lua service.call() (REPO-07).';
COMMENT ON COLUMN service_catalog.service_id IS 'Stable, unique identifier (e.g., "crm.customer_lookup").';
COMMENT ON COLUMN service_catalog.endpoint_url IS 'HTTPS endpoint URL to invoke.';
COMMENT ON COLUMN service_catalog.request_schema IS 'JSON Schema defining request body shape.';
COMMENT ON COLUMN service_catalog.response_schema IS 'JSON Schema defining response body shape.';
COMMENT ON COLUMN service_catalog.required_auth IS 'Authentication method: NONE, API_KEY, OAUTH2, or MUTUAL_TLS.';
COMMENT ON COLUMN service_catalog.timeout_ms IS 'Maximum request duration in milliseconds (1ms..1hour).';
COMMENT ON COLUMN service_catalog.retry_policy IS 'JSON object defining retry strategy and max attempts.';
COMMENT ON COLUMN service_catalog.created_at IS 'UTC timestamp when service was registered.';
COMMENT ON COLUMN service_catalog.updated_at IS 'UTC timestamp of most recent service update.';
