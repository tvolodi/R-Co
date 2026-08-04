# Process Designer Canvas — Batch 2 Enhancements

**Module:** Visual Canvas (React Flow) — Enhancement Layer  
**Stage:** F2 Batch 2 — Canvas Quality-of-Life Features  
**Requirements:** PD-UI-16 (CEL expression editor), PD-UI-17 (Minimap & zoom), PD-UI-18 (Auto-layout), PD-UI-19 (Undo/redo)  
**Date:** 2026-05-29  
**Designer:** CODE-DESIGNER  
**Classification:** Type E (all four — novel UI components / cross-cutting state)

---

## 1. Module Purpose

The Batch 2 enhancements add four quality-of-life features to the Process Designer canvas that were deferred from Batch 1. They sit on top of the existing React Flow foundation without altering the core node/edge rendering, converter functions, or save workflow:

1. **CEL expression editor** (PD-UI-16) — replaces the plain `<textarea>` in `ConditionDialog` with a code editor widget (CodeMirror) that provides CEL syntax highlighting, bracket matching, and inline server-error display.
2. **Canvas minimap & zoom controls** (PD-UI-17) — adds React Flow's built-in `<MiniMap />` and `<Controls />` components to the canvas for large-graph navigation.
3. **Auto-layout** (PD-UI-18) — a "Re-layout" toolbar button that runs a DAG layout algorithm (dagre) on the current graph and updates node positions.
4. **Undo/redo** (PD-UI-19) — a Zustand-based history stack that captures every canvas mutation and enables Ctrl+Z / Ctrl+Y for all user actions.

---

## 2. Classification Rationale

| Requirement | Lego type | Reason |
|---|---|---|
| PD-UI-16 | **E** | Novel UI widget (code editor with custom CEL mode) — not a list page, CRUD endpoint, migration, or node type. |
| PD-UI-17 | **E** | Canvas configuration change (add `<MiniMap/>` + `<Controls/>`) — a one-line JSX addition, but interacts with existing component layout. |
| PD-UI-18 | **E** | Integration of external DAG layout library (dagre) — requires a layout algorithm function and toolbar button. |
| PD-UI-19 | **E** | Cross-cutting state management (Zustand history stack) that wraps all canvas mutation entry points. |

---

## 3. Component Hierarchy Changes

### 3.1 New and modified components

```
DefinitionEditorPage                        [MODIFIED — toolbar additions, undo/redo wiring]
 └── DefinitionEditorShell                  [existing — carries toolbar]
      ├── NodePalette                       [unchanged]
      ├── ProcessCanvas                     [MODIFIED — MiniMap, Controls, undo/redo hooks]
      │    ├── <ReactFlow>
      │    │    ├── <MiniMap />             [NEW — PD-UI-17]
      │    │    └── <Controls />            [NEW — PD-UI-17]
      │    └── ConditionDialog              [MODIFIED — CodeMirror replaces textarea; PD-UI-16]
      ├── ValidationSummaryBar              [unchanged]
      ├── PropertyPanel                     [unchanged]
      └── CelExpressionEditor               [NEW — reusable code editor; PD-UI-16]
```

### 3.2 New files

| File | Purpose |
|---|---|
| `web/src/components/canvas/CelExpressionEditor.tsx` | CodeMirror 6 wrapper with CEL syntax highlighting, bracket matching, and server error display |
| `web/src/stores/canvasHistoryStore.ts` | Zustand store with `past`/`future` stacks for undo/redo |
| `web/src/utils/canvas/autoLayout.ts` | Dagre-based layout algorithm: `applyLayout(nodes, edges) => positioned Nodes` |

### 3.3 Modified files

| File | Change |
|---|---|
| `web/src/components/canvas/ConditionDialog.tsx` | Replace `<textarea>` with `<CelExpressionEditor>`; add `serverError` prop |
| `web/src/components/canvas/ProcessCanvas.tsx` | Add `<MiniMap />` and `<Controls />` inside `<ReactFlow>`; integrate undo/redo hooks |
| `web/src/pages/definitions/DefinitionEditorPage.tsx` | Add "Re-layout" toolbar button; wire undo/redo keyboard shortcuts; track `serverErrors` from save response |
| `web/package.json` | Add `@codemirror/lang-cel` (or custom CEL mode), `@codemirror/view`, `@codemirror/state`, `@dagrejs/dagre` |

---

## 4. PD-UI-16 — CEL Expression Editor

### 4.1 Purpose

Replace the plain `<textarea>` in the `ConditionDialog` with a proper code editor that provides:
- CEL syntax highlighting (keywords, strings, booleans, numbers, operators)
- Bracket matching (highlight matching `()`, `{}`, `[]`)
- Basic line numbers (optional, recommended)
- Inline error display for server-side syntax validation errors (from PD-06 on save)

### 4.2 Component API

```typescript
// CelExpressionEditor.tsx
interface CelExpressionEditorProps {
  value: string
  onChange: (value: string) => void
  disabled?: boolean
  serverError?: string | null       // from save response — surfaced inline below editor
  placeholder?: string
  minHeight?: string                // default: "80px"
}
```

### 4.3 Library choice: CodeMirror 6

**Decision:** CodeMirror 6 over Monaco Editor.

| Criteria | CodeMirror 6 | Monaco Editor |
|---|---|---|
| Bundle size | ~200 KB gzipped | ~2 MB gzipped |
| CEL syntax support | Custom mode via `@codemirror/language` (StreamLanguage) | Custom ` monarch` language (heavier) |
| Bracket matching | Built-in `@codemirror/autocomplete` → `closeBrackets()` | Built-in |
| React integration | `@uiw/react-codemirror` (thin wrapper) | `@monaco-editor/react` |
| Bundled in Vite | Full tree-shaking possible | Large single bundle |
| Suitability | ✅ Matches a single-field editor | Overkill for a 3-line expression field |

### 4.4 CEL syntax highlighting

A custom `StreamLanguage` parser for the CEL grammar will be implemented as a small (~50-line) module. The parser recognises:

- **Keywords**: `true`, `false`, `null`, `in`, `as`, `not`, `and`, `or`, `matches`, `contains`, `startsWith`, `endsWith`
- **Types**: `int`, `uint`, `double`, `string`, `bytes`, `list`, `map`, `bool`, `null_type`, `dyn`, `any`
- **Strings**: double-quoted with escape sequences `\n`, `\t`, `\\`, `\"`, `\xNN`, `\uNNNN`
- **Numbers**: integers and floats
- **Operators**: `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`, `+`, `-`, `*`, `/`, `%`
- **Comments**: `//` single-line
- **Identifiers**: alphanumeric with `.` path separator, `[]` indexing

The parser will be placed in `web/src/utils/cel/celLanguage.ts`.

### 4.5 Server error integration

After a save operation (`PUT /definitions/:id`), the backend may return validation errors per PD-06. The `DefinitionEditorPage` will extract errors scoped to edge conditions and pass them down to `ConditionDialog` → `CelExpressionEditor`.

```typescript
// Error shape from PD-06 (RFC 9457)
interface ServerValidationError {
  detail: Array<{
    loc: string          // e.g. "graph.edges[2].condition"
    message: string
    type: string
  }>
}

// Flow:
// DefinitionEditorPage.handleSave
//   → catches API error
//   → parses RFC 9457 response
//   → filters detail items where loc contains "condition"
//   → maps to { edgeId, message }
//   → passes to ProcessCanvas via new prop `conditionErrors: Map<string, string>`
//   → ProcessCanvas passes to ConditionDialog via `serverError` prop
//   → ConditionDialog passes to CelExpressionEditor via `serverError` prop
```

### 4.6 Error display

```
┌──────────────────────────────────────┐
│  CEL Expression                       │
│  ┌────────────────────────────────┐   │
│  │ status == 'approved'           │   │
│  │                                │   │
│  └────────────────────────────────┘   │
│  ⚠ Syntax error at position 7:       │
│  expecting '==' got '==='            │  ← inline error
└──────────────────────────────────────┘
```

The error text is rendered as a `<div>` immediately below the CodeMirror widget, styled with `--color-error` text and `--color-error-light` background, with `aria-describedby` linking the editor to the error node for accessibility.

---

## 5. PD-UI-17 — Minimap & Zoom Controls

### 5.1 Purpose

Add spatial navigation aids for large process graphs (>20 nodes).

### 5.2 Implementation

React Flow ships built-in components:

```tsx
import { MiniMap, Controls } from '@xyflow/react'

// Inside <ReactFlow> in ProcessCanvas.tsx:
<ReactFlow ...>
  <Background color="#ccc" gap={20} />
  <MiniMap
    nodeColor={(node) => {
      // Match node type colors for minimap fidelity
      const type = (node.data as CanvasNodeData)?.nodeType
      switch (type) {
        case 'START':           return 'var(--color-brand-400)'
        case 'END':             return 'var(--color-error)'
        case 'EXCLUSIVE_GATEWAY': return 'var(--color-warning-dark)'
        case 'PARALLEL_GATEWAY':  return 'var(--color-success-dark)'
        default:                return 'var(--color-brand-500)'
      }
    }}
    maskColor="rgba(0,0,0,0.1)"
    style={{ position: 'absolute', bottom: 12, right: 12, borderRadius: 8, boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }}
  />
  <Controls
    position="bottom-left"
    style={{ borderRadius: 8, boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }}
  />
</ReactFlow>
```

### 5.3 Layout considerations

- `<MiniMap />` is positioned `bottom-right` with `position: absolute` (React Flow's built-in positioning)
- `<Controls />` is positioned `bottom-left` — this avoids overlap with the minimap
- Both components are rendered inside the `<ReactFlow>` component tree and respect the canvas viewport
- The minimap is **always visible** — no toggle is required by the requirement
- In **read-only mode**, both minimap and controls remain visible (navigation is still useful)

### 5.4 Zoom controls

`<Controls />` renders three buttons by default:

| Button | Action | Keyboard equivalent |
|---|---|---|
| `+` | Zoom in | Ctrl+Scroll up |
| `−` | Zoom out | Ctrl+Scroll down |
| `⟳` (fit) | Fit view to all nodes | — |

No custom zoom levels are needed — React Flow defaults (0.25× to 4×) are sufficient.

### 5.5 Conditionally hidden on small canvases

Not required by PD-UI-17. The minimap and controls are always rendered. If the graph fits the viewport, the minimap simply shows a small preview.

---

## 6. PD-UI-18 — Auto-Layout

### 6.1 Purpose

Provide a one-click "Re-layout" button that automatically arranges all canvas nodes using a DAG layout algorithm, producing a clean left-to-right or top-to-bottom flow.

### 6.2 Library: `@dagrejs/dagre`

| Concern | Decision |
|---|---|
| **Library** | `@dagrejs/dagre` (the maintained fork of `dagre`) |
| **npm package** | `npm install @dagrejs/dagre` |
| **Bundle impact** | ~40 KB minified, ~12 KB gzipped |
| **Algorithm** | Directed acyclic graph layered layout (Sugiyama-style) |
| **Rank direction** | Top-to-bottom (`TB`) — matches BPMN process flow convention |

### 6.3 Auto-layout function

```typescript
// web/src/utils/canvas/autoLayout.ts

export function applyLayout(
  nodes: Node<CanvasNodeData>[],
  edges: Edge[],
  direction: 'TB' | 'LR' = 'TB',
): { nodes: Node<CanvasNodeData>[] }
```

**Algorithm:** Creates a `dagre.graphlib.Graph`, registers each node with type-appropriate dimensions (180×72 for tasks, 56×56 for gateways, 48×48 for START/END), registers all edges, calls `dagre.layout(g)`, and maps laid-out positions back onto the node array. Node positions are offset by half-width/half-height so the dagre center coordinates become top-left origin for React Flow.

### 6.4 UI integration

A "Re-layout" button is added to the toolbar in `DefinitionEditorPage.tsx`, next to the "Show Raw JSON" button:

```
[Show Raw JSON] [Re-layout] [Save]
```

On click:
1. Read current nodes/edges from `canvasStateRef`
2. Call `applyLayout(nodes, edges)`
3. Update canvas state via `setNodes` (passed through a new prop `onAutoLayout` on `ProcessCanvas`)
4. Mark dirty
5. The undo stack captures the pre-layout state (see PD-UI-19), so Ctrl+Z undoes the re-layout

The button is **disabled** in read-only mode.

### 6.5 When auto-layout runs automatically

- On **initial load** when a definition has no persisted node positions (e.g. imported from JSON, or created before Batch 1 shipped position persistence)
- This is handled in `graphToFlow.ts` — if no node has `position` attributes, run `applyLayout()` before returning the initial nodes

---

## 7. PD-UI-19 — Undo/Redo

### 7.1 Purpose

Support Ctrl+Z (undo) and Ctrl+Y (redo) for all canvas operations: add node, delete node, move node, add edge, delete edge, edit node property, auto-layout.

### 7.2 Store design: Zustand

A dedicated Zustand store (`canvasHistoryStore.ts`) manages a **past/future stack** of canvas snapshots.

```typescript
// web/src/stores/canvasHistoryStore.ts

interface CanvasSnapshot {
  nodesJSON: string
  edgesJSON: string
}

interface CanvasHistoryState {
  past: CanvasSnapshot[]
  future: CanvasSnapshot[]
  maxDepth: number
  pushSnapshot: (snapshot: CanvasSnapshot) => void
  undo: (current: CanvasSnapshot) => CanvasSnapshot | null
  redo: (current: CanvasSnapshot) => CanvasSnapshot | null
  clear: () => void
}
```

**Implementation:** `pushSnapshot` appends to `past[]` capped at `maxDepth` (50) and clears `future[]`. `undo` pops the last element from `past[]`, pushes the current snapshot onto `front of future[]`, and returns the popped snapshot. `redo` does the inverse. All three use Zustand set/get.

### 7.3 Integration points

#### 7.3.1 Snapshot triggers

A snapshot is pushed to the history **before** each user-initiated mutation. The following events trigger `pushSnapshot`:

| Trigger | Where | Condition |
|---|---|---|
| Node added (palette double-click) | `ProcessCanvas` `useEffect` for `paletteAddTrigger` | Before `setNodes` |
| Node added (drag-drop) | `ProcessCanvas` `onDrop` | Before `setNodes` |
| Node moved | `ProcessCanvas` `handleNodesChange` with `type: 'position'` change | Debounced (300 ms after last position change) |
| Node deleted | `ProcessCanvas` `handleNodesChange` with `type: 'remove'` | Immediately |
| Edge added | `ProcessCanvas` `onConnect` | Before edge creation |
| Edge deleted | `ProcessCanvas` `handleEdgesChange` with `type: 'remove'` | Immediately |
| Node property edited | `ProcessCanvas` `useEffect` for `nodeUpdateTrigger` | Before `setNodes` |
| Auto-layout applied | `ProcessCanvas` `onAutoLayout` prop handler | Before setting new positions |

**Debounce for node dragging:** Position changes fire rapidly during drag. A debounced snapshot at 300 ms prevents flooding the history stack while still enabling undo of node positions.

#### 7.3.2 Keyboard shortcuts

Registered at the `DefinitionEditorPage` level via a `useEffect` with `keydown` listener:

```typescript
useEffect(() => {
  const handler = (e: KeyboardEvent) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'z' && !e.shiftKey) {
      e.preventDefault()
      handleUndo()
    }
    if ((e.ctrlKey || e.metaKey) && e.key === 'z' && e.shiftKey) {
      e.preventDefault()
      handleRedo()
    }
    if ((e.ctrlKey || e.metaKey) && e.key === 'y') {
      e.preventDefault()
      handleRedo()
    }
  }
  window.addEventListener('keydown', handler)
  return () => window.removeEventListener('keydown', handler)
}, [])
```

`handleUndo` and `handleRedo` are callbacks that:
1. Call `canvasHistoryStore.undo(current)` / `canvasHistoryStore.redo(current)`
2. If a snapshot is returned, parse `nodesJSON`/`edgesJSON` and call `setNodes`/`setEdges` with the restored state
3. Mark dirty

#### 7.3.3 React Flow `onNodesChange` interception

The existing `handleNodesChange` callback in `ProcessCanvas` wraps `onNodesChange`. For undo/redo, we need to detect position changes and push snapshots:

```typescript
const handleNodesChange: OnNodesChange<Node<CanvasNodeData>> = useCallback(
  (changes) => {
    // Snapshot before position changes (with debounce)
    const hasPositionChange = changes.some(c => c.type === 'position' && c.dragging === false)
    const hasRemove = changes.some(c => c.type === 'remove')
    if (hasPositionChange || hasRemove) {
      takeSnapshot()   // pushes current state to history
    }
    onNodesChange(changes)
    onDirtyChange(true)
  },
  [onNodesChange, onDirtyChange],
)
```

### 7.4 Cursor visual feedback

No explicit undo/redo UI widget is required by PD-UI-19. The standard Ctrl+Z/Ctrl+Y keyboard shortcuts are sufficient. However, a simple tooltip or toast ("Undo: moved node" / "Redo: deleted edge") shown for 1.5 seconds via the existing Toast component is **recommended** to confirm the action, especially when undoing a delete or auto-layout.

### 7.5 History preservation

The history stack is **not persisted** across page reloads. On save or definition reload, `clear()` is called. This matches user expectations — refreshing the page or saving resets the undo history.

---

## 8. Data Flow

```mermaid
flowchart TD
    subgraph Inputs [User actions]
        DB[Double-click palette]
        DD[Drag-drop node]
        DM[Drag move node]
        EC[Connect handles]
        EP[Edit property]
        AL[Re-layout btn]
        KU[Ctrl+Z]
        KR[Ctrl+Y]
    end

    subgraph Canvas [ProcessCanvas]
        NS[useNodesState]
        ES[useEdgesState]
        HS[canvasHistoryStore]
        SNAP[takeSnapshot]
        RF[ReactFlow]
        MM[MiniMap]
        CT[Controls]
    end

    subgraph Dialogs
        CD[ConditionDialog]
        CEL[CelExpressionEditor]
    end

    subgraph Utils
        ALG[applyLayout]
        FT[flowToGraph]
    end

    EC --> CD --> CEL --> ES
    AL --> ALG --> NS
    KU --> HS -->|undo| NS + ES
    KR --> HS -->|redo| NS + ES
    NS --> RF --> MM & CT
    SV --> FT -->|PUT /definitions/:id| API -->|errors| CEL
    NS & ES --> SNAP --> HS
```

---

## 9. Error Taxonomy

### PD-UI-16 — CEL Expression Editor

| Error | Source | Display |
|---|---|---|
| Server-side CEL syntax error | `PUT /definitions/:id` response (PD-06 validation) | Red text inline below editor, `aria-describedby` linkage |
| Server-side CEL type error | Same response | Same treatment |
| Network failure on save | Fetch/axios network error | Toast: "Failed to save definition" (existing pattern) |
| Invalid CEL expression (client-side heuristic) | Optional: basic `cel-syntax` parse with regex | Lightweight warning below editor (not a hard block) |

### PD-UI-17 — Minimap & Zoom

No error states. Components are purely presentational.

### PD-UI-18 — Auto-Layout

| Error | Source | Display |
|---|---|---|
| Dagre layout failure (cyclic graph) | `dagre.layout()` throws | `try/catch` → toast: "Auto-layout failed: graph contains cycles" |
| Empty graph (no nodes) | `applyLayout` called with empty array | Toast: "No nodes to layout" |

### PD-UI-19 — Undo/Redo

| Error | Source | Display |
|---|---|---|
| Nothing to undo | `past` stack empty | No-op (no feedback needed) |
| Nothing to redo | `future` stack empty | No-op (no feedback needed) |
| JSON parse error on snapshot restore | Corrupted snapshot data (edge case) | `try/catch` → silent fallback (do not crash canvas) |

---

## 10. Dependencies

### Runtime dependencies (new — to be added to `web/package.json`)

| Package | Version | Purpose | Estimated size |
|---|---|---|---|
| `@codemirror/view` | ^6.35 | Core CodeMirror view layer | 120 KB (gzip ~40 KB) |
| `@codemirror/state` | ^6.5 | CodeMirror editor state | 30 KB (gzip ~10 KB) |
| `@codemirror/language` | ^6.10 | StreamLanguage for custom CEL mode | 25 KB (gzip ~8 KB) |
| `@codemirror/autocomplete` | ^6.18 | `closeBrackets()` for bracket matching | 15 KB (gzip ~5 KB) |
| `@codemirror/commands` | ^6.7 | Basic key bindings | 8 KB (gzip ~3 KB) |
| `@uiw/react-codemirror` | ^4.23 | React wrapper for CodeMirror 6 | 5 KB (gzip ~2 KB) |
| `@dagrejs/dagre` | ^1.1 | DAG layout algorithm | 40 KB (gzip ~12 KB) |

All are MIT-licensed.

### No new dependencies needed for

- **Minimap + Controls** (`@xyflow/react` already includes them; currently imported but not rendered)
- **Undo/redo** (Zustand already in `package.json`)

### Module dependencies

| Module | Depends on | Must NOT depend on |
|---|---|---|
| `CelExpressionEditor` | `@codemirror/*`, `@uiw/react-codemirror`, `celLanguage` | React Flow, Zustand, API client |
| `canvasHistoryStore` | `zustand` | React, React Flow |
| `autoLayout` | `@dagrejs/dagre` | React, React Flow (pure function) |
| `celLanguage` | (none — standalone parser) | Any framework |

---

## 11. State Transitions

### Canvas undo/redo state machine

```
                         ┌─────────────────┐
                         │   Idle (no ops)  │
                         └────────┬────────┘
                                  │ user action
                                  ▼
                  ┌───────────────────────────────┐
                  │    pushSnapshot(current)      │
                  │    → append to past[]         │
                  │    → clear future[]           │
                  └───────────────┬───────────────┘
                                  │ apply mutation
                                  ▼
                         ┌─────────────────┐
                         │  Canvas updated  │
                         └────────┬────────┘
                    ┌─────────────┼─────────────┐
                    │             │             │
                    ▼             ▼             ▼
              ┌──────────┐ ┌──────────┐ ┌──────────┐
              │ Ctrl+Z   │ │ Ctrl+Y   │ │ New op   │
              └────┬─────┘ └────┬─────┘ └────┬─────┘
                   │            │             │
                   ▼            ▼             │
          ┌────────────────┐ ┌──────────────┐ │
          │ undo(current)  │ │ redo(current)│ │
          │ → pop past[]   │ │ → pop future │ │
          │ → current→future│ │ → current→past│ │
          │ → restore snap │ │ → restore snap│ │
          └───────┬────────┘ └──────┬────────┘ │
                  │                 │           │
                  └─────────────────┘           │
                            │                   │
                            ▼                   │
                   ┌────────────────┐           │
                   │ Canvas restored│───────────┘
                   └────────────────┘
```

### Auto-layout trigger

```
                    ┌─────────────────┐
                    │  Re-layout btn  │
                    └────────┬────────┘
                             │
                             ▼
              ┌──────────────────────────┐
              │ pushSnapshot(current)    │ ← capture pre-layout state
              │   (enables Ctrl+Z)       │
              └───────────┬──────────────┘
                          │
                          ▼
              ┌──────────────────────────┐
              │ applyLayout(nodes, edges)│
              │ → returns positioned[]   │
              └───────────┬──────────────┘
                          │
                          ▼
              ┌──────────────────────────┐
              │ setNodes(positioned)     │
              │ fitView()               │
              └──────────────────────────┘
```

---

## 12. Open Questions

1. **PD-UI-16: CEL syntax highlighting scope.** The requirement says "CEL syntax highlighting". Should we implement a full CEL language mode (tokens, keywords, string escapes, comments) or a simpler "CEL-like" mode (generic expression highlighter)? **Recommendation:** Full CEL mode — it is ~50 lines of `StreamLanguage` configuration and provides correct highlighting. No open question needed — proceed with full CEL mode.

2. **PD-UI-18: Layout direction.** Should the auto-layout default to top-to-bottom (`TB`) or left-to-right (`LR`)? BPMN process flows are typically top-to-bottom (start → end). The function accepts a `direction` parameter but the default should be `TB`. **Recommendation:** Default `TB`, no UI toggle needed for Batch 2.

3. **PD-UI-19: History depth.** What is the max history depth? 50 is a reasonable default — it provides ~50 undo steps without unbounded memory growth. Each snapshot is a JSON string of nodes+edges (typically 1–5 KB for a moderate graph). 50 × 5 KB = ~250 KB max. **Recommendation:** 50, configurable via a constant.

4. **PD-UI-16: Do we need both Monaco AND CodeMirror support?** The requirement says "Monaco or CodeMirror". The design chooses CodeMirror for its smaller bundle size, which is more appropriate for a single-field editor. **Recommendation:** CodeMirror 6 only, no fallback to Monaco.

5. **PD-UI-17: Should minimap be toggleable?** The requirement does not specify a toggle. **Recommendation:** Always visible, no toggle needed.

6. **PD-UI-19: Should there be a visible undo/redo button in the toolbar?** The requirement only specifies Ctrl+Z/Ctrl+Y keyboard shortcuts. **Recommendation:** No toolbar button in Batch 2. Can be added later as a tooltip or dropdown.

---

## 13. Acceptance Criteria Checklist

| Criterion | Verification |
|---|---|
| PD-UI-16: ConditionDialog uses code editor with CEL highlighting | Visual inspection — CEL keywords are coloured differently from strings |
| PD-UI-16: Bracket matching works | Type `(` → the matching `)` is highlighted when cursor is next to one |
| PD-UI-16: Server errors shown inline below editor | Mock a save error with `condition`-scoped detail item → error text appears below CodeMirror |
| PD-UI-17: Minimap visible in bottom-right | Canvas renders a small minimap widget showing a miniature of the graph |
| PD-UI-17: Zoom controls visible in bottom-left | Three buttons (+ / − / fit) are rendered |
| PD-UI-17: Zoom controls work | Click `+` → graph zooms in; click `−` → zooms out; click fit → all nodes visible |
| PD-UI-18: Re-layout button exists in toolbar | Button labelled "Re-layout" visible in non-read-only mode |
| PD-UI-18: Auto-layout arranges nodes neatly | Nodes with messy positions are rearranged into a clean top-to-bottom DAG |
| PD-UI-18: Graph with cycles shows error toast | Create a cycle → click Re-layout → toast "graph contains cycles" |
| PD-UI-19: Ctrl+Z undoes last operation | Add a node → Ctrl+Z → node disappears |
| PD-UI-19: Ctrl+Y redoes the undone operation | After Ctrl+Z → Ctrl+Y → node reappears |
| PD-UI-19: Undo works for all operations | Test: add node, delete node, move node, add edge, edit property, auto-layout → each is undoable |
| PD-UI-19: Auto-layout is undoable | Click Re-layout → Ctrl+Z → nodes return to pre-layout positions |
