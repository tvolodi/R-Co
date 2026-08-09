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
    # ISS-0101 / GH-359: `tenant` and `tenant_hostnames` were previously
    # allow-listed here as a KNOWN duplicate while GBL-140 and the
    # 031/050 scope-header patch were pending. Both are GLOBAL_REGISTRY
    # (canonical home = public) and no longer belong on this allow-list —
    # migrations/GBL-140_iss0101_drop_shadow_tenant_tables.sql removes the
    # tenant_default shadow, and migrations/031_adp04b_tenant_realm_binding.sql
    # / migrations/050_tenant_hostnames.sql now carry `-- scope: public`
    # headers (plus public.-qualified DDL) so no future reprovision can
    # recreate the shadow. Removed from the allow-list deliberately so a
    # regression here fails this linter instead of passing silently.
    # ISS-0620 / GH-573, BLOCKER: KNOWN, INTENTIONAL, TEMPORARY duplicate —
    # NOT a HYBRID classification. GBL-134 wrongly dropped these 4 tables'
    # tenant_default copies (they are PER_TENANT per ISS-0185-diagnosis.yaml's
    # classification_table.per_tenant_public_is_stray; canonical home =
    # tenant_default). GBL-137 recreates the tenant_default structure as a
    # non-destructive forward-fix, but GBL-135 never dropped these tables'
    # `public` copies (they were never in its v_tables array), so `public`
    # is now the stray shadow — genuinely a duplicate again. Dropping the
    # stray `public` copy is a destructive DROP and is deliberately deferred
    # to its own, separately reviewed migration/issue rather than bundled
    # into GBL-137's additive-only forward-fix. Remove these 4 names from
    # this allow-list once that follow-up migration lands.
    "artifact_activation_groups",
    "entity_definitions",
    "entity_record_latest",
    "entity_type_instances",
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
