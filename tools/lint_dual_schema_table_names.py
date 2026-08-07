#!/usr/bin/env python3
"""ISS-0185: Linter that rejects any migration whose unqualified CREATE TABLE
statement targets a table name already present in another schema after
applying all migrations.

Strategy:
  1. Connect to the test database (BPM_TEST_DB_URL).
  2. Run every migration file in correct migrationOrder() sequence — but
     we cannot easily do that from Python. Instead, we query the *current*
     state of the schema (after `zig build migrate` has already been run
     and applied GBL-134 + GBL-135) and check whether ANY table name is
     duplicated across `public` and `tenant_default`.

This is a state-based lint: it passes only when the post-migration schema
has zero unintended duplicates. Combined with the new -- scope: public /
-- scope: all_schemas headers added by ISS-0185, fresh migrations will
not re-introduce duplicates — the cleanup migrations remove existing
ones, and this linter catches any new ones that slip through.

Exit codes:
  0 = clean (no duplicates)
  1 = BLOCKER (duplicates found)
  2 = environment error (DB unreachable, etc.)

Usage:
  python3 tools/lint_dual_schema_table_names.py
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Allow-list of table names that legitimately live in BOTH public and
# tenant_default (HYBRID tables — both copies anchored to their own FK
# chains). Updated by ISS-0185.
ALLOW_LIST: set[str] = {
    # artifact_* chain: artifact_activations → artifact_versions → repository_artifacts
    "artifact_activation_history",
    "artifact_activations",
    "artifact_versions",
    "event_type_registry_producers",  # FK → public.artifact_versions
    "oidc_migration_item",            # FK → public.oidc_migration_job
    "oidc_migration_job",
    "repository_artifacts",
    # tenant registry: tenant_hostnames → tenant
    "tenant",
    "tenant_hostnames",
}


def _psql() -> str:
    return r"C:\pf\PostgreSQL\17\bin\psql.exe"


def main() -> int:
    db = os.environ.get("BPM_TEST_DB_URL") or os.environ.get("BPM_DB_URL")
    if not db:
        sys.stderr.write("[FAIL] BPM_TEST_DB_URL or BPM_DB_URL must be set\n")
        return 2

    pgpassword = os.environ.get("PGPASSWORD")
    if not pgpassword:
        # psql requires it set even if empty
        os.environ["PGPASSWORD"] = "bpm"

    psql = _psql()
    if not Path(psql).exists():
        sys.stderr.write(f"[FAIL] psql not found at {psql}\n")
        return 2

    # Intersection of table names in public and tenant_default
    sql = (
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='public' AND table_type='BASE TABLE' "
        "INTERSECT "
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='tenant_default' AND table_type='BASE TABLE' "
        "ORDER BY 1;"
    )

    out = subprocess.run(
        [psql, db, "-A", "-t", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        sys.stderr.write(f"[FAIL] psql failed: {out.stderr}\n")
        return 2

    dupes = [line.strip() for line in out.stdout.splitlines() if line.strip()]
    non_allow = [t for t in dupes if t not in ALLOW_LIST]

    if non_allow:
        sys.stderr.write(
            f"[BLOCKER] ISS-0185: {len(non_allow)} table name(s) duplicated "
            f"between public and tenant_default:\n"
        )
        for t in non_allow:
            sys.stderr.write(f"  - {t}\n")
        sys.stderr.write(
            "\nFix: every duplicated table must be classified as GLOBAL_REGISTRY\n"
            "(public canonical; tenant_default shadow) or PER_TENANT\n"
            "(tenant_default canonical; public shadow). Add the source migration\n"
            "to GBL-134 (drop global shadow from tenant) or GBL-135 (drop\n"
            "per-tenant shadow from public). See\n"
            "docs/issue-reports/ISS-0185-diagnosis.yaml for the per-table\n"
            "classification.\n"
        )
        return 1

    sys.stdout.write(
        f"[OK] ISS-0185 dual-schema linter: 0 duplicated table names "
        f"between public and tenant_default\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
