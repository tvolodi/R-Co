"""Shared body for retired queue/claim tool shims.

These tools wrote to a git-committed JSON file (handoffs/global_queue.json or
handoffs/batch_queue.json) as a cross-workspace lock. That approach has no
compare-and-swap and produced repeated real double-claim incidents
(GH-542, GH-518, GH-526 — see docs/anti-patterns.md), most recently the
GH-752/GH-758 duplicate-work incident on 2026-08-13 that motivated replacing
it entirely with TaskManager (external SQLite DB, atomic BEGIN IMMEDIATE
claims). See docs/agents/protocols/LOOP_PROTOCOL.md.

Original tool bodies are preserved as tools/<name>.py.retired-2026-08-13 for
reference — not deleted, since they document real incident-response history
that anti-patterns.md and this repo's commit log still reference.
"""
import sys


def die(retired_name: str, replacement: str) -> int:
    print(
        f"error: tools/{retired_name} is retired (2026-08-13).\n"
        f"\n"
        f"This tool wrote to a git-committed JSON file as a cross-workspace lock,\n"
        f"which has no compare-and-swap and produced real double-claim incidents\n"
        f"(GH-542, GH-518, GH-526, GH-752/GH-758 — see docs/anti-patterns.md).\n"
        f"\n"
        f"Use instead:\n"
        f"  {replacement}\n"
        f"\n"
        f"See docs/agents/protocols/LOOP_PROTOCOL.md for the full picture.\n"
        f"The original implementation is preserved for reference at\n"
        f"tools/{retired_name}.retired-2026-08-13 — do not resurrect it as a call site.",
        file=sys.stderr,
    )
    return 1
