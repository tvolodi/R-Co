#!/usr/bin/env python3
"""
SQL parameter type safety linter for Zig source files.

Catches the two specific patterns that cause PostgreSQL C42883
'operator does not exist' errors, as documented in ISS-0124 / GH #390.

Rules checked:
  BLOCKER — col::text = $N  (column explicitly cast to text; parameter has no
            cast, so PostgreSQL infers it as a non-text type and raises C42883)
  MAJOR   — WHERE col = <integer_literal>  (bare integer compared to a TEXT
            column — fails for known-TEXT columns like schema_migrations.version)

The linter does NOT flag bare `WHERE uuid_col = $N` because PostgreSQL can
coerce text→uuid implicitly; only the explicit `col::text = $N` pattern
blocks the cast.

Exits 0 if no BLOCKER/MAJOR, 1 otherwise.

Usage:
    python3 tools/lint_sql_param_types.py [src_dir] [tests_dir]
    # Defaults: src/ and tests/
"""

import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Patterns that cause real C42883 errors
# ---------------------------------------------------------------------------

# col::text = $N  or  col::TEXT = $N  (no ::type after $N)
# This is the asymmetric-cast anti-pattern: column is cast to text but
# parameter keeps its native type (uuid, integer, etc.) → C42883.
# NOTE: only flag when the parameter binding is a non-string type (uuid etc.).
# If both sides are text (e.g. `id::text = $1` with a []const u8 param) it's safe.
# We detect the risky variant: $N follows a non-text column expression or the
# broader pattern where the cast creates ambiguity in a multi-type comparison.
ASYMMETRIC_TEXT_CAST_RE = re.compile(
    # Catches: WHERE col_uuid::text = $N  (not preceded by plain text context)
    # Specifically: uuid/bigint/int columns cast to text compared to bare $N
    r'\b(id|tenant_id|user_id|instance_id|onboarding_id|assignee_ref)::text\s*(?:=|!=|<>)\s*\$(\d+)(?!\s*::(?:text|uuid))',
    re.IGNORECASE,
)

# Known-TEXT columns that must not be compared to bare integer literals
# Only flag when it looks like SQL context: preceded by WHERE/AND keyword on the same line
TEXT_COLUMNS_VS_INT_RE = re.compile(
    r'\b(?:WHERE|AND)\b[^"\']*\b(version)\s*=\s*(\d+)\b(?![\'"\.])',
    re.IGNORECASE,
)

# ---------------------------------------------------------------------------
# Linting logic
# ---------------------------------------------------------------------------

def lint_file(path: Path) -> list:
    issues = []
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return issues

    lines = content.splitlines()

    for lineno, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue

        # BLOCKER: col::text = $N  (asymmetric cast)
        for m in ASYMMETRIC_TEXT_CAST_RE.finditer(line):
            col, param = m.group(1), m.group(2)
            issues.append((
                "BLOCKER", str(path), lineno,
                f"asymmetric cast: '{col}::text = ${param}' — parameter ${param} "
                f"lacks a ::type cast. Add ${param}::text or remove the column cast. "
                f"C42883 risk (ISS-0124).",
            ))

        # MAJOR: WHERE version = 77  (integer literal vs TEXT column)
        for m in TEXT_COLUMNS_VS_INT_RE.finditer(line):
            col, val = m.group(1), m.group(2)
            issues.append((
                "MAJOR", str(path), lineno,
                f"column '{col}' (TEXT) compared to bare integer {val} — "
                f"use '{val}' (string literal) instead. C42883 risk (ISS-0124).",
            ))

    return issues


def lint_tree(roots: list[Path]) -> list:
    all_issues = []
    for root in roots:
        for zig_file in sorted(root.rglob("*.zig")):
            # Skip vendor and generated code
            parts = zig_file.parts
            if any(p in ("vendor", "zig-cache", "zig-out", "zig-out-check") for p in parts):
                continue
            all_issues.extend(lint_file(zig_file))
    return all_issues


def main(argv: list[str]) -> int:
    roots = []
    if len(argv) > 1:
        roots = [Path(a) for a in argv[1:]]
    else:
        for default in ("src", "tests"):
            p = Path(default)
            if p.exists():
                roots.append(p)

    if not roots:
        print("ERROR: no source directories found", file=sys.stderr)
        return 1

    issues = lint_tree(roots)

    blockers = [i for i in issues if i[0] == "BLOCKER"]
    majors   = [i for i in issues if i[0] == "MAJOR"]
    minors   = [i for i in issues if i[0] == "MINOR"]

    for severity, path, lineno, msg in sorted(issues, key=lambda x: (x[0], x[1], x[2])):
        rel = path.replace("\\", "/")
        # Trim to repo-relative path
        for prefix in ("src/", "tests/"):
            idx = rel.find(prefix)
            if idx >= 0:
                rel = rel[idx:]
                break
        print(f"[{severity}] {rel}:{lineno}: {msg}")

    print(f"\nSummary: {len(blockers)} BLOCKER, {len(majors)} MAJOR, {len(minors)} MINOR")

    if blockers or majors:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
