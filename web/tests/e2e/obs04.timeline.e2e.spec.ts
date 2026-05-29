import { expect, test } from '@playwright/test'

const E2E_EMAIL = process.env.BPM_E2E_EMAIL ?? 'obs04-e2e@local.test'
const E2E_PASSWORD = process.env.BPM_E2E_PASSWORD ?? 'obs04-e2e-password'
const E2E_INSTANCE_ID = process.env.BPM_E2E_INSTANCE_ID
const ACCESS_TOKEN = 'obs04-e2e-access-token'
const REFRESH_TOKEN = 'obs04-e2e-refresh-token'
const DEFAULT_INSTANCE_ID = E2E_INSTANCE_ID ?? '00000000-0000-0000-0000-000000000404'

function makeFakeJwt(payload: Record<string, unknown>): string {
  const encode = (obj: unknown) =>
    Buffer.from(JSON.stringify(obj))
      .toString('base64')
      .replace(/=+$/, '')
  const header = encode({ alg: 'none', typ: 'JWT' })
  const body = encode(payload)
  return `${header}.${body}.fake-sig`
}

const TOKEN_PROCESS_OPERATOR = makeFakeJwt({
  sub: 'obs04-e2e-user-001',
  display_name: 'OBS04 E2E User',
  roles: ['PROCESS_OPERATOR'],
})

const mockUser = {
  id: '00000000-0000-0000-0000-000000000111',
  email: E2E_EMAIL,
  display_name: 'OBS04 E2E User',
  is_active: true,
  roles: ['PROCESS_OPERATOR'],
  created_at: '2026-01-01T00:00:00Z',
}

const mockInstance = {
  instance_id: DEFAULT_INSTANCE_ID,
  definition_id: '00000000-0000-0000-0000-000000000222',
  definition_name: 'Obs Timeline Flow',
  definition_version: '1.0.0',
  status: 'ACTIVE',
  current_nodes: ['review_task'],
  variables: {
    customer_id: 'C-123',
    amount: 42,
  },
  started_at: '2026-05-25T00:00:00Z',
}

const mockTimeline = {
  items: [
    {
      event_type: 'TASK_COMPLETED',
      timestamp: '2026-05-25T00:00:10Z',
      actor_display_name: 'OBS04 E2E User',
      description: 'Task review_task completed',
      instance_id: DEFAULT_INSTANCE_ID,
      event_id: '00000000-0000-0000-0000-000000000333',
      sequence_num: 3,
      task_id: '00000000-0000-0000-0000-000000000444',
      node_id: 'review_task',
      metadata: {
        trace_id: 'obs04-e2e-trace-1',
      },
    },
  ],
  next_cursor: null,
  count: 1,
}

test.beforeEach(async ({ page }) => {
  await page.route('**/health/ready', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ status: 'ok' }),
    })
  })

  await page.route('**/api/v1/**', async (route) => {
    const request = route.request()
    const method = request.method()
    const url = new URL(request.url())
    const path = url.pathname

    if (path === '/api/v1/auth/login' && method === 'POST') {
      const body = request.postDataJSON() as { email?: string; password?: string }
      if (body.email === E2E_EMAIL && body.password === E2E_PASSWORD) {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            access_token: ACCESS_TOKEN,
            refresh_token: REFRESH_TOKEN,
            user: mockUser,
          }),
        })
        return
      }

      await route.fulfill({
        status: 401,
        contentType: 'application/json',
        body: JSON.stringify({
          title: 'Unauthorized',
          status: 401,
        }),
      })
      return
    }

    if (path === '/api/v1/auth/me' && method === 'GET') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(mockUser),
      })
      return
    }

    if (path === '/api/v1/auth/logout' && method === 'POST') {
      await route.fulfill({
        status: 204,
        body: '',
      })
      return
    }

    if (path === '/api/v1/instances' && method === 'GET') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          items: [mockInstance],
          next_cursor: null,
          has_more: false,
        }),
      })
      return
    }

    if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}` && method === 'GET') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(mockInstance),
      })
      return
    }

    if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}/events` && method === 'GET') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([]),
      })
      return
    }

    if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}/timeline` && method === 'GET') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(mockTimeline),
      })
      return
    }

    await route.fulfill({
      status: 404,
      contentType: 'application/json',
      body: JSON.stringify({
        title: 'Not Found',
        status: 404,
        path,
      }),
    })
  })
})

test.describe('OBS-04 timeline browser flow', () => {
  test('opens an instance and renders the timeline tab state', async ({ page }) => {
    await page.goto('/login')
    await expect(page.getByTestId('page-login')).toBeVisible()
    await page.screenshot({ path: 'test-results/obs04-01-login.png', fullPage: true })

    await page.getByTestId('login-token-input').fill(TOKEN_PROCESS_OPERATOR)
    await page.getByTestId('login-submit').click()
    await expect(page).not.toHaveURL(/\/login/)

    const instancesHeading = page.getByRole('heading', { name: 'Instances' })
    await expect(instancesHeading).toBeVisible()
    await page.screenshot({ path: 'test-results/obs04-02-instances.png', fullPage: true })

    if (E2E_INSTANCE_ID) {
      await page.goto(`/instances/${E2E_INSTANCE_ID}`)
    } else {
      const firstInstanceLink = page.locator('tbody tr td a').first()
      await expect(firstInstanceLink).toBeVisible()
      await firstInstanceLink.click()
    }

    await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
    await page.getByRole('button', { name: 'Timeline' }).click()
    await expect(page.getByRole('heading', { name: 'Timeline' })).toBeVisible()

    const timelineEntry = page.locator('article').first()
    const emptyMessage = page.getByText('No timeline entries found.')

    await Promise.race([
      timelineEntry.waitFor({ state: 'visible', timeout: 20_000 }).catch(() => null),
      emptyMessage.waitFor({ state: 'visible', timeout: 20_000 }).catch(() => null),
    ])

    await expect(timelineEntry.or(emptyMessage)).toBeVisible()
    await page.screenshot({ path: 'test-results/obs04-03-timeline.png', fullPage: true })
  })
})
