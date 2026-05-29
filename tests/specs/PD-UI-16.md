# Test Spec: PD-UI-16 — CEL Expression Editor

**Requirement:** PD-UI-16 — Edge condition inputs on EXCLUSIVE_GATEWAY SHALL use a code editor field (Monaco or CodeMirror) with CEL syntax highlighting and basic bracket matching. Syntax errors from the server (PD-06) SHALL be surfaced inline below the field.
**Priority:** SHOULD
**Test layer:** e2e (Playwright against real backend)
**Run:** WF02-f2b-shoulds-20260529
**Design ref:** `src/design/canvas-f2-batch1.md`
**Backend APIs consumed:** `POST /definitions`, `GET /definitions/:id`, `PUT /definitions/:id`

---

## Test Cases

### TC-PDUI16-01: ConditionDialog shows CodeMirror CEL expression editor

**Given:** A DRAFT definition with an EXCLUSIVE_GATEWAY node exists
**When:** The user opens the ConditionDialog for an edge originating from the EXCLUSIVE_GATEWAY
**Then:** Screen shows a CodeMirror editor (CodeMirror wrapper element is visible inside the ConditionDialog) with CEL placeholder text "e.g. status == 'approved'", bracket matching enabled, and line numbers visible
**Layer:** e2e
**Acceptance criterion mapped:** CEL expression editor uses CodeMirror with syntax highlighting and bracket matching

---

### TC-PDUI16-02: Syntax errors surfaced inline below CEL editor

**Given:** The ConditionDialog is open with the CEL expression editor visible
**When:** The user types an invalid CEL expression (e.g. "status ==")
**Then:** The Confirm button remains disabled; a server-side validation error from the backend (PD-06) is displayed inline below the editor as an alert with error styling
**Layer:** e2e
**Acceptance criterion mapped:** Syntax errors surfaced inline below the CEL field
