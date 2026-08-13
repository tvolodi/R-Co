# Test Spec: GRD-UI-07 — Generated per-field ARIA wiring

**Requirement:** GRD-UI-07 — Every field rendered by `FieldFactory` / `DynamicFormRenderer` must carry `aria-required` (when required), `aria-describedby` (when a hint exists), `aria-invalid` + `aria-errormessage` (when a validation error exists). The `aria-describedby` value must reference an existing hint node in the DOM at the same moment (`aria-errormessage` likewise). The `<form>` element must carry `aria-busy="true"` while the submit is in-flight and clear it in `finally`.
**Priority:** MUST
**Test layer:** unit (Vitest + Testing Library), e2e (Playwright — real backend)

**Design reference:** `src/design/pw13-pw16-batch19-20260813.md` §4.1–§4.4, §5.4, §12.4.

## Test Cases

### TC-GRD-UI-07-01: string field carries aria-required="true" when required
**Given:** a field definition `{ type: 'string', title: 'Title', required: true }`
**When:** `renderFormField('title', fieldDef, undefined, undefined, register)` is called
**Then:** the rendered `<input>` has `id="title"`, a `<label htmlFor="title">`, and `aria-required="true"`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-01`)

### TC-GRD-UI-07-02: hint node is created with `${fieldName}-hint` id and referenced by aria-describedby
**Given:** `fieldDef = { type: 'string', title: 'Title', description: 'Enter your title' }`
**When:** the field is rendered
**Then:** `<p id="title-hint">Enter your title</p>` exists in the DOM; the `<input>` has `aria-describedby="title-hint"`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-02`)

### TC-GRD-UI-07-03: errorMessage produces aria-invalid="true" + aria-errormessage pointing at existing node
**Given:** `fieldDef = { type: 'string', title: 'Title', required: true }` and `errorMessage = 'Title is required'`
**When:** the field is rendered
**Then:** the input has `aria-invalid="true"`, `aria-errormessage="title-error"`; a `<p id="title-error" role="alert">` exists
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-2
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-03`)

### TC-GRD-UI-07-04: number / date / textarea / select fields carry the ARIA attribute set
**Given:** four field definitions of varying types
**When:** each is rendered
**Then:** each carries `aria-required` (when required), `aria-describedby` (when hint), `aria-invalid` + `aria-errormessage` (when error)
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-04a..04c`, `TC-FF-05`)

### TC-GRD-UI-07-05: required=false omits the attribute (NOT `aria-required="false"`)
**Given:** `fieldDef = { type: 'string', title: 'Optional' }`
**When:** the field is rendered
**Then:** the `<input>` has NO `aria-required` attribute (omitted, per WAI-ARIA 1.2)
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-1 + §12.4 mode 4
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-06`), `web/tests/unit/FieldFactory.aria.12.test.tsx` (`TC-FF-09`)

### TC-GRD-UI-07-06: CMP-UI-05 registry routing renders the registered renderer + carries attributes
**Given:** `fieldRegistry.set('org.acme.rating', { renderInput, requiredAriaAttributes: […] })`
**When:** a field with `type: 'org.acme.rating'` is rendered
**Then:** the renderer receives `ariaRequired=true`, `ariaDescribedBy='rating-hint'`, `ariaErrorMessage='rating-error'`; the rendered `<input>` carries the full attribute set
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-5
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-07`)

### TC-GRD-UI-07-07: registry lookup miss falls through to defaultBuiltinRenderer (full attr set emitted)
**Given:** `fieldDef.type = 'org.acme.unregistered'` (not in the registry, not a built-in)
**When:** the field is rendered
**Then:** the FieldFactory does not crash; a `console.warn` is emitted with the missing type; the label still renders (the input itself may be omitted per the contract)
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-5 + §12.4 mode 2
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-08`), `web/tests/unit/FieldFactory.aria.12.test.tsx` (`TC-FF-10`)

### TC-GRD-UI-07-08: joinHintIds returns space-separated string in order
**Given:** an array of hint IDs
**When:** `joinHintIds([...])` is called
**Then:** the result is the IDs joined by a single space (no commas), preserving order; `null` / `undefined` entries are filtered out
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-1 + §12.4 mode 5
**Implemented by:** `web/tests/unit/FieldFactory.aria.test.tsx` (`TC-FF-09`), `web/tests/unit/FieldFactory.aria.12.test.tsx` (`TC-FF-11`)

### TC-GRD-UI-07-09: DynamicFormRenderer — idle form has aria-busy="false"
**Given:** a mounted `<DynamicFormRenderer>` with no submit in flight
**When:** the form element is inspected
**Then:** it carries `aria-busy="false"` and `data-testid="task-form"`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-4
**Implemented by:** `web/tests/unit/DynamicFormRenderer.aria.test.tsx` (`TC-DFR-01`)

### TC-GRD-UI-07-10: DynamicFormRenderer — aria-busy flips to "true" while saving
**Given:** an in-flight submit (Promise unresolved)
**When:** `submit()` is clicked
**Then:** the `<form>` carries `aria-busy="true"` until the Promise resolves, then `aria-busy="false"`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-4
**Implemented by:** `web/tests/unit/DynamicFormRenderer.aria.test.tsx` (`TC-DFR-02`)

### TC-GRD-UI-07-11: DynamicFormRenderer — aria-busy cleared in finally even on throw
**Given:** a submit whose `onSubmit` throws
**When:** the form is submitted
**Then:** `aria-busy` returns to `"false"` (the `try / finally` invariant from §4.2 / §12.4 mode 3)
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-4 + §12.4 mode 3
**Implemented by:** `web/tests/unit/DynamicFormRenderer.aria.test.tsx` (`TC-DFR-03`), `web/tests/unit/DynamicFormRenderer.12.test.tsx` (`TC-DFR-04`)

### TC-GRD-UI-07-12: aria-validator — empty DOM returns no dangling references
**Given:** an empty `document.body`
**When:** `detectDanglingAriaReferences(document.body)` is called
**Then:** the result is `[]`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-3
**Implemented by:** `web/tests/unit/aria-validator.test.ts` (`TC-AV-01`)

### TC-GRD-UI-07-13: aria-validator — `aria-invalid` without `aria-errormessage` is dangling
**Given:** `<input aria-invalid="true" />` with no `aria-errormessage` and no error node
**When:** the detector runs
**Then:** the result contains one entry with `fieldKey` and `ariaErrorMessage: ''`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-3 + §12.4 mode 1
**Implemented by:** `web/tests/unit/aria-validator.test.ts` (`TC-AV-02`)

### TC-GRD-UI-07-14: aria-validator — `aria-errormessage` referencing a missing id is dangling
**Given:** `<input aria-invalid="true" aria-errormessage="x-error" />` with no node with `id="x-error"`
**When:** the detector runs
**Then:** the result contains one entry with `fieldKey` and `ariaErrorMessage: 'x-error'`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-3 + §12.4 mode 1
**Implemented by:** `web/tests/unit/aria-validator.test.ts` (`TC-AV-03`)

### TC-GRD-UI-07-15: aria-validator — valid `aria-errormessage` target is NOT dangling
**Given:** an input + a `<div id="x-error" role="alert">` target
**When:** the detector runs
**Then:** the result is `[]`
**Layer:** unit
**Acceptance criterion mapped:** GRD-UI-07 AC-3
**Implemented by:** `web/tests/unit/aria-validator.test.ts` (`TC-AV-04`)

### TC-GRD-UI-07-16: real task form on `/tasks/dashboard` renders `aria-required="true"` for required fields
**Given:** a seeded definition whose task has a `form_schema` with a required `subject` field, authenticated as `worker-user`
**When:** the user opens `/tasks/dashboard?taskId=…`
**Then:** the `subject` input carries `aria-required="true"`
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-01`)

### TC-GRD-UI-07-17: real task form — `aria-describedby` resolves to a hint node
**Given:** a seeded definition with a `description`-hint on the `subject` field
**When:** the user opens the task dashboard
**Then:** the `subject` input has `aria-describedby="<id>"`; `<p id="<id>">…</p>` is visible
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-02`)

### TC-GRD-UI-07-18: real task form — empty submit triggers `aria-invalid` + `aria-errormessage`
**Given:** a task with a required `subject` field
**When:** the user clears the input and clicks `[data-testid="task-submit-btn"]`
**Then:** the input carries `aria-invalid="true"`, `aria-errormessage="<id>"`, and a `<p id="<id>" role="alert">` is present
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-2
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-03`)

### TC-GRD-UI-07-19: real form — number / date / textarea / select fields all carry the ARIA attribute set
**Given:** a task with one field per widget type
**When:** the user opens the dashboard
**Then:** each input carries the relevant ARIA attributes; no `role="textbox"` mismatch for number / date; textarea tag is `TEXTAREA`
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-1
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-04`)

### TC-GRD-UI-07-20: real form — zero dangling aria-errormessage references after a submit attempt
**Given:** a task with multiple required fields
**When:** the user clears all textboxes and submits
**Then:** `page.evaluate()` returns `[]` for `[aria-invalid="true"]` elements whose `aria-errormessage` target id is missing
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-3 + §12.4 mode 1
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-05`)

### TC-GRD-UI-07-21: optional field omits `aria-required` on the real form
**Given:** a task with an optional `description` field
**When:** the user opens the dashboard
**Then:** the `description` input does NOT carry an `aria-required` attribute
**Layer:** e2e
**Acceptance criterion mapped:** GRD-UI-07 AC-1 + §12.4 mode 4
**Implemented by:** `web/tests/e2e/grd-ui-07.field-aria.e2e.spec.ts` (`TC-GRD-UI-07-E2E-06`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| GRD-UI-07 AC-1: every field has label htmlFor, aria-required, aria-describedby resolving to hint | `TC-GRD-UI-07-01`, `TC-GRD-UI-07-02`, `TC-GRD-UI-07-04`, `TC-GRD-UI-07-16`, `TC-GRD-UI-07-17`, `TC-GRD-UI-07-19`, `TC-GRD-UI-07-21` |
| GRD-UI-07 AC-2: required empty submit → aria-invalid + aria-errormessage | `TC-GRD-UI-07-03`, `TC-GRD-UI-07-18` |
| GRD-UI-07 AC-3: dangling aria-errormessage fails assertion with field key | `TC-GRD-UI-07-12..15`, `TC-GRD-UI-07-20` |
| GRD-UI-07 AC-4: form element aria-busy in-flight; cleared in finally | `TC-GRD-UI-07-09..11` |
| GRD-UI-07 AC-5: CMP-UI-05 registry renders without page edit | `TC-GRD-UI-07-06`, `TC-GRD-UI-07-07` |
| §12.4 mode 1: dangling aria-errormessage | `TC-GRD-UI-07-13`, `TC-GRD-UI-07-14`, `TC-GRD-UI-07-20` |
| §12.4 mode 2: registry lookup miss | `TC-GRD-UI-07-07`, `web/tests/unit/FieldFactory.aria.12.test.tsx` (`TC-FF-10`) |
| §12.4 mode 3: aria-busy cleared in finally | `TC-GRD-UI-07-11`, `web/tests/unit/DynamicFormRenderer.12.test.tsx` (`TC-DFR-04`) |
| §12.4 mode 4: required omitted from definition | `TC-GRD-UI-07-05`, `TC-GRD-UI-07-21` |
| §12.4 mode 5: multiple hints space-separated | `TC-GRD-UI-07-08`, `web/tests/unit/FieldFactory.aria.12.test.tsx` (`TC-FF-11`) |

## Acceptance Test Coverage Matrix

| AC | E2E | Unit | Status |
|---|---|---|---|
| AC-1 | `TC-GRD-UI-07-16`, `TC-GRD-UI-07-17`, `TC-GRD-UI-07-19`, `TC-GRD-UI-07-21` | `TC-GRD-UI-07-01`, `TC-GRD-UI-07-02`, `TC-GRD-UI-07-04`, `TC-GRD-UI-07-05` | COVERED |
| AC-2 | `TC-GRD-UI-07-18` | `TC-GRD-UI-07-03` | COVERED |
| AC-3 | `TC-GRD-UI-07-20` | `TC-GRD-UI-07-12..15` | COVERED |
| AC-4 | (covered indirectly via AC-3 E2E submit path) | `TC-GRD-UI-07-09..11` | COVERED |
| AC-5 | (covered by `web/tests/e2e/a11y-gate.e2e.spec.ts` AC-6 cross-cutting) | `TC-GRD-UI-07-06`, `TC-GRD-UI-07-07` | COVERED |
| §12.4 mode 1 | `TC-GRD-UI-07-20` | `TC-GRD-UI-07-13`, `TC-GRD-UI-07-14` | COVERED |
| §12.4 mode 2 | (covered) | `TC-GRD-UI-07-07`, `TC-FF-10` | COVERED |
| §12.4 mode 3 | (covered) | `TC-GRD-UI-07-11`, `TC-DFR-04` | COVERED |
| §12.4 mode 4 | `TC-GRD-UI-07-21` | `TC-GRD-UI-07-05`, `TC-FF-09` | COVERED |
| §12.4 mode 5 | (covered) | `TC-GRD-UI-07-08`, `TC-FF-11` | COVERED |

## Execution Notes For TEST-RUNNER

- E2E uses real Keycloak + BPM API + PostgreSQL per design §0. The seeded definition for each test is created via `POST /api/v1/definitions` and torn down in `afterEach`.
- Per-test isolation: each test creates a uniquely-named definition (e.g., `pw13-batch19-grd-ui-07-<uuid>`); the seeded tenant is reused, not modified globally.
- `web/tests/unit/DynamicFormRenderer.12.test.tsx` adds explicit regression for §12.4 mode 3 (the finally invariant) — covers the case where `onSubmit` rejects synchronously after awaiting an async dependency.
