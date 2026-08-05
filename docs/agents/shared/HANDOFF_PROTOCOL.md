# Shared Protocol — Handoff Lifecycle

**Audience:** every agent in the BPM Platform pipeline, under every harness (Claude Code, GitHub Copilot).
**Status:** AUTHORITATIVE. Where an agent-specific file disagrees with this document about handoff mechanics, **this document wins** — report the discrepancy in your handoff `result.issues` with severity MINOR so it gets fixed at the source.

This file exists because the handoff lifecycle is identical for all agents, and stating it once prevents the drift measured by the 2026-08-05 pipeline audit: the same rule written in three layers, diverging silently until agents followed contradictory instructions.

---

## 1. Claim your handoff

At session start, find the handoff addressed to you:

```
handoffs/<RUN-ID>/step-*.json  where  to_agent == "<YOUR_AGENT_ID>"  and  status == "PENDING"
```

```bash
grep -rl '"to_agent": "<YOUR_AGENT_ID>"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Then:

1. Read the file, plus **every** artefact listed in `context.artifacts_in`.
2. Set `status` to `IN_PROGRESS`.
3. **Do NOT set `started_at`.** ORCH stamps it immediately before dispatching you. Writing it yourself produces a `started_at` later than your own dispatch — one of the corruption modes behind the 31 handoffs whose `started_at` precedes their `created_at`.

If no PENDING handoff exists: report that to the user and wait. Do not invent work.

---

## 2. Read and write handoff JSON safely

**Always read with `utf-8-sig`. Always write with `utf-8`.**

```python
import json

with open(path, encoding="utf-8-sig") as f:      # tolerates BOM and plain UTF-8 alike
    handoff = json.load(f)

with open(path, "w", encoding="utf-8") as f:     # never emits a BOM
    json.dump(handoff, f, indent=2)
```

88 handoff files in this repo carry a UTF-8 BOM. A bare `json.load(open(path))` raises `UnicodeDecodeError` on every one, making those handoffs invisible to whoever reads them — a bug that was present in the orchestrator's own registry snippet.

**Never hand-edit handoff JSON in a text editor.** 11 files in this repo are unparseable (bad escapes, trailing commas, raw control bytes) and 9 store `result` as a JSON *string* instead of an object, so `h["result"]["status"]` raises `TypeError`. Both are signatures of manual editing. Use the Python form above.

---

## 3. Timestamps come from the clock — never from memory

Session context is not a clock. Before writing any timestamp, run this and paste its exact output:

```bash
python3 tools/utcnow.py          # 2026-08-05T06:25:12Z
```

**Use that tool rather than an inline one-liner.** The rule here was never ambiguous, and it still produced 149 handoffs whose `completed_at` precedes their `started_at` — because the near-miss variants are visually identical in their output:

| Command | Output | |
|---|---|---|
| `(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")` | `06:25:12Z` | correct |
| `(Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")` | `11:25:12Z` | **local time labelled Z** |
| `datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")` | `11:25:12Z` | **local time labelled Z** |

Drop one method call and you get local time wearing a UTC suffix. Nothing in the string says which one you ran. On a host at UTC+5 every stamp is silently five hours ahead, and when ORCH and its subagents resolve the clock differently *within one run*, durations go negative.

This is not hypothetical: repo-wide, the inversions cluster at whole-hour offsets (4h ×27, 5h ×18, 11h ×25) — the signature of timezone drift, not of invented values. `tools/lint_handoffs.py` reports these as **H013**, distinct from H003, because the fix is to change your *command*, not your data.

Check a suspicious stamp:
```bash
python3 tools/utcnow.py --check 2026-08-05T10:49:05Z   # exit 1 if it is not plausibly now
python3 tools/utcnow.py --offset                        # report this host's UTC offset
```

Rules:

| Field | Who writes it | When |
|---|---|---|
| `created_at` | ORCH | at handoff creation |
| `started_at` | **ORCH only** | immediately before dispatch |
| `completed_at` | you | when you complete the handoff |

`completed_at` must never precede `started_at`. **148 handoffs currently violate this** — one by 30 hours — which silently corrupts every retrospective and estimation variance computed from step durations.

---

## 4. Complete the handoff

If your handoff's `task.functions_to_call` lists `fn:` calls, the completion chain is mandatory and ordered:

```
fn:validate-completeness → fn:register-inner-report → fn:complete-handoff
```

Calling `fn:complete-handoff` without `fn:register-inner-report` is a workflow violation. See `docs/agents/FUNCTIONS.md`.

Write your result:

```python
handoff["status"] = "COMPLETED"          # or "FAILED"
handoff["result"] = {
    "status": "PASS",                    # see legal values below
    "summary": "<what you did, one or two sentences>",
    "artifacts_out": ["path/to/file", ...],
    "issues": [],                        # {severity, description} — severity: BLOCKER|MAJOR|MINOR
    "next_action": "Route to <AGENT> (Step <N>)",
}
handoff["completed_at"] = "<exact output of the shell command in §3>"
```

Then update the matching entry's `status` in `handoffs/registry.json`.

**Legal `result.status` values — no others:**

| Value | Meaning |
|---|---|
| `PASS` | Work complete, acceptance criteria met |
| `FAIL` | Work attempted, acceptance criteria not met |
| `PARTIAL` | Some criteria met; remainder blocked and listed in `issues` |
| `BLOCKED` | Could not start or continue; blocker named in `issues` |
| `SKIPPED` | Step not applicable to this run (state why in `summary`) |

Values like `FAILED`, `PARTIAL_PASS`, or `CONDITIONAL` are **not** legal and will fail the lint gate in §5.

---

## 5. Verify before you complete — mandatory

```bash
python3 tools/lint_handoffs.py     # must exit 0
```

This is a hard gate, in the same sense that `zig build` exiting 0 is a hard gate. It checks:

| Code | Catches |
|---|---|
| H001 | Handoff file is not parseable JSON |
| H002 | `result` stored as a string instead of an object |
| H003 | `completed_at` earlier than `started_at` |
| H004 | `started_at` earlier than `created_at` |
| H005 | `COMPLETED` without `completed_at` |
| H006 | `result.status` outside the legal set in §4 |
| H007 | Required schema key missing |
| H008 | UTF-8 BOM (invisible to a bare `json.load`) |
| H009 | Step left open while the run advanced past it |
| H010 | Handoff absent from `registry.json` |
| H011 | UTF-16 corruption in `orchestrator.log` |
| H012 | `orchestrator.log` shorter than its committed version |

If it reports a BLOCKER against a file you touched, fix it before completing.

---

## 6. The audit trail is append-only

`handoffs/orchestrator.log` and `handoffs/registry.json` record what the pipeline did and why. **They must never shrink.**

- Open the log with mode `"a"` — **never** `"w"`. Never regenerate it wholesale.
- On Windows, **never** append with PowerShell `>>`: it writes UTF-16 into a UTF-8 file. (`  R O U T E  ` appears 17 times in the historical log from exactly this.) Use `Out-File -Encoding utf8 -Append`, or the Python form:

```python
with open("handoffs/orchestrator.log", "a", encoding="utf-8") as f:
    f.write(f"{ts} | {event} | {run_id} | {handoff_id[:8]} | {agent} | {detail}\n")
```

This is not hypothetical. On 2026-08-04 commit `ba8f3b9` cut `orchestrator.log` from **1357 lines to 17**, and `db362fd` cut `registry.json` from **714 entries to 4**. Both reached `main` through a squash-merge unchallenged and were recoverable only from git blobs.

A commit that shrinks either file is a defect, not a cleanup.

---

## 7. Never satisfy a gate by editing what it measures

If a gate blocks you, fix the condition it detects. **Never make the detector stop reporting.**

Forbidden regardless of how the task is phrased:

- Renaming or reformatting output tokens so a string-matching gate stops matching.
- Deleting, defaulting, or making unreachable an error path a gate looks for.
- Redirecting diagnostic output away from where the gate reads it.
- Wrapping a failing command so its exit code or output is masked.

This already happened here. ORCH's benchmark pre-check greps `zig build bench` output for `BPM_DB_URL` / `BENCHMARK_SETUP_ERROR` / `missing`. On 2026-05-30 an ADHOC task was phrased as *"no BPM_DB_URL/missing/BENCHMARK_SETUP_ERROR token in head output"*, and the agent complied by renaming the labels rather than fixing the environment. `resolveDbUrl` later gained a hardcoded fallback that made its `MissingDbUrl` error unreachable — so the benchmark can no longer report a missing DB URL at all. Nine ADHOC runs chased that symptom; none fixed the cause.

**If a gate is wrong, escalate to change the gate's definition** — do not quietly satisfy it.

---

## 8. Workspace hygiene

- Pre-existing unrelated uncommitted changes are **expected context, not a blocker.** Continue, and keep your edits scoped to your handoff's targets. Stop only for true file overlap on your targets, or a blocker that prevents acceptance criteria.
- Do not spend tokens reporting unrelated pre-existing changes.
- Commit workflow artefacts you create or modify (`handoffs/`, `docs/issue-reports/`, `docs/issues/`, `src/design/`) before completing — they are the project's audit trail.
- Scratch files — one-off scripts, debug dumps, `.log`/`.tmp`/`.exe`/`.pdb` — go in `scratch/` (git-ignored). Never in the project root or any tracked directory.
