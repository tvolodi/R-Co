# Pipeline Spec: process-definition — Process Definition Lifecycle

**Requirements covered:** PD-UI-01, PD-UI-02, PD-UI-03, PD-UI-04, PD-UI-09, PD-UI-10, PD-UI-12  
**Actor:** Process designer (platform administrator)  
**Starting state:** Administrator is authenticated; no test definition exists  
**Ending state:** Test definition created during the pipeline is activated (ACTIVE status)

## Workflow narrative

A process designer creates a new process definition from scratch, edits its graph on the
canvas by renaming a node and saving, verifies the change persists after a reload, then
activates the definition. Once active, the canvas switches to read-only mode. The journey
validates that the UI forms, the canvas editor, and the backend all stay in sync across
the full create → design → activate cycle. Testing any one screen without the others
misses the critical handoffs: the create dialog must produce an ID the canvas can load;
the save action must persist before activation is attempted; activation must flip the
status the list page shows.

## Chain topology

```
login (admin token obtained once)
  → [1] verify definition list structure  (PD-UI-01) → reads: —
  → [2] create definition via dialog      (PD-UI-04) → produces: definitionId, definitionName
  → [3] verify in list with DRAFT status  (PD-UI-01) → reads: definitionId
  → [4] open canvas and verify nodes      (PD-UI-09) → reads: definitionId
  → [5] rename node via property panel    (PD-UI-12) → reads: definitionId → produces: savedTaskName
  → [6] save definition                   (PD-UI-12) → reads: definitionId
  → [7] reload and verify change persisted(PD-UI-09) → reads: definitionId, savedTaskName
  → [8] activate definition               (PD-UI-04) → reads: definitionId
  → [9] verify canvas is read-only        (PD-UI-09) → reads: definitionId
  → [10] verify ACTIVE in list            (PD-UI-02) → reads: definitionId
  → cleanup: DELETE /api/v1/definitions/{definitionId}
```

A failure at any step aborts all subsequent steps. The `pl.onCleanup()` handler
deletes the definition via API (204/404 both acceptable).

---

## Steps

### Step 1 — PD-UI-01: definition list columns and search

**Given:** Administrator is logged in and navigates to `/definitions` via the sidebar  
**When:** The definitions page loads  
**Then:** The filter bar is visible; a search for a non-existent term shows "No results found";
the "New Definition" button is present  
**Gate condition:** none  
**Produces:** nothing

---

### Step 2 — PD-UI-04: create definition via dialog

**Given:** Administrator is on `/definitions`; the create dialog has not been opened yet  
**When:** The administrator clicks "New Definition", fills in name, version "1.0.0", and
a description, then clicks the submit button  
**Then:** The browser navigates to `/definitions/{id}` and the canvas is visible  
**Gate condition:** `definitionId` extracted from the URL must be a non-empty UUID — all
subsequent canvas steps depend on this ID  
**Produces:** `definitionId`, `definitionName`

---

### Step 3 — PD-UI-01: verify definition appears in list with DRAFT status

**Given:** `definitionId` from step 2 exists in the backend  
**When:** Administrator navigates back to `/definitions` and searches by the definition name  
**Then:** The definition row is visible with the correct name; the status shown is DRAFT  
**Gate condition:** none  
**Produces:** nothing

---

### Step 4 — PD-UI-09: canvas renders with default nodes

**Given:** Administrator navigates to `/definitions/{definitionId}`  
**When:** The canvas loads  
**Then:** The `[data-testid="process-canvas"]` element is visible; at least 2 React Flow
nodes are present (START and END from the default graph); the node palette is visible  
**Gate condition:** none  
**Produces:** nothing

---

### Step 5 — PD-UI-12: rename HUMAN_TASK node via property panel

**Given:** Canvas is loaded for `definitionId`; a HUMAN_TASK node exists (added via
palette double-click if not present from step 4)  
**When:** The administrator double-clicks the HUMAN_TASK palette item to add a node,
clicks the node to open the property panel, clears the name field, and types a new name  
**Then:** The node on the canvas shows the updated name in real time  
**Gate condition:** none  
**Produces:** `savedTaskName` (the new name typed by this step)

---

### Step 6 — PD-UI-12: save definition

**Given:** Canvas has unsaved changes from step 5  
**When:** Administrator clicks the Save button (`[data-testid="btn-save-definition"]`)  
**Then:** A "Definition saved" success toast appears  
**Gate condition:** none  
**Produces:** nothing (side effect: definition graph persisted via PATCH)

---

### Step 7 — PD-UI-09: reload and verify change persisted

**Given:** `savedTaskName` from step 5; `definitionId` from step 2  
**When:** Administrator re-authenticates (loginWithToken again) and navigates back to
`/definitions/{definitionId}` — this forces a fresh load from the backend  
**Then:** The canvas renders with the correct node count; `savedTaskName` appears as a
visible node label on the canvas  
**Gate condition:** `savedTaskName` visible — confirms the save in step 6 actually persisted  
**Produces:** nothing

---

### Step 8 — PD-UI-04: activate definition

**Given:** Definition is in DRAFT status; canvas is loaded  
**When:** Administrator clicks the Activate button and confirms (if a confirmation dialog
appears)  
**Then:** A success indicator is shown; the read-only banner appears on the canvas  
**Gate condition:** none (the step 9 gate verifies activation succeeded visually)  
**Produces:** nothing

---

### Step 9 — PD-UI-09: verify canvas is read-only after activation

**Given:** Definition has been activated in step 8  
**When:** Administrator is on the canvas page for `definitionId`  
**Then:** `[data-testid="read-only-banner"]` is visible and contains "ACTIVE"; the node
palette (`[data-testid="node-palette"]`) is NOT visible; the Save button
(`[data-testid="btn-save-definition"]`) is NOT visible  
**Gate condition:** read-only banner visible — confirms activation took effect  
**Produces:** nothing

---

### Step 10 — PD-UI-02: verify ACTIVE status in definition list

**Given:** Definition was activated in step 8  
**When:** Administrator navigates to `/definitions`, searches by definition name, and
applies the "ACTIVE" status filter  
**Then:** The definition row is visible with ACTIVE status  
**Gate condition:** none  
**Produces:** nothing

---

## Cleanup

**Handler:** registered via `pl.onCleanup()` — runs unconditionally  
**Action:** `DELETE /api/v1/definitions/{definitionId}` (204 or 404 both acceptable)  
**Fallback:** if `definitionId` is empty (chain aborted before step 2), no API call is made

---

## Failure behaviour

| Step that fails | Steps skipped | System state left behind | Cleanup needed |
|---|---|---|---|
| Step 1 | Steps 2–10 | Nothing created | No |
| Step 2 | Steps 3–10 | Definition may be partial | Yes — delete definition |
| Steps 3–7 | Remaining steps | Definition exists in DRAFT | Yes — delete definition |
| Step 8 | Steps 9–10 | Definition exists, activation failed | Yes — delete definition |
| Steps 9–10 | Remaining | Definition ACTIVE | Yes — delete definition (204 expected) |
