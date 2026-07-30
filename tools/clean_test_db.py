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
# NOTE: schema_migrations is deliberately excluded — we clean test DATA only,
# not the migration tracking table. This allows migrations to remain idempotent:
# TestHarness.init() will see which migrations have already run and skip them.
TABLES = [
    "instance_definition_snapshots",
    "tasks",
    "timers",
    "instance_projections",
    "variable_schemas",
    "process_definitions",
    "events",
    "audit_log",
    "audit_entries",
    "dead_letter_items",
    "webhook_subscriptions",
]

# Mandatory system roles seeded across identity migrations. Integration cleanup
# must restore them so deterministic runs do not depend on historical DB state.
SYSTEM_ROLES = [
    ("PLATFORM_ADMIN", "Full platform access; cannot be deleted"),
    ("PROCESS_DESIGNER", "Create/modify process definitions"),
    ("PROCESS_OPERATOR", "Manage instances and tasks"),
    ("VIEWER", "Read-only access to instances and definitions"),
    ("TASK_WORKER", "Complete and read assigned tasks"),
    ("AGENT_RUNNER", "Agent execution account role for pipeline/runtime automation"),
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
    # Use TRUNCATE with CASCADE to properly handle foreign key dependencies.
    # This is much faster than DELETE and guarantees all dependent rows are removed.
    # Order doesn't matter with CASCADE, but we keep the original order for clarity.

    # Build comma-separated list of all tables for atomic TRUNCATE.
    tables_str = ", ".join(TABLES)
    ok = run_psql(f"TRUNCATE TABLE {tables_str} CASCADE")
    if not ok:
        print("ERROR: Test database cleanup failed; aborting integration run.", file=sys.stderr)
        sys.exit(1)

    # Clean tenant-schema tables (Stage 12 schema-per-tenant).
    # Public-schema TRUNCATE does not reach tenant_default.* tables; clean them
    # separately using a SET search_path so FK-referencing tables are also cleared.
    TENANT_SCHEMAS = ["tenant_default"]
    TENANT_TABLES = [
        "instance_definition_snapshots",
        "tasks",
        "timers",
        "instance_projections",
        "variable_schemas",
        "process_definitions",
        "events",
    ]
    for schema in TENANT_SCHEMAS:
        tenant_tables_str = ", ".join(TENANT_TABLES)
        run_psql(
            f"SET search_path TO {schema},public; "
            f"TRUNCATE TABLE {tenant_tables_str} CASCADE"
        )

    # Clean tenant rows created by integration tests.
    # ENV-01 added ON DELETE RESTRICT: test tenants must be deleted BEFORE production tenants.
    # Use two-step DELETE to avoid FK violation (test tenant references production tenant).
    # The default system tenant (slug = 'default') is preserved.
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'test' AND slug != 'default'")
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'production' AND slug != 'default'")

    for role_name, role_description in SYSTEM_ROLES:
        sql = (
            "INSERT INTO roles (name, description, is_system) "
            f"VALUES ('{role_name}', '{role_description}', true) "
            "ON CONFLICT (name) DO NOTHING"
        )
        if not run_psql(sql):
            print("ERROR: Failed to reseed mandatory system roles; aborting integration run.", file=sys.stderr)
            sys.exit(1)

    print("Test database cleaned.", flush=True)


if __name__ == "__main__":
    main()
