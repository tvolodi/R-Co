#!/usr/bin/env python3
"""
gh_claim.py — claim the newest open GitHub issue not currently being processed.

SOURCE OF TRUTH: https://github.com/tvolodi/R-Co/issues  (open issues, sorted newest first,
                 EXCLUDING label:requirement — see tools/reqctl_batch_claim.py for those)
LOCK REGISTRY:   handoffs/global_queue.json               (IN_PROGRESS items = locked)

The lock registry is NOT a backlog — it only records what is currently being worked on.
When an issue is resolved, its lock entry stays in the file as audit history.

Exit codes:
  0 — item claimed; JSON of the claimed item printed to stdout
  2 — no claimable issues (all open GitHub issues are locked, or GitHub reports 0 open)
  3 — every open issue is actively locked by another workspace (try again later)
  1 — unexpected error (gh CLI unavailable, JSON parse failure, etc.)

Usage:
  python3 tools/gh_claim.py [<workspace_id>]

  <workspace_id> defaults to "<hostname>-<pid>" when omitted.
  For loop mode, pass BPM_WORKSPACE_ID from .env instead (see .env.example) — do NOT use
  machine name alone. Two parallel checkouts of this repo on the same host share the same
  hostname, so a hostname-derived workspace_id collides across workspaces and lets two of
  them claim the same GitHub issue under an identical lock key (2026-08-07 GH-542 incident,
  see docs/anti-patterns.md). BPM_WORKSPACE_ID is set by hand per checkout and is guaranteed
  distinct.

Printed JSON on exit 0:
  {
    "issue_id":     "GH-533",
    "issue_number": 533,
    "github_issue": "https://github.com/tvolodi/R-Co/issues/533",
    "title":        "...",
    "severity":     "MAJOR",
    "labels":       [...],
    "status":       "IN_PROGRESS",
    "lock":         {"workspace_id": "...", "locked_at": "..."},
    "locked_at":    "..."
  }

ORCH loop:
  exit 0 → run full WF-03 for this item, then call queue_release.py GH-NNN <workspace>
  exit 2 → stop the loop (no open GitHub issues remain)
  exit 3 → stop or retry after a delay (everything is locked by other workspaces)

*** THIS SCRIPT ONLY WRITES THE LOCAL global_queue.json FILE. IT DOES NOT COMMIT OR
*** PUSH TO GIT. The lock is invisible to other workspaces until the caller commits
*** and pushes handoffs/global_queue.json to origin/main. The caller MUST do that
*** immediately after a successful (exit 0) claim, BEFORE starting any WF-03 work —
*** see docs/agents/protocols/LOOP_PROTOCOL.md "ORCH loop mode — step by step".
*** Deferring that push to end-of-run (alongside queue_release.py) leaves a window
*** where a second workspace reads a stale, still-unlocked main and claims the same
*** issue. This exact race let two workspaces both claim GH-542 on 2026-08-07 —
*** see docs/anti-patterns.md.
"""

import datetime
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _queue_sync import sync_queue_from_origin  # noqa: E402

QUEUE_FILE  = "handoffs/global_queue.json"
LOCK_FILE   = "handoffs/global_queue.lock"
REPO        = "tvolodi/R-Co"
TTL_MINUTES = 120   # stale-lock expiry


# ── helpers ──────────────────────────────────────────────────────────────────


def _utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _lock_expired(locked_at: str) -> bool:
    try:
        t = (
            datetime.datetime
            .strptime(locked_at, "%Y-%m-%dT%H:%M:%SZ")
            .replace(tzinfo=datetime.timezone.utc)
        )
        return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60 > TTL_MINUTES
    except Exception:
        return True  # unparseable → treat as expired


def _acquire_file_mutex(owner: str) -> bool:
    """Atomically create the file-level mutex. Returns True if acquired."""
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            json.dump({"owner": owner, "at": _utcnow()}, f)
        return True
    except FileExistsError:
        try:
            with open(LOCK_FILE, encoding="utf-8-sig") as f:
                data = json.load(f)
            if _lock_expired(data.get("at", "")):
                os.remove(LOCK_FILE)
                return _acquire_file_mutex(owner)
        except Exception:
            pass
        return False


def _release_file_mutex() -> None:
    try:
        os.remove(LOCK_FILE)
    except FileNotFoundError:
        pass


def _read_queue() -> dict:
    if not os.path.exists(QUEUE_FILE):
        return {"version": "1", "items": []}
    with open(QUEUE_FILE, encoding="utf-8-sig") as f:
        return json.load(f)


def _write_queue(data: dict) -> None:
    with open(QUEUE_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


REQUIREMENT_LABEL = "requirement"


def _fetch_open_issues() -> list:
    """Return all open GitHub issues sorted newest first (highest number first),
    excluding anything labeled 'requirement'.

    Requirement-labeled issues (166 as of 2026-08-07) are handled exclusively
    by the requirement-batch loop (reqctl_batch_claim.py / LOOP_PROTOCOL.md
    "Requirement batch loop mode"), which drains them via WF-02 (Requirement
    Implementation) in dependency order from docs/requirements.yaml. This
    loop runs WF-03 (Issue Resolving), the wrong workflow for a from-scratch,
    never-implemented requirement — ORCHESTRATOR.md's own rule is "if the
    feature has not been specified yet -> WF-02." Before this filter existed,
    gh_claim.py's newest-number-first ordering meant issue #331 (BRW-SEC-1,
    the single highest-numbered open issue at the time) would have been the
    very next thing claimed by a plain "start loop" run, sending a
    from-scratch requirement through the wrong pipeline. See
    docs/anti-patterns.md.
    """
    result = subprocess.run(
        [
            "gh", "issue", "list",
            "--repo", REPO,
            "--state", "open",
            "--limit", "500",
            "--json", "number,title,labels,createdAt,url",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh issue list failed:\n{result.stderr.strip()}")
    issues = json.loads(result.stdout)
    issues = [
        i for i in issues
        if REQUIREMENT_LABEL not in {lbl["name"] for lbl in i.get("labels", [])}
    ]
    issues.sort(key=lambda x: x["number"], reverse=True)  # newest = highest number
    return issues


_RESOLVED_STATUSES = {"RESOLVED", "RESOLVED-WITH-INFRA-BLOCK"}


def _already_resolved_locally(github_issue_url: str) -> str | None:
    """Return a short reason string if a local docs/issues/ISS-*.json already
    marks this GitHub issue RESOLVED, else None.

    Discovered 2026-08-07: an issue can be fixed and merged to main (by any
    workspace) without ever being closed on GitHub — closing the GitHub issue
    and merging the fix are two separate actions, and nothing enforces they
    happen together. gh_claim.py's source of truth is GitHub's open/closed
    state, so a still-open-but-already-fixed issue gets claimed and worked a
    second time. This happened twice in one session (GH-545, GH-548) before
    being caught. ISSUE-FIXER's Step 0.5 registry lookup already detects this
    correctly ONCE A RUN HAS ALREADY BEEN STARTED — checking here, before
    claiming, avoids spending Step 00 (branch creation) and Step 0.5 time on
    a run that will just discover the same thing a few minutes later, and
    matters more for a design/implementation run that (per GH-548) can drift
    past the "already resolved" signal instead of stopping on it.
    """
    issues_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "issues")
    if not os.path.isdir(issues_dir):
        return None
    for name in os.listdir(issues_dir):
        if not name.startswith("ISS-") or not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(issues_dir, name), encoding="utf-8-sig") as f:
                iss = json.load(f)
        except Exception:
            continue
        if iss.get("github_issue") != github_issue_url:
            continue
        status = iss.get("status")
        if status in _RESOLVED_STATUSES:
            return f"{name} status={status!r}"
    return None


def _infer_severity(issue: dict) -> str:
    """Map GitHub labels to BLOCKER / MAJOR / MINOR. Defaults to MAJOR."""
    names = {lbl["name"].lower() for lbl in issue.get("labels", [])}
    if names & {"blocker", "critical", "severity: blocker", "severity:blocker"}:
        return "BLOCKER"
    if names & {"major", "bug", "severity: major", "severity:major"}:
        return "MAJOR"
    if names & {"minor", "severity: minor", "severity:minor"}:
        return "MINOR"
    return "MAJOR"


# ── main ─────────────────────────────────────────────────────────────────────


def main() -> int:
    workspace_id = sys.argv[1] if len(sys.argv) > 1 else f"{socket.gethostname()}-{os.getpid()}"

    # Retry acquiring the file mutex (another workspace may be mid-write)
    for attempt in range(5):
        if _acquire_file_mutex(workspace_id):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        # Read current lock registry. Sync against origin/main first — the
        # local file mutex only protects two processes on this machine; it
        # says nothing about another workspace's already-pushed claim that
        # this local checkout hasn't pulled yet. See _queue_sync.py.
        queue = sync_queue_from_origin(_read_queue())

        # Build set of GitHub URLs currently locked (and not stale).
        # A workspace still actively working an item can extend its lock's
        # life past TTL_MINUTES by calling queue_heartbeat.py periodically
        # (see that tool's docstring — this closes the gap where a lock aged
        # out by wall-clock alone while the claimant was still genuinely
        # working, observed 2026-08-07 on GH-526). heartbeat_at, when
        # present, is checked instead of locked_at; a lock that has never
        # been heartbeated falls back to locked_at exactly as before.
        active_locks: set[str] = set()
        for item in queue["items"]:
            if item.get("status") != "IN_PROGRESS":
                continue
            lock = item.get("lock") or {}
            freshness_ts = lock.get("heartbeat_at") or lock.get("locked_at", "")
            if not _lock_expired(freshness_ts):
                active_locks.add(item["github_issue"])

        # Fetch all open GitHub issues
        try:
            open_issues = _fetch_open_issues()
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1

        if not open_issues:
            return 2  # GitHub reports 0 open issues — loop is done

        # Walk newest-first; find first unclaimed, not-already-resolved issue
        any_actively_locked = False
        for issue in open_issues:
            url = issue["url"]
            if url in active_locks:
                any_actively_locked = True
                continue  # another workspace owns this

            resolved_reason = _already_resolved_locally(url)
            if resolved_reason:
                print(
                    f"[gh_claim] skipping {url} — already resolved locally ({resolved_reason}); "
                    "the fix landed on main but the GitHub issue was never closed. "
                    "Consider running: gh issue close <number> --comment '...'",
                    file=sys.stderr,
                )
                continue
            now = _utcnow()
            severity = _infer_severity(issue)
            issue_id = f"GH-{issue['number']}"

            claimed_item = {
                "issue_id":     issue_id,
                "issue_number": issue["number"],
                "github_issue": url,
                "title":        issue["title"],
                "severity":     severity,
                "labels":       [lbl["name"] for lbl in issue.get("labels", [])],
                "status":       "IN_PROGRESS",
                "lock":         {"workspace_id": workspace_id, "locked_at": now},
                "added_at":     now,
                "started_at":   now,
                "completed_at": None,
                "run_id":       None,
                "deferred_reason": None,
            }

            # Update existing entry (if any) or append
            existing = next(
                (i for i in queue["items"] if i.get("github_issue") == url),
                None,
            )
            if existing is not None:
                existing.update(claimed_item)
            else:
                queue["items"].append(claimed_item)

            _write_queue(queue)
            print(json.dumps(claimed_item, indent=2))
            return 0

        # Reached here: no issue was claimable. Distinguish WHY for the caller:
        # "everything is being worked by someone else" (retry later, exit 3)
        # vs. "nothing left to do" (every open issue was either locked or
        # already resolved-but-unclosed — either way, stop the loop, exit 2).
        if any_actively_locked:
            print("All open GitHub issues are locked by other workspaces.", file=sys.stderr)
            return 3

        return 2  # nothing claimable (none open, or all already resolved)

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    finally:
        _release_file_mutex()


if __name__ == "__main__":
    sys.exit(main())
