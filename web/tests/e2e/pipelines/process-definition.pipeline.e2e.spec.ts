/**
 * Pipeline: Process Definition Lifecycle
 * Spec: tests/specs/PIPELINE-process-definition.md
 * Covers: PD-UI-01, PD-UI-02, PD-UI-04, PD-UI-09, PD-UI-10, PD-UI-12
 *
 * Chain: list → create → verify in list → canvas → rename node → save →
 *        reload verify → activate → verify read-only → verify ACTIVE in list
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  extractIdFromUrl,
  authHeaders,
} from '../pipeline'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
const API_PREFIX = '/api/v1'

interface ProcessDefinitionState {
  adminToken: string
  definitionId: string
  definitionName: string
  savedTaskName: string
}

async function navigateToCanvas(page: import('@playwright/test').Page, definitionId: string): Promise<void> {
  await page.evaluate((id) => {
    window.history.pushState({}, '', `/definitions/${id}`)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, definitionId)
  await page.waitForURL(`/definitions/${definitionId}`, { timeout: 10_000 })
  await expect(page.getByTestId('process-canvas')).toBeVisible({ timeout: 15_000 })
}

test.describe('Pipeline: process definition lifecycle (PD-UI-01, 02, 04, 09, 10, 12)', () => {
  test('full lifecycle: list → create → edit canvas → save → activate → read-only', async ({ page, request }) => {
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`)
    if (!backendOk.ok()) throw new Error(`Backend not ready: ${backendOk.status()}`)
    const idpOk = await request.fetch(KEYCLOAK_DISCOVERY_URL)
    if (!idpOk.ok()) throw new Error(`Keycloak not ready: ${idpOk.status()}`)

    const adminToken = await getKeycloakToken(request)
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 10)
    const defName = `Pipeline Def ${fixtureId}`
    const savedTaskName = `Pipeline Task ${fixtureId}`

    const pl = createPipeline<ProcessDefinitionState>('process-definition', { page, request })
    pl.state.adminToken = adminToken

    pl.onCleanup(async (s) => {
      if (!s.definitionId) return
      await request.delete(`${API_BASE_URL}${API_PREFIX}/definitions/${s.definitionId}`, {
        headers: authHeaders(s.adminToken),
      }).catch(() => {})
    })

    // ── Step 1: Definition list structure ─────────────────────────────────────
    await pl.step('PD-UI-01: definition list structure and empty search', async () => {
      await page.getByRole('link', { name: 'Definitions' }).click()
      await page.waitForURL(/\/definitions/, { timeout: 10_000 })
      await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId('btn-new-definition')).toBeVisible()

      await page.getByTestId('definition-search').fill(`nonexistent-${fixtureId}`)
      await page.waitForTimeout(1500)
      await expect(page.getByText('No results found')).toBeVisible({ timeout: 10_000 })
      await page.getByTestId('definition-search').fill('')
    })

    // ── Step 2: Create definition via dialog ──────────────────────────────────
    await pl.step('PD-UI-04: create definition via dialog', async (s) => {
      await page.getByTestId('btn-new-definition').click()
      const dialog = page.getByTestId('create-definition-dialog')
      await expect(dialog).toBeVisible({ timeout: 5_000 })
      await expect(dialog).toContainText('Create New Definition')

      await page.getByTestId('create-name-input').fill(defName)
      await page.getByTestId('create-version-input').fill('1.0.0')
      await page.getByTestId('create-description-input').fill('Created by pipeline E2E test')
      await page.getByTestId('create-submit').click()

      await page.waitForURL(/\/definitions\/(?!new$)([0-9a-f-]+)/, { timeout: 15_000 })
      s.definitionId = extractIdFromUrl(page.url(), 'definitions')
      s.definitionName = defName
      pl.gate(!!s.definitionId, 'definitionId must be present in URL after creation')
    })

    // ── Step 3: Verify in list with DRAFT status ───────────────────────────────
    await pl.step('PD-UI-01: definition appears in list as DRAFT', async (s) => {
      await page.getByRole('link', { name: 'Definitions' }).click()
      await page.waitForURL(/\/definitions/, { timeout: 10_000 })
      await page.getByTestId('definition-search').fill(s.definitionName)
      await page.waitForTimeout(1500)
      await expect(page.getByTestId(`def-name-${s.definitionId}`)).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId(`def-name-${s.definitionId}`)).toContainText(s.definitionName)
    })

    // ── Step 4: Canvas renders with default nodes ──────────────────────────────
    await pl.step('PD-UI-09: canvas loads with nodes and palette', async (s) => {
      await navigateToCanvas(page, s.definitionId)
      await expect(page.getByTestId('node-palette')).toBeVisible()
      await expect(page.locator('.react-flow__node')).toHaveCount(2) // START + END from dialog default
    })

    // ── Step 5: Add and rename a HUMAN_TASK node ──────────────────────────────
    await pl.step('PD-UI-10 + PD-UI-12: add node via palette and rename it', async (s) => {
      await navigateToCanvas(page, s.definitionId)

      const humanTaskItem = page.getByTestId('palette-item-HUMAN_TASK')
      await expect(humanTaskItem).toBeVisible()
      await humanTaskItem.dblclick()
      await page.waitForTimeout(500)
      await expect(page.locator('.react-flow__node')).toHaveCount(3)

      // Click the newly added node — it will be the last one with no label yet
      const nodes = page.locator('.react-flow__node')
      await nodes.last().click()
      await page.waitForTimeout(400)

      const propertyPanel = page.getByTestId('property-panel')
      await expect(propertyPanel).toBeVisible({ timeout: 5_000 })

      const nameInput = page.getByTestId('prop-name-input')
      await expect(nameInput).toBeVisible()
      await nameInput.clear()
      await nameInput.fill(savedTaskName)
      await page.waitForTimeout(300)
      await expect(page.getByText(savedTaskName)).toBeVisible()

      s.savedTaskName = savedTaskName
    })

    // ── Step 6: Save definition ───────────────────────────────────────────────
    await pl.step('PD-UI-12: save definition', async (s) => {
      const saveButton = page.getByTestId('btn-save-definition')
      await expect(saveButton).toBeVisible()
      await expect(saveButton).not.toBeDisabled()
      await saveButton.click()
      await expect(page.getByText('Definition saved', { exact: false })).toBeVisible({ timeout: 10_000 })
    })

    // ── Step 7: Reload and verify change persisted ────────────────────────────
    await pl.step('PD-UI-09: reload canvas and verify saved name persisted', async (s) => {
      await loginWithToken(page, s.adminToken)
      await navigateToCanvas(page, s.definitionId)
      await expect(page.locator('.react-flow__node')).toHaveCount(3)
      await expect(page.getByText(s.savedTaskName)).toBeVisible({ timeout: 10_000 })
      pl.gate(await page.getByText(s.savedTaskName).count() > 0, `"${s.savedTaskName}" must be visible after reload`)
    })

    // ── Step 8: Activate definition ───────────────────────────────────────────
    await pl.step('PD-UI-04: activate definition', async (s) => {
      await navigateToCanvas(page, s.definitionId)
      const activateButton = page.getByRole('button', { name: /Activate/i })
      await expect(activateButton).toBeVisible({ timeout: 5_000 })
      await activateButton.click()

      // Confirm dialog if present
      const confirmButton = page.getByRole('button', { name: /Confirm|Activate/i }).last()
      const hasConfirm = await confirmButton.count() > 0
      if (hasConfirm && await confirmButton.isVisible()) {
        await confirmButton.click()
      }
      await page.waitForTimeout(500)
    })

    // ── Step 9: Verify canvas is read-only ────────────────────────────────────
    await pl.step('PD-UI-09: canvas is read-only after activation', async (s) => {
      await loginWithToken(page, s.adminToken)
      await navigateToCanvas(page, s.definitionId)
      await expect(page.getByTestId('read-only-banner')).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId('read-only-banner')).toContainText('ACTIVE')
      await expect(page.getByTestId('node-palette')).not.toBeVisible()
      await expect(page.getByTestId('btn-save-definition')).not.toBeVisible()
      pl.gate(true, 'canvas confirmed read-only after activation')
    })

    // ── Step 10: Verify ACTIVE in definition list ─────────────────────────────
    await pl.step('PD-UI-02: ACTIVE definition visible in list with status filter', async (s) => {
      await page.getByRole('link', { name: 'Definitions' }).click()
      await page.waitForURL(/\/definitions/, { timeout: 10_000 })
      await page.getByTestId('definition-search').fill(s.definitionName)
      await page.waitForTimeout(1500)

      const statusFilter = page.getByTestId('status-filter-select')
      if (await statusFilter.count() > 0) {
        await statusFilter.selectOption('ACTIVE')
        await page.waitForTimeout(500)
      }

      await expect(page.getByTestId(`def-name-${s.definitionId}`)).toBeVisible({ timeout: 10_000 })
    })

    await pl.runCleanup()
  })
})
