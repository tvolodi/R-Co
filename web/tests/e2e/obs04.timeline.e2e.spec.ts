import { expect, test } from '@playwright/test'
import { loginWithToken } from './helpers'

const E2E_INSTANCE_ID = process.env.BPM_E2E_INSTANCE_ID
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
  await page.route('**/api/v1/**', async (route) => {
    const request = route.request()
    const method = request.method()
    const url = new URL(request.url())
    const path = url.pathname

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
    await loginWithToken(page, TOKEN_PROCESS_OPERATOR)

    const instancesHeading = page.getByRole('heading', { name: 'Instances' })
    await expect(instancesHeading).toBeVisible()
    await page.screenshot({ path: 'test-results/obs04-01-instances.png', fullPage: true })

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
