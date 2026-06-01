import psycopg2

conn = psycopg2.connect('postgres://bpm:bpm@localhost:5433/bpm_test')
cur = conn.cursor()
cur.execute("""
    SELECT proname, pg_get_function_arguments(oid) 
    FROM pg_proc 
    WHERE proname LIKE 'bpm_audit%' 
    ORDER BY proname
""")
for row in cur.fetchall():
    print(f'{row[0]}({row[1]})')

print("\n--- Triggers on audit_entries ---")
cur.execute("""
    SELECT tgname, proname 
    FROM pg_trigger t 
    JOIN pg_proc p ON t.tgfoid = p.oid 
    WHERE tgrelid = 'audit_entries'::regclass 
    AND NOT tgisinternal
""")
for row in cur.fetchall():
    print(f'  {row[0]} -> {row[1]}')

print("\n--- Columns on audit_entries ---")
cur.execute("""
    SELECT column_name, data_type, is_nullable 
    FROM information_schema.columns 
    WHERE table_name = 'audit_entries' 
    ORDER BY ordinal_position
""")
for row in cur.fetchall():
    print(f'  {row[0]}: {row[1]} ({row[2]})')

conn.close()
