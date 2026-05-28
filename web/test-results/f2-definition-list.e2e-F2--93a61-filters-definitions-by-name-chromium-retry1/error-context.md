# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-01 — Definition list >> TC-PDUI01-03: search input filters definitions by name
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:222:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByTestId('def-name-ffae27c3-2bf3-49c2-921e-1257caf6efb3')
Expected: visible
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 5000ms
  - waiting for getByTestId('def-name-ffae27c3-2bf3-49c2-921e-1257caf6efb3')

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
  - heading "Process Definitions" [level=2]
  - textbox "Search definitions...": Alpha pd-ui-e2e-search-1779988153454
  - text: Status
  - combobox:
    - option "All" [selected]
    - option "Draft"
    - option "Active"
    - option "Deprecated"
    - option "Archived"
  - button "+ New Definition"
  - paragraph: No definitions found
```

# Test source

```ts
  142 | ): Promise<void> {
  143 |   const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
  144 |     headers: { 'Authorization': `Bearer ${token}` },
  145 |   })
  146 |   // 204 or 404 are both acceptable (already deleted or not found)
  147 |   if (response.status() !== 204 && response.status() !== 404) {
  148 |     console.warn(`DELETE /definitions/${id} returned ${response.status()}`)
  149 |   }
  150 | }
  151 | 
  152 | // ── Test suite ────────────────────────────────────────────────────────────────
  153 | 
  154 | test.describe('F2 — Definition List View (PD-UI-01 through PD-UI-04)', () => {
  155 |   let authToken: string
  156 |   const createdDefinitionIds: string[] = []
  157 | 
  158 |   /** UUID v4-like id for tracking test-created definitions */
  159 |   function testId(label: string): string {
  160 |     return `pd-ui-e2e-${label}-${Date.now()}`
  161 |   }
  162 | 
  163 |   test.beforeAll(async ({ request }) => {
  164 |     // Obtain a real JWT from Keycloak
  165 |     authToken = await getKeycloakToken(request)
  166 |   })
  167 | 
  168 |   test.afterEach(async ({ request }) => {
  169 |     // Clean up all definitions created during tests
  170 |     for (const id of createdDefinitionIds) {
  171 |       await deleteTestDefinition(request, authToken, id)
  172 |     }
  173 |     createdDefinitionIds.length = 0
  174 |   })
  175 | 
  176 |   // ═══════════════════════════════════════════════════════════════════════════════
  177 |   // PD-UI-01 — Definition list
  178 |   // ═══════════════════════════════════════════════════════════════════════════════
  179 | 
  180 |   test.describe('PD-UI-01 — Definition list', () => {
  181 |     test('TC-PDUI01-01: definition list shows definitions from the backend', async ({ page, request }) => {
  182 |       const uniqueSuffix = testId('list-01')
  183 |       const def1 = await createTestDefinition(request, authToken, `Order Flow ${uniqueSuffix}`, '1.0.0')
  184 |       const def2 = await createTestDefinition(request, authToken, `Approval Flow ${uniqueSuffix}`, '1.0.0')
  185 |       createdDefinitionIds.push(def1.id, def2.id)
  186 | 
  187 |       await loginWithToken(page, authToken)
  188 | 
  189 |       // Navigate to definitions via sidebar (SPA navigation preserves in-memory session)
  190 |       await navigateToDefinitions(page)
  191 | 
  192 |       // Screen shows the definition names in the table
  193 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  194 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  195 | 
  196 |       // Screen shows version, status badge, and creation date for each row
  197 |       // The definition name button is clickable (proves it's a rendered row)
  198 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toContainText(`Order Flow ${uniqueSuffix}`)
  199 | 
  200 |       await shot(page, 'TC01-definition-list')
  201 |       // VERDICT: Screen shows definition list with name buttons for both test definitions
  202 |     })
  203 | 
  204 |     test('TC-PDUI01-02: empty state renders when no definitions exist for search', async ({ page }) => {
  205 |       await loginWithToken(page, authToken)
  206 | 
  207 |       await navigateToDefinitions(page)
  208 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  209 | 
  210 |       // Search for a non-existent definition
  211 |       await page.getByTestId('definition-search').fill(`nonexistent-${Date.now()}`)
  212 |       // Wait for debounce and API response
  213 |       await page.waitForTimeout(1000)
  214 | 
  215 |       // Screen shows "No definitions found" empty message
  216 |       await expect(page.getByText('No definitions found')).toBeVisible({ timeout: 10_000 })
  217 | 
  218 |       await shot(page, 'TC02-empty-state')
  219 |       // VERDICT: Screen shows "No definitions found" when no results match the search query
  220 |     })
  221 | 
  222 |     test('TC-PDUI01-03: search input filters definitions by name', async ({ page, request }) => {
  223 |       const uniqueSuffix = testId('search')
  224 |       const def1 = await createTestDefinition(request, authToken, `Alpha Flow ${uniqueSuffix}`, '1.0.0')
  225 |       const def2 = await createTestDefinition(request, authToken, `Beta Flow ${uniqueSuffix}`, '1.0.0')
  226 |       createdDefinitionIds.push(def1.id, def2.id)
  227 | 
  228 |       await loginWithToken(page, authToken)
  229 |       await navigateToDefinitions(page)
  230 | 
  231 |       // Both definitions visible initially
  232 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  233 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  234 | 
  235 |       // Type search for Alpha only
  236 |       const searchInput = page.getByTestId('definition-search')
  237 |       await searchInput.fill(`Alpha ${uniqueSuffix}`)
  238 |       // Wait for 300ms debounce + API round-trip
  239 |       await page.waitForTimeout(1500)
  240 | 
  241 |       // Screen shows only the Alpha definition
> 242 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      |                                                             ^ Error: expect(locator).toBeVisible() failed
  243 |       await expect(page.getByTestId(`def-name-${def2.id}`)).not.toBeVisible()
  244 | 
  245 |       // URL contains the search parameter
  246 |       await expect(page).toHaveURL(/search=Alpha/)
  247 | 
  248 |       await shot(page, 'TC03-search-filter')
  249 |       // VERDICT: Screen shows only Alpha Flow after typing search query; URL contains search param
  250 |     })
  251 |   })
  252 | 
  253 |   // ═══════════════════════════════════════════════════════════════════════════════
  254 |   // PD-UI-02 — Status filter
  255 |   // ═══════════════════════════════════════════════════════════════════════════════
  256 | 
  257 |   test.describe('PD-UI-02 — Status filter', () => {
  258 |     test('TC-PDUI02-01: status filter dropdown shows all four options', async ({ page }) => {
  259 |       await loginWithToken(page, authToken)
  260 |       await navigateToDefinitions(page)
  261 | 
  262 |       // Open the multi-select status filter
  263 |       const statusFilter = page.getByTestId('status-filter')
  264 |       await expect(statusFilter).toBeVisible()
  265 | 
  266 |       // The filter shows the label "Status"
  267 |       await expect(statusFilter).toContainText('Status')
  268 | 
  269 |       await shot(page, 'TC02-01-status-filter-visible')
  270 |       // VERDICT: Screen shows status filter with "Status" label
  271 |     })
  272 | 
  273 |     test('TC-PDUI02-02: selecting Draft filter shows only DRAFT definitions', async ({ page, request }) => {
  274 |       const uniqueSuffix = testId('draft-filter')
  275 |       const draftDef = await createTestDefinition(request, authToken, `Draft Only ${uniqueSuffix}`, '1.0.0')
  276 |       createdDefinitionIds.push(draftDef.id)
  277 | 
  278 |       await loginWithToken(page, authToken)
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
```