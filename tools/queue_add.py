#!/usr/bin/env python3
"""RETIRED 2026-08-13 — see tools/_retired_claim_tool.py and LOOP_PROTOCOL.md."""
import sys

from _retired_claim_tool import die

if __name__ == "__main__":
    sys.exit(die(
        "queue_add.py",
        "nothing — filing the GitHub issue (gh issue create) is now the whole forward.\n"
        "  TaskManager's github_pull.py mirrors it into claimable work automatically:\n"
        r'  python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\github_pull.py" r-co --exclude-label requirement',
    ))
