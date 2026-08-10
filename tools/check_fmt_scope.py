#!/usr/bin/env python3
"""check_fmt_scope.py — `zig fmt --check` scoped to the current change (PI-03 / GH-293).

Why this exists
----------------
`zig fmt --check .` run whole-tree reports 440 pre-existing unformatted files
as of this writing (225 under src/, 200 under tests/, plus build.zig,
build.zig.zon, vendor/, scratch/, and docs/exp701_doc_embed.zig) — none of
which are related to any particular change. Gating `zig build check` on the
whole tree would fail every single future PR on formatting debt it did not
create, which is not a fair or actionable signal, and is exactly the kind of
"gate fails for reasons unrelated to this change" outcome PI-04's `check`
interim stand-in deliberately avoided by dropping `zig fmt` entirely
(see git history / ISS-0079).

This script instead scopes `zig fmt --check` to only the `.zig` files the
current branch actually modified relative to `main` — the standard pattern
for introducing a formatting gate into a codebase with pre-existing debt:
fail loudly for what THIS change touches, without attributing debt someone
else created to whichever branch happens to run the gate. Pre-existing debt
is not silently blessed — see `docs/issues/ISS-0078.json` for the follow-up
note recommending a tracked, separately-scheduled whole-tree cleanup.

What this checks
-----------------
  1. Diff `.zig` files between `main` and the current worktree (staged,
     unstaged, and committed-but-unmerged changes are all included — anything
     that would land in the PR).
  2. Run `zig fmt --check <files>` against exactly that list.
  3. Exit 0 if the list is empty (nothing to check) or every file is already
     formatted. Exit 1 and print the offending files otherwise.

If `main` is unreachable (e.g. a shallow clone, or `origin/main` not fetched)
this falls back to comparing against `origin/main`, then gives up cleanly
with a clear message rather than silently checking nothing.
"""

from __future__ import annotations

import subprocess
import sys


def run(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def resolve_base_ref() -> str | None:
    """Find the best available ref to diff against: local main, then origin/main."""
    for ref in ("main", "origin/main"):
        code, _, _ = run(["git", "rev-parse", "--verify", "--quiet", ref])
        if code == 0:
            return ref
    return None


def changed_zig_files(base_ref: str) -> list[str]:
    """.zig files that differ between base_ref and the current worktree.

    Uses `git diff --name-only <base>...HEAD` (merge-base diff, the same
    triple-dot form used elsewhere in this repo's tooling) unioned with
    working-tree changes not yet committed, so a file edited but not yet
    committed on the feature branch is still caught before it is pushed.
    """
    files: set[str] = set()

    code, out, _ = run(["git", "diff", "--name-only", f"{base_ref}...HEAD", "--", "*.zig"])
    if code == 0:
        files.update(f.strip() for f in out.splitlines() if f.strip())

    # Uncommitted changes (staged + unstaged) against HEAD.
    code, out, _ = run(["git", "diff", "--name-only", "HEAD", "--", "*.zig"])
    if code == 0:
        files.update(f.strip() for f in out.splitlines() if f.strip())

    # Untracked new .zig files also belong to "this change".
    code, out, _ = run(["git", "ls-files", "--others", "--exclude-standard", "--", "*.zig"])
    if code == 0:
        files.update(f.strip() for f in out.splitlines() if f.strip())

    # Only files that still exist on disk (excludes deletions).
    import os

    return sorted(f for f in files if os.path.isfile(f))


def main() -> int:
    base_ref = resolve_base_ref()
    if base_ref is None:
        print(
            "check_fmt_scope: could not resolve 'main' or 'origin/main' to diff "
            "against — skipping scoped fmt check (nothing to compare against). "
            "This is not a pass; it means the check could not run. Fetch main "
            "and retry.",
            file=sys.stderr,
        )
        return 1

    files = changed_zig_files(base_ref)
    if not files:
        print(f"check_fmt_scope: no .zig files changed relative to {base_ref} — nothing to check.")
        return 0

    print(f"check_fmt_scope: checking {len(files)} changed .zig file(s) against {base_ref}:")
    for f in files:
        print(f"  {f}")

    code, out, err = run(["zig", "fmt", "--check", *files])
    if out.strip():
        print(out, end="")
    if err.strip():
        print(err, end="", file=sys.stderr)

    if code != 0:
        print(
            "check_fmt_scope: FAILED — the file(s) listed above are not "
            "`zig fmt`-formatted. Run `zig fmt <file>` on each and re-run "
            "`zig build check`.",
            file=sys.stderr,
        )
        return 1

    print("check_fmt_scope: PASSED — all changed .zig files are formatted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
