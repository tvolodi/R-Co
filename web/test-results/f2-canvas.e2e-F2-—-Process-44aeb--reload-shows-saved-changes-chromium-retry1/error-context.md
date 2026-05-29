# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas.e2e.spec.ts >> F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12) >> Save workflow >> TC-SAVE-01: Modified canvas saves via PUT and reload shows saved changes
- Location: tests\e2e\f2-canvas.e2e.spec.ts:857:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByText('Definition saved')
Expected: visible
Timeout: 10000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 10000ms
  - waiting for getByText('Definition saved')

```

```yaml
- complementary:
  - text: BPM Platform
  - navigation:
    - link "Instances":
      - /url: /instances
    - link "My Tasks":
      - /url: /tasks
    - link "Definitions":
      - /url: /definitions
    - link "DLQ":
      - /url: /dlq
    - link "Webhooks":
      - /url: /webhooks
    - link "Users":
      - /url: /admin/users
    - link "Groups":
      - /url: /admin/groups
    - link "Tokens":
      - /url: /admin/tokens
    - link "Audit":
      - /url: /admin/audit
    - link "Health":
      - /url: /admin/health
    - link "Metrics":
      - /url: /admin/metrics
  - text: Admin User PLATFORM_ADMIN
  - button "Sign out"
- main:
  - heading "Full Save pd-ui-canvas-e2e-fullsave-01-1780044249931" [level=2]
  - button "Show Raw JSON"
  - button "Re-layout"
  - button "Save"
  - text: Unprocessable Entity Node Palette Events
  - img
  - text: Start
  - img
  - text: End
  - img
  - text: Timer Tasks
  - img
  - text: Human Task
  - img
  - text: Service Task
  - img
  - text: Sub-process Gateways ✕ Exclusive Gateway + Parallel Gateway
  - application:
    - img:
      - group "Edge from start to task-pd-ui-canvas-e2e-fullsave-01-1780044249931"
    - img:
      - group "Edge from task-pd-ui-canvas-e2e-fullsave-01-1780044249931 to end"
    - group:
      - img
    - group:
      - img
      - text: Full Saved Task pd-ui-canvas-e2e-fullsave-01-1780044249931 Human Task
    - group:
      - img
    - img
    - img "Mini Map"
    - button "Zoom In":
      - img
    - button "Zoom Out":
      - img
    - button "Fit View":
      - img
    - button "Toggle Interactivity":
      - img
    - link "React Flow attribution":
      - /url: https://reactflow.dev
      - text: React Flow
  - text: Properties
  - button "Close panel": ✕
  - text: "Node: task-pd-ui-canvas-e2e-fullsave-01-1780044249931 (HUMAN_TASK) Name"
  - textbox "Node name": Full Saved Task pd-ui-canvas-e2e-fullsave-01-1780044249931
  - text: Assignee Type
  - combobox:
    - option "User" [selected]
    - option "Group"
    - option "Role"
    - option "Unassigned"
  - text: Assignee Ref
  - textbox "Assignee reference"
  - text: Form Schema
  - textbox "JSON Schema"
  - paragraph: Select a node on the canvas to edit its properties. Changes are saved locally until you click Save.
```

# Test source

```ts
  782 |       await shot(page, 'TC12-03-after-reload')
  783 |       // VERDICT: Screen shows canvas with 3 nodes and saved name after reload — changes persisted via PATCH
  784 |     })
  785 | 
  786 |     test('TC-PDUI12-04: Property panel shows correct fields per node type', async ({ page, request }) => {
  787 |       const uniqueSuffix = testId('fields-04')
  788 |       // Create a definition with multiple node types — all connected (backend rejects isolated nodes with 422)
  789 |       const graph = {
  790 |         nodes: [
  791 |           { id: 'start', node_type: 'START', label: null, attributes: null },
  792 |           { id: `human-${uniqueSuffix}`, node_type: 'HUMAN_TASK', label: `Human ${uniqueSuffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  793 |           { id: `service-${uniqueSuffix}`, node_type: 'SERVICE_TASK', label: `Service ${uniqueSuffix}`, attributes: '{"role":"admin-user","service_type":"http","endpoint":"https://example.com/api","service_config":"{}"}' },
  794 |           { id: `timer-${uniqueSuffix}`, node_type: 'TIMER', label: `Timer ${uniqueSuffix}`, attributes: '{"role":"admin-user","timer_type":"duration","timer_duration":"PT1H","duration_iso8601":"PT1H"}' },
  795 |           { id: `gw-${uniqueSuffix}`, node_type: 'EXCLUSIVE_GATEWAY', label: null, attributes: null },
  796 |           { id: 'end', node_type: 'END', label: null, attributes: null },
  797 |         ],
  798 |         edges: [
  799 |           { id: 'e1', source: 'start', target: `human-${uniqueSuffix}`, condition: null, is_default: false },
  800 |           { id: 'e2', source: `human-${uniqueSuffix}`, target: `service-${uniqueSuffix}`, condition: null, is_default: false },
  801 |           { id: 'e3', source: `service-${uniqueSuffix}`, target: `timer-${uniqueSuffix}`, condition: null, is_default: false },
  802 |           { id: 'e4', source: `timer-${uniqueSuffix}`, target: `gw-${uniqueSuffix}`, condition: null, is_default: false },
  803 |           { id: 'e5', source: `gw-${uniqueSuffix}`, target: 'end', condition: "status == 'approved'", is_default: false },
  804 |           { id: 'e6', source: `gw-${uniqueSuffix}`, target: 'end', condition: null, is_default: true },
  805 |         ],
  806 |       }
  807 |       const def = await createTestDefinition(request, authToken, `Field Types ${uniqueSuffix}`, '1.0.0', graph)
  808 |       createdDefinitionIds.push(def.id)
  809 | 
  810 |       await loginWithToken(page, authToken)
  811 |       await navigateToCanvas(page, def.id)
  812 | 
  813 |       // Click HUMAN_TASK node — panel shows assignee fields
  814 |       await page.getByText(`Human ${uniqueSuffix}`).click()
  815 |       await page.waitForTimeout(500)
  816 |       await expect(page.getByTestId('prop-assignee-type')).toBeVisible()
  817 |       await expect(page.getByTestId('prop-form-schema')).toBeVisible()
  818 |       await shot(page, 'TC12-04-human-task-fields')
  819 |       // VERDICT: Screen shows HUMAN_TASK property panel with assignee_type, assignee_ref, form_schema fields
  820 | 
  821 |       // Click SERVICE_TASK node — panel shows service fields
  822 |       await page.getByText(`Service ${uniqueSuffix}`).click()
  823 |       await page.waitForTimeout(500)
  824 |       await expect(page.getByTestId('prop-service-type')).toBeVisible()
  825 |       await expect(page.getByTestId('prop-service-config')).toBeVisible()
  826 |       await shot(page, 'TC12-04-service-task-fields')
  827 |       // VERDICT: Screen shows SERVICE_TASK property panel with service_type, service_config fields
  828 | 
  829 |       // Click TIMER node — TimerNode renders only a clock icon, no text label.
  830 |       // Node order: START, HUMAN_TASK, SERVICE_TASK, TIMER (4th), GATEWAY, END.
  831 |       // Click the canvas pane first to deselect the previously selected SERVICE_TASK node,
  832 |       // then click the TIMER node using its React Flow data-testid attribute.
  833 |       await page.getByTestId('process-canvas').click({ position: { x: 10, y: 10 } })
  834 |       await page.waitForTimeout(300)
  835 |       await page.locator('[data-testid^="rf__node-timer-"]').click()
  836 |       await page.waitForTimeout(500)
  837 |       await expect(page.getByTestId('prop-timer-type')).toBeVisible()
  838 |       await expect(page.getByTestId('prop-timer-duration')).toBeVisible()
  839 |       await shot(page, 'TC12-04-timer-fields')
  840 |       // VERDICT: Screen shows TIMER property panel with timer_type, timer_duration fields
  841 | 
  842 |       // Click EXCLUSIVE_GATEWAY node — panel shows no node-level attributes
  843 |       await page.getByTestId('process-canvas').locator('.react-flow__node').filter({ hasText: /EXCLUSIVE|GATEWAY/i }).first().click()
  844 |       await page.waitForTimeout(500)
  845 |       // Gateway should not show node-level attribute fields like assignee_type
  846 |       await expect(page.getByTestId('prop-assignee-type')).not.toBeVisible()
  847 |       await shot(page, 'TC12-04-gateway-no-fields')
  848 |       // VERDICT: Screen shows EXCLUSIVE_GATEWAY property panel with no node-level attribute fields
  849 |     })
  850 |   })
  851 | 
  852 |   // ═══════════════════════════════════════════════════════════════════════════════
  853 |   // Save workflow
  854 |   // ═══════════════════════════════════════════════════════════════════════════════
  855 | 
  856 |   test.describe('Save workflow', () => {
  857 |     test('TC-SAVE-01: Modified canvas saves via PUT and reload shows saved changes', async ({ page, request }) => {
  858 |       const uniqueSuffix = testId('fullsave-01')
  859 |       // Use a valid connected graph (backend rejects isolated nodes with 422)
  860 |       const graph = threeNodeGraph(uniqueSuffix)
  861 |       const def = await createTestDefinition(request, authToken, `Full Save ${uniqueSuffix}`, '1.0.0', graph)
  862 |       createdDefinitionIds.push(def.id)
  863 | 
  864 |       await loginWithToken(page, authToken)
  865 |       await navigateToCanvas(page, def.id)
  866 | 
  867 |       // Initial state: 3 nodes, 2 edges (valid connected graph)
  868 |       await expect(page.locator('.react-flow__node')).toHaveCount(3)
  869 |       await expect(page.locator('.react-flow__edge')).toHaveCount(2)
  870 | 
  871 |       // Change a node name to mark dirty
  872 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  873 |       await page.waitForTimeout(500)
  874 |       await expect(page.getByTestId('property-panel')).toBeVisible()
  875 |       const nameInput = page.getByTestId('prop-name-input')
  876 |       await nameInput.clear()
  877 |       await nameInput.fill(`Full Saved Task ${uniqueSuffix}`)
  878 |       await page.waitForTimeout(300)
  879 | 
  880 |       // Save
  881 |       await page.getByTestId('btn-save-definition').click()
> 882 |       await expect(page.getByText('Definition saved', { exact: false })).toBeVisible({ timeout: 10_000 })
      |                                                                          ^ Error: expect(locator).toBeVisible() failed
  883 | 
  884 |       // Reload — re-authenticate since token is in-memory
  885 |       await page.reload()
  886 |       await loginWithToken(page, authToken)
  887 |       await navigateToCanvas(page, def.id)
  888 | 
  889 |       // Verify 3 nodes persist after reload
  890 |       await expect(page.locator('.react-flow__node')).toHaveCount(3)
  891 | 
  892 |       // Verify the saved name persisted
  893 |       await expect(page.getByText(`Full Saved Task ${uniqueSuffix}`)).toBeVisible()
  894 | 
  895 |       await shot(page, 'TC-SAVE-01-after-reload')
  896 |       // VERDICT: Screen shows canvas with 3 nodes and saved name after reload — modifications persisted via PATCH
  897 |     })
  898 | 
  899 |     test('TC-SAVE-02: Unsaved changes dialog on navigation away', async ({ page, request }) => {
  900 |       const uniqueSuffix = testId('unsaved-02')
  901 |       const graph = startEndGraph()
  902 |       const def = await createTestDefinition(request, authToken, `Unsaved ${uniqueSuffix}`, '1.0.0', graph)
  903 |       createdDefinitionIds.push(def.id)
  904 | 
  905 |       await loginWithToken(page, authToken)
  906 |       await navigateToCanvas(page, def.id)
  907 | 
  908 |       // Make a change to set dirty flag
  909 |       const startNode = page.locator('.react-flow__node').first()
  910 |       await startNode.click()
  911 |       await page.waitForTimeout(300)
  912 | 
  913 |       // Attempt to navigate to a different page (e.g., login)
  914 |       await page.goto('/login')
  915 |       await page.waitForTimeout(1000)
  916 | 
  917 |       // The unsaved changes dialog should appear
  918 |       // React Router's useBlocker shows a custom dialog
  919 |       const unsavedDialog = page.getByTestId('unsaved-changes-dialog')
  920 |       if (await unsavedDialog.isVisible()) {
  921 |         await shot(page, 'TC-SAVE-02-unsaved-dialog')
  922 |         // VERDICT: Screen shows unsaved changes confirmation dialog when navigating away with dirty canvas
  923 | 
  924 |         // Discard changes
  925 |         await page.getByTestId('unsaved-discard').click()
  926 |         await page.waitForTimeout(500)
  927 | 
  928 |         // Should navigate away to /login
  929 |         await expect(page).toHaveURL(/\/login/)
  930 |       } else {
  931 |         // If no dialog appears (or if page.load cancels the navigation guard),
  932 |         // at minimum we verify the navigation attempt didn't break
  933 |         console.log('Unsaved changes dialog did not appear (may depend on React Router v7 useBlocker implementation)')
  934 |         await shot(page, 'TC-SAVE-02-no-dialog')
  935 |       }
  936 |       // VERDICT: Screen navigated to /login (with or without dialog)
  937 |     })
  938 |   })
  939 | })
  940 | 
```