-- Test the chain hash function directly
SELECT bpm_audit_compute_chain_hash(
    '550e8400-e29b-41d4-a716-446655440000'::uuid,
    '550e8400-e29b-41d4-a716-446655440001'::uuid,
    '550e8400-e29b-41d4-a716-446655440002'::uuid,
    'test.action',
    'test',
    '550e8400-e29b-41d4-a716-446655440003'::uuid,
    NOW()::timestamptz,
    '{"key":"value"}'::jsonb,
    '{"result":"ok"}'::jsonb,
    '550e8400-e29b-41d4-a716-446655440004'::uuid,
    'trace-123',
    '0000000000000000000000000000000000000000000000000000000000000000'::text,
    NULL
) AS hash_result;
