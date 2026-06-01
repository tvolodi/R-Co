import psycopg2

conn = psycopg2.connect('postgres://bpm:bpm@localhost:5433/bpm_test')
cur = conn.cursor()

# Get the full function body of bpm_audit_apply_chain_hash
cur.execute("""
    SELECT pg_get_functiondef(oid) 
    FROM pg_proc 
    WHERE proname = 'bpm_audit_apply_chain_hash'
""")
row = cur.fetchone()
if row:
    print("=== bpm_audit_apply_chain_hash function definition ===")
    print(row[0])
else:
    print("Function not found!")

# Also check: which migration applied the trigger?
cur.execute("""
    SELECT tgname, pg_get_functiondef(p.oid)
    FROM pg_trigger t 
    JOIN pg_proc p ON t.tgfoid = p.oid 
    WHERE tgrelid = 'audit_entries'::regclass 
    AND tgname = 'trg_bpm_audit_apply_chain_hash'
""")
row = cur.fetchone()
if row:
    print(f"\n=== Trigger {row[0]} ===")
    print(row[1])

conn.close()
