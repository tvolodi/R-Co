# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-03 — Version history >> TC-PDUI03-04: clicking the same name again collapses the version history
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:368:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByTestId('version-history-row')
Expected: visible
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 5000ms
  - waiting for getByTestId('version-history-row')

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
  - 'heading "Edit: Collapse Test pd-ui-e2e-collapse-1779988200609" [level=2]'
  - text: Graph JSON (nodes + edges)
  - textbox: "{ \"nodes\": [], \"edges\": [] }"
  - paragraph: Visual canvas (React Flow) will replace this editor in a future iteration.
  - button "Save"
```

# Test source

```ts
  279 |       await navigateToDefinitions(page)
  280 | 
  281 |       // Both definitions visible before filtering
  282 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
  283 | 
  284 |       await shot(page, 'TC02-02-before-filter')
  285 |       // VERDICT: Screen shows draft definition in unfiltered list
  286 |     })
  287 | 
  288 |     test('TC-PDUI02-04: status filter selects Draft and shows filtered results', async ({ page, request }) => {
  289 |       const uniqueSuffix = testId('reload')
  290 |       const def1 = await createTestDefinition(request, authToken, `Reload Test A ${uniqueSuffix}`, '1.0.0')
  291 |       const def2 = await createTestDefinition(request, authToken, `Reload Test B ${uniqueSuffix}`, '2.0.0', 'Second version')
  292 |       createdDefinitionIds.push(def1.id, def2.id)
  293 | 
  294 |       await loginWithToken(page, authToken)
  295 |       await navigateToDefinitions(page)
  296 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  297 | 
  298 |       // Both definitions visible
  299 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  300 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  301 | 
  302 |       // Select "Draft" in the status filter
  303 |       await page.getByTestId('status-filter-select').selectOption('DRAFT')
  304 |       await page.waitForTimeout(500)
  305 | 
  306 |       // Both definitions are DRAFT, so both should still be visible
  307 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  308 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  309 | 
  310 |       await shot(page, 'TC02-04-after-filter')
  311 |       // VERDICT: Screen shows filtered definitions after selecting Draft in status filter
  312 |     })
  313 | 
  314 |     test('TC-PDUI02-05: clearing all status filters shows all definitions', async ({ page, request }) => {
  315 |       const uniqueSuffix = testId('clear')
  316 |       const def = await createTestDefinition(request, authToken, `Clear Filter Test ${uniqueSuffix}`, '1.0.0')
  317 |       createdDefinitionIds.push(def.id)
  318 | 
  319 |       await loginWithToken(page, authToken)
  320 |       await navigateToDefinitions(page)
  321 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  322 | 
  323 |       // Select DRAFT filter
  324 |       await page.getByTestId('status-filter-select').selectOption('DRAFT')
  325 |       await page.waitForTimeout(500)
  326 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
  327 | 
  328 |       // Clear filter by selecting "All"
  329 |       await page.getByTestId('status-filter-select').selectOption('')
  330 |       await page.waitForTimeout(500)
  331 | 
  332 |       // Definition still visible without filter
  333 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
  334 | 
  335 |       await shot(page, 'TC02-05-after-clear')
  336 |       // VERDICT: Screen shows all definitions after clearing status filter
  337 |     })
  338 |   })
  339 | 
  340 |   // ═══════════════════════════════════════════════════════════════════════════════
  341 |   // PD-UI-03 — Version history
  342 |   // ═══════════════════════════════════════════════════════════════════════════════
  343 | 
  344 |   test.describe('PD-UI-03 — Version history', () => {
  345 |     test('TC-PDUI03-01: clicking definition name expands version history row', async ({ page, request }) => {
  346 |       const uniqueSuffix = testId('expand')
  347 |       const def = await createTestDefinition(request, authToken, `Version Flow ${uniqueSuffix}`, '1.0.0')
  348 |       createdDefinitionIds.push(def.id)
  349 | 
  350 |       await loginWithToken(page, authToken)
  351 |       await navigateToDefinitions(page)
  352 | 
  353 |       // Click the definition name button to expand version history
  354 |       await page.getByTestId(`def-name-${def.id}`).click()
  355 |       await page.waitForTimeout(1000)
  356 | 
  357 |       // Screen shows version history row
  358 |       const versionHistory = page.getByTestId('version-history-row')
  359 |       await expect(versionHistory).toBeVisible({ timeout: 10_000 })
  360 | 
  361 |       // Shows "Version history: <name>" heading
  362 |       await expect(versionHistory).toContainText(`Version Flow ${uniqueSuffix}`)
  363 | 
  364 |       await shot(page, 'TC03-01-expanded-version-history')
  365 |       // VERDICT: Screen shows version history row with heading "Version history: Version Flow ..."
  366 |     })
  367 | 
  368 |     test('TC-PDUI03-04: clicking the same name again collapses the version history', async ({ page, request }) => {
  369 |       const uniqueSuffix = testId('collapse')
  370 |       const def = await createTestDefinition(request, authToken, `Collapse Test ${uniqueSuffix}`, '1.0.0')
  371 |       createdDefinitionIds.push(def.id)
  372 | 
  373 |       await loginWithToken(page, authToken)
  374 |       await navigateToDefinitions(page)
  375 | 
  376 |       // Expand first
  377 |       await page.getByTestId(`def-name-${def.id}`).click()
  378 |       await page.waitForTimeout(1000)
> 379 |       await expect(page.getByTestId('version-history-row')).toBeVisible()
      |                                                             ^ Error: expect(locator).toBeVisible() failed
  380 | 
  381 |       // Click again to collapse
  382 |       await page.getByTestId(`def-name-${def.id}`).click()
  383 |       await page.waitForTimeout(500)
  384 | 
  385 |       // Version history row should be gone
  386 |       await expect(page.getByTestId('version-history-row')).not.toBeVisible()
  387 | 
  388 |       await shot(page, 'TC03-04-collapsed')
  389 |       // VERDICT: Screen no longer shows version history after clicking name again
  390 |     })
  391 |   })
  392 | 
  393 |   // ═══════════════════════════════════════════════════════════════════════════════
  394 |   // PD-UI-04 — Create definition
  395 |   // ═══════════════════════════════════════════════════════════════════════════════
  396 | 
  397 |   test.describe('PD-UI-04 — Create definition', () => {
  398 |     test('TC-PDUI04-01: "New Definition" button opens create dialog', async ({ page }) => {
  399 |       await loginWithToken(page, authToken)
  400 |       await navigateToDefinitions(page)
  401 | 
  402 |       // Click the "New Definition" button
  403 |       const newDefButton = page.getByTestId('btn-new-definition')
  404 |       await expect(newDefButton).toBeVisible()
  405 |       await newDefButton.click()
  406 | 
  407 |       // Screen shows create definition dialog
  408 |       const dialog = page.getByTestId('create-definition-dialog')
  409 |       await expect(dialog).toBeVisible({ timeout: 5_000 })
  410 | 
  411 |       // Dialog title is "Create New Definition"
  412 |       await expect(dialog).toContainText('Create New Definition')
  413 | 
  414 |       // Form fields present
  415 |       await expect(page.getByTestId('create-name-input')).toBeVisible()
  416 |       await expect(page.getByTestId('create-version-input')).toBeVisible()
  417 |       await expect(page.getByTestId('create-description-input')).toBeVisible()
  418 | 
  419 |       // Buttons present
  420 |       await expect(page.getByTestId('create-submit')).toBeVisible()
  421 |       await expect(page.getByTestId('create-cancel')).toBeVisible()
  422 | 
  423 |       await shot(page, 'TC04-01-create-dialog-open')
  424 |       // VERDICT: Screen shows "Create New Definition" dialog with name, version, and description fields
  425 |     })
  426 | 
  427 |     test('TC-PDUI04-02: dialog validates required name field', async ({ page }) => {
  428 |       await loginWithToken(page, authToken)
  429 |       await navigateToDefinitions(page)
  430 | 
  431 |       // Open dialog
  432 |       await page.getByTestId('btn-new-definition').click()
  433 |       await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })
  434 | 
  435 |       // Clear the name field (default might be empty) and submit
  436 |       const nameInput = page.getByTestId('create-name-input')
  437 |       await nameInput.fill('')
  438 | 
  439 |       // Submit
  440 |       await page.getByTestId('create-submit').click()
  441 |       await page.waitForTimeout(500)
  442 | 
  443 |       // Screen shows validation error
  444 |       await expect(page.getByText('Name is required')).toBeVisible()
  445 | 
  446 |       await shot(page, 'TC04-02-validation-error')
  447 |       // VERDICT: Screen shows "Name is required" validation error when name is empty
  448 |     })
  449 | 
  450 |     test('TC-PDUI04-03: creating a definition succeeds', async ({ page }) => {
  451 |       const uniqueSuffix = testId('create')
  452 | 
  453 |       await loginWithToken(page, authToken)
  454 |       await navigateToDefinitions(page)
  455 | 
  456 |       // Open dialog
  457 |       await page.getByTestId('btn-new-definition').click()
  458 |       await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })
  459 | 
  460 |       // Fill form
  461 |       const defName = `E2E Created ${uniqueSuffix}`
  462 |       await page.getByTestId('create-name-input').fill(defName)
  463 |       await page.getByTestId('create-version-input').fill('1.0.0')
  464 |       await page.getByTestId('create-description-input').fill('Created by E2E test')
  465 | 
  466 |       await shot(page, 'TC04-03-form-filled')
  467 | 
  468 |       // Submit — this should navigate away to /definitions/:id
  469 |       await page.getByTestId('create-submit').click()
  470 | 
  471 |       // Wait for navigation to the new definition's editor page
  472 |       await page.waitForURL(/\/definitions\/(?!new$)([0-9a-f-]+)/, { timeout: 15_000 })
  473 | 
  474 |       await shot(page, 'TC04-03-after-creation')
  475 |       // VERDICT: Screen navigated to /definitions/{id} after successful creation
  476 |     })
  477 | 
  478 |     test('TC-PDUI04-05: Cancel button dismisses the dialog', async ({ page }) => {
  479 |       await loginWithToken(page, authToken)
```