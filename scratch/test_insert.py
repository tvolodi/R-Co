import psycopg2

conn = psycopg2.connect('postgres://bpm:bpm@localhost:5433/bpm_test')
conn.autocommit = True
cur = conn.cursor()

# Try a simple insert into audit_entries to see what error we get
try:
    cur.execute("""
        INSERT INTO audit_entries (audit_id, actor_id, action, resource_type, resource_id, timestamp, tenant_id)
        VALUES (gen_random_uuid(), gen_random_uuid(), 'TEST', 'test_resource', gen_random_uuid(), now(), gen_random_uuid())
    """)
    print("INSERT succeeded")
    
    # Check if chain_hash was populated
    cur.execute("SELECT audit_id, chain_hash, prev_chain_hash FROM audit_entries WHERE action = 'TEST' ORDER BY timestamp DESC LIMIT 1")
    row = cur.fetchone()
    print(f"audit_id={row[0]}, chain_hash={row[1]}, prev_chain_hash={row[2]}")
    
    # Clean up
    cur.execute("DELETE FROM audit_entries WHERE action = 'TEST'")
    print("Cleanup done")
except Exception as e:
    print(f"ERROR: {e}")

# Check the trigger function bodies
print("\n--- Trigger function bodies ---")
cur.execute("""
    SELECT proname, pg_get_functiondef(oid) 
    FROM pg_proc 
    WHERE proname IN ('bpm_audit_apply_chain_hash', 'bpm_audit_immutable_guard', 'bpm_audit_enforce_immutability')
    ORDER BY proname
""")
for row in cur.fetchall():
    print(f"\n=== {row[0]} ===")
    print(row[1][:500])

conn.close()
