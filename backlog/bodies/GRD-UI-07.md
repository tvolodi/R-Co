> **Extends:** CMP-UI-05, making ARIA wiring a property of the field registry rather than of each screen.

> `FieldFactory` SHALL emit, for every field it generates, a `<label htmlFor>` bound to the input id, `aria-required` reflecting the JSON Schema `required` list, `aria-describedby` pointing at the field hint node, and `aria-invalid` with `aria-errormessage` pointing at the field error node whenever the field is in error. `DynamicFormRenderer` SHALL set `aria-busy` on the form element while a submit is in flight. Whenever `aria-invalid` is `true`, the node referenced by `aria-errormessage` SHALL exist in the DOM.

**Acceptance Criteria:**
- GIVEN a Playwright E2E opens a human task on the real backend whose `form_schema` has five properties, WHEN the form renders, THEN every generated field carries a `<label htmlFor>` matching its input id, `aria-required`, and `aria-describedby` resolving to an existing hint node; no HTTP mocking is used.
- GIVEN a required field is submitted empty, WHEN validation fails in that E2E, THEN the field carries `aria-invalid="true"` and `aria-errormessage` pointing at a node that exists in the DOM and holds the error text.
- GIVEN a field sets `aria-invalid="true"` with a dangling `aria-errormessage` reference, WHEN the ARIA assertion runs on the Task Inbox surface, THEN the gate fails naming the field key.
- GIVEN the form is submitted against the real API, WHEN the request is in flight, THEN the form element carries `aria-busy="true"`, and when the response settles the attribute is removed.
- GIVEN a field type registered per CMP-UI-05 after the built-in seed, WHEN a task using it renders, THEN it carries the full attribute set without an edit to any file under `web/src/pages/`.
- GIVEN the Task Inbox with a rendered form, WHEN the GRD-UI-06 axe scan runs on it, THEN there is no `serious` or `critical` violation of the `label`, `aria-valid-attr-value` or `aria-required-attr` rules.

**See:** GRD-UI-06, CMP-UI-05, CMP-UI-03, TK-UI-01
