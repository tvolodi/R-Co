-- 002_event_type_registry.sql
-- Stage 1: ES-05 — Event type registry with JSON Schema validation
-- Adapted from ai-dala-forge for BPM Platform

CREATE TABLE IF NOT EXISTS event_type_registry (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL,
    schema_version  INTEGER     NOT NULL DEFAULT 1,
    json_schema     JSONB       NOT NULL DEFAULT '{}',
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- ES-05: name + version uniquely identifies a schema
    CONSTRAINT uq_event_type_version UNIQUE (name, schema_version)
);

-- Fast lookup by name when validating appends
CREATE INDEX IF NOT EXISTS idx_etr_name ON event_type_registry(name);

-- ── Built-in platform event types ────────────────────────────────────────────
-- Seeded here so migration is self-contained.
INSERT INTO event_type_registry (name, schema_version, json_schema, description)
VALUES
    ('INSTANCE_STARTED',       1, '{"type":"object","required":["definition_id"],"properties":{"definition_id":{"type":"string"},"correlation_key":{"type":"string"},"variables":{"type":"object"}}}'::jsonb,    'Process instance started'),
    ('INSTANCE_COMPLETED',     1, '{"type":"object","properties":{"output_variables":{"type":"object"}}}'::jsonb,                                                                                                  'Process instance completed normally'),
    ('INSTANCE_CANCELLED',     1, '{"type":"object","properties":{"reason":{"type":"string"}}}'::jsonb,                                                                                                           'Process instance cancelled by operator'),
    ('INSTANCE_ERROR',         1, '{"type":"object","required":["code","message"],"properties":{"code":{"type":"string"},"message":{"type":"string"},"detail":{"type":"object"}}}'::jsonb,                        'Unresolvable execution condition'),
    ('TASK_ACTIVATED',         1, '{"type":"object","required":["node_id","node_type"],"properties":{"node_id":{"type":"string"},"node_type":{"type":"string"},"assignee_type":{"type":"string"},"assignee_ref":{"type":"string"}}}'::jsonb, 'Task node entered; task record created'),
    ('TASK_COMPLETED',         1, '{"type":"object","required":["task_id"],"properties":{"task_id":{"type":"string"},"output_variables":{"type":"object"}}}'::jsonb,                                              'Task completed by actor'),
    ('TASK_REASSIGNED',        1, '{"type":"object","required":["task_id","new_assignee"],"properties":{"task_id":{"type":"string"},"new_assignee":{"type":"string"}}}'::jsonb,                                   'Task assignment changed'),
    ('GATEWAY_EVALUATED',      1, '{"type":"object","required":["gateway_id","selected_edge"],"properties":{"gateway_id":{"type":"string"},"gateway_type":{"type":"string"},"selected_edge":{"type":"string"}}}'::jsonb, 'Gateway condition evaluated'),
    ('PARALLEL_SPLIT',         1, '{"type":"object","required":["gateway_id","branches"],"properties":{"gateway_id":{"type":"string"},"branches":{"type":"array","items":{"type":"string"}}}}'::jsonb,            'Parallel gateway split: tokens created'),
    ('PARALLEL_JOIN',          1, '{"type":"object","required":["gateway_id"],"properties":{"gateway_id":{"type":"string"}}}'::jsonb,                                                                             'Parallel gateway join: all tokens arrived'),
    ('VARIABLE_OVERWRITTEN',   1, '{"type":"object","required":["key","old_value","new_value"],"properties":{"key":{"type":"string"},"old_value":{},"new_value":{}}}'::jsonb,                                     'Variable collision: old value overwritten'),
    ('TIMER_SCHEDULED',        1, '{"type":"object","required":["timer_id","fires_at"],"properties":{"timer_id":{"type":"string"},"fires_at":{"type":"string"},"action_type":{"type":"string"}}}'::jsonb,         'Timer created for a step'),
    ('TIMER_FIRED',            1, '{"type":"object","required":["timer_id"],"properties":{"timer_id":{"type":"string"}}}'::jsonb,                                                                                  'Timer fired and action dispatched'),
    ('TIMER_CANCELLED',        1, '{"type":"object","required":["timer_id"],"properties":{"timer_id":{"type":"string"},"reason":{"type":"string"}}}'::jsonb,                                                      'Timer cancelled before firing'),
    ('SERVICE_TASK_INVOKED',   1, '{"type":"object","required":["node_id","endpoint"],"properties":{"node_id":{"type":"string"},"endpoint":{"type":"string"},"method":{"type":"string"}}}'::jsonb,                'Service task HTTP call dispatched'),
    ('SERVICE_TASK_COMPLETED', 1, '{"type":"object","required":["node_id"],"properties":{"node_id":{"type":"string"},"status_code":{"type":"integer"},"output_variables":{"type":"object"}}}'::jsonb,             'Service task HTTP call returned successfully'),
    ('SERVICE_TASK_FAILED',    1, '{"type":"object","required":["node_id","error"],"properties":{"node_id":{"type":"string"},"error":{"type":"string"},"retry_count":{"type":"integer"}}}'::jsonb,                'Service task HTTP call failed'),
    ('SUBPROCESS_STARTED',     1, '{"type":"object","required":["node_id","child_instance_id"],"properties":{"node_id":{"type":"string"},"child_instance_id":{"type":"string"}}}'::jsonb,                        'Sub-process child instance started'),
    ('SUBPROCESS_COMPLETED',   1, '{"type":"object","required":["node_id","child_instance_id"],"properties":{"node_id":{"type":"string"},"child_instance_id":{"type":"string"},"output_variables":{"type":"object"}}}'::jsonb, 'Sub-process completed, parent token unblocked'),
    ('EXECUTION_ERROR',        1, '{"type":"object","required":["code","message"],"properties":{"code":{"type":"string"},"message":{"type":"string"},"node_id":{"type":"string"}}}'::jsonb,                       'EE-10: execution error halting instance')
ON CONFLICT (name, schema_version) DO NOTHING;
