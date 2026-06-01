#!/usr/bin/env python3
import subprocess

# Test database connection
result = subprocess.run(
    ['C:\\Users\\tvolo\\AppData\\Local\\Microsoft\\WinGet\\Links\\psql.cmd', '-t', 'postgres://bpm:bpm@localhost:5433/bpm_test', '-c', 'SELECT version();'],
    capture_output=True,
    text=True,
    timeout=10
)
print("VERSION OUTPUT:")
print(result.stdout)
print("\nSTDERR:")
print(result.stderr)

# Test a simple count
result2 = subprocess.run(
    ['C:\\Users\\tvolo\\AppData\\Local\\Microsoft\\WinGet\\Links\\psql.cmd', '-t', 'postgres://bpm:bpm@localhost:5433/bpm_test', '-c', 'SELECT COUNT(*) FROM audit_entries;'],
    capture_output=True,
    text=True,
    timeout=10
)
print("\nAUDIT_ENTRIES COUNT:")
print(result2.stdout)
