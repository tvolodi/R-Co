#!/usr/bin/env python3
"""RETIRED 2026-08-13 — see tools/_retired_claim_tool.py and LOOP_PROTOCOL.md.

Already superseded once before, by gh_claim.py — this file was the original
backlog-based (not GitHub-based) claim tool from before the v2 protocol.
"""
import sys

from _retired_claim_tool import die

if __name__ == "__main__":
    sys.exit(die(
        "queue_claim.py",
        r'python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\claim.py" r-co <workspace_id> task/current.json',
    ))
