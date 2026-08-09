# Module: lint_handoffs.py Acknowledgment Baseline (ISS-0627 / GH #596, H003/H004/H005/H009 subset)

**Issue:** ISS-0627 / GH #596 (scoped-down subset, ISSUE-FIXER triage
2026-08-08, WF03-GH596-20260808 Step 1)
**Categories in scope:** H003 (148 BLOCKER), H004 (34 BLOCKER), H005
(5 BLOCKER), H009 (38 MAJOR) — 225 of ISS-0627's 292-finding remainder.
**Out of scope:** H013 (53), H001-structural (~4 files), H006-CONDITIONAL
(1), H007 (69/~10 files) — each its own distinct per-file or per-policy
judgment call per ISS-0627, tracked there for future runs. Does not touch
`tools/repair_handoff_bookkeeping.py`'s existing GH-594 scope (H002/H008/
H010/H006-partial/H001-encoding).

## Module purpose

`tools/lint_handoffs.py` currently has exactly two outcomes for a finding:
report it and count it toward the BLOCKER/MAJOR exit-code gate, forever, on
every full-corpus run. For H003/H004/H005/H009 that is wrong in a specific
way ISS-0627 already diagnosed: none of these 225 findings has a recoverable
correct value anywhere in the file that produced it. `completed_at` earlier
than `started_at` (H003), `started_at` earlier than `created_at` (H004), a
`COMPLETED` status with no `completed_at` (H005), and a PENDING/IN_PROGRESS
step the pipeline visibly ran past (H009) are not data-entry errors with a
knowable right answer sitting nearby — they are the historical fact of how
the work actually happened, 2026-05-22 through 2026-08-07, before the
bookkeeping directives that would have prevented them existed in enforced
form. "Fixing" any of them by writing a plausible timestamp or flipping a
status to `COMPLETED` would fabricate audit-trail evidence, which CLAUDE.md's
Bookkeeping section treats as strictly worse than an honestly flagged gap.

This module gives those 225 findings a third outcome: **permanently
acknowledged**. An acknowledged finding is not deleted, not silenced, not
removed from the tool's output — it is individually printed on every run,
under its own `[ACKNOWLEDGED]` label, with a dated, reasoned, attributable
record of who accepted it and why. It is excluded from exactly one thing:
the `counts['BLOCKER']`/`counts['MAJOR']` sum that decides `main()`'s exit
code. This is the same shape as `tools/lint_test_wiring.py`'s
`KNOWN_UNATTACHED` ledger (a reported-but-non-gating 4th bucket) combined
with `tools/lint_test_isolation.baseline.json`'s content-keyed baseline file
(for volume — 225 entries is too many for an in-source dict literal, the
scale `tools/lint_test_isolation.py`'s baseline-file approach already exists
to handle).

This is Type E per `templates/lego-catalog.md` — cross-cutting tooling
change to a linter, not a CRUD/migration/list-page/React-Flow-node shape.
Like `src/design/iss0626-handoff-bookkeeping-repair.md` (the sibling GH-594
design), the module is Python tooling, so its "public interface" (§5) is
CLI flags and function signatures, and its test specs (§8) follow the
`reqctl.py cmd_selftest` convention (plain `assert`-style checks against
synthetic fixtures, no pytest — no `tools/*.py` in this repo uses either).

---

## 0. The H009 collision question (resolved — NOT safe as message-text-only)

ISS-0627's diagnosis proposed the `severity|code|file|line|message` key
exactly as `tools/lint_test_isolation.py`'s `issue_key()` uses it, reasoning
that H003/H004/H005/H009's messages already embed the actual data values, so
a changed finding produces a changed message and therefore a changed key.
That reasoning holds for H003, H004, and H005 (§0.1) but **does not hold for
H009 as written** (§0.2) — this section states the actual risk, the exact
code read to confirm it, and the key-scheme change it requires.

### 0.1 Why H003/H004/H005 are safe under plain message-text matching

Read directly from `tools/lint_handoffs.py` `_lint_parsed_handoff`
(lines 128-199):

- H003: `f"completed_at ({completed}) is earlier than started_at ({started}). ..."`
  — both `completed` and `started` are the literal ISO-8601 strings from the
  file. Any change to either value (a real edit, a future re-write) changes
  the message. Two *different* files can coincidentally share a message only
  if both their `completed_at` and `started_at` values are byte-identical —
  but the key already includes `path`, so two different files never collide
  regardless. Two *different points in the same file's history* producing the
  same H003 message requires the same file to have the same `completed_at`
  and `started_at` pair both times, which is definitionally "the same
  finding," not a new one wearing an old finding's key.
- H004: same structure, `started`/`created` in place of `completed`/`started`.
- H005: `"status is COMPLETED but completed_at is unset."` — a fixed string
  with no embedded values at all. This looks like the weak case at first
  glance, but H005's *entire defect surface* is exactly two booleans
  (`status == "COMPLETED"` and `completed_at` falsy) — there is no third
  variable that could make "the same file, a genuinely different H005
  situation" a meaningful sentence. If `completed_at` later gets set to any
  non-empty value, H005 no longer fires at all (it drops out of the finding
  set entirely, not into a differently-worded H005). If `status` changes away
  from `COMPLETED`, likewise. There is no state transition that produces
  "still H005, but a different H005" — so message-only matching is safe for
  H005 not because the message is rich, but because the predicate is binary
  with only one true branch.

### 0.2 Why H009 is NOT safe under plain message-text matching

Read directly from `lint_orphans` (lines 232-254):

```python
later_completed = [
    other
    for other, oh in ordered[idx + 1 :]
    if oh.get("status") == "COMPLETED"
]
if later_completed:
    findings.append(Finding(
        "H009", "MAJOR", rel,
        f"status is {handoff.get('status')} but {len(later_completed)} "
        f"later step(s) in run {run_id} are COMPLETED — the pipeline "
        "advanced past a step it never closed.",
    ))
```

The message embeds `handoff.get('status')` (PENDING or IN_PROGRESS),
`len(later_completed)` (a **count**), and `run_id`. It does **not** embed
*which* later steps are COMPLETED — only how many. `path` (`rel`, the
orphaned file itself) is part of the outer `severity|code|path|message` key,
but neither `path` nor the message encodes `later_completed`'s membership.

**Concrete collision scenario**, confirmed possible in this repo's actual
history (not hypothetical): `git log --diff-filter=D --name-only -- 'handoffs/*/step-*.json'`
shows handoff step files have been deleted, added, and reorganized within
run directories across commits over the corpus's life (348 step-file
touches in history; multiple deletions confirmed, e.g. under
`ADHOC-WF02-exp201-202-infra/`, `ADHOC-bench-env-20260529/`, and others).
Given that a run directory's file membership is not immutable over time:

1. At baseline-generation time, orphan step `handoffs/WF02-x/step-02a-....json`
   has `status: PENDING`. Steps `03` and `04` in the same run are
   `COMPLETED`. `later_completed = [step-03-..., step-04-...]`, so the
   message reads `"status is PENDING but 2 later step(s) in run WF02-x are
   COMPLETED — the pipeline advanced past a step it never closed."` This
   exact string is recorded as a baseline entry for `step-02a-....json` /
   H009.
2. At some later point, step `03`'s file is removed from the run directory
   (renamed, reorganized, or corrected) and a *different* step `05` is added
   as `COMPLETED`, while `step-02a` itself is untouched (still `PENDING`).
   Now `later_completed = [step-04-..., step-05-...]` — a **different set**
   of bypassing steps — but the count is still `2`, `status` is still
   `PENDING`, and `run_id` is unchanged. **The message text is byte-for-byte
   identical to step 1's**, even though the actual later-completed steps
   that produced it are not the same steps.

This is a real, not merely theoretical, gap: `severity|code|path|message`
alone would silently match this new, distinct orphan situation against the
old baseline entry and acknowledge it without a human ever having reviewed
*this* combination of bypassing steps. That is exactly the kind of silent
gate-weakening CLAUDE.md's "Never Satisfy a Gate by Editing What It
Measures" directive exists to prevent — the risk here is not that anyone
edited the detector, but that the key scheme's blind spot could make a
brand-new finding invisible to the gate without anyone doing anything
resembling tampering.

**Resolution: H009's key must fold in the identity of `later_completed`,
not just its count.** The count is already inside the message string, so it
doesn't need duplicating; what's missing is the *membership*. §1.2 below
adds a `detail` component carrying a stable, sorted fingerprint of
`later_completed`'s file paths, present in the key for H009 only. H003/H004/
H005 do not need this component (§0.1) — adding it uniformly would just be
a no-op for those three codes, but keeping it H009-specific keeps the key
scheme legible: a reader can see exactly why H009 alone carries the extra
field, rather than wondering why an unused field exists everywhere.

---

## 1. Baseline record location and schema

### 1.1 Location: `tools/lint_handoffs.baseline.json` (tools/ sibling-file convention)

**Decision: `tools/` sibling file, matching `tools/lint_test_isolation.baseline.json`
and `tools/lint_test_tenant_provisioning.baseline.json` exactly — not
`docs/issues/`.**

Justification, made explicit as the handoff requires:

- **Consistency wins over conceptual proximity to ISS-0627.** Every other
  lint tool in this repo that ships a baseline keeps it as a same-directory
  sibling of the linter script (`lint_test_isolation.py` +
  `lint_test_isolation.baseline.json`; `lint_test_tenant_provisioning.py` +
  `lint_test_tenant_provisioning.baseline.json`). A third baseline file
  living in `docs/issues/` would be the one exception to an otherwise
  universal pattern, and the next engineer looking for "where does this
  linter's baseline live" would have to know to look in two different
  directories depending on which linter. `docs/issues/` is the right home
  for the *narrative* of ISS-0627 (already there, as `ISS-0627.json`) but the
  *machine-read, tool-consumed* baseline is operationally part of the
  linter, not part of the issue registry — `tools/lint_handoffs.py` needs to
  `open()` it on every run the same way the other two linters already do.
- **The issue file and the baseline file serve different readers.**
  `docs/issues/ISS-0627.json` is read by ISSUE-FIXER doing triage and by
  humans doing archaeology on why a category was deferred. The baseline file
  is read by `tools/lint_handoffs.py` itself, every run, and by
  `--no-baseline` auditors. Colocating it with the tool that reads it (not
  the issue that motivated it) is the same reasoning that already put
  `lint_test_isolation.baseline.json` next to `lint_test_isolation.py`
  rather than inside whatever issue first justified building it.
- **No concrete reason favors `docs/issues/` for this specific baseline.**
  The handoff invited finding one; none surfaced. `docs/issues/` entries are
  one-file-per-issue narrative records, not per-linter machine state, and
  225 keyed findings do not fit that shape any better than they fit
  `tools/`.

**File:** `tools/lint_handoffs.baseline.json`

### 1.2 Schema

Mirrors `tools/lint_test_isolation.baseline.json`'s header-provenance +
flat-array shape, with two additions: a `reason_ref` per entry (§1.3) and an
H009-only `detail` component inside the key material (§0.2).

```jsonc
{
  "version": 1,
  "generated_at": "<python tools/utcnow.py output — real clock, never invented>",
  "source": "tools/generate_lint_handoffs_baseline.py --apply",
  "regenerated_by": "WF03-GH596-20260808 (GitHub #596 / ISS-0627, H003/H004/H005/H009 permanent-acknowledgment subset)",
  "regeneration_note": "Initial generation: 225 entries (148 H003 + 34 H004 + 5 H005 + 38 H009), one per finding tools/lint_handoffs.py reported against the full corpus at generation time. See docs/issues/ISS-0627.json for the shared root-cause narrative this baseline's reason_ref values point to.",
  "reasons": {
    "H003": "ISS-0627 §H003: completed_at precedes started_at with no whole-hour-offset signature (that subset is H013, separately tracked). No field in the handoff file recovers the true value; any correction would be fabricated audit-trail data. Accepted as permanent historical record.",
    "H004": "ISS-0627 §H004: started_at precedes created_at. Same unrecoverable-history problem as H003, opposite field pair. Accepted as permanent historical record.",
    "H005": "ISS-0627 §H005: status is COMPLETED but completed_at was never set. No value to recover from any source in the file. Accepted as permanent historical record.",
    "H009": "ISS-0627 §H009: a PENDING/IN_PROGRESS step has later COMPLETED steps in the same run. Marking the orphaned step COMPLETED or FAILED after the fact would fabricate evidence the record does not show; this is a real historical process irregularity, not a data-entry error. Accepted as permanent historical record."
  },
  "issues": [
    {
      "file": "handoffs/WF02-.../step-03-backend-dev.json",
      "code": "H003",
      "matching_key": "BLOCKER|H003|handoffs/WF02-.../step-03-backend-dev.json|completed_at (2026-05-23T01:10:00Z) is earlier than started_at (2026-05-23T04:40:00Z). Timestamps must come from the shell clock, never from session context. This corrupts retrospective variance calculations.",
      "reason_ref": "H003",
      "acknowledged_at": "<python tools/utcnow.py output at generation time>",
      "acknowledged_by": "WF03-GH596-20260808 / tools/generate_lint_handoffs_baseline.py"
    },
    {
      "file": "handoffs/WF02-.../step-02a-....json",
      "code": "H009",
      "matching_key": "MAJOR|H009|handoffs/WF02-.../step-02a-....json|status is PENDING but 2 later step(s) in run WF02-... are COMPLETED — the pipeline advanced past a step it never closed.|later_completed:handoffs/WF02-.../step-03-....json,handoffs/WF02-.../step-04-....json",
      "reason_ref": "H009",
      "acknowledged_at": "<python tools/utcnow.py output at generation time>",
      "acknowledged_by": "WF03-GH596-20260808 / tools/generate_lint_handoffs_baseline.py"
    }
  ]
}
```

**Header provenance fields** (file-level, one set, matching
`lint_test_isolation.baseline.json`'s shape):
- `version` — schema version integer, `1` at initial generation.
- `generated_at` — real-clock timestamp of this file's most recent
  regeneration, from `python tools/utcnow.py`.
- `source` — the exact command used to regenerate this file (§2's
  generation script invocation).
- `regenerated_by` — which run/PR produced this version, human-readable,
  matching the `regenerated_by` convention in the existing baselines.
- `regeneration_note` — free text describing what changed in this
  regeneration and why, matching the existing convention.

**`reasons` — one shared reason string per finding code (decision: (a), not
per-entry free text).** Per the handoff's explicit instruction to justify
this choice rather than silently pick it:

All 225 entries reduce to exactly 4 root causes, and each root cause is
already fully written out in `ISS-0627.json`'s `symptom` field (H003:
"completed_at precedes started_at, NOT a whole-hour offset... No source in
the file recovers the true timestamp"; H004: "same unrecoverable-history
problem... opposite direction"; H005: "No value to recover from any source
in the file"; H009: "a real historical process irregularity, not a
data-entry error"). A per-entry free-text reason for, say, entry #87 of 148
H003 findings would either (i) restate the same sentence 148 times with the
file path swapped in — pure noise, since the *reason* genuinely does not
vary per entry, only the *finding* does, or (ii) invent a distinguishing
rationale per file that does not actually exist, which is the same kind of
fabrication-dressed-as-data problem this whole mechanism exists to avoid on
the *timestamp* side — inventing 148 distinct justifications for a defect
that has exactly one cause would be manufacturing spurious variety, not
genuine distinct reasoning.

CLAUDE.md's own anti-pattern warning (`Never Satisfy a Gate by Editing What
It Measures`) is about a gate being silently weakened by relabeling what it
detects — it is not a requirement that acknowledgment text be maximally
verbose per instance. A shared `reasons` map keyed by code, referenced by
each entry's `reason_ref`, keeps the actual content honest (it says exactly
as much as is true: "this code, for this root cause, is accepted") while
still making every one of the 225 entries individually addressable,
individually dated, and individually printed (§3) — the per-entry fields
that vary for real (`file`, `matching_key`, `acknowledged_at`) still vary
per entry; only the *reason prose*, which genuinely doesn't vary, is
deduplicated.

**If a future entry needs a genuinely distinct rationale** (e.g. a
newly-discovered H009 that a human reviews and accepts for a reason beyond
"same root cause as the rest of the batch"), the schema supports it without
migration: `reason_ref` may point to a code-level key in `reasons` (the
common case, all 225 initial entries) **or** be an inline string starting
with `"adhoc:"` for a one-off entry with its own text, checked first by the
loader (§4) before falling back to the `reasons` map lookup. This is
specified now so a future single-entry addition doesn't require a schema
version bump, but no such entry exists in the initial 225.

**Per-finding entry fields:**

| Field | Source | Notes |
|---|---|---|
| `file` | `Finding.path` (`rel`) | POSIX-style, matching `lint_test_isolation.baseline.json`'s `file` convention — not to be confused with any `handoff_id` field inside the target handoff's own payload. |
| `code` | `Finding.code` | One of `H003`/`H004`/`H005`/`H009`. |
| `matching_key` | Computed (§1.3) | The full string this entry matches against; stored explicitly (not reconstructed at match time from other fields) so the baseline file is self-describing and diffable — a human reading the JSON sees exactly what will be matched, not an implicit formula applied to other columns. |
| `reason_ref` | `"H003"` / `"H004"` / `"H005"` / `"H009"` (or `"adhoc:..."`) | Points into the header `reasons` map (§1.2). |
| `acknowledged_at` | `python tools/utcnow.py`, run once per generation batch | Real clock, never invented — every entry generated in the same run shares the same `acknowledged_at` value as `generated_at` (batch timestamp), which is honest: they were in fact all acknowledged in the same generation event, not at 225 independently-recorded moments. |
| `acknowledged_by` | `"<run_id> / tools/generate_lint_handoffs_baseline.py"` | The "who" — matches `regenerated_by`/`source`'s existing precedent of naming the run and the tool. |

### 1.3 The key-matching scheme, precisely

**For H003, H004, H005:**

```
matching_key = f"{severity}|{code}|{path}|{message}"
```

Identical in shape to `tools/lint_test_isolation.py`'s `issue_key()`, minus
the `line` component — H003/H004/H005/H009 findings are file-level (no line
number; `Finding` has no `line` field, only `path`), unlike
`lint_test_isolation.py`'s per-line `Issue`.

**For H009 only** (per §0.2's resolution):

```
matching_key = (
    f"{severity}|{code}|{path}|{message}"
    f"|later_completed:{','.join(sorted(later_completed_paths))}"
)
```

where `later_completed_paths` is the same list `lint_orphans` already
computes (`[other for other, oh in ordered[idx+1:] if oh.get("status") ==
"COMPLETED"]`) — the *paths*, not just the count, sorted for determinism
regardless of the input list's original order (which is already
step-sort-order, but sorting explicitly at key-construction time removes
any dependency on that incidental property holding forever).

### 1.4 Worked example — brand-new distinct finding does NOT match an old entry

**Setup:** baseline contains the H009 entry from §0.2 step 1:
`matching_key = "MAJOR|H009|handoffs/WF02-x/step-02a-....json|status is PENDING but 2 later step(s) in run WF02-x are COMPLETED — the pipeline advanced past a step it never closed.|later_completed:handoffs/WF02-x/step-03-....json,handoffs/WF02-x/step-04-....json"`

**New lint run**, after the corpus changes exactly as described in §0.2 step
2 (step `03` removed, step `05` added as COMPLETED, `step-02a` itself
untouched): `lint_orphans` computes `later_completed = [step-04-....json,
step-05-....json]` for the same orphan `step-02a-....json`. The message
text is unchanged (`"status is PENDING but 2 later step(s)... "` — same
count, same status, same run_id), so under `severity|code|path|message`
ALONE this would incorrectly match the baseline entry above. But this
design's H009 key appends the sorted `later_completed` paths:

```
new_matching_key = "MAJOR|H009|handoffs/WF02-x/step-02a-....json|status is PENDING but 2 later step(s) in run WF02-x are COMPLETED — the pipeline advanced past a step it never closed.|later_completed:handoffs/WF02-x/step-04-....json,handoffs/WF02-x/step-05-....json"
```

`new_matching_key != matching_key` (the trailing `later_completed:` segment
differs: `step-03...,step-04...` vs `step-04...,step-05...`) — **no
match**. The finding reports as a fresh, non-acknowledged H009 MAJOR, exactly
as it should, because the actual set of steps that bypassed `step-02a` has
changed and no human has reviewed *this* combination yet.

**Second worked example (H003, per the handoff's own suggested scenario):**
suppose a future fix edits `step-04-....json`'s `started_at` field to
correct an unrelated H004 on that same file, and the edit is made carelessly
enough that it also introduces a *new* H003 (`completed_at` now precedes the
corrected `started_at`, where it didn't before). The new H003 message embeds
the corrected `started_at` value, e.g. `"completed_at (2026-05-23T01:10:00Z)
is earlier than started_at (2026-05-23T09:00:00Z)..."` — a different
`started_at` string than whatever (if anything) was previously baselined for
that file+H003 (or, if this file had no prior H003 at all, there is simply
no baseline entry for it to collide with). Either way, `matching_key`
differs from every existing baseline entry for that `file`+`H003`
combination, so the new finding reports as BLOCKER, not ACKNOWLEDGED. This
confirms F from the handoff's acceptance criteria as a verified property,
not an assumption: message-text inclusion of the actual data values is what
makes a genuine edit visible, for H003/H004/H005 directly, and for H009 via
the added `later_completed` fingerprint component.

---

## 2. Generation mechanism — one-time reviewed script, reusing existing predicates

**Not 225 hand-typed entries.** `tools/generate_lint_handoffs_baseline.py`
(new file) is a one-time, reviewed script — parallel in spirit to
`tools/repair_handoff_bookkeeping.py`'s existence as a reviewed script for
GH-594's mechanical subset, though this script never modifies a handoff
file; it only ever writes `tools/lint_handoffs.baseline.json`.

### 2.1 Reuses `tools/lint_handoffs.py`'s own detection functions — does not reimplement

Per the handoff's explicit instruction and the same reasoning
`preexisting_file_finding_codes`/`preexisting_run_finding_codes` already
apply for `--changed` mode (reuse `_lint_parsed_handoff`/`lint_orphans`
rather than a second copy of the predicates, which is exactly the drift risk
those two functions already exist to avoid):

```python
# tools/generate_lint_handoffs_baseline.py
import sys
sys.path.insert(0, "tools")
from lint_handoffs import (
    read_handoff,
    _lint_parsed_handoff,
    lint_orphans,
    step_sort_key,
    Finding,
)
```

The script's own corpus walk mirrors `main()`'s exactly (same
`step-*.json` filename filter, same directory walk, same `runs` dict
construction keyed by `run_id`), then calls:

- `_lint_parsed_handoff(parsed, rel, findings)` per file — produces H003/
  H004/H005 (H001/H002/H006/H007/H008 findings are also produced by this
  call but are filtered out before baseline-writing, §2.3, since this
  script only ever emits H003/H004/H005/H009 entries).
- `lint_orphans(runs, findings)` once, after the full corpus is loaded —
  produces H009. The script additionally captures `later_completed`'s path
  list per H009 finding, which `lint_orphans` itself does not currently
  return (it only appends `Finding` objects to `findings`). §2.2 below
  specifies this without modifying `lint_orphans`'s signature.

### 2.2 Capturing H009's `later_completed` membership without changing `lint_orphans`'s signature

`lint_orphans` computes `later_completed` internally and discards it after
formatting the message. Rather than change `lint_orphans`'s signature (which
would touch `tools/lint_handoffs.py`'s own production code path, expanding
this design's footprint beyond "generate a baseline file"), the generation
script contains a **local, read-only copy of `lint_orphans`'s inner
loop-body logic** — not the predicate (`_lint_parsed_handoff`, which IS
reused, §2.1), but the orphan-walk shape, which is 8 lines of pure iteration
with no independent judgment calls to drift (`ordered = sorted(...)`,
`later_completed = [other for other, oh in ordered[idx+1:] if ...]`). This
is a narrower and lower-risk duplication than reimplementing a detection
*predicate* (which is what the handoff and `preexisting_file_finding_codes`
both warn against) — it is capturing an intermediate value the existing
function computes but does not expose, using the exact same expression.

To keep this honest rather than a silent fork that could drift from
`lint_orphans`'s real behavior over time, the generation script's own
`selftest` (§7) includes a differential check: run `lint_orphans` from
`tools/lint_handoffs.py` directly against a synthetic `runs` fixture,
separately run the generation script's local orphan-walk against the same
fixture, and assert the **messages** produced by both are byte-identical
(the generation script's copy must reproduce `lint_orphans`'s own output
exactly, proving it is not a divergent reimplementation, merely the same
computation with one extra piece — `later_completed`'s path list — captured
alongside).

### 2.3 What the script does NOT do

- Never writes to any `handoffs/**/step-*.json` file. Read-only over the
  corpus.
- Never invents a reason string per entry — every entry's `reason_ref`
  points at the shared `reasons` map (§1.2), which is written once by a
  human/CODE-DESIGNER reviewing this design, not generated per-entry by the
  script.
- Emits entries **only** for `H003`/`H004`/`H005`/`H009` — any other code
  `_lint_parsed_handoff` happens to also report (H001/H002/H006/H007/H008)
  on the same corpus walk is discarded before writing, since this baseline
  is scoped to exactly the 225-finding subset per the handoff's batch-cap
  discipline. (Those other codes are either already fixed by GH-594's
  `repair_handoff_bookkeeping.py`, or explicitly out of scope per ISS-0627,
  and must not silently gain acknowledgment entries as a side effect of this
  script's corpus walk touching the same files.)

### 2.4 CLI (illustrative signatures)

```
tools/generate_lint_handoffs_baseline.py [handoffs_dir] [--apply] [--out PATH]
```

| Flag | Meaning |
|---|---|
| `--apply` | Write `tools/lint_handoffs.baseline.json` (default: `--out`'s path). Without this flag: dry-run, prints the proposed before/after entry counts per code and the full JSON to stdout, writes nothing. |
| `--out PATH` | Override the output path (default: `tools/lint_handoffs.baseline.json`). |
| `--now ISO8601` | Timestamp for `generated_at`/`acknowledged_at`, REQUIRED with `--apply`. The script never calls the system clock itself — the invoking agent supplies `python3 tools/utcnow.py`'s output, matching `repair_handoff_bookkeeping.py`'s own `--now` convention (§6 of `iss0626-handoff-bookkeeping-repair.md`) and CLAUDE.md's timestamp-sourcing rule. |
| `--run-id STR` | Value recorded in `regenerated_by`/`acknowledged_by` (e.g. `"WF03-GH596-20260808"`). |

```python
def main(argv: list[str]) -> int: ...

def scan_h003_h004_h005(handoffs_dir: str) -> list[Finding]: ...
    # walks the corpus, calls _lint_parsed_handoff per file (imported from
    # lint_handoffs), filters to codes in {"H003", "H004", "H005"}

def scan_h009(runs: dict[str, list[tuple[str, dict]]]) -> list[tuple[Finding, list[str]]]: ...
    # returns (Finding, later_completed_paths) pairs; later_completed_paths
    # is the extra value captured per §2.2

def build_baseline_entries(
    findings: list[Finding],
    h009_pairs: list[tuple[Finding, list[str]]],
    now: str,
    run_id: str,
) -> list[dict]: ...
    # applies §1.3's matching_key formula per code, assembles each entry
    # per §1.2's field table

def render_baseline_file(entries: list[dict], now: str, source_cmd: str, run_id: str) -> dict: ...
    # assembles the full header + issues document per §1.2
```

**Exit codes:** `0` dry-run or `--apply` completed. `2` usage error
(`handoffs_dir` not found, `--apply` without `--now`).

---

## 3. `tools/lint_handoffs.py` full-corpus integration — the ACKNOWLEDGED bucket

### 3.1 Where baseline-matching happens in `main()`

Inserted after the existing `--changed`-mode `preexisting_*` filtering block
(after line 665's `findings = kept`, or immediately after `lint_orphans`/
`lint_clock_skew` are called when `--changed` is not active — see §5 for the
exact composition rule) and before the existing `findings.sort(...)` call:

```python
acknowledged: list[Finding] = []
if not args.no_baseline:
    baseline = load_lint_handoffs_baseline(args.baseline.resolve())
    if baseline:
        remaining: list[Finding] = []
        for f in findings:
            key = matching_key_for(f, later_completed_cache)  # §3.2
            if key in baseline:
                acknowledged.append(f)
                continue
            remaining.append(f)
        findings = remaining
```

`matching_key_for` computes exactly §1.3's formula: for H003/H004/H005,
`f"{f.severity}|{f.code}|{f.path}|{f.message}"`; for H009, the same string
plus the `|later_completed:...` suffix, which requires access to the
`later_completed` path list `lint_orphans` computed for that specific
finding. Since `lint_orphans` currently discards this after building the
message (§2.2's same observation, now on the production side), `main()`'s
own call site needs the same "capture the intermediate value" treatment:
`lint_orphans` gains an optional keyword parameter,
`capture: dict[int, list[str]] | None = None`, defaulting to `None` (fully
backward compatible — every existing caller, including
`preexisting_run_finding_codes`, keeps working unchanged since it never
passes this argument). When provided, `lint_orphans` records
`capture[id(finding)] = later_completed_paths` alongside appending the
`Finding` to `findings`, exactly mirroring how the finding is built — no
predicate logic changes, only an optional side-channel for a value already
being computed. `main()` passes `capture={}` and threads it into
`matching_key_for` for any `f.code == "H009"`.

This is the one production-code touch this design makes to
`tools/lint_handoffs.py` itself (beyond `main()`'s new baseline-filtering
block and CLI flags, §3.4) — everything else is additive. It is a strictly
optional, additive parameter, so `--changed` mode's existing
`preexisting_run_finding_codes` call (which does not pass `capture`) is
provably unaffected.

### 3.2 Bucket semantics — reported, tallied, never gates

```python
counts = defaultdict(int)
for f in findings:
    counts[f.severity] += 1
ack_count = len(acknowledged)
```

`ack_count` is **not** added to `counts['BLOCKER']` or `counts['MAJOR']`.
The exit-code line (currently `return 1 if (counts["BLOCKER"] or
counts["MAJOR"]) else 0`) is unchanged — it already only reads `counts`,
which acknowledged findings never enter.

### 3.3 Print output — `[ACKNOWLEDGED]`, individually listed, matching `lint_test_wiring.py`'s `[KNOWN]` precedent

```python
if not quiet:
    for f in findings:
        print(f)
    if acknowledged:
        print()
        for f in acknowledged:
            print(f"[ACKNOWLEDGED] {f.severity:7s} {f.code}  {f.path}")
            print(f"               {f.message}")
            print(f"               reason: {baseline_reason_for(f)}  "
                  f"(acknowledged {baseline_entry_for(f)['acknowledged_at']} "
                  f"by {baseline_entry_for(f)['acknowledged_by']})")
    if findings or acknowledged:
        print()

print(
    f"lint_handoffs: {total} handoffs checked — "
    f"{counts['BLOCKER']} BLOCKER, {counts['MAJOR']} MAJOR, {counts['MINOR']} MINOR"
    + (f", {ack_count} ACKNOWLEDGED" if ack_count else "")
)
```

This is the direct analog of `lint_test_wiring.py`'s `[KNOWN]` bucket
(§465-478 of that file): every acknowledged finding still prints, every run,
with enough context (code, file, message, reason, who/when) that a human
skimming the output sees exactly what was accepted and why — the bucket
being non-empty is not itself a problem (unlike `KNOWN_UNATTACHED`'s
"EMPTY is the intended steady state," an empty `tools/lint_handoffs.baseline.json`
is NOT the goal here — 225 entries are the honest, permanent size of this
specific historical acknowledgment, since the underlying handoffs cannot be
un-happened). What must never happen is the count silently dropping to zero
in the printed output while the underlying `baseline.json` still lists 225
entries, or vice versa — §7's selftest checks this invariant directly.

### 3.4 `--no-baseline` flag (mirrors `tools/lint_test_tenant_provisioning.py`)

```python
parser.add_argument(
    "--baseline",
    type=Path,
    default=REPO_ROOT / "tools" / "lint_handoffs.baseline.json",
    help="path to the acknowledgment baseline for H003/H004/H005/H009 (default: %(default)s)",
)
parser.add_argument(
    "--no-baseline",
    action="store_true",
    help="disable baseline acknowledgment (use to validate the acknowledgment mechanism itself)",
)
```

With `--no-baseline`, every H003/H004/H005/H009 finding reports as a normal
BLOCKER/MAJOR — no `acknowledged` bucket is populated at all, and the
`ack_count` line is omitted, matching `lint_test_tenant_provisioning.py`'s
existing `--no-baseline` semantics precisely: nothing about the linter's own
detection logic changes; only whether the acknowledgment filtering step
runs. The audit line already required by CLAUDE.md's convention
(`"Suppressed N issue(s) from baseline: <path>"`) is printed by this
linter's normal (non-`--no-baseline`) path whenever `ack_count > 0`:

```python
if ack_count and not args.no_baseline:
    print(f"Acknowledged {ack_count} issue(s) from baseline: {args.baseline}")
```

placed alongside the existing summary line, matching
`lint_test_isolation.py`'s `"Suppressed {suppressed} issue(s) from
baseline: {args.baseline}"` wording pattern (renamed "Acknowledged" rather
than "Suppressed" here specifically because — unlike
`lint_test_isolation.py`'s baseline, which removes matched issues from the
report entirely, §3.3 above — this mechanism's matched findings are still
individually printed under `[ACKNOWLEDGED]`; "suppressed" would misdescribe
behavior that is visible-but-non-gating, not hidden).

---

## 4. Composition with `--changed` mode's `preexisting_*` logic (GH-594) — explicitly distinct, explicitly composed

**These are two different questions and this design does not merge them:**

- `--changed` mode's `preexisting_file_finding_codes` /
  `preexisting_run_finding_codes` (added GH-594, lines 447-564) answer:
  *"did the branch currently being checked introduce this finding, or did it
  already exist at merge-base?"* This is branch-relative and re-evaluated
  fresh, from git history, on every run — it is not a suppression list, it
  is a same-file/same-code presence diff.
- This design's baseline (`tools/lint_handoffs.baseline.json`) answers a
  branch-independent question: *"has this specific historical finding been
  reviewed by a human/agent and accepted as permanent record?"* It is a
  fixed, versioned file that changes only when someone deliberately
  regenerates it (§2), never as a side effect of which branch is checked
  out.

**Composition rule (per the handoff's recommendation, adopted): baseline
matching applies identically in both `--changed` and full-corpus modes,
independently of and in addition to `--changed`'s own pre-existing-diff
logic.** Concretely, in `main()`, the baseline-filtering block (§3.1) runs
**after** the existing `only_changed is not None` pre-existing-diff block
(current lines 638-665), operating on whatever `findings` list that block
already produced — not before it, and not as a replacement branch.

This ordering is deliberate, not incidental: `--changed` mode's diff logic
can only be evaluated meaningfully on findings that are still in play after
that filtering; running baseline-matching first and diff-filtering second
would mean the diff logic occasionally operates over already-acknowledged
findings for no benefit (they'd just get re-filtered a second time,
harmlessly, but out of the intended reading order — "first ask whether this
branch introduced it; whatever's left, ask whether it's an accepted
permanent record").

**Why the two must compose rather than short-circuit each other, worked
through per the handoff's example:** consider a file already carrying two
H003 findings that are both in the baseline, on a branch that fixes one of
them but not the other. Under `--changed`, `preexisting_file_finding_codes`
compares merge-base to now **by code**, not by individual finding — so if
the file still has *any* H003 at merge-base and *any* H003 now, the code
`H003` is treated as pre-existing for that file and none of that file's
H003 findings are newly reported by `--changed`'s own logic (this is
already true today, independent of baseline). Both the fixed one (now gone
entirely — no finding to filter) and the still-present one flow through to
the baseline-filtering step, where the still-present one matches its
existing baseline entry (`matching_key` unchanged, since neither its
`completed_at` nor `started_at` moved) and is bucketed ACKNOWLEDGED. If a
*third*, brand-new H003 appeared in the same file on this branch (a
distinct timestamp pair, per §1.4's worked example), `--changed`'s own
per-code diff would currently suppress it too (same code, same file,
already "pre-existing" by code) — that is a pre-existing behavior of
`--changed` mode this design does not change or attempt to fix; it is
called out here only so the interaction is explicit, not because this
design is responsible for `--changed`'s code-level (not instance-level)
granularity. What this design adds is orthogonal: whether a finding survives
into the final report is `(not filtered by --changed's per-code diff) AND
(not matched by the baseline)` — two independent gates in series, neither
aware of the other's internal logic, exactly the "must not be confused with
or merged into one mechanism" requirement from the handoff.

---

## 5. Coverage confirmation — all 4 categories, explicit exclusions unchanged

- **H003** — §1.3 (key formula), §2.1 (generation reuses
  `_lint_parsed_handoff`), §3 (bucket/print/gate).
- **H004** — same three references, second branch of
  `_lint_parsed_handoff`.
- **H005** — same three references, third branch of `_lint_parsed_handoff`.
- **H009** — §0.2 (collision analysis), §1.3 (H009-specific key formula),
  §2.2 (capturing `later_completed` without changing `lint_orphans`'s
  predicate), §3.1 (the one production-code addition: `capture` kwarg).

**Untouched by this design, confirmed:**
- `tools/repair_handoff_bookkeeping.py` (H002/H008/H010/H006-partial/
  H001-encoding, GH-594) — no reference to this design's baseline file, no
  shared code path, no shared CLI flags. The only shared concept is both
  scripts reading the same corpus read-only via similar walk logic, which
  is incidental, not a dependency.
- H013 — no whole-hour-offset detection or correction logic added anywhere
  in this design. `lint_clock_skew` (H013's detector) is untouched.
- H001-structural (~4 files) — no bracket/delimiter judgment logic.
- H006-CONDITIONAL (1 finding) — no enum-mapping decision made or implied.
- H007 (69 findings/~10 files) — no schema-migration logic.

These four remain tracked in ISS-0627 exactly as before this design; nothing
here reduces their finding counts or absorbs them into the ACKNOWLEDGED
bucket. If H013 is later folded into this same baseline mechanism (per
ISS-0627's own acceptance criteria leaving that door open), that is a
decision for H013's own future run to make explicitly, reading this design
as prior art rather than duplicating it — this design takes no position on
H013 and adds no speculative capability for it.

---

## 6. Error taxonomy

This module is a linter and a one-time generation script, not a service —
"errors" here are the failure modes each piece must handle without
crashing or silently corrupting output, matching the level of rigor
`tools/lint_handoffs.py` and `tools/lint_test_isolation.py` already apply to
their own baseline loading:

| Condition | Handling |
|---|---|
| `tools/lint_handoffs.baseline.json` absent | `load_lint_handoffs_baseline` returns an empty mapping (matching `lint_test_isolation.py`'s `load_baseline`'s `if not path.exists(): return set()`); every H003/H004/H005/H009 finding reports normally, exactly as if `--no-baseline` were passed. Not a crash, not a silent full-suppression. |
| `tools/lint_handoffs.baseline.json` present but malformed JSON | Same defensive pattern as the two existing `load_baseline` functions: catch `(json.JSONDecodeError, OSError)`, return empty mapping, findings report normally. A malformed baseline degrades to "acknowledge nothing," never to "crash the linter" or "acknowledge everything." |
| A baseline entry references a `reason_ref` not present in the `reasons` map (and is not an `"adhoc:"`-prefixed inline string) | The entry is still used for matching (the acknowledgment itself is not weakened by a broken reason lookup), but `baseline_reason_for` substitutes a literal `"(reason_ref '<ref>' not found in baseline reasons map — see tools/lint_handoffs.baseline.json)"` string in the printed `[ACKNOWLEDGED]` block, so the gap in provenance is visible rather than crashing or silently printing nothing. |
| `generate_lint_handoffs_baseline.py --apply` invoked without `--now` | Exit code 2, usage error — this script never falls back to a system clock call, per §2.4 and CLAUDE.md's timestamp-sourcing rule. |
| Generation script's differential check (§2.2) finds its local orphan-walk copy diverges from `lint_orphans`'s actual message output on the same fixture | `selftest` (§7) fails loudly; this is the drift-detection mechanism, not a runtime condition to recover from — it means the local copy needs updating to match `lint_orphans`, and the script must not be used to regenerate the real baseline until it does. |
| Two different baseline entries produce the same `matching_key` (a corrupted or hand-edited baseline file) | Not a crash — `baseline` is loaded as a `set`/`dict` keyed by `matching_key`, so a duplicate simply collapses to one entry silently, same as `lint_test_isolation.py`'s existing `load_baseline` behavior (a `set` of strings). This is an accepted, pre-existing convention in this repo's baseline files, not a new risk introduced here. |

---

## 7. Test specifications (mutation-checkable, synthetic fixtures)

Following the `reqctl.py cmd_selftest` convention (also used by
`tools/repair_handoff_bookkeeping.py`'s own `selftest` subcommand, GH-594) —
plain `assert`/`check`-style comparisons against synthetic fixtures, no
pytest/unittest. Invoked as
`python3 tools/generate_lint_handoffs_baseline.py selftest` and
`python3 tools/lint_handoffs.py selftest` (a new `selftest` subcommand added
to `lint_handoffs.py` itself, since §3's baseline-filtering logic lives
there and needs its own coverage independent of the generation script's).

### 7.1 TS-BASELINE-01 — a baseline-matched finding is excluded from the gating count but still printed

**Fixture:** a synthetic `runs`/corpus producing exactly one H003 finding
(`file: "handoffs/FIX-01/step-01-x.json"`, known `completed_at`/`started_at`
pair). A synthetic `tools/lint_handoffs.baseline.json`-shaped dict
containing exactly one entry whose `matching_key` is computed via §1.3's
formula against that same finding (constructed the same way, not copy-pasted,
so a formula typo in the fixture would show up as a test failure rather than
tautologically matching itself).

**Run:** the full `main()`-equivalent pipeline — lint the fixture corpus,
apply baseline-filtering (§3.1) with `--no-baseline` NOT set.

**Assertions:**
- `counts['BLOCKER']` is `0` — the H003 finding’s severity does NOT enter
  the gating tally.
- `acknowledged` contains exactly one `Finding` whose `path`/`code`/
  `message` match the fixture's H003 finding exactly (same object identity
  of content, confirming it wasn't dropped, only rebucketed).
- The rendered stdout (or the function producing it) contains a line
  starting with `[ACKNOWLEDGED]` and the fixture's file path and code.
- The final exit-code computation (`1 if (counts["BLOCKER"] or
  counts["MAJOR"]) else 0`) evaluates to `0` for this fixture (assuming no
  other unrelated findings), proving the exclusion is real at the point that
  matters, not just in a side counter nobody reads.
- **Mutation check:** if the baseline-filtering step (§3.1) is skipped
  entirely (simulating "the ACKNOWLEDGED mechanism was never wired in"),
  `counts['BLOCKER']` is `1` and the exit code is `1` for the same fixture —
  proving the positive assertions above are specifically gated on the
  filtering step having run, not on some property already true of the
  fixture without it.

### 7.2 TS-BASELINE-02 — a brand-new finding is NOT excluded, even on a file with existing baseline entries

**Fixture:** the same file path as 7.1's fixture (`handoffs/FIX-01/step-01-x.json`)
carries **two** H003-shaped situations: the baseline entry from 7.1
(`completed_at`/`started_at` pair A), and the corpus fixture's actual
finding uses pair B (different values) — modeling "this file has an old
acknowledged H003 and a new, distinct one," the exact scenario the handoff's
acceptance criterion 4 (and §1.4's worked examples) requires proving.

**Run:** same pipeline as 7.1.

**Assertions:**
- `matching_key` computed for the fixture's actual finding (pair B) is
  provably different from the one baseline entry present (pair A) —
  asserted directly by string inequality, not just inferred from the count
  below.
- `counts['BLOCKER']` is `1` (pair B's finding reports normally).
- `acknowledged` is empty for this file (pair A's baseline entry exists but
  matches nothing in this fixture's actual findings, since the corpus
  fixture doesn't contain a finding with pair A's values in this test).
- **Mutation check:** if `matching_key` construction is (incorrectly)
  changed to key on `severity|code|path` only, omitting `message` (simulating
  "someone weakens the key to be file+code only, ignoring the handoff's
  explicit warning against that"), pair B's finding WOULD incorrectly match
  pair A's baseline entry (same file, same code) — this mutation is asserted
  to produce `counts['BLOCKER'] == 0`, proving 7.2's actual (correct) test
  is specifically pinned on message inclusion, not passing by coincidence.

### 7.3 TS-BASELINE-03 — H009 collision case from §0.2/§1.4 is correctly disambiguated

**Fixture:** two synthetic `runs` snapshots for run `WF02-x`, same orphan
file `step-02a-....json` (status `PENDING`) in both:
- Snapshot 1 (baseline-generation time): later-completed steps
  `[step-03-....json, step-04-....json]`.
- Snapshot 2 (current lint run): later-completed steps
  `[step-04-....json, step-05-....json]` — same count (2), different
  membership, per §0.2's exact scenario.

Baseline built from Snapshot 1's H009 finding via §1.3's H009 key formula
(including the `later_completed` fingerprint).

**Run:** lint Snapshot 2, apply baseline-filtering.

**Assertions:**
- The plain-message-only key (`severity|code|path|message`, no
  `later_completed` suffix) for Snapshot 2's finding EQUALS Snapshot 1's
  plain-message-only key — asserted directly, proving the collision this
  design fixes is real in the test fixture, not assumed.
- The full `matching_key` (WITH the `later_completed` suffix, §1.3) for
  Snapshot 2's finding does NOT equal Snapshot 1's full `matching_key` —
  proving the fingerprint component is what prevents the match.
- `counts['MAJOR']` is `1` for Snapshot 2's lint run (the H009 reports as
  new, not acknowledged).
- `acknowledged` is empty.
- **Mutation check:** if H009's key formula is reverted to the plain
  `severity|code|path|message` form (no `later_completed` suffix — i.e.
  §0.2's originally-proposed, insufficient scheme), Snapshot 2's finding
  DOES match Snapshot 1's baseline entry, and `counts['MAJOR']` becomes `0`
  — proving this test specifically exercises the exact gap §0.2 identified,
  not a generic "keys differ somehow" property.

### 7.4 TS-BASELINE-04 — `--no-baseline` restores full gating

**Fixture:** identical to 7.1's (one H003 finding, one matching baseline
entry).

**Run:** the pipeline with `--no-baseline` set.

**Assertions:**
- `load_lint_handoffs_baseline` is never called, or its result is
  discarded — either way, `acknowledged` is empty.
- `counts['BLOCKER']` is `1` (the finding reports as a normal BLOCKER).
- Exit-code computation is `1` for this fixture.
- The `"Acknowledged N issue(s) from baseline"` audit line is NOT printed.
- **Mutation check:** if `--no-baseline` is (incorrectly) implemented as
  merely suppressing the print line while still applying the filter
  (simulating "the flag was wired to hide the acknowledgment instead of
  disabling it," which would defeat the audit purpose of the flag), then
  `counts['BLOCKER']` would incorrectly be `0` under this mutated behavior —
  this test's second assertion (`counts['BLOCKER'] == 1`) specifically
  catches that mutation, proving `--no-baseline` is pinned on gating
  behavior, not merely on output verbosity.

### 7.5 TS-BASELINE-05 — generation script's local H009 orphan-walk matches `lint_orphans` exactly (differential check, §2.2)

**Fixture:** a synthetic multi-step `runs` dict with at least one orphaned
PENDING step bypassed by 2+ later COMPLETED steps.

**Run:** (a) `lint_handoffs.lint_orphans(runs, findings_a)` (the real,
imported function). (b) the generation script's local orphan-walk helper
against the same `runs` fixture, producing `findings_b` +
`later_completed_paths`.

**Assertions:**
- `findings_a`'s single H009 `Finding.message` string equals `findings_b`'s
  corresponding message string, byte-for-byte.
- `later_completed_paths` (only available from (b), since (a)'s
  `lint_orphans` discards it, §2.2) has length equal to
  `len(later_completed)` as parsed back out of `findings_a`'s message
  (cross-checking the captured list against the count embedded in the
  official function's own message, without needing `lint_orphans` itself to
  expose the list).
- **Mutation check:** if the generation script's local orphan-walk copy is
  edited to use `ordered[idx:]` instead of `ordered[idx + 1:]` (an
  off-by-one that would incorrectly include the orphan step itself in
  `later_completed`), the message-equality assertion above fails — proving
  this differential test would actually catch the generation script's
  local copy drifting from `lint_orphans`'s real semantics, which is the
  entire purpose of §2.2's differential check existing.

---

## 8. Summary of files touched by this design

- **New:** `tools/generate_lint_handoffs_baseline.py` (one-time generation
  script, including its `selftest` subcommand covering §7.5 and its own
  fixture-based checks for §1.3's key formulas).
- **New:** `tools/lint_handoffs.baseline.json` (225 entries, written by
  running the generation script under `--apply` — not hand-typed).
- **Modified:** `tools/lint_handoffs.py` — adds `--baseline`/`--no-baseline`
  CLI flags, the baseline-filtering block in `main()` (§3.1-§3.4), the
  optional `capture` keyword parameter on `lint_orphans` (§3.1, backward
  compatible, defaults to `None`), and a new `selftest` subcommand covering
  §7.1-§7.4. No existing detection predicate (`_lint_parsed_handoff`,
  `lint_orphans`'s orphan-finding logic itself, `lint_clock_skew`,
  `preexisting_file_finding_codes`, `preexisting_run_finding_codes`) is
  changed in behavior — only additive code around them.
- **Not modified by this design:** `tools/repair_handoff_bookkeeping.py`;
  any file under `handoffs/`; `docs/issues/ISS-0627.json` (referenced, not
  edited, by this design — DOC-UPDATER or ISSUE-FIXER updates its status
  separately once this design is implemented and the baseline is generated).
