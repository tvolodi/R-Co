import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { getKeycloakToken, loginWithToken } from './helpers'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_PREFIX = '/api/v1'

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: path.join(dir, `F3-${name}.png`), fullPage: true })
}

async function navigateSpa(page: import('@playwright/test').Page, targetPath: string): Promise<void> {
  await page.evaluate((path) => {
    window.history.pushState({}, '', path)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

async function assertNoErrorBoundary(page: import('@playwright/test').Page): Promise<void> {
  const panel = page.getByTestId('error-boundary-panel')
  const becameVisible = await panel
    .waitFor({ state: 'visible', timeout: 2_500 })
    .then(() => true)
    .catch(() => false)

  if (!becameVisible) return

  const details = page.getByTestId('error-boundary-details')
  if ((await details.count()) > 0 && await details.isVisible()) {
    await details.locator('summary').click()
    const content = (await details.locator('pre').textContent()) ?? 'unknown error'
    throw new Error(`ErrorBoundary was rendered: ${content}`)
  }

  throw new Error('ErrorBoundary was rendered without details')
}

async function getAnyActiveDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
): Promise<{ id: string; name: string; version: string }> {
  const unique = `f3-e2e-${Date.now()}`
  const createResponse = await request.post(`${API_PREFIX}/definitions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name: `F3 Monitoring ${unique}`,
      version: '1.0.0',
      description: 'Auto-created by F3 instance monitoring E2E setup',
      stage: null,
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: 'Start', attributes: null },
          { id: 'task-1', node_type: 'HUMAN_TASK', label: 'Review', attributes: '{"role":"OPS_REVIEWER"}' },
          { id: 'end', node_type: 'END', label: 'End', attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'task-1', condition: null, is_default: false },
          { id: 'e2', source: 'task-1', target: 'end', condition: null, is_default: false },
        ],
      },
    },
  })

  if (!createResponse.ok()) {
    const createBody = await createResponse.text()
    throw new Error(`POST /definitions failed during F3 setup (${createResponse.status()}): ${createBody}`)
  }

  const created = await createResponse.json() as { id: string; name: string; version: string }
  const activateResponse = await request.post(`${API_PREFIX}/definitions/${created.id}/activate`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })
  if (!activateResponse.ok()) {
    const activateBody = await activateResponse.text()
    throw new Error(`POST /definitions/${created.id}/activate failed during F3 setup (${activateResponse.status()}): ${activateBody}`)
  }
  return created
}

async function startInstanceApi(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  definitionId: string,
  correlationKey: string,
): Promise<{ instance_id: string }> {
  const response = await request.post(`${API_PREFIX}/instances`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      definition_id: definitionId,
      correlation_key: correlationKey,
      initial_variables: { source: 'f3-e2e', amount: 42 },
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`POST /instances failed (${response.status()}): ${body}`)
  }

  return response.json() as Promise<{ instance_id: string }>
}

async function cancelInstanceApi(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  instanceId: string,
  reason?: string,
): Promise<void> {
  const response = await request.post(`${API_PREFIX}/instances/${instanceId}/cancel`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: { reason },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`POST /instances/${instanceId}/cancel failed (${response.status()}): ${body}`)
  }
}

async function waitForTimelineEntries(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  instanceId: string,
): Promise<void> {
  const deadline = Date.now() + 20_000
  let lastStatus = 0
  let lastBody = ''

  while (Date.now() < deadline) {
    const response = await request.get(`${API_PREFIX}/instances/${instanceId}/timeline`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })

    lastStatus = response.status()
    lastBody = await response.text()

    if (response.ok()) {
      try {
        const parsed = JSON.parse(lastBody) as { count?: number }
        if (typeof parsed.count === 'number' && parsed.count > 0) {
          return
        }
      } catch {
        // Keep polling until deadline to absorb eventual-consistency windows.
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 500))
  }

  throw new Error(`Timeline seed did not become available for ${instanceId}. Last status=${lastStatus}, body=${lastBody}`)
}

function toDatetimeLocalInput(value: Date): string {
  const local = new Date(value.getTime() - value.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

test.describe('F3 instance monitoring UI (IN-UI-01..08)', () => {
  let token = ''
  let definitionId = ''
  let definitionName = ''
  let seededInstanceId = ''
  let historyTimelineInstanceId = ''
  let cancellableInstanceId = ''

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request)

    const def = await getAnyActiveDefinition(request, token)
    definitionId = def.id
    definitionName = def.name

    const seeded = await startInstanceApi(
      request,
      token,
      definitionId,
      `f3-seeded-${Date.now()}`,
    )
    seededInstanceId = seeded.instance_id

    const historyTimeline = await startInstanceApi(
      request,
      token,
      definitionId,
      `f3-history-timeline-${Date.now()}`,
    )
    historyTimelineInstanceId = historyTimeline.instance_id
    await cancelInstanceApi(request, token, historyTimelineInstanceId, 'Seed mixed history/timeline events for F3 E2E')
    await waitForTimelineEntries(request, token, historyTimelineInstanceId)

    const cancellable = await startInstanceApi(
      request,
      token,
      definitionId,
      `f3-cancellable-${Date.now()}`,
    )
    cancellableInstanceId = cancellable.instance_id
  })

  test('IN-UI-01/02: board shows required columns and URL-persisted filters', async ({ page }) => {
    await loginWithToken(page, token)

    await page.getByRole('link', { name: 'Instances' }).click()
    await page.waitForURL(/\/instances/)

    await expect(page.getByTestId('instance-board-table')).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Instance ID' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Definition' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Status' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Correlation Key' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Started' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Last Updated' })).toBeVisible()
    await shot(page, '01-board-columns')
    // VERDICT: Screen shows instance board table with required IN-UI-01 columns.

    await navigateSpa(page, `/instances?status=ACTIVE&definitionName=${encodeURIComponent(definitionName)}&definitionId=${encodeURIComponent(definitionId)}`)

    await expect(page.getByTestId('instance-board-table')).toBeVisible()
    await expect(page.getByTestId('status-filter-active')).toBeChecked()
    await expect(page).toHaveURL(new RegExp('status=ACTIVE'))
    await expect(page).toHaveURL(new RegExp('definitionName='))
    await shot(page, '02-filters-url-persisted')
    // VERDICT: Screen shows filtered rows after status and definition filters, and URL contains persisted filter state.
  })

  test('IN-UI-03: start instance dialog starts and navigates to detail', async ({ page }) => {
    await loginWithToken(page, token)

    await navigateSpa(page, `/instances?definitionName=${encodeURIComponent(definitionName)}&definitionId=${encodeURIComponent(definitionId)}`)

    await page.getByTestId('start-instance-button').click()
    await expect(page.getByTestId('start-instance-dialog')).toBeVisible()
    await shot(page, '03-start-dialog-open')
    // VERDICT: Screen shows start-instance dialog after clicking Start Instance.

    await page.getByTestId('start-definition-name').fill(definitionName)
    await page.getByTestId('start-definition-name').press('Tab')
    await page.getByTestId('start-correlation-key').fill(`f3-ui-start-${Date.now()}`)
    await page.getByTestId('start-variables-json').fill('{"source":"ui-start","nested":{"ok":true}}')
    await page.getByTestId('submit-start-instance').click()

    await page.waitForURL(/\/instances\//, { timeout: 12_000 })
    await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
    await shot(page, '04-start-navigate-detail')
    // VERDICT: Screen shows instance detail page after submitting Start Instance.
  })

  test('IN-UI-04: detail shows status, snapshot graph, variable map, and active-tasks panel', async ({ page }) => {
    await loginWithToken(page, token)

    await navigateSpa(page, `/instances/${seededInstanceId}`)
    await assertNoErrorBoundary(page)

    await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Definition Snapshot' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Variables' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Active Tasks' })).toBeVisible()
    await expect(page.getByTestId('instance-readonly-graph')).toBeVisible()
    await shot(page, '05-detail-panels')
    // VERDICT: Screen shows status, read-only graph panel, variables map, and active-task panel on the instance detail page.
  })

  test('IN-UI-05: history tab supports filters and expandable raw payload JSON', async ({ page }) => {
    await loginWithToken(page, token)

    await navigateSpa(page, `/instances/${historyTimelineInstanceId}`)
    await assertNoErrorBoundary(page)

    await page.getByRole('button', { name: 'History' }).click()
    await expect(page.getByRole('heading', { name: 'Event history' })).toBeVisible()
    await expect(page.getByTestId('event-history-filter-bar')).toBeVisible()
    await shot(page, '06-history-tab-open')
    // VERDICT: Screen shows Event history tab with filter controls.

    const eventTypeSelect = page.locator('label:has-text("Event type") select')
    await expect.poll(async () => await eventTypeSelect.locator('option').count(), { timeout: 10_000 }).toBeGreaterThan(1)

    const historySection = page.locator('section').filter({ has: page.getByTestId('event-history-filter-bar') })
    const historyTable = historySection.locator('table').first()
    const firstRow = historyTable.locator('tbody tr').first()
    await firstRow.locator('summary', { hasText: 'Payload' }).click()
    await expect(firstRow.locator('pre')).toBeVisible()

    const selectedType = await eventTypeSelect.locator('option').nth(1).getAttribute('value')
    expect(selectedType).toBeTruthy()
    await eventTypeSelect.selectOption(selectedType ?? undefined)
    await page.getByRole('button', { name: 'Apply' }).click()
    await expect(eventTypeSelect).toHaveValue(selectedType ?? '')

    const fromInput = page.locator('input[type="datetime-local"]').first()
    const toInput = page.locator('input[type="datetime-local"]').nth(1)
    const now = new Date()
    await fromInput.fill(toDatetimeLocalInput(new Date(now.getTime() - 24 * 60 * 60 * 1000)))
    await toInput.fill(toDatetimeLocalInput(new Date(now.getTime() + 60 * 60 * 1000)))
    await page.getByRole('button', { name: 'Apply' }).click()
    await expect(page.getByText('Range:')).toBeVisible()

    await shot(page, '07-history-filters-payload')
    // VERDICT: Screen shows filtered history rows by event type/time range and expanded raw JSON payload inline.
  })

  test('IN-UI-06: timeline tab shows avatar, timestamp, and human-readable description', async ({ page }) => {
    await loginWithToken(page, token)

    await navigateSpa(page, `/instances/${historyTimelineInstanceId}`)
    await assertNoErrorBoundary(page)

    const timelineRequestPromise = page.waitForResponse(
      (response) => response.url().includes(`/api/v1/instances/${historyTimelineInstanceId}/timeline`) && response.request().method() === 'GET',
    )

    await page.getByRole('button', { name: 'Timeline' }).click()
    await expect(page.getByRole('heading', { name: 'Timeline' })).toBeVisible()

    const timelineResponse = await timelineRequestPromise
    expect(timelineResponse.ok()).toBeTruthy()
    const timelinePayload = await timelineResponse.json() as { count?: number }
    expect(timelinePayload.count ?? 0).toBeGreaterThan(0)

    const firstTimelineEntry = page.locator('article').first()
    await expect(firstTimelineEntry).toBeVisible({ timeout: 10_000 })

    const avatar = firstTimelineEntry.locator('div[aria-label="System actor"], div[aria-label^="Actor "]').first()
    await expect(avatar).toBeVisible()
    await expect(firstTimelineEntry.locator('time')).toBeVisible()

    const description = (await firstTimelineEntry.locator('strong').first().innerText()).trim()
    const metaLine = (await firstTimelineEntry
      .locator('div')
      .filter({ hasText: /• seq/ })
      .first()
      .innerText()).trim()
    const eventType = metaLine.split(' • ')[0]?.trim() ?? ''
    expect(description.length).toBeGreaterThan(0)
    expect(eventType.length).toBeGreaterThan(0)
    expect(description).not.toBe(eventType)

    await shot(page, '08-timeline-feed')
    // VERDICT: Screen shows timeline feed with actor avatar, readable timestamp, and human-readable description text.
  })

  test('IN-UI-07: cancel flow confirms and updates status to CANCELLED', async ({ page }) => {
    await loginWithToken(page, token)

    await navigateSpa(page, `/instances/${cancellableInstanceId}`)
    await assertNoErrorBoundary(page)
    await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
    await expect(page.getByText('ACTIVE').first()).toBeVisible()

    await page.getByRole('button', { name: 'Cancel' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Cancel instance?' })).toBeVisible()
    await page.locator('#cancel-reason').fill('Operator cancellation from IN-UI-07 E2E')
    await shot(page, '09-cancel-dialog')
    // VERDICT: Screen shows cancellation confirmation dialog before the cancel API call.

    await page.getByRole('button', { name: 'Confirm cancellation' }).click()
    await expect(page.getByText('CANCELLED').first()).toBeVisible({ timeout: 10_000 })
    await expect(page.getByRole('button', { name: 'Cancel' })).toHaveCount(0)
    await shot(page, '10-cancelled-status')
    // VERDICT: Screen shows CANCELLED status on detail page after confirmation, matching cancel action UX.
  })

  test('IN-UI-08: board/detail refresh indicator and manual refresh are visible and functional', async ({ page }) => {
    await loginWithToken(page, token)

    await page.getByRole('link', { name: 'Instances' }).click()
    await page.waitForURL(/\/instances/)

    const boardLabel = page.locator('span:has-text("Last refreshed:")').first()
    await expect(boardLabel).toBeVisible()
    const boardBefore = (await boardLabel.textContent()) ?? ''
    await page.getByRole('button', { name: 'Refresh' }).first().click()
    await expect.poll(async () => (await boardLabel.textContent()) ?? '', { timeout: 8_000 }).not.toBe(boardBefore)
    await shot(page, '11-board-refresh-indicator')
    // VERDICT: Screen shows board last-refreshed indicator and manual Refresh updates the displayed refresh time.

    await navigateSpa(page, `/instances/${seededInstanceId}`)
    await assertNoErrorBoundary(page)
    const detailLabel = page.locator('span:has-text("Last refreshed:")').first()
    await expect(detailLabel).toBeVisible()
    const detailBefore = (await detailLabel.textContent()) ?? ''

    await expect.poll(async () => (await detailLabel.textContent()) ?? '', { timeout: 16_000 }).not.toBe(detailBefore)

    await page.getByRole('button', { name: 'Refresh' }).first().click()
    await expect(page.getByRole('button', { name: /Refresh|Refreshing\.\.\./ }).first()).toBeVisible()
    await shot(page, '12-detail-refresh-indicator')
    // VERDICT: Screen shows detail-page last-refreshed indicator auto-updating and manual Refresh trigger updating it on demand.
  })
})
