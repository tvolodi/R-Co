# Test Spec: TK-UI-10 — Mobile task completion (responsive layout)

**Requirement:** TK-UI-10 — The task detail panel and complete flow SHALL be fully operable on a 375 px viewport (per FNFR-07). Form fields, the complete button, and error messages must not be clipped or require horizontal scrolling.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Task inbox is usable on 375px mobile viewport | TC-TK-UI-10-E2E-01 |
| Task detail page renders without horizontal scrolling | TC-TK-UI-10-E2E-02 |
| Form fields are readable and input-able on mobile | TC-TK-UI-10-E2E-03 |
| Complete button is accessible and clickable on mobile | TC-TK-UI-10-E2E-04 |
| Error messages display fully on mobile | TC-TK-UI-10-E2E-05 |
| Text input fields not clipped on mobile | TC-TK-UI-10-E2E-06 |

## Test Cases

### TC-TK-UI-10-E2E-01: Task inbox displays on 375px viewport
**Given:** the browser viewport is set to 375px width (mobile)
**When:** user navigates to the Task Inbox
**Then:** screen shows the task list in a single-column mobile layout without horizontal scrolling
**Layer:** e2e
**Acceptance criterion mapped:** mobile viewport support for task list

### TC-TK-UI-10-E2E-02: Task detail page renders without horizontal scrolling
**Given:** the browser viewport is 375px wide and user opens a task detail
**When:** task detail page is loaded
**Then:** screen displays all content in a single column and horizontal scrollbar is not visible
**Layer:** e2e
**Acceptance criterion mapped:** mobile detail page layout

### TC-TK-UI-10-E2E-03: Form fields are readable and input-able on mobile
**Given:** a 375px mobile viewport with a task form open
**When:** form is rendered
**Then:** each form field is fully visible and can be interacted with (tap to focus, type input) without truncation
**Layer:** e2e
**Acceptance criterion mapped:** mobile form usability

### TC-TK-UI-10-E2E-04: Complete button is accessible on mobile
**Given:** a 375px mobile viewport with a task form
**When:** user scrolls to the bottom of the form
**Then:** the Complete/Submit button is fully visible and tap-able without horizontal scrolling required
**Layer:** e2e
**Acceptance criterion mapped:** mobile button accessibility

### TC-TK-UI-10-E2E-05: Error messages display in full on mobile
**Given:** a form submission fails with an error message (e.g. "Field is required")
**When:** error is displayed on a 375px viewport
**Then:** the entire error message is visible without clipping or requiring horizontal scroll
**Layer:** e2e
**Acceptance criterion mapped:** mobile error message display

### TC-TK-UI-10-E2E-06: Text input fields not clipped on mobile
**Given:** form with text input fields on 375px viewport
**When:** user taps on an input field
**Then:** the field expands/scrolls to be fully visible and the on-screen keyboard does not hide the field label
**Layer:** e2e
**Acceptance criterion mapped:** mobile input field visibility
