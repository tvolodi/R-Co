-- Get the source code of bpm_audit_compute_chain_hash function
SELECT pg_get_functiondef(oid) as func_def
FROM pg_proc
WHERE proname = 'bpm_audit_compute_chain_hash'
AND pronargs = 13;
