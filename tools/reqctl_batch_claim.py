#!/usr/bin/env python3
"""RETIRED 2026-08-13 — see tools/_retired_claim_tool.py and LOOP_PROTOCOL.md."""
import sys

from _retired_claim_tool import die

if __name__ == "__main__":
    sys.exit(die(
        "reqctl_batch_claim.py",
        r'python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\claim.py" r-co <workspace_id> task/current.json'
        "\n  (requirement batches are now mirrored into the same work_items table as GitHub"
        "\n  issues — see requirements_pull.py to (re)populate them from docs/requirements.yaml)",
    ))
