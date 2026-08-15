#!/usr/bin/env python3
"""
ISS-0088: CI linter guarding against stale table-name drift in test cleanup
tooling.

tools/clean_test_db.py's TABLES/TENANT_TABLES lists and
tests/integration/helpers.zig's resetTestData() both hard-code business table
names as plain strings for best-effort TRUNCATE cleanup. Neither file is
validated against the live schema, so a rename/drop anywhere in migration
history (e.g. GBL-073, 072_tnt01_rename_legacy_tables.sql) can silently desync
them — the try/best-effort error handling that exists to tolerate partial
migration states also hides permanent stale references (relation does not
exist errors swallowed identically to genuinely-missing tables).

This linter extracts every string-literal table name referenced by the two
cleanup call sites and checks it against the canonical BUSINESS_TABLES list
in lint_migration_schema.py (the same list migrations are linted against),
plus a small allowlist of non-business platform tables those call sites also
touch (e.g. service_catalog).

Exits 0 if clean, 1 if any referenced table name is not recognized.

Usage:
    python3 tools/lint_test_table_refs.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_migration_schema import BUSINESS_TABLES  # noqa: E402

# Table names the cleanup call sites are also allowed to reference that are
# not covered by lint_migration_schema.py's BUSINESS_TABLES (that list only
# covers the 21 tables relocated by the TNT-01 migration).
EXTRA_ALLOWED_TABLES = {
    "service_catalog",
    "instance_definition_snapshots",  # migrations/004_definitions.sql
    "variable_schemas",  # migrations/012_event_retention.sql
    # PLC-01..04 (WF02-plc-batch-a-20260815): public catalog tables cleaned
    # between integration runs so module_id's global uniqueness does not
    # collide with prior-run data.
    "process_module_catalog",
    "process_module_catalog_share",
}

KNOWN_TABLES = set(BUSINESS_TABLES) | EXTRA_ALLOWED_TABLES

CLEAN_TEST_DB_PY = REPO_ROOT / "tools" / "clean_test_db.py"
HELPERS_ZIG = REPO_ROOT / "tests" / "integration" / "helpers.zig"


class Issue:
    def __init__(self, file: str, line: int, table: str):
        self.file = file
        self.line = line
        self.table = table

    def __str__(self) -> str:
        return (
            f"[BLOCKER] T001 {self.file}:{self.line}: table '{self.table}' is not a "
            f"known current table (see tools/lint_migration_schema.py BUSINESS_TABLES). "
            f"Likely a stale/renamed reference — check migrations for a RENAME/DROP."
        )


def _extract_list_literal(content: str, var_name: str) -> list[tuple[int, str]]:
    """Return (line_number, table_name) pairs for string literals inside a
    Python top-level `var_name = [ ... ]` list literal."""
    results: list[tuple[int, str]] = []
    match = re.search(rf"^{re.escape(var_name)}\s*=\s*\[", content, re.MULTILINE)
    if not match:
        return results

    start = match.end()
    depth = 1
    end = start
    for i in range(start, len(content)):
        if content[i] == "[":
            depth += 1
        elif content[i] == "]":
            depth -= 1
            if depth == 0:
                end = i
                break
    block = content[start:end]
    block_start_line = content[:start].count("\n") + 1

    for m in re.finditer(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', block):
        line_no = block_start_line + block[: m.start()].count("\n")
        results.append((line_no, m.group(1)))
    return results


def lint_clean_test_db_py() -> list[Issue]:
    issues: list[Issue] = []
    if not CLEAN_TEST_DB_PY.is_file():
        return issues
    content = CLEAN_TEST_DB_PY.read_text(encoding="utf-8")
    rel = str(CLEAN_TEST_DB_PY.relative_to(REPO_ROOT))

    for var_name in ("TABLES", "TENANT_TABLES"):
        for line_no, table in _extract_list_literal(content, var_name):
            if table not in KNOWN_TABLES:
                issues.append(Issue(rel, line_no, table))
    return issues


def lint_helpers_zig() -> list[Issue]:
    issues: list[Issue] = []
    if not HELPERS_ZIG.is_file():
        return issues
    content = HELPERS_ZIG.read_text(encoding="utf-8")
    rel = str(HELPERS_ZIG.relative_to(REPO_ROOT))

    for lineno, line in enumerate(content.splitlines(), start=1):
        m = re.search(r'truncateTableBestEffort\(\s*conn\s*,\s*"([a-zA-Z_][a-zA-Z0-9_]*)"\s*\)', line)
        if m:
            table = m.group(1)
            if table not in KNOWN_TABLES:
                issues.append(Issue(rel, lineno, table))
    return issues


def main() -> int:
    issues = lint_clean_test_db_py() + lint_helpers_zig()

    for issue in issues:
        print(issue, file=sys.stderr)

    if issues:
        print(
            f"\nlint_test_table_refs: FAILED — {len(issues)} stale/unknown table reference(s) found.",
            file=sys.stderr,
        )
        return 1

    print("lint_test_table_refs: OK — all referenced table names are current.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
