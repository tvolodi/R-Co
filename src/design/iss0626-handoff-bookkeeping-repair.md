# Module: Handoff Bookkeeping Repair Script (ISS-0626 safe-mechanical subset)

**Issue:** ISS-0626 / GH #594 (narrowed scope, ISSUE-FIXER triage 2026-08-08)
**Categories in scope:** H002 (9 files), H008 (88 files), H010 (1868 of 2270
missing registry entries), H006-partial (2 of 3 findings: `FAILED`->`FAIL`,
`PARTIAL_PASS`->`PARTIAL`), H001-encoding-subset (~7 of 11 files)
**Out of scope:** H001-structural (~4 files), H003 (148), H004 (34), H005 (5),
H006-CONDITIONAL (1), H007 (69), H009 (38), H013 (53) — see §8. Tracked in
ISS-0627 / GH #596.

## Module purpose

`tools/repair_handoff_bookkeeping.py` is a one-off, repeatable repair script
that closes the safe-mechanical subset of the handoff-corpus defects
`tools/lint_handoffs.py` detects. "Safe-mechanical" means: for every file this
script touches, the correct output is either (a) fully recoverable from data
already present in that same file (H002's stringified `result`, H008's BOM,
H006's unambiguous renames), or (b) purely additive from data already present
in the *scanned* handoff corpus with nothing invented (H010's registry
backfill), or (c) accepted only after a two-part verification that would
reject the change outright if anything beyond the intended bytes moved (H001's
encoding-fallback subset). No category in this design ever writes a value that
is not already recoverable, byte-for-byte or field-for-field, from a file the
script itself read.

This is Type E per `templates/lego-catalog.md` — a one-off, cross-cutting
repair operating on ~2000 pre-existing JSON files outside any CRUD/migration/
list-page/React-Flow-node shape. It is prose design; the script is Python
tooling (like `tools/lint_handoffs.py` and `tools/reqctl.py`), not Zig, so
its "public interface" (§6) is CLI flags and function signatures rather than
`pub fn` exports, and its test specs (§5) follow the `reqctl.py selftest`
convention already established in this repo (plain `assert`-style checks
against synthetic fixtures, no pytest — confirmed by grep: no `tools/*.py` in
this repo uses pytest or `unittest`; `reqctl.py cmd_selftest` is the only
existing self-test convention and this design follows it) rather than the
Zig `std.testing` mutation-check format used for engine code.

---

## 0. Non-negotiable operating constraints (apply to every category)

These four rules are stated once here because they govern all five repair
categories identically; each category section below states only what is
specific to it.

**C-1 Dry-run-first.** The script's default mode is `--dry-run` (also the
implicit default with no flag at all — there is no way to invoke the script
and have it write by accident). Dry-run performs every read, every parse,
every proposed transformation, and every verification step (§0's C-3) that
the real run would — the only thing it skips is the final `os.replace()` onto
the real file. Dry-run output is the before/after count table (§7) plus, at
`--verbose`, a per-file unified diff of exactly what would change. Writing
requires the explicit `--apply` flag.

**C-2 Idempotent.** Re-running the script (dry-run or `--apply`) against a
corpus that has already been fixed must report zero proposed changes for
every category. Each category's detection predicate (§1-§5) is the *same*
predicate `lint_handoffs.py` uses to flag the defect in the first place
(H002: `isinstance(result, str)`; H008: BOM byte-prefix; H010: `handoff_id`
absent from registry `entries`; H006: `status` field literally equal to
`FAILED` or `PARTIAL_PASS`; H001-subset: file fails to parse AND the
specific corruption signature in §5 matches). A file that no longer matches
the predicate is left untouched and is not counted as a "found" candidate on
the second run — this makes idempotency a direct, testable consequence of
reusing the detection predicate rather than a separately-maintained property.

**C-3 Self-verifying write.** For every file the script modifies under
`--apply`:
1. Compute the proposed new byte content in memory.
2. Write it to a temp file in the same directory (`<name>.tmp-<pid>`), never
   in-place first.
3. Re-open the temp file and `json.load()` it. If this raises, delete the
   temp file, record the file as a **FAILED** repair (not silently skipped —
   see §7), and do not touch the original. Move to the next file.
4. If the re-parse succeeds, additionally re-run the category's own
   detection predicate against the re-parsed content and assert it now
   returns "clean" (e.g. for H002, `isinstance(reparsed['result'], dict)` —
   not just "is valid JSON somehow"). If this assertion fails, same failure
   path as step 3: delete temp, record FAILED, do not touch the original.
5. Only after both checks in steps 3-4 pass: `os.replace(tmp_path,
   original_path)` — an atomic rename on both POSIX and Windows (NTFS),
   so there is no window where the original file is truncated or partially
   written. The original file is never opened in write/truncate mode
   directly.

This is stronger than "the write succeeded" — it is "the write succeeded AND
produced the specific intended fix," which is what prevents a category whose
transformation logic has a latent bug from silently reporting success while
leaving the file just as broken (or broken differently) than before.

**C-4 Category isolation.** Each of the five categories below is an
independent pass over the corpus with its own predicate, its own
transformation, and its own before/after counter. A single file may match
more than one predicate (e.g. a file could in principle have both a BOM and a
stringified result — none of the sampled H002 files do, per ISS-0626's triage
note, but the script does not assume this). When a file matches multiple
predicates, the passes apply in this fixed order: **H008 (BOM strip) first,
then H001-encoding-subset, then H002, then H006, last H010** (H010 reads the
already-repaired file content for whichever fields it backfills, so it must
run after any content-level fix has been committed for that file in the same
invocation). Each pass re-reads the file from disk rather than passing an
in-memory buffer to the next pass, so C-3's write-then-reread-then-verify
cycle is honestly repeated per pass, not skipped for the second matching
category.

---

## 1. H002 — stringified `result` field (9 files)

### 1.1 Scope

All 9 files live under `handoffs/WF02-iss105-token-model-schema-20260611/`
per ISS-0626's triage. The script does not hardcode this directory — it
applies the same predicate corpus-wide, so if a 10th file matching H002's
signature exists anywhere else it is still found and fixed identically (the
directory concentration is a fact about this corpus's history, not a
constraint the script encodes).

### 1.2 Detection predicate

Identical to `lint_handoff_file`'s own check (`tools/lint_handoffs.py` lines
181-191): after reading the file with `utf-8-sig` tolerance and
`json.loads`, the top-level parsed object has a `result` key whose value's
Python type is `str` (not `dict`, not `None`).

### 1.3 Transformation

```
def fix_h002(parsed: dict) -> dict | None:
    """Return a new dict with result unwrapped, or None if unsafe to fix."""
    raw_result = parsed["result"]
    try:
        inner = json.loads(raw_result)
    except json.JSONDecodeError:
        return None  # not a JSON-string after all; leave flagged, do not force
    if not isinstance(inner, dict):
        return None  # round-tripped to something other than an object -- e.g.
                      # a bare number or list -- do not accept; H002's own
                      # definition in lint_handoffs.py is specifically
                      # "result should be an object", so anything that isn't
                      # a dict after unwrapping is not a fix, it is a
                      # different, unhandled shape
    fixed = dict(parsed)
    fixed["result"] = inner
    return fixed
```

This is exactly ISS-0626's own verification requirement restated as code:
"json.loads() must succeed and produce a dict before accepting the change."
`fix_h002` returning `None` routes the file to the **SKIPPED (unsafe)**
bucket in §7, not a silent no-op — a file whose `result` string does not
round-trip to a dict is not H002 as diagnosed and must be visible as a
discrepancy from the triage's stated count (9), not swallowed.

### 1.4 Post-write predicate re-check (per C-3 step 4)

`isinstance(reparsed["result"], dict)` must be `True`.

---

## 2. H008 — UTF-8 BOM (88 files)

### 2.1 Detection predicate

Identical to `lint_handoffs.py`'s own check: `raw.startswith(b"\xef\xbb\xbf")`
on the raw file bytes, read in binary mode before any decoding.

### 2.2 Transformation

```
def fix_h008(raw: bytes) -> bytes:
    assert raw.startswith(b"\xef\xbb\xbf")
    return raw[3:]
```

No JSON parsing is required to perform this fix — it is a pure byte-slice
operation, which is what makes "content otherwise byte-identical" a
structural guarantee rather than something that needs separate verification:
removing exactly the 3 BOM bytes and nothing else is the entire operation.
The script still performs C-3's full verify-by-reparse cycle (parse the
result as JSON, confirm no BOM remains) because a self-verifying write is
mandated uniformly (§0), not because BOM-stripping is expected to be able to
corrupt content.

### 2.3 Byte-identical check (stronger than C-3's default)

In addition to C-3's standard re-parse check, H008 asserts
`new_raw == original_raw[3:]` before accepting the write — i.e. the only
difference between old and new file bytes is the missing 3-byte prefix. This
is a category-specific strengthening of C-3, not a replacement for it.

### 2.4 Post-write predicate re-check

`not new_raw.startswith(b"\xef\xbb\xbf")`.

---

## 3. H010 — registry.json additive backfill (1868 of 2270 missing entries)

### 3.1 Scope and hard constraint

**Purely additive.** The script never removes, reorders, or mutates an
existing entry in `handoffs/registry.json`. It only appends new entries for
handoff files whose `handoff_id` is not already present among
`registry["entries"][*]["handoff_id"]`.

### 3.2 Field sourcing — no invented data

For each `*.json` handoff file under `handoffs/` (matched the same way
`lint_handoffs.py` walks the tree: `name.startswith("step-") and
name.endswith(".json")` — this excludes `registry.json`,
`orchestrator.log`, `escalations.json`, and any `estimation.json`/
`STOP_LOOP` marker files, none of which are handoff step files and none of
which belong in the registry), the script builds a candidate registry entry
using **only** fields already present in that file:

```
def build_registry_entry(path: str, parsed: dict) -> dict | None:
    """Return a new registry entry sourced only from the handoff's own
    fields, or None if a required field is missing (do not invent it)."""
    required = ("handoff_id", "run_id", "step", "from_agent", "to_agent",
                "created_at", "status")
    missing = [k for k in required if k not in parsed or parsed[k] in (None, "")]
    if missing:
        return None  # see 3.3 -- warn and skip, never placeholder-fill
    entry = {
        "handoff_id": parsed["handoff_id"],
        "file": path.replace(os.sep, "/"),      # derived from the filesystem
                                                   # scan itself, not invented --
                                                   # this is the one field every
                                                   # existing registry entry
                                                   # also derives this way
        "run_id": parsed["run_id"],
        "step": parsed["step"],
        "from_agent": parsed["from_agent"],
        "to_agent": parsed["to_agent"],
        "created_at": parsed["created_at"],
        "status": parsed["status"],
    }
    if "stage" in parsed and parsed["stage"]:
        entry["stage"] = parsed["stage"]          # optional field, included
                                                     # only when the source file
                                                     # itself has it (present in
                                                     # 275 of 305 existing
                                                     # registry entries sampled)
    return entry
```

`"file"` is the one field not drawn from the JSON body of the handoff
itself — it is the relative path the script found the file at during its own
directory walk, exactly mirroring how every pre-existing registry entry
already records `"file"` (confirmed against `handoffs/registry.json`'s
existing entries, e.g. `"file":
"handoffs/ADHOC-gh402-migration-order-20260803/step-00-backend-dev-migration-fix.json"`).
This is not an invented value; it is the discovery path, which is
definitionally known and correct because the script is reading that exact
file at that exact path.

### 3.3 Missing-field handling (explicit, per the handoff's requirement)

If any of the 7 required fields (`handoff_id, run_id, step, from_agent,
to_agent, created_at, status`) is absent, empty-string, or `null` in a given
handoff file, that file is **skipped entirely for H010** — no partial entry
is added, no placeholder (`"unknown"`, `""`, `None`) is written into any
field. The file is recorded in the run report (§7) under a distinct
**"H010 skipped — missing required field"** bucket, naming the file and
which field(s) were absent, so the gap is visible to whoever reads the
report rather than silently reducing the "1868 fixed" count with no
explanation. This is deliberately more conservative than H002/H008/H006: a
missing field is not a "verify then reject" case (there is nothing to
verify — the source datum simply is not there), it is an immediate skip.

A handoff file that itself fails to parse as JSON at all (i.e. it is an
H001 case not in the encoding-subset this script also fixes, §5, or one of
the ~4 structural-typo H001 files explicitly out of scope, §8) is likewise
skipped for H010 with a distinct reason string ("source file unparseable"),
since the script cannot read `handoff_id` etc. from a file it cannot parse.
The script does not attempt to backfill a registry entry for such a file
from its filename or directory alone — a `run_id`/`step` guessed from a
directory name is exactly the kind of inference this category's "purely
additive, no invented fields" constraint forbids.

### 3.4 Duplicate `handoff_id` guard

If the corpus scan encounters two different files claiming the same
`handoff_id` (a pre-existing data-quality question outside this repair's
scope to resolve), the script does not silently pick one. It records both
file paths under a **"H010 skipped — duplicate handoff_id"** bucket and adds
neither to the registry, leaving the ambiguity visible rather than guessing
which file is authoritative. (No such duplicate is known to exist in the
current corpus per the triage sample, but the predicate must not assume
uniqueness un-checked given 2270 files were never mechanically
cross-verified before.)

### 3.5 Write mechanics for registry.json specifically

`registry.json` is a single JSON document, not 1868 independent files, so
C-3's per-file temp-write-then-atomic-replace pattern applies once, to the
whole file, after all candidate entries for this run have been computed:
read `registry.json` with `utf-8-sig` tolerance (per CLAUDE.md's Bookkeeping
directive), append every accepted new entry (§3.2/§3.3/§3.4) to the
in-memory `entries` list preserving existing entry order and content
unchanged, update `last_updated` to the value of `python3 tools/utcnow.py`'s
output supplied by the invoking agent (the script itself never calls the
system clock — see §6's `--now` parameter), write to a temp file, re-parse
it, assert `len(new_entries) == len(old_entries) + accepted_count` and that
every one of the `old_entries` is present unchanged (byte-for-byte
dict-equal) in the new list, then atomically replace.

### 3.6 Post-write predicate re-check

Re-run H010's own detection predicate (`all_ids - registered`, mirroring
`lint_registry`) against the new registry content and the full corpus scan
performed in this run; the resulting missing-count must equal exactly the
count of files skipped in §3.3/§3.4 (i.e. every file that *could* be added,
was).

---

## 4. H006 partial — two unambiguous status-string renames (2 of 3 findings)

### 4.1 Scope, and how the excluded 3rd finding is structurally avoided

Renames applied, **only exact matches**:
- `"FAILED"` → `"FAIL"`
- `"PARTIAL_PASS"` → `"PARTIAL"`

The excluded third H006 finding has `result.status == "CONDITIONAL"`. The
transformation function below is written as an explicit two-entry mapping
table, not a general "normalize toward `LEGAL_RESULT_STATUS`" routine — this
is the mechanism that keeps `CONDITIONAL` untouched, not a separate
exclusion check bolted on afterward:

```
H006_SAFE_RENAMES = {
    "FAILED": "FAIL",
    "PARTIAL_PASS": "PARTIAL",
}

def fix_h006(value: str) -> str | None:
    """Return the renamed value, or None if value is not one of the two
    unambiguous cases (including CONDITIONAL, and including any value
    already legal)."""
    return H006_SAFE_RENAMES.get(value)  # .get() returns None for
                                            # "CONDITIONAL" or anything else
                                            # not in the table -- there is no
                                            # code path in this function that
                                            # can produce an output for a key
                                            # absent from H006_SAFE_RENAMES
```

Because `H006_SAFE_RENAMES` has exactly two keys and the lookup uses
`.get()` with an implicit `None` default (never a fallback transformation,
never a "best guess"), a file with `status == "CONDITIONAL"` always produces
`None` from `fix_h006` and is therefore never written — the exclusion is a
property of the lookup table's contents, verifiable by reading the table,
not a behavioral claim that needs separate testing beyond confirming the
table has exactly these two entries (§5.4 does test this directly).

### 4.2 Where the value appears

Per `lint_handoffs.py`'s H006 check (lines 192-203), the value being
checked is `result.status` (a nested field, only when `result` is already a
`dict` — which for the 9 H002 files is only true *after* §1's fix has run
in the same invocation, consistent with §0 C-4's fixed pass ordering placing
H002 before H006). The top-level `status` field (e.g. `"COMPLETED"`,
`"PENDING"`) is a different field with a different, larger legal set
(`TERMINAL_OK` / `OPEN_STATUSES` in `lint_handoffs.py`) and is **not** in
scope for this rename — only `result.status` is checked against
`LEGAL_RESULT_STATUS`. The handoff's own task description says "wherever
these appear as a handoff's status or result.status value"; this design
applies the rename to both the top-level `status` field and `result.status`
field wherever either is literally `"FAILED"` or `"PARTIAL_PASS"`, since
`lint_handoffs.py` itself never expects `"FAILED"`/`"PARTIAL_PASS"` as a
legal top-level `status` either (`TERMINAL_OK = {"COMPLETED", "CANCELLED",
"ESCALATED"}`, `OPEN_STATUSES = {"PENDING", "IN_PROGRESS"}` — neither set
contains `"FAILED"` or `"PARTIAL_PASS"`), so a top-level `status` of
`"FAILED"` is equally a historical inconsistency worth the same
unambiguous, table-driven rename. Both fields are checked independently
using the identical `fix_h006` lookup.

### 4.3 Post-write predicate re-check

Neither `parsed.get("status")` nor (if `result` is a dict)
`parsed["result"].get("status")` equals `"FAILED"` or `"PARTIAL_PASS"`
after the write; `"CONDITIONAL"` (wherever it occurs) is byte-identical to
before.

---

## 5. H001 encoding-corruption subset (~7 of 11 files)

### 5.1 Scope and the two-part accept-or-skip gate

This is the highest-risk category because, unlike H002/H008/H006, the
starting file **does not parse as JSON at all** — there is no `parsed` dict
to read a predicate off; the predicate is defined over the raw bytes and the
error `json.loads` raises.

**Candidate identification:** a file is an H001-encoding-subset candidate
if (a) `json.loads(raw.decode("utf-8-sig"))` raises `UnicodeDecodeError` or
`json.JSONDecodeError`, AND (b) the same raw bytes, decoded as `cp1252` and
re-encoded as `utf-8`, DO parse successfully as JSON. Condition (b) is the
mechanical signature ISS-0626's triage confirmed
(`WF02-lua06-16-20260528/step-02-backend-dev.json`): a PowerShell console
that emitted curly quotes (`‘ ’ “ ”`) or an em-dash under
the Windows-1252 code page, subsequently saved/read as if it were UTF-8,
produces exactly this decode/re-encode signature. A file that fails (a) but
also fails (b) (i.e. cp1252-then-utf8 still doesn't parse) is a structural
typo (bracket/delimiter), not an encoding case — it falls through to §8's
explicit exclusion, never attempted by this script.

**Accept gate (both required, per the handoff's explicit instruction):**

```
def try_fix_h001_encoding(raw: bytes) -> bytes | None:
    """Return the repaired bytes, or None if the fix must be rejected."""
    try:
        text = raw.decode("cp1252")
    except UnicodeDecodeError:
        return None  # not this failure mode
    candidate = text.encode("utf-8")

    # Gate (a): must re-parse as valid JSON.
    try:
        json.loads(candidate.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None

    # Gate (b): byte-level diff against the original must show ONLY the
    # known-corrupted-character positions changed -- nothing else touched.
    if not _only_known_corruption_bytes_differ(raw, candidate):
        return None

    return candidate
```

### 5.2 The byte-diff gate, precisely

`_only_known_corruption_bytes_differ` performs an aligned byte comparison
between `raw` (original, invalid-UTF-8-as-cp1252) and `candidate` (the
cp1252-decoded/utf8-reencoded repair), and accepts the fix only if **every**
byte-range that differs corresponds to one of the known corruption
signatures below — the specific cp1252 byte sequences that PowerShell's
curly-quote/em-dash output produces when misread as UTF-8, each mapped to
its correct UTF-8 encoding:

| cp1252 source char | cp1252 byte | Correct UTF-8 bytes | Corrupted UTF-8-as-cp1252 rendering |
|---|---|---|---|
| left single quote `'` | `0x91` | `E2 80 98` | `E2 82 AC` family artifacts / mis-decoded multi-byte |
| right single quote `'` | `0x92` | `E2 80 99` | (as above) |
| left double quote `"` | `0x93` | `E2 80 9C` | (as above) |
| right double quote `"` | `0x94` | `E2 80 9D` | (as above) |
| em dash `—` | `0x97` | `E2 80 94` | (as above) |
| en dash `–` | `0x96` | `E2 80 93` | (as above) |

(The exact right-hand "corrupted rendering" column is populated from the
specific byte sequences observed in the sampled file
`WF02-lua06-16-20260528/step-02-backend-dev.json` during implementation —
this table is illustrative of the mechanism, not a claim that all six
characters were observed in the corpus; BACKEND-DEV extends the table only
with byte sequences actually present in files this script processes, never
speculatively.)

Implementation approach: walk both byte strings with `difflib.SequenceMatcher`
(or an equivalent minimal-diff algorithm) to get the list of `replace`/
`insert`/`delete` opcodes between `raw` and `candidate`. For **every**
non-`equal` opcode, the old byte slice must exactly match the "corrupted"
side of one of the table rows above and the new byte slice must exactly
match that same row's "correct" side. If even one differing region does not
match a table entry — e.g. an unrelated byte moved, a character was
inserted/deleted outside the known set, or a differing region's old/new
bytes don't correspond to the same table row — the whole file is rejected
by gate (b) regardless of gate (a)'s outcome, per the handoff's explicit
"only known-corrupted-character positions changed, nothing else" wording.

### 5.3 Skip-and-flag, not force-fix

Any file failing either gate is left completely untouched (`raw` bytes
never written) and is recorded in §7's report under **"H001 skipped — gate
(a)/(b) failed"** with which gate rejected it. This includes: files that are
genuinely structural typos (§8, always rejected — gate (a) fails because
cp1252-decode-then-parse still doesn't produce valid JSON, since a bracket
typo isn't an encoding problem at all), and any of the ~7 encoding-subset
files where the byte-diff gate finds an unexpected additional difference
this design's known-corruption table doesn't cover. A rejected-by-gate-(b)
file is explicitly *not* the same outcome as "not attempted" — it is
attempted, found to have moved more than the known corruption, and declined,
which is exactly the conservative behavior the handoff requires ("Files that
don't pass both checks must be skipped and left flagged, not force-fixed").

### 5.4 Post-write predicate re-check

`json.loads` on the written file succeeds, and a fresh byte-diff between the
now-written file and the *original* pre-fix bytes (recomputed from the git
blob at `HEAD`, not from the script's own in-memory copy, so this check does
not just re-verify its own arithmetic) still shows only known-corruption
positions changed.

---

## 6. CLI interface (illustrative signatures)

```
tools/repair_handoff_bookkeeping.py [handoffs_dir] [options]
```

**Options:**

| Flag | Meaning |
|---|---|
| `--apply` | Perform writes. Without this flag, the script only reports what it would do (default: dry-run). |
| `--category {h002,h008,h010,h006,h001-encoding,all}` | Restrict the run to one category (repeatable). Default: all five. |
| `--now ISO8601` | Timestamp to stamp into `registry.json`'s `last_updated` (H010, §3.5). REQUIRED when `--apply` is combined with `--category` including `h010`; the script never calls the system clock itself — the invoking agent supplies the output of `python3 tools/utcnow.py`, per CLAUDE.md's Bookkeeping directive on timestamp sourcing. |
| `--report PATH` | Write the machine-readable before/after count table (§7) to PATH as JSON. Always printed to stdout as a human-readable table regardless. |
| `--verbose` | In dry-run, also print a per-file unified diff of the proposed change. |

**Exit codes:** `0` dry-run completed with no fatal errors (regardless of how
many candidates were found) / `--apply` completed with zero FAILED repairs.
`1` `--apply` completed but one or more files hit the FAILED-repair path
(§0 C-3 step 3/4) — partial success, needs investigation, matches
`lint_handoffs.py`'s own "1 = findings" exit-code convention. `2` usage error
(bad flags, `handoffs_dir` not found).

**Core functions (signatures only):**

```
def main(argv: list[str]) -> int: ...

def scan_corpus(handoffs_dir: str) -> list[tuple[str, bytes]]: ...
    # every step-*.json file, as (relpath, raw_bytes); same walk
    # predicate as lint_handoffs.py's main()

def run_category(
    category: str, files: list[tuple[str, bytes]], apply: bool,
) -> CategoryReport: ...
```

`CategoryReport` (dataclass) carries, per category: `category`,
`before_count` (candidates matching the detection predicate), `fixed_count`
(written + self-verified), `skipped_count` (rejected by an accept gate or a
missing-field/duplicate rule), `failed_count` (write attempted, re-parse/
re-predicate check failed, rolled back per C-3), `after_count` (candidates
matching the same predicate post-run — should equal `before_count -
fixed_count`), and `skipped_files` / `failed_files` as `(path, reason)`
lists for the run report.

---

## 7. Before/after reporting (per-category target table)

The script's summary output — printed in both dry-run and `--apply` modes —
is structured so a later `lint_handoffs.py` run can be checked against a
named target per category, matching the handoff's explicit requirement:

```
Category    Before   Fixed   Skipped   Failed   After   Target
H002        9        9       0         0        0       0
H008        88       88      0         0        0       0
H010        1868     1868    0         0        0       0
H006        3        2       1         0        1       1  (CONDITIONAL retained)
H001-enc    ~7        ?      ?         0        ?       0 or (11 - structural_count)
```

`H001-enc`'s exact "Before" and "Target" counts are not hardcoded — they are
computed live from the accept-gate outcome (§5.1's condition (a)+(b)), since
the "~7 of 11" figure in the issue is itself an estimate pending the
script's own gate evaluation. If fewer than 7 files pass both gates, that is
not a script defect — it means fewer files than estimated matched the
specific known-corruption signature, and the shortfall is visible in
`skipped_files` with per-file reasons, not silently absorbed into the count.

After a full `--apply` run across all five categories, the acceptance
criterion is: re-running `python3 tools/lint_handoffs.py` reports H002 count
0, H008 count 0, H010 count 0, and H006 count 1 (down from 3) — the same
four numeric targets ISS-0626's acceptance criteria specify. `lint_handoffs.py`
does not have a discrete "H001-encoding" vs "H001-structural" split in its
own output (both are folded into a single `H001` BLOCKER count), so this
script's own report (`--report`, §6) is the source of truth for how many of
the original 11 H001 findings were closed by this run; the residual H001
count in `lint_handoffs.py`'s own output after this run equals `11 -
fixed_count` and is expected to still include all ~4 structural-typo files
(§8) plus any encoding-subset file this run's gates rejected.

---

## 8. Explicitly out of scope — do not extend this script to cover these

Per the handoff's instruction, this section names every category this
design deliberately does not touch, so no future reader mistakes the
absence of a fix for an oversight:

- **H001-structural (~4 files):** bracket/delimiter typos (e.g. a `]`
  closing what should be a `}`) that require understanding which delimiter
  the original author intended — a judgment call per file, not a mechanical
  transformation. Tracked in ISS-0627 / GH #596 for per-file human/agent
  review. This script's gate (a) in §5.1 structurally rejects these files
  (cp1252-decode-then-parse still fails), so there is no code path by which
  this script could accidentally "fix" one with a guessed bracket.
- **H003 (148 findings) / H004 (34):** `completed_at`/`started_at`/
  `created_at` ordering violations with no whole-hour-offset signature (that
  subset is H013, also excluded below). No field in the file recovers the
  true timestamp; any correction is fabrication. Tracked in ISS-0627 for a
  permanent-acknowledgment mechanism (a dated, reasoned suppression list),
  not a value fix.
- **H005 (5 findings):** `status == "COMPLETED"` but `completed_at` is
  entirely unset. Same unrecoverable-value problem as H003/H004.
- **H006-CONDITIONAL (1 finding):** `result.status == "CONDITIONAL"` has no
  1:1 mapping onto `LEGAL_RESULT_STATUS`. Structurally excluded from this
  script by §4.1's closed two-entry lookup table, not by a separate runtime
  check — there is no code path that could rename it. Needs either a
  by-hand read of the file's own context (does it mean `PARTIAL`? `BLOCKED`?)
  or a decision to add `CONDITIONAL` to `lint_handoffs.py`'s own legal enum
  as a legitimate historical value; tracked in ISS-0627.
- **H007 (69 findings, ~10 distinct files):** an early alternate schema
  (`workflow_id`/`sequence` instead of `run_id`/`step`). This is a
  schema-migration decision (rename the old files' keys, vs. teach the
  linter to recognize the old shape as an accepted historical variant), not
  a silent key-add — adding `run_id`/`step` keys derived from
  `workflow_id`/`sequence` would be *inventing* a mapping between two
  different schemas, which this script's "only fields already present"
  principle for H010 (§3.2) specifically forbids applying by inference
  across differently-named keys. Tracked in ISS-0627 for an explicit
  decision.
- **H009 (38 findings):** a PENDING/IN_PROGRESS step bypassed by later
  COMPLETED steps in the same run. Marking the orphaned step COMPLETED (or
  any other terminal status) after the fact would fabricate evidence that a
  step finished when the record shows it did not — this is a real historical
  process irregularity, not a data-entry error, and no automated fix is
  appropriate. Tracked in ISS-0627.
- **H013 (53 findings):** `completed_at` precedes `started_at` by
  approximately a whole-hour offset — mechanically the signature of a
  dropped `.ToUniversalTime()` call, and the *offset* is computable, but the
  *causal timezone* (which host, which DST rule, at the moment the command
  ran) is not recorded anywhere in the file. ISS-0627 asks for an explicit,
  documented decision on whether hour-offset correction clears the "no
  judgment" bar; this design takes no position and implements nothing for
  H013 pending that decision.

**Open question flagged for CODE-DESIGN-VALIDATOR / ORCH, not silently
resolved:** H013's exclusion is the one boundary in this list that is
genuinely a design *policy* choice rather than a hard fabrication
impossibility (unlike H003/H004/H005/H009/H007's true "no source value
exists" property). If a future decision is made that whole-hour correction
is acceptable, it would need its own reviewed script and its own
before/after target — this design intentionally does not pre-build that
capability speculatively, consistent with `templates/lego-catalog.md`'s "do
not add speculatively" principle and the handoff's explicit exclusion. This
is flagged here rather than left as a silent gap.

---

## 9. Test specifications (mutation-checkable, synthetic fixtures)

Following this repo's established Python-tooling self-test convention
(`tools/reqctl.py cmd_selftest` — plain `assert`/`check`-style comparisons
against synthetic fixtures, invoked as `python3 tools/repair_handoff_bookkeeping.py
selftest`, no pytest/unittest dependency, matching the fact that no
`tools/*.py` in this repo uses either), each test below constructs a small
synthetic fixture in a temp directory, runs the relevant category's
transformation function directly (not the full CLI, to keep each test
isolated to one category's logic), and asserts both the positive outcome
(fix applied correctly) and — per this repo's mutation-check discipline
established in `src/design/iss0169-lua08-09-10-limiter-wiring.md` §5 — what
must happen if the fix logic is reverted or absent, adapted to this being
deterministic Python data transformation rather than concurrent Zig runtime
behavior: the "mutation" is calling the raw/no-op path instead of the fix
function, and asserting the predicate that should now be *false* is still
*true*.

### 9.1 TS-H002-01 — string-wrapped `result` becomes an object, and only then

**Fixture:** a synthetic handoff JSON, `result` set to
`json.dumps({"status": "PASS", "summary": "ok"})` (i.e. a JSON string
containing a valid object) — mirrors the real 9-file shape.

**Run:** `fix_h002(parsed)` where `parsed` is the fixture loaded via
`json.loads`.

**Assertions:**
- Return value is not `None`.
- `isinstance(result["result"], dict)` is `True`.
- `result["result"] == {"status": "PASS", "summary": "ok"}` — the unwrapped
  content matches exactly what was inside the string, nothing added or
  dropped.
- Every other top-level key in the fixture is unchanged (`dict`-equal to the
  original except for `result`).
- **Mutation check:** if `fix_h002` is replaced with a no-op (`return
  parsed` unchanged, i.e. the "fix logic reverted" case), then
  `isinstance(result["result"], dict)` is `False` (it is still `str`) —
  proving the assertion above specifically depends on the transformation
  having run, not on some property already true of the fixture.

**Negative case in the same test function:** a second fixture whose
`result` is `'"just a plain string, not an object"'` (a JSON string that
round-trips via `json.loads` to a Python `str`, not a `dict`) must produce
`fix_h002(...) is None` — proving the "must produce a dict" gate (§1.3)
actually rejects a string-that-round-trips-to-another-string, not just a
string that fails to parse at all.

### 9.2 TS-H008-01 — BOM is stripped, content is otherwise byte-identical

**Fixture:** `b"\xef\xbb\xbf" + json.dumps({"handoff_id": "x", ...}).encode("utf-8")`.

**Run:** `fix_h008(raw)`.

**Assertions:**
- Returned bytes do not start with `\xef\xbb\xbf`.
- Returned bytes equal `raw[3:]` exactly (not merely "also valid JSON" —
  byte-for-byte equal to the original minus the BOM prefix).
- `json.loads(fix_h008(raw))` succeeds and produces the same dict as
  `json.loads(raw.decode("utf-8-sig"))`.
- **Mutation check:** if `fix_h008` is replaced with a no-op (`return raw`),
  the returned bytes still start with `\xef\xbb\xbf` — i.e. the
  BOM-presence predicate the script's own idempotency check (C-2) relies on
  would still fire on a second pass, proving the test's assertions are
  actually gated on the strip having happened, not on some pre-existing
  property of the fixture.

### 9.3 TS-H010-01 — registry gains exactly one entry, nothing else changes

**Fixture:**
- A synthetic `registry.json` with one existing entry (`handoff_id: "aaa"`,
  full valid entry per §3.2's shape).
- A synthetic handoff file on disk with `handoff_id: "bbb"` and all 7
  required fields present, whose `handoff_id` is not in the registry.

**Run:** `build_registry_entry(path, parsed_bbb)` followed by the
registry-merge step (§3.5) that appends it to a copy of the fixture
registry.

**Assertions:**
- The new registry's `entries` list has exactly 2 items (1 original + 1
  new) — not 1 (nothing added) and not >2 (nothing duplicated).
- The original `"aaa"` entry is present in the new list, dict-equal to its
  original form (untouched — proves "purely additive").
- The new entry for `"bbb"` contains exactly the 7 required fields (plus
  `stage` only if present in the source fixture) sourced from `parsed_bbb`,
  with no additional invented keys and no field left as `None`/`""`.
- **Mutation check:** if `build_registry_entry` / the merge step is skipped
  entirely (simulating "the reconciliation logic is absent"), the new
  registry's `entries` list still has exactly 1 item and does not contain
  `"bbb"` — i.e. re-running H010's own detection predicate
  (`all_ids - registered`) against this un-merged registry still reports
  `"bbb"` as missing, proving the test's positive assertions above are
  specifically detecting the merge having happened.

**Companion negative case:** a second synthetic handoff file missing
`from_agent` (one of the 7 required fields) must produce
`build_registry_entry(...) is None`, and the merge step must record it under
the "H010 skipped — missing required field" bucket (§3.3) naming
`from_agent` as the absent field, and must NOT add any entry (not even a
partial one) to the registry for that file.

### 9.4 TS-H006-01 — unambiguous renames apply; CONDITIONAL never does

**Fixture:** three synthetic `result.status` values: `"FAILED"`,
`"PARTIAL_PASS"`, `"CONDITIONAL"`.

**Run:** `fix_h006(value)` for each.

**Assertions:**
- `fix_h006("FAILED") == "FAIL"`.
- `fix_h006("PARTIAL_PASS") == "PARTIAL"`.
- `fix_h006("CONDITIONAL") is None`.
- `fix_h006("PASS") is None` (already-legal values are untouched, not
  routed through the rename table).
- **Mutation check:** if `H006_SAFE_RENAMES` is (incorrectly) extended with
  a third entry `"CONDITIONAL": "PARTIAL"` (simulating "the exclusion logic
  was removed and someone guessed a mapping"), this exact test's third
  assertion (`fix_h006("CONDITIONAL") is None`) fails — proving the test
  actually pins the exclusion, not merely the two inclusions.

### 9.5 TS-H001-ENC-01 — accept only when both gates pass; byte-diff gate is load-bearing

**Fixture A (should be accepted):** a small synthetic JSON handoff whose
`task.description` value contains the exact byte sequence produced by
cp1252 byte `0x93` (left double quote) misread as UTF-8 — i.e. construct
`raw` by taking a valid-JSON template, encoding the human-readable text with
one curly quote via `"...".encode("cp1252")`, and using that as the "on
disk" bytes (this fixture-construction step deliberately inverts the
real-world corruption direction to build a synthetic instance of it,
consistent with how a PowerShell console actually produced the real files).

**Fixture B (should be rejected — structural, not encoding):** a synthetic
file with a genuine bracket typo (`]` in place of `}`) that does NOT parse
under cp1252-decode-then-utf8-reencode either (because the defect is
delimiter placement, not character encoding).

**Fixture C (should be rejected — byte-diff gate catches an extra change):**
a synthetic file constructed so that `raw.decode("cp1252").encode("utf-8")`
happens to also alter one byte outside the known-corruption table (e.g. by
prepending an unrelated ASCII byte difference) — simulating "gate (a) would
pass but gate (b) must still reject it."

**Run:** `try_fix_h001_encoding(raw)` on each fixture.

**Assertions:**
- Fixture A: return value is not `None`; `json.loads` of the returned bytes
  succeeds; the *only* differing byte range versus the original, per
  `_only_known_corruption_bytes_differ`, is the curly-quote sequence.
- Fixture B: return value is `None` (gate (a) fails — still doesn't parse
  after cp1252 fallback).
- Fixture C: return value is `None` (gate (a) may pass, but gate (b) must
  reject due to the extra, non-cataloged difference).
- **Mutation check:** if gate (b) (`_only_known_corruption_bytes_differ`) is
  removed and `try_fix_h001_encoding` accepts on gate (a) alone, Fixture C
  is incorrectly accepted (returns non-`None`) — proving the test
  specifically exercises the byte-diff gate's rejection power, not just
  "some fixture gets accepted, some doesn't."

### 9.6 Idempotency check (cross-category, run after any single-category test)

**Run:** apply each of the four transformation functions (`fix_h002`,
`fix_h008`, `fix_h006`, and the H010 merge step) a second time to their own
already-fixed output.

**Assertions:**
- `fix_h002` on an already-unwrapped `result` (already a `dict`): the
  detection predicate (`isinstance(result, str)`) is `False`, so the
  category's file-selection step (not `fix_h002` itself, which is never
  called on a non-candidate) does not select this file on a second pass —
  tested by asserting the *selection* predicate, not by calling
  `fix_h002` on a dict and checking it errors.
- `fix_h008` on already-BOM-free bytes: same pattern, the BOM-presence
  predicate is `False` on the second pass.
- `fix_h006` on an already-renamed `"FAIL"`: `fix_h006("FAIL") is None`
  (not in the rename table — already legal).
  H010 merge step on a registry that already contains `"bbb"`:
  `build_registry_entry` still succeeds (it does not consult the registry),
  but the merge step's own "already present, skip" check (based on
  `handoff_id in registered`, mirroring `lint_registry`'s set-difference)
  produces zero new entries on the second run.

---

## 10. Summary of files touched by this design

- **New:** `tools/repair_handoff_bookkeeping.py` (the repair script itself,
  including its `selftest` subcommand covering §9).
- **Modified (by running the script under `--apply`, not by hand-editing):**
  up to 9 files under `handoffs/WF02-iss105-token-model-schema-20260611/`
  (H002), up to 88 files corpus-wide (H008), `handoffs/registry.json` (H010,
  single additive rewrite), up to 3 files corpus-wide for the 2 unambiguous
  H006 renames (a file may carry both a top-level and nested `status` hit,
  still one file), up to ~7 files corpus-wide (H001-encoding-subset,
  possibly fewer if the byte-diff gate rejects some).
- **Not modified by this script, ever:** any file matching only an
  out-of-scope category (§8); `handoffs/orchestrator.log`;
  `handoffs/escalations.json`; any `estimation.json`.
