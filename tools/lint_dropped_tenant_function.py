#!/usr/bin/env python3
"""
ISS-0688 / GH-745: CI linter guarding against silent reintroduction of
bpm_effective_tenant_id() calls in src/.

Background: bpm_effective_tenant_id() was a SQL function (reading the
session GUC bpm.tenant_id) used by the pre-SCHEMA LEGACY_RLS tenant
isolation model. It was dropped from the `public` schema by the
LEGACY_RLS-to-SCHEMA cutover migrations (GBL-116/123/130/131) as part of
SPT-03 (commit 584408611586c). Every PER_TENANT table (process_definitions,
instance_projections, audit_entries, ...) is now reached via SCHEMA-mode
search_path routing, so any SQL predicate referencing this function against
the `public` copy fails outright with Postgres 42883 (undefined function).

A subtler trap: a per-tenant-SCHEMA copy of bpm_effective_tenant_id() still
exists in every tenant_* schema (created earlier by migration 028, never
dropped there) and reads the SAME session GUC — but SCHEMA mode never sets
that GUC (src/db/pool.zig applyRequestStorageRouting(), SCHEMA branch), so
the per-tenant copy silently falls back to the all-zero UUID default rather
than raising an error. This makes the bug backwards-compatible-looking for
the seeded default tenant (whose UUID IS the all-zero UUID) while silently
wrong for every other tenant — see ISS-0688 for a live example of this
masking a hard 42883 in tests scoped to the default tenant.

ISS-0688 / GH-745 found this SQL function call had been silently
reintroduced into src/engine/instance.zig's InstanceStore.create() after
SPT-03 had already removed it once (by some later, untracked merge/rebase),
breaking POST /api/v1/instances entirely in SCHEMA mode. This linter is the
"standing check" ISS-0688's prevention plan asked for: any surviving
reference in src/ is unconditionally broken code, never a legitimate call —
bind the requesting tenant as an explicit $N::uuid parameter instead (see
src/engine/instance.zig and src/engine/pin_resolver.zig for the pattern).

Deliberately scoped to src/ only (not tests/): several integration test
fixture files (e.g. tests/integration/adp02_tenant_scope_test.zig,
tests/integration/adp03_tenant_context_resolution_test.zig) still seed rows
via raw SQL using bpm_effective_tenant_id() against the default tenant,
where it happens to resolve correctly today (see the masking trap above) —
that is a separate, already-flagged latent bug (see ISS-0688's follow-up
note), not the class of unconditional breakage this linter guards against
in shipped application code.

Exits 0 if clean, 1 if any reference is found in src/.

Usage:
    python3 tools/lint_dropped_tenant_function.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

SRC_DIR = REPO_ROOT / "src"

# src/design/ is documentation describing the historical architecture and
# the cutover itself -- it must be able to name the function to explain why
# it was removed. Excluded the same way lint_sql_table_refs.py excludes it.
EXEMPT_PATH_PREFIXES = ("src/design/",)

SCAN_EXTENSIONS = (".zig",)

# Comment lines that merely explain why the function is NOT called are fine
# ("dropped bpm_effective_tenant_id()", "no bpm_effective_tenant_id() call",
# "never bpm_effective_tenant_id()", etc.) -- only flag it when the token is
# followed by an opening paren immediately preceded by non-comment code
# context, i.e. an actual call `bpm_effective_tenant_id(`. Comment-only
# mentions in *.zig line comments (//, ///) are allowed so the fix's own
# explanatory comments (and future ones) don't trip this linter -- the same
# shape of false positive lint_migration_schema.py had to guard against
# (ISS-0109).
CALL_RE = re.compile(r"bpm_effective_tenant_id\s*\(")
COMMENT_LINE_RE = re.compile(r"^\s*//")


def find_violations() -> list[tuple[str, int, str]]:
    violations = []
    for path in sorted(SRC_DIR.rglob("*")):
        if not path.is_file() or path.suffix not in SCAN_EXTENSIONS:
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        if any(rel.startswith(p) for p in EXEMPT_PATH_PREFIXES):
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if COMMENT_LINE_RE.match(line):
                continue
            if CALL_RE.search(line):
                violations.append((rel, lineno, line.strip()))
    return violations


def main() -> int:
    violations = find_violations()
    if not violations:
        print("lint_dropped_tenant_function: OK — no bpm_effective_tenant_id() calls in src/.")
        return 0

    print("lint_dropped_tenant_function: BLOCKER — bpm_effective_tenant_id() is dropped from")
    print("public and unconditionally broken wherever called. Bind the requesting tenant as")
    print("an explicit $N::uuid parameter instead (see src/engine/instance.zig, ISS-0688 / GH-745).")
    print()
    for rel, lineno, line in violations:
        print(f"  {rel}:{lineno}: {line}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
