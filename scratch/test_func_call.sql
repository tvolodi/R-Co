-- Test if bpm_audit_compute_chain_hash function works
DO $$
DECLARE
    result TEXT;
BEGIN
    RAISE NOTICE 'Testing bpm_audit_compute_chain_hash...';
    
    result := bpm_audit_compute_chain_hash(
        '550e8400-e29b-41d4-a716-446655440000'::uuid,  -- tenant_id
        '550e8400-e29b-41d4-a716-446655440001'::uuid,  -- actor_id
        '550e8400-e29b-41d4-a716-446655440002'::uuid,  -- audit_id
        'test.action'::text,  -- action
        'test'::text,  -- resource_type
        '550e8400-e29b-41d4-a716-446655440003'::uuid,  -- resource_id
        NOW()::timestamptz,  -- timestamp
        '{"key":"value"}'::jsonb,  -- context
        '{"result":"ok"}'::jsonb,  -- result
        '550e8400-e29b-41d4-a716-446655440004'::uuid,  -- ref_id
        'trace-123'::text,  -- trace_id
        NULL::text,  -- prev_hash
        NULL::text  -- request_id
    );
    
    RAISE NOTICE 'Function worked! Result: %', result;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error calling function: % %', SQLSTATE, SQLERRM;
END $$;
