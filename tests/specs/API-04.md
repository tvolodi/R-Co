# Test Spec: API-04 — Task operations

**Requirement:** API-04 — The API SHALL expose: `GET /tasks` (list, filterable by assignee/status/instance), `GET /tasks/:id`, `POST /tasks/:id/complete`, `POST /tasks/:id/assign`, `POST /tasks/:id/reassign`.  
**Priority:** MUST  
**Test layer:** unit, integration  
**Related specs:** EE-03 (task creation), EE-04 (completion logic), API-06 (pagination)  
**Design reference:** `src/design/api-04-task-operations.md`

---

## Test Cases Summary

| Test Case ID | Endpoint | Description | Layer |
|---|---|---|---|
| TC-API-04-01 | GET /tasks | page_size=0 → HTTP 422 INVALID_PAGE_SIZE | unit |
| TC-API-04-02 | GET /tasks | page_size=201 → HTTP 422 INVALID_PAGE_SIZE | unit |
| TC-API-04-03 | GET /tasks | Malformed base64url cursor → HTTP 422 INVALID_CURSOR | unit |
| TC-API-04-04 | GET /tasks | Cursor with wrong endpoint prefix → HTTP 422 INVALID_CURSOR | unit |
| TC-API-04-05 | GET /tasks | Expired cursor (>24h old) → HTTP 410 CURSOR_EXPIRED | integration |
| TC-API-04-06 | GET /tasks | Cursor from /instances endpoint → HTTP 422 INVALID_CURSOR | unit |
| TC-API-04-07 | GET /tasks | Cursor navigation — second page returns items after first page | integration |
| TC-API-04-08 | GET /tasks | Invalid status value → HTTP 422 INVALID_STATUS | unit |
| TC-API-04-09 | GET /tasks | status=PENDING filter returns only PENDING tasks | integration |
| TC-API-04-10 | GET /tasks | status=COMPLETED filter returns only COMPLETED tasks | integration |
| TC-API-04-11 | GET /tasks | status=CANCELLED filter returns only CANCELLED tasks | integration |
| TC-API-04-12 | GET /tasks | assignee_id filter returns only tasks for that user | integration |
| TC-API-04-13 | GET /tasks | instance_id filter returns only tasks for that instance | integration |
| TC-API-04-14 | GET /tasks | Invalid instance_id UUID format → HTTP 422 INVALID_INSTANCE_ID | unit |
| TC-API-04-15 | GET /tasks | Combined assignee_id + status filters narrow results | integration |
| TC-API-04-16 | GET /tasks | TASK_WORKER sees only own tasks (row-level restriction) | integration |
| TC-API-04-17 | GET /tasks | TASK_WORKER with assignee_id=other user → HTTP 200 empty items | integration |
| TC-API-04-18 | GET /tasks | PROCESS_OPERATOR sees all tasks across all users | integration |
| TC-API-04-19 | GET /tasks | Empty result → HTTP 200, items=[], next_cursor=null | integration |
| TC-API-04-20 | GET /tasks | Last page has no next_cursor | integration |
| TC-API-04-21 | GET /tasks/:id | Success — returns full task detail | integration |
| TC-API-04-22 | GET /tasks/:id | Task not found → HTTP 404 TASK_NOT_FOUND | integration |
| TC-API-04-23 | GET /tasks/:id | Malformed task_id (not UUID) → HTTP 422 INVALID_TASK_ID | unit |
| TC-API-04-31 | POST .../complete | PROCESS_OPERATOR completes a PENDING task → HTTP 200 | integration |
| TC-API-04-32 | POST .../complete | TASK_WORKER completes own assigned task → HTTP 200 | integration |
| TC-API-04-33 | POST .../complete | Already-COMPLETED task → HTTP 409 TASK_ALREADY_TERMINATED | integration |
| TC-API-04-34 | POST .../complete | CANCELLED task → HTTP 409 TASK_ALREADY_TERMINATED | integration |
| TC-API-04-35 | POST .../complete | TASK_WORKER completes another user's task → HTTP 403 FORBIDDEN | integration |
| TC-API-04-36 | POST .../complete | TASK_WORKER completes GROUP-assigned task → HTTP 403 FORBIDDEN | integration |
| TC-API-04-37 | POST .../complete | Malformed task_id → HTTP 422 INVALID_TASK_ID | unit |
| TC-API-04-38 | POST .../complete | output_variables=null → HTTP 422 INVALID_INPUT | integration |
| TC-API-04-39 | POST .../complete | output_variables is JSON array → HTTP 422 INVALID_INPUT | integration |
| TC-API-04-40 | POST .../complete | Non-existent task_id → HTTP 404 TASK_NOT_FOUND | integration |
| TC-API-04-41 | POST .../assign | PROCESS_OPERATOR assigns unassigned task → HTTP 200 | integration |
| TC-API-04-42 | POST .../assign | Task already assigned → HTTP 409 TASK_ALREADY_ASSIGNED | integration |
| TC-API-04-43 | POST .../assign | TASK_WORKER caller → HTTP 403 FORBIDDEN | unit |
| TC-API-04-44 | POST .../assign | Non-existent task_id → HTTP 404 TASK_NOT_FOUND | integration |
| TC-API-04-45 | POST .../assign | user_id missing from body → HTTP 422 INVALID_INPUT | unit |
| TC-API-04-46 | POST .../assign | user_id empty string → HTTP 422 INVALID_INPUT | unit |
| TC-API-04-47 | POST .../assign | Task not PENDING (completed/cancelled) → HTTP 409 TASK_ALREADY_TERMINATED | integration |
| TC-API-04-51 | POST .../reassign | PROCESS_OPERATOR reassigns assigned task → HTTP 200 | integration |
| TC-API-04-52 | POST .../reassign | Task is unassigned → HTTP 409 TASK_NOT_ASSIGNED | integration |
| TC-API-04-53 | POST .../reassign | TASK_WORKER caller → HTTP 403 FORBIDDEN | unit |
| TC-API-04-54 | POST .../reassign | Non-existent task_id → HTTP 404 TASK_NOT_FOUND | integration |
| TC-API-04-55 | POST .../reassign | user_id missing from body → HTTP 422 INVALID_INPUT | unit |
| TC-API-04-56 | POST .../reassign | user_id empty string → HTTP 422 INVALID_INPUT | unit |
| TC-API-04-57 | POST .../reassign | Task not PENDING (completed/cancelled) → HTTP 409 TASK_ALREADY_TERMINATED | integration |

**Cross-reference note:** TC-API-04-01 through TC-API-04-04 supersede the earlier EE-03 unit tests TC-EE-03-API-01 through TC-EE-03-API-04, which tested the old offset/limit handler. The API-04 handler uses cursor pagination; these new test cases cover the same validation paths for the updated `handleList`. TC-EE-04-08 (malformed task_id for complete) is repeated as TC-API-04-37 with the same assertion.

---

## Group 1: GET /tasks — Pagination

### TC-API-04-01: page_size=0 → HTTP 422 INVALID_PAGE_SIZE

**Preconditions:** None — validation fires before any store access.

**Input:**  
`GET /api/v1/tasks?page_size=0`  
Actor: PROCESS_OPERATOR (is_operator_or_above=true)

**Expected result:**
- HTTP 422.
- Response body: RFC 9457 Problem Details with `"error": "INVALID_PAGE_SIZE"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC1 (list, paginated); API-06 (N ≤ 0 rejected with HTTP 422).

---

### TC-API-04-02: page_size=201 → HTTP 422 INVALID_PAGE_SIZE

**Preconditions:** None.

**Input:**  
`GET /api/v1/tasks?page_size=201`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_PAGE_SIZE"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-06 (N > 200 rejected with HTTP 422).

---

### TC-API-04-03: Malformed base64url cursor → HTTP 422 INVALID_CURSOR

**Preconditions:** None.

**Input:**  
`GET /api/v1/tasks?cursor=!!!`  
Actor: PROCESS_OPERATOR  
`page_size`: 50 (default)

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_CURSOR"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC1; API-06 (cursor is opaque; malformed cursor yields 422).

---

### TC-API-04-04: Cursor with wrong endpoint prefix → HTTP 422 INVALID_CURSOR

**Preconditions:** None.

**Input:**  
Cursor whose base64url decoding yields `"I:<timestamp>:<uuid>"` (the instance-list prefix) instead of `"T:<timestamp>:<uuid>"`.  
`GET /api/v1/tasks?cursor=<instance-cursor>`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_CURSOR"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-06 ("A cursor from one endpoint MUST NOT be usable on a different endpoint").

---

### TC-API-04-05: Expired cursor (>24 hours old) → HTTP 410 CURSOR_EXPIRED

**Preconditions:**
- A cursor was produced by a previous `GET /tasks` response more than 24 hours ago (cursor's embedded `created_at_us` is >86,400,000,000 µs before `now`).

**Input:**  
`GET /api/v1/tasks?cursor=<expired-cursor>`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 410.
- Response body contains `"error": "CURSOR_EXPIRED"`.
- Body includes guidance to start a fresh query without a cursor.

**Layer:** integration  
**Acceptance criterion mapped:** API-06 ("Cursors expire 24 hours after creation. An expired cursor returns HTTP 410").

---

### TC-API-04-06: Cursor from /instances endpoint → HTTP 422 INVALID_CURSOR

**Preconditions:**
- A valid cursor `C_inst` was obtained from `GET /instances`.

**Input:**  
`GET /api/v1/tasks?cursor=<C_inst>`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_CURSOR"`.

**Layer:** unit  
**Note:** The /instances cursor uses the `"I:"` prefix; the /tasks handler must reject any cursor not starting with `"T:"`.  
**Acceptance criterion mapped:** API-06 cross-endpoint cursor isolation.

---

### TC-API-04-07: Cursor navigation — second page follows first page

**Preconditions:**
- 5 tasks exist for instance `I1`, all PENDING, created in known order.
- No other tasks exist.

**Input — Page 1:**  
`GET /api/v1/tasks?page_size=3`  
Actor: PROCESS_OPERATOR

**Expected result — Page 1:**
- HTTP 200.
- `items` has 3 entries (the 3 most recently created tasks).
- `next_cursor` is a non-null opaque string.
- `count` = 3.

**Input — Page 2:**  
`GET /api/v1/tasks?page_size=3&cursor=<next_cursor from page 1>`  
Actor: PROCESS_OPERATOR (same actor)

**Expected result — Page 2:**
- HTTP 200.
- `items` has 2 entries (the 2 remaining tasks, in `created_at DESC` order).
- `next_cursor` is null (last page).
- `count` = 2.
- The union of items from page 1 and page 2 equals the full set of 5 tasks, with no duplicates.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 (paginated); API-06 (cursor navigation, last-page null cursor).

---

## Group 1: GET /tasks — Filters

### TC-API-04-08: Invalid status value → HTTP 422 INVALID_STATUS

**Preconditions:** None.

**Input:**  
`GET /api/v1/tasks?status=RUNNING`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_STATUS"`.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC1 (filterable by status); API-07 (invalid field → HTTP 422).

---

### TC-API-04-09: status=PENDING filter returns only PENDING tasks

**Preconditions:**
- Instance `I1` has 2 PENDING tasks (`T1`, `T2`) and 1 COMPLETED task (`T3`).

**Input:**  
`GET /api/v1/tasks?status=PENDING`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains `T1` and `T2`; `T3` is absent.
- `count` = 2.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 (filterable by status).

---

### TC-API-04-10: status=COMPLETED filter returns only COMPLETED tasks

**Preconditions:**
- 1 PENDING task (`T1`) and 2 COMPLETED tasks (`T2`, `T3`) exist.

**Input:**  
`GET /api/v1/tasks?status=COMPLETED`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains `T2` and `T3`; `T1` is absent.
- `count` = 2.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1.

---

### TC-API-04-11: status=CANCELLED filter returns only CANCELLED tasks

**Preconditions:**
- 1 PENDING task (`T1`) and 1 CANCELLED task (`T2`) exist.

**Input:**  
`GET /api/v1/tasks?status=CANCELLED`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains only `T2`.
- `count` = 1.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1.

---

### TC-API-04-12: assignee_id filter returns only tasks assigned to that user

**Preconditions:**
- Task `T1`: assignee_type=USER, assignee_ref=`alice`.
- Task `T2`: assignee_type=USER, assignee_ref=`bob`.
- Task `T3`: unassigned.

**Input:**  
`GET /api/v1/tasks?assignee_id=alice`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains only `T1`.
- `count` = 1.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 (filterable by assignee_id).

---

### TC-API-04-13: instance_id filter returns only tasks for that instance

**Preconditions:**
- Instance `I1` has tasks `T1`, `T2`.
- Instance `I2` has task `T3`.

**Input:**  
`GET /api/v1/tasks?instance_id=<I1-uuid>`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains `T1` and `T2`; `T3` is absent.
- `count` = 2.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 (filterable by instance_id).

---

### TC-API-04-14: Invalid instance_id UUID format → HTTP 422 INVALID_INSTANCE_ID

**Preconditions:** None.

**Input:**  
`GET /api/v1/tasks?instance_id=not-a-uuid`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INSTANCE_ID"`.

**Layer:** unit  
**Acceptance criterion mapped:** API-07 (invalid field → HTTP 422).

---

### TC-API-04-15: Combined assignee_id + status filters narrow results

**Preconditions:**
- Task `T1`: assignee=`alice`, status=PENDING.
- Task `T2`: assignee=`alice`, status=COMPLETED.
- Task `T3`: assignee=`bob`, status=PENDING.

**Input:**  
`GET /api/v1/tasks?assignee_id=alice&status=PENDING`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` contains only `T1`.
- `count` = 1.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 (filterable by assignee_id, status — combined).

---

## Group 1: GET /tasks — Role-based visibility

### TC-API-04-16: TASK_WORKER sees only own tasks

**Preconditions:**
- Task `T1`: assignee_type=USER, assignee_ref=`alice` (TASK_WORKER caller).
- Task `T2`: assignee_type=USER, assignee_ref=`bob`.
- Task `T3`: unassigned.

**Input:**  
`GET /api/v1/tasks`  
Actor: TASK_WORKER with user_id=`alice` (is_operator_or_above=false)

**Expected result:**
- HTTP 200.
- `items` contains only `T1`.
- `T2` and `T3` are absent regardless of any assignee_id filter.
- `count` = 1.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 ("TASK_WORKER sees only their own tasks").

---

### TC-API-04-17: TASK_WORKER with assignee_id=other user → HTTP 200 empty items

**Preconditions:**
- Task `T1`: assignee_type=USER, assignee_ref=`bob`.
- Caller is TASK_WORKER with user_id=`alice`.

**Input:**  
`GET /api/v1/tasks?assignee_id=bob`  
Actor: TASK_WORKER, user_id=`alice`

**Expected result:**
- HTTP 200.
- `items` = [] (empty).
- `next_cursor` = null.
- `count` = 0.
- No 403 or 422 is returned; the result is silently empty because a TASK_WORKER can never see another user's tasks.

**Layer:** integration  
**Acceptance criterion mapped:** Design doc §2.4 (TASK_WORKER + assignee_id ≠ actor.user_id → empty result, not an error).

---

### TC-API-04-18: PROCESS_OPERATOR sees all tasks

**Preconditions:**
- Task `T1`: assignee=`alice`.
- Task `T2`: assignee=`bob`.
- Task `T3`: unassigned.

**Input:**  
`GET /api/v1/tasks`  
Actor: PROCESS_OPERATOR (is_operator_or_above=true)

**Expected result:**
- HTTP 200.
- `items` contains `T1`, `T2`, and `T3`.
- `count` = 3.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC1 ("PROCESS_OPERATOR and above see all").

---

### TC-API-04-19: Empty result → HTTP 200 with empty items array

**Preconditions:**
- No tasks exist.

**Input:**  
`GET /api/v1/tasks`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- Response body: `{ "items": [], "next_cursor": null, "count": 0 }`.

**Layer:** integration  
**Acceptance criterion mapped:** API-06 edge case ("Empty result set: HTTP 200, empty items array, no cursor").

---

### TC-API-04-20: Last page has no next_cursor

**Preconditions:**
- Exactly 2 tasks exist.

**Input:**  
`GET /api/v1/tasks?page_size=5`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 200.
- `items` has 2 entries.
- `next_cursor` = null.
- `count` = 2.

**Layer:** integration  
**Acceptance criterion mapped:** API-06 edge case ("Single item fitting on the first page: HTTP 200, no cursor").

---

## Group 2: GET /tasks/:id

### TC-API-04-21: Success — returns full task detail

**Preconditions:**
- Task `T1` exists: instance_id=`I1`, node_id=`approve-step`, node_name=`Loan Approval`, status=PENDING, assignee_type=USER, assignee_ref=`alice`, created_at and updated_at are set.

**Input:**  
`GET /api/v1/tasks/<T1-uuid>`  
Actor: any authenticated role

**Expected result:**
- HTTP 200.
- Response body matches `TaskDetailResponse` schema:
  ```json
  {
    "task_id":       "<T1-uuid>",
    "instance_id":   "<I1-uuid>",
    "node_id":       "approve-step",
    "node_name":     "Loan Approval",
    "status":        "PENDING",
    "assignee_type": "USER",
    "assignee_ref":  "alice",
    "created_at":    <epoch-microseconds>,
    "updated_at":    <epoch-microseconds>
  }
  ```

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC2 (returns task including status, instance_id, node_id, assignee_type, assignee_ref, created_at).

---

### TC-API-04-22: Task not found → HTTP 404 TASK_NOT_FOUND

**Preconditions:**
- No task row exists for UUID `00000000-0000-0000-0000-000000000099`.

**Input:**  
`GET /api/v1/tasks/00000000-0000-0000-0000-000000000099`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 404.
- Response body contains `"error": "TASK_NOT_FOUND"`.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC2 ("HTTP 404 if not found").

---

### TC-API-04-23: Malformed task_id → HTTP 422 INVALID_TASK_ID

**Preconditions:** None.

**Input:**  
`GET /api/v1/tasks/not-a-uuid`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_TASK_ID"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-07 (invalid path parameter → HTTP 422).

---

## Group 3: POST /tasks/:id/complete

### TC-API-04-31: PROCESS_OPERATOR completes a PENDING task → HTTP 200

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`alice`.
- Instance for `T1` is ACTIVE.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": { "approved": true } }`  
Actor: PROCESS_OPERATOR (is_operator_or_above=true, user_id=`operator1`)

**Expected result:**
- HTTP 200.
- Response body: `{ "status": "ok", "task_id": "<T1-uuid>" }`.
- Task `T1` row: status=COMPLETED.
- No HTTP 403 is returned — PROCESS_OPERATOR may complete any task regardless of assignee.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3 (POST complete succeeds). Design §4.3 (PROCESS_OPERATOR skips ownership check).

---

### TC-API-04-32: TASK_WORKER completes own assigned task → HTTP 200

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`alice`.
- Instance for `T1` is ACTIVE.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": {} }`  
Actor: TASK_WORKER, user_id=`alice`

**Expected result:**
- HTTP 200.
- Response body: `{ "status": "ok", "task_id": "<T1-uuid>" }`.
- Task status changes to COMPLETED.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3. Design §4.3 (TASK_WORKER with matching assignee_ref=actor.user_id is permitted).

---

### TC-API-04-33: Already-COMPLETED task → HTTP 409 TASK_ALREADY_TERMINATED

**Preconditions:**
- Task `T1` exists with status=COMPLETED.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": {} }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_ALREADY_TERMINATED"`.
- No additional state changes occur.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3 ("HTTP 409 if already completed or cancelled").

---

### TC-API-04-34: CANCELLED task → HTTP 409 TASK_ALREADY_TERMINATED

**Preconditions:**
- Task `T1` exists with status=CANCELLED (e.g. instance was cancelled via EE-08).

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": {} }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_ALREADY_TERMINATED"`.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3 ("HTTP 409 if already completed or cancelled"); API-04 edge case ("Task for a CANCELLED instance: task is already CANCELLED; completion returns HTTP 409").

---

### TC-API-04-35: TASK_WORKER completes another user's task → HTTP 403 FORBIDDEN

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`bob`.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": {} }`  
Actor: TASK_WORKER, user_id=`alice` (alice ≠ bob)

**Expected result:**
- HTTP 403.
- Response body contains `"error": "FORBIDDEN"`.
- Task status remains PENDING; no event is appended.
- The 403 check happens AFTER the 404 lookup and BEFORE output_variables validation.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 edge case ("TASK_WORKER attempts to complete a task assigned to a different user: HTTP 403"). Design §4.3.

---

### TC-API-04-36: TASK_WORKER completes GROUP-assigned task → HTTP 403 FORBIDDEN

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=GROUP, assignee_ref=`reviewers`.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": {} }`  
Actor: TASK_WORKER, user_id=`alice`

**Expected result:**
- HTTP 403.
- Response body contains `"error": "FORBIDDEN"`.
- Task status remains PENDING.
- Note: group membership check (IDN-02) is not yet implemented; TASK_WORKER is restricted to USER-assigned tasks only.

**Layer:** integration  
**Acceptance criterion mapped:** Design §9.1 (TASK_WORKER restricted to USER-assigned tasks only, pending IDN-02).

---

### TC-API-04-37: Malformed task_id → HTTP 422 INVALID_TASK_ID

**Preconditions:** None.

**Input:**  
`POST /api/v1/tasks/not-a-uuid/complete`  
Body: `{ "output_variables": {} }`  
Actor: TASK_WORKER

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_TASK_ID"`.
- No TaskStore or InstanceStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-07. Cross-reference: TC-EE-04-08 (same assertion, now tracked here).

---

### TC-API-04-38: output_variables=null → HTTP 422 INVALID_INPUT

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`alice`.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": null }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.

**Layer:** integration  
**Note:** The role check and task fetch occur before body parsing; a valid task_id and role are required to reach this code path.  
**Acceptance criterion mapped:** API-04 AC3 body shape; API-07.

---

### TC-API-04-39: output_variables is JSON array → HTTP 422 INVALID_INPUT

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`alice`.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/complete`  
Body: `{ "output_variables": [1, 2, 3] }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3 (body must be JSON object, not array).

---

### TC-API-04-40: Non-existent task_id → HTTP 404 TASK_NOT_FOUND

**Preconditions:**
- No task row exists for UUID `00000000-0000-0000-0000-000000000099`.

**Input:**  
`POST /api/v1/tasks/00000000-0000-0000-0000-000000000099/complete`  
Body: `{ "output_variables": {} }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 404.
- Response body contains `"error": "TASK_NOT_FOUND"`.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC3; design §4.3 step 2.

---

## Group 4: POST /tasks/:id/assign

### TC-API-04-41: PROCESS_OPERATOR assigns an unassigned PENDING task → HTTP 200

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=null, assignee_ref=null (unassigned).

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/assign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR (is_operator_or_above=true)

**Expected result:**
- HTTP 200.
- Response body: `TaskDetailResponse` with updated task:
  - `assignee_type` = `"USER"`
  - `assignee_ref` = `"alice"`
  - `status` = `"PENDING"`
- `tasks` row for `T1`: `assignee_type = 'USER'`, `assignee_ref = 'alice'`, `updated_at` refreshed.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC4 ("assigns an unassigned task to a specific user").

---

### TC-API-04-42: Task already assigned → HTTP 409 TASK_ALREADY_ASSIGNED

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`bob` (already assigned).

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/assign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_ALREADY_ASSIGNED"`.
- Task row is not modified.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC4 ("HTTP 409 if task already assigned").

---

### TC-API-04-43: TASK_WORKER caller → HTTP 403 FORBIDDEN

**Preconditions:** None — role check fires before any store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/assign`  
Body: `{ "user_id": "alice" }`  
Actor: TASK_WORKER (is_operator_or_above=false)

**Expected result:**
- HTTP 403.
- Response body contains `"error": "FORBIDDEN"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** Design §5.3 step 1 (role check is the first operation).

---

### TC-API-04-44: Non-existent task_id → HTTP 404 TASK_NOT_FOUND

**Preconditions:**
- No task row exists for UUID `00000000-0000-0000-0000-000000000099`.

**Input:**  
`POST /api/v1/tasks/00000000-0000-0000-0000-000000000099/assign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 404.
- Response body contains `"error": "TASK_NOT_FOUND"`.

**Layer:** integration  
**Acceptance criterion mapped:** Design §5.3 step 4 (NotFound → HTTP 404).

---

### TC-API-04-45: user_id missing from body → HTTP 422 INVALID_INPUT

**Preconditions:** None — validation fires before store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/assign`  
Body: `{}`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC4 (body: `{ "user_id": "..." }` required); API-07.

---

### TC-API-04-46: user_id empty string → HTTP 422 INVALID_INPUT

**Preconditions:** None — validation fires before store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/assign`  
Body: `{ "user_id": "" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.

**Layer:** unit  
**Acceptance criterion mapped:** API-07 ("An empty required field MUST be treated as missing and reported with HTTP 422").

---

### TC-API-04-47: Task not PENDING (completed/cancelled) → HTTP 409 TASK_ALREADY_TERMINATED

**Preconditions:**
- Task `T1` exists: status=COMPLETED, assignee_ref=null.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/assign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_ALREADY_TERMINATED"`.
- Task row is not modified.

**Layer:** integration  
**Acceptance criterion mapped:** Design §5.3 (Task not PENDING → AssignmentConflict → HTTP 409).

---

## Group 5: POST /tasks/:id/reassign

### TC-API-04-51: PROCESS_OPERATOR reassigns an assigned PENDING task → HTTP 200

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_type=USER, assignee_ref=`bob` (already assigned).

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/reassign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR (is_operator_or_above=true)

**Expected result:**
- HTTP 200.
- Response body: `TaskDetailResponse` with updated task:
  - `assignee_type` = `"USER"`
  - `assignee_ref` = `"alice"`
  - `status` = `"PENDING"`
- `tasks` row for `T1`: `assignee_ref = 'alice'`, `updated_at` refreshed.

**Layer:** integration  
**Acceptance criterion mapped:** API-04 AC5 ("changes the assignee of an already-assigned task").

---

### TC-API-04-52: Task is unassigned → HTTP 409 TASK_NOT_ASSIGNED

**Preconditions:**
- Task `T1` exists: status=PENDING, assignee_ref=null (unassigned).

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/reassign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_NOT_ASSIGNED"`.
- Task row is not modified.

**Layer:** integration  
**Acceptance criterion mapped:** Design §6.4 (`assignee_ref IS NOT NULL` precondition → 0 rows → AssignmentConflict → HTTP 409 TASK_NOT_ASSIGNED).

---

### TC-API-04-53: TASK_WORKER caller → HTTP 403 FORBIDDEN

**Preconditions:** None — role check fires before any store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/reassign`  
Body: `{ "user_id": "alice" }`  
Actor: TASK_WORKER (is_operator_or_above=false)

**Expected result:**
- HTTP 403.
- Response body contains `"error": "FORBIDDEN"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC5 ("Requires PROCESS_OPERATOR or above"). Design §6.3 step 1.

---

### TC-API-04-54: Non-existent task_id → HTTP 404 TASK_NOT_FOUND

**Preconditions:**
- No task row exists for UUID `00000000-0000-0000-0000-000000000099`.

**Input:**  
`POST /api/v1/tasks/00000000-0000-0000-0000-000000000099/reassign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 404.
- Response body contains `"error": "TASK_NOT_FOUND"`.

**Layer:** integration  
**Acceptance criterion mapped:** Design §6.3 step 4 (NotFound → HTTP 404).

---

### TC-API-04-55: user_id missing from body → HTTP 422 INVALID_INPUT

**Preconditions:** None — validation fires before store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/reassign`  
Body: `{}`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.
- No TaskStore method is called.

**Layer:** unit  
**Acceptance criterion mapped:** API-04 AC5 (body: `{ "user_id": "..." }` required); API-07.

---

### TC-API-04-56: user_id empty string → HTTP 422 INVALID_INPUT

**Preconditions:** None — validation fires before store access.

**Input:**  
`POST /api/v1/tasks/<any-valid-uuid>/reassign`  
Body: `{ "user_id": "" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 422.
- Response body contains `"error": "INVALID_INPUT"`.

**Layer:** unit  
**Acceptance criterion mapped:** API-07 ("An empty required field MUST be treated as missing and reported with HTTP 422").

---

### TC-API-04-57: Task not PENDING (completed/cancelled) → HTTP 409 TASK_ALREADY_TERMINATED

**Preconditions:**
- Task `T1` exists: status=CANCELLED, assignee_type=USER, assignee_ref=`bob`.

**Input:**  
`POST /api/v1/tasks/<T1-uuid>/reassign`  
Body: `{ "user_id": "alice" }`  
Actor: PROCESS_OPERATOR

**Expected result:**
- HTTP 409.
- Response body contains `"error": "TASK_ALREADY_TERMINATED"`.
- Task row is not modified.

**Layer:** integration  
**Acceptance criterion mapped:** Design §6.4 (`status = 'PENDING'` precondition → 0 rows → AssignmentConflict → HTTP 409).
