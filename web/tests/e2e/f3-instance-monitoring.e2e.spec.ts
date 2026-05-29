import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_TOKEN_URL = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
const KEYCLOAK_USERNAME = 'admin-user'
const KEYCLOAK_PASSWORD = 'admin-pass'
const API_PREFIX = '/api/v1'

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: path.join(dir, `F3-${name}.png`), fullPage: true })
}

async function getKeycloakToken(request: import('@playwright/test').APIRequestContext): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: KEYCLOAK_CLIENT_ID,
      username: KEYCLOAK_USERNAME,
      password: KEYCLOAK_PASSWORD,
      grant_type: 'password',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Keycloak token request failed (${response.status()}): ${body}`)
  }

  const body = await response.json() as { access_token: string }
  return body.access_token
}

async function loginWithToken(page: import('@playwright/test').Page, token: string): Promise<void> {
  await page.goto('/login')
  await expect(page.getByTestId('login-token-input')).toBeVisible()
  await page.getByTestId('login-token-input').fill(token)
  await page.getByTestId('login-submit').click()
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
  await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 10_000 })
}

async function navigateSpa(page: import('@playwright/test').Page, targetPath: string): Promise<void> {
  await page.evaluate((path) => {
    window.history.pushState({}, '', path)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
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

test.describe('F3 instance monitoring UI (IN-UI-01..04)', () => {
  let token = ''
  let definitionId = ''
  let definitionName = ''
  let seededInstanceId = ''

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

    await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Definition Snapshot' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Variables' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Active Tasks' })).toBeVisible()
    await expect(page.getByTestId('instance-readonly-graph')).toBeVisible()
    await shot(page, '05-detail-panels')
    // VERDICT: Screen shows status, read-only graph panel, variables map, and active-task panel on the instance detail page.
  })
})
