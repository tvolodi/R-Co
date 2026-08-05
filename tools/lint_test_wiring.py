#!/usr/bin/env python3
"""
lint_test_wiring.py — Catch test files that are wired into no build target.

Why this exists
----------------
Zig compiles a file whenever anything imports it, but only *runs* that
file's `test` blocks if the file is reachable from a `b.addTest(...)` root
(directly as the root itself, or transitively via an `@import` chain that a
root pulls in). A file can therefore compile cleanly, sit in the repo for
months, and contribute zero test coverage while `zig build test` reports
green the entire time — because nothing ever asked Zig to run its tests.

This has happened twice in this repo:
  - ISS-0102: six OIDC test files wired into no build target.
  - ISS-0132 / GH #428: src/engine/transition.zig carried 26 in-file tests
    (30 once GH #428 added more) that never executed because build.zig
    referenced the file only as an imported *module* (`transition_mod`),
    never as an `addTest` root — in the engine's purest, most
    safety-critical module. See docs/anti-patterns.md and
    src/transition_test_root.zig for the full story and the shim pattern
    that fixed it.

What this checks
-----------------
  1. Find every `src/**/*.zig` and `tests/**/*.zig` file containing at least
     one `test "..."` or `test {` block.
  2. Find every `addTest` root file referenced in build.zig
     (`.root_source_file = b.path("...")` immediately following a
     `b.addTest(` call).
  3. For each addTest root that is itself a thin shim (few or no `test`
     blocks of its own, just `@import(...)` statements — the pattern used by
     tests/unit/*_test_root.zig and src/transition_test_root.zig), resolve
     each `@import("relative/path.zig")` it contains to the file it pulls in
     (relative to the shim's own directory), and treat that file — and
     anything it in turn imports — as reachable too. This handles one level
     of indirection explicitly and recurses, since `main_test.zig` imports
     `helpers.zig` which some integration tests need but don't import
     directly.
  4. Any test-bearing file from step 1 that is not itself an addTest root
     and was never reached in step 3 is reported as UNWIRED — the file's
     tests silently never run.

This is intentionally a regex/line-scan, not a Zig AST parser — consistent
with every other tools/lint_*.py in this repo. It will not catch cleverly
disguised imports (computed paths, non-literal @import arguments), but
those don't appear anywhere in this codebase today (verified by grep).

Exit codes:
  0  every test-bearing file is reachable from some addTest root
  1  one or more test-bearing files are unreachable (UNWIRED)
  2  bad invocation
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_ZIG = REPO_ROOT / "build.zig"

SCAN_DIRS = ("src", "tests")

TEST_BLOCK = re.compile(r'^\s*test\s+("[^"]*"\s*)?\{', re.MULTILINE)
ADD_TEST_CALL = re.compile(r"\bb\.addTest\(")
ROOT_SOURCE_FILE = re.compile(r'\.root_source_file\s*=\s*b\.path\(\s*"([^"]+)"\s*\)')
IMPORT_LITERAL = re.compile(r'@import\(\s*"([^"]+\.zig)"\s*\)')

# How many lines after `b.addTest(` to look for the matching
# `.root_source_file = b.path("...")`. build.zig's addTest calls are always
# `b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = ... }) })`
# — 1-3 lines apart in every occurrence in this file (verified by inspection);
# generous headroom in case that literal formatting drifts slightly.
ADD_TEST_LOOKAHEAD_LINES = 6

# A shim/root file is treated as "resolve its @import chain" rather than
# "must itself contain test blocks" when it has at most this many of its own
# non-imported test blocks. tests/unit/*_test_root.zig and
# src/transition_test_root.zig all have either 0 or exactly 1 (the wrapping
# `test { ... }` block itself, which Zig counts as a synthetic container
# test — see graph_test_root.zig's doc comment).
SHIM_OWN_TEST_BLOCK_MAX = 1


def find_test_bearing_files() -> set[Path]:
    """Every .zig file under src/ or tests/ containing a test block."""
    found: set[Path] = set()
    for top in SCAN_DIRS:
        base = REPO_ROOT / top
        if not base.is_dir():
            continue
        for path in base.rglob("*.zig"):
            try:
                text = path.read_text(encoding="utf-8-sig")
            except OSError:
                continue
            if TEST_BLOCK.search(text):
                found.add(path.resolve())
    return found


def find_addtest_roots() -> set[Path]:
    """Every root_source_file that is the root of a b.addTest(...) call."""
    if not BUILD_ZIG.is_file():
        return set()
    text = BUILD_ZIG.read_text(encoding="utf-8-sig")
    lines = text.splitlines()

    roots: set[Path] = set()
    for i, line in enumerate(lines):
        if not ADD_TEST_CALL.search(line):
            continue
        window = "\n".join(lines[i : i + ADD_TEST_LOOKAHEAD_LINES])
        m = ROOT_SOURCE_FILE.search(window)
        if not m:
            continue
        candidate = (REPO_ROOT / m.group(1)).resolve()
        if candidate.is_file():
            roots.add(candidate)
    return roots


def resolve_imports(path: Path) -> list[Path]:
    """Literal @import("*.zig") targets referenced from `path`, resolved
    relative to path's own directory (Zig's @import resolution rule for
    relative paths). Non-.zig imports (module names like "std", "bpm",
    "expr") are not returned since IMPORT_LITERAL requires a .zig suffix.
    """
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return []
    targets: list[Path] = []
    for m in IMPORT_LITERAL.finditer(text):
        candidate = (path.parent / m.group(1)).resolve()
        if candidate.is_file():
            targets.append(candidate)
    return targets


def count_own_test_blocks(path: Path) -> int:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return 0
    return len(TEST_BLOCK.findall(text))


def reachable_from_roots(roots: set[Path]) -> set[Path]:
    """BFS over @import edges starting at every addTest root. A root that
    carries more than SHIM_OWN_TEST_BLOCK_MAX test blocks of its own is
    still walked (its imports might legitimately pull in more coverage,
    e.g. main_test.zig importing helpers.zig), but the walk is not required
    to explain why the root itself is reachable — it always is, by
    definition, since it's the file Zig starts analysis from.
    """
    reachable: set[Path] = set()
    frontier = list(roots)
    while frontier:
        current = frontier.pop()
        if current in reachable:
            continue
        reachable.add(current)
        for target in resolve_imports(current):
            if target not in reachable:
                frontier.append(target)
    return reachable


def relpath(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT)).replace("\\", "/")
    except ValueError:
        return str(path)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--quiet", action="store_true", help="print only the verdict line"
    )
    args = parser.parse_args(argv[1:])

    test_bearing = find_test_bearing_files()
    roots = find_addtest_roots()
    reachable = reachable_from_roots(roots)

    unwired = sorted(
        (p for p in test_bearing if p not in reachable), key=relpath
    )

    if not args.quiet:
        print(f"lint_test_wiring: {len(test_bearing)} test-bearing file(s) found")
        print(f"lint_test_wiring: {len(roots)} addTest root(s) in build.zig")
        print(f"lint_test_wiring: {len(reachable)} file(s) reachable from a root")
        print()

    if unwired:
        for path in unwired:
            print(f"  [UNWIRED] {relpath(path)}")
            print(
                "            contains a test block but is not reachable from any "
                "b.addTest(...) root in build.zig"
            )
        print()
        print(
            f"lint_test_wiring: FAIL — {len(unwired)} test-bearing file(s) unwired "
            "into no build target"
        )
        print(
            "  Fix: add the file as its own addTest root, or add "
            '`_ = @import("...")` / `std.testing.refAllDecls(...)` to an '
            "existing root/shim that reaches it. See "
            "src/transition_test_root.zig for the shim pattern when the file "
            "cannot be its own root (module-root constraint)."
        )
        return 1

    print(
        f"lint_test_wiring: PASS — all {len(test_bearing)} test-bearing file(s) "
        "reachable from an addTest root"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
