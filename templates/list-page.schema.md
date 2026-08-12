# Admin list page template (Lego Type B) — schema reference

Authoritative description of every field in `templates/specs/list-page.template.yaml` and any concrete `templates/specs/<name>.list-page.yaml` parameter file produced from it.

The codegen tool `tools/codegen_list_page.py` consumes this format and emits one file:

- `web/src/pages/<page_slug>/<PageName>.tsx` — React/TypeScript component with filter form, data table, row actions, and optional create form.

**What codegen produces vs. what the implementer writes:**  
Generated boilerplate covers: the filter form with controlled inputs, the table skeleton with header and cell renderers, the `useQuery` / `useMutation` wiring, role-gated action buttons, the create-form dialog, and lint markers (`// lint:F030 queryKey must use queryKeys factory` etc.). The implementer fills in only `// CUSTOM:` blocks: cell formatters that need domain knowledge, confirm-dialog copy, and any non-standard action handlers. Never edit boilerplate outside `// CUSTOM:` blocks; re-run codegen after a spec change.

---

## Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Template version. Currently `1`. Bump only when the YAML schema itself changes. |
| `page_name` | string | yes | PascalCase React component name. Used as the default export name and in the file path: `web/src/pages/<page_slug>/<PageName>.tsx`. |
| `page_slug` | string | yes | Path under `web/src/pages/`. Use `admin/<slug>` for platform-admin pages. |
| `resource_name` | string | yes | Singular, camelCase resource identifier. Used in generated variable names and TanStack Query key expressions. |
| `requirement_ids` | list[string] | yes | MUST requirement IDs this page satisfies. Used by lint to cross-check the requirements doc. |
| `purpose` | string (multi-line) | yes | One-paragraph rationale. Emitted as a leading TSDoc comment in the generated file. |
| `list_query_key` | string | yes | Full `queryKeys.*` expression for the list query. **Must reference the project-wide `queryKeys` factory** — never an inline array literal. Lint rule F030 enforces this. |
| `api` | APIBlock | yes | REST endpoint paths. See **APIBlock** below. |
| `filters` | list[Filter] | yes (may be empty) | Filter inputs rendered above the table. See **Filter** below. |
| `columns` | list[Column] | yes (min 1) | Table column definitions. See **Column** below. |
| `row_actions` | list[RowAction] | yes (may be empty) | Per-row action buttons in the rightmost column. See **RowAction** below. |
| `create_form` | CreateForm or null | no | Inline create form triggered by a `+New` button. `null` omits the button entirely. See **CreateForm** below. |

---

## APIBlock

| Field | Type | Required | Notes |
|---|---|---|---|
| `list_endpoint` | string | yes | `GET` endpoint path that returns paginated rows, e.g. `/api/v1/audit-policies`. |
| `create_endpoint` | string | no | `POST` endpoint path. Required when `create_form` is set. |
| `delete_endpoint` | string | no | `DELETE` endpoint path. Required when any `row_action.action` is `archive` or `delete`. Path params use `:id` convention. |

---

## Filter

Each filter becomes a controlled input rendered in a form above the table. Filter values are passed as query params to `list_endpoint`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | snake_case identifier. Used as the query param name and the input's `id`. |
| `type` | enum: `text`, `select`, `number`, `date` | yes | Input type. `select` requires `options`. |
| `label` | string | yes | Display label for the input. |
| `placeholder` | string | no | Placeholder text (text inputs only). |
| `default` | scalar | no | Default value pre-filled on mount. |
| `options` | list[Option] | when type=select | List of `{ value, label }` pairs. |

### Option

| Field | Type | Notes |
|---|---|---|
| `value` | string | The value sent to the API. Use `""` for the "all" sentinel. |
| `label` | string | Display label. |

---

## Column

Each column entry produces a table header and a cell renderer.

| Field | Type | Required | Notes |
|---|---|---|---|
| `header` | string | yes | Column header text. |
| `accessor` | string | yes | Dotted path into the row data object (e.g. `created_at`, `owner.name`). |
| `format` | enum: `date`, `datetime`, `currency`, `badge` | no | Optional formatter. When absent, the raw string value is rendered. The `date`/`datetime` formatters use the project's `formatDate` util. `badge` renders a coloured pill — colour mapping goes in a `// CUSTOM:` block. |

---

## RowAction

| Field | Type | Required | Notes |
|---|---|---|---|
| `label` | string | yes | Button label text. |
| `action` | enum: `archive`, `delete`, `view`, `edit`, `promote`, `custom` | yes | Semantic action. `archive` and `delete` call `delete_endpoint`. `view` navigates to a detail page. `custom` goes in a `// CUSTOM:` block. |
| `requires_role` | string or null | yes | RBAC role string (e.g. `PLATFORM_ADMIN`). When set, the button is hidden for users without the role — never disabled-only. `null` = visible to all authenticated users. |
| `confirm` | string | no | Confirmation dialog message. When set, codegen wraps the action in a `<ConfirmDialog>`. |

---

## CreateForm

| Field | Type | Required | Notes |
|---|---|---|---|
| `button_label` | string | yes | Label for the `+New` button that opens the form. |
| `fields` | list[FormField] | yes (min 1) | Form inputs. See **FormField** below. |
| `submit_label` | string | yes | Label for the form submit button. |
| `on_success_invalidate` | string | yes | `queryKeys.*` expression to invalidate after a successful create. Must match `list_query_key` in almost all cases. |

### FormField

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | snake_case field name sent in the `POST` body. |
| `type` | enum: `text`, `textarea`, `select`, `number`, `date`, `checkbox` | yes | Input type. `select` requires `options`. |
| `label` | string | yes | Display label. |
| `required` | bool | no | When `true`, codegen adds a client-side required validation. Default `false`. |
| `options` | list[Option] | when type=select | Same `{ value, label }` shape as Filter options. |

---

## Generated output structure

```
web/src/pages/<page_slug>/<PageName>.tsx
├── TSDoc comment from `purpose`
├── Imports (React, TanStack Query, queryKeys, project UI components)
├── Filter form component
│   └── controlled inputs per `filters[]`
├── Table component
│   ├── column definitions per `columns[]`
│   └── // CUSTOM: badge colour map (when format: badge is used)
├── Row action handlers
│   ├── archive/delete handlers (call delete_endpoint + invalidate)
│   └── // CUSTOM: handler body for action: custom
├── CreateForm dialog (when create_form is set)
│   └── form fields per create_form.fields[]
└── Default export: <PageName> (composes the above)
```

---

## CUSTOM: blocks in generated page files

Codegen marks two kinds of implementer-owned regions:

1. **Badge colour mapping** — when a column uses `format: badge`, the generated file emits:

```tsx
// CUSTOM: map status values to badge colours
const statusColour: Record<string, string> = {
  ACTIVE:   "green",
  ARCHIVED: "grey",
  // add more variants here
};
```

2. **Custom row-action handler** — when `action: custom` is used:

```tsx
// CUSTOM: implement this action handler
const handleCustomAction = (row: AuditPolicyRow) => {
  // e.g. navigate to a detail page, open a modal, etc.
};
```

**Rule:** Never delete a `// CUSTOM:` comment. Never hand-edit lines outside `// CUSTOM:` blocks — re-run codegen after updating the YAML instead.

---

## Lint rules (enforced by `tools/lint_frontend_conventions.py` on generated output)

The validator FAILs if any of these are violated in the generated file:

1. F030: `list_query_key` is an inline array (`['resource', 'list']`) rather than a `queryKeys` factory reference.
2. F031: `on_success_invalidate` does not match `list_query_key`.
3. F032: Any `row_action` with `requires_role` set renders a disabled button instead of hiding the element.
4. F033: Any `delete_endpoint` call is made without the matching `confirm` dialog.
5. F034: `page_slug` contains uppercase characters.

---

## Worked example

**Spec:** `templates/specs/svc-04-services-admin-page.list-page.yaml`  
**Generated file:** `web/src/pages/admin/services/ServicesAdminPage.tsx`

The spec declares a `text` search filter, five table columns (including one `format: badge` column for `status`), two row actions (`view` + `archive` with `requires_role: PLATFORM_ADMIN`), and a `create_form`. Codegen emits the full component skeleton. The implementer opens the generated file and fills in:

```tsx
// CUSTOM: map status values to badge colours
const statusColour: Record<string, string> = {
  ACTIVE:      "green",
  INACTIVE:    "red",
  MAINTENANCE: "yellow",
};
```

Everything else (filter binding, query wiring, table rendering, archive mutation with confirm dialog, create-form submit) is boilerplate — do not touch it.

---

## Real-codebase candidates that would have been Type B

- `admin-groups.list-page.yaml` — platform admin group list with create form
- `dlq-items.list-page.yaml` — dead-letter queue item list with re-queue and discard row actions
- `tenant-list.list-page.yaml` — tenant list with platform-admin-only archive action
