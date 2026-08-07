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
  5. Separately: every `b.addRunArtifact(<addTest result>)` binding in
     build.zig must appear in at least one `<step>.dependOn(&<binding>.step)`
     call. A Run artifact that is created and configured but attached to no
     step is built on demand and never executed. Such a binding is reported
     as UNATTACHED.

Why check 5 exists (ISS-0150 / GH #466)
----------------------------------------
Checks 1-4 prove a test-bearing file is REACHABLE from an addTest root. They
say nothing about whether that root is ever RUN. tests/integration/
entity_subsystem_test.zig fell straight through that gap: it had its own
addTest artifact and its own fully configured Run artifact (setCwd,
setEnvironmentVariable) — so this linter reported it as correctly wired —
but the `dependOn` line attaching that Run artifact to the integration
barrier step was missing. Every sibling target in the same region of
build.zig had one. The file was therefore compiled and never executed, and
had in fact stopped compiling entirely (it was written against a TestHarness
API that no longer existed) without any gate noticing. See docs/issues/
ISS-0150.json.

This is intentionally a regex/line-scan, not a Zig AST parser — consistent
with every other tools/lint_*.py in this repo. It will not catch cleverly
disguised imports (computed paths, non-literal @import arguments), but
those don't appear anywhere in this codebase today (verified by grep).

Exit codes:
  0  every test-bearing file is reachable from some addTest root, and every
     addTest Run artifact is attached to at least one build step
  1  one or more test-bearing files are unreachable (UNWIRED), or one or more
     addTest Run artifacts are attached to no step (UNATTACHED)
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

# Directory names (anywhere under SCAN_DIRS) that hold fixture / test-data
# files — positive or negative controls consumed by *lint* tools, not by
# zig's test runner. Files in these directories are not required to be
# reachable from a b.addTest(...) root in build.zig. Currently used by:
#   tests/integration/_fixtures/lint_tenant_provisioning/ (ISS-0605 / GH-537)
FIXTURE_DIR_NAMES = ("_fixtures",)

TEST_BLOCK = re.compile(r'^\s*test\s+("[^"]*"\s*)?\{', re.MULTILINE)
ADD_TEST_CALL = re.compile(r"\bb\.addTest\(")
ROOT_SOURCE_FILE = re.compile(r'\.root_source_file\s*=\s*b\.path\(\s*"([^"]+)"\s*\)')
IMPORT_LITERAL = re.compile(r'@import\(\s*"([^"]+\.zig)"\s*\)')

# `const <name> = b.addTest(.{` — captures the binding an addTest result is
# stored under, so a later addRunArtifact(<name>) can be tied back to a test.
ADD_TEST_BINDING = re.compile(r"\bconst\s+(\w+)\s*=\s*b\.addTest\(")
# `const <run_name> = b.addRunArtifact(<artifact_name>);`
ADD_RUN_ARTIFACT = re.compile(
    r"\bconst\s+(\w+)\s*=\s*b\.addRunArtifact\(\s*(\w+)\s*\)"
)
# Any `<owner>.dependOn(<target>)` edge in build.zig. Both owner and target may
# be written either as a bare binding (`test_step`) or as a binding's `.step`
# field (`run_foo.step` / `&run_foo.step`); the optional `&` and `.step` are
# stripped so both spellings collapse to the same binding name. Capturing the
# `X.step.dependOn(Y)` owner form matters: build.zig attaches the integration
# barrier with `run_iss503_..._after_others.step.dependOn(test_integration_others_step)`,
# and a pattern anchored on a bare owner would miss that edge entirely and then
# report ~40 correctly-wired targets as unattached.
DEPEND_ON_EDGE = re.compile(
    r"\b(\w+)(?:\.step)?\s*\.dependOn\(\s*&?\s*(\w+)(?:\.step)?\s*\)"
)
# `const <name> = b.step("<public-name>", ...)` — a user-invocable build step.
STEP_BINDING_DECL = re.compile(r'\bconst\s+(\w+)\s*=\s*b\.step\(\s*"([^"]+)"')

# Known-unattached test binaries with an open tracking issue, kept OUT of the
# failure count so this check can gate `zig build test` today without hiding
# what it found. Each entry must name the issue that will remove it. This is a
# ledger, not a suppression list: entries are reported on every run (as KNOWN),
# and adding one without an accompanying issue defeats the check's purpose.
#
# EMPTY, and that is the intended steady state. The ledger's two ISS-0157
# entries (`iss105_integration_tests`, `differential_tests`) were both fixed and
# attached to aggregate steps:
#   * differential_tests never compiled — `@embedFile("../../src/engine/
#     transition.zig")` cannot escape the embedding module's root. The bytes now
#     arrive via src/engine/transition_source_embed.zig; 3/3 tests pass.
#   * iss105_integration_tests' GIN-index assertion passes; 4/4 tests pass.
#
# Adding an entry here is a temporary, visible record while a specific issue is
# open — never a way to keep a failing binary out of the aggregate steps.
KNOWN_UNATTACHED: dict[str, str] = {}

# Steps that CI / the pipeline actually invoke. A test Run artifact reachable
# only from some other narrow, opt-in step is effectively unexecuted: that is
# exactly how entity_subsystem_test.zig hid for months (it WAS attached — to
# `test-integration-exp`, which nothing ever ran). See ISS-0150 / GH #466.
AGGREGATE_STEP_NAMES = ("test", "test-integration")

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
    """Every .zig file under src/ or tests/ containing a test block.

    Files inside any FIXTURE_DIR_NAMES directory are excluded — those are
    positive/negative controls consumed by *lint* tools (e.g. tools/
    lint_test_tenant_provisioning.py) and are not meant to run as zig tests.
    """
    found: set[Path] = set()
    for top in SCAN_DIRS:
        base = REPO_ROOT / top
        if not base.is_dir():
            continue
        for path in base.rglob("*.zig"):
            # Fixture files live under a _fixtures/ subdirectory anywhere
            # in the tree; they're test data, not test code.
            if any(part in FIXTURE_DIR_NAMES for part in path.parts):
                continue
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


def find_unattached_run_artifacts() -> list[tuple[str, str, bool]]:
    """Test Run artifacts not reachable from an aggregate build step.

    Builds the dependOn graph over build.zig's step/Run bindings, then walks it
    from each step whose public name is in AGGREGATE_STEP_NAMES. Any
    addRunArtifact binding that wraps an addTest result and is not reached is
    reported.

    Returns (run_binding_name, test_binding_name, attached_somewhere) triples,
    where attached_somewhere distinguishes "attached to nothing at all" from
    the subtler "attached only to a narrow step nothing invokes".

    Only addRunArtifact bindings whose argument is a known addTest binding are
    considered — addRunArtifact over a normal executable (migrate, bench,
    codegen helpers) is invoked directly by name and needs no dependOn.
    """
    if not BUILD_ZIG.is_file():
        return []
    text = BUILD_ZIG.read_text(encoding="utf-8-sig")

    # binding -> the root source file its addTest compiles.
    lines = text.splitlines()
    test_bindings: dict[str, str] = {}
    for i, line in enumerate(lines):
        m = ADD_TEST_BINDING.search(line)
        if not m:
            continue
        window = "\n".join(lines[i : i + ADD_TEST_LOOKAHEAD_LINES])
        rm = ROOT_SOURCE_FILE.search(window)
        test_bindings[m.group(1)] = rm.group(1) if rm else ""

    step_bindings = {m.group(1): m.group(2) for m in STEP_BINDING_DECL.finditer(text)}

    # edges: binding -> set of bindings it depends on
    edges: dict[str, set[str]] = {}
    attached_anywhere: set[str] = set()
    for m in DEPEND_ON_EDGE.finditer(text):
        owner, target = m.group(1), m.group(2)
        edges.setdefault(owner, set()).add(target)
        attached_anywhere.add(target)

    # Walk from every aggregate step.
    reached: set[str] = set()
    frontier = [
        binding
        for binding, public_name in step_bindings.items()
        if public_name in AGGREGATE_STEP_NAMES
    ]
    while frontier:
        current = frontier.pop()
        if current in reached:
            continue
        reached.add(current)
        frontier.extend(edges.get(current, ()))

    # Group Run artifacts by the addTest binding they wrap. build.zig sometimes
    # creates a SECOND Run artifact over the same test binary to carry a
    # different ordering edge (run_iss503_integration_tests_after_others exists
    # precisely so the barrier dependency does not leak onto the narrow step's
    # shared Run artifact, since dependOn edges are global to a Step in Zig's
    # build graph). The test binary is executed as long as ANY of its Run
    # artifacts is reachable, so the question is per-artifact, not per-binding.
    runs_by_artifact: dict[str, list[str]] = {}
    for m in ADD_RUN_ARTIFACT.finditer(text):
        run_name, artifact_name = m.group(1), m.group(2)
        if artifact_name not in test_bindings:
            continue  # not a test binary — runs by name, not via a step
        runs_by_artifact.setdefault(artifact_name, []).append(run_name)

    # Every source file whose test blocks DO execute: the roots of executing
    # artifacts, plus everything those roots pull in via @import. Two distinct
    # build-graph shapes make an idle artifact harmless, and neither is the
    # defect this check hunts for:
    #   - a duplicate addTest over an already-executing root
    #     (svc_integration_tests / env_integration_tests are both extra roots
    #     over main_test.zig, which run_integration_tests already executes);
    #   - a dedicated root for a file that the main_test.zig aggregate also
    #     imports, so its blocks run inside that binary regardless.
    # The genuine defect is a file that executes in NO binary at all.
    executed_roots: set[Path] = set()
    for artifact_name, runs in runs_by_artifact.items():
        if not any(r in reached for r in runs):
            continue
        rel = test_bindings.get(artifact_name)
        if not rel:
            continue
        candidate = (REPO_ROOT / rel).resolve()
        if candidate.is_file():
            executed_roots.add(candidate)
    executed_files = reachable_from_roots(executed_roots)

    unattached: list[tuple[str, str, bool]] = []
    for artifact_name, run_names in runs_by_artifact.items():
        if any(r in reached for r in run_names):
            continue  # some Run artifact for this binary does execute
        rel = test_bindings.get(artifact_name)
        root = (REPO_ROOT / rel).resolve() if rel else None
        if root is not None and root in executed_files:
            continue  # this file's test blocks run inside another binary
        unattached.append(
            (
                run_names[0],
                artifact_name,
                any(r in attached_anywhere for r in run_names),
            )
        )
    return unattached


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
    unattached = find_unattached_run_artifacts()

    if not args.quiet:
        print(f"lint_test_wiring: {len(test_bearing)} test-bearing file(s) found")
        print(f"lint_test_wiring: {len(roots)} addTest root(s) in build.zig")
        print(f"lint_test_wiring: {len(reachable)} file(s) reachable from a root")
        print()

    known = [t for t in unattached if t[1] in KNOWN_UNATTACHED]
    unattached = [t for t in unattached if t[1] not in KNOWN_UNATTACHED]

    if known:
        for run_name, artifact_name, _ in known:
            print(
                f"  [KNOWN]      {run_name} (b.addRunArtifact({artifact_name})) "
                f"— tracked by {KNOWN_UNATTACHED[artifact_name]}"
            )
            print(
                "               not reachable from an aggregate step; fails on "
                "first execution, so attaching it requires fixing that first"
            )
        print()

    if unattached:
        for run_name, artifact_name, attached_somewhere in unattached:
            print(f"  [UNATTACHED] {run_name} (b.addRunArtifact({artifact_name}))")
            if attached_somewhere:
                print(
                    "               attached only to a narrow step that no "
                    "aggregate step reaches — never runs under "
                    f"{' / '.join(AGGREGATE_STEP_NAMES)}"
                )
            else:
                print(
                    "               wraps an addTest artifact but no build step "
                    "depends on it — it is built and never executed"
                )
        print()
        print(
            f"lint_test_wiring: FAIL — {len(unattached)} test Run artifact(s) "
            "not reachable from an aggregate build step"
        )
        print(
            "  Fix: add `<step>.dependOn(&<run_name>.step);` for a step that an "
            "aggregate step reaches (usually test_integration_others_step, the "
            "barrier reachable from `zig build test-integration`). A narrow "
            "opt-in step alone is not enough: if nothing invokes it, the tests "
            "never run — see ISS-0150 / GH #466."
        )
        return 1

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
        "reachable from an addTest root, and every test Run artifact is "
        "attached to a build step"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
