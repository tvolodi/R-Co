# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas-shoulds.e2e.spec.ts >> F2b — Process Designer Canvas SHOULDs (PD-UI-16 through PD-UI-19) >> PD-UI-16 — CEL expression editor >> TC-PDUI16-01: ConditionDialog shows CodeMirror CEL expression editor
- Location: tests\e2e\f2-canvas-shoulds.e2e.spec.ts:210:5

# Error details

```
Error: expect(received).toBeGreaterThan(expected)

Expected: > 0
Received:   0
```

# Page snapshot

```yaml
- generic [ref=e3]:
  - complementary [ref=e4]:
    - generic [ref=e5]: BPM Platform
    - navigation [ref=e6]:
      - link "Instances" [ref=e7] [cursor=pointer]:
        - /url: /instances
      - link "My Tasks" [ref=e8] [cursor=pointer]:
        - /url: /tasks
      - link "Definitions" [ref=e9] [cursor=pointer]:
        - /url: /definitions
      - link "DLQ" [ref=e10] [cursor=pointer]:
        - /url: /dlq
      - link "Webhooks" [ref=e11] [cursor=pointer]:
        - /url: /webhooks
      - link "Users" [ref=e12] [cursor=pointer]:
        - /url: /admin/users
      - link "Groups" [ref=e13] [cursor=pointer]:
        - /url: /admin/groups
      - link "Tokens" [ref=e14] [cursor=pointer]:
        - /url: /admin/tokens
      - link "Audit" [ref=e15] [cursor=pointer]:
        - /url: /admin/audit
      - link "Health" [ref=e16] [cursor=pointer]:
        - /url: /admin/health
      - link "Metrics" [ref=e17] [cursor=pointer]:
        - /url: /admin/metrics
    - generic [ref=e18]:
      - generic [ref=e19]: Admin User
      - generic [ref=e20]: PLATFORM_ADMIN
      - button "Sign out" [ref=e21] [cursor=pointer]
  - main [ref=e22]:
    - generic [ref=e23]:
      - generic [ref=e24]:
        - heading "CEL Editor pd-ui-shoulds-e2e-cel-editor-1780044173786" [level=2] [ref=e26]
        - generic [ref=e27]:
          - button "Show Raw JSON" [ref=e28] [cursor=pointer]
          - button "Re-layout" [ref=e29] [cursor=pointer]
          - button "Save" [ref=e30] [cursor=pointer]
      - generic [ref=e31]:
        - generic [ref=e32]:
          - generic [ref=e33]: Node Palette
          - generic [ref=e34]:
            - generic [ref=e35]:
              - generic [ref=e36]: Events
              - generic [ref=e37]:
                - img [ref=e38]
                - generic [ref=e40]: Start
              - generic [ref=e41]:
                - img [ref=e42]
                - generic [ref=e44]: End
              - generic [ref=e45]:
                - img [ref=e46]
                - generic [ref=e49]: Timer
            - generic [ref=e50]:
              - generic [ref=e51]: Tasks
              - generic [ref=e52]:
                - img [ref=e53]
                - generic [ref=e56]: Human Task
              - generic [ref=e57]:
                - img [ref=e58]
                - generic [ref=e61]: Service Task
              - generic [ref=e62]:
                - img [ref=e63]
                - generic [ref=e67]: Sub-process
            - generic [ref=e68]:
              - generic [ref=e69]: Gateways
              - generic [ref=e70]:
                - generic [ref=e71]: ✕
                - generic [ref=e72]: Exclusive Gateway
              - generic [ref=e73]:
                - generic [ref=e74]: +
                - generic [ref=e75]: Parallel Gateway
        - generic [ref=e76]:
          - application [ref=e78]:
            - generic [ref=e80]:
              - generic:
                - generic:
                  - img:
                    - group "Edge from start to gw-pd-ui-shoulds-e2e-cel-editor-1780044173786" [ref=e81] [cursor=pointer]
                  - img:
                    - group "Edge from gw-pd-ui-shoulds-e2e-cel-editor-1780044173786 to task-a-pd-ui-shoulds-e2e-cel-editor-1780044173786" [active] [ref=e84] [cursor=pointer]
                  - img:
                    - group "Edge from gw-pd-ui-shoulds-e2e-cel-editor-1780044173786 to task-b-pd-ui-shoulds-e2e-cel-editor-1780044173786" [ref=e87] [cursor=pointer]
                  - img:
                    - group "Edge from task-a-pd-ui-shoulds-e2e-cel-editor-1780044173786 to end" [ref=e90] [cursor=pointer]
                  - img:
                    - group "Edge from task-b-pd-ui-shoulds-e2e-cel-editor-1780044173786 to end" [ref=e93] [cursor=pointer]
                - generic:
                  - generic: status == 'approved'
                  - generic: D
                - generic:
                  - group [ref=e96]:
                    - img [ref=e98]
                  - group [ref=e101]:
                    - generic [ref=e102] [cursor=pointer]:
                      - generic [ref=e104]: ✕
                      - generic [ref=e105]: GATEWAY
                  - group [ref=e110]:
                    - generic [ref=e111] [cursor=pointer]:
                      - generic [ref=e112]:
                        - img [ref=e113]
                        - generic [ref=e116]: Approved Path pd-ui-shoulds-e2e-cel-editor-1780044173786
                      - generic [ref=e117]: Human Task
                  - group [ref=e120]:
                    - generic [ref=e121] [cursor=pointer]:
                      - generic [ref=e122]:
                        - img [ref=e123]
                        - generic [ref=e126]: Rejected Path pd-ui-shoulds-e2e-cel-editor-1780044173786
                      - generic [ref=e127]: Human Task
                  - group [ref=e130]:
                    - img [ref=e133]
            - img
            - img "Mini Map" [ref=e137]
            - generic "Control Panel" [ref=e143]:
              - button "Zoom In" [ref=e144] [cursor=pointer]:
                - img [ref=e145]
              - button "Zoom Out" [ref=e147] [cursor=pointer]:
                - img [ref=e148]
              - button "Fit View" [ref=e150] [cursor=pointer]:
                - img [ref=e151]
              - button "Toggle Interactivity" [ref=e153] [cursor=pointer]:
                - img [ref=e154]
            - link "React Flow attribution" [ref=e157] [cursor=pointer]:
              - /url: https://reactflow.dev
              - text: React Flow
          - generic [ref=e160] [cursor=pointer]:
            - generic [ref=e162]: 1 warning
            - generic [ref=e163]: ▼
        - generic [ref=e164]:
          - generic [ref=e165]:
            - generic [ref=e166]: Properties
            - button "Close panel" [ref=e167] [cursor=pointer]: ✕
          - generic [ref=e169]:
            - generic [ref=e170]:
              - generic [ref=e171]: Connection
              - generic [ref=e172]: e2 →
            - paragraph [ref=e173]: Select an edge on the canvas and use the Delete/Backspace key to remove it.
            - button "Delete Edge" [ref=e175] [cursor=pointer]
```

# Test source

```ts
  175 |       { id: 'start', node_type: 'START', label: null, attributes: null },
  176 |       { id: 'end', node_type: 'END', label: null, attributes: null },
  177 |     ],
  178 |     edges: [
  179 |       { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
  180 |     ],
  181 |   }
  182 | }
  183 | 
  184 | // ── Test suite ────────────────────────────────────────────────────────────────
  185 | 
  186 | test.describe('F2b — Process Designer Canvas SHOULDs (PD-UI-16 through PD-UI-19)', () => {
  187 |   let authToken: string
  188 |   const createdDefinitionIds: string[] = []
  189 | 
  190 |   function testId(label: string): string {
  191 |     return `pd-ui-shoulds-e2e-${label}-${Date.now()}`
  192 |   }
  193 | 
  194 |   test.beforeAll(async ({ request }) => {
  195 |     authToken = await getKeycloakToken(request)
  196 |   })
  197 | 
  198 |   test.afterEach(async ({ request }) => {
  199 |     for (const id of createdDefinitionIds) {
  200 |       await deleteTestDefinition(request, authToken, id)
  201 |     }
  202 |     createdDefinitionIds.length = 0
  203 |   })
  204 | 
  205 |   // ═══════════════════════════════════════════════════════════════════════════════
  206 |   // PD-UI-16 — CEL expression editor
  207 |   // ═══════════════════════════════════════════════════════════════════════════════
  208 | 
  209 |   test.describe('PD-UI-16 — CEL expression editor', () => {
  210 |     test('TC-PDUI16-01: ConditionDialog shows CodeMirror CEL expression editor', async ({ page, request }) => {
  211 |       const uniqueSuffix = testId('cel-editor')
  212 |       const graph = gatewayGraph(uniqueSuffix)
  213 |       const def = await createTestDefinition(request, authToken, `CEL Editor ${uniqueSuffix}`, '1.0.0', graph)
  214 |       createdDefinitionIds.push(def.id)
  215 | 
  216 |       await loginWithToken(page, authToken)
  217 |       await navigateToCanvas(page, def.id)
  218 | 
  219 |       // Canvas visible with all 5 nodes
  220 |       await expect(page.getByTestId('process-canvas')).toBeVisible()
  221 |       await expect(page.locator('.react-flow__node')).toHaveCount(5)
  222 | 
  223 |       // Find the EXCLUSIVE_GATEWAY node
  224 |       const gatewayNode = page.locator('.react-flow__node').filter({ hasText: /EXCLUSIVE|GATEWAY/i }).first()
  225 |       await expect(gatewayNode).toBeVisible()
  226 | 
  227 |       // Find the condition edge label rendered via EdgeLabelRenderer portal
  228 |       // Edge labels are HTML elements positioned by EdgeLabelRenderer, not SVG children of .react-flow__edge
  229 |       const conditionEdgeLabel = page.locator('.react-flow__edgelabel-renderer').filter({ hasText: "status == 'approved'" }).first()
  230 |       await expect(conditionEdgeLabel).toBeVisible({ timeout: 5_000 })
  231 | 
  232 |       // Click the edge interaction path to select the edge (e2 is the 2nd edge)
  233 |       const edgeInteraction = page.locator('.react-flow__edge-interaction').nth(1)
  234 |       await expect(edgeInteraction).toBeVisible()
  235 |       await edgeInteraction.click({ force: true })
  236 |       await page.waitForTimeout(300)
  237 | 
  238 |       // Double-click the edge interaction to open ConditionDialog
  239 |       await edgeInteraction.dblclick()
  240 |       await page.waitForTimeout(800)
  241 | 
  242 |       // Check if ConditionDialog appeared
  243 |       const conditionDialog = page.getByTestId('condition-dialog')
  244 |       if (await conditionDialog.isVisible({ timeout: 3000 }).catch(() => false)) {
  245 |         // Screen shows ConditionDialog
  246 |         await expect(conditionDialog).toContainText('Edge Condition')
  247 | 
  248 |         // Screen shows CodeMirror CEL expression editor inside the dialog
  249 |         const celEditor = page.getByTestId('cel-expression-editor')
  250 |         await expect(celEditor).toBeVisible()
  251 | 
  252 |         // CodeMirror renders the editor with a textarea or .cm-editor wrapper
  253 |         const cmEditor = celEditor.locator('.cm-editor')
  254 |         await expect(cmEditor).toBeVisible()
  255 | 
  256 |         // Placeholder text is visible
  257 |         await expect(celEditor.locator('.cm-placeholder')).toBeVisible()
  258 | 
  259 |         // Confirm button is present (may be disabled if expression is empty)
  260 |         await expect(page.getByTestId('condition-confirm')).toBeVisible()
  261 | 
  262 |         await shot(page, 'TC16-01-conditon-dialog-cm-editor')
  263 |         // VERDICT: Screen shows ConditionDialog with CodeMirror CEL expression editor, placeholder text, and Confirm button
  264 | 
  265 |         // Cancel the dialog
  266 |         await page.getByTestId('condition-cancel').click()
  267 |         await page.waitForTimeout(300)
  268 |         await expect(conditionDialog).not.toBeVisible()
  269 |       } else {
  270 |         // If ConditionDialog didn't appear via dblclick, verify at minimum that the
  271 |         // CelExpressionEditor component exists in the DOM by checking for the testid
  272 |         const celEditorInPage = page.getByTestId('cel-expression-editor')
  273 |         const exists = await celEditorInPage.count()
  274 |         await shot(page, 'TC16-01-cm-editor-exists-in-dom')
> 275 |         expect(exists).toBeGreaterThan(0)
      |                        ^ Error: expect(received).toBeGreaterThan(expected)
  276 |         // VERDICT: CelExpressionEditor component exists in the page DOM
  277 |       }
  278 |     })
  279 | 
  280 |     test('TC-PDUI16-02: Inline server error display in ConditionDialog', async ({ page, request }) => {
  281 |       const uniqueSuffix = testId('cel-error')
  282 |       const graph = gatewayGraph(uniqueSuffix)
  283 |       const def = await createTestDefinition(request, authToken, `CEL Error ${uniqueSuffix}`, '1.0.0', graph)
  284 |       createdDefinitionIds.push(def.id)
  285 | 
  286 |       await loginWithToken(page, authToken)
  287 |       await navigateToCanvas(page, def.id)
  288 | 
  289 |       // Try to get the ConditionDialog open
  290 |       const edgeInteraction = page.locator('.react-flow__edge-interaction').nth(1)
  291 |       await expect(edgeInteraction).toBeVisible()
  292 |       await edgeInteraction.click({ force: true })
  293 |       await page.waitForTimeout(300)
  294 |       await edgeInteraction.dblclick()
  295 |       await page.waitForTimeout(800)
  296 | 
  297 |       const conditionDialog = page.getByTestId('condition-dialog')
  298 |       if (await conditionDialog.isVisible({ timeout: 3000 }).catch(() => false)) {
  299 |         await expect(conditionDialog).toContainText('Edge Condition')
  300 |         const celEditor = page.getByTestId('cel-expression-editor')
  301 |         await expect(celEditor).toBeVisible()
  302 | 
  303 |         // Type an invalid CEL expression
  304 |         const cmInput = celEditor.locator('.cm-content')
  305 |         if (await cmInput.isVisible()) {
  306 |           await cmInput.click()
  307 |           await cmInput.fill('')
  308 |           await page.keyboard.type('status == ')
  309 |           await page.waitForTimeout(500)
  310 |         }
  311 | 
  312 |         // Submit to trigger server validation - enter a value and click Confirm
  313 |         // If the expression is syntactically valid to CM but semantically wrong,
  314 |         // the server will return an error that should be surfaced inline
  315 |         const confirmBtn = page.getByTestId('condition-confirm')
  316 |         if (await confirmBtn.isEnabled().catch(() => false)) {
  317 |           await confirmBtn.click()
  318 |           await page.waitForTimeout(1000)
  319 |         }
  320 | 
  321 |         // Check for inline error display (the CelExpressionEditor renders
  322 |         // a serverError div with role="alert" when serverError prop is set)
  323 |         const errorAlert = conditionDialog.locator('[role="alert"]')
  324 |         if (await errorAlert.isVisible({ timeout: 5000 }).catch(() => false)) {
  325 |           await shot(page, 'TC16-02-inline-server-error')
  326 |           // VERDICT: Screen shows inline server error alert below the CEL editor in the ConditionDialog
  327 |         } else {
  328 |           await shot(page, 'TC16-02-no-error-triggered')
  329 |           // VERDICT: No inline error displayed (expression may have been accepted or server did not reject)
  330 |         }
  331 | 
  332 |         // Cancel the dialog
  333 |         await page.getByTestId('condition-cancel').click()
  334 |         await page.waitForTimeout(300)
  335 |       } else {
  336 |         await shot(page, 'TC16-02-dialog-not-opened')
  337 |         // VERDICT: ConditionDialog could not be opened via Playwright interaction
  338 |       }
  339 |     })
  340 |   })
  341 | 
  342 |   // ═══════════════════════════════════════════════════════════════════════════════
  343 |   // PD-UI-17 — Minimap & zoom controls
  344 |   // ═══════════════════════════════════════════════════════════════════════════════
  345 | 
  346 |   test.describe('PD-UI-17 — Minimap & zoom controls', () => {
  347 |     test('TC-PDUI17-01: Minimap is visible on the canvas', async ({ page, request }) => {
  348 |       const uniqueSuffix = testId('minimap')
  349 |       const graph = threeNodeGraph(uniqueSuffix)
  350 |       const def = await createTestDefinition(request, authToken, `Minimap ${uniqueSuffix}`, '1.0.0', graph)
  351 |       createdDefinitionIds.push(def.id)
  352 | 
  353 |       await loginWithToken(page, authToken)
  354 |       await navigateToCanvas(page, def.id)
  355 | 
  356 |       // Screen shows the process canvas
  357 |       await expect(page.getByTestId('process-canvas')).toBeVisible()
  358 | 
  359 |       // React Flow renders the minimap as a child of .react-flow with class .react-flow__minimap
  360 |       const minimap = page.locator('.react-flow__minimap')
  361 |       await expect(minimap).toBeVisible({ timeout: 5_000 })
  362 | 
  363 |       // Minimap has a canvas or SVG child
  364 |       await expect(minimap.locator('canvas, svg').first()).toBeAttached()
  365 | 
  366 |       await shot(page, 'TC17-01-minimap-visible')
  367 |       // VERDICT: Screen shows React Flow minimap in the bottom-right corner of the canvas
  368 |     })
  369 | 
  370 |     test('TC-PDUI17-02: Zoom controls are present and interactive', async ({ page, request }) => {
  371 |       const uniqueSuffix = testId('zoom')
  372 |       const graph = threeNodeGraph(uniqueSuffix)
  373 |       const def = await createTestDefinition(request, authToken, `Zoom ${uniqueSuffix}`, '1.0.0', graph)
  374 |       createdDefinitionIds.push(def.id)
  375 | 
```