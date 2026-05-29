# Test Spec: PD-UI-17 — Canvas Minimap & Zoom

**Requirement:** PD-UI-17 — The canvas SHALL include a minimap for large graphs and zoom controls (fit-to-screen, zoom in/out).
**Priority:** SHOULD
**Test layer:** e2e (Playwright against real backend)
**Run:** WF02-f2b-shoulds-20260529
**Design ref:** `src/design/canvas-f2-batch1.md`

---

## Test Cases

### TC-PDUI17-01: Minimap is visible on the canvas

**Given:** A DRAFT definition editor page is open
**When:** The canvas has loaded with nodes
**Then:** Screen shows a minimap in the bottom-right corner of the canvas (React Flow `.react-flow__minimap` element is present and visible)
**Layer:** e2e
**Acceptance criterion mapped:** Minimap present on canvas

---

### TC-PDUI17-02: Zoom controls are present and interactive

**Given:** The definition editor page is open
**When:** The canvas has loaded
**Then:** Screen shows the React Flow Controls component in the bottom-left corner with zoom-in, zoom-out, and fit-to-view buttons (`.react-flow__controls` element is present); clicking zoom-in increases the viewport scale
**Layer:** e2e
**Acceptance criterion mapped:** Zoom controls present and functional
