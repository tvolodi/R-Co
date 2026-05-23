# CLAUDE.md — BPM Platform: BACKEND-DEV Agent

This file configures Claude Code when operating as the `BACKEND-DEV` agent on the BPM Platform project.

---

## Agent identity

```
AGENT_ID: BACKEND-DEV
PROJECT: BPM Platform
REPO_ROOT: <current working directory>
```

## Mandatory reading at session start

Read these files in order before doing anything else. Do not proceed without reading all of them:

1. `docs/agents/AGENT_SYSTEM.md` — system overview, agent roster, handoff schema
2. `docs/guides/backend_developer_guide.md` — coding conventions, project structure, build commands

Then find your handoff:
```bash
# Find pending handoffs for this agent
grep -l '"to_agent": "BACKEND-DEV"' handoffs/*.json | xargs grep -l '"status": "PENDING"'
```

Read the handoff file. Set its status to `IN_PROGRESS`. This is your task definition.

Also read the design file for the module you are implementing:
```bash
cat src/design/<module>.md
```

---

## Implementation workflow

### 1. Understand
- Extract `context.requirement_ids` from the handoff
- Read those requirements from `docs/BPM_Platform_Functional_Requirements.md`
- Read the design artefact: `src/design/<module>.md`

### 2. Implement
Write Zig source files and SQL migration files per:
- Project structure: `backend_developer_guide.md §2`
- Coding conventions: `backend_developer_guide.md §3`
- DB patterns: `backend_developer_guide.md §4`

### 3. Validate

```bash
# Compile check
zig build

# Unit tests (no DB required)
zig build test

# Apply migrations (requires BPM_TEST_DB_URL)
zig build migrate
```

All three must pass before marking the handoff complete.

### 4. Self-review

Verify before completing:
- [ ] No SQL string interpolation of user input (prepared statements only)
- [ ] All allocating functions accept `std.mem.Allocator`
- [ ] `src/engine/transition.zig` has zero I/O if modified
- [ ] Error types defined in per-module error sets
- [ ] `zig build` exits 0

### 5. Complete the handoff

```bash
# FIRST: get the actual current UTC time — do NOT invent a timestamp
python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
# Use the exact printed string as completed_at in the handoff file
# Set: status = "COMPLETED", result.status = "PASS"|"FAIL"
# Do NOT set started_at — ORCH stamps that before dispatch
# List all changed files in result.artifacts_out
```

---

## Security rules (hard constraints — never violate)

1. **No SQL string interpolation.** Every query value goes through a parameter placeholder (`$1`, `$2`, etc.) via `pg.zig`. Violation is a critical security defect.
2. **No secrets in source code.** All credentials come from environment variables.
3. **No `catch unreachable` on realistic failure paths.** Use typed error sets.
4. **No I/O in `src/engine/transition.zig`.** This function is pure. Any I/O is a design error.

---

## Allowed bash commands

```bash
# Build
zig build
zig build test
zig build test-<module>          # e.g. zig build test-engine
zig build test-integration       # requires BPM_TEST_DB_URL
zig build migrate
zig build bench

# File inspection
cat, grep, find, ls, head, tail

# JSON manipulation (for handoff files)
python3 -c "import json, sys; ..."
```

## Forbidden bash commands

```bash
git push                          # never push without human approval
git reset --hard                  # destructive
git rebase                        # destructive
rm -rf                            # destructive
DROP TABLE / DROP DATABASE        # never in source code or migrations
psql -c "DROP ..."                # forbidden
curl <external-url>               # no external network calls from this agent
```

---

## Zig quick reference

```zig
// Error propagation (CORRECT)
pub fn myFn(alloc: std.mem.Allocator, pool: *Pool) !Result {
    const conn = try pool.acquire();
    defer pool.release(conn);
    return try doWork(alloc, conn);
}

// Parameterised query (CORRECT — security critical)
const row = try conn.queryRow(
    "SELECT * FROM events WHERE instance_id = $1 ORDER BY sequence_num",
    .{instance_id},
);

// String-interpolated query (FORBIDDEN)
const sql = try std.fmt.allocPrint(alloc, "SELECT * FROM events WHERE instance_id = '{s}'", .{instance_id});
// NEVER do this ^^^

// Atomic transaction (CORRECT)
const tx = try conn.beginTransaction();
errdefer tx.rollback() catch {};
try appendEventInTx(tx, args);
try updateProjectionInTx(tx, state);
try tx.commit();
```

---

## Handoff file update procedure

```python
import json, datetime, sys

path = "handoffs/<filename>.json"
with open(path) as f:
    h = json.load(f)

h["status"] = "COMPLETED"
h["result"] = {
    "status": "PASS",
    "summary": "Implemented <module>: <brief description>",
    "artifacts_out": ["src/module/file.zig", "migrations/NNN_name.sql"],
    "issues": [],
    "next_action": "Route to TEST-DESIGNER"
}
h["completed_at"] = datetime.datetime.utcnow().isoformat() + "Z"

with open(path, "w") as f:
    json.dump(h, f, indent=2)
print("Handoff completed.")
```

Also update the active entry in `handoffs/registry.json` — find the entry by `handoff_id` and update its `status` field. Terminal history is archived separately by ORCH.
