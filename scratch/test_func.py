#!/usr/bin/env python3
import subprocess
import sys

# Test function call via psql
sql = """
SELECT bpm_audit_compute_chain_hash(
    '550e8400-e29b-41d4-a716-446655440000'::uuid,
    '550e8400-e29b-41d4-a716-446655440001'::uuid,
    '550e8400-e29b-41d4-a716-446655440002'::uuid,
    'test.action'::text,
    'test'::text,
    '550e8400-e29b-41d4-a716-446655440003'::uuid,
    NOW()::timestamptz,
    '{\"key\":\"value\"}'::jsonb,
    '{\"result\":\"ok\"}'::jsonb,
    '550e8400-e29b-41d4-a716-446655440004'::uuid,
    'trace-123'::text,
    NULL::text,
    NULL::text
) AS hash;
"""

try:
    result = subprocess.run(
        ['C:\\Users\\tvolo\\AppData\\Local\\Microsoft\\WinGet\\Links\\psql.cmd', '-t', 'postgres://bpm:bpm@localhost:5433/bpm_test', '-c', sql],
        capture_output=True,
        text=True,
        timeout=10
    )
    print("STDOUT:", result.stdout)
    print("STDERR:", result.stderr)
    print("RETURNCODE:", result.returncode)
except Exception as e:
    print(f"Error: {e}")
