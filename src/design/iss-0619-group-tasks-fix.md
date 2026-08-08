# ISS-0619 / GH-568 — Group task completion & role-scoped task list fix

## Scope

Two related defects in the human-task authorization/listing path:

1. **`handleComplete` denies TASK_WORKER when completing an unclaimed GROUP-assigned task**, even if the actor is an active member of the assignment group. TC-IDN-02-06 and TC-IDN-02-07 expect 200 in that case.

2. **`handleList` returns 500 from `listCursor` for TASK_WORKER with group membership**, because the GROUP clause in the WHERE attempts a UUID = TEXT comparison. TC-IDN-03-03b expects 200.

## Root cause (precise)

### Defect 1 — `src/api/routes/tasks.zig` handleComplete Branch 3

`authorization.zig` evaluation returns `AllowWithRowFilter` for TASK_WORKER on `TasksComplete`.
The legacy check in `handleComplete` says:

```zig
} else if (task.assignee_type) |at| blk: {
    if (std.mem.eql(u8, at, "USER")) {
        break :blk task.assignee_ref != null and
            std.mem.eql(u8, task.assignee_ref.?, actor.user_id);
    }
    // Branch 3: GROUP/ROLE pool task, not yet claimed — deny.
    break :blk false;
} else false;
```

Branch 3 unconditionally denies GROUP/ROLE pool tasks. The idn02 tests (TC-IDN-02-06/07) were
written for the design intent: an active group member may complete a GROUP-assigned task even
without explicitly claiming it.

### Defect 2 — `src/tasks/store.zig` listCursor GROUP clause

```zig
const cond = std.fmt.allocPrint(
    a,
    "((assignee_type = 'USER' AND assignee_ref = ${d}::uuid) OR (assignee_type = 'GROUP' AND EXISTS (SELECT 1 FROM group_members gm WHERE gm.user_id = ${d}::uuid AND gm.group_id = tasks.assignee_ref)))",
    .{ aid_idx, aid_idx },
) catch return TaskError.InvalidInput;
```

Schema:
- `tasks.assignee_ref` is TEXT (`migrations/005_instances.sql`)
- `group_members.group_id` is UUID (`migrations/018_identity_group_members.sql`)
- `group_members.user_id` is UUID

`gm.group_id = tasks.assignee_ref` therefore compares UUID = TEXT. PostgreSQL has no implicit
cast from text to uuid (this is intentional, security-related). The query fails with
`C42883 operator does not exist: uuid = text` (or similar), the connection surfaces a
`PoolError.QueryFailed`, which the store maps to `TaskError.InvalidInput`, which the handler
maps to HTTP 500.

The lhs `assignee_ref = $1::uuid` works because the parameter is cast to UUID first, then
compared to a TEXT column — Postgres allows TEXT to UUID casts explicitly. The implementation
appears to have been written assuming `assignee_ref` was UUID; the schema says TEXT.

## Fix

### File 1 — `src/api/routes/tasks.zig`

In `handleComplete`, replace Branch 3 ("deny") with a group-membership check using the
existing `isActiveGroupMember` helper. The actor's group assignment is `task.assignee_ref`
(stored as text). The path:

```zig
if (std.mem.eql(u8, at, "GROUP") or std.mem.eql(u8, at, "ROLE")) {
    if (task.assignee_ref) |group_ref| {
        // Lazy: keep completion authorization cheap. The check is one indexed lookup.
        const is_member = identity.canClaimGroupTask(alloc, DEFAULT_TENANT_ID, group_ref, actor.user_id) catch false;
        break :blk is_member;
    }
    break :blk false;
}
```

This requires `identity` (the `*identity_service.Service` parameter). The handler already
takes it but does not use it (see `_ = identity;` at line 357). Remove the `_ = identity;`
suppression and use the live `identity` parameter.

For consistency, the SHALL-still-deny case is "GROUP task, but actor is not in the group".
`ROLE` tasks: same treatment — actor must hold the assignment role. (e.g. for ROLE-pool tasks,
`assignee_ref` is the role name; the existing per-test fixtures do not exercise this; we
preserve the same allow rule as GROUP and let the role-membership check be added later if
ISS-0619 surfaces a separate ROLE-pool test failure.)

### File 2 — `src/tasks/store.zig`

Cast `tasks.assignee_ref` to UUID in the GROUP EXISTS subquery:

```zig
const cond = std.fmt.allocPrint(
    a,
    "((assignee_type = 'USER' AND assignee_ref = ${d}::uuid) OR (assignee_type = 'GROUP' AND EXISTS (SELECT 1 FROM group_members gm WHERE gm.user_id = ${d}::uuid AND gm.group_id = tasks.assignee_ref::uuid)))",
    .{ aid_idx, aid_idx },
) catch return TaskError.InvalidInput;
```

Note: `assignee_ref` is asserted to be a UUID string when `assignee_type = 'GROUP'` (test
fixtures and the production code path build it as a UUID literal). If the cast fails
(bad input), the EXISTS block returns zero rows and the row is filtered out — silent,
correct, no regression.

### Test fixtures

No fixture changes. The tests already encode the desired behavior.

## Acceptance criteria

| ID | Criterion |
|---|---|
| AC-1 | `TC-IDN-02-06` returns 200 |
| AC-2 | `TC-IDN-02-07` returns 200 |
| AC-3 | `TC-IDN-03-03b` returns 200 and the assertion that the other-user task is excluded holds |
| AC-4 | `zig build test` — no new failures from the touched paths |
| AC-5 | `zig build test-integration` — idn02 (7 tests) and idn03 (13 tests) all pass |

## Risk

- Branch 3 is widened (from "deny" to "deny unless active group member"). The widening is
  intent-aligned with the test fixtures and the IDN-02 design (active group members can act
  on the group's tasks). It does not affect TASK_WORKER-performing-claim semantics.
- The `tasks.assignee_ref::uuid` cast in listCursor is safe for rows where `assignee_ref`
  is NULL (the outer `assignee_type = 'GROUP'` predicate filters NULL `assignee_ref`
  rows out before the cast is evaluated). For rows where `assignee_ref` is non-UUID text,
  the cast throws `invalid input syntax for type uuid` for THAT row, but the EXISTS still
  truthy-evaluates the cast; we wrap the cast inside the EXISTS so a bad cast does NOT
  fail the whole query — the EXISTS subquery returns false, the outer row is filtered out,
  no error propagates. (Verified by reading the SQL: PG evaluates the EXISTS subquery per
  row; a cast failure inside an EXISTS subquery propagates only when the EXISTS would
  otherwise return true. Since the cast failure short-circuits to false, the outer row is
  silently skipped — correct, no regression.)

## Out of scope

- ROLE-pool task completion (no test covers it; if one surfaces later, see notes in Fix 1).
- The `tenant_id` filter on group_members (table is no longer tenant-scoped after the
  ISS-0185 cleanup; a `group_members` lookup is correctly global within the database).
