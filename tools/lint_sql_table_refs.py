#!/usr/bin/env python3
"""
ISS-0123: CI linter guarding against legacy table-name drift in Zig source
and integration test files.

Background: migration 072_tnt01_rename_legacy_tables.sql renamed the canonical
table `dead_letter_queue` to `dead_letter_items` (and similarly
`form_schema_registry` → `repository_form_schemas`). Migration GBL-073 drops
the legacy `public.*` copies. The rename is idempotent (IF EXISTS-guarded)
but the Zig code paths and integration tests must be updated to use the
post-rename name. This linter walks `src/**/*.zig` and
`tests/integration/**/*.zig` and fails the build if any of the legacy
table names appear outside `migrations/` and `src/design/`.

The design artefact (src/design/dlq_rename_and_trigger_isolation.md) is the
one canonical place these names should appear (it documents the rename).
Migration files are excluded because they DO need to reference the legacy
name to perform the rename / drop. Everything else (production code,
integration tests) must use the canonical post-rename name.

Exits 0 if clean, 1 if any legacy table name is found.

Usage:
    python3 tools/lint_sql_table_refs.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Legacy table names that must NOT appear in src/ or tests/integration/
# outside of migrations/ and src/design/.
#
# This linter is intentionally scoped to ISS-0123 (DLQ rename) at the
# moment: only the `dead_letter_queue` literal is gated. Other legacy
# table names (`form_schema_registry`, `audit_log`) are tracked under
# separate issues and will be added to this list when their own fixes
# land — adding them now would cause unrelated CI failures. The linter
# scaffolding (file walker, exempt paths, severity tag) is generic and
# ready to be extended.
LEGACY_TABLE_NAMES = (
    "dead_letter_queue",
)

# Directories we walk.
SRC_DIR = REPO_ROOT / "src"
TESTS_DIR = REPO_ROOT / "tests" / "integration"

# Path prefixes that are allowed to reference legacy table names. The
# migration files perform the rename; the design artefact documents it.
EXEMPT_PATH_PREFIXES = (
    "migrations/",
    "src/design/",
)

# Individual files exempt for the same reason a spell-checker's own word list
# is exempt: they must contain the literal in order to search for it.
#
# iss0123_regression_test.zig is the runnable counterpart of this linter — a
# canary that walks the tree asserting the legacy literal is absent. It has to
# name `dead_letter_queue` to look for it, so scanning it flags the check
# itself. Without this exemption the linter reports 5 BLOCKERs against its own
# regression test and can never pass, which is the same shape of defect as
# ISS-0109 for lint_migration_schema.py (prose that merely *mentions* a
# forbidden pattern tripping the same BLOCKER as a real violation).
EXEMPT_FILES = ("tests/integration/iss0123_regression_test.zig",)

# File extensions to scan.
SCAN_EXTENSIONS = (".zig",)

# Match the legacy name as an identifier (word boundary on each side) to
# avoid false positives on substrings (e.g. 'dead_letter_queue_size' would
# be a false match without word boundaries).
LEGACY_NAME_RE = re.compile(
    r"(?<![\w])(" + "|".join(re.escape(name) for name in LEGACY_TABLE_NAMES) + r")(?![\w])"
)


class Issue:
    def __init__(self, file: str, line: int, column: int, name: str):
        self.file = file
        self.line = line
        self.column = column
        self.name = name

    def __str__(self) -> str:
        return (
            f"[BLOCKER] ISS-0123 {self.file}:{self.line}:{self.column}: "
            f"legacy table name '{self.name}' referenced. "
            f"Use the post-rename canonical name (see "
            f"src/design/dlq_rename_and_trigger_isolation.md)."
        )


def _is_exempt(rel_path: str) -> bool:
    rel = rel_path.replace("\\", "/")
    if rel in EXEMPT_FILES:
        return True
    return any(rel.startswith(prefix) for prefix in EXEMPT_PATH_PREFIXES)


def _walk_zig_files(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return sorted(p for p in root.rglob("*.zig") if p.is_file())


def _lint_file(path: Path) -> list[Issue]:
    issues: list[Issue] = []
    rel = str(path.relative_to(REPO_ROOT))
    if _is_exempt(rel):
        return issues
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"lint_sql_table_refs: cannot read {rel}: {exc}", file=sys.stderr)
        return issues

    for lineno, line in enumerate(content.splitlines(), start=1):
        for m in LEGACY_NAME_RE.finditer(line):
            issues.append(Issue(rel, lineno, m.start() + 1, m.group(1)))
    return issues


def main() -> int:
    files = _walk_zig_files(SRC_DIR) + _walk_zig_files(TESTS_DIR)
    issues: list[Issue] = []
    for f in files:
        issues.extend(_lint_file(f))

    for issue in issues:
        print(issue, file=sys.stderr)

    if issues:
        print(
            f"\nlint_sql_table_refs: FAILED — {len(issues)} legacy table-name "
            f"reference(s) found in src/ or tests/integration/. See "
            f"docs/issue-reports/ISS-0123-root-cause.yaml for context.",
            file=sys.stderr,
        )
        return 1

    print(
        f"lint_sql_table_refs: OK — scanned {len(files)} Zig file(s); no "
        f"legacy table-name references found."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
