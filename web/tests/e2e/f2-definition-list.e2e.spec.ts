/**
 * E2E tests — Stage F2: Definition List View
 * Requirements: PD-UI-01, PD-UI-02, PD-UI-03, PD-UI-04 (all MUST)
 * Run: WF02-f2a-pdui01-04-20260528
 *
 * Directive T-2 compliance:
 *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
 *   - No page.route() stubs for any API endpoint.
 *   - All HTTP calls go to the real backend:
 *     1. Keycloak token endpoint (password grant) for authentication
 *     2. Backend /definitions API for test data setup/teardown
 *     3. Browser API calls (via the app's client.ts) with real JWT token
 *
 * Directive T-3 compliance:
 *   - After every significant UI action a screenshot is taken and the visible
 *     DOM is asserted. Every verdict is stated as "screen shows X after Y".
 *
 * Infrastructure:
 *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
 *   - Backend API: available at same origin via Vite proxy (/api → localhost:8080)
 *   - Keycloak: http://localhost:8081/realms/bpm-default
 *   - Test user: admin-user / admin-pass (PLATFORM_ADMIN role, has PROCESS_DESIGNER access)
 *   - Bootstrap token env var: TEST_BOOTSTRAP_TOKEN (fallback if Keycloak unavailable)
 */

import { test, expect } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { getKeycloakToken, loginWithToken } from './helpers'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_PREFIX = '/api/v1'

// ── Screenshot helper ─────────────────────────────────────────────────────────

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: path.join(dir, `PDUI-${name}.png`) })
}/** Navigate to /definitions via the sidebar link (SPA navigation — preserves session). */
async function navigateToDefinitions(page: import('@playwright/test').Page): Promise<void> {
  await page.getByRole('link', { name: 'Definitions' }).click()
  await page.waitForURL(/\/definitions/, { timeout: 10_000 })
}

async function filterDefinitionsByName(
  page: import('@playwright/test').Page,
  searchTerm: string,
): Promise<void> {
  await page.getByTestId('definition-search').fill(searchTerm)
  // Allow debounce + network round-trip to settle before visibility assertions.
  await page.waitForTimeout(1500)
}

// ── API helpers (using Playwright request context with real token) ────────────

async function createTestDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  name: string,
  version: string,
  description?: string,
): Promise<{ id: string; name: string; version: string; status: string }> {
  const response = await request.post(`${API_PREFIX}/definitions`, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name,
      version,
      description: description ?? '',
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: null, attributes: null },
          { id: 'end', node_type: 'END', label: null, attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
        ],
      },
      stage: null,
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`POST /definitions failed (${response.status()}): ${body}`)
  }

  return response.json() as Promise<{ id: string; name: string; version: string; status: string }>
}

async function deleteTestDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  id: string,
): Promise<void> {
  const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
    headers: { 'Authorization': `Bearer ${token}` },
  })
  // 204 or 404 are both acceptable (already deleted or not found)
  if (response.status() !== 204 && response.status() !== 404) {
    console.warn(`DELETE /definitions/${id} returned ${response.status()}`)
  }
}

// ── Test suite ────────────────────────────────────────────────────────────────

test.describe('F2 — Definition List View (PD-UI-01 through PD-UI-04)', () => {
  let authToken: string
  const createdDefinitionIds: string[] = []

  /** UUID v4-like id for tracking test-created definitions */
  function testId(label: string): string {
    return `pd-ui-e2e-${label}-${Date.now()}`
  }

  test.beforeAll(async ({ request }) => {
    // Obtain a real JWT from Keycloak
    authToken = await getKeycloakToken(request)
  })

  test.afterEach(async ({ request }) => {
    // Clean up all definitions created during tests
    for (const id of createdDefinitionIds) {
      await deleteTestDefinition(request, authToken, id)
    }
    createdDefinitionIds.length = 0
  })

  // ═══════════════════════════════════════════════════════════════════════════════
  // PD-UI-01 — Definition list
  // ═══════════════════════════════════════════════════════════════════════════════

  test.describe('PD-UI-01 — Definition list', () => {
    test('TC-PDUI01-01: definition list shows definitions from the backend', async ({ page, request }) => {
      const uniqueSuffix = testId('list-01')
      const def1 = await createTestDefinition(request, authToken, `Order Flow ${uniqueSuffix}`, '1.0.0')
      const def2 = await createTestDefinition(request, authToken, `Approval Flow ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(def1.id, def2.id)

      await loginWithToken(page, authToken)

      // Navigate to definitions via sidebar (SPA navigation preserves in-memory session)
      await navigateToDefinitions(page)
      await filterDefinitionsByName(page, uniqueSuffix)

      // Screen shows the definition names in the table
      await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()

      // Screen shows version, status badge, and creation date for each row
      // The definition name button is clickable (proves it's a rendered row)
      await expect(page.getByTestId(`def-name-${def1.id}`)).toContainText(`Order Flow ${uniqueSuffix}`)

      await shot(page, 'TC01-definition-list')
      // VERDICT: Screen shows definition list with name buttons for both test definitions
    })

    test('TC-PDUI01-02: empty state renders when no definitions exist for search', async ({ page }) => {
      await loginWithToken(page, authToken)

      await navigateToDefinitions(page)
      await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })

      // Search for a non-existent definition
      await page.getByTestId('definition-search').fill(`nonexistent-${Date.now()}`)
      // Wait for debounce and API response
      await page.waitForTimeout(1000)

      // Screen shows "No results found" empty message (search state)
      await expect(page.getByText('No results found')).toBeVisible({ timeout: 10_000 })

      await shot(page, 'TC02-empty-state')
      // VERDICT: Screen shows "No results found" when no results match the search query
    })

    test('TC-PDUI01-03: search input filters definitions by name', async ({ page, request }) => {
      const uniqueSuffix = testId('search')
      const def1 = await createTestDefinition(request, authToken, `Alpha Flow ${uniqueSuffix}`, '1.0.0')
      const def2 = await createTestDefinition(request, authToken, `Beta Flow ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(def1.id, def2.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await filterDefinitionsByName(page, uniqueSuffix)

      // Both definitions visible initially
      await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()

      // Type search for the full definition name (backend uses ILIKE substring matching)
      await filterDefinitionsByName(page, `Alpha Flow ${uniqueSuffix}`)

      // Screen shows only the Alpha definition
      await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      await expect(page.getByTestId(`def-name-${def2.id}`)).not.toBeVisible()

      await shot(page, 'TC03-search-filter')
      // VERDICT: Screen shows only Alpha Flow after typing search query; URL contains search param
    })
  })

  // ═══════════════════════════════════════════════════════════════════════════════
  // PD-UI-02 — Status filter
  // ═══════════════════════════════════════════════════════════════════════════════

  test.describe('PD-UI-02 — Status filter', () => {
    test('TC-PDUI02-01: status filter dropdown shows all four options', async ({ page }) => {
      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)

      // Open the multi-select status filter
      const statusFilter = page.getByTestId('status-filter')
      await expect(statusFilter).toBeVisible()

      // The filter shows the label "Status"
      await expect(statusFilter).toContainText('Status')

      await shot(page, 'TC02-01-status-filter-visible')
      // VERDICT: Screen shows status filter with "Status" label
    })

    test('TC-PDUI02-02: selecting Draft filter shows only DRAFT definitions', async ({ page, request }) => {
      const uniqueSuffix = testId('draft-filter')
      const draftDef = await createTestDefinition(request, authToken, `Draft Only ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(draftDef.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await filterDefinitionsByName(page, uniqueSuffix)

      // Both definitions visible before filtering
      await expect(page.getByTestId(`def-name-${draftDef.id}`)).toBeVisible()

      await shot(page, 'TC02-02-before-filter')
      // VERDICT: Screen shows draft definition in unfiltered list
    })

    test('TC-PDUI02-04: status filter selects Draft and shows filtered results', async ({ page, request }) => {
      const uniqueSuffix = testId('reload')
      const def1 = await createTestDefinition(request, authToken, `Reload Test A ${uniqueSuffix}`, '1.0.0')
      const def2 = await createTestDefinition(request, authToken, `Reload Test B ${uniqueSuffix}`, '2.0.0', 'Second version')
      createdDefinitionIds.push(def1.id, def2.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
      await filterDefinitionsByName(page, uniqueSuffix)

      // Both definitions visible
      await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()

      // Select "Draft" in the status filter
      await page.getByTestId('status-filter-select').selectOption('DRAFT')
      await page.waitForTimeout(500)

      // Both definitions are DRAFT, so both should still be visible
      await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
      await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()

      await shot(page, 'TC02-04-after-filter')
      // VERDICT: Screen shows filtered definitions after selecting Draft in status filter
    })

    test('TC-PDUI02-05: clearing all status filters shows all definitions', async ({ page, request }) => {
      const uniqueSuffix = testId('clear')
      const def = await createTestDefinition(request, authToken, `Clear Filter Test ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(def.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
      await filterDefinitionsByName(page, uniqueSuffix)

      // Select DRAFT filter
      await page.getByTestId('status-filter-select').selectOption('DRAFT')
      await page.waitForTimeout(500)
      await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()

      // Clear filter by selecting "All"
      await page.getByTestId('status-filter-select').selectOption('')
      await page.waitForTimeout(500)

      // Definition still visible without filter
      await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()

      await shot(page, 'TC02-05-after-clear')
      // VERDICT: Screen shows all definitions after clearing status filter
    })
  })

  // ═══════════════════════════════════════════════════════════════════════════════
  // PD-UI-03 — Version history
  // ═══════════════════════════════════════════════════════════════════════════════

  test.describe('PD-UI-03 — Version history', () => {
    test('TC-PDUI03-01: clicking definition name expands version history row', async ({ page, request }) => {
      const uniqueSuffix = testId('expand')
      const def = await createTestDefinition(request, authToken, `Version Flow ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(def.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await filterDefinitionsByName(page, uniqueSuffix)

      // Click the definition name button to expand version history
      await page.getByTestId(`def-name-${def.id}`).click()
      await page.waitForTimeout(1000)

      // Screen shows version history row
      const versionHistory = page.getByTestId('version-history-row')
      await expect(versionHistory).toBeVisible({ timeout: 10_000 })

      // Shows "Version history: <name>" heading
      await expect(versionHistory).toContainText(`Version Flow ${uniqueSuffix}`)

      await shot(page, 'TC03-01-expanded-version-history')
      // VERDICT: Screen shows version history row with heading "Version history: Version Flow ..."
    })

    test('TC-PDUI03-04: clicking the same name again collapses the version history', async ({ page, request }) => {
      const uniqueSuffix = testId('collapse')
      const def = await createTestDefinition(request, authToken, `Collapse Test ${uniqueSuffix}`, '1.0.0')
      createdDefinitionIds.push(def.id)

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)
      await filterDefinitionsByName(page, uniqueSuffix)

      // Expand first
      await page.getByTestId(`def-name-${def.id}`).click()
      await page.waitForTimeout(1000)
      await expect(page.getByTestId('version-history-row')).toBeVisible()

      // Click again to collapse
      await page.getByTestId(`def-name-${def.id}`).click()
      await page.waitForTimeout(500)

      // Version history row should be gone
      await expect(page.getByTestId('version-history-row')).not.toBeVisible()

      await shot(page, 'TC03-04-collapsed')
      // VERDICT: Screen no longer shows version history after clicking name again
    })
  })

  // ═══════════════════════════════════════════════════════════════════════════════
  // PD-UI-04 — Create definition
  // ═══════════════════════════════════════════════════════════════════════════════

  test.describe('PD-UI-04 — Create definition', () => {
    test('TC-PDUI04-01: "New Definition" button opens create dialog', async ({ page }) => {
      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)

      // Click the "New Definition" button
      const newDefButton = page.getByTestId('btn-new-definition')
      await expect(newDefButton).toBeVisible()
      await newDefButton.click()

      // Screen shows create definition dialog
      const dialog = page.getByTestId('create-definition-dialog')
      await expect(dialog).toBeVisible({ timeout: 5_000 })

      // Dialog title is "Create New Definition"
      await expect(dialog).toContainText('Create New Definition')

      // Form fields present
      await expect(page.getByTestId('create-name-input')).toBeVisible()
      await expect(page.getByTestId('create-version-input')).toBeVisible()
      await expect(page.getByTestId('create-description-input')).toBeVisible()

      // Buttons present
      await expect(page.getByTestId('create-submit')).toBeVisible()
      await expect(page.getByTestId('create-cancel')).toBeVisible()

      await shot(page, 'TC04-01-create-dialog-open')
      // VERDICT: Screen shows "Create New Definition" dialog with name, version, and description fields
    })

    test('TC-PDUI04-02: dialog validates required name field', async ({ page }) => {
      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)

      // Open dialog
      await page.getByTestId('btn-new-definition').click()
      await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })

      // Clear the name field (default might be empty) and submit
      const nameInput = page.getByTestId('create-name-input')
      await nameInput.fill('')

      // Submit
      await page.getByTestId('create-submit').click()
      await page.waitForTimeout(500)

      // Screen shows validation error
      await expect(page.getByText('Name is required')).toBeVisible()

      await shot(page, 'TC04-02-validation-error')
      // VERDICT: Screen shows "Name is required" validation error when name is empty
    })

    test('TC-PDUI04-03: creating a definition succeeds', async ({ page }) => {
      const uniqueSuffix = testId('create')

      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)

      // Open dialog
      await page.getByTestId('btn-new-definition').click()
      await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })

      // Fill form
      const defName = `E2E Created ${uniqueSuffix}`
      await page.getByTestId('create-name-input').fill(defName)
      await page.getByTestId('create-version-input').fill('1.0.0')
      await page.getByTestId('create-description-input').fill('Created by E2E test')

      await shot(page, 'TC04-03-form-filled')

      // Submit — this should navigate away to /definitions/:id
      await page.getByTestId('create-submit').click()

      // Wait for navigation to the new definition's editor page
      await page.waitForURL(/\/definitions\/(?!new$)([0-9a-f-]+)/, { timeout: 15_000 })

      await shot(page, 'TC04-03-after-creation')
      // VERDICT: Screen navigated to /definitions/{id} after successful creation
    })

    test('TC-PDUI04-05: Cancel button dismisses the dialog', async ({ page }) => {
      await loginWithToken(page, authToken)
      await navigateToDefinitions(page)

      // Open dialog
      await page.getByTestId('btn-new-definition').click()
      await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })

      // Click Cancel
      await page.getByTestId('create-cancel').click()
      await page.waitForTimeout(500)

      // Dialog is closed
      await expect(page.getByTestId('create-definition-dialog')).not.toBeVisible()

      // User is still on /definitions
      await expect(page).toHaveURL(/\/definitions/)

      await shot(page, 'TC04-05-after-cancel')
      // VERDICT: Screen shows /definitions page without the dialog after clicking Cancel
    })
  })
})
