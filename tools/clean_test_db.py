#!/usr/bin/env python3
"""Clean all data from the test database before running integration tests.

Uses docker-compose exec to run DELETE statements via psql inside the
db_test container.  Tables are deleted in FK-safe order.
"""
import subprocess
import sys
import os

DB = "bpm_test"
USER = "bpm"

# Tables in FK-safe deletion order (children before parents).
TABLES = [
    "instance_definition_snapshots",
    "process_events",
    "tasks",
    "timers",
    "instance_projections",
    "variable_schemas",
    "process_definitions",
    "events",
    "event_store",
    "audit_log",
    "audit_entries",
    "dlq",
    "webhook_subscriptions",
    "schema_migrations",
]


def run_psql(sql: str) -> bool:
    """Execute SQL via docker-compose exec db_test psql.  Returns True on success."""
    cmd = [
        "docker-compose", "exec", "-T", "db_test",
        "psql", "-U", USER, "-d", DB,
        "-c", sql,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Ignore "relation does not exist" errors (table may not have been created yet).
        stderr_lower = result.stderr.lower()
        if "does not exist" in stderr_lower or "relation" in stderr_lower:
            return True
        print(f"WARNING: psql '{sql[:60]}...' failed: {result.stderr.strip()}", file=sys.stderr)
        return False
    return True


def main() -> None:
    print("Cleaning test database...", flush=True)
    for table in TABLES:
        if table == "audit_entries":
            run_psql("TRUNCATE TABLE audit_entries")
        else:
            run_psql(f"DELETE FROM {table}")
    print("Test database cleaned.", flush=True)


if __name__ == "__main__":
    main()
