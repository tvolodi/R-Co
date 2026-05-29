# Test Spec: PD-UI-19 — Undo / Redo

**Requirement:** PD-UI-19 — The canvas SHALL support undo/redo (Ctrl+Z / Ctrl+Y) for all canvas operations (add node, delete edge, move node, edit property).
**Priority:** SHOULD
**Test layer:** e2e (Playwright against real backend)
**Run:** WF02-f2b-shoulds-20260529
**Design ref:** `src/design/canvas-f2-batch1.md`

---

## Test Cases

### TC-PDUI19-01: Ctrl+Z undoes node addition

**Given:** A DRAFT definition editor page is open with an existing graph
**When:** The user adds a new node via palette double-click (nodes count increases), then presses Ctrl+Z
**Then:** The added node is removed from the canvas; the node count returns to the original count before the addition
**Layer:** e2e
**Acceptance criterion mapped:** Undo reverses node addition

---

### TC-PDUI19-02: Ctrl+Y redoes after undo

**Given:** The user has just performed an undo (Ctrl+Z) that removed a previously added node
**When:** The user presses Ctrl+Y
**Then:** The previously removed node reappears on the canvas; the node count returns to the count just after the addition
**Layer:** e2e
**Acceptance criterion mapped:** Redo restores previously undone operation

---

### TC-PDUI19-03: Undo/redo works for property edits

**Given:** A DRAFT definition editor page is open with a HUMAN_TASK node
**When:** The user changes the node name in the property panel, then presses Ctrl+Z
**Then:** The node name reverts to the previous value; pressing Ctrl+Y restores the edited name
**Layer:** e2e
**Acceptance criterion mapped:** Undo/redo works for property edits
