# Pipeline Spec: instance-task-lifecycle — Instance and Task Lifecycle

**Requirements covered:** IN-UI-01, IN-UI-02, IN-UI-03, IN-UI-04, IN-UI-07, TK-UI-01, TK-UI-02, TK-UI-03, TK-UI-04  
**Actors:** Platform operator (starts instances, can see all tasks), task worker (completes tasks)  
**Starting state:** Both operator and worker are authenticated; an ACTIVE definition with a
HUMAN_TASK node assigned to the worker user exists  
**Ending state:** Instance is COMPLETED (via task completion) or CANCELLED (via cancel step)

## Workflow narrative

An operator starts a new process instance from the instance board and verifies it appears
in the monitoring view. A worker then opens the task inbox, sees the assigned task, fills
in the required form fields, and completes the task. The operator verifies the instance
status moves to COMPLETED. This is the core business value chain of the entire platform:
instances only exist because definitions were created; tasks only appear because instances
were started; the instance only completes because tasks are completed. The cancel path
(steps 9–10) is included as a variant that validates the operator's ability to abort an
active instance mid-flight, which is a separate system state not covered by the happy path.

## Chain topology

```
setup (API): create definition → activate → produce: definitionId, definitionName, workerUserId
login operator
  → [1] instance board columns             (IN-UI-01)  → reads: —
  → [2] start instance via UI dialog       (IN-UI-03)  → produces: instanceId
  → [3] instance detail: panels visible    (IN-UI-04)  → reads: instanceId
  → [4] wait for task to appear (API poll) → reads: instanceId
login worker
  → [5] task inbox shows the task          (TK-UI-01)  → reads: instanceId
  → [6] open task detail panel             (TK-UI-02)  → reads: instanceId → produces: taskId
  → [7] fill required form field           (TK-UI-03)  → reads: taskId
  → [8] complete task                      (TK-UI-04)  → reads: taskId
login operator
  → [9] verify instance COMPLETED          (IN-UI-04)  → reads: instanceId
  --- OR cancel variant ---
  → [9b] cancel instance via UI            (IN-UI-07)  → reads: instanceId
  → [10b] verify instance CANCELLED        (IN-UI-04)  → reads: instanceId
  → cleanup: cancel instance if still ACTIVE (API), delete definition (API)
```

A failure at any step aborts all subsequent steps. The `pl.onCleanup()` handler
ensures the instance is cancelled and the definition is deleted regardless of chain state.

---

## Steps

### Setup — create and activate definition (API, before chain starts)

**Given:** Operator token is available  
**When:** `POST /api/v1/definitions` with a graph containing START → HUMAN_TASK → END where
HUMAN_TASK has `assignee_type: "USER"` and `assignee_ref: workerUserId`; then
`POST /api/v1/definitions/{id}/activate`  
**Then:** Definition is ACTIVE; `definitionId` and `definitionName` are stored  
**Gate condition:** Both API calls return 2xx — without an ACTIVE definition there is
nothing to instance  
**Produces:** `definitionId`, `definitionName`, `workerUserId`

---

### Step 1 — IN-UI-01: instance board columns

**Given:** Operator is logged in and navigates to `/instances`  
**When:** The instance board table loads  
**Then:** Table is visible with columns: Instance ID, Definition, Status, Correlation Key,
Started, Last Updated  
**Gate condition:** none  
**Produces:** nothing

---

### Step 2 — IN-UI-03: start instance via UI dialog

**Given:** Operator is on the instance board; `definitionName` from setup is known  
**When:** Operator clicks "Start Instance", fills in the definition name, a unique
correlation key, and initial variables `{"source":"pipeline-e2e"}`, then clicks Submit  
**Then:** Browser navigates to `/instances/{id}`; instance detail heading is visible  
**Gate condition:** `instanceId` extracted from URL must be a non-empty UUID — all
subsequent steps depend on this instance  
**Produces:** `instanceId`

---

### Step 3 — IN-UI-04: instance detail panels visible

**Given:** `instanceId` from step 2; operator navigates to `/instances/{instanceId}`  
**When:** The page loads  
**Then:** Headings visible: "Instance", "Definition Snapshot", "Variables", "Active Tasks";
the read-only graph canvas `[data-testid="instance-readonly-graph"]` is visible; no error
boundary is rendered  
**Gate condition:** none  
**Produces:** nothing

---

### Step 4 — wait for task to appear (API poll)

**Given:** `instanceId` from step 2; `workerToken` is available  
**When:** `GET /api/v1/tasks?instance_id={instanceId}` is polled until `items.length > 0`
or 20 seconds elapse  
**Then:** At least one task exists for the instance  
**Gate condition:** Task appeared within timeout — if no task appears the engine did not
process the INSTANCE_STARTED event, which makes steps 5–8 impossible  
**Produces:** nothing (task ID will be found via UI in step 6)

---

### Step 5 — TK-UI-01: worker task inbox shows the task

**Given:** Worker is logged in; task was confirmed to exist in step 4  
**When:** Worker navigates to `/tasks`  
**Then:** `[data-testid="task-inbox-list"]` is visible; at least one `[data-testid="task-row"]`
is present  
**Gate condition:** none  
**Produces:** nothing

---

### Step 6 — TK-UI-02: open task detail panel

**Given:** At least one task row is visible  
**When:** Worker clicks the first task row  
**Then:** `[data-testid="task-detail-panel"]` is visible; `[data-testid="task-detail-title"]`
has non-empty text; instance context fields visible: definition name, instance ID,
correlation key  
**Gate condition:** `taskId` extracted from the row's `data-task-id` attribute must be
non-empty  
**Produces:** `taskId`

---

### Step 7 — TK-UI-03: fill required form field

**Given:** Task detail panel is open; the form has a required `approver_notes` text field  
**When:** Worker fills `[data-testid="form-field-approver_notes"]` with "Approved via pipeline test"  
**Then:** The field shows the entered text; no validation error is shown  
**Gate condition:** none  
**Produces:** nothing

---

### Step 8 — TK-UI-04: complete task

**Given:** Required form field is filled from step 7  
**When:** Worker clicks `[data-testid="task-complete-button"]`  
**Then:** A POST request to `/tasks/{taskId}/complete` is made and succeeds; either a
success toast appears or the task row disappears from the inbox  
**Gate condition:** none  
**Produces:** nothing (side effect: instance engine processes TASK_COMPLETED event)

---

### Step 9 — IN-UI-04: verify instance COMPLETED

**Given:** Operator is logged in; task was completed in step 8; `instanceId` from step 2  
**When:** Operator navigates to `/instances/{instanceId}`  
**Then:** The status shown on the detail page is "COMPLETED" (the HUMAN_TASK was the only
task before END, so completing it finishes the instance)  
**Gate condition:** none  
**Produces:** nothing

---

### Steps 9b–10b — cancel variant (alternative to steps 8–9)

These steps replace steps 8–9 when the pipeline is run in cancel-verification mode.
They are included here for completeness — the default run follows the happy path (steps 8–9).

**Step 9b — IN-UI-07: cancel instance via UI**  
**Given:** Instance is ACTIVE; operator is on the instance detail page  
**When:** Operator clicks Cancel, fills in a reason, and confirms  
**Then:** Status shows "CANCELLED"; Cancel button disappears  

**Step 10b — IN-UI-04: verify CANCELLED on detail page**  
**Given:** Cancel was confirmed in step 9b  
**When:** Operator is still on the instance detail page  
**Then:** Status is "CANCELLED"  

---

## Cleanup

**Handler:** registered via `pl.onCleanup()` — runs unconditionally  
**Actions (in order):**
1. If `instanceId` is set and instance may still be ACTIVE: `POST /api/v1/instances/{instanceId}/cancel`
   with reason "pipeline-test-cleanup" (404/409 both acceptable — instance may already be terminal)
2. If `definitionId` is set: `DELETE /api/v1/definitions/{definitionId}` (204 or 404 acceptable)

---

## Failure behaviour

| Step that fails | Steps skipped | System state left behind | Cleanup needed |
|---|---|---|---|
| Setup | All steps | Definition may exist in DRAFT | Yes — delete definition |
| Step 1 | Steps 2–9 | Definition ACTIVE | Yes — delete definition |
| Step 2 | Steps 3–9 | Definition ACTIVE; no instance | Yes — delete definition |
| Steps 3–4 | Remaining | Instance ACTIVE | Yes — cancel instance, delete definition |
| Steps 5–7 | Remaining | Instance ACTIVE; task unclaimed | Yes — cancel instance, delete definition |
| Step 8 | Step 9 | Instance ACTIVE; task not completed | Yes — cancel instance, delete definition |
| Step 9 | — | Instance COMPLETED; definition still exists | Yes — delete definition |
