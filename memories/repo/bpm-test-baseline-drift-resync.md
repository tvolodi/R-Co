# BPM Platform: test-baseline-drift resync workflow

When the GH-512 regression-test infrastructure drifts from main (recurrence class GH-653,
GH-701, GH-759), the fix is mechanical and applies to exactly three test-infra files. No
src/ changes, no schema, no API surface.

## Three files to edit

1. **`tests/integration/gh512_t010_regression_test.zig`**
   - Doc-comment block above `const t010_blocker_ceiling: u32 = N;`
   - The constant itself: bump to current T010 BLOCKER count.

2. **`tests/specs/fixtures/gh512-baseline-snapshot.json`**
   - `snapshot_version`: bump 4 → 5 etc.
   - `captured_at`: refresh to UTC stamp from `python tools/utcnow.py`.
   - `captured_by`: name the resolving WF + ISS.
   - `expected.total_issues`: bump to current live total.
   - `expected.by_severity.BLOCKER`: bump.
   - `expected.by_code.T010`: bump.
   - `expected.platform_admin_uuid_count`: bump.
   - Add a `<version>_addendum` field mirroring the existing v3/v4 addendum structure
     (rationale + verified_by).
   - `regression_policy.t010_blocker_ceiling`: bump.
   - `regression_policy.notes`: refresh the numbers.
   - `regression_policy.t010_blocker_ceiling_history`: append a new entry for the
     drift-introducing commit.

3. **`tools/lint_test_isolation.baseline.json`**
   - Preamble: `regenerated_by`, `regeneration_note`, `last_line_sync` → refresh.
   - `issues` array: usually unchanged (the baseline file is internally consistent).
     BUT every test-infra edit may shift line numbers in the test file, so the
     linter may flag a single line-drift mismatch — fix that one entry's `line`.

## Critical verification

```bash
python tools/lint_test_isolation.py --no-baseline --json tests/integration > scratch/live_scan.json 2>&1
python -c "
import json
with open('scratch/live_scan.json','rb') as f: live=json.loads(f.read().decode('utf-16'))  # PowerShell redirects use UTF-16!
with open('tools/lint_test_isolation.baseline.json','rb') as f: base=json.loads(f.read().decode('utf-8-sig'))
def key(x): return (x['severity'],x['code'],x['file'],x['message'])
live_keys={key(x):x['line'] for x in live['issues']}
base_keys={key(x):x['line'] for x in base['issues']}
print('only_base:',len(set(base_keys)-set(live_keys)))
print('only_live:',len(set(live_keys)-set(base_keys)))
print('line_drift:',[(k,base_keys[k],live_keys[k]) for k in set(base_keys)&set(live_keys) if base_keys[k]!=live_keys[k]])
"
python tools/lint_test_isolation.py  # must exit 0
python tools/lint_handoffs.py  # must exit 0
```

## Common trap: PowerShell redirect produces UTF-16 output

`python tools/lint_test_isolation.py --no-baseline --json ... > scratch/live_scan.json`
on Windows PowerShell writes the JSON as UTF-16 LE (`ff fe` BOM), not UTF-8. Always
read back with `f.read().decode('utf-16')`, NOT `utf-8` / `utf-8-sig`.

## Line-drift after self-edit

Editing the .zig test file's doc-comment adds lines, which shifts the platform-admin UUID
RETAIN entry in the SAME file. So the baseline.json entry for that file's line number
also needs to be bumped (e.g. 337 → 342 after a +5 doc-comment expansion). Diff
baseline.json issues array against a fresh --no-baseline scan to find these.

## Handoff write conventions

- BOM-tolerant read (`utf-8-sig`).
- Write `utf-8` (NO BOM) — `lint_handoffs.py` rejects BOMs.
- Preserve CRLF + no trailing newline (matches existing file convention).
- Use Python `json.dumps(..., indent=2, ensure_ascii=False)` then replace `\n` with `\r\n`.
