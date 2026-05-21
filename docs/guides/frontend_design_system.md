# BPM Platform — Frontend Design System

**Version:** 0.1 · 2026-05-20  
**Agent ID:** `FRONTEND-DEV`  
**Audience:** Frontend Developer agent

---

## 1. Design Principles

1. **Clarity over cleverness** — operators under pressure need scannable information, not clever UI patterns.
2. **Status is always visible** — process status, task status, and instance state must be immediately identifiable without reading text.
3. **Destructive actions require confirmation** — cancel, delete, discard, revoke must never fire on a single click.
4. **Density with breathing room** — data tables are dense; cards have generous padding.

---

## 2. Color Tokens

All colors are defined as CSS custom properties in `web/src/styles/tokens.css`. Never use raw hex/rgb values outside this file.

### 2.1 Base palette

```css
:root {
  /* Neutrals */
  --color-neutral-0:   #ffffff;
  --color-neutral-50:  #f8f9fa;
  --color-neutral-100: #f1f3f5;
  --color-neutral-200: #e9ecef;
  --color-neutral-300: #dee2e6;
  --color-neutral-400: #ced4da;
  --color-neutral-500: #adb5bd;
  --color-neutral-600: #6c757d;
  --color-neutral-700: #495057;
  --color-neutral-800: #343a40;
  --color-neutral-900: #212529;

  /* Brand */
  --color-brand-400: #4dabf7;
  --color-brand-500: #339af0;
  --color-brand-600: #228be6;
  --color-brand-700: #1971c2;

  /* Semantic */
  --color-success-light: #d3f9d8;
  --color-success:       #40c057;
  --color-success-dark:  #2f9e44;

  --color-warning-light: #fff3bf;
  --color-warning:       #fcc419;
  --color-warning-dark:  #e67700;

  --color-error-light:   #ffe3e3;
  --color-error:         #fa5252;
  --color-error-dark:    #c92a2a;

  --color-info-light:    #dbe4ff;
  --color-info:          #4c6ef5;
  --color-info-dark:     #3b5bdb;
}
```

### 2.2 Semantic surface tokens

```css
:root {
  --surface-page:       var(--color-neutral-50);
  --surface-card:       var(--color-neutral-0);
  --surface-sidebar:    var(--color-neutral-900);
  --surface-overlay:    rgba(0, 0, 0, 0.5);

  --text-primary:       var(--color-neutral-900);
  --text-secondary:     var(--color-neutral-600);
  --text-disabled:      var(--color-neutral-400);
  --text-inverse:       var(--color-neutral-0);

  --border-default:     var(--color-neutral-200);
  --border-focus:       var(--color-brand-500);
  --border-error:       var(--color-error);

  --interactive-primary:        var(--color-brand-600);
  --interactive-primary-hover:  var(--color-brand-700);
  --interactive-danger:         var(--color-error);
  --interactive-danger-hover:   var(--color-error-dark);
}
```

---

## 3. Typography

```css
:root {
  --font-sans: 'Inter', system-ui, -apple-system, sans-serif;
  --font-mono: 'JetBrains Mono', 'Fira Code', monospace;

  /* Scale */
  --text-xs:   0.75rem;   /* 12px */
  --text-sm:   0.875rem;  /* 14px */
  --text-base: 1rem;      /* 16px */
  --text-lg:   1.125rem;  /* 18px */
  --text-xl:   1.25rem;   /* 20px */
  --text-2xl:  1.5rem;    /* 24px */
  --text-3xl:  1.875rem;  /* 30px */

  /* Weights */
  --font-normal:   400;
  --font-medium:   500;
  --font-semibold: 600;
  --font-bold:     700;
}
```

---

## 4. Spacing & Layout

Use an 8 px base grid. Spacing values: `4, 8, 12, 16, 24, 32, 48, 64` px.

```css
:root {
  --space-1:  4px;
  --space-2:  8px;
  --space-3:  12px;
  --space-4:  16px;
  --space-6:  24px;
  --space-8:  32px;
  --space-12: 48px;
  --space-16: 64px;

  --radius-sm: 4px;
  --radius-md: 8px;
  --radius-lg: 12px;
  --radius-full: 9999px;

  --sidebar-width:     240px;
  --content-max-width: 1280px;
  --panel-width:       400px;
}
```

---

## 5. Status Badge Specifications

`<StatusBadge>` is used across all entity types. Each status has a fixed visual identity.

### 5.1 Definition status

| Status | Background | Text | Dot color |
|---|---|---|---|
| `DRAFT` | `--color-neutral-100` | `--text-secondary` | `--color-neutral-500` |
| `ACTIVE` | `--color-success-light` | `--color-success-dark` | `--color-success` |
| `DEPRECATED` | `--color-warning-light` | `--color-warning-dark` | `--color-warning` |
| `ARCHIVED` | `--color-neutral-200` | `--color-neutral-600` | `--color-neutral-400` |

### 5.2 Instance status

| Status | Background | Text | Dot |
|---|---|---|---|
| `ACTIVE` | `--color-info-light` | `--color-info-dark` | `--color-info` (animated pulse) |
| `COMPLETED` | `--color-success-light` | `--color-success-dark` | `--color-success` |
| `CANCELLED` | `--color-neutral-200` | `--color-neutral-600` | `--color-neutral-400` |
| `ERROR` | `--color-error-light` | `--color-error-dark` | `--color-error` |

### 5.3 Task status

| Status | Background | Text |
|---|---|---|
| `PENDING` | `--color-info-light` | `--color-info-dark` |
| `COMPLETED` | `--color-success-light` | `--color-success-dark` |
| `CANCELLED` | `--color-neutral-200` | `--color-neutral-600` |

### 5.4 Badge component API

```tsx
<StatusBadge
  status="ACTIVE"          // string key from above tables
  domain="instance"        // "definition" | "instance" | "task" | "timer" | "dlq"
  size="sm"                // "sm" | "md" (default md)
/>
```

---

## 6. Process Canvas Node Styles

### 6.1 Node dimensions

| Node type | Width | Min height |
|---|---|---|
| `START` | 48 px (circle) | 48 px |
| `END` | 48 px (circle, double border) | 48 px |
| `HUMAN_TASK` | 180 px | 72 px |
| `EXCLUSIVE_GATEWAY` | 56 px (diamond) | 56 px |
| `PARALLEL_GATEWAY` | 56 px (diamond with +) | 56 px |
| `SERVICE_TASK` | 180 px | 72 px |
| `TIMER` | 56 px (circle with clock icon) | 56 px |
| `SUB_PROCESS` | 200 px | 80 px (dashed border) |

### 6.2 Node states (runtime visualization)

| State | Visual treatment |
|---|---|
| Default | White card, neutral border |
| Active (has token) | Blue border (`--color-brand-500`), animated pulse ring |
| Completed | Green background tint (`--color-success-light`) |
| Error | Red border (`--color-error`), error icon in corner |
| Read-only | Cursor: `default`; no hover effects |

### 6.3 Edge styles

| Edge type | Style |
|---|---|
| Default transition | Solid line, arrow marker, neutral color |
| CEL condition edge | Solid line with a label bubble showing expression (truncated to 30 chars) |
| Default edge (gateway) | Dashed line with `D` marker bubble |
| Cancelled branch | Grey, reduced opacity |

---

## 7. Core UI Components

### 7.1 Button

```tsx
<Button
  variant="primary" | "secondary" | "danger" | "ghost"
  size="sm" | "md" | "lg"
  loading={boolean}           // shows spinner, disables click
  disabled={boolean}
  onClick={handler}
>
  Label
</Button>
```

- `primary`: filled brand color
- `secondary`: outlined, brand color text
- `danger`: filled error color — only for destructive actions
- `ghost`: no border, text only — for low-prominence actions

### 7.2 DataTable

```tsx
<DataTable
  columns={ColumnDef[]}       // TanStack Table column definitions
  data={rows}
  isLoading={boolean}         // shows skeleton rows
  emptyMessage="No instances found"
  onRowClick={(row) => void}  // optional row click handler
/>
```

- Skeleton loading: 5 grey animated rows shown while `isLoading`
- Empty state: centered icon + message
- Sticky header on scroll
- Sortable columns: click header to toggle asc/desc

### 7.3 Dialog (confirmation pattern)

```tsx
<ConfirmDialog
  open={boolean}
  onConfirm={() => void}
  onCancel={() => void}
  title="Cancel Instance?"
  description="All open tasks will be cancelled. This action cannot be undone."
  confirmLabel="Cancel Instance"
  confirmVariant="danger"
/>
```

All destructive actions (cancel instance, delete definition, revoke token, discard DLQ item) MUST use `ConfirmDialog`, not a plain `window.confirm`.

### 7.4 Toast

```tsx
import { useToast } from '../hooks/useToast'

const toast = useToast()
toast.success('Task completed successfully')
toast.error('Failed to cancel instance', { description: error.detail })
toast.warning('Instance is in an error state')
```

- Toasts appear top-right, stack vertically
- Auto-dismiss: success/info after 4 s; error after 8 s (with manual close)
- Max 4 toasts visible simultaneously (older ones drop off)
- Use `aria-live="polite"` for success; `aria-live="assertive"` for errors

### 7.5 JsonEditor

A controlled textarea with JSON syntax validation:

```tsx
<JsonEditor
  value={jsonString}
  onChange={(value, isValid) => void}
  label="Initial Variables"
  height={200}
  readOnly={false}
/>
```

- Shows red border + error message for invalid JSON
- Pretty-prints on blur
- Used for: initial variables, output variables, event payload inspection

### 7.6 DynamicForm

Renders a form from a JSON Schema object:

```tsx
<DynamicForm
  schema={jsonSchema}         // JSON Schema object from task node's form_schema
  onSubmit={(values) => void}
  submitLabel="Complete Task"
  isSubmitting={boolean}
/>
```

**Supported JSON Schema types → input mapping:**

| JSON Schema type/format | Rendered as |
|---|---|
| `string` | `<input type="text">` |
| `string, format: date` | `<input type="date">` |
| `string, format: date-time` | `<input type="datetime-local">` |
| `string, enum: [...]` | `<select>` |
| `number` / `integer` | `<input type="number">` |
| `boolean` | `<input type="checkbox">` |
| `string, maxLength > 200` | `<textarea>` |

---

## 8. Page Layout Template

```tsx
function SomePage() {
  return (
    <PageLayout
      title="Process Instances"
      actions={<Button variant="primary">Start Instance</Button>}
    >
      <FilterBar>
        {/* filters */}
      </FilterBar>
      <DataTable ... />
      <PaginationControls ... />
    </PageLayout>
  )
}
```

`PageLayout` provides:
- Page title (h1) + actions slot (top-right)
- Content area with `--content-max-width` constraint
- Consistent vertical spacing between sections

---

## 9. Responsive Breakpoints

| Name | Min width | Notes |
|---|---|---|
| `mobile` | 375 px | Task Inbox must work here |
| `tablet` | 768 px | Sidebar collapses to hamburger |
| `desktop` | 1024 px | Minimum for all other views (FNFR-07) |
| `wide` | 1280 px | Canvas editor benefits from this |

On `mobile`, the sidebar is hidden behind a hamburger menu (full-screen drawer). The Process Designer canvas is not available on mobile (shown as a notice with a link to open on desktop).
