import os
import psycopg

print('ENV', os.environ.get('BPM_TEST_DB_URL'))
conn = psycopg.connect(os.environ['BPM_TEST_DB_URL'])
try:
    print('OK', conn.execute('select 1').fetchone())
finally:
    conn.close()
