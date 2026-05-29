# Test Spec: PD-UI-18 — Auto-layout (Re-layout button)

**Requirement:** PD-UI-18 — A "Re-layout" button SHALL apply an automatic DAG layout algorithm (e.g. Dagre) to arrange nodes cleanly.
**Priority:** SHOULD
**Test layer:** e2e (Playwright against real backend)
**Run:** WF02-f2b-shoulds-20260529
**Design ref:** `src/design/canvas-f2-batch1.md`

---

## Test Cases

### TC-PDUI18-01: 'Re-layout' button is present in the toolbar

**Given:** A DRAFT definition editor page is open
**When:** The toolbar loads
**Then:** Screen shows a button labelled "Re-layout" with `data-testid="btn-auto-layout"` in the editor toolbar alongside Save and Show Raw JSON buttons
**Layer:** e2e
**Acceptance criterion mapped:** Re-layout button present in toolbar

---

### TC-PDUI18-02: Clicking 'Re-layout' rearranges nodes

**Given:** The definition editor page is open for a DRAFT definition with multiple nodes in a non-ideal layout
**When:** The user clicks the "Re-layout" button
**Then:** The nodes are rearranged on the canvas by the Dagre layout algorithm; node positions change (positions differ from the initial layout); the canvas remains interactive after re-layout
**Layer:** e2e
**Acceptance criterion mapped:** Re-layout button applies DAG layout algorithm
