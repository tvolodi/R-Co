# BPM DOC-UPDATER: surgical edits to issue_index.json

## The trap

`docs/issues/issue_index.json` is the canonical ISS registry. It mixes:
- Style 1 — non-ASCII Unicode (em-dash `—`, en-dash `–`) stored as **literal escape sequences** (`\u2014`, `\u2013`)
- Style 2 — non-ASCII stored as **raw UTF-8 bytes** (e.g. `\u2014` literally encoded)
- Line endings: CRLF (Windows repo, autocrlf enabled) — Git will warn "LF will be replaced by CRLF" on every save
- 147+ entries, ~115KB — full `json.dump` re-serialization churns the entire file

## The fix pattern (verified WF03-GH759-20260813)

Use **surgical regex replacement** on the raw bytes/text, not `json.dump`. This preserves the `\u2014` escape style AND keeps line-ending handling under your control.

```python
import re
nl = "\r\n" if "\r\n" in text else "\n"
# 1. Bump counters at top (last_updated, next_issue_id)
text = re.sub(r'("next_issue_id"\s*:\s*)212', r'\g<1>697', text, count=1)
text = re.sub(r'("last_updated"\s*:\s*)"[0-9T:\-]+Z"',
              rf'\1"{RESOLVED_AT}"', text, count=1)
# 2. Append new entry before closing "  ]\n}"
text = text.replace("  ]" + nl + "}", "," + nl + new_entry + "  ]" + nl + "}", 1)
# 3. Flip status REGISTERED -> RESOLVED on specific entry by id
m = re.search(r'(\{\s*"id"\s*:\s*"ISS-0697"[^}]*?"status"\s*:\s*)"REGISTERED"(\s*,[^}]*?\n\s*\})', text, re.DOTALL)
inner = m.group(2)[:-len("\n    }")].rstrip(",")  # strip closing brace, strip trailing comma
text = text[:m.start()] + m.group(1) + '"RESOLVED"' + inner + ',\n      "resolved_at": "...",\n    }' + text[m.end():]
# 4. Write with utf-8 (no BOM), no ensure_ascii re-encode
open(PATH, "wb").write(text.encode("utf-8"))
# 5. Smoke-check: json.loads(text) must succeed; ISS-0697 status must be RESOLVED
```

## Why json.dump fails here

`json.dump(obj, f, ensure_ascii=False)` will write non-ASCII as raw UTF-8 bytes — but the existing file may have stored them as escape sequences (`\u2014`). The result is a massive noise diff of `~12 \u2014 -> —` lines that pollutes the commit. With `ensure_ascii=True` (default), it re-escapes all non-ASCII, churning the file the other direction. **Neither flag matches the original file's mixed convention.** Surgical regex replacement sidesteps the problem entirely.

## File ending on Windows

The file ends with `\r\n` (CRLF) after the final `}` — but the `}` itself has no trailing newline in some save cycles. Use `text.rstrip("\r\n")` then `rstrip("\n")` to handle either case before locating `  ]\n}`.

## Three-step JSON regex trap

If your regex captures `\n    }` as part of the matched group and you do `rstrip("}")` then re-add `}`, you may end up with `,` outside the object (`},\n    ,\n      "new_field"`) — invalid JSON. Capture the **whole entry including closing brace**; strip both the brace AND any trailing comma; then re-add `}` cleanly at the end.

## Diff size, verified

Re-serializing the full file (json.dump) → 50 +/- lines diff, 12 of them noise
(`\u2014` <-> `—`).
Surgical edit → 22 +/- lines, 1 noise line (the appended new entry's title).