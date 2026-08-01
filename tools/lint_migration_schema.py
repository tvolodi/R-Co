#!/usr/bin/env python3
"""
TNT-02: CI linter for migration SQL files.

Scans .sql files in the migrations/ directory and rejects any non-GBL file
that contains a public.<business_table> reference for the 21 business tables
that must live exclusively in per-tenant schemas.

References to permitted platform tables (public.tenant, public.schema_migrations,
etc.) are allowed and emit a MINOR informational note, not an error.

Exits 0 if clean, 1 if any BLOCKER violations found.

Usage:
    python3 tools/lint_migration_schema.py [migrations_dir]
    # Default migrations_dir: migrations/ (relative to repo root)
"""

import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Business tables that MUST NOT appear schema-qualified in migration files.
# These 21 tables must live exclusively in per-tenant schemas.
# ---------------------------------------------------------------------------
BUSINESS_TABLES = [
    "events",
    "events_archive",
    "process_definitions",
    "instance_projections",
    "tasks",
    "tokens",
    "timers",
    "audit_entries",
    "audit_log",
    "users",
    "groups",
    "group_members",
    "roles",
    "user_roles",
    "api_tokens",
    "webhook_subscriptions",
    "dead_letter_items",
    "event_type_registry",
    "event_retention_policies",
    "repository_form_schemas",
    "instance_sequence",
]

# Regex pattern: public.<business_table> — word boundary after table name so
# e.g. "public.events_archive" does not match as "public.events".
_BUSINESS_TABLE_PATTERN = re.compile(
    r"public\.(" + "|".join(re.escape(t) for t in BUSINESS_TABLES) + r")\b",
    re.IGNORECASE,
)

# ---------------------------------------------------------------------------
# Permitted public references (not rejected — platform routing/registry tables).
# ---------------------------------------------------------------------------
PERMITTED_PUBLIC_TABLES = [
    "tenant",
    "tenant_schemas",
    "tenant_hostnames",
    "tenant_realm_binding",
    "schema_migrations",
    "onboarding_registry",
    "service_catalog",
    "repository_artifacts",
    "repository_activations",
    "alerting_state",
]

_PERMITTED_TABLE_PATTERN = re.compile(
    r"public\.(" + "|".join(re.escape(t) for t in PERMITTED_PUBLIC_TABLES) + r")\b",
    re.IGNORECASE,
)

# ---------------------------------------------------------------------------
# Issue dataclass
# ---------------------------------------------------------------------------


class Issue:
    def __init__(self, code: str, severity: str, file: str, line: int, col: int, text: str):
        self.code = code
        self.severity = severity
        self.file = file
        self.line = line
        self.col = col
        self.text = text

    def __str__(self) -> str:
        return (
            f"[{self.severity}] {self.code} {self.file}:{self.line}:{self.col}: {self.text}"
        )


# ---------------------------------------------------------------------------
# Per-file linting
# ---------------------------------------------------------------------------


def _strip_line_comment(line: str) -> str:
    """
    Strip a trailing `--` SQL line comment, respecting single-quoted string
    literals so a `--` inside a string (e.g. '...--...') is not mistaken for
    a comment marker. Standard SQL comment semantics: `--` outside of a
    string literal runs to end of line.
    """
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "'":
            in_string = not in_string
        elif not in_string and line[i : i + 2] == "--":
            return line[:i]
        i += 1
    return line


def lint_file(path: str) -> list[Issue]:
    """
    Scan a single .sql file for public.<business_table> references.

    GBL-prefixed files are exempt (they operate on the global public schema).

    Plain `--` line comments are stripped before matching, so prose that
    merely mentions a business table by name is not flagged as executable
    SQL (TNT-02 only cares about actual schema-qualified references).

    Also scans string literals inside DO $$ BEGIN ... END $$ blocks for
    embedded SQL that might reference business tables by schema-qualified name.
    """
    issues: list[Issue] = []
    basename = os.path.basename(path)

    # GBL-prefixed files operate on public schema — exempt from business-table checks.
    if basename.startswith("GBL-"):
        return issues

    try:
        content = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        issues.append(
            Issue("M000", "BLOCKER", path, 0, 0, f"Could not read file: {exc}")
        )
        return issues

    lines = content.splitlines()

    # Track whether we're inside a DO $$ ... $$ block to detect string-literal
    # references in dynamic SQL per TNT-02 edge case.
    in_do_block = False
    do_block_depth = 0

    for lineno, line in enumerate(lines, start=1):
        code = _strip_line_comment(line)

        # Detect DO $$ block boundaries (simple heuristic — handles common patterns).
        # Uses the comment-stripped text so a `--` comment mentioning "DO $$" in
        # prose cannot be mistaken for an actual block boundary.
        if re.search(r"\bDO\b.*\$\$", code, re.IGNORECASE):
            in_do_block = True
            do_block_depth += 1
        elif in_do_block and "$$" in code:
            do_block_depth -= 1
            if do_block_depth <= 0:
                in_do_block = False
                do_block_depth = 0

        # Check for business table references on this line's code (comments excluded).
        # Inside a DO block: also check inside single-quoted string literals.
        targets_to_check = [code]
        if in_do_block:
            # Extract single-quoted string literals within the DO block.
            string_literals = re.findall(r"'([^']*)'", code)
            targets_to_check.extend(string_literals)

        for target in targets_to_check:
            for match in _BUSINESS_TABLE_PATTERN.finditer(target):
                col = match.start() + 1
                table = match.group(1)
                issues.append(
                    Issue(
                        "M001",
                        "BLOCKER",
                        path,
                        lineno,
                        col,
                        f"public.{table} reference in migration file — business tables must be "
                        f"unqualified (search_path handles schema routing per TNT-02)",
                    )
                )

        # Check for permitted public references — emit MINOR informational note.
        # These are valid (e.g. public.schema_migrations in migration runner code)
        # and do NOT cause a non-zero exit.
        for match in _PERMITTED_TABLE_PATTERN.finditer(code):
            table = match.group(1)
            col = match.start() + 1
            issues.append(
                Issue(
                    "M002",
                    "MINOR",
                    path,
                    lineno,
                    col,
                    f"public.{table} reference — permitted platform table (allowed, not an error)",
                )
            )

    return issues


# ---------------------------------------------------------------------------
# Directory-level linting
# ---------------------------------------------------------------------------


def lint_directory(migrations_dir: str) -> list[Issue]:
    """
    Scan all .sql files in migrations_dir.

    Returns a flat list of all Issues found across all files.
    """
    all_issues: list[Issue] = []
    migrations_path = Path(migrations_dir)

    if not migrations_path.is_dir():
        all_issues.append(
            Issue("M000", "BLOCKER", migrations_dir, 0, 0, f"Directory not found: {migrations_dir}")
        )
        return all_issues

    sql_files = sorted(migrations_path.glob("*.sql"))
    if not sql_files:
        # No SQL files is technically clean.
        return all_issues

    for sql_file in sql_files:
        file_issues = lint_file(str(sql_file))
        all_issues.extend(file_issues)

    return all_issues


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "migrations"

    # Single-file mode: when argv[1] is a .sql file path, lint that file directly.
    # Directory mode: when argv[1] is a directory, lint all .sql files inside it.
    if Path(target).is_file():
        issues = lint_file(target)
        files_scanned = 1
    else:
        issues = lint_directory(target)
        files_scanned = len(list(Path(target).glob("*.sql"))) if Path(target).is_dir() else 0

    blockers = [i for i in issues if i.severity == "BLOCKER"]
    minors = [i for i in issues if i.severity == "MINOR"]

    # Print MINOR notes first (informational).
    for issue in minors:
        print(issue)

    # Print BLOCKER errors.
    for issue in blockers:
        print(issue, file=sys.stderr)

    if blockers:
        print(
            f"\nlint_migration_schema: FAILED — {len(blockers)} BLOCKER violation(s) found.",
            file=sys.stderr,
        )
        return 1

    print(f"lint_migration_schema: OK — {files_scanned} file(s) scanned, 0 violations.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
