# Test Spec: TK-UI-03 — Dynamic form rendering (form schema to UI)

**Requirement:** TK-UI-03 — If the task node defines a `form_schema` (JSON Schema), the task detail panel SHALL render a dynamic form with appropriate field types (text, number, boolean, date, select, etc.). Required fields are enforced client-side before submission.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Form schema with text field is rendered | TC-TK-UI-03-E2E-01 |
| Form schema with number field is rendered | TC-TK-UI-03-E2E-02 |
| Form schema with boolean field is rendered | TC-TK-UI-03-E2E-03 |
| Form schema with date field is rendered | TC-TK-UI-03-E2E-04 |
| Form schema with select/enum field is rendered | TC-TK-UI-03-E2E-05 |
| Required field validation enforced client-side | TC-TK-UI-03-E2E-06 |
| Form validation prevents submission with missing required fields | TC-TK-UI-03-E2E-07 |

## Test Cases

### TC-TK-UI-03-E2E-01: Text field from form schema renders as input
**Given:** a task with form_schema containing a text field (type: "string")
**When:** task detail panel is opened
**Then:** screen shows a text input field with the field label visible
**Layer:** e2e
**Acceptance criterion mapped:** text field rendering

### TC-TK-UI-03-E2E-02: Number field from form schema renders as numeric input
**Given:** a task with form_schema containing a number field (type: "number")
**When:** task detail panel is opened
**Then:** screen shows a number input field that only accepts numeric values
**Layer:** e2e
**Acceptance criterion mapped:** number field rendering

### TC-TK-UI-03-E2E-03: Boolean field from form schema renders as checkbox
**Given:** a task with form_schema containing a boolean field (type: "boolean")
**When:** task detail panel is opened
**Then:** screen shows a checkbox or toggle control for the field
**Layer:** e2e
**Acceptance criterion mapped:** boolean field rendering

### TC-TK-UI-03-E2E-04: Date field from form schema renders as date picker
**Given:** a task with form_schema containing a date field (type: "string", format: "date")
**When:** task detail panel is opened
**Then:** screen shows a date input field or picker control
**Layer:** e2e
**Acceptance criterion mapped:** date field rendering

### TC-TK-UI-03-E2E-05: Select/enum field from form schema renders as dropdown
**Given:** a task with form_schema containing an enum field with options ["PENDING", "APPROVED", "REJECTED"]
**When:** task detail panel is opened
**Then:** screen shows a dropdown/select control with the enum options visible
**Layer:** e2e
**Acceptance criterion mapped:** select field rendering

### TC-TK-UI-03-E2E-06: Required fields are marked as required in UI
**Given:** a form schema with required fields marked (required: ["approver_notes"])
**When:** task detail panel is opened
**Then:** screen visually indicates required fields (e.g. asterisk, "required" label)
**Layer:** e2e
**Acceptance criterion mapped:** required field indication

### TC-TK-UI-03-E2E-07: Form submission is blocked if required fields are empty
**Given:** a form with a required field that is empty
**When:** user clicks the Complete/Submit button
**Then:** screen shows validation error message and form is not submitted
**Layer:** e2e
**Acceptance criterion mapped:** client-side required field validation
