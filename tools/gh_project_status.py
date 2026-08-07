#!/usr/bin/env python3
"""
gh_project_status.py — move a GitHub issue's card in the "R-Co system" project board.

PURPOSE: give the maintainer a single board to read pipeline state from, instead of
having to open agent chats or issue bodies to find out what's being worked on.

Project: https://github.com/users/tvolodi/projects/3 ("R-Co system")
Status field options (fixed, do not rename in the UI without updating STATUS_OPTIONS below):
  Todo -> In Progress -> Implemented -> Validated by UAT agent -> Done
  (Implemented -> Done directly is valid for non-UAT-scoped issues; see --target below.)

State machine (see docs/agents/protocols/ISSUE_QUEUE.md for the authoritative version):
  claim (Step 00)              Todo               -> In Progress
  WF-03 Step Final, non-UAT    In Progress         -> Implemented -> Done   (--target done)
  WF-03 Step Final, UAT-scoped In Progress         -> Implemented          (--target implemented)
  UAT-RUNNER validates it      Implemented         -> Validated by UAT agent -> Done

Usage:
  python3 tools/gh_project_status.py <issue-number> --target <in_progress|implemented|validated|done>

Exit codes:
  0 — moved (or already at/past the target status — idempotent, safe to call unconditionally)
  1 — error (gh CLI failure, issue not found, field/option lookup failure)

Notes:
  - Adding an issue to the project is idempotent: `gh project item-add` returns the
    existing item if the issue is already on the board.
  - Current status is read cheaply via `gh issue view --json projectItems` (one
    GraphQL node), NOT `gh project item-list` (which pages the whole ~300+ item
    board and is expensive enough to hit rate limits when called once per WF-03 step
    across many runs). Field/option IDs come from `gh project field-list`, called
    once per invocation — a renamed Status option is picked up automatically and
    fails loud (exit 1) rather than silently mis-filing.
"""

import json
import subprocess
import sys

OWNER = "tvolodi"
REPO = "tvolodi/R-Co"
PROJECT_NUMBER = "3"

# canonical Status option names, keyed by the --target values this script accepts
STATUS_OPTIONS = {
    "todo": "Todo",
    "in_progress": "In Progress",
    "implemented": "Implemented",
    "validated": "Validated by UAT agent",
    "done": "Done",
}

# ordering, so "already past target" can be detected and treated as success
STATUS_ORDER = ["Todo", "In Progress", "Implemented", "Validated by UAT agent", "Done"]


def _run(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{result.stderr}")
    return result.stdout


def _get_status_field():
    out = _run(["gh", "project", "field-list", PROJECT_NUMBER, "--owner", OWNER, "--format", "json"])
    data = json.loads(out)
    for f in data["fields"]:
        if f.get("name") == "Status":
            return f
    raise RuntimeError("Status field not found on project 3")


def _verify_is_issue(issue_number: int) -> None:
    """Guard against the PR/issue shared-number-space trap: gh issue view <N> will
    happily resolve N to a pull request if no issue N exists, and item-add would then
    silently move the wrong board card. Fail loud instead."""
    out = _run(["gh", "api", f"repos/{REPO}/issues/{issue_number}", "--jq", "{pull_request: (.pull_request != null)}"])
    if json.loads(out).get("pull_request"):
        raise RuntimeError(
            f"#{issue_number} is a pull request, not an issue (GitHub issue/PR numbers "
            f"share one sequence — an ISS-NNNN suffix does NOT imply the GitHub issue "
            f"number equals NNNN; look up github_issue in the ISS-NNNN.json file instead)"
        )


def _add_item(issue_number: int) -> str:
    _verify_is_issue(issue_number)
    url = f"https://github.com/{REPO}/issues/{issue_number}"
    out = _run(["gh", "project", "item-add", PROJECT_NUMBER, "--owner", OWNER, "--url", url, "--format", "json"])
    return json.loads(out)["id"]


def _current_status_name(issue_number: int) -> str | None:
    """Cheap per-issue lookup — avoids paging the ~300+ item board via item-list."""
    out = _run(["gh", "issue", "view", str(issue_number), "--json", "projectItems"])
    for pi in json.loads(out).get("projectItems", []):
        if pi.get("title") == "R-Co system":
            status = pi.get("status")
            return status.get("name") if status else None
    return None


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[2] != "--target":
        print(__doc__)
        return 1
    try:
        issue_number = int(sys.argv[1])
    except ValueError:
        print(f"error: '{sys.argv[1]}' is not a valid issue number")
        return 1
    target_key = sys.argv[3].lower()
    if target_key not in STATUS_OPTIONS:
        print(f"error: --target must be one of {list(STATUS_OPTIONS)}")
        return 1
    target_name = STATUS_OPTIONS[target_key]

    try:
        # Cheap check first: if the card is already on the board and at/past target,
        # skip the (expensive) field-list/item-add/item-edit calls entirely. This is
        # the common case — most calls in a WF-03 run are idempotent re-asserts.
        current = _current_status_name(issue_number)
        if current is not None and current in STATUS_ORDER and target_name in STATUS_ORDER:
            if STATUS_ORDER.index(current) >= STATUS_ORDER.index(target_name):
                print(f"OK — issue #{issue_number} already at '{current}' (target was '{target_name}'), no change")
                return 0

        item_id = _add_item(issue_number)  # idempotent; also re-checks PR/issue guard
        field = _get_status_field()
        option = next((o for o in field["options"] if o["name"] == target_name), None)
        if option is None:
            raise RuntimeError(f"Status option '{target_name}' not found on the board")
        project_id_out = _run(["gh", "project", "view", PROJECT_NUMBER, "--owner", OWNER, "--format", "json"])
        project_id = json.loads(project_id_out)["id"]

        _run([
            "gh", "project", "item-edit",
            "--id", item_id,
            "--project-id", project_id,
            "--field-id", field["id"],
            "--single-select-option-id", option["id"],
        ])
        print(f"OK — issue #{issue_number} moved to '{target_name}'")
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
