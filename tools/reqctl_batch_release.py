#!/usr/bin/env python3
"""RETIRED 2026-08-13 — see tools/_retired_claim_tool.py and LOOP_PROTOCOL.md."""
import sys

from _retired_claim_tool import die

if __name__ == "__main__":
    sys.exit(die(
        "reqctl_batch_release.py",
        r'python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\release.py" <workspace_id> task/current.json --status DONE',
    ))
